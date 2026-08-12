#import "PPPreferences.h"

#include "PlayerPROCore.h"

NSString *const PPDriverSampleRateDefaultsKey = @"DriverOutputSampleRate";
NSString *const PPDriverOversamplingDefaultsKey = @"DriverOutputOversampling";
NSString *const PPDriverMicroDelayDefaultsKey = @"DriverStereoDelayMilliseconds";
NSString *const PPDriverTickRemoverDefaultsKey = @"DriverTickRemover";
NSString *const PPDriverSurroundDefaultsKey = @"DriverSurround";
NSString *const PPDriverReverbEnabledDefaultsKey = @"DriverReverbEnabled";
NSString *const PPDriverReverbDelayDefaultsKey = @"DriverReverbDelay";
NSString *const PPDriverReverbStrengthDefaultsKey = @"DriverReverbStrength";

NSString *const PPMusicListPlaybackModeDefaultsKey = @"MusicListPlaybackMode";
NSString *const PPMusicListRememberDefaultsKey = @"MusicListRememberForNextLaunch";
NSString *const PPMusicListLoadFirstDefaultsKey = @"MusicListLoadFirstWhenOpened";
NSString *const PPMusicListReturnToStartDefaultsKey = @"MusicListReturnToStartWhenDone";
NSString *const PPMusicListAutoPlayDefaultsKey = @"MusicListAutomaticPlayAfterOpening";
NSString *const PPMusicListSavedPathsDefaultsKey = @"MusicListRememberedPaths";

NSString *const PPAutomaticCompressionDefaultsKey = @"AutomaticMAD1Compression";
NSString *const PPAddFileExtensionDefaultsKey = @"AddExtensionToFileNames";
NSString *const PPOscilloscopeLinesDefaultsKey = @"OscilloscopeDrawLines";
NSString *const PPPreferredPatternEditorDefaultsKey = @"PreferredPatternEditor";

NSString *const PPDigitalStepDefaultsKey = @"DigitalEditorDefaultStep";
NSString *const PPDigitalOctaveDefaultsKey = @"DigitalEditorDefaultOctave";
NSString *const PPDigitalTraceDefaultsKey = @"DigitalEditorTracePlayback";
NSString *const PPDigitalFieldGuidesDefaultsKey = @"DigitalEditorFieldGuides";
NSString *const PPDigitalRowGuidesDefaultsKey = @"DigitalEditorRowGuides";

NSString *const PPBoxZoomDefaultsKey = @"BoxEditorDefaultZoom";
NSString *const PPBoxOctaveMarkersDefaultsKey = @"BoxEditorOctaveMarkers";
NSString *const PPBoxAuditionDefaultsKey = @"BoxEditorAuditionNotes";
NSString *const PPBoxTimeBandsDefaultsKey = @"BoxEditorTimeBands";

NSString *const PPClassicalZoomDefaultsKey = @"ClassicalEditorDefaultZoom";
NSString *const PPClassicalStaffGuidesDefaultsKey = @"ClassicalEditorStaffGuides";
NSString *const PPClassicalAuditionDefaultsKey = @"ClassicalEditorAuditionNotes";

NSString *const PPPianoMacKeyboardDefaultsKey = @"PianoUseMacKeyboard";
NSString *const PPPianoKeyUpModeDefaultsKey = @"PianoKeyUpMode";
NSString *const PPPianoSmallViewDefaultsKey = @"PianoSmallView";
NSString *const PPPianoOctaveMarkersDefaultsKey = @"PianoOctaveMarkers";
NSString *const PPPianoRecordingModeDefaultsKey = @"PianoRecordingTrackMode";
NSString *const PPPianoRecordingTrackDefaultsKey = @"PianoRecordingTrack";
NSString *const PPPianoKeyMapDefaultsKey = @"PianoKeyMap";

NSString *const PPMIDIInputEnabledDefaultsKey = @"MIDIInputEnabled";
NSString *const PPMIDIInputSourceDefaultsKey = @"MIDIInputSourceUniqueID";
NSString *const PPMIDIInputSourceNameDefaultsKey = @"MIDIInputSourceName";
NSString *const PPMIDIInputChannelDefaultsKey = @"MIDIInputChannel";
NSString *const PPMIDIVelocityDefaultsKey = @"MIDIVelocityControlsVolume";
NSString *const PPMIDIChannelMappingDefaultsKey = @"MIDIChannelControlsInstrumentAndTrack";
NSString *const PPMIDIRecordNoteOffDefaultsKey = @"MIDIRecordNoteOff";
NSString *const PPMIDIOutputEnabledDefaultsKey = @"MIDIOutputEnabled";
NSString *const PPMIDIOutputDestinationDefaultsKey = @"MIDIOutputDestinationUniqueID";
NSString *const PPMIDIOutputDestinationNameDefaultsKey = @"MIDIOutputDestinationName";
NSString *const PPMIDIAuditionOutputDefaultsKey = @"MIDIAuditionOutput";
NSString *const PPMIDIThruDefaultsKey = @"MIDIInputThru";
NSString *const PPMIDIPlaybackOutputDefaultsKey = @"MIDIPlaybackOutput";
NSString *const PPMIDIOutputRoutingDefaultsKey = @"MIDIOutputChannelRouting";
NSString *const PPMIDIOutputChannelDefaultsKey = @"MIDIOutputFixedChannel";
NSString *const PPMIDIProgramChangesDefaultsKey = @"MIDIOutputProgramChanges";
NSString *const PPMIDIClockDefaultsKey = @"MIDIOutputClock";

