#ifndef PPFreeverbDSP_h
#define PPFreeverbDSP_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
	double roomSize;
	double damping;
	double predelayMilliseconds;
	double lowpassPercent;
	double highpassPercent;
	double wetDecibels;
	double dryDecibels;
} PPFreeverbParameters;

/// Processes normalized, interleaved mono or stereo PCM in place.
bool PPFreeverbProcessInterleaved(float *samples, size_t frames, unsigned int channels,
	double sampleRate, PPFreeverbParameters parameters);

/// Persistent, allocation-free processing state for the playback mixer.
typedef struct PPFreeverbRealtime PPFreeverbRealtime;

PPFreeverbRealtime *PPFreeverbRealtimeCreate(double sampleRate, size_t maximumFrames,
	PPFreeverbParameters parameters);
void PPFreeverbRealtimeDestroy(PPFreeverbRealtime *effect);
void PPFreeverbRealtimeReset(PPFreeverbRealtime *effect);
/// Updates a running instance without clearing its delay lines or reverb tail.
void PPFreeverbRealtimeSetParameters(PPFreeverbRealtime *effect,
	PPFreeverbParameters parameters);

/// Processes PlayerPRO's stereo 32-bit accumulator buffer in place. The buffer
/// contains `frames * 2` samples whose nominal full scale is +/-32768.
bool PPFreeverbRealtimeProcessInt32(PPFreeverbRealtime *effect, int32_t *samples,
	size_t frames);

#ifdef __cplusplus
}
#endif

#endif
