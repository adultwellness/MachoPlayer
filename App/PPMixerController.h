#import <Cocoa/Cocoa.h>

#include "PlayerPROCore.h"

typedef void (^PPMixerReverbHandler)(BOOL enabled, NSInteger delayMilliseconds, NSInteger strength);

@interface PPMixerController : NSWindowController

@property(nonatomic, copy) PPMixerReverbHandler reverbHandler;

- (instancetype)initWithMusic:(MADMusic *)music driver:(MADDriverRec *)driver;
- (void)attachMusic:(MADMusic *)music driver:(MADDriverRec *)driver;
- (void)refreshFromDriver;

@end
