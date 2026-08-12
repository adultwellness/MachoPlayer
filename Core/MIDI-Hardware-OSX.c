#include "MIDI-Hardware-OSX.h"

#include "MAD.h"
#include "MADDriver.h"
#include "RDriver.h"
#include "RDriverInt.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <stdatomic.h>
#include <string.h>

Boolean MIDIHardware = false;
Boolean MIDIHardwareAlreadyOpen = false;

static MIDIClientRef gMIDIClient;
static MIDIPortRef gMIDIInputPort;
static MIDIPortRef gMIDIOutputPort;
static MIDIEndpointRef gMIDIVirtualInput;
static MIDIEndpointRef gMIDIOutputDestination;

static int32_t gSelectedInputID = -1;
static int32_t gSelectedOutputID = MADMIDI_NO_ENDPOINT_ID;
static bool gInputEnabled;
static bool gOutputEnabled;
static bool gPlaybackEnabled;
static bool gClockEnabled;
static bool gProgramChangesEnabled;
static _Atomic int gChannelRouting = MADMIDIChannelRoutingTrack;
static _Atomic unsigned char gFixedChannel;
static int16_t gLastProgram[16] = {
	-1, -1, -1, -1, -1, -1, -1, -1,
	-1, -1, -1, -1, -1, -1, -1, -1
};

static MADMIDIEventCallback gEventCallback;
static void *gEventContext;
static MADMIDIDevicesChangedCallback gDevicesChangedCallback;
static void *gDevicesContext;

typedef struct MADMIDIParser {
	uint8_t runningStatus;
	uint8_t currentStatus;
	uint8_t data[2];
	uint8_t count;
	uint8_t needed;
	bool inSysEx;
} MADMIDIParser;

static MADMIDIParser gParser;

static void MADMIDINotifyProc(const MIDINotification *message, void *refCon);
static void MADMIDIReadProc(const MIDIPacketList *packetList, void *readProcRefCon, void *sourceConnectionRefCon);

static uint8_t MADMIDIDataLength(uint8_t status)
{
	if (status < 0x80) return 0;
	if (status < 0xF0) {
		uint8_t kind = status & 0xF0;
		return kind == 0xC0 || kind == 0xD0 ? 1 : 2;
	}
	switch (status) {
		case 0xF1: case 0xF3: return 1;
		case 0xF2: return 2;
		default: return 0;
	}
}

static void MADMIDIDeliver(uint8_t status, uint8_t data1, uint8_t data2)
{
	if (gEventCallback != NULL) gEventCallback(gEventContext, status, data1, data2);
}

static void MADMIDIParseByte(uint8_t byte)
{
	// Realtime bytes may occur between any two data bytes and never disturb
	// running status.
	if (byte >= 0xF8) {
		MADMIDIDeliver(byte, 0, 0);
		return;
	}
	if (gParser.inSysEx) {
		if (byte == 0xF7) gParser.inSysEx = false;
		return;
	}
	if (byte & 0x80) {
		gParser.count = 0;
		if (byte == 0xF0) {
			gParser.inSysEx = true;
			gParser.runningStatus = 0;
			gParser.currentStatus = 0;
			gParser.needed = 0;
			return;
		}
		gParser.needed = MADMIDIDataLength(byte);
		gParser.currentStatus = byte;
		if (byte < 0xF0) {
			gParser.runningStatus = byte;
		} else {
			// System-common messages cancel running status, but still need to
			// retain their own status while their one or two data bytes arrive.
			gParser.runningStatus = 0;
		}
		if (gParser.needed == 0) {
			MADMIDIDeliver(byte, 0, 0);
			gParser.currentStatus = gParser.runningStatus;
		}
		return;
	}
	if (gParser.currentStatus == 0 || gParser.needed == 0) return;
	gParser.data[gParser.count++] = byte & 0x7F;
	if (gParser.count >= gParser.needed) {
		MADMIDIDeliver(gParser.currentStatus, gParser.data[0],
			gParser.needed > 1 ? gParser.data[1] : 0);
		gParser.count = 0;
		if (gParser.currentStatus >= 0xF0) {
			gParser.currentStatus = 0;
			gParser.needed = 0;
		} else {
			gParser.currentStatus = gParser.runningStatus;
		}
	}
}

