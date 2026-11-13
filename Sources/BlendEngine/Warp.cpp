// Blend engine: straightens a wandering tempo (live drummers) by gently resampling every stem onto a constant beat grid.
#include "Track.h"
#include "blend_engine.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>
#include <vector>

namespace {

constexpr double kRate = 44100.0;
constexpr int kTaps = 32, kHalf = kTaps / 2, kPhases = 4096;
constexpr int kReach = 8, kStep = 4;
constexpr double kRateLimit = 0.05, kMinDrift = 0.025;
constexpr float kBroken = 0.88f, kProof = 0.85f, kTighter = 0.05f;

struct Map {
    std::vector<double> src, dst;

    double forward(double t) const {
        if (t <= src.front()) return t + dst.front() - src.front();
        if (t >= src.back()) return t + dst.back() - src.back();
        size_t j = (size_t)(std::upper_bound(src.begin(), src.end(), t) - src.begin()) - 1;
        return dst[j] + (t - src[j]) / (src[j + 1] - src[j]) * (dst[j + 1] - dst[j]);
    }
};

struct Sinc {
    std::vector<float> table;

    static double bessel(double x) {
        double sum = 1, term = 1;
        for (int k = 1; k < 32; ++k) {
            term *= (x / (2.0 * k)) * (x / (2.0 * k));
            sum += term;
        }
        return sum;
    }

    Sinc() : table((size_t)(kPhases + 1) * kTaps) {
        const double beta = 7.5, norm = bessel(beta);
        for (int p = 0; p <= kPhases; ++p) {
            double frac = (double)p / kPhases, sum = 0;
            float *row = &table[(size_t)p * kTaps];
            for (int j = 0; j < kTaps; ++j) {
                double x = (j - (kHalf - 1)) - frac, u = x / kHalf;
                double w = std::fabs(u) < 1.0 ? bessel(beta * std::sqrt(1.0 - u * u)) / norm : 0.0;
                double s = std::fabs(x) < 1e-9 ? 1.0 : std::sin(M_PI * x) / (M_PI * x);
                row[j] = (float)(s * w);
                sum += row[j];
            }
            for (int j = 0; j < kTaps; ++j) row[j] = (float)(row[j] / sum);
        }
    }

