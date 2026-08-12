#import <Cocoa/Cocoa.h>
#include <unistd.h>

#import "PPApplicationController.h"
#import "PPEqualizerController.h"
#import "PPPatternCommandCodec.h"
#import "PPPianoController.h"
#import "PPSampleEditorController.h"
#include "PlayerPROCore.h"
#include "MADDriver.h"
#include "embeddedPlugs.h"
#include "MIDI-Hardware-OSX.h"
#include "RDriverInt.h"
#include "VSTFunctions.h"

enum {
	PPEnvelopeOn = 1,
	PPEnvelopeSustain = 2,
	PPEnvelopeLoop = 4,
	PPEnvelopeFixedSpeed = 8
};

static NSInteger PPActualInstrumentCount(const MADMusic *music)
{
	NSInteger lastUsed = -1;
	if (music == NULL || music->fid == NULL) return 0;
	for (NSInteger instrument = 0; instrument < MAXINSTRU; instrument++) {
		if (music->fid[instrument].name[0] != 0 || music->fid[instrument].numSamples > 0) lastUsed = instrument;
	}
	return lastUsed + 1;
}

static BOOL PPTestBuiltinMixerDSP(MADDriverRec *driver)
{
	if (driver == NULL) return NO;
	PPBuiltinEffectSlot globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS] = {0};
	PPBuiltinEffectSlot trackSlots[MAXTRACK][PP_BUILTIN_TRACK_EFFECT_SLOTS] = {0};
	bool trackEnabled[MAXTRACK] = {false};

	// A closed DJ Filter should strongly attenuate a Nyquist-frequency signal.
	globalSlots[0].effectID = PP_BUILTIN_DJ_FILTER_ID;
	globalSlots[0].values[0] = -1.0f;
	MADConfigureBuiltinEffectChains(driver, true, globalSlots, trackEnabled, trackSlots, MAXTRACK);
	int filtered[512 * 2];
	for (NSInteger frame = 0; frame < 512; frame++) {
		filtered[frame * 2] = filtered[frame * 2 + 1] = frame & 1 ? 20000 : -20000;
	}
	ProcessVSTPlug(driver, filtered, 512, -1);
	long long filteredTail = 0;
	for (NSInteger sample = 384 * 2; sample < 512 * 2; sample++) filteredTail += llabs(filtered[sample]);
	BOOL filterPassed = filteredTail < 128LL * 2LL * 2000LL;
	float liveFilterValues[PP_BUILTIN_EFFECT_PARAMETER_COUNT] = {0};
	BOOL globalLiveUpdatePassed = MADUpdateBuiltinEffectParameters(driver, true,
		0, 0, PP_BUILTIN_DJ_FILTER_ID, liveFilterValues);
	int unfiltered[512 * 2];
	for (NSInteger frame = 0; frame < 512; frame++) {
		unfiltered[frame * 2] = unfiltered[frame * 2 + 1] =
			frame & 1 ? 12000 : -12000;
	}
	int unfilteredReference[512 * 2];
	memcpy(unfilteredReference, unfiltered, sizeof(unfiltered));
	ProcessVSTPlug(driver, unfiltered, 512, -1);
	globalLiveUpdatePassed &= memcmp(unfiltered, unfilteredReference,
		sizeof(unfiltered)) == 0;

	// The compressor is stereo-linked and should reduce sustained material well
	// above its threshold once its attack envelope has settled.
	memset(globalSlots, 0, sizeof(globalSlots));
	globalSlots[0].effectID = PP_BUILTIN_COMPRESSOR_ID;
	globalSlots[0].values[0] = -24.0f;
	globalSlots[0].values[1] = 8.0f;
	globalSlots[0].values[2] = 0.1f;
	globalSlots[0].values[3] = 100.0f;
	MADConfigureBuiltinEffectChains(driver, true, globalSlots, trackEnabled, trackSlots, MAXTRACK);
	int compressed[512 * 2];
	for (NSInteger sample = 0; sample < 512 * 2; sample++) compressed[sample] = 28000;
	ProcessVSTPlug(driver, compressed, 512, -1);
	BOOL compressorPassed = llabs(compressed[511 * 2]) < 10000 && compressed[511 * 2] != 0 &&
		compressed[511 * 2] == compressed[511 * 2 + 1];

	// Verify that multiple per-track slots are recognized and run as a chain.
	memset(globalSlots, 0, sizeof(globalSlots));
	trackSlots[0][0].effectID = PP_BUILTIN_DJ_FILTER_ID;
	trackSlots[0][0].values[0] = -1.0f;
	trackSlots[0][1] = (PPBuiltinEffectSlot){
		.effectID = PP_BUILTIN_COMPRESSOR_ID,
		.values = {-24.0f, 8.0f, 0.1f, 100.0f, 0.0f}
	};
	trackEnabled[0] = true;
	driver->base.chan[0].TrackID = 0;
	MADConfigureBuiltinEffectChains(driver, false, globalSlots, trackEnabled, trackSlots, MAXTRACK);
	int trackChain[512 * 2];
	for (NSInteger frame = 0; frame < 512; frame++) {
		trackChain[frame * 2] = trackChain[frame * 2 + 1] = frame & 1 ? 20000 : -20000;
	}
	ProcessVSTPlug(driver, trackChain, 512, 0);
	long long trackTail = 0;
	for (NSInteger sample = 384 * 2; sample < 512 * 2; sample++) trackTail += llabs(trackChain[sample]);
	float liveCompressorValues[PP_BUILTIN_EFFECT_PARAMETER_COUNT] = {
		0.0f, 1.0f, 0.1f, 1.0f, 0.0f
	};
	BOOL trackLiveUpdatePassed = MADUpdateBuiltinEffectParameters(driver, false,
		0, 0, PP_BUILTIN_DJ_FILTER_ID, liveFilterValues) &&
		MADUpdateBuiltinEffectParameters(driver, false, 0, 1,
			PP_BUILTIN_COMPRESSOR_ID, liveCompressorValues);
	int liveTrack[512 * 2];
	for (NSInteger frame = 0; frame < 512; frame++) {
		liveTrack[frame * 2] = liveTrack[frame * 2 + 1] =
			frame & 1 ? 5000 : -5000;
	}
	int liveTrackReference[512 * 2];
	memcpy(liveTrackReference, liveTrack, sizeof(liveTrack));
	ProcessVSTPlug(driver, liveTrack, 512, 0);
	trackLiveUpdatePassed &= memcmp(liveTrack, liveTrackReference,
		sizeof(liveTrack)) == 0;
	return filterPassed && globalLiveUpdatePassed && compressorPassed &&
		IsVSTChanEffect(driver, 0) && trackTail < 128LL * 2LL * 2000LL &&
		trackLiveUpdatePassed;
}

