// Blend engine: two stem decks slaved to a master beat clock, per-stem time-stretch, scratch, loops, FX, beat-scheduled automation and output effects (radio, behind glass, hall, lo-fi).
#include "blend_engine.h"
#include "Track.h"
#include "signalsmith-stretch.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <mach/mach_time.h>
#include <vector>

namespace {

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

constexpr int kSeg = 64;
constexpr int kFade = 192;
constexpr int kMaxIn = 512;
constexpr int kSeekMax = 16384;
constexpr int kMaxEvents = 512;
constexpr int kRing = 1 << 17;
constexpr int kRingMask = kRing - 1;
constexpr int kDrums = 1;

enum { MODE_SLAVED = 0, MODE_SCRATCH = 1, MODE_SPINUP = 2, MODE_BRAKE = 3, MODE_REWIND = 4 };
enum { C_LOAD, C_SCHEDULE, C_CANCEL, C_PARAM, C_TEMPO, C_PLAY, C_STOP, C_CUE, C_SCR_BEGIN, C_SCR_MOVE, C_SCR_END, C_SYNC, C_RESET, C_FX };

struct IO {
    float *ch[2];
    float *operator[](int c) { return ch[c]; }
};

struct Cmd {
    int type = 0;
    int deck = 0;
    int param = 0;
    double a = 0;
    be_event ev{};
    be_track *track = nullptr;
};

template <class T, int N> struct Ring {
    T items[N];
    std::atomic<uint32_t> head{0}, tail{0};
    bool push(const T &v) {
        uint32_t h = head.load(std::memory_order_relaxed), n = (h + 1) % N;
        if (n == tail.load(std::memory_order_acquire)) return false;
        items[h] = v;
        head.store(n, std::memory_order_release);
        return true;
    }
    bool pop(T &v) {
        uint32_t t = tail.load(std::memory_order_relaxed);
        if (t == head.load(std::memory_order_acquire)) return false;
        v = items[t];
        tail.store((t + 1) % N, std::memory_order_release);
        return true;
    }
};

inline float hermite(float xm1, float x0, float x1, float x2, float t) {
    float c = (x1 - xm1) * 0.5f, v = x0 - x1, w = c + v, a = w + v + (x2 - x0) * 0.5f, b = w + a;
    return (((a * t) - b) * t + c) * t + x0;
}

inline float shape(float t, int curve) {
    switch (curve) {
    case BE_CURVE_SMOOTH: return t * t * (3.0f - 2.0f * t);
    case BE_CURVE_EASE_IN: return t * t;
    case BE_CURVE_EASE_OUT: return 1.0f - (1.0f - t) * (1.0f - t);
    default: return t;
    }
}

struct Param {
    float cur = 0, target = 0, v0 = 0, v1 = 0;
    bool ramp = false;
    double b0 = 0, b1 = 0;
    int curve = 0, tag = 0;

    void set(float v) {
        cur = target = v;
        ramp = false;
    }
    void begin(const be_event &ev) {
        float from = std::isnan(ev.from) ? cur : (float)ev.from;
        if (ev.endBeat <= ev.beat) {
            set((float)ev.value);
            return;
        }
        ramp = true;
        b0 = ev.beat;
        b1 = ev.endBeat;
        v0 = from;
        v1 = (float)ev.value;
        curve = ev.curve;
        tag = ev.tag;
        cur = target = from;
    }
    float advance(double beat, float smooth) {
        if (ramp) {
            if (beat >= b1) {
                cur = target = v1;
                ramp = false;
            } else if (beat > b0) {
                cur = target = v0 + (v1 - v0) * shape((float)((beat - b0) / (b1 - b0)), curve);
            }
        } else {
            cur += (target - cur) * smooth;
            if (std::fabs(target - cur) < 1e-5f) cur = target;
        }
        return cur;
    }
};

struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1[2] = {0, 0}, z2[2] = {0, 0};
    void set(bool high, double fc, double q, double sr) {
        double w = 2.0 * 3.14159265358979 * fc / sr, c = std::cos(w), alpha = std::sin(w) / (2.0 * q), a0 = 1.0 + alpha;
        double edge = high ? (1.0 + c) * 0.5 : (1.0 - c) * 0.5;
        b0 = (float)(edge / a0);
        b1 = (float)((high ? -(1.0 + c) : 1.0 - c) / a0);
        b2 = b0;
        a1 = (float)(-2.0 * c / a0);
        a2 = (float)((1.0 - alpha) / a0);
    }
    void clear() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
    inline float run(float x, int ch) {
        float y = b0 * x + z1[ch];
        z1[ch] = b1 * x - a1 * y + z2[ch];
        z2[ch] = b2 * x - a2 * y;
        return y;
    }
};