    const float *row(int p) const { return &table[(size_t)p * kTaps]; }
};

void walk(const double *bt, int n, int from, int dir, double T, std::vector<double> &k, std::vector<double> &t) {
    double lastK = 0, lastT = bt[from];
    for (int i = from + dir; i >= 0 && i < n; i += dir) {
        double gap = std::fabs(bt[i] - lastT), steps = std::round(gap / T);
        if (steps < 1) continue;
        double tol = std::min(0.45, 0.2 + 0.012 * steps) * T;
        if (std::fabs(gap - steps * T) > tol) {
            if (gap < 12.0) continue;
        } else if (steps <= 2) {
            T += 0.25 * (gap / steps - T);
        }
        lastK += dir * steps;
        lastT = bt[i];
        k.push_back(lastK);
        t.push_back(lastT);
    }
}

bool plan(const double *bt, int n, Map &map, be_warp &info) {
    if (n < 64) return false;
    std::vector<double> d;
    for (int i = 1; i < n; ++i) d.push_back(bt[i] - bt[i - 1]);
    std::nth_element(d.begin(), d.begin() + d.size() / 2, d.end());
    double T0 = d[d.size() / 2];
    if (T0 < 0.2 || T0 > 1.2) return false;

    int start = -1, run = 0;
    for (int i = 1; i < n && start < 0; ++i) {
        run = std::fabs((bt[i] - bt[i - 1]) - T0) < 0.09 * T0 ? run + 1 : 0;
        if (run >= 8) start = i - 8;
    }
    if (start < 0) return false;

    std::vector<double> kb, tb, k, t;
    walk(bt, n, start, -1, T0, kb, tb);
    for (size_t i = kb.size(); i-- > 0;) {
        k.push_back(kb[i]);
        t.push_back(tb[i]);
    }
    k.push_back(0);
    t.push_back(bt[start]);
    walk(bt, n, start, 1, T0, k, t);
    if ((int)k.size() < n * 7 / 10) return false;

    std::vector<double> K, tau;
    size_t lo = 0, hi = 0;
    for (double c = k.front(); c <= k.back(); c += kStep) {
        while (lo < k.size() && k[lo] < c - kReach) ++lo;
        while (hi < k.size() && k[hi] <= c + kReach) ++hi;
        double sw = 0, sx = 0, sy = 0, sxx = 0, sxy = 0;
        int count = 0;
        for (size_t i = lo; i < hi; ++i) {
            double x = k[i] - c, u = std::fabs(x) / (kReach + 1), w = 1 - u * u * u;
            w = w * w * w;
            sw += w;
            sx += w * x;
            sy += w * t[i];
            sxx += w * x * x;
            sxy += w * x * t[i];
            ++count;
        }
        double den = sw * sxx - sx * sx;
        if (count < 5 || std::fabs(den) < 1e-9) continue;
        K.push_back(c);
        tau.push_back((sy * sxx - sx * sxy) / den);
    }
    if (K.size() < 8) return false;

    double a = (tau.back() - tau.front()) / (K.back() - K.front());
    map.src = tau;
    map.dst.clear();
    for (size_t j = 0; j < K.size(); ++j) map.dst.push_back(tau.front() + (K[j] - K.front()) * a);
    map.dst.back() = tau.back();

    info.anchors = (int32_t)K.size();
    info.drift = 0;
    info.rateLow = info.rateHigh = 1;
    for (size_t j = 0; j < K.size(); ++j) {
        info.drift = std::max(info.drift, std::fabs(map.src[j] - map.dst[j]));
        if (j + 1 == K.size()) break;
        double span = map.src[j + 1] - map.src[j];
        if (span <= 0) return false;
        double rate = span / (map.dst[j + 1] - map.dst[j]);
        info.rateLow = std::min(info.rateLow, rate);
        info.rateHigh = std::max(info.rateHigh, rate);
    }
    return info.rateLow > 1 - kRateLimit && info.rateHigh < 1 + kRateLimit;
}

inline int16_t pack(float v) {
    long r = std::lrintf(v);
    return (int16_t)(r > 32767 ? 32767 : r < -32768 ? -32768 : r);
}

void resample(const int16_t *in, int16_t *out, int64_t frames, const Map &map, const Sinc &sinc) {
    auto clampFrame = [frames](double f) { return (int64_t)std::min<double>((double)frames, std::max(0.0, std::ceil(f))); };
    int64_t head = clampFrame(map.dst.front() * kRate), tail = clampFrame(map.dst.back() * kRate);
    std::memcpy(out, in, (size_t)head * 2 * sizeof(int16_t));
    if (tail < frames) std::memcpy(out + tail * 2, in + tail * 2, (size_t)(frames - tail) * 2 * sizeof(int16_t));
    for (size_t j = 0; j + 1 < map.dst.size(); ++j) {
        double d0 = map.dst[j] * kRate, s0 = map.src[j] * kRate;
        double slope = (map.src[j + 1] - map.src[j]) / (map.dst[j + 1] - map.dst[j]);
        int64_t n0 = clampFrame(d0), n1 = clampFrame(map.dst[j + 1] * kRate);
        for (int64_t n = n0; n < n1; ++n) {
            double pos = s0 + (n - d0) * slope;
            int64_t i = (int64_t)std::floor(pos), b = i - (kHalf - 1);
            const float *w = sinc.row((int)((pos - i) * kPhases + 0.5));
            float l0 = 0, l1 = 0, r0 = 0, r1 = 0;
            if (b >= 0 && b + kTaps <= frames) {
                const int16_t *x = in + 2 * b;
                for (int q = 0; q < kTaps; q += 2) {
                    l0 += w[q] * x[2 * q];
                    r0 += w[q] * x[2 * q + 1];
                    l1 += w[q + 1] * x[2 * q + 2];
                    r1 += w[q + 1] * x[2 * q + 3];
                }
            } else {
                for (int q = 0; q < kTaps; ++q) {
                    int64_t f = b + q;
                    if (f < 0 || f >= frames) continue;
                    l0 += w[q] * in[2 * f];
                    r0 += w[q] * in[2 * f + 1];
                }
            }
            out[2 * n] = pack(l0 + l1);
            out[2 * n + 1] = pack(r0 + r1);
        }
    }
}

float tightness(const int16_t *pcm, int64_t frames, double T, double t0) {
    const int hop = 64, lag = 6;
    size_t n = (size_t)(frames / hop);
    if (n < 64 || T <= 0) return 0;
    std::vector<float> env(n);
    const float k = 1.0f - std::exp(-2.0f * (float)M_PI * 130.0f / (float)kRate);
    float a = 0, b = 0;
    for (size_t m = 0; m < n; ++m) {
        float acc = 0;
        const int16_t *x = pcm + m * hop * 2;
        for (int i = 0; i < hop; ++i) {
            a += k * ((float)x[2 * i] + (float)x[2 * i + 1] - a);
            b += k * (a - b);
            acc += std::fabs(b);
        }
        env[m] = acc;
    }
    double per = T * kRate / hop;
    long reach = (long)(0.22 * per);
    std::vector<float> peaks, offs;
    for (double c = t0 * kRate / hop; c + reach < (double)n; c += per) {
        long mid = std::lround(c);
        if (mid - reach < lag) continue;
        long best = mid;
        float top = 0;
        for (long m = mid - reach; m <= mid + reach; ++m) {
            float rise = env[(size_t)m] - env[(size_t)(m - lag)];
            if (rise > top) {
                top = rise;
                best = m;
            }
        }
        peaks.push_back(top);
        offs.push_back((float)(best - c));
    }
    if (peaks.size() < 48) return 0;
    std::vector<float> sorted(peaks);
    std::nth_element(sorted.begin(), sorted.begin() + sorted.size() * 9 / 10, sorted.end());
    float floor = sorted[sorted.size() * 9 / 10] * 0.25f;
    std::vector<float> strong;
    for (size_t i = 0; i < peaks.size(); ++i) {
        if (peaks[i] >= floor) strong.push_back(offs[i]);
    }
    if (strong.size() < 32) return 0;
    std::vector<float> order(strong);
    std::nth_element(order.begin(), order.begin() + order.size() / 2, order.end());
    float mid = order[order.size() / 2], window = (float)(0.015 * kRate / hop);
    int near = 0;
    for (float o : strong) {
        if (std::fabs(o - mid) <= window) ++near;
    }
    return (float)near / strong.size();
}

}

