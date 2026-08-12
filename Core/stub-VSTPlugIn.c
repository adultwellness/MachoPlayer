//
//  stub-VSTPlugIn.c
//  PPMacho
//
//  Created by C.W. Betts on 2/6/14.
//
//

#include "VSTFunctions.h"
#include "MADDriver.h"
#include "../App/PPFreeverbDSP.h"

#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct PPBuiltinEffectInstance {
	uint32_t effectID;
	float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
	_Atomic(float) liveValues[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
	float appliedFreeverbValues[7];
	PPFreeverbRealtime *freeverb;
	double filterState[2];
	double compressorEnvelope;
	struct PPBuiltinEffectInstance *nextAllocation;
} PPBuiltinEffectInstance;

typedef struct PPBuiltinEffects {
	_Atomic(PPBuiltinEffectInstance *) globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS];
	atomic_bool globalEnabled;
	_Atomic(PPBuiltinEffectInstance *) trackSlots[MAXTRACK][PP_BUILTIN_TRACK_EFFECT_SLOTS];
	atomic_bool trackEnabled[MAXTRACK];
	PPBuiltinEffectInstance *allocations;
} PPBuiltinEffects;

static PPFreeverbParameters PPDefaultMixerFreeverb(void)
{
	PPFreeverbParameters parameters = {
		.roomSize = 0.84,
		.damping = 0.50,
		.predelayMilliseconds = 0.0,
		.lowpassPercent = 0.0,
		.highpassPercent = 0.0,
		.wetDecibels = -6.0,
		.dryDecibels = 0.0
	};
	return parameters;
}

static double PPClamp(double value, double minimum, double maximum)
{
	if (!isfinite(value)) return minimum;
	return value < minimum ? minimum : (value > maximum ? maximum : value);
}

static int32_t PPAccumulatorSample(double normalized)
{
	double scaled = normalized * 32768.0;
	if (scaled > INT32_MAX) return INT32_MAX;
	if (scaled < INT32_MIN) return INT32_MIN;
	return (int32_t)llround(scaled);
}

static bool PPBuiltinEffectIDIsSupported(uint32_t effectID)
{
	return effectID == PP_BUILTIN_FREEVERB_ID || effectID == PP_BUILTIN_DJ_FILTER_ID ||
		effectID == PP_BUILTIN_COMPRESSOR_ID;
}

static PPBuiltinEffectInstance *PPCreateBuiltinEffect(const MADDriverRec *driver,
	const PPBuiltinEffectSlot *settings)
{
	if (driver == NULL || settings == NULL || !PPBuiltinEffectIDIsSupported(settings->effectID)) return NULL;
	PPBuiltinEffectInstance *effect = calloc(1, sizeof(PPBuiltinEffectInstance));
	if (effect == NULL) return NULL;
	effect->effectID = settings->effectID;
	memcpy(effect->values, settings->values, sizeof(effect->values));
	for (size_t index = 0; index < PP_BUILTIN_EFFECT_PARAMETER_COUNT; index++) {
		atomic_init(&effect->liveValues[index], settings->values[index]);
	}
	for (size_t index = 0; index < 7; index++) {
		effect->appliedFreeverbValues[index] = settings->values[index];
	}
	if (effect->effectID == PP_BUILTIN_FREEVERB_ID) {
		PPFreeverbParameters parameters = {
			.roomSize = PPClamp(effect->values[0], 0.0, 1.0),
			.damping = PPClamp(effect->values[1], 0.0, 1.0),
			.predelayMilliseconds = PPClamp(effect->values[2], 0.0, 2000.0),
			.lowpassPercent = PPClamp(effect->values[3], 0.0, 100.0),
			.highpassPercent = PPClamp(effect->values[4], 0.0, 100.0),
			.wetDecibels = PPClamp(effect->values[5], -60.0, 12.0),
			.dryDecibels = PPClamp(effect->values[6], -60.0, 12.0)
		};
		effect->freeverb = PPFreeverbRealtimeCreate(driver->DriverSettings.outPutRate,
			(size_t)driver->ASCBUFFERReal, parameters);
		if (effect->freeverb == NULL) {
			free(effect);
			return NULL;
		}
	}
	return effect;
}

static bool PPBuiltinEffectMatches(const PPBuiltinEffectInstance *effect,
	const PPBuiltinEffectSlot *settings)
{
	return effect != NULL && settings != NULL && effect->effectID == settings->effectID &&
		memcmp(effect->values, settings->values, sizeof(effect->values)) == 0;
}

