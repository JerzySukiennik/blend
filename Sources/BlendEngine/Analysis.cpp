// Blend engine: track storage plus offline analysis (beat grid, downbeat and phrase phase, key, loudness, per-beat stem energy, waveform).
#include "Track.h"
#include "blend_engine.h"

#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace {

constexpr double kRate = 44100.0;
constexpr int kVocals = 0, kDrums = 1, kBass = 2, kOther = 3;

struct FFT {
    int n, log2n;
    FFTSetup setup;
    std::vector<float> win, re, im, buf;
    explicit FFT(int size) : n(size), log2n((int)std::lround(std::log2((double)size))), win(size), re(size / 2), im(size / 2), buf(size) {
        setup = vDSP_create_fftsetup(log2n, kFFTRadix2);
        vDSP_hann_window(win.data(), n, vDSP_HANN_NORM);
    }
    ~FFT() { vDSP_destroy_fftsetup(setup); }
    void mag(const float *x, float *out) {
        vDSP_vmul(x, 1, win.data(), 1, buf.data(), 1, n);
        DSPSplitComplex sc{re.data(), im.data()};
        vDSP_ctoz((const DSPComplex *)buf.data(), 2, &sc, 1, n / 2);
        vDSP_fft_zrip(setup, &sc, 1, log2n, FFT_FORWARD);
        vDSP_zvabs(&sc, 1, out, 1, n / 2);
    }
};

std::vector<float> mono(const be_track *t, unsigned mask) {
    std::vector<float> out((size_t)t->frames, 0.0f);
    for (int s = 0; s < t->stems; ++s) {
        if (!(mask & (1u << s))) continue;
        const int16_t *d = t->pcm[s].data();
        for (int64_t i = 0; i < t->frames; ++i) out[(size_t)i] += (d[2 * i] + d[2 * i + 1]) * (0.5f / 32768.0f);
    }
    return out;
}

std::vector<float> onsetStrength(const std::vector<float> &x, int hop, double &fps) {
    const int n = 1024, bins = 372;
    FFT fft(n);
    fps = kRate / hop;
    size_t frames = x.size() > (size_t)n ? (x.size() - n) / hop : 0;
    std::vector<float> osf(frames, 0.0f), prev(bins, 0.0f), cur(n / 2);
    for (size_t m = 0; m < frames; ++m) {
        fft.mag(x.data() + m * hop, cur.data());
        float flux = 0;
        for (int b = 1; b < bins; ++b) {
            float v = std::log1p(60.0f * cur[b]);
            float d = v - prev[b];
            if (d > 0) flux += d;
            prev[b] = v;
        }
        osf[m] = flux;
    }
    int w = (int)(fps * 0.4);
    std::vector<float> out(frames, 0.0f);
    double acc = 0;
    for (size_t m = 0; m < frames; ++m) {
        acc += osf[m];
        if (m >= (size_t)w) acc -= osf[m - w];
        float mean = (float)(acc / std::min<size_t>(m + 1, w));
        out[m] = std::max(0.0f, osf[m] - mean);
    }
    return out;
}

double coarseTempo(const std::vector<float> &osf, double fps) {
    int lo = (int)(fps * 60.0 / 185.0), hi = (int)(fps * 60.0 / 70.0);
    double best = -1, bestLag = fps * 60.0 / 124.0;
    for (int lag = lo; lag <= hi; ++lag) {
        double s = 0, s2 = 0;
        for (size_t m = 0; m + 2 * lag < osf.size(); ++m) {
            s += osf[m] * osf[m + lag];
            s2 += osf[m] * osf[m + 2 * lag];
        }
        double bpm = fps * 60.0 / lag, oct = std::log2(bpm / 124.0);
        double score = (s + 0.5 * s2) * std::exp(-oct * oct / (2 * 0.32 * 0.32));
        if (score > best) {
            best = score;
            bestLag = lag;
        }
    }
    double bpm0 = fps * 60.0 / bestLag, top = -1, pick = bpm0;
    for (double bpm = bpm0 - 2.0; bpm <= bpm0 + 2.0; bpm += 0.02) {
        double T = fps * 60.0 / bpm;
        int phases = (int)T;
        for (int ph = 0; ph < phases; ++ph) {
            double s = 0;
            for (double p = ph; p < osf.size() - 1; p += T) s += osf[(size_t)(p + 0.5)];
            if (s > top) {
                top = s;
                pick = bpm;
            }
        }
    }
    return pick;
}