static bool MADMIDIEndpointInfo(MIDIEndpointRef endpoint, int32_t *uniqueID,
	char *name, size_t nameCapacity)
{
	if (endpoint == 0) return false;
	SInt32 identifier = 0;
	if (MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &identifier) != noErr) return false;
	CFStringRef displayName = NULL;
	if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &displayName) != noErr ||
		displayName == NULL) {
		MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &displayName);
	}
	if (uniqueID != NULL) *uniqueID = identifier;
	if (name != NULL && nameCapacity > 0) {
		name[0] = '\0';
		if (displayName != NULL) {
			CFStringGetCString(displayName, name, (CFIndex)nameCapacity, kCFStringEncodingUTF8);
		}
		if (name[0] == '\0') {
			const char *fallback = "Unnamed MIDI endpoint";
			strncpy(name, fallback, nameCapacity - 1);
			name[nameCapacity - 1] = '\0';
		}
	}
	if (displayName != NULL) CFRelease(displayName);
	return true;
}

static MIDIEndpointRef MADMIDIEndpointWithID(bool source, int32_t uniqueID)
{
	ItemCount count = source ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations();
	for (ItemCount index = 0; index < count; index++) {
		MIDIEndpointRef endpoint = source ? MIDIGetSource(index) : MIDIGetDestination(index);
		if (!source && endpoint == gMIDIVirtualInput) continue;
		int32_t candidate = 0;
		if (MADMIDIEndpointInfo(endpoint, &candidate, NULL, 0) && candidate == uniqueID) return endpoint;
	}
	return 0;
}

static void MADMIDIRebuildInputConnections(void)
{
	if (gMIDIClient == 0) return;
	if (gMIDIInputPort != 0) {
		MIDIPortDispose(gMIDIInputPort);
		gMIDIInputPort = 0;
	}
	memset(&gParser, 0, sizeof(gParser));
	if (!gInputEnabled) return;
	if (MIDIInputPortCreate(gMIDIClient, CFSTR("MachoPlayer MIDI Input"),
		MADMIDIReadProc, NULL, &gMIDIInputPort) != noErr) return;
	ItemCount count = MIDIGetNumberOfSources();
	for (ItemCount index = 0; index < count; index++) {
		MIDIEndpointRef source = MIDIGetSource(index);
		int32_t identifier = 0;
		if (!MADMIDIEndpointInfo(source, &identifier, NULL, 0)) continue;
		if (gSelectedInputID == 0 || identifier == gSelectedInputID) {
			MIDIPortConnectSource(gMIDIInputPort, source, (void *)(intptr_t)identifier);
		}
	}
}

static void MADMIDIResolveOutput(void)
{
	// CoreMIDI unique IDs are signed. Negative values are legitimate, so the
	// no-destination sentinel lives at a value reserved by MachoPlayer.
	gMIDIOutputDestination = gOutputEnabled && gSelectedOutputID != MADMIDI_NO_ENDPOINT_ID
		? MADMIDIEndpointWithID(false, gSelectedOutputID) : 0;
}

bool MADMIDIInitialize(MADMIDIEventCallback eventCallback,
	void *eventContext,
	MADMIDIDevicesChangedCallback devicesChangedCallback,
	void *devicesContext)
{
	gEventCallback = eventCallback;
	gEventContext = eventContext;
	gDevicesChangedCallback = devicesChangedCallback;
	gDevicesContext = devicesContext;
	if (gMIDIClient != 0) return true;
	OSStatus error = MIDIClientCreate(CFSTR("MachoPlayer"), MADMIDINotifyProc, NULL, &gMIDIClient);
	if (error != noErr) return false;
	error = MIDIOutputPortCreate(gMIDIClient, CFSTR("MachoPlayer MIDI Output"), &gMIDIOutputPort);
	if (error != noErr) {
		MIDIClientDispose(gMIDIClient);
		gMIDIClient = 0;
		return false;
	}
	// This destination lets another application send directly to MachoPlayer
	// even when no physical MIDI source is connected.
	MIDIDestinationCreate(gMIDIClient, CFSTR("MachoPlayer Input"),
		MADMIDIReadProc, NULL, &gMIDIVirtualInput);
	MIDIHardware = true;
	MIDIHardwareAlreadyOpen = true;
	MADMIDIRebuildInputConnections();
	MADMIDIResolveOutput();
	return true;
}