float be_kick_tightness(const int16_t *pcm, int64_t frames, double period, double first) { return tightness(pcm, frames, period, first); }

extern "C" {

int32_t be_track_straighten(be_track *t, double *beatTimes, int32_t nBeats, double *downbeatTimes, int32_t nDownbeats, int32_t decide, be_warp *info) {
    be_warp w;
    std::memset(&w, 0, sizeof(w));
    w.rateLow = w.rateHigh = 1;
    auto done = [&](int32_t applied) {
        w.applied = applied;
        if (info) *info = w;
        return applied;
    };
    if (!t || !beatTimes || nBeats < 64) return done(0);

    double T0 = 0, p0 = 0, T1 = 0, p1 = 0;
    bool fitted = be_fit_grid(beatTimes, nBeats, T0, p0, w.before);
    if (!fitted) w.before = 0;
    w.after = w.before;

    Map map;
    if (!plan(beatTimes, nBeats, map, w)) return done(0);
    std::vector<double> moved(beatTimes, beatTimes + nBeats);
    for (double &b : moved) b = map.forward(b);
    if (!be_fit_grid(moved.data(), nBeats, T1, p1, w.after)) return done(0);

    static const Sinc sinc;
    int lead = t->stems == BE_STEMS ? 1 : 0;
    std::vector<int16_t> fresh[BE_STEMS];
    if (decide) {
        if (w.drift < kMinDrift || w.after < w.before) return done(0);
        fresh[lead].resize(t->pcm[lead].size());
        resample(t->pcm[lead].data(), fresh[lead].data(), t->frames, map, sinc);
        w.tightBefore = fitted ? tightness(t->pcm[lead].data(), t->frames, T0, p0) : 0;
        w.tightAfter = tightness(fresh[lead].data(), t->frames, T1, p1);
        bool tighter = w.tightAfter >= w.tightBefore + kTighter;
        bool repaired = w.before < kBroken && w.after >= std::max(w.before + 0.05f, kProof) && w.tightAfter >= w.tightBefore - 0.02f;
        if (!tighter && !repaired) return done(0);
    }

    std::vector<std::thread> jobs;
    for (int s = 0; s < t->stems; ++s) {
        if (!fresh[s].empty()) continue;
        jobs.emplace_back([t, s, &map, &fresh] {
            fresh[s].resize(t->pcm[s].size());
            resample(t->pcm[s].data(), fresh[s].data(), t->frames, map, sinc);
        });
    }
    for (std::thread &job : jobs) job.join();
    for (int s = 0; s < t->stems; ++s) t->pcm[s].swap(fresh[s]);

    std::copy(moved.begin(), moved.end(), beatTimes);
    for (int i = 0; downbeatTimes && i < nDownbeats; ++i) downbeatTimes[i] = map.forward(downbeatTimes[i]);
    return done(1);
}

}