struct Hall {
    static constexpr int kCombs = 8, kPasses = 4;
    std::vector<float> comb[2][kCombs], pass[2][kPasses];
    int ci[2][kCombs] = {}, pi[2][kPasses] = {};
    float damp[2][kCombs] = {};
    void setup() {
        static const int combLen[kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}, passLen[kPasses] = {556, 441, 341, 225};
        for (int c = 0; c < 2; ++c) {
            for (int i = 0; i < kCombs; ++i) comb[c][i].assign((size_t)(combLen[i] + c * 23), 0.0f);
            for (int i = 0; i < kPasses; ++i) pass[c][i].assign((size_t)(passLen[i] + c * 23), 0.0f);
        }
    }
    void clear() {
        for (int c = 0; c < 2; ++c) {
            for (int i = 0; i < kCombs; ++i) {
                std::fill(comb[c][i].begin(), comb[c][i].end(), 0.0f);
                damp[c][i] = 0;
            }
            for (int i = 0; i < kPasses; ++i) std::fill(pass[c][i].begin(), pass[c][i].end(), 0.0f);
        }
    }
    inline float run(float in, int c) {
        float out = 0;
        for (int i = 0; i < kCombs; ++i) {
            std::vector<float> &b = comb[c][i];
            float y = b[(size_t)ci[c][i]];
            damp[c][i] = y * 0.72f + damp[c][i] * 0.28f;
            b[(size_t)ci[c][i]] = in + damp[c][i] * 0.86f;
            if (++ci[c][i] >= (int)b.size()) ci[c][i] = 0;
            out += y;
        }
        for (int i = 0; i < kPasses; ++i) {
            std::vector<float> &b = pass[c][i];
            float y = b[(size_t)pi[c][i]];
            b[(size_t)pi[c][i]] = out + y * 0.5f;
            if (++pi[c][i] >= (int)b.size()) pi[c][i] = 0;
            out = y - out;
        }
        return out;
    }
};

struct OutputFx {
    int now = 0, want = 0;
    float mix = 0;
    Biquad hp, lp1, lp2, glass1, glass2, crush;
    Hall hall;
    uint32_t seed = 22222;
    float held[2] = {0, 0}, sum[2] = {0, 0};
    int count = 0;

    void setup(double sr) {
        hp.set(true, 330.0, 0.707, sr);
        lp1.set(false, 3300.0, 0.707, sr);
        lp2.set(false, 3600.0, 0.9, sr);
        glass1.set(false, 430.0, 0.6, sr);
        glass2.set(false, 520.0, 0.707, sr);
        crush.set(false, 5200.0, 0.707, sr);
        hall.setup();
    }

    void reset() {
        hp.clear();
        lp1.clear();
        lp2.clear();
        glass1.clear();
        glass2.clear();
        crush.clear();
        hall.clear();
        held[0] = held[1] = sum[0] = sum[1] = 0;
        count = 0;
    }

    void process(float *L, float *R, int n) {
        for (int i = 0; i < n; ++i) {
            float target = (now == want && now != BE_FX_NONE) ? 1.0f : 0.0f;
            mix += (target - mix) * 0.0012f;
            if (now != want && mix < 0.004f) {
                now = want;
                mix = 0;
                reset();
            }
            if (now == BE_FX_NONE) continue;
            float l = L[i], r = R[i], wl = l, wr = r;
            switch (now) {
            case BE_FX_RADIO: {
                seed = seed * 1664525u + 1013904223u;
                float hiss = ((float)(seed >> 9) / 4194304.0f - 1.0f) * 0.0022f;
                float m = lp2.run(lp1.run(hp.run(0.5f * (l + r), 0), 0), 0);
                wl = wr = std::tanh(m * 2.6f) * 0.72f + hiss;
                break;
            }
            case BE_FX_GLASS: {
                float a = glass2.run(glass1.run(l, 0), 0), b = glass2.run(glass1.run(r, 1), 1);
                float midS = 0.5f * (a + b), side = 0.2f * (a - b);
                wl = (midS + side) * 1.2f;
                wr = (midS - side) * 1.2f;
                break;
            }
            case BE_FX_HALL: {
                float in = (l + r) * 0.015f;
                wl = l * 0.8f + hall.run(in, 0) * 0.9f;
                wr = r * 0.8f + hall.run(in, 1) * 0.9f;
                break;
            }
            case BE_FX_LOFI: {
                sum[0] += l;
                sum[1] += r;
                if (++count >= 5) {
                    held[0] = std::round(sum[0] * 0.2f * 24.0f) / 24.0f;
                    held[1] = std::round(sum[1] * 0.2f * 24.0f) / 24.0f;
                    sum[0] = sum[1] = 0;
                    count = 0;
                }
                wl = crush.run(held[0], 0);
                wr = crush.run(held[1], 1);
                break;
            }
            default: break;
            }
            L[i] = l + (wl - l) * mix;
            R[i] = r + (wr - r) * mix;
        }
    }
};

struct SVF {
    float ic1 = 0, ic2 = 0;
    inline void run(float x, float g, float k, float a1, float a2, float a3, float &lp, float &hp) {
        float v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2.0f * v1 - ic1;
        ic2 = 2.0f * v2 - ic2;
        lp = v2;
        hp = x - k * v1 - v2;
        (void)g;
    }
};

inline void readInt(const be_track *t, int stem, int64_t i0, int n, float *L, float *R) {
    const int16_t *d = t->pcm[stem].data();
    const float sc = t->gain / 32768.0f;
    const int64_t F = t->frames;
    for (int i = 0; i < n; ++i) {
        int64_t k = i0 + i;
        if (k >= 0 && k < F) {
            L[i] = d[2 * k] * sc;
            R[i] = d[2 * k + 1] * sc;
        } else {
            L[i] = R[i] = 0.0f;
        }
    }
}

