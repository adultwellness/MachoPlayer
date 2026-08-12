#import <Cocoa/Cocoa.h>

#include "MADDriver.h"

NS_ASSUME_NONNULL_BEGIN

#define PP_EQUALIZER_BAND_COUNT 8

/// Writes the original eight control points into PlayerPRO's 1025-bin FFT
/// filter and enables or bypasses the output equalizer.
void PPSetEqualizerBands(MADDriverRec * _Nullable driver,
	const double * _Nonnull bands, bool enabled);

@interface PPEqualizerController : NSWindowController
- (instancetype)initWithDriver:(MADDriverRec * _Nullable)driver;
- (void)attachDriver:(MADDriverRec * _Nullable)driver;
@end

NS_ASSUME_NONNULL_END
