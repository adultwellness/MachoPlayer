#import <Cocoa/Cocoa.h>

#include "PlayerPROCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PPPatternEditorMode) {
	PPPatternEditorModeBox,
	PPPatternEditorModeClassical,
	PPPatternEditorModeClassicOverview,
	PPPatternEditorModeWave
};

typedef void (^PPPatternModeHandler)(void);

@interface PPPatternModeController : NSWindowController

- (instancetype)initWithMusic:(MADMusic *)music
	driver:(MADDriverRec *)driver
	pattern:(NSInteger)pattern
	instrument:(NSInteger)instrument
	mode:(PPPatternEditorMode)mode
	changeHandler:(PPPatternModeHandler)changeHandler
	closeHandler:(PPPatternModeHandler)closeHandler;

- (void)stopPreview;
- (void)reloadPreferences;

@end

NS_ASSUME_NONNULL_END