std::vector<double> onsetBeats(const std::vector<float> &osf, double fps, double bpm) {
    double T = fps * 60.0 / bpm, top = -1;
    int bestPh = 0;
    for (int ph = 0; ph < (int)T; ++ph) {
        double s = 0;
        for (double p = ph; p < osf.size() - 1; p += T) s += osf[(size_t)(p + 0.5)];
        if (s > top) {
            top = s;
            bestPh = ph;
        }
    }
    float mean = 0;
    for (float v : osf) mean += v;
    mean /= std::max<size_t>(1, osf.size());
    std::vector<double> beats;
    for (double p = bestPh; p < osf.size() - 4; p += T) {
        int c = (int)(p + 0.5), bi = c;
        for (int j = c - 3; j <= c + 3; ++j) {
            if (j > 0 && j < (int)osf.size() - 1 && osf[j] > osf[bi]) bi = j;
        }
        if (bi < 1 || osf[bi] < mean * 1.5f) continue;
        float a = osf[bi - 1], b = osf[bi], c2 = osf[bi + 1], den = a - 2 * b + c2;
        double frac = std::fabs(den) > 1e-9 ? 0.5 * (a - c2) / den : 0.0;
        beats.push_back((bi + frac) / fps + 512.0 / kRate);
    }
    return beats;
}

bool fitGrid(const double *bt, int n, double &T, double &t0, float &conf, double *roundT = nullptr, double *roundT0 = nullptr) {
    if (n < 12) return false;
    std::vector<double> d;
    for (int i = 1; i < n; ++i) d.push_back(bt[i] - bt[i - 1]);
    std::nth_element(d.begin(), d.begin() + d.size() / 2, d.end());
    double T0 = d[d.size() / 2];
    if (T0 < 0.2 || T0 > 1.2) return false;
    int runStart = 0, runLen = 1, bestStart = 0, bestLen = 1;
    for (int i = 1; i < n; ++i) {
        if (std::fabs((bt[i] - bt[i - 1]) - T0) < 0.09 * T0) {
            ++runLen;
        } else {
            runStart = i;
            runLen = 1;
        }
        if (runLen > bestLen) {
            bestLen = runLen;
            bestStart = runStart;
        }
    }
    if (bestLen < 8) return false;
    double a = (bt[bestStart + bestLen - 1] - bt[bestStart]) / (bestLen - 1), b = bt[bestStart];
    if (60.0 / a < 85.0) a *= 0.5;
    double centre = 0.5 * (bt[bestStart] + bt[bestStart + bestLen - 1]);
    double reach = std::max(8.0, 0.5 * (bt[bestStart + bestLen - 1] - bt[bestStart]));
    double span = bt[n - 1] - bt[0];
    std::vector<double> k(n, 0.0);
    std::vector<char> keep(n, 0);
    for (int pass = 0; pass < 24; ++pass) {
        double tol = reach > span ? 0.03 : 0.05;
        double sk = 0, st = 0, skk = 0, skt = 0;
        int m = 0;
        for (int i = 0; i < n; ++i) {
            k[i] = std::round((bt[i] - b) / a);
            keep[i] = std::fabs(bt[i] - centre) <= reach && std::fabs(bt[i] - (b + a * k[i])) < tol;
            if (!keep[i]) continue;
            sk += k[i];
            st += bt[i];
            skk += k[i] * k[i];
            skt += k[i] * bt[i];
            ++m;
        }
        double den = m * skk - sk * sk;
        if (m < 8 || std::fabs(den) < 1e-9) break;
        a = (m * skt - sk * st) / den;
        b = (st - a * sk) / m;
        if (reach > span * 2) break;
        reach *= 1.6;
    }
    double bpm = 60.0 / a, whole = std::round(bpm);
    if (roundT) *roundT = 0;
    if (roundT && roundT0 && std::fabs(bpm - whole) < 0.03) {
        std::vector<double> r;
        for (int i = 0; i < n; ++i) {
            if (keep[i]) r.push_back(bt[i] - 60.0 / whole * k[i]);
        }
        if (!r.empty()) {
            std::nth_element(r.begin(), r.begin() + r.size() / 2, r.end());
            *roundT = 60.0 / whole;
            *roundT0 = r[r.size() / 2];
        }
    }
    int good = 0;
    for (int i = 0; i < n; ++i) {
        double ph = (bt[i] - b) / a;
        if (std::fabs(ph - std::round(ph)) * a < 0.03) ++good;
    }
    conf = (float)good / n;
    T = a;
    t0 = b;
    return true;
}