void MADMIDIShutdown(void)
{
	if (gOutputEnabled) MADMIDISendAllNotesOff();
	if (gMIDIInputPort != 0) MIDIPortDispose(gMIDIInputPort);
	if (gMIDIOutputPort != 0) MIDIPortDispose(gMIDIOutputPort);
	if (gMIDIVirtualInput != 0) MIDIEndpointDispose(gMIDIVirtualInput);
	if (gMIDIClient != 0) MIDIClientDispose(gMIDIClient);
	gMIDIInputPort = 0;
	gMIDIOutputPort = 0;
	gMIDIVirtualInput = 0;
	gMIDIOutputDestination = 0;
	gMIDIClient = 0;
	gEventCallback = NULL;
	gEventContext = NULL;
	gDevicesChangedCallback = NULL;
	gDevicesContext = NULL;
	MIDIHardware = false;
	MIDIHardwareAlreadyOpen = false;
}

size_t MADMIDIGetSourceCount(void) { return (size_t)MIDIGetNumberOfSources(); }
size_t MADMIDIGetDestinationCount(void)
{
	size_t visibleCount = 0;
	ItemCount count = MIDIGetNumberOfDestinations();
	for (ItemCount index = 0; index < count; index++) {
		if (MIDIGetDestination(index) != gMIDIVirtualInput) visibleCount++;
	}
	return visibleCount;
}

bool MADMIDIGetSourceInfo(size_t index, int32_t *uniqueID, char *name, size_t nameCapacity)
{
	if (index >= (size_t)MIDIGetNumberOfSources()) return false;
	return MADMIDIEndpointInfo(MIDIGetSource((ItemCount)index), uniqueID, name, nameCapacity);
}

bool MADMIDIGetDestinationInfo(size_t index, int32_t *uniqueID, char *name, size_t nameCapacity)
{
	size_t visibleIndex = 0;
	ItemCount count = MIDIGetNumberOfDestinations();
	for (ItemCount rawIndex = 0; rawIndex < count; rawIndex++) {
		MIDIEndpointRef endpoint = MIDIGetDestination(rawIndex);
		if (endpoint == gMIDIVirtualInput) continue;
		if (visibleIndex++ == index) {
			return MADMIDIEndpointInfo(endpoint, uniqueID, name, nameCapacity);
		}
	}
	return false;
}

bool MADMIDIIsApplicationInputEndpoint(int32_t uniqueID)
{
	int32_t applicationInputID = 0;
	return gMIDIVirtualInput != 0 &&
		MADMIDIEndpointInfo(gMIDIVirtualInput, &applicationInputID, NULL, 0) &&
		applicationInputID == uniqueID;
}

void MADMIDIRefreshDevices(void)
{
	// Ask installed drivers to rescan, then immediately restore MachoPlayer's
	// connections. CoreMIDI may subsequently deliver another setup-change
	// notification if a driver finishes its scan asynchronously.
	if (MADMIDIOutputIsEnabled()) {
		MADMIDISendAllNotesOff();
		MIDIFlushOutput(gMIDIOutputDestination);
	}
	MIDIRestart();
	MADMIDIRebuildInputConnections();
	MADMIDIResolveOutput();
	if (gDevicesChangedCallback != NULL) {
		gDevicesChangedCallback(gDevicesContext);
	}
}

void MADMIDISetInput(int32_t sourceUniqueID, bool enabled)
{
	gSelectedInputID = sourceUniqueID;
	gInputEnabled = enabled;
	MADMIDIRebuildInputConnections();
}

