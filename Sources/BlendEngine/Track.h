// Blend engine: decoded track storage shared by the player and the analyzer.
#ifndef BLEND_TRACK_H
#define BLEND_TRACK_H

#include "blend_engine.h"
#include <atomic>
#include <vector>

struct be_track {
    std::atomic<int> refs{1};
    int stems = 0;
    int64_t frames = 0;
    std::vector<int16_t> pcm[BE_STEMS];
    double bpm = 120.0;
    double firstBeat = 0.0;
    float gain = 1.0f;
};

#endif
