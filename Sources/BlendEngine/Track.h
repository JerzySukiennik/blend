// Blend engine: decoded track storage shared by the player and the analyzer.
#ifndef BLEND_TRACK_H
#define BLEND_TRACK_H

#include "blend_engine.h"
#include <atomic>
#include <vector>

constexpr int kBendShift = 10;

struct be_track {
    std::atomic<int> refs{1};
    int stems = 0;
    int64_t frames = 0;
    std::vector<int16_t> pcm[BE_STEMS];
    double bpm = 120.0;
    double firstBeat = 0.0;
    float gain = 1.0f;
    std::vector<float> bend;
    int keyHint = -1;
    float keyHintStrength = 0.0f;
    double tempoHint = 0.0;

    float bendAt(double frame) const {
        if (bend.empty() || frame < 0) return 0.0f;
        double x = frame / (double)(1 << kBendShift) - 0.5;
        if (x <= 0) return bend.front();
        size_t i = (size_t)x;
        if (i + 1 >= bend.size()) return bend.back();
        float f = (float)(x - (double)i);
        return bend[i] + (bend[i + 1] - bend[i]) * f;
    }
};

bool be_fit_grid(const double *beatTimes, int n, double &period, double &first, float &confidence);
bool be_own_grid(const be_track *t, double &period, double &first);
float be_kick_tightness(const int16_t *pcm, int64_t frames, double period, double first, bool broad);
int be_lead_stem(const be_track *t);
std::vector<int16_t> be_mixdown(const be_track *t);
void be_note_key(be_track *t);

#endif