NSString *const PPFKeyActionsDefaultsKey = @"FunctionKeyActions";
NSString *const PPTrackColorsDefaultsKey = @"TrackColors";

static NSArray<NSString *> *PPDefaultTrackColorStrings(void)
{
	// The original editors identified tracks with saturated color chips rather
	// than the later pastel header treatment: red, green, cyan and yellow for
	// the first four tracks. Keep the extended palette for modern multichannel
	// songs while preserving that repeating visual language.
	return @[@"FF1414", @"7DC40A", @"1AE0E0", @"FFE80A",
		@"A645E8", @"FF7A14", @"2E6EFF", @"FF47A3"];
}

NSArray<NSString *> *PPDefaultPianoKeyMap(void)
{
	static NSArray<NSString *> *mapping;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableArray<NSString *> *notes = [NSMutableArray arrayWithCapacity:NUMBER_NOTES];
		for (NSInteger note = 0; note < NUMBER_NOTES; note++) [notes addObject:@""];
		NSArray<NSString *> *keys = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"0",
			@"q", @"w", @"e", @"r", @"t", @"z", @"u", @"i", @"o", @"p",
			@"a", @"s", @"d", @"f", @"g", @"h", @"j", @"k", @"l",
			@"y", @"x", @"c", @"v", @"b", @"n", @"m",
			@"Q", @"W", @"E", @"R", @"T", @"Z", @"U", @"I", @"O", @"P",
			@"A", @"S", @"D", @"F", @"G", @"H", @"J", @"K", @"L",
			@"Y", @"X", @"C", @"V", @"B", @"N", @"M"];
		for (NSInteger index = 0; index < (NSInteger)keys.count && 24 + index < NUMBER_NOTES; index++) {
			notes[(NSUInteger)(24 + index)] = keys[(NSUInteger)index];
		}
		mapping = notes.copy;
	});
	return mapping;
}

NSArray<NSString *> *PPPreferredPianoKeyMap(void)
{
	NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:PPPianoKeyMapDefaultsKey];
	if (stored.count != NUMBER_NOTES) return PPDefaultPianoKeyMap();
	NSMutableSet<NSString *> *used = [NSMutableSet set];
	for (id value in stored) {
		if (![value isKindOfClass:NSString.class] || [(NSString *)value length] > 1) {
			return PPDefaultPianoKeyMap();
		}
		if ([(NSString *)value length] > 0) {
			if ([used containsObject:value]) return PPDefaultPianoKeyMap();
			[used addObject:value];
		}
	}
	return (NSArray<NSString *> *)stored;
}

