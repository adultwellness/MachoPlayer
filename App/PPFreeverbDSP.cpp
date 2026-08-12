#include "PPFreeverbDSP.h"

#include "../Resources/freeverb dsp/revmodel.hpp"

#include <algorithm>
#include <climits>
#include <cmath>
#include <new>
#include <vector>

namespace {

double clampValue(double value, double minimum, double maximum)
{
	return std::max(minimum, std::min(value, maximum));
}

float gainForDecibels(double decibels)
{
	if (decibels <= -60.0) return 0.0f;
	return static_cast<float>(std::pow(10.0, decibels / 20.0));
}

void filterWetSignal(std::vector<float>& samples, double sampleRate,
	double lowpassPercent, double highpassPercent)
{
	const double nyquist = std::max(sampleRate * 0.5, 1.0);
	const double lowAmount = clampValue(lowpassPercent / 100.0, 0.0, 1.0);
	const double highAmount = clampValue(highpassPercent / 100.0, 0.0, 1.0);
	float lowState = 0.0f;
	float highInput = 0.0f;
	float highState = 0.0f;

	double lowAlpha = 1.0;
	if (lowAmount > 0.0) {
		const double cutoff = 200.0 * std::pow(std::max(nyquist / 200.0, 1.0), 1.0 - lowAmount);
		lowAlpha = 1.0 - std::exp(-2.0 * M_PI * cutoff / sampleRate);
	}
	double highAlpha = 0.0;
	if (highAmount > 0.0) {
		const double cutoff = 20.0 * std::pow(std::max((nyquist * 0.95) / 20.0, 1.0), highAmount);
		const double timeConstant = 1.0 / (2.0 * M_PI * cutoff);
		const double interval = 1.0 / sampleRate;
		highAlpha = timeConstant / (timeConstant + interval);
	}

	for (float& value : samples) {
		float filtered = value;
		if (lowAmount > 0.0) {
			lowState += static_cast<float>(lowAlpha) * (filtered - lowState);
			filtered = lowState;
		}
		if (highAmount > 0.0) {
			highState = static_cast<float>(highAlpha) * (highState + filtered - highInput);
			highInput = filtered;
			filtered = highState;
		}
		value = filtered;
	}
}

} // namespace

struct PPFreeverbRealtime {
	revmodel model;
	PPFreeverbParameters parameters;
	double sampleRate;
	size_t maximumFrames;
	std::vector<float> originalLeft;
	std::vector<float> originalRight;
	std::vector<float> inputLeft;
	std::vector<float> inputRight;
	std::vector<float> wetLeft;
	std::vector<float> wetRight;
};

static void PPFreeverbConfigureModel(PPFreeverbRealtime& effect)
{
	effect.model.setroomsize(static_cast<float>(clampValue(effect.parameters.roomSize, 0.0, 1.0)));
	effect.model.setdamp(static_cast<float>(clampValue(effect.parameters.damping, 0.0, 1.0)));
	effect.model.setwidth(1.0f);
	effect.model.setwet(gainForDecibels(effect.parameters.wetDecibels) / 3.0f);
	effect.model.setdry(0.0f);
}

PPFreeverbRealtime *PPFreeverbRealtimeCreate(double sampleRate, size_t maximumFrames,
	PPFreeverbParameters parameters)
{
	if (!std::isfinite(sampleRate) || sampleRate <= 0.0 || maximumFrames == 0) return nullptr;
	try {
		PPFreeverbRealtime *effect = new PPFreeverbRealtime;
		effect->parameters = parameters;
		effect->sampleRate = sampleRate;
		effect->maximumFrames = maximumFrames;
		effect->originalLeft.resize(maximumFrames);
		effect->originalRight.resize(maximumFrames);
		effect->inputLeft.resize(maximumFrames);
		effect->inputRight.resize(maximumFrames);
		effect->wetLeft.resize(maximumFrames);
		effect->wetRight.resize(maximumFrames);
		PPFreeverbConfigureModel(*effect);
		return effect;
	} catch (const std::bad_alloc&) {
		return nullptr;
	}
}

void PPFreeverbRealtimeDestroy(PPFreeverbRealtime *effect)
{
	delete effect;
}

void PPFreeverbRealtimeReset(PPFreeverbRealtime *effect)
{
	if (effect == nullptr) return;
	effect->model.mute();
	std::fill(effect->originalLeft.begin(), effect->originalLeft.end(), 0.0f);
	std::fill(effect->originalRight.begin(), effect->originalRight.end(), 0.0f);
	std::fill(effect->inputLeft.begin(), effect->inputLeft.end(), 0.0f);
	std::fill(effect->inputRight.begin(), effect->inputRight.end(), 0.0f);
	std::fill(effect->wetLeft.begin(), effect->wetLeft.end(), 0.0f);
	std::fill(effect->wetRight.begin(), effect->wetRight.end(), 0.0f);
}