static BOOL PPTestOutputEqualizer(MADDriverRec *driver)
{
	if (driver == NULL || driver->Filter == NULL || driver->fData == NULL ||
		driver->outputEqualizerState == NULL) return NO;
	enum { frameCount = 4096, sampleCount = frameCount * 2 };
	int16_t original[sampleCount];
	for (NSInteger frame = 0; frame < frameCount; frame++) {
		original[frame * 2] = (int16_t)lrint(sin(2.0 * M_PI * 37.0 *
			(double)frame / 1024.0) * 12000.0);
		original[frame * 2 + 1] = (int16_t)lrint(sin(2.0 * M_PI * 83.0 *
			(double)frame / 1024.0) * 7000.0);
	}

	// Bypass and the original 100% preset must both be bit-for-bit transparent.
	double unity[PP_EQUALIZER_BAND_COUNT];
	for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) unity[band] = 1.0;
	int16_t bypassed[sampleCount];
	memcpy(bypassed, original, sizeof(original));
	PPSetEqualizerBands(driver, unity, false);
	MADProcessOutputEqualizer(driver, bypassed, frameCount);
	BOOL bypassPassed = memcmp(bypassed, original, sizeof(original)) == 0;
	int16_t flat[sampleCount];
	memcpy(flat, original, sizeof(original));
	PPSetEqualizerBands(driver, unity, true);
	MADProcessOutputEqualizer(driver, flat, frameCount);
	BOOL unityPassed = memcmp(flat, original, sizeof(original)) == 0;

	double quarterGain[PP_EQUALIZER_BAND_COUNT];
	for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) quarterGain[band] = 0.25;
	PPSetEqualizerBands(driver, quarterGain, true);
	int16_t attenuated[sampleCount];
	memcpy(attenuated, original, sizeof(original));
	MADProcessOutputEqualizer(driver, attenuated, frameCount);
	long long beforeLeft = 0, beforeRight = 0, afterLeft = 0, afterRight = 0;
	long long channelDifference = 0;
	for (NSInteger frame = 1024; frame < frameCount; frame++) {
		beforeLeft += llabs(original[(frame - 1024) * 2]);
		beforeRight += llabs(original[(frame - 1024) * 2 + 1]);
		afterLeft += llabs(attenuated[frame * 2]);
		afterRight += llabs(attenuated[frame * 2 + 1]);
		channelDifference += llabs((long long)attenuated[frame * 2] -
			(long long)attenuated[frame * 2 + 1]);
	}
	PPSetEqualizerBands(driver, unity, false);
	BOOL attenuationPassed = afterLeft > 0 && afterRight > 0 &&
		afterLeft < beforeLeft / 2 && afterRight < beforeRight / 2;
	BOOL stereoPassed = channelDifference > 0;
	return bypassPassed && unityPassed && attenuationPassed && stereoPassed;
}

