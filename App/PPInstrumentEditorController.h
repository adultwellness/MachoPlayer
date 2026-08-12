#import <Cocoa/Cocoa.h>

#include "PlayerPROCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^PPInstrumentEditorHandler)(void);

/// The 2002 Instrument Info window: instrument envelope flags, editable sample
/// metadata, and the 96-note sample-assignment piano.
@interface PPInstrumentEditorController : NSWindowController

- (instancetype)initWithMusic:(MADMusic *)music
	driver:(MADDriverRec *)driver
	instrument:(NSInteger)instrument
	sample:(NSInteger)sample
	changeHandler:(PPInstrumentEditorHandler)changeHandler
	closeHandler:(PPInstrumentEditorHandler)closeHandler;

- (void)stopPreview;

@end

NS_ASSUME_NONNULL_END