static void PPInstallBuiltinSlot(PPBuiltinEffects *effects,
	_Atomic(PPBuiltinEffectInstance *) *destination, const MADDriverRec *driver,
	const PPBuiltinEffectSlot *settings)
{
	if (settings == NULL || settings->effectID == 0 || !PPBuiltinEffectIDIsSupported(settings->effectID)) {
		atomic_store_explicit(destination, NULL, memory_order_release);
		return;
	}
	PPBuiltinEffectInstance *current = atomic_load_explicit(destination, memory_order_acquire);
	if (PPBuiltinEffectMatches(current, settings)) return;
	PPBuiltinEffectInstance *created = PPCreateBuiltinEffect(driver, settings);
	if (created == NULL) {
		atomic_store_explicit(destination, NULL, memory_order_release);
		return;
	}
	created->nextAllocation = effects->allocations;
	effects->allocations = created;
	atomic_store_explicit(destination, created, memory_order_release);
}

static void PPProcessDJFilter(PPBuiltinEffectInstance *effect, int32_t *samples,
	size_t frames, double sampleRate)
{
	double position = PPClamp(atomic_load_explicit(&effect->liveValues[0],
		memory_order_relaxed), -1.0, 1.0);
	if (fabs(position) < 0.0001 || sampleRate <= 0.0) return;
	double cutoff = position < 0.0
		? 80.0 * pow(20000.0 / 80.0, 1.0 + position)
		: 20.0 * pow(10000.0 / 20.0, position);
	cutoff = PPClamp(cutoff, 20.0, sampleRate * 0.45);
	double coefficient = 1.0 - exp(-2.0 * M_PI * cutoff / sampleRate);
	for (size_t frame = 0; frame < frames; frame++) {
		for (size_t channel = 0; channel < 2; channel++) {
			double input = (double)samples[frame * 2 + channel] / 32768.0;
			effect->filterState[channel] += coefficient * (input - effect->filterState[channel]);
			double output = position < 0.0 ? effect->filterState[channel] : input - effect->filterState[channel];
			samples[frame * 2 + channel] = PPAccumulatorSample(output);
		}
	}
}

static void PPProcessCompressor(PPBuiltinEffectInstance *effect, int32_t *samples,
	size_t frames, double sampleRate)
{
	if (sampleRate <= 0.0) return;
	double threshold = PPClamp(atomic_load_explicit(&effect->liveValues[0],
		memory_order_relaxed), -60.0, 0.0);
	double ratio = PPClamp(atomic_load_explicit(&effect->liveValues[1],
		memory_order_relaxed), 1.0, 20.0);
	double attack = PPClamp(atomic_load_explicit(&effect->liveValues[2],
		memory_order_relaxed), 0.1, 200.0);
	double release = PPClamp(atomic_load_explicit(&effect->liveValues[3],
		memory_order_relaxed), 1.0, 2000.0);
	double makeup = PPClamp(atomic_load_explicit(&effect->liveValues[4],
		memory_order_relaxed), 0.0, 24.0);
	double attackCoefficient = exp(-1.0 / (sampleRate * attack * 0.001));
	double releaseCoefficient = exp(-1.0 / (sampleRate * release * 0.001));
	double makeupGain = pow(10.0, makeup / 20.0);
	for (size_t frame = 0; frame < frames; frame++) {
		double left = (double)samples[frame * 2] / 32768.0;
		double right = (double)samples[frame * 2 + 1] / 32768.0;
		double detector = fmax(fabs(left), fabs(right));
		double coefficient = detector > effect->compressorEnvelope ? attackCoefficient : releaseCoefficient;
		effect->compressorEnvelope = coefficient * effect->compressorEnvelope + (1.0 - coefficient) * detector;
		double levelDB = 20.0 * log10(fmax(effect->compressorEnvelope, 1.0e-9));
		double reductionDB = levelDB > threshold ? threshold + (levelDB - threshold) / ratio - levelDB : 0.0;
		double gain = pow(10.0, reductionDB / 20.0) * makeupGain;
		samples[frame * 2] = PPAccumulatorSample(left * gain);
		samples[frame * 2 + 1] = PPAccumulatorSample(right * gain);
	}
}