double hitWeight(const std::vector<float> &x, double t0, double T) {
    const int w = (int)(0.04 * kRate);
    double acc = 0;
    int n = 0;
    for (double t = t0; (t + 0.05) * kRate < (double)x.size(); t += T) {
        if (t < 0) continue;
        size_t i0 = (size_t)(t * kRate);
        double e = 0;
        for (int i = 0; i < w; ++i) e += std::fabs(x[i0 + i]);
        acc += e;
        ++n;
    }
    return n ? acc / n : 0.0;
}

double refinePhase(const std::vector<float> &x, double t0, double T, bool lowpass) {
    const int D = 16;
    size_t n = x.size() / D;
    std::vector<float> env(n);
    float lp1 = 0, lp2 = 0;
    const float k = lowpass ? 0.021f : 1.0f;
    for (size_t i = 0; i < n; ++i) {
        float m = 0;
        for (int j = 0; j < D; ++j) {
            lp1 += (x[i * D + j] - lp1) * k;
            lp2 += (lp1 - lp2) * k;
            float v = std::fabs(lp2);
            if (v > m) m = v;
        }
        env[i] = m;
    }
    double fs = kRate / D;
    int W = (int)(0.06 * fs);
    std::vector<double> avg(2 * W + 1, 0.0);
    int count = 0;
    for (double t = t0; t * fs < (double)n - W - 1; t += T) {
        long c = std::lround(t * fs);
        if (c < W) continue;
        for (int j = -W; j <= W; ++j) avg[j + W] += env[c + j];
        ++count;
    }
    if (count < 8) return t0;
    int reach = (int)(0.045 * fs), pk = W;
    for (int j = W - reach; j <= W + reach; ++j) {
        if (avg[j] > avg[pk]) pk = j;
    }
    double base = avg[pk];
    for (int j = std::max(0, pk - (int)(0.03 * fs)); j <= pk; ++j) base = std::min(base, avg[j]);
    std::vector<double> sorted(avg);
    std::nth_element(sorted.begin(), sorted.begin() + sorted.size() / 2, sorted.end());
    if (avg[pk] < sorted[sorted.size() / 2] * 1.3) return t0;
    double thr = base + 0.3 * (avg[pk] - base);
    int at = pk;
    while (at > 0 && avg[at - 1] > thr) --at;
    return t0 + (at - W) / fs;
}

struct Chroma {
    std::vector<float> frames;
    double fps = 0;
    size_t count = 0;
};

Chroma chromaOf(const std::vector<float> &x) {
    const int D = 4, n = 4096, hop = 2048;
    std::vector<float> y(x.size() / D);
    for (size_t i = 0; i < y.size(); ++i) y[i] = 0.25f * (x[i * D] + x[i * D + 1] + x[i * D + 2] + x[i * D + 3]);
    double fs = kRate / D;
    FFT fft(n);
    std::vector<int> pc(n / 2, -1);
    for (int b = 1; b < n / 2; ++b) {
        double f = b * fs / n;
        if (f < 62.0 || f > 2100.0) continue;
        int note = (int)std::lround(12.0 * std::log2(f / 440.0)) + 69;
        pc[b] = ((note % 12) + 12) % 12;
    }
    Chroma c;
    c.fps = fs / hop;
    c.count = y.size() > (size_t)n ? (y.size() - n) / hop : 0;
    c.frames.assign(c.count * 12, 0.0f);
    std::vector<float> mag(n / 2);
    for (size_t m = 0; m < c.count; ++m) {
        fft.mag(y.data() + m * hop, mag.data());
        for (int b = 2; b < n / 2 - 1; ++b) {
            if (pc[b] < 0 || mag[b] < mag[b - 1] || mag[b] < mag[b + 1]) continue;
            c.frames[m * 12 + pc[b]] += mag[b] * mag[b];
        }
    }
    return c;
}