inline double readVar(const be_track *t, int stem, double pos, double r0, double r1, int n, float *L, float *R) {
    const int16_t *d = t->pcm[stem].data();
    const float sc = t->gain / 32768.0f;
    const int64_t F = t->frames;
    double p = pos, r = r0, dr = (r1 - r0) / n;
    for (int i = 0; i < n; ++i) {
        double fl = std::floor(p);
        int64_t k = (int64_t)fl;
        float f = (float)(p - fl);
        if (k >= 1 && k + 2 < F) {
            const int16_t *q = d + 2 * (k - 1);
            L[i] = hermite(q[0], q[2], q[4], q[6], f) * sc;
            R[i] = hermite(q[1], q[3], q[5], q[7], f) * sc;
        } else {
            float a[4], b[4];
            for (int j = 0; j < 4; ++j) {
                int64_t m = k - 1 + j;
                bool ok = m >= 0 && m < F;
                a[j] = ok ? d[2 * m] : 0.0f;
                b[j] = ok ? d[2 * m + 1] : 0.0f;
            }
            L[i] = hermite(a[0], a[1], a[2], a[3], f) * sc;
            R[i] = hermite(b[0], b[1], b[2], b[3], f) * sc;
        }
        p += r;
        r += dr;
    }
    return p;
}

struct Scratch {
    float stem[BE_STEMS][2][kSeg];
    float in[2][kMaxIn];
    float seek[2][kSeekMax];
    float bus[2][kSeg];
    float tmp[2][kSeg];
};

struct Deck {
    be_track *track = nullptr;
    double sr = 44100.0;
    bool playing = false, ended = false, wasPlaying = false, reattached = false;
    int mode = MODE_SLAVED;
    double offset = 0, pos = 0, rate = 1, pitch = 0;

    bool stretching = false, bendOn = false;
    int64_t fed = 0;
    Stretch st[BE_STEMS];
    bool stOn[BE_STEMS] = {false, false, false, false};
    int inLat = 0, outLat = 0;

    double scratchTarget = 0, vrate = 0;
    double spinLeft = 0, brakeStep = 0;
    double rewindFrom = 0, rewindTotal = 1, rewindT = 0;

    bool loop = false;
    double loopStart = 0, loopLen = 4;

    bool rolling = false;
    int rollStart = 0, rollW = 0, rollLen = 0, rollT = 0, rollFade = 0;
    std::vector<float> rollBuf[2];

    std::vector<float> echoBuf[2];
    int echoW = 0;
    float echoLp[2] = {0, 0};
    int echoIdle = 1 << 30;

    Param p[BE_P_COUNT];
    float prev[BE_P_COUNT] = {0};
    SVF filt[2];
    int fadeIn = 0;

    bool ghost = false;
    double ghostPos = 0, ghostRate = 1;
    int ghostLeft = 0;

    float level[BE_STEMS] = {0, 0, 0, 0};

    void setup(double sampleRate) {
        sr = sampleRate;
        for (int s = 0; s < BE_STEMS; ++s) st[s].presetDefault(2, (float)sr, true);
        inLat = st[0].inputLatency();
        outLat = st[0].outputLatency();
        for (int c = 0; c < 2; ++c) {
            rollBuf[c].assign(kRing, 0.0f);
            echoBuf[c].assign(kRing, 0.0f);
        }
        defaults();
    }

    void defaults() {
        p[BE_P_VOLUME].set(1.0f);
        for (int s = 0; s < BE_STEMS; ++s) {
            p[BE_P_STEM0 + s].set(1.0f);
            p[BE_P_USER0 + s].set(1.0f);
        }
        p[BE_P_FILTER].set(0.0f);
        p[BE_P_ECHO].set(0.0f);
        for (int i = 0; i < BE_P_COUNT; ++i) prev[i] = p[i].cur;
        pitch = 0;
        applyPitch();
        loop = rolling = false;
    }

    void applyPitch(float bend = 0.0f) {
        for (int s = 0; s < BE_STEMS; ++s) {
            bool shift = track == nullptr || track->stems == 1 || s != kDrums;
            st[s].setTransposeSemitones((shift ? (float)pitch : 0.0f) + bend);
        }
    }

    double fpb() const { return sr * 60.0 / track->bpm; }
    double deckBeat() const { return track ? (pos - track->firstBeat) / fpb() : 0.0; }

    void beginGhost() {
        if (!playing) return;
        ghost = true;
        ghostPos = pos;
        ghostRate = rate;
        ghostLeft = kFade;
        fadeIn = kFade;
    }

    void startStretch(double audible, double r) {
        int ls = (int)std::lround(inLat + r * outLat);
        if (ls > kSeekMax) ls = kSeekMax;
        fed = (int64_t)std::llround(audible) + ls;
        stretching = true;
        for (int s = 0; s < BE_STEMS; ++s) stOn[s] = false;
    }

    void primeStem(int s, double r, Scratch &w) {
        int ls = (int)std::lround(inLat + r * outLat);
        if (ls > kSeekMax) ls = kSeekMax;
        readInt(track, s, fed - ls, ls, w.seek[0], w.seek[1]);
        IO in{{w.seek[0], w.seek[1]}};
        st[s].outputSeek(in, ls);
        stOn[s] = true;
    }

    void start(double trackBeat, double atBeat) {
        if (!track) return;
        if (playing) beginGhost();
        offset = trackBeat - atBeat;
        pos = track->firstBeat + trackBeat * fpb();
        mode = MODE_SLAVED;
        stretching = false;
        playing = true;
        ended = false;
        fadeIn = kFade;
        rate = 1;
    }

    void stop() {
        if (!playing) return;
        beginGhost();
        playing = false;
        rolling = false;
        mode = MODE_SLAVED;
    }