static void PPProcessBuiltinEffect(PPBuiltinEffectInstance *effect, int32_t *samples,
	size_t frames, double sampleRate)
{
	if (effect == NULL) return;
	switch (effect->effectID) {
		case PP_BUILTIN_FREEVERB_ID: {
			float values[7];
			bool changed = false;
			for (size_t index = 0; index < 7; index++) {
				values[index] = atomic_load_explicit(&effect->liveValues[index],
					memory_order_relaxed);
				if (values[index] != effect->appliedFreeverbValues[index]) changed = true;
			}
			if (changed) {
				PPFreeverbParameters parameters = {
					.roomSize = PPClamp(values[0], 0.0, 1.0),
					.damping = PPClamp(values[1], 0.0, 1.0),
					.predelayMilliseconds = PPClamp(values[2], 0.0, 2000.0),
					.lowpassPercent = PPClamp(values[3], 0.0, 100.0),
					.highpassPercent = PPClamp(values[4], 0.0, 100.0),
					.wetDecibels = PPClamp(values[5], -60.0, 12.0),
					.dryDecibels = PPClamp(values[6], -60.0, 12.0)
				};
				PPFreeverbRealtimeSetParameters(effect->freeverb, parameters);
				memcpy(effect->appliedFreeverbValues, values, sizeof(values));
			}
			PPFreeverbRealtimeProcessInt32(effect->freeverb, samples, frames);
			break;
		}
		case PP_BUILTIN_DJ_FILTER_ID:
			PPProcessDJFilter(effect, samples, frames, sampleRate);
			break;
		case PP_BUILTIN_COMPRESSOR_ID:
			PPProcessCompressor(effect, samples, frames, sampleRate);
			break;
		default:
			break;
	}
}

void MADInitializeBuiltinEffects(MADDriverRec *intDriver)
{
	if (intDriver == NULL || intDriver->vstEffects != NULL) return;
	intDriver->vstEffects = calloc(1, sizeof(PPBuiltinEffects));
}

void MADDisposeBuiltinEffects(MADDriverRec *intDriver)
{
	if (intDriver == NULL || intDriver->vstEffects == NULL) return;
	PPBuiltinEffects *effects = intDriver->vstEffects;
	PPBuiltinEffectInstance *effect = effects->allocations;
	while (effect != NULL) {
		PPBuiltinEffectInstance *next = effect->nextAllocation;
		PPFreeverbRealtimeDestroy(effect->freeverb);
		free(effect);
		effect = next;
	}
	free(effects);
	intDriver->vstEffects = NULL;
}

void MADConfigureBuiltinFreeverb(MADDriverRec *intDriver, bool globalEnabled,
	const bool *trackEnabled, size_t trackCount)
{
	PPBuiltinEffectSlot globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS] = {0};
	globalSlots[0].effectID = PP_BUILTIN_FREEVERB_ID;
	PPFreeverbParameters defaults = PPDefaultMixerFreeverb();
	globalSlots[0].values[0] = (float)defaults.roomSize;
	globalSlots[0].values[1] = (float)defaults.damping;
	globalSlots[0].values[2] = (float)defaults.predelayMilliseconds;
	globalSlots[0].values[3] = (float)defaults.lowpassPercent;
	globalSlots[0].values[4] = (float)defaults.highpassPercent;
	globalSlots[0].values[5] = (float)defaults.wetDecibels;
	globalSlots[0].values[6] = (float)defaults.dryDecibels;
	PPBuiltinEffectSlot (*trackSlots)[PP_BUILTIN_TRACK_EFFECT_SLOTS] = calloc(MAXTRACK, sizeof(*trackSlots));
	if (trackSlots != NULL) {
		for (size_t track = 0; track < trackCount && track < MAXTRACK; track++) {
			if (trackEnabled != NULL && trackEnabled[track]) trackSlots[track][0] = globalSlots[0];
		}
	}
	MADConfigureBuiltinEffectChains(intDriver, globalEnabled, globalSlots,
		trackEnabled, trackSlots, trackCount);
	free(trackSlots);
}

void MADConfigureBuiltinEffectChains(MADDriverRec *intDriver, bool globalEnabled,
	const PPBuiltinEffectSlot globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS],
	const bool *trackEnabled,
	const PPBuiltinEffectSlot (*trackSlots)[PP_BUILTIN_TRACK_EFFECT_SLOTS],
	size_t trackCount)
{
	if (intDriver == NULL) return;
	if (intDriver->vstEffects == NULL) MADInitializeBuiltinEffects(intDriver);
	PPBuiltinEffects *effects = intDriver->vstEffects;
	if (effects == NULL) return;
	atomic_store_explicit(&effects->globalEnabled, false, memory_order_release);
	for (size_t slot = 0; slot < PP_BUILTIN_GLOBAL_EFFECT_SLOTS; slot++) {
		PPInstallBuiltinSlot(effects, &effects->globalSlots[slot], intDriver,
			globalSlots == NULL ? NULL : &globalSlots[slot]);
	}
	atomic_store_explicit(&effects->globalEnabled, globalEnabled, memory_order_release);
	for (size_t track = 0; track < MAXTRACK; track++) {
		atomic_store_explicit(&effects->trackEnabled[track], false, memory_order_release);
		for (size_t slot = 0; slot < PP_BUILTIN_TRACK_EFFECT_SLOTS; slot++) {
			const PPBuiltinEffectSlot *settings = trackSlots != NULL && track < trackCount
				? &trackSlots[track][slot] : NULL;
			PPInstallBuiltinSlot(effects, &effects->trackSlots[track][slot], intDriver, settings);
		}
		bool enabled = trackEnabled != NULL && track < trackCount && trackEnabled[track];
		atomic_store_explicit(&effects->trackEnabled[track], enabled, memory_order_release);
	}
}