void MADMIDISetOutput(int32_t destinationUniqueID, bool enabled)
{
	if (gOutputEnabled && (destinationUniqueID != gSelectedOutputID || !enabled)) {
		MADMIDISendAllNotesOff();
	}
	gSelectedOutputID = destinationUniqueID;
	gOutputEnabled = enabled;
	for (size_t index = 0; index < 16; index++) gLastProgram[index] = -1;
	MADMIDIResolveOutput();
}

void MADMIDISetOutputOptions(bool playbackEnabled,
	bool clockEnabled,
	bool programChangesEnabled,
	MADMIDIChannelRouting routing,
	uint8_t fixedChannel)
{
	routing = routing <= MADMIDIChannelRoutingFixed ? routing : MADMIDIChannelRoutingTrack;
	fixedChannel &= 0x0F;
	MADMIDIChannelRouting previousRouting = (MADMIDIChannelRouting)
		atomic_load_explicit(&gChannelRouting, memory_order_acquire);
	uint8_t previousFixedChannel =
		(uint8_t)atomic_load_explicit(&gFixedChannel, memory_order_acquire);
	bool routingChanged = routing != previousRouting ||
		fixedChannel != previousFixedChannel;
	if (routingChanged && MADMIDIOutputIsEnabled()) MADMIDISendAllNotesOff();
	gPlaybackEnabled = playbackEnabled;
	gClockEnabled = clockEnabled;
	gProgramChangesEnabled = programChangesEnabled;
	atomic_store_explicit(&gFixedChannel, fixedChannel, memory_order_release);
	atomic_store_explicit(&gChannelRouting, routing, memory_order_release);
	if (routingChanged || !programChangesEnabled) {
		for (size_t index = 0; index < 16; index++) gLastProgram[index] = -1;
	}
}

bool MADMIDIOutputIsEnabled(void)
{
	return gOutputEnabled && gMIDIOutputPort != 0 && gMIDIOutputDestination != 0;
}

bool MADMIDIPlaybackOutputIsEnabled(void)
{
	return MADMIDIOutputIsEnabled() && gPlaybackEnabled;
}

bool MADMIDIClockOutputIsEnabled(void)
{
	return MADMIDIOutputIsEnabled() && gClockEnabled;
}

uint8_t MADMIDIRoutedChannel(int track, int instrument)
{
	MADMIDIChannelRouting routing = (MADMIDIChannelRouting)
		atomic_load_explicit(&gChannelRouting, memory_order_acquire);
	switch (routing) {
		case MADMIDIChannelRoutingInstrument: return (uint8_t)(instrument < 0 ? 0 : instrument) & 0x0F;
		case MADMIDIChannelRoutingFixed:
			return (uint8_t)atomic_load_explicit(&gFixedChannel,
				memory_order_acquire) & 0x0F;
		case MADMIDIChannelRoutingTrack:
		default: return (uint8_t)(track < 0 ? 0 : track) & 0x0F;
	}
}

void MADMIDISendBytes(const uint8_t *bytes, size_t length)
{
	if (!MADMIDIOutputIsEnabled() || bytes == NULL || length == 0 || length > 256) return;
	MIDIPacketList packetList;
	MIDIPacket *packet = MIDIPacketListInit(&packetList);
	packet = MIDIPacketListAdd(&packetList, sizeof(packetList), packet, 0, length, bytes);
	if (packet != NULL) MIDISend(gMIDIOutputPort, gMIDIOutputDestination, &packetList);
}

void MADMIDISendNoteOn(uint8_t channel, uint8_t note, uint8_t velocity)
{
	uint8_t message[] = {(uint8_t)(0x90 | (channel & 0x0F)), (uint8_t)(note & 0x7F),
		(uint8_t)((velocity & 0x7F) == 0 ? 1 : (velocity & 0x7F))};
	MADMIDISendBytes(message, sizeof(message));
}

void MADMIDISendNoteOff(uint8_t channel, uint8_t note, uint8_t velocity)
{
	uint8_t message[] = {(uint8_t)(0x80 | (channel & 0x0F)), (uint8_t)(note & 0x7F),
		(uint8_t)(velocity & 0x7F)};
	MADMIDISendBytes(message, sizeof(message));
}

