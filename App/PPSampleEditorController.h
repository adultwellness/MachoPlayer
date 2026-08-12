#import <Cocoa/Cocoa.h>

#include "PlayerPROCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^PPSampleEditorHandler)(void);

@interface PPSampleEditorController : NSWindowController

- (instancetype)initWithMusic:(MADMusic *)music
	driver:(MADDriverRec *)driver
	instrument:(NSInteger)instrument
	sample:(NSInteger)sample
	changeHandler:(PPSampleEditorHandler)changeHandler
	closeHandler:(PPSampleEditorHandler)closeHandler;

- (void)stopPreview;

@end

/// Exercises the byte-accurate destructive editing primitives without opening UI.
FOUNDATION_EXPORT BOOL PPSampleRunEditingSelfTest(void);

NS_ASSUME_NONNULL_END