int detectKey(const Chroma &c, float &strength) {
    static const double maj[12] = {0.16519551, 0.04749026, 0.08293076, 0.06687112, 0.09994645, 0.09274123, 0.05294487, 0.13159476, 0.05218986, 0.07443653, 0.06940723, 0.0642515};
    static const double mnr[12] = {0.17235348, 0.05336489, 0.0761009, 0.10043649, 0.05621498, 0.08527853, 0.0497915, 0.13451001, 0.07458916, 0.05003023, 0.09187879, 0.05545106};
    double h[12] = {0};
    for (size_t m = 0; m < c.count; ++m) {
        double tot = 0;
        for (int i = 0; i < 12; ++i) tot += c.frames[m * 12 + i];
        if (tot <= 1e-9) continue;
        for (int i = 0; i < 12; ++i) h[i] += std::sqrt(c.frames[m * 12 + i] / tot);
    }
    double best = -2, second = -2;
    int key = 0;
    for (int k = 0; k < 24; ++k) {
        const double *p = k < 12 ? maj : mnr;
        double mx = 0, my = 0;
        for (int i = 0; i < 12; ++i) {
            mx += h[(i + k) % 12];
            my += p[i];
        }
        mx /= 12;
        my /= 12;
        double sxy = 0, sxx = 0, syy = 0;
        for (int i = 0; i < 12; ++i) {
            double a = h[(i + k) % 12] - mx, b = p[i] - my;
            sxy += a * b;
            sxx += a * a;
            syy += b * b;
        }
        double r = sxx > 0 ? sxy / std::sqrt(sxx * syy) : 0;
        if (r > best) {
            second = best;
            best = r;
            key = k;
        } else if (r > second) {
            second = r;
        }
    }
    strength = (float)(best - second);
    return key;
}

std::vector<float> beatEnergy(const be_track *t, double fpb, double first, int &beats) {
    beats = (int)std::floor(((double)t->frames - first) / fpb);
    if (beats < 0) beats = 0;
    std::vector<float> e((size_t)beats * BE_STEMS, 0.0f);
    for (int s = 0; s < t->stems; ++s) {
        const int16_t *d = t->pcm[s].data();
        for (int b = 0; b < beats; ++b) {
            int64_t a = (int64_t)(first + b * fpb), z = (int64_t)(first + (b + 1) * fpb);
            if (a < 0) a = 0;
            if (z > t->frames) z = t->frames;
            double acc = 0;
            for (int64_t i = a; i < z; i += 2) {
                double v = d[2 * i] * (1.0 / 32768.0);
                acc += v * v;
            }
            e[(size_t)b * BE_STEMS + s] = (float)std::sqrt(acc / std::max<int64_t>(1, (z - a) / 2));
        }
    }
    return e;
}

}

bool be_fit_grid(const double *beatTimes, int n, double &period, double &first, float &confidence) { return fitGrid(beatTimes, n, period, first, confidence); }

bool be_own_grid(const be_track *t, double &period, double &first) {
    int lead = be_lead_stem(t);
    std::vector<float> rhythm = mono(t, lead >= 0 ? (1u << lead) : 0xFu);
    double fps = 0;
    std::vector<float> osf = onsetStrength(rhythm, 256, fps);
    if (osf.size() < 400) return false;
    std::vector<double> beats = onsetBeats(osf, fps, coarseTempo(osf, fps));
    float conf = 0;
    if (!fitGrid(beats.data(), (int)beats.size(), period, first, conf)) return false;
    first = refinePhase(rhythm, first, period, !(t->stems == BE_STEMS && lead == kDrums));
    return true;
}

int be_lead_stem(const be_track *t) {
    if (t->stems != BE_STEMS) return 0;
    double drums = 0, all = 0;
    for (int64_t i = 0; i < t->frames; i += 8) {
        double sum = 0;
        for (int s = 0; s < BE_STEMS; ++s) {
            double v = (double)t->pcm[s][2 * i] + t->pcm[s][2 * i + 1];
            if (s == kDrums) drums += v * v;
            sum += v;
        }
        all += sum * sum;
    }
    return drums >= 0.01 * all ? kDrums : -1;
}