static BOOL PPTestStoppedSampleRendering(MADLibrary *library, MADMusic *music, sData *sample)
{
	if (library == NULL || music == NULL || sample == NULL || sample->data == NULL) return NO;
	MADDriverSettings settings;
	MADGetBestDriver(&settings);
	settings.driverMode = NoHardwareDriver;
	settings.outPutBits = 16;
	settings.outPutMode = DeluxeStereoOutPut;
	settings.numChn = MAX(settings.numChn, 4);
	MADDriverRec *driver = NULL;
	MADErr error = MADCreateDriver(&settings, library, &driver);
	if (error == MADNoErr) error = MADStartDriver(driver);
	if (error == MADNoErr) error = MADAttachDriverToMusic(driver, music, NULL);
	if (error == MADNoErr && !PPTestOutputEqualizer(driver)) error = MADSoundManagerErr;
	if (error == MADNoErr && !PPTestBuiltinMixerDSP(driver)) error = MADSoundManagerErr;
	bool trackEffects[MAXTRACK] = {false};
	if (error == MADNoErr) MADConfigureBuiltinFreeverb(driver, true, trackEffects, MAXTRACK);
	if (error == MADNoErr) error = MADPlaySoundData(driver, sample->data, (size_t)sample->size, 0, 48,
		sample->amp, 0, 0, sample->c2spd, sample->stereo);
	char *rendered = error == MADNoErr ? calloc(driver->BufSize, 1) : NULL;
	if (error == MADNoErr && rendered == NULL) error = MADNeedMemory;
	if (error == MADNoErr && !MADDirectSaveAlways(rendered, NULL, driver)) error = MADUnknownErr;
	BOOL audible = NO;
	if (error == MADNoErr) {
		for (size_t index = 0; index < driver->BufSize; index++) {
			if (rendered[index] != 0) { audible = YES; break; }
		}
	}
	BOOL mixerTail = NO;
	if (error == MADNoErr) {
		memset(rendered, 0, driver->BufSize);
		if (!MADDirectSaveAlways(rendered, NULL, driver)) error = MADUnknownErr;
		for (size_t index = 0; error == MADNoErr && index < driver->BufSize; index++) {
			if (rendered[index] != 0) { mixerTail = YES; break; }
		}
	}
	BOOL trackMixerTail = NO;
	if (error == MADNoErr) {
		trackEffects[0] = true;
		MADConfigureBuiltinFreeverb(driver, false, trackEffects, MAXTRACK);
		error = MADPlaySoundData(driver, sample->data, (size_t)sample->size, 0, 48,
			sample->amp, 0, 0, sample->c2spd, sample->stereo);
		memset(rendered, 0, driver->BufSize);
		if (error == MADNoErr && !MADDirectSaveAlways(rendered, NULL, driver)) error = MADUnknownErr;
		memset(rendered, 0, driver->BufSize);
		if (error == MADNoErr && !MADDirectSaveAlways(rendered, NULL, driver)) error = MADUnknownErr;
		for (size_t index = 0; error == MADNoErr && index < driver->BufSize; index++) {
			if (rendered[index] != 0) { trackMixerTail = YES; break; }
		}
	}
	BOOL combinedRoutingStable = NO;
	if (error == MADNoErr && music->header != NULL) {
		/*
		 * A stateless per-track effect followed by a stateless global effect
		 * must not replay a finished one-shot. This catches stale track
		 * accumulator data being fed back into the master bus.
		 */
		MADCleanDriver(driver);
		size_t accumulatorBytes = (size_t)driver->ASCBUFFER * 8 +
			(size_t)driver->MDelay * 2 * 8;
		memset(driver->DASCBuffer, 0, accumulatorBytes);
		for (NSInteger buffer = 0; buffer < MAXCHANEFFECT; buffer++) {
			memset(driver->DASCEffectBuffer[buffer], 0, accumulatorBytes);
		}
		PPBuiltinEffectSlot globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS] = {0};
		PPBuiltinEffectSlot trackSlots[MAXTRACK][PP_BUILTIN_TRACK_EFFECT_SLOTS] = {0};
		bool combinedTrackEnabled[MAXTRACK] = {false};
		globalSlots[0].effectID = PP_BUILTIN_DJ_FILTER_ID;
		trackSlots[0][0].effectID = PP_BUILTIN_DJ_FILTER_ID;
		combinedTrackEnabled[0] = true;
		FXBus savedBus = music->header->chanBus[0];
		music->header->chanBus[0].Active = true;
		music->header->chanBus[0].ByPass = false;
		music->header->chanBus[0].copyId = 0;
		MADConfigureBuiltinEffectChains(driver, true, globalSlots,
			combinedTrackEnabled, trackSlots, MAXTRACK);
		int16_t pulse[64];
		for (NSInteger sampleIndex = 0; sampleIndex < 64; sampleIndex++) {
			pulse[sampleIndex] = sampleIndex & 1 ? 12000 : -12000;
		}
		error = MADPlaySoundData(driver, (const char *)pulse, sizeof(pulse),
			0, 48, 16, 0, 0, 44100, false);
		long long firstEnergy = 0;
		long long finalEnergy = 0;
		for (NSInteger buffer = 0; error == MADNoErr && buffer < 8; buffer++) {
			memset(rendered, 0, driver->BufSize);
			if (!MADDirectSaveAlways(rendered, NULL, driver)) {
				error = MADUnknownErr;
				break;
			}
			long long energy = 0;
			const int16_t *samples = (const int16_t *)rendered;
			for (size_t sampleIndex = 0;
				sampleIndex < driver->BufSize / sizeof(int16_t); sampleIndex++) {
				energy += llabs(samples[sampleIndex]);
			}
			if (buffer == 0) firstEnergy = energy;
			if (buffer == 7) finalEnergy = energy;
		}
		combinedRoutingStable = error == MADNoErr && firstEnergy > 0 &&
			finalEnergy == 0;
		music->header->chanBus[0] = savedBus;
	}
	free(rendered);
	if (driver != NULL) {
		MADStopDriver(driver);
		MADDisposeDriver(driver);
	}
	return error == MADNoErr && audible && mixerTail && trackMixerTail &&
		combinedRoutingStable;
}