bool MADUpdateBuiltinEffectParameters(MADDriverRec *intDriver, bool global,
	size_t track, size_t slot, uint32_t effectID,
	const float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT])
{
	if (intDriver == NULL || intDriver->vstEffects == NULL || values == NULL) return false;
	PPBuiltinEffects *effects = intDriver->vstEffects;
	PPBuiltinEffectInstance *effect = NULL;
	if (global) {
		if (slot >= PP_BUILTIN_GLOBAL_EFFECT_SLOTS) return false;
		effect = atomic_load_explicit(&effects->globalSlots[slot], memory_order_acquire);
	} else {
		if (track >= MAXTRACK || slot >= PP_BUILTIN_TRACK_EFFECT_SLOTS) return false;
		effect = atomic_load_explicit(&effects->trackSlots[track][slot], memory_order_acquire);
	}
	if (effect == NULL || effect->effectID != effectID) return false;
	memcpy(effect->values, values, sizeof(effect->values));
	for (size_t index = 0; index < PP_BUILTIN_EFFECT_PARAMETER_COUNT; index++) {
		atomic_store_explicit(&effect->liveValues[index], values[index],
			memory_order_release);
	}
	return true;
}

void DisposeVSTEffect(VSTEffect *myEffect)
{
	
}

VSTEffect* CreateVSTEffect(short effectID)
{
	return NULL;
}

short ConvertUniqueIDToIndex(uint32_t idx)
{
	return PPBuiltinEffectIDIsSupported(idx) ? 0 : -1;
}

void ApplyVSTSets(VSTEffect* myEffect, FXSets* set)
{
	
}

bool IsVSTChanEffect(MADDriverRec *intDriver, short channel)
{
	if (intDriver == NULL || intDriver->vstEffects == NULL || channel < 0 || channel >= MAXTRACK) return false;
	// Piano audition is a master-bus preview, not another voice belonging to
	// the selected tracker track. Sharing that track's nonlinear effect state
	// (especially its compressor) can duck or garble the programmed notes.
	if (channel == intDriver->previewChannel) return false;
	short track = intDriver->base.chan[channel].TrackID;
	if (track < 0 || track >= MAXTRACK) return false;
	PPBuiltinEffects *effects = intDriver->vstEffects;
	if (!atomic_load_explicit(&effects->trackEnabled[track], memory_order_acquire)) return false;
	for (size_t slot = 0; slot < PP_BUILTIN_TRACK_EFFECT_SLOTS; slot++) {
		if (atomic_load_explicit(&effects->trackSlots[track][slot], memory_order_acquire) != NULL) return true;
	}
	return false;
}

void ProcessVSTPlug(MADDriverRec *intDriver, int *data, int datasize, short channel)
{
	if (intDriver == NULL || intDriver->vstEffects == NULL || data == NULL || datasize <= 0) return;
	_Static_assert(sizeof(int) == sizeof(int32_t), "PlayerPRO's accumulator must be 32-bit");
	PPBuiltinEffects *effects = intDriver->vstEffects;
	if (channel < 0) {
		if (!atomic_load_explicit(&effects->globalEnabled, memory_order_acquire)) return;
		for (size_t slot = 0; slot < PP_BUILTIN_GLOBAL_EFFECT_SLOTS; slot++) {
			PPBuiltinEffectInstance *effect = atomic_load_explicit(&effects->globalSlots[slot], memory_order_acquire);
			PPProcessBuiltinEffect(effect, (int32_t *)data, (size_t)datasize,
				intDriver->DriverSettings.outPutRate);
		}
	} else if (channel < MAXTRACK) {
		short track = intDriver->base.chan[channel].TrackID;
		if (track < 0 || track >= MAXTRACK ||
			!atomic_load_explicit(&effects->trackEnabled[track], memory_order_acquire)) return;
		for (size_t slot = 0; slot < PP_BUILTIN_TRACK_EFFECT_SLOTS; slot++) {
			PPBuiltinEffectInstance *effect = atomic_load_explicit(&effects->trackSlots[track][slot], memory_order_acquire);
			PPProcessBuiltinEffect(effect, (int32_t *)data, (size_t)datasize,
				intDriver->DriverSettings.outPutRate);
		}
	}
}