void be_note_key(be_track *t) {
    std::vector<float> tonal = mono(t, t->stems == BE_STEMS ? ((1u << kVocals) | (1u << kBass) | (1u << kOther)) : 1u);
    Chroma ch = chromaOf(tonal);
    t->keyHint = detectKey(ch, t->keyHintStrength);
}

std::vector<int16_t> be_mixdown(const be_track *t) {
    std::vector<int16_t> out((size_t)t->frames * 2);
    for (size_t i = 0; i < out.size(); ++i) {
        int v = 0;
        for (int s = 0; s < t->stems; ++s) v += t->pcm[s][i];
        out[i] = (int16_t)std::max(-32768, std::min(32767, v / 2));
    }
    return out;
}

extern "C" {

be_track *be_track_create(int32_t stems, int64_t frames) {
    if (stems < 1 || stems > BE_STEMS || frames < 0) return nullptr;
    be_track *t = new be_track();
    t->stems = stems;
    t->frames = frames;
    for (int s = 0; s < stems; ++s) t->pcm[s].assign((size_t)frames * 2, 0);
    return t;
}

int16_t *be_track_stem(be_track *t, int32_t stem) { return (t && stem >= 0 && stem < t->stems) ? t->pcm[stem].data() : nullptr; }
int64_t be_track_frames(be_track *t) { return t ? t->frames : 0; }

void be_track_set_grid(be_track *t, double bpm, double firstBeatFrame) {
    if (!t || bpm < 30.0) return;
    t->bpm = bpm;
    t->firstBeat = firstBeatFrame;
}

void be_track_set_gain(be_track *t, float gain) {
    if (t) t->gain = gain;
}

void be_track_set_tempo_hint(be_track *t, double bpm) {
    if (t) t->tempoHint = bpm;
}

void be_track_release(be_track *t) {
    if (t && t->refs.fetch_sub(1) == 1) delete t;
}

static double localPhase(const be_track *t, double firstBeatFrame, double framesPerBeat, double fromBeat, int beats) {
    int lead = be_lead_stem(t);
    unsigned mask = lead >= 0 ? (1u << lead) : 0xFu;
    int64_t i0 = (int64_t)(firstBeatFrame + (fromBeat - 1) * framesPerBeat), i1 = (int64_t)(firstBeatFrame + (fromBeat + beats + 1) * framesPerBeat);
    if (i0 < 0) i0 = 0;
    if (i1 > t->frames) i1 = t->frames;
    if (i1 - i0 < (int64_t)(kRate * 3)) return 1.0;
    std::vector<float> x((size_t)(i1 - i0), 0.0f);
    for (int s = 0; s < t->stems; ++s) {
        if (!(mask & (1u << s))) continue;
        const int16_t *d = t->pcm[s].data();
        for (int64_t i = i0; i < i1; ++i) x[(size_t)(i - i0)] += (d[2 * i] + d[2 * i + 1]) * (0.5f / 32768.0f);
    }
    double T = framesPerBeat / kRate, t0 = (firstBeatFrame + fromBeat * framesPerBeat - (double)i0) / kRate;
    while (t0 < 0.1) t0 += T;
    return refinePhase(x, t0, T, !(t->stems == BE_STEMS && lead == kDrums)) - t0;
}

double be_local_phase(const be_track *t, double firstBeatFrame, double framesPerBeat, double fromBeat, int32_t beats) {
    if (!t || beats < 16 || framesPerBeat < 1000) return 0.0;
    int half = beats / 2;
    double early = localPhase(t, firstBeatFrame, framesPerBeat, fromBeat, half), late = localPhase(t, firstBeatFrame, framesPerBeat, fromBeat + half, half);
    if (std::fabs(early - late) > 0.004 || std::fabs(early + late) > 0.03) return 0.0;
    return 0.5 * (early + late);
}

int32_t be_analyze(const be_track *t, const double *beatTimes, int32_t nBeats, const double *downbeatTimes, int32_t nDownbeats, be_analysis *out) {
    if (!t || !out || t->frames < (int64_t)(kRate * 8)) return 0;
    std::memset(out, 0, sizeof(*out));
    bool stems = t->stems == BE_STEMS;
    int lead = be_lead_stem(t);
    std::vector<float> rhythm = mono(t, lead >= 0 ? (1u << lead) : 0xFu);

    double T = 0, t0 = 0, roundT = 0, roundT0 = 0;
    float conf = 0;
    bool ok = nBeats >= 12 && fitGrid(beatTimes, nBeats, T, t0, conf, &roundT, &roundT0) && conf >= 0.7f;
    if (!ok) {
        double fps = 0;
        std::vector<float> osf = onsetStrength(rhythm, 256, fps);
        if (osf.size() < 400) return 0;
        double bpm0 = coarseTempo(osf, fps);
        std::vector<double> ob = onsetBeats(osf, fps, bpm0);
        roundT = 0;
        if (!fitGrid(ob.data(), (int)ob.size(), T, t0, conf, &roundT, &roundT0)) {
            T = 60.0 / bpm0;
            t0 = ob.empty() ? 0.0 : ob[0];
            conf = 0.2f;
            roundT = 0;
        }
        nDownbeats = 0;
    }
    std::vector<int16_t> mix;
    auto leadPcm = [&]() -> const int16_t * {
        if (lead >= 0) return t->pcm[lead].data();
        if (mix.empty()) mix = be_mixdown(t);
        return mix.data();
    };
    if (roundT > 0) {
        const int16_t *pcm = leadPcm();
        float whole = be_kick_tightness(pcm, t->frames, roundT, roundT0, lead < 0), fitted = be_kick_tightness(pcm, t->frames, T, t0, lead < 0);
        bool heard = whole > 0 || fitted > 0, close = std::fabs(60.0 / roundT - 60.0 / T) < 0.01;
        if (heard ? whole >= fitted - 0.01f : close) {
            T = roundT;
            t0 = roundT0;
        }
    }
    double octave = t->tempoHint > 0 ? 60.0 / T / t->tempoHint : 1.0;
    if (t->tempoHint > 0 ? octave > 1.7 && octave < 2.3 : 60.0 / T > 176.0) {
        if (hitWeight(rhythm, t0 + T, 2 * T) > hitWeight(rhythm, t0, 2 * T)) t0 += T;
        T *= 2;
    } else if (octave > 0.43 && octave < 0.59) {
        T *= 0.5;
    }
    t0 = refinePhase(rhythm, t0, T, !(stems && lead == kDrums));
    if (!ok) conf = std::min(conf, 0.3f + be_kick_tightness(leadPcm(), t->frames, T, t0, lead < 0));
    mix.clear();
    mix.shrink_to_fit();
    double shift = std::floor(t0 / T);
    t0 -= shift * T;
    rhythm.clear();
    rhythm.shrink_to_fit();

    double fpb = T * kRate, first = t0 * kRate;
    int beats = 0;
    std::vector<float> e = beatEnergy(t, fpb, first, beats);
    if (beats < 16) return 0;

    std::vector<float> tonal = mono(t, stems ? ((1u << kVocals) | (1u << kBass) | (1u << kOther)) : 1u);
    Chroma ch = chromaOf(tonal);
    tonal.clear();
    tonal.shrink_to_fit();
    out->key = detectKey(ch, out->keyStrength);
    if (t->keyHint >= 0) {
        out->key = t->keyHint;
        out->keyStrength = t->keyHintStrength;
    }

    int barPhase = 0;
    if (nDownbeats >= 4) {
        int votes[4] = {0, 0, 0, 0};
        for (int i = 0; i < nDownbeats; ++i) {
            long k = std::lround((downbeatTimes[i] - t0) / T);
            votes[((k % 4) + 4) % 4]++;
        }
        for (int i = 1; i < 4; ++i) {
            if (votes[i] > votes[barPhase]) barPhase = i;
        }
    } else {
        std::vector<float> bc((size_t)beats * 12, 0.0f);
        for (size_t m = 0; m < ch.count; ++m) {
            double time = (m * 2048.0 + 2048.0) * 4.0 / kRate;
            long b = (long)std::floor((time - t0) / T);
            if (b < 0 || b >= beats) continue;
            for (int i = 0; i < 12; ++i) bc[(size_t)b * 12 + i] += ch.frames[m * 12 + i];
        }
        double nov[4] = {0, 0, 0, 0};
        for (int b = 1; b < beats; ++b) {
            double na = 0, nb = 0, dot = 0;
            for (int i = 0; i < 12; ++i) {
                double x = bc[(size_t)(b - 1) * 12 + i], y = bc[(size_t)b * 12 + i];
                na += x * x;
                nb += y * y;
                dot += x * y;
            }
            if (na > 0 && nb > 0) nov[b % 4] += 1.0 - dot / std::sqrt(na * nb);
        }
        for (int i = 1; i < 4; ++i) {
            if (nov[i] > nov[barPhase]) barPhase = i;
        }
    }

    int bars = (beats - barPhase) / 4;
    std::vector<float> bf((size_t)std::max(0, bars) * BE_STEMS, 0.0f);
    for (int b = 0; b < bars; ++b) {
        for (int s = 0; s < BE_STEMS; ++s) {
            float acc = 0;
            for (int q = 0; q < 4; ++q) acc += e[(size_t)(barPhase + b * 4 + q) * BE_STEMS + s];
            bf[(size_t)b * BE_STEMS + s] = std::log10(1e-4f + acc * 0.25f);
        }
    }
    double pn[8] = {0};
    for (int b = 1; b < bars; ++b) {
        double d = 0;
        for (int s = 0; s < BE_STEMS; ++s) d += std::fabs(bf[(size_t)b * BE_STEMS + s] - bf[(size_t)(b - 1) * BE_STEMS + s]);
        pn[b % 8] += d;
    }
    int phrase = 0;
    for (int i = 1; i < 8; ++i) {
        if (pn[i] > pn[phrase]) phrase = i;
    }

    std::vector<float> loud;
    for (int b = 0; b < beats; ++b) {
        double acc = 0;
        for (int s = 0; s < t->stems; ++s) acc += (double)e[(size_t)b * BE_STEMS + s] * e[(size_t)b * BE_STEMS + s];
        loud.push_back((float)std::sqrt(acc));
    }
    std::sort(loud.begin(), loud.end());
    double sum = 0;
    size_t from = loud.size() / 2;
    for (size_t i = from; i < loud.size(); ++i) sum += loud[i];
    double rms = sum / std::max<size_t>(1, loud.size() - from);
    float gain = rms > 1e-4 ? (float)(0.17 / rms) : 1.0f;
    out->gain = std::min(2.5f, std::max(0.25f, gain));

    out->bpm = 60.0 / T;
    out->firstBeatFrame = first;
    out->barPhase = barPhase;
    out->phrasePhase = phrase;
    out->gridConfidence = conf;
    out->beatCount = beats;
    return 1;
}

int32_t be_beat_energy(const be_track *t, double bpm, double firstBeatFrame, float *out, int32_t maxBeats) {
    if (!t || !out || bpm < 30.0) return 0;
    int beats = 0;
    std::vector<float> e = beatEnergy(t, kRate * 60.0 / bpm, firstBeatFrame, beats);
    if (beats > maxBeats) beats = maxBeats;
    std::memcpy(out, e.data(), sizeof(float) * (size_t)beats * BE_STEMS);
    return beats;
}

int32_t be_waveform(const be_track *t, double pointsPerSecond, uint8_t *out, int32_t maxPoints) {
    if (!t || !out || pointsPerSecond <= 0) return 0;
    double step = kRate / pointsPerSecond;
    int points = (int)std::floor((double)t->frames / step);
    if (points > maxPoints) points = maxPoints;
    for (int s = 0; s < BE_STEMS; ++s) {
        if (s >= t->stems) {
            for (int p = 0; p < points; ++p) out[(size_t)p * BE_STEMS + s] = 0;
            continue;
        }
        const int16_t *d = t->pcm[s].data();
        for (int p = 0; p < points; ++p) {
            int64_t a = (int64_t)(p * step), z = (int64_t)((p + 1) * step);
            double acc = 0;
            int pk = 0;
            for (int64_t i = a; i < z; ++i) {
                int v = d[2 * i] < 0 ? -d[2 * i] : d[2 * i];
                if (v > pk) pk = v;
                acc += (double)d[2 * i] * d[2 * i];
            }
            double rms = std::sqrt(acc / std::max<int64_t>(1, z - a)) / 32768.0, peak = pk / 32768.0;
            double v = std::sqrt(std::min(1.0, 0.6 * rms * 2.4 + 0.4 * peak));
            out[(size_t)p * BE_STEMS + s] = (uint8_t)std::lround(std::min(1.0, v) * 255.0);
        }
    }
    return points;
}

}