    void jump(double trackBeat, double atBeat) {
        if (!track) return;
        if (!playing) {
            pos = track->firstBeat + trackBeat * fpb();
            return;
        }
        beginGhost();
        offset = trackBeat - atBeat;
        pos = track->firstBeat + trackBeat * fpb();
        if (stretching) startStretch(pos, rate);
    }

    void render(int n, double beat0, double beat1, double bpm, Scratch &w, float *outL, float *outR) {
        float smooth = 1.0f - std::exp(-(float)n / (0.006f * (float)sr));
        float g0[BE_P_COUNT], g1[BE_P_COUNT];
        for (int i = 0; i < BE_P_COUNT; ++i) {
            g0[i] = prev[i];
            g1[i] = p[i].advance(beat1, smooth);
            prev[i] = g1[i];
        }
        for (int s = 0; s < BE_STEMS; ++s) level[s] *= 0.93f;
        if (!track) return;
        bool act[BE_STEMS];
        float sg0[BE_STEMS], sg1[BE_STEMS];
        for (int s = 0; s < BE_STEMS; ++s) {
            const Param &q = p[BE_P_STEM0 + s], &u = p[BE_P_USER0 + s];
            sg0[s] = g0[BE_P_STEM0 + s] * g0[BE_P_USER0 + s];
            sg1[s] = g1[BE_P_STEM0 + s] * g1[BE_P_USER0 + s];
            act[s] = s < track->stems && (sg0[s] > 1e-5f || sg1[s] > 1e-5f || ((q.target > 1e-5f || q.ramp) && u.target > 1e-5f));
        }

        std::memset(w.bus[0], 0, sizeof(float) * n);
        std::memset(w.bus[1], 0, sizeof(float) * n);
        bool have[BE_STEMS] = {false, false, false, false};

        if (playing) {
            double f = fpb();
            double slaved = bpm / track->bpm;
            if (mode == MODE_SLAVED) {
                rate = slaved;
                double want0 = track->firstBeat + (beat0 + offset) * f;
                double want1 = track->firstBeat + (beat1 + offset) * f;
                bool bent = !track->bend.empty();
                bool need = std::fabs(slaved - 1.0) > 1e-7 || pitch != 0.0 || bent;
                if (bent) {
                    applyPitch(track->bendAt(want0));
                    bendOn = true;
                } else if (bendOn) {
                    applyPitch();
                    bendOn = false;
                }
                if (need != stretching) {
                    beginGhost();
                    if (need) {
                        startStretch(want0, slaved);
                    } else {
                        stretching = false;
                        pos = std::round(want0);
                    }
                }
                if (stretching) {
                    double lat = inLat + slaved * outLat;
                    int64_t m64 = (int64_t)std::floor(want1 + lat) - fed;
                    if (m64 < 0 || m64 > kMaxIn) {
                        beginGhost();
                        startStretch(want0, slaved);
                        m64 = (int64_t)std::floor(want1 + lat) - fed;
                        if (m64 < 0) m64 = 0;
                        if (m64 > kMaxIn) m64 = kMaxIn;
                    }
                    int m = (int)m64;
                    for (int s = 0; s < track->stems; ++s) {
                        if (!act[s]) {
                            stOn[s] = false;
                            continue;
                        }
                        if (!stOn[s]) primeStem(s, slaved, w);
                        readInt(track, s, fed, m, w.in[0], w.in[1]);
                        IO in{{w.in[0], w.in[1]}}, out{{w.stem[s][0], w.stem[s][1]}};
                        st[s].process(in, m, out, n);
                        have[s] = true;
                    }
                    fed += m;
                    pos = (double)fed - lat;
                } else {
                    if (std::fabs(want0 - pos) > 1.0) {
                        beginGhost();
                        pos = std::round(want0);
                    }
                    for (int s = 0; s < track->stems; ++s) {
                        if (!act[s]) continue;
                        readInt(track, s, (int64_t)pos, n, w.stem[s][0], w.stem[s][1]);
                        have[s] = true;
                    }
                    pos += n;
                }
                if (pos > (double)track->frames + sr * 0.25) {
                    playing = false;
                    ended = true;
                }
            } else {
                double r0 = vrate, r1 = vrate;
                if (mode == MODE_SCRATCH) {
                    double target = (scratchTarget - pos) / (0.012 * sr);
                    if (target > 8.0) target = 8.0;
                    if (target < -8.0) target = -8.0;
                    r1 = vrate + (target - vrate) * 0.45;
                } else if (mode == MODE_SPINUP) {
                    double k = spinLeft > n ? (double)n / spinLeft : 1.0;
                    r1 = vrate + (slaved - vrate) * k;
                    spinLeft -= n;
                } else if (mode == MODE_REWIND) {
                    rewindT += n;
                    double u = rewindT >= rewindTotal ? 1.0 : rewindT / rewindTotal;
                    r1 = u < 0.15 ? rewindFrom + (-3.2 - rewindFrom) * (u / 0.15) : -3.2 + 2.4 * (u - 0.15) / 0.85;
                } else {
                    r1 = vrate - brakeStep * n;
                    if (r1 < 0.0) r1 = 0.0;
                }
                double end = pos;
                for (int s = 0; s < track->stems; ++s) {
                    if (!act[s]) continue;
                    end = readVar(track, s, pos, r0, r1, n, w.stem[s][0], w.stem[s][1]);
                    have[s] = true;
                }
                if (end == pos) end = pos + n * (r0 + r1) * 0.5;
                pos = end;
                vrate = r1;
                rate = r1;
                if (mode == MODE_SPINUP && spinLeft <= 0) {
                    mode = MODE_SLAVED;
                    offset = (pos - track->firstBeat) / f - beat1;
                    stretching = false;
                    pos = std::round(pos);
                    reattached = true;
                } else if (mode == MODE_BRAKE && r1 <= 0.0) {
                    playing = false;
                    mode = MODE_SLAVED;
                } else if (mode == MODE_REWIND && rewindT >= rewindTotal) {
                    beginGhost();
                    playing = false;
                    mode = MODE_SLAVED;
                }
            }
        }

        const float inv = 1.0f / n;
        for (int s = 0; s < track->stems; ++s) {
            if (!have[s]) continue;
            float a = sg0[s], b = sg1[s], d = (b - a) * inv, peak = 0;
            float *sl = w.stem[s][0], *sr2 = w.stem[s][1];
            for (int i = 0; i < n; ++i) {
                float g = a + d * i, x = sl[i] * g;
                w.bus[0][i] += x;
                w.bus[1][i] += sr2[i] * g;
                x = std::fabs(x);
                if (x > peak) peak = x;
            }
            if (peak > level[s]) level[s] = peak;
        }

        if (fadeIn > 0) {
            for (int i = 0; i < n; ++i) {
                float g = fadeIn > 0 ? 1.0f - (float)fadeIn / kFade : 1.0f;
                w.bus[0][i] *= g;
                w.bus[1][i] *= g;
                if (fadeIn > 0) --fadeIn;
            }
        }

        if (ghost) {
            int m = ghostLeft < n ? ghostLeft : n;
            double end = ghostPos;
            for (int s = 0; s < track->stems; ++s) {
                float g = sg1[s];
                if (g <= 1e-5f) continue;
                end = readVar(track, s, ghostPos, ghostRate, ghostRate, m, w.tmp[0], w.tmp[1]);
                for (int i = 0; i < m; ++i) {
                    float fo = g * (float)(ghostLeft - i) / kFade;
                    w.bus[0][i] += w.tmp[0][i] * fo;
                    w.bus[1][i] += w.tmp[1][i] * fo;
                }
            }
            ghostPos = end == ghostPos ? ghostPos + m * ghostRate : end;
            ghostLeft -= m;
            if (ghostLeft <= 0) ghost = false;
        }

        for (int i = 0; i < n; ++i) {
            if (!rolling) {
                rollBuf[0][rollW] = w.bus[0][i];
                rollBuf[1][rollW] = w.bus[1][i];
                rollW = (rollW + 1) & kRingMask;
                if (rollFade > 0) {
                    float g = 1.0f - (float)rollFade / 64.0f;
                    w.bus[0][i] *= g;
                    w.bus[1][i] *= g;
                    --rollFade;
                }
            } else {
                if (rollT < rollLen || rollT < 1) {
                    int k = (rollStart + rollT) & kRingMask;
                    rollBuf[0][k] = w.bus[0][i];
                    rollBuf[1][k] = w.bus[1][i];
                }
                int ph = rollT % (rollLen > 0 ? rollLen : 1);
                if (rollT >= rollLen) {
                    int k = (rollStart + ph) & kRingMask;
                    w.bus[0][i] = rollBuf[0][k];
                    w.bus[1][i] = rollBuf[1][k];
                }
                int edge = ph < rollLen - ph ? ph : rollLen - ph;
                if (edge < 48) {
                    float g = (float)edge / 48.0f;
                    w.bus[0][i] *= g;
                    w.bus[1][i] *= g;
                }
                ++rollT;
            }
        }

        float fv = g1[BE_P_FILTER], amt = std::fabs(fv);
        if (amt > 0.002f || std::fabs(g0[BE_P_FILTER]) > 0.002f) {
            float cutoff = fv < 0 ? 20000.0f * std::pow(80.0f / 20000.0f, amt) : 20.0f * std::pow(8000.0f / 20.0f, amt);
            float g = std::tan(3.14159265f * cutoff / (float)sr), k = 0.85f;
            float a1 = 1.0f / (1.0f + g * (g + k)), a2 = g * a1, a3 = g * a2;
            float wet = amt < 0.04f ? amt / 0.04f : 1.0f;
            for (int c = 0; c < 2; ++c) {
                float *x = w.bus[c];
                for (int i = 0; i < n; ++i) {
                    float lp, hp;
                    filt[c].run(x[i], g, k, a1, a2, a3, lp, hp);
                    x[i] += ((fv < 0 ? lp : hp) - x[i]) * wet;
                }
            }
        }

        float e0 = g0[BE_P_ECHO], e1 = g1[BE_P_ECHO];
        bool echoing = e0 > 1e-4f || e1 > 1e-4f;
        if (echoing) echoIdle = 0;
        float v0 = g0[BE_P_VOLUME], v1 = g1[BE_P_VOLUME];
        if (echoIdle < (int)(sr * 8.0)) {
            double delay = 0.75 * 60.0 / bpm * sr;
            if (delay > kRing - 8) delay = kRing - 8;
            int di = (int)delay;
            float df = (float)(delay - di);
            for (int i = 0; i < n; ++i) {
                float send = e0 + (e1 - e0) * inv * i, vol = v0 + (v1 - v0) * inv * i;
                int r0 = (echoW - di) & kRingMask, r1 = (r0 - 1) & kRingMask;
                for (int c = 0; c < 2; ++c) {
                    float y = echoBuf[c][r0] + (echoBuf[c][r1] - echoBuf[c][r0]) * df;
                    echoLp[c] += (y - echoLp[c]) * 0.42f;
                    echoBuf[c][echoW] = w.bus[c][i] * send + echoLp[c] * 0.58f;
                    (c == 0 ? outL : outR)[i] += w.bus[c][i] * vol + y;
                }
                echoW = (echoW + 1) & kRingMask;
            }
            echoIdle += n;
        } else {
            for (int i = 0; i < n; ++i) {
                float vol = v0 + (v1 - v0) * inv * i;
                outL[i] += w.bus[0][i] * vol;
                outR[i] += w.bus[1][i] * vol;
            }
        }
    }
};

}