void MADMIDISendProgramIfNeeded(uint8_t channel, uint8_t program)
{
	channel &= 0x0F;
	program &= 0x7F;
	if (!gProgramChangesEnabled || gLastProgram[channel] == program) return;
	uint8_t message[] = {(uint8_t)(0xC0 | channel), program};
	MADMIDISendBytes(message, sizeof(message));
	gLastProgram[channel] = program;
}

void MADMIDISendAllNotesOff(void)
{
	if (!MADMIDIOutputIsEnabled()) return;
	for (uint8_t channel = 0; channel < 16; channel++) {
		uint8_t sustainOff[] = {(uint8_t)(0xB0 | channel), 64, 0};
		uint8_t allNotesOff[] = {(uint8_t)(0xB0 | channel), 123, 0};
		MADMIDISendBytes(sustainOff, sizeof(sustainOff));
		MADMIDISendBytes(allNotesOff, sizeof(allNotesOff));
	}
}

void InitMIDIHarware(void)
{
	MIDIHardware = true;
	MIDIHardwareAlreadyOpen = gMIDIClient != 0;
}

void OpenMIDIHardware(MADDriverRec *rec)
{
	(void)rec;
	if (gMIDIClient == 0) MADMIDIInitialize(NULL, NULL, NULL, NULL);
}

void CloseMIDIHarware(void)
{
	// The app owns the shared client. Switching PlayerPRO drivers must not tear
	// down live keyboard input or invalidate the Preferences endpoint lists.
}

void SendMIDIClock(MADDriverRec *driver, MADByte byte)
{
	(void)driver;
	if (!MADMIDIClockOutputIsEnabled()) return;
	uint8_t message = byte;
	MADMIDISendBytes(&message, 1);
}

void SendMIDITimingClock(MADDriverRec *driver)
{
	(void)driver;
	// F8 timing clocks are emitted by the tracker tick path. Song Position
	// Pointer will be added when transport seeking is made sample-accurate.
}

static void MADMIDINotifyProc(const MIDINotification *message, void *refCon)
{
	(void)refCon;
	if (message == NULL) return;
	bool endpointIdentityChanged = false;
	switch (message->messageID) {
		case kMIDIMsgSetupChanged:
		case kMIDIMsgObjectAdded:
		case kMIDIMsgObjectRemoved:
			endpointIdentityChanged = true;
			break;
		case kMIDIMsgPropertyChanged: {
			const MIDIObjectPropertyChangeNotification *change =
				(const MIDIObjectPropertyChangeNotification *)message;
			CFStringRef property = change->propertyName;
			endpointIdentityChanged = property != NULL &&
				(CFEqual(property, kMIDIPropertyUniqueID) ||
				 CFEqual(property, kMIDIPropertyName) ||
				 CFEqual(property, kMIDIPropertyDisplayName) ||
				 CFEqual(property, kMIDIPropertyOffline));
			break;
		}
		default:
			break;
	}
	if (!endpointIdentityChanged) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		// Do not tear down ports or replace the selected destination here.
		// Several virtual devices send setup/property notifications as their
		// first packets arrive. The endpoint reference remains valid, and
		// re-enumerating during that notification made the Preferences popup
		// turn into "Unavailable device" exactly when playback began.
		if (gDevicesChangedCallback != NULL) {
			gDevicesChangedCallback(gDevicesContext);
		}
	});
}

static void MADMIDIReadProc(const MIDIPacketList *packetList,
	void *readProcRefCon,
	void *sourceConnectionRefCon)
{
	(void)readProcRefCon;
	(void)sourceConnectionRefCon;
	if (!gInputEnabled || packetList == NULL) return;
	const MIDIPacket *packet = &packetList->packet[0];
	for (UInt32 packetIndex = 0; packetIndex < packetList->numPackets; packetIndex++) {
		for (UInt16 byteIndex = 0; byteIndex < packet->length; byteIndex++) {
			MADMIDIParseByte(packet->data[byteIndex]);
		}
		packet = MIDIPacketNext(packet);
	}
}