static int PPRunSelfTest(const char *path)
{
	MADErr xmImportError = PPXMRunImportSelfTest();
	if (xmImportError != MADNoErr) {
		fprintf(stderr, "FastTracker XM import self-test failed with error %d\n",
			xmImportError);
		return EXIT_FAILURE;
	}
	fprintf(stdout, "FastTracker XM import passed (packed patterns, empty row counts, envelopes, loops, 8/16-bit delta samples, extended effects, truncation rejection)\n");
	MADMIDISetOutputOptions(true, false, true, MADMIDIChannelRoutingTrack, 0);
	BOOL trackerRoutingPassed = MADMIDIRoutedChannel(3, 9) == 3;
	MADMIDISetOutputOptions(true, false, true, MADMIDIChannelRoutingInstrument, 0);
	BOOL instrumentRoutingPassed = MADMIDIRoutedChannel(3, 9) == 9;
	MADMIDISetOutputOptions(true, false, true, MADMIDIChannelRoutingFixed, 12);
	BOOL fixedRoutingPassed = MADMIDIRoutedChannel(3, 9) == 12;
	MADMIDISetOutputOptions(false, false, false, MADMIDIChannelRoutingTrack, 0);
	if (!trackerRoutingPassed || !instrumentRoutingPassed || !fixedRoutingPassed) {
		fprintf(stderr, "CoreMIDI channel-routing self-test failed\n");
		return EXIT_FAILURE;
	}
	fprintf(stdout, "CoreMIDI channel routing passed (tracker, instrument, fixed)\n");
	if (!PPPianoRunPreviewOwnershipSelfTest()) {
		fprintf(stderr, "Piano preview voice-ownership self-test failed\n");
		return EXIT_FAILURE;
	}
	fprintf(stdout, "Piano preview voice ownership passed (reserved audition voice preserves pattern tracks)\n");
	if (!PPPatternRunCommandCodecSelfTest()) {
		fprintf(stderr, "PlayerPRO Digital command codec self-test failed\n");
		return EXIT_FAILURE;
	}
	fprintf(stdout, "Digital command notation passed (blank fields, OFF, 0-F, G, L, O)\n");
	if (!PPApplicationRunPatternFileSelfTest()) {
		fprintf(stderr, "PlayerPRO standalone pattern-file self-test failed\n");
		return EXIT_FAILURE;
	}
	fprintf(stdout, "Standalone PATN pattern files passed (original endian format and track adaptation)\n");
	if (!PPSampleRunEditingSelfTest()) {
		fprintf(stderr, "PlayerPRO destructive sample-editing self-test failed\n");
		return EXIT_FAILURE;
	}
	if (!PPApplicationRunSampleWorkflowSelfTest()) {
		fprintf(stderr, "PlayerPRO sample-import workflow self-test failed\n");
		return EXIT_FAILURE;
	}
	fprintf(stdout, "Destructive sample editing and RAW sample conversion passed (clipboard primitives, crop/reverse/normalize, native filters, EQ-3, Freeverb and realtime mixer tails, stereo frames)\n");
	MADLibrary *library = NULL;
	MADMusic *music = NULL;
	char type[5] = {0};
	char *mutablePath = strdup(path);
	if (mutablePath == NULL) {
		return EXIT_FAILURE;
	}
	MADErr error = MADInitLibrary(NULL, &library);
	if (error == MADNoErr) {
		error = MADMusicIdentifyCString(library, type, mutablePath);
	}
	if (error == MADNoErr) {
		error = MADLoadMusicFileCString(library, &music, type, mutablePath);
	}
	if (error == MADNoErr && (music == NULL || music->header == NULL ||
		music->header->numPat == 0 || music->header->numChn == 0)) {
		error = MADIncompatibleFile;
	}
	if (error == MADNoErr) {
		fprintf(stdout, "Loaded %.4s: %u patterns, %u tracks, %ld actual instruments\n",
			type, music->header->numPat, music->header->numChn, (long)PPActualInstrumentCount(music));
		MADByte expectedPatterns = music->header->numPat;
		MADByte expectedTracks = music->header->numChn;
		char roundTripPath[PATH_MAX];
		snprintf(roundTripPath, sizeof(roundTripPath), "/tmp/playerpro-26-self-test-%d.madk", getpid());
		unlink(roundTripPath);
		error = MADMusicSaveCString(music, roundTripPath, true);
		if (error == MADNoErr) {
			MADDisposeMusic(&music, NULL);
			memset(type, 0, sizeof(type));
			error = MADMusicIdentifyCString(library, type, roundTripPath);
		}
		if (error == MADNoErr) {
			error = MADLoadMusicFileCString(library, &music, type, roundTripPath);
		}
		if (error == MADNoErr && (music == NULL || music->header->numPat != expectedPatterns ||
			music->header->numChn != expectedTracks)) {
			error = MADIncompatibleFile;
		}
		unlink(roundTripPath);
		if (error == MADNoErr) {
			fprintf(stdout, "Imported tracker MADK save/reload round trip passed\n");
			MADDisposeMusic(&music, NULL);
			music = CreateFreeMADK();
			if (music == NULL) error = MADNeedMemory;
		}
		static const int16_t fixtureFrames[] = {-12000, 8000, -4000, 16000, 4000, -16000, 12000, -8000};
		if (error == MADNoErr) {
			music->fid[0].firstSample = 0;
			music->fid[0].no = 0;
			memcpy(music->fid[0].name, "Self-test instrument", 20);
			music->fid[0].volEnv[0] = (EnvRec){0, 64};
			music->fid[0].volEnv[1] = (EnvRec){96, 42};
			music->fid[0].volEnv[2] = (EnvRec){300, 0};
			music->fid[0].volSize = 3;
			music->fid[0].volSus = 1;
			music->fid[0].volBeg = 0;
			music->fid[0].volEnd = 2;
			music->fid[0].volType = PPEnvelopeOn | PPEnvelopeSustain | PPEnvelopeLoop;
			music->fid[0].pannEnv[0] = (EnvRec){0, 32};
			music->fid[0].pannEnv[1] = (EnvRec){150, 48};
			music->fid[0].pannEnv[2] = (EnvRec){300, 16};
			music->fid[0].pannSize = 3;
			music->fid[0].pannSus = 0;
			music->fid[0].pannBeg = 0;
			music->fid[0].pannEnd = 2;
			music->fid[0].pannType = PPEnvelopeOn | PPEnvelopeLoop | PPEnvelopeFixedSpeed;
			music->fid[0].volFade = 917;
			for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
				music->fid[0].what[note] = note < 48 ? 0 : 1;
			}
			music->header->numInstru = 1;
			sData *fixtureSample = MADCreateSample(music, 0, 0);
			if (fixtureSample == NULL) error = MADNeedMemory;
			else {
				fixtureSample->size = (int)sizeof(fixtureFrames);
				fixtureSample->data = malloc(sizeof(fixtureFrames));
				if (fixtureSample->data == NULL) error = MADNeedMemory;
				else memcpy(fixtureSample->data, fixtureFrames, sizeof(fixtureFrames));
				fixtureSample->amp = 16;
				fixtureSample->stereo = MADTrue;
				fixtureSample->c2spd = 22050;
				fixtureSample->vol = 64;
				fixtureSample->loopBeg = 4;
				fixtureSample->loopSize = 8;
				memcpy(fixtureSample->name, "Stereo fixture", 14);
				music->header->numSamples = 1;
			}
			PatData *fixturePattern = music->partition[0];
			if (fixturePattern == NULL || fixturePattern->header.size < 12 || music->header->numChn < 2) {
				error = MADIncompatibleFile;
			} else {
				*GetMADCommand(7, 0, fixturePattern) = (Cmd){1, 48, MADEffectSpeed, 6, 0x40, 0};
				*GetMADCommand(8, 1, fixturePattern) = (Cmd){1, 52, MADEffectVibrato, 0x24, 0x30, 0};
				*GetMADCommand(9, 0, fixturePattern) = (Cmd){1, 0xFE, MADEffectNoteOff, 0, 0xFF, 0};
				*GetMADCommand(10, 1, fixturePattern) = (Cmd){1, 55, MADEffectLoop, 0x03, 0x20, 0};
				*GetMADCommand(11, 0, fixturePattern) = (Cmd){1, 57, MADEffectNOffset, 0x12, 0x30, 0};
			}
		}
		if (error == MADNoErr) {
			sData *fixtureSample = music->sample[0];
			if (!PPTestStoppedSampleRendering(library, music, fixtureSample)) error = MADSoundManagerErr;
			else fprintf(stdout, "Output Equalizer and ordered Freeverb/DJ Filter/Compressor mixer paths produced verified PCM\n");
		}
		if (error == MADNoErr) {
			music->header->globalEffect[0] = (int)PP_BUILTIN_FREEVERB_ID;
			music->header->globalEffect[1] = (int)PP_BUILTIN_DJ_FILTER_ID;
			music->header->globalFXActive = true;
			music->header->chanEffect[0][0] = (int)PP_BUILTIN_FREEVERB_ID;
			music->header->chanEffect[0][1] = (int)PP_BUILTIN_COMPRESSOR_ID;
			music->header->chanBus[0].Active = true;
			music->header->chanBus[0].ByPass = false;
			music->header->chanBus[0].copyId = 0;
			for (NSInteger setIndex = 0; setIndex < 4; setIndex++) {
				FXSets *set = &music->sets[setIndex];
				BOOL global = setIndex < 2;
				BOOL firstSlot = (setIndex % 2) == 0;
				set->track = global ? -1 : 0;
				set->id = firstSlot ? 0 : 1;
				set->FXID = (int)(firstSlot ? PP_BUILTIN_FREEVERB_ID :
					(global ? PP_BUILTIN_DJ_FILTER_ID : PP_BUILTIN_COMPRESSOR_ID));
				if (firstSlot) {
					set->noArg = 7;
					set->values[0] = 0.84f;
					set->values[1] = 0.50f;
					set->values[5] = -6.0f;
					set->name[0] = 8;
					memcpy(&set->name[1], "Freeverb", 8);
				} else if (global) {
					set->noArg = 1;
					set->values[0] = 0.35f;
					set->name[0] = 9;
					memcpy(&set->name[1], "DJ Filter", 9);
				} else {
					set->noArg = 5;
					set->values[0] = -18.0f;
					set->values[1] = 6.0f;
					set->values[2] = 5.0f;
					set->values[3] = 150.0f;
					set->values[4] = 2.0f;
					set->name[0] = 10;
					memcpy(&set->name[1], "Compressor", 10);
				}
			}
		}
		if (error == MADNoErr) error = MADMusicSaveCString(music, roundTripPath, true);
		if (error == MADNoErr) {
			MADDisposeMusic(&music, NULL);
			memset(type, 0, sizeof(type));
			error = MADMusicIdentifyCString(library, type, roundTripPath);
		}
		if (error == MADNoErr) error = MADLoadMusicFileCString(library, &music, type, roundTripPath);
		Cmd *roundTripCommandA = error == MADNoErr && music != NULL ? GetMADCommand(7, 0, music->partition[0]) : NULL;
		Cmd *roundTripCommandB = error == MADNoErr && music != NULL ? GetMADCommand(8, 1, music->partition[0]) : NULL;
		Cmd *roundTripCommandG = error == MADNoErr && music != NULL ? GetMADCommand(9, 0, music->partition[0]) : NULL;
		Cmd *roundTripCommandL = error == MADNoErr && music != NULL ? GetMADCommand(10, 1, music->partition[0]) : NULL;
		Cmd *roundTripCommandO = error == MADNoErr && music != NULL ? GetMADCommand(11, 0, music->partition[0]) : NULL;
		if (error == MADNoErr && (music == NULL || music->fid[0].numSamples != 1 || music->sample[0] == NULL ||
			music->sample[0]->size != (int)sizeof(fixtureFrames) || music->sample[0]->amp != 16 ||
			!music->sample[0]->stereo || music->sample[0]->c2spd != 22050 || music->sample[0]->loopBeg != 4 ||
			music->sample[0]->loopSize != 8 || memcmp(music->sample[0]->data, fixtureFrames, sizeof(fixtureFrames)) != 0 ||
			music->fid[0].volSize != 3 || music->fid[0].volEnv[1].pos != 96 || music->fid[0].volEnv[1].val != 42 ||
			music->fid[0].volSus != 1 || music->fid[0].volEnd != 2 ||
			music->fid[0].volType != (PPEnvelopeOn | PPEnvelopeSustain | PPEnvelopeLoop) || music->fid[0].volFade != 917 ||
			music->fid[0].pannSize != 3 || music->fid[0].pannEnv[1].pos != 150 ||
			music->fid[0].pannEnv[1].val != 48 || music->fid[0].pannEnd != 2 ||
			music->fid[0].pannType != (PPEnvelopeOn | PPEnvelopeLoop | PPEnvelopeFixedSpeed) ||
			(uint32_t)music->header->globalEffect[0] != PP_BUILTIN_FREEVERB_ID || !music->header->globalFXActive ||
			(uint32_t)music->header->globalEffect[1] != PP_BUILTIN_DJ_FILTER_ID ||
			(uint32_t)music->header->chanEffect[0][0] != PP_BUILTIN_FREEVERB_ID || !music->header->chanBus[0].Active ||
			(uint32_t)music->header->chanEffect[0][1] != PP_BUILTIN_COMPRESSOR_ID ||
			(uint32_t)music->sets[0].FXID != PP_BUILTIN_FREEVERB_ID ||
			(uint32_t)music->sets[1].FXID != PP_BUILTIN_DJ_FILTER_ID || music->sets[1].values[0] != 0.35f ||
			(uint32_t)music->sets[2].FXID != PP_BUILTIN_FREEVERB_ID ||
			(uint32_t)music->sets[3].FXID != PP_BUILTIN_COMPRESSOR_ID || music->sets[3].values[1] != 6.0f ||
			music->fid[0].what[0] != 0 || music->fid[0].what[47] != 0 ||
			music->fid[0].what[48] != 1 || music->fid[0].what[95] != 1 ||
			roundTripCommandA == NULL || roundTripCommandA->ins != 1 || roundTripCommandA->note != 48 ||
			roundTripCommandA->cmd != MADEffectSpeed || roundTripCommandA->arg != 6 || roundTripCommandA->vol != 0x40 ||
			roundTripCommandB == NULL || roundTripCommandB->ins != 1 || roundTripCommandB->note != 52 ||
			roundTripCommandB->cmd != MADEffectVibrato || roundTripCommandB->arg != 0x24 || roundTripCommandB->vol != 0x30 ||
			roundTripCommandG == NULL || roundTripCommandG->note != 0xFE || roundTripCommandG->cmd != MADEffectNoteOff ||
			roundTripCommandG->arg != 0 || roundTripCommandG->vol != 0xFF ||
			roundTripCommandL == NULL || roundTripCommandL->note != 55 || roundTripCommandL->cmd != MADEffectLoop ||
			roundTripCommandL->arg != 0x03 || roundTripCommandL->vol != 0x20 ||
			roundTripCommandO == NULL || roundTripCommandO->note != 57 || roundTripCommandO->cmd != MADEffectNOffset ||
			roundTripCommandO->arg != 0x12 || roundTripCommandO->vol != 0x30)) {
			error = MADIncompatibleFile;
		}
		unlink(roundTripPath);
		if (error == MADNoErr) {
			fprintf(stdout, "Samples, envelopes, note maps, all built-in mixer routes/parameters, and Digital 0-F/G/L/O commands survived MADK save/reload\n");
		}
	}
	if (music != NULL) {
		MADDisposeMusic(&music, NULL);
	}
	if (library != NULL) {
		MADDisposeLibrary(library);
	}
	free(mutablePath);
	if (error != MADNoErr) {
		fprintf(stderr, "PlayerPRO self-test failed with error %d\n", error);
		return EXIT_FAILURE;
	}
	return EXIT_SUCCESS;
}

int main(int argc, const char *argv[])
{
	if (argc == 3 && strcmp(argv[1], "--self-test") == 0) {
		@autoreleasepool {
			return PPRunSelfTest(argv[2]);
		}
	}
	@autoreleasepool {
		NSApplication *application = NSApplication.sharedApplication;
		application.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
		PPApplicationController *controller = [[PPApplicationController alloc] init];
		application.delegate = controller;
		[application run];
	}
	return 0;
}