struct be_engine {
    double sr = 44100.0;
    Deck deck[BE_DECKS];
    Scratch work;
    Param tempo;
    double beat = 0;
    uint64_t frames = 0;
    uint32_t epoch = 0;
    be_event events[kMaxEvents];
    bool used[kMaxEvents];
    int pending = 0;
    float limiter = 1.0f, peak = 0, load = 0;
    OutputFx fx;
    Ring<Cmd, 2048> cmds;
    Ring<be_track *, 64> retired;
    std::atomic<uint32_t> seq{0};
    be_state shared{};
    mach_timebase_info_data_t timebase{};

    Param *param(int d, int id) {
        if (id == BE_P_TEMPO) return &tempo;
        if (d < 0 || d >= BE_DECKS || id < 0 || id >= BE_P_COUNT) return nullptr;
        return &deck[d].p[id];
    }

    void apply(const be_event &ev) {
        if (ev.type == BE_EV_RAMP) {
            if (Param *q = param(ev.deck, ev.param)) q->begin(ev);
            return;
        }
        if (ev.deck < 0 || ev.deck >= BE_DECKS) return;
        Deck &d = deck[ev.deck];
        if (!d.track) return;
        double bpm = tempo.cur;
        switch (ev.type) {
        case BE_EV_START: d.start(ev.value, ev.beat); break;
        case BE_EV_STOP: d.stop(); break;
        case BE_EV_SEEK: d.jump(ev.value, ev.beat); break;
        case BE_EV_LOOP:
            d.loopLen = ev.value > 0.01 ? ev.value : 4.0;
            d.loopStart = std::isnan(ev.from) ? ev.beat + d.offset : ev.from;
            d.loop = true;
            break;
        case BE_EV_UNLOOP: d.loop = false; break;
        case BE_EV_BRAKE: {
            if (!d.playing) break;
            double total = (ev.value > 0.01 ? ev.value : 1.0) * 60.0 / bpm * sr;
            if (d.stretching) d.beginGhost();
            d.stretching = false;
            d.vrate = d.rate;
            d.brakeStep = d.rate / total;
            d.mode = MODE_BRAKE;
            break;
        }
        case BE_EV_SPIN: {
            if (!d.playing) break;
            if (d.stretching) d.beginGhost();
            d.stretching = false;
            d.vrate = d.rate;
            d.rewindFrom = d.rate;
            d.rewindTotal = (ev.value > 0.01 ? ev.value : 1.5) * 60.0 / bpm * sr;
            d.rewindT = 0;
            d.rolling = false;
            d.loop = false;
            d.mode = MODE_REWIND;
            break;
        }
        case BE_EV_ROLL: {
            int len = (int)(ev.value * 60.0 / bpm * sr);
            if (len < 64) len = 64;
            if (len > kRing - 64) len = kRing - 64;
            if (!d.rolling) {
                d.rolling = true;
                d.rollStart = d.rollW;
                d.rollT = 0;
                d.rollLen = len;
            } else if (len < d.rollLen || d.rollT < d.rollLen) {
                d.rollLen = len;
            }
            break;
        }
        case BE_EV_UNROLL:
            if (d.rolling) {
                d.rolling = false;
                d.rollFade = 64;
            }
            break;
        case BE_EV_PITCH:
            d.pitch = ev.value;
            d.applyPitch();
            break;
        default: break;
        }
    }