void PPFreeverbRealtimeSetParameters(PPFreeverbRealtime *effect,
	PPFreeverbParameters parameters)
{
	if (effect == nullptr) return;
	effect->parameters = parameters;
	PPFreeverbConfigureModel(*effect);
}

bool PPFreeverbRealtimeProcessInt32(PPFreeverbRealtime *effect, int32_t *samples,
	size_t frames)
{
	if (effect == nullptr || samples == nullptr || frames == 0 || frames > effect->maximumFrames) return false;
	for (size_t frame = 0; frame < frames; frame++) {
		effect->originalLeft[frame] = static_cast<float>(samples[frame * 2]) / 32768.0f;
		effect->originalRight[frame] = static_cast<float>(samples[frame * 2 + 1]) / 32768.0f;
		effect->inputLeft[frame] = effect->originalLeft[frame];
		effect->inputRight[frame] = effect->originalRight[frame];
		effect->wetLeft[frame] = 0.0f;
		effect->wetRight[frame] = 0.0f;
	}

	effect->model.processreplace(effect->inputLeft.data(), effect->inputRight.data(),
		effect->wetLeft.data(), effect->wetRight.data(), static_cast<long>(frames), 1);
	// The realtime mixer currently exposes the original Freeverb room/damping
	// preset. Keep the filter fields honored for forward-compatible saved sets.
	filterWetSignal(effect->wetLeft, effect->sampleRate,
		effect->parameters.lowpassPercent, effect->parameters.highpassPercent);
	filterWetSignal(effect->wetRight, effect->sampleRate,
		effect->parameters.lowpassPercent, effect->parameters.highpassPercent);
	const float dryGain = gainForDecibels(effect->parameters.dryDecibels);
	for (size_t frame = 0; frame < frames; frame++) {
		double left = 32768.0 * (effect->wetLeft[frame] + effect->originalLeft[frame] * dryGain);
		double right = 32768.0 * (effect->wetRight[frame] + effect->originalRight[frame] * dryGain);
		samples[frame * 2] = static_cast<int32_t>(std::llround(clampValue(left, INT32_MIN, INT32_MAX)));
		samples[frame * 2 + 1] = static_cast<int32_t>(std::llround(clampValue(right, INT32_MIN, INT32_MAX)));
	}
	return true;
}

bool PPFreeverbProcessInterleaved(float *samples, size_t frames, unsigned int channels,
	double sampleRate, PPFreeverbParameters parameters)
{
	if (samples == nullptr || frames == 0 || (channels != 1 && channels != 2) ||
		!std::isfinite(sampleRate) || sampleRate <= 0.0) return false;
	try {
		std::vector<float> originalLeft(frames);
		std::vector<float> originalRight(frames);
		std::vector<float> inputLeft(frames, 0.0f);
		std::vector<float> inputRight(frames, 0.0f);
		std::vector<float> wetLeft(frames, 0.0f);
		std::vector<float> wetRight(frames, 0.0f);
		for (size_t frame = 0; frame < frames; frame++) {
			originalLeft[frame] = samples[frame * channels];
			originalRight[frame] = channels == 2 ? samples[frame * channels + 1] : originalLeft[frame];
		}

		const size_t predelayFrames = std::min(frames,
			static_cast<size_t>(std::llround(sampleRate *
				clampValue(parameters.predelayMilliseconds, 0.0, 2000.0) / 1000.0)));
		for (size_t frame = predelayFrames; frame < frames; frame++) {
			inputLeft[frame] = originalLeft[frame - predelayFrames];
			inputRight[frame] = originalRight[frame - predelayFrames];
		}

		revmodel model;
		model.setroomsize(static_cast<float>(clampValue(parameters.roomSize, 0.0, 1.0)));
		model.setdamp(static_cast<float>(clampValue(parameters.damping, 0.0, 1.0)));
		model.setwidth(1.0f);
		model.setwet(gainForDecibels(parameters.wetDecibels) / 3.0f);
		model.setdry(0.0f);
		model.processreplace(inputLeft.data(), inputRight.data(), wetLeft.data(), wetRight.data(),
			static_cast<long>(frames), 1);

		filterWetSignal(wetLeft, sampleRate, parameters.lowpassPercent, parameters.highpassPercent);
		filterWetSignal(wetRight, sampleRate, parameters.lowpassPercent, parameters.highpassPercent);
		const float dryGain = gainForDecibels(parameters.dryDecibels);
		for (size_t frame = 0; frame < frames; frame++) {
			samples[frame * channels] = wetLeft[frame] + originalLeft[frame] * dryGain;
			if (channels == 2) samples[frame * channels + 1] = wetRight[frame] + originalRight[frame] * dryGain;
		}
	} catch (const std::bad_alloc&) {
		return false;
	}
	return true;
}