NSDictionary<NSString *, id> *PPPreferenceDefaultValues(void)
{
	return @{
		PPDriverSampleRateDefaultsKey: @44100,
		PPDriverOversamplingDefaultsKey: @1,
		PPDriverMicroDelayDefaultsKey: @25,
		PPDriverTickRemoverDefaultsKey: @NO,
		PPDriverSurroundDefaultsKey: @NO,
		PPDriverReverbEnabledDefaultsKey: @NO,
		PPDriverReverbDelayDefaultsKey: @100,
		PPDriverReverbStrengthDefaultsKey: @20,
		PPMusicListPlaybackModeDefaultsKey: @0,
		PPMusicListRememberDefaultsKey: @YES,
		PPMusicListLoadFirstDefaultsKey: @NO,
		PPMusicListReturnToStartDefaultsKey: @NO,
		PPMusicListAutoPlayDefaultsKey: @NO,
		PPMusicListSavedPathsDefaultsKey: @[],
		PPAutomaticCompressionDefaultsKey: @YES,
		PPAddFileExtensionDefaultsKey: @YES,
		PPOscilloscopeLinesDefaultsKey: @YES,
		PPPreferredPatternEditorDefaultsKey: @"digital",
		PPDigitalStepDefaultsKey: @1,
		PPDigitalOctaveDefaultsKey: @0,
		PPDigitalTraceDefaultsKey: @YES,
		PPDigitalFieldGuidesDefaultsKey: @YES,
		PPDigitalRowGuidesDefaultsKey: @YES,
		PPBoxZoomDefaultsKey: @1,
		PPBoxOctaveMarkersDefaultsKey: @YES,
		PPBoxAuditionDefaultsKey: @YES,
		PPBoxTimeBandsDefaultsKey: @YES,
		PPClassicalZoomDefaultsKey: @1,
		PPClassicalStaffGuidesDefaultsKey: @YES,
		PPClassicalAuditionDefaultsKey: @YES,
		PPPianoMacKeyboardDefaultsKey: @YES,
		PPPianoKeyUpModeDefaultsKey: @1,
		PPPianoSmallViewDefaultsKey: @NO,
		PPPianoOctaveMarkersDefaultsKey: @YES,
		PPPianoRecordingModeDefaultsKey: @1,
		PPPianoRecordingTrackDefaultsKey: @0,
		PPPianoKeyMapDefaultsKey: PPDefaultPianoKeyMap(),
		PPMIDIInputEnabledDefaultsKey: @NO,
		PPMIDIInputSourceDefaultsKey: @0,
		PPMIDIInputSourceNameDefaultsKey: @"",
		PPMIDIInputChannelDefaultsKey: @0,
		PPMIDIVelocityDefaultsKey: @YES,
		PPMIDIChannelMappingDefaultsKey: @NO,
		PPMIDIRecordNoteOffDefaultsKey: @NO,
		PPMIDIOutputEnabledDefaultsKey: @NO,
		PPMIDIOutputDestinationDefaultsKey: @(-2147483648LL),
		PPMIDIOutputDestinationNameDefaultsKey: @"",
		PPMIDIAuditionOutputDefaultsKey: @YES,
		PPMIDIThruDefaultsKey: @NO,
		PPMIDIPlaybackOutputDefaultsKey: @YES,
		PPMIDIOutputRoutingDefaultsKey: @0,
		PPMIDIOutputChannelDefaultsKey: @0,
		PPMIDIProgramChangesDefaultsKey: @YES,
		PPMIDIClockDefaultsKey: @NO,
		PPFKeyActionsDefaultsKey: @[@"none", @"none", @"none", @"none", @"none", @"none",
			@"none", @"none", @"none", @"none", @"none", @"none"],
		PPTrackColorsDefaultsKey: PPDefaultTrackColorStrings()
	};
}

static NSColor *PPColorFromString(NSString *string)
{
	if (![string isKindOfClass:NSString.class] || string.length != 6) return nil;
	unsigned int value = 0;
	NSScanner *scanner = [NSScanner scannerWithString:string];
	if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
	return [NSColor colorWithCalibratedRed:((value >> 16) & 0xFF) / 255.0
		green:((value >> 8) & 0xFF) / 255.0 blue:(value & 0xFF) / 255.0 alpha:1.0];
}

static NSString *PPStringFromColor(NSColor *color)
{
	NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: color;
	NSInteger red = (NSInteger)llround(MIN(MAX(rgb.redComponent, 0.0), 1.0) * 255.0);
	NSInteger green = (NSInteger)llround(MIN(MAX(rgb.greenComponent, 0.0), 1.0) * 255.0);
	NSInteger blue = (NSInteger)llround(MIN(MAX(rgb.blueComponent, 0.0), 1.0) * 255.0);
	return [NSString stringWithFormat:@"%02lX%02lX%02lX", (long)red, (long)green, (long)blue];
}

NSArray<NSColor *> *PPDefaultTrackColors(void)
{
	NSMutableArray<NSColor *> *colors = [NSMutableArray array];
	for (NSString *string in PPDefaultTrackColorStrings()) {
		[colors addObject:PPColorFromString(string) ?: NSColor.controlAccentColor];
	}
	return colors;
}

NSArray<NSColor *> *PPPreferredTrackColors(void)
{
	NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:PPTrackColorsDefaultsKey];
	// A previous modern build accidentally persisted the white control-surface
	// colors instead of the eight track chips. Treat that exact palette as an
	// obsolete default so existing installations regain the original colors;
	// genuine user palettes remain untouched.
	NSArray *legacyNearWhitePalette = @[@"FDFDFF", @"FDFDFD", @"FFFDFD", @"FFFDFD",
		@"FDFDFF", @"FDFDFD", @"FFFDFD", @"FDFDFD"];
	if ([stored isEqualToArray:legacyNearWhitePalette]) stored = nil;
	NSMutableArray<NSColor *> *colors = [NSMutableArray array];
	for (id value in stored) {
		NSColor *color = PPColorFromString(value);
		if (color != nil) [colors addObject:color];
	}
	return colors.count > 0 ? colors : PPDefaultTrackColors();
}

NSColor *PPPreferredTrackColor(NSInteger track)
{
	NSArray<NSColor *> *colors = PPPreferredTrackColors();
	return colors[(NSUInteger)MAX(track, 0) % colors.count];
}

void PPStorePreferredTrackColors(NSArray<NSColor *> *colors)
{
	NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithCapacity:colors.count];
	for (NSColor *color in colors) [strings addObject:PPStringFromColor(color)];
	[NSUserDefaults.standardUserDefaults setObject:strings forKey:PPTrackColorsDefaultsKey];
}