    void command(const Cmd &c) {
        Deck *d = (c.deck >= 0 && c.deck < BE_DECKS) ? &deck[c.deck] : nullptr;
        switch (c.type) {
        case C_LOAD:
            if (!d) break;
            d->playing = false;
            d->ghost = false;
            d->stretching = false;
            d->mode = MODE_SLAVED;
            d->ended = false;
            if (d->track) retired.push(d->track);
            d->track = c.track;
            d->pos = d->track ? d->track->firstBeat : 0.0;
            d->offset = 0;
            d->defaults();
            break;
        case C_SCHEDULE:
            for (int i = 0; i < kMaxEvents; ++i) {
                if (!used[i]) {
                    used[i] = true;
                    events[i] = c.ev;
                    ++pending;
                    break;
                }
            }
            break;
        case C_CANCEL:
            for (int i = 0; i < kMaxEvents; ++i) {
                if (used[i] && events[i].tag == c.param) {
                    used[i] = false;
                    --pending;
                }
            }
            for (int k = 0; k < BE_DECKS; ++k) {
                for (int i = 0; i < BE_P_COUNT; ++i) {
                    Param &q = deck[k].p[i];
                    if (q.ramp && q.tag == c.param) {
                        q.ramp = false;
                        q.target = q.cur;
                    }
                }
            }
            if (tempo.ramp && tempo.tag == c.param) {
                tempo.ramp = false;
                tempo.target = tempo.cur;
            }
            break;
        case C_PARAM:
            if (Param *q = param(c.deck, c.param)) {
                q->ramp = false;
                q->target = (float)c.a;
            }
            break;
        case C_TEMPO: tempo.set((float)c.a); break;
        case C_PLAY: {
            if (!d || !d->track) break;
            Deck &other = deck[1 - c.deck];
            double tb = std::isnan(c.a) ? d->deckBeat() : c.a;
            if (!other.playing) {
                beat = tb;
                tempo.set((float)d->track->bpm);
                ++epoch;
            }
            d->start(tb, beat);
            break;
        }
        case C_STOP:
            if (d) d->stop();
            break;
        case C_CUE:
            if (d && d->track) d->jump(c.a, beat);
            break;
        case C_SCR_BEGIN:
            if (!d || !d->track || d->mode == MODE_SCRATCH) break;
            d->wasPlaying = d->playing && d->mode != MODE_BRAKE && d->mode != MODE_REWIND;
            if (d->stretching) d->beginGhost();
            d->stretching = false;
            d->vrate = d->playing ? d->rate : 0.0;
            d->scratchTarget = d->pos;
            d->mode = MODE_SCRATCH;
            d->playing = true;
            d->ended = false;
            break;
        case C_SCR_MOVE:
            if (d && d->mode == MODE_SCRATCH) d->scratchTarget += c.a;
            break;
        case C_SCR_END:
            if (!d || d->mode != MODE_SCRATCH) break;
            if (d->wasPlaying) {
                d->mode = MODE_SPINUP;
                d->spinLeft = 0.07 * sr;
            } else {
                d->beginGhost();
                d->playing = false;
                d->mode = MODE_SLAVED;
            }
            break;
        case C_SYNC: {
            if (!d || !d->track || !d->playing || d->mode != MODE_SLAVED) break;
            double snapped = std::round(d->offset);
            if (std::fabs(snapped - d->offset) > 1e-4) {
                d->jump(beat + snapped, beat);
                ++epoch;
            }
            break;
        }
        case C_FX: fx.want = c.param; break;
        case C_RESET:
            for (int k = 0; k < BE_DECKS; ++k) {
                deck[k].stop();
                deck[k].defaults();
            }
            for (int i = 0; i < kMaxEvents; ++i) used[i] = false;
            pending = 0;
            break;
        default: break;
        }
    }

