#ifndef PP_MIDI_HARDWARE_OSX_H
#define PP_MIDI_HARDWARE_OSX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MADMIDIEventCallback)(void *context, uint8_t status, uint8_t data1, uint8_t data2);
typedef void (*MADMIDIDevicesChangedCallback)(void *context);

typedef enum MADMIDIChannelRouting {
	MADMIDIChannelRoutingTrack = 0,
	MADMIDIChannelRoutingInstrument = 1,
	MADMIDIChannelRoutingFixed = 2
} MADMIDIChannelRouting;

#define MADMIDI_NO_ENDPOINT_ID INT32_MIN

/// Starts the shared CoreMIDI client used by live input and PlayerPRO output.
bool MADMIDIInitialize(MADMIDIEventCallback eventCallback,
	void *eventContext,
	MADMIDIDevicesChangedCallback devicesChangedCallback,
	void *devicesContext);
void MADMIDIShutdown(void);

size_t MADMIDIGetSourceCount(void);
size_t MADMIDIGetDestinationCount(void);
bool MADMIDIGetSourceInfo(size_t index, int32_t *uniqueID, char *name, size_t nameCapacity);
bool MADMIDIGetDestinationInfo(size_t index, int32_t *uniqueID, char *name, size_t nameCapacity);
bool MADMIDIIsApplicationInputEndpoint(int32_t uniqueID);
void MADMIDIRefreshDevices(void);

/// A source ID of 0 means every physical/virtual source.
void MADMIDISetInput(int32_t sourceUniqueID, bool enabled);
/// MADMIDI_NO_ENDPOINT_ID means no destination.
void MADMIDISetOutput(int32_t destinationUniqueID, bool enabled);
void MADMIDISetOutputOptions(bool playbackEnabled,
	bool clockEnabled,
	bool programChangesEnabled,
	MADMIDIChannelRouting routing,
	uint8_t fixedChannel);

bool MADMIDIOutputIsEnabled(void);
bool MADMIDIPlaybackOutputIsEnabled(void);
bool MADMIDIClockOutputIsEnabled(void);
uint8_t MADMIDIRoutedChannel(int track, int instrument);

void MADMIDISendBytes(const uint8_t *bytes, size_t length);
void MADMIDISendNoteOn(uint8_t channel, uint8_t note, uint8_t velocity);
void MADMIDISendNoteOff(uint8_t channel, uint8_t note, uint8_t velocity);
void MADMIDISendProgramIfNeeded(uint8_t channel, uint8_t program);
void MADMIDISendAllNotesOff(void);

#ifdef __cplusplus
}
#endif

#endif
