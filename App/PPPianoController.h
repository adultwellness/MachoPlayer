#import <Cocoa/Cocoa.h>

#include "PlayerPROCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^PPPianoRecordHandler)(NSInteger note, NSInteger track, BOOL livePlayback);
typedef void (^PPPianoStatusHandler)(NSString *status);
typedef void (^PPPianoOctaveHandler)(NSInteger octave);
typedef void (^PPPianoMIDIOutputHandler)(NSInteger note, NSInteger track,
	NSInteger instrument, NSInteger velocity, BOOL began);

/// Regression coverage for the Piano's non-destructive reserved audition voice.
BOOL PPPianoRunPreviewOwnershipSelfTest(void);

/// The original PlayerPRO Piano: a scrollable, labeled 96-note audition and
/// recording window with both the 2002 large strip and compact keyboard modes.
@interface PPPianoController : NSWindowController

- (instancetype)initWithRecordHandler:(PPPianoRecordHandler)recordHandler
	statusHandler:(PPPianoStatusHandler)statusHandler
	octaveHandler:(PPPianoOctaveHandler)octaveHandler
	midiOutputHandler:(PPPianoMIDIOutputHandler)midiOutputHandler;
- (void)attachMusic:(MADMusic * _Nullable)music driver:(MADDriverRec * _Nullable)driver
	selectedInstrument:(NSInteger)instrument selectedTrack:(NSInteger)track;
- (void)setSelectedInstrument:(NSInteger)instrument selectedTrack:(NSInteger)track;
- (void)setKeyboardOffset:(NSInteger)octaveOffset;
- (void)setRecordingEnabled:(BOOL)enabled;
- (void)reloadPreferences;
- (void)updatePlaybackHighlights;
- (void)stopPreview;
- (BOOL)auditionNote:(NSInteger)note velocity:(NSInteger)velocity
	instrument:(NSInteger)instrument track:(NSInteger)track;
- (void)handleMIDINoteOn:(NSInteger)note velocity:(NSInteger)velocity
	instrument:(NSInteger)instrument track:(NSInteger)track;
- (void)handleMIDINoteOff:(NSInteger)note track:(NSInteger)track;
- (void)handleMIDINoteOff:(NSInteger)note track:(NSInteger)track stopVoice:(BOOL)stopVoice;

@property(nonatomic, readonly, getter=isRecordingEnabled) BOOL recordingEnabled;

@end

NS_ASSUME_NONNULL_END