    void fire() {
        while (pending > 0) {
            int best = -1;
            for (int i = 0; i < kMaxEvents; ++i) {
                if (!used[i]) continue;
                bool now = std::isnan(events[i].beat);
                if (!now && events[i].beat > beat + 1e-9) continue;
                if (best < 0 || now || (!std::isnan(events[best].beat) && events[i].beat < events[best].beat)) best = i;
                if (now) break;
            }
            if (best < 0) return;
            used[best] = false;
            --pending;
            be_event ev = events[best];
            if (std::isnan(ev.beat)) {
                ev.beat = beat;
                if (ev.type == BE_EV_RAMP) ev.endBeat = beat + (std::isnan(ev.endBeat) ? 0.0 : ev.endBeat);
            }
            apply(ev);
        }
    }

    void render(float *L, float *R, int total) {
        uint64_t t0 = mach_absolute_time();
        Cmd c;
        while (cmds.pop(c)) command(c);
        std::memset(L, 0, sizeof(float) * total);
        std::memset(R, 0, sizeof(float) * total);
        int done = 0;
        while (done < total) {
            fire();
            double bpm = tempo.advance(beat, 1.0f);
            if (bpm < 40.0) bpm = 40.0;
            double bpf = bpm / (60.0 * sr);
            int n = total - done < kSeg ? total - done : kSeg;
            if (pending > 0) {
                for (int i = 0; i < kMaxEvents; ++i) {
                    if (!used[i]) continue;
                    double k = std::ceil((events[i].beat - beat) / bpf);
                    if (k < 1) k = 1;
                    if (k < n) n = (int)k;
                }
            }
            for (int k = 0; k < BE_DECKS; ++k) {
                Deck &d = deck[k];
                if (!d.loop || !d.playing || d.mode != MODE_SLAVED || !d.track) continue;
                double db = beat + d.offset, end = d.loopStart + d.loopLen;
                if (db >= end - 1e-9) {
                    d.jump(db - d.loopLen, beat);
                    db -= d.loopLen;
                }
                double left = std::ceil((end - db) / bpf);
                if (left < 1) left = 1;
                if (left < n) n = (int)left;
            }
            double beat1 = beat + n * bpf;
            for (int k = 0; k < BE_DECKS; ++k) deck[k].render(n, beat, beat1, bpm, work, L + done, R + done);
            for (int k = 0; k < BE_DECKS; ++k) {
                Deck &d = deck[k];
                if (!d.reattached) continue;
                d.reattached = false;
                if (!deck[1 - k].playing) {
                    double db = beat1 + d.offset, snapped = std::round(d.offset);
                    beat1 = db - snapped;
                    d.offset = snapped;
                }
                ++epoch;
            }
            if (fx.now != BE_FX_NONE || fx.want != BE_FX_NONE) fx.process(L + done, R + done, n);
            for (int i = done; i < done + n; ++i) {
                float l = L[i] * 0.84f, r = R[i] * 0.84f;
                float a = std::fabs(l) > std::fabs(r) ? std::fabs(l) : std::fabs(r);
                float want = a > 0.92f ? 0.92f / a : 1.0f;
                if (want < limiter) limiter = want;
                else limiter += (1.0f - limiter) * 0.0004f;
                L[i] = l * limiter;
                R[i] = r * limiter;
                if (a > peak) peak = a;
            }
            beat = beat1;
            done += n;
            frames += n;
        }
        uint64_t t1 = mach_absolute_time();
        double spent = (double)(t1 - t0) * timebase.numer / timebase.denom * 1e-9;
        float use = (float)(spent / (total / sr));
        load = use > load ? use : load + (use - load) * 0.05f;
        publish();
        peak *= 0.9f;
    }

