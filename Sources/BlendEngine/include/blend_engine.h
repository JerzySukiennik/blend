// Blend engine C API: two stem decks slaved to a master beat clock, beat-scheduled automation, track analysis.
#ifndef BLEND_ENGINE_H
#define BLEND_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BE_STEMS 4
#define BE_DECKS 2

enum {
    BE_P_VOLUME = 0,
    BE_P_STEM0 = 1,
    BE_P_STEM1 = 2,
    BE_P_STEM2 = 3,
    BE_P_STEM3 = 4,
    BE_P_FILTER = 5,
    BE_P_ECHO = 6,
    BE_P_USER0 = 7,
    BE_P_USER1 = 8,
    BE_P_USER2 = 9,
    BE_P_USER3 = 10,
    BE_P_COUNT = 11,
    BE_P_TEMPO = 100
};

enum {
    BE_EV_START = 1,
    BE_EV_STOP = 2,
    BE_EV_SEEK = 3,
    BE_EV_RAMP = 4,
    BE_EV_LOOP = 5,
    BE_EV_UNLOOP = 6,
    BE_EV_BRAKE = 7,
    BE_EV_ROLL = 8,
    BE_EV_UNROLL = 9,
    BE_EV_PITCH = 10
};

enum { BE_CURVE_LINEAR = 0, BE_CURVE_SMOOTH = 1, BE_CURVE_EASE_IN = 2, BE_CURVE_EASE_OUT = 3 };

typedef struct be_engine be_engine;
typedef struct be_track be_track;

typedef struct {
    int32_t type;
    int32_t deck;
    int32_t param;
    int32_t tag;
    int32_t curve;
    double beat;
    double endBeat;
    double value;
    double from;
} be_event;

typedef struct {
    int32_t loaded;
    int32_t playing;
    int32_t mode;
    int32_t looping;
    int32_t rolling;
    int32_t stretching;
    int32_t ended;
    double frame;
    double beat;
    double offset;
    double rate;
    double pitch;
    float params[BE_P_COUNT];
    float level[BE_STEMS];
} be_deck_state;

typedef struct {
    double masterBeat;
    double masterBpm;
    uint64_t frames;
    uint32_t epoch;
    int32_t pendingEvents;
    float peak;
    float load;
    be_deck_state deck[BE_DECKS];
} be_state;

be_engine *be_create(double sampleRate);
void be_destroy(be_engine *e);
void be_render(be_engine *e, float *left, float *right, int32_t frames);
void be_collect(be_engine *e);
void be_get_state(be_engine *e, be_state *out);

be_track *be_track_create(int32_t stems, int64_t frames);
int16_t *be_track_stem(be_track *t, int32_t stem);
int64_t be_track_frames(be_track *t);
void be_track_set_grid(be_track *t, double bpm, double firstBeatFrame);
void be_track_set_gain(be_track *t, float gain);
void be_track_release(be_track *t);

void be_deck_load(be_engine *e, int32_t deck, be_track *t);
void be_schedule(be_engine *e, const be_event *ev);
void be_cancel(be_engine *e, int32_t tag);
void be_set_param(be_engine *e, int32_t deck, int32_t param, float value);
void be_set_tempo(be_engine *e, double bpm);
void be_play(be_engine *e, int32_t deck, double trackBeat);
void be_stop(be_engine *e, int32_t deck);
void be_cue(be_engine *e, int32_t deck, double trackBeat);
void be_scratch_begin(be_engine *e, int32_t deck);
void be_scratch_move(be_engine *e, int32_t deck, double deltaFrames);
void be_scratch_end(be_engine *e, int32_t deck);
void be_sync_phase(be_engine *e, int32_t deck);
void be_reset(be_engine *e);

typedef struct {
    double bpm;
    double firstBeatFrame;
    int32_t barPhase;
    int32_t phrasePhase;
    int32_t key;
    float keyStrength;
    float gain;
    float gridConfidence;
    int32_t beatCount;
} be_analysis;

int32_t be_analyze(const be_track *t, const double *beatTimes, int32_t nBeats, const double *downbeatTimes, int32_t nDownbeats, be_analysis *out);
int32_t be_beat_energy(const be_track *t, double bpm, double firstBeatFrame, float *out, int32_t maxBeats);
int32_t be_waveform(const be_track *t, double pointsPerSecond, uint8_t *out, int32_t maxPoints);

typedef struct {
    float before;
    float after;
    float tightBefore;
    float tightAfter;
    double drift;
    double rateLow;
    double rateHigh;
    int32_t anchors;
    int32_t applied;
    int32_t half;
    int32_t bent;
    int32_t lead;
} be_warp;

int32_t be_track_straighten(be_track *t, double *beatTimes, int32_t nBeats, double *downbeatTimes, int32_t nDownbeats, int32_t decide, be_warp *info);

#ifdef __cplusplus
}
#endif

#endif
