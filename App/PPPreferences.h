#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const PPDriverSampleRateDefaultsKey;
extern NSString *const PPDriverOversamplingDefaultsKey;
extern NSString *const PPDriverMicroDelayDefaultsKey;
extern NSString *const PPDriverTickRemoverDefaultsKey;
extern NSString *const PPDriverSurroundDefaultsKey;
extern NSString *const PPDriverReverbEnabledDefaultsKey;
extern NSString *const PPDriverReverbDelayDefaultsKey;
extern NSString *const PPDriverReverbStrengthDefaultsKey;

extern NSString *const PPMusicListPlaybackModeDefaultsKey;
extern NSString *const PPMusicListRememberDefaultsKey;
extern NSString *const PPMusicListLoadFirstDefaultsKey;
extern NSString *const PPMusicListReturnToStartDefaultsKey;
extern NSString *const PPMusicListAutoPlayDefaultsKey;
extern NSString *const PPMusicListSavedPathsDefaultsKey;

extern NSString *const PPAutomaticCompressionDefaultsKey;
extern NSString *const PPAddFileExtensionDefaultsKey;
extern NSString *const PPOscilloscopeLinesDefaultsKey;
extern NSString *const PPPreferredPatternEditorDefaultsKey;

extern NSString *const PPDigitalStepDefaultsKey;
extern NSString *const PPDigitalOctaveDefaultsKey;
extern NSString *const PPDigitalTraceDefaultsKey;
extern NSString *const PPDigitalFieldGuidesDefaultsKey;
extern NSString *const PPDigitalRowGuidesDefaultsKey;

extern NSString *const PPBoxZoomDefaultsKey;
extern NSString *const PPBoxOctaveMarkersDefaultsKey;
extern NSString *const PPBoxAuditionDefaultsKey;
extern NSString *const PPBoxTimeBandsDefaultsKey;

extern NSString *const PPClassicalZoomDefaultsKey;
extern NSString *const PPClassicalStaffGuidesDefaultsKey;
extern NSString *const PPClassicalAuditionDefaultsKey;

extern NSString *const PPPianoMacKeyboardDefaultsKey;
extern NSString *const PPPianoKeyUpModeDefaultsKey;
extern NSString *const PPPianoSmallViewDefaultsKey;
extern NSString *const PPPianoOctaveMarkersDefaultsKey;
extern NSString *const PPPianoRecordingModeDefaultsKey;
extern NSString *const PPPianoRecordingTrackDefaultsKey;
extern NSString *const PPPianoKeyMapDefaultsKey;

extern NSString *const PPMIDIInputEnabledDefaultsKey;
extern NSString *const PPMIDIInputSourceDefaultsKey;
extern NSString *const PPMIDIInputSourceNameDefaultsKey;
extern NSString *const PPMIDIInputChannelDefaultsKey;
extern NSString *const PPMIDIVelocityDefaultsKey;
extern NSString *const PPMIDIChannelMappingDefaultsKey;
extern NSString *const PPMIDIRecordNoteOffDefaultsKey;
extern NSString *const PPMIDIOutputEnabledDefaultsKey;
extern NSString *const PPMIDIOutputDestinationDefaultsKey;
extern NSString *const PPMIDIOutputDestinationNameDefaultsKey;
extern NSString *const PPMIDIAuditionOutputDefaultsKey;
extern NSString *const PPMIDIThruDefaultsKey;
extern NSString *const PPMIDIPlaybackOutputDefaultsKey;
extern NSString *const PPMIDIOutputRoutingDefaultsKey;
extern NSString *const PPMIDIOutputChannelDefaultsKey;
extern NSString *const PPMIDIProgramChangesDefaultsKey;
extern NSString *const PPMIDIClockDefaultsKey;

extern NSString *const PPFKeyActionsDefaultsKey;
extern NSString *const PPTrackColorsDefaultsKey;

NSDictionary<NSString *, id> *PPPreferenceDefaultValues(void);
NSArray<NSColor *> *PPDefaultTrackColors(void);
NSArray<NSColor *> *PPPreferredTrackColors(void);
NSColor *PPPreferredTrackColor(NSInteger track);
void PPStorePreferredTrackColors(NSArray<NSColor *> *colors);
NSArray<NSString *> *PPDefaultPianoKeyMap(void);
NSArray<NSString *> *PPPreferredPianoKeyMap(void);

NS_ASSUME_NONNULL_END