    void publish() {
        seq.fetch_add(1, std::memory_order_acq_rel);
        be_state &s = shared;
        s.masterBeat = beat;
        s.masterBpm = tempo.cur;
        s.frames = frames;
        s.epoch = epoch;
        s.pendingEvents = pending;
        s.peak = peak;
        s.load = load;
        s.masterFx = fx.want;
        for (int k = 0; k < BE_DECKS; ++k) {
            Deck &d = deck[k];
            be_deck_state &o = s.deck[k];
            o.loaded = d.track != nullptr;
            o.playing = d.playing;
            o.mode = d.mode;
            o.looping = d.loop;
            o.rolling = d.rolling;
            o.stretching = d.stretching;
            o.ended = d.ended;
            o.frame = d.pos;
            o.beat = d.deckBeat();
            o.offset = d.offset;
            o.rate = d.playing ? d.rate : 0.0;
            o.pitch = d.pitch;
            for (int i = 0; i < BE_P_COUNT; ++i) o.params[i] = d.p[i].cur;
            for (int i = 0; i < BE_STEMS; ++i) o.level[i] = d.level[i];
        }
        seq.fetch_add(1, std::memory_order_acq_rel);
    }
};

extern "C" {

be_engine *be_create(double sampleRate) {
    be_engine *e = new be_engine();
    e->sr = sampleRate;
    for (int k = 0; k < BE_DECKS; ++k) e->deck[k].setup(sampleRate);
    for (int i = 0; i < kMaxEvents; ++i) e->used[i] = false;
    e->tempo.set(120.0f);
    e->fx.setup(sampleRate);
    mach_timebase_info(&e->timebase);
    e->publish();
    return e;
}

void be_destroy(be_engine *e) {
    if (!e) return;
    be_collect(e);
    for (int k = 0; k < BE_DECKS; ++k) {
        if (e->deck[k].track) be_track_release(e->deck[k].track);
    }
    delete e;
}

void be_render(be_engine *e, float *left, float *right, int32_t frames) { e->render(left, right, frames); }

void be_collect(be_engine *e) {
    be_track *t;
    while (e->retired.pop(t)) be_track_release(t);
}

void be_get_state(be_engine *e, be_state *out) {
    for (int tries = 0; tries < 64; ++tries) {
        uint32_t a = e->seq.load(std::memory_order_acquire);
        if (a & 1) continue;
        std::memcpy(out, &e->shared, sizeof(be_state));
        if (e->seq.load(std::memory_order_acquire) == a) return;
    }
}

void be_deck_load(be_engine *e, int32_t deck, be_track *t) {
    if (t) t->refs.fetch_add(1);
    Cmd c;
    c.type = C_LOAD;
    c.deck = deck;
    c.track = t;
    e->cmds.push(c);
}

void be_schedule(be_engine *e, const be_event *ev) {
    Cmd c;
    c.type = C_SCHEDULE;
    c.ev = *ev;
    e->cmds.push(c);
}

static void post(be_engine *e, int type, int deck, int param, double a) {
    Cmd c;
    c.type = type;
    c.deck = deck;
    c.param = param;
    c.a = a;
    e->cmds.push(c);
}

void be_cancel(be_engine *e, int32_t tag) { post(e, C_CANCEL, -1, tag, 0); }
void be_set_param(be_engine *e, int32_t deck, int32_t param, float value) { post(e, C_PARAM, deck, param, value); }
void be_set_tempo(be_engine *e, double bpm) { post(e, C_TEMPO, -1, 0, bpm); }
void be_play(be_engine *e, int32_t deck, double trackBeat) { post(e, C_PLAY, deck, 0, trackBeat); }
void be_stop(be_engine *e, int32_t deck) { post(e, C_STOP, deck, 0, 0); }
void be_cue(be_engine *e, int32_t deck, double trackBeat) { post(e, C_CUE, deck, 0, trackBeat); }
void be_scratch_begin(be_engine *e, int32_t deck) { post(e, C_SCR_BEGIN, deck, 0, 0); }
void be_scratch_move(be_engine *e, int32_t deck, double deltaFrames) { post(e, C_SCR_MOVE, deck, 0, deltaFrames); }
void be_scratch_end(be_engine *e, int32_t deck) { post(e, C_SCR_END, deck, 0, 0); }
void be_sync_phase(be_engine *e, int32_t deck) { post(e, C_SYNC, deck, 0, 0); }
void be_reset(be_engine *e) { post(e, C_RESET, -1, 0, 0); }
void be_set_master_fx(be_engine *e, int32_t preset) { post(e, C_FX, -1, preset, 0); }

}
