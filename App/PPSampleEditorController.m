#import "PPSampleEditorController.h"
#import "PPFreeverbDSP.h"

#include <limits.h>
#include <math.h>
#include <time.h>
#include "RDriverInt.h"

static NSPasteboardType const PPSamplePasteboardType = @"com.quadmation.playerpro.sample-pcm";
static NSPasteboardType const PPEnvelopePasteboardType = @"com.quadmation.playerpro.instrument-envelope";
static NSInteger const PPVolumeEnvelopeMode = -1;
static NSInteger const PPPanningEnvelopeMode = -2;
static NSInteger const PPEnvelopeLength = 300;

typedef NS_ENUM(NSInteger, PPSampleTool) {
	PPSampleToolSelect = 0,
	PPSampleToolPencil,
	PPSampleToolZoom
};

/// A continuous slider with the single unity-gain notch used by Saturator.
/// The notch is visual only: values remain freely selectable between 0 and 10.
@interface PPSaturatorSlider : NSSlider
@end

@interface PPFreeverbControlView : NSView
@property(nonatomic, strong) NSArray<NSSlider *> *sliders;
@property(nonatomic, strong) NSArray<NSTextField *> *valueFields;
- (PPFreeverbParameters)parameters;
@end

@interface PPEQ3ControlView : NSView
@property(nonatomic, strong) NSArray<NSSlider *> *sliders;
@property(nonatomic, strong) NSArray<NSTextField *> *valueFields;
@property(nonatomic, strong) NSSlider *lowFrequencySlider;
@property(nonatomic, strong) NSSlider *highFrequencySlider;
@property(nonatomic, strong) NSArray<NSTextField *> *frequencyValueFields;
@property(nonatomic, readonly) double lowGainDecibels;
@property(nonatomic, readonly) double midGainDecibels;
@property(nonatomic, readonly) double highGainDecibels;
@property(nonatomic, readonly) double lowCrossoverHertz;
@property(nonatomic, readonly) double highCrossoverHertz;
- (instancetype)initWithFrame:(NSRect)frame sampleRate:(double)sampleRate;
@end

@implementation PPEQ3ControlView

- (instancetype)initWithFrame:(NSRect)frame sampleRate:(double)sampleRate
{
	self = [super initWithFrame:frame];
	if (self == nil) return nil;
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSArray<NSString *> *names = @[@"Low gain", @"Mid gain", @"High gain"];
	NSMutableArray<NSSlider *> *sliders = [NSMutableArray arrayWithCapacity:names.count];
	NSMutableArray<NSTextField *> *values = [NSMutableArray arrayWithCapacity:names.count];
	for (NSInteger band = 0; band < (NSInteger)names.count; band++) {
		CGFloat y = NSHeight(frame) - 27.0 - band * 29.0;
		NSTextField *label = [NSTextField labelWithString:names[band]];
		label.frame = NSMakeRect(0, y + 2, 82, 18);
		label.font = font;
		label.textColor = NSColor.blackColor;
		[self addSubview:label];
		NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(86, y, 205, 20)];
		slider.minValue = -12.0;
		slider.maxValue = 12.0;
		slider.doubleValue = 0.0;
		slider.numberOfTickMarks = 5;
		slider.allowsTickMarkValuesOnly = NO;
		slider.continuous = YES;
		slider.tag = band;
		slider.target = self;
		slider.action = @selector(updateValueLabels:);
		slider.accessibilityLabel = [names[band] stringByAppendingString:@" gain"];
		[self addSubview:slider];
		[sliders addObject:slider];
		NSTextField *value = [NSTextField labelWithString:@"+0.0 dB"];
		value.frame = NSMakeRect(296, y + 2, 64, 18);
		value.font = font;
		value.alignment = NSTextAlignmentRight;
		value.textColor = NSColor.blackColor;
		value.accessibilityLabel = [names[band] stringByAppendingString:@" gain value"];
		[self addSubview:value];
		[values addObject:value];
	}
	self.sliders = sliders.copy;
	self.valueFields = values.copy;

	double nyquist = MAX(sampleRate * 0.5, 2.0);
	double minimumFrequency = 1.0;
	double maximumFrequency = MAX(nyquist * 0.95, minimumFrequency * 1.1);
	double lowDefault = MIN(250.0, maximumFrequency * 0.35);
	double highDefault = MIN(4000.0, maximumFrequency * 0.85);
	highDefault = MIN(MAX(highDefault, lowDefault * 1.5), maximumFrequency);
	if (lowDefault >= highDefault) lowDefault = MAX(minimumFrequency, highDefault * 0.5);
	NSArray<NSString *> *frequencyNames = @[@"Low / Mid", @"Mid / High"];
	NSMutableArray<NSTextField *> *frequencyValues = [NSMutableArray arrayWithCapacity:2];
	for (NSInteger crossover = 0; crossover < 2; crossover++) {
		CGFloat y = NSHeight(frame) - 27.0 - (crossover + 3) * 29.0;
		NSTextField *label = [NSTextField labelWithString:frequencyNames[crossover]];
		label.frame = NSMakeRect(0, y + 2, 82, 18);
		label.font = font;
		label.textColor = NSColor.blackColor;
		[self addSubview:label];
		NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(86, y, 205, 20)];
		slider.minValue = log10(minimumFrequency);
		slider.maxValue = log10(maximumFrequency);
		slider.doubleValue = log10(crossover == 0 ? lowDefault : highDefault);
		slider.continuous = YES;
		slider.target = self;
		slider.action = @selector(updateValueLabels:);
		slider.accessibilityLabel = [frequencyNames[crossover] stringByAppendingString:@" crossover"];
		[self addSubview:slider];
		NSTextField *value = [NSTextField labelWithString:@""];
		value.frame = NSMakeRect(296, y + 2, 64, 18);
		value.font = font;
		value.alignment = NSTextAlignmentRight;
		value.textColor = NSColor.blackColor;
		[self addSubview:value];
		[frequencyValues addObject:value];
		if (crossover == 0) self.lowFrequencySlider = slider;
		else self.highFrequencySlider = slider;
	}
	self.frequencyValueFields = frequencyValues.copy;
	[self updateValueLabels:nil];
	return self;
}

- (void)updateValueLabels:(id)sender
{
	for (NSInteger band = 0; band < (NSInteger)self.sliders.count; band++) {
		self.valueFields[band].stringValue = [NSString stringWithFormat:@"%+.1f dB", self.sliders[band].doubleValue];
		self.sliders[band].accessibilityValueDescription = self.valueFields[band].stringValue;
	}
	const double minimumGap = 0.025;
	if (sender == self.lowFrequencySlider &&
		self.lowFrequencySlider.doubleValue >= self.highFrequencySlider.doubleValue - minimumGap) {
		self.highFrequencySlider.doubleValue = MIN(self.lowFrequencySlider.doubleValue + minimumGap,
			self.highFrequencySlider.maxValue);
		self.lowFrequencySlider.doubleValue = MIN(self.lowFrequencySlider.doubleValue,
			self.highFrequencySlider.doubleValue - minimumGap);
	} else if (sender == self.highFrequencySlider &&
		self.highFrequencySlider.doubleValue <= self.lowFrequencySlider.doubleValue + minimumGap) {
		self.lowFrequencySlider.doubleValue = MAX(self.highFrequencySlider.doubleValue - minimumGap,
			self.lowFrequencySlider.minValue);
		self.highFrequencySlider.doubleValue = MAX(self.highFrequencySlider.doubleValue,
			self.lowFrequencySlider.doubleValue + minimumGap);
	}
	double frequencies[] = {self.lowCrossoverHertz, self.highCrossoverHertz};
	for (NSInteger crossover = 0; crossover < 2; crossover++) {
		NSString *value = frequencies[crossover] >= 1000.0
			? [NSString stringWithFormat:@"%.2f kHz", frequencies[crossover] / 1000.0]
			: [NSString stringWithFormat:@"%.0f Hz", frequencies[crossover]];
		self.frequencyValueFields[crossover].stringValue = value;
		(crossover == 0 ? self.lowFrequencySlider : self.highFrequencySlider).accessibilityValueDescription = value;
	}
}

- (double)lowGainDecibels { return self.sliders[0].doubleValue; }
- (double)midGainDecibels { return self.sliders[1].doubleValue; }
- (double)highGainDecibels { return self.sliders[2].doubleValue; }
- (double)lowCrossoverHertz { return pow(10.0, self.lowFrequencySlider.doubleValue); }
- (double)highCrossoverHertz { return pow(10.0, self.highFrequencySlider.doubleValue); }

@end

@implementation PPFreeverbControlView

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self == nil) return nil;
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSArray<NSString *> *names = @[@"Room size", @"Damping", @"Predelay", @"Lowpass", @"Highpass", @"Wet level", @"Dry level"];
	double minimums[] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
	double maximums[] = {1.0, 1.0, 500.0, 100.0, 100.0, 1.0, 1.0};
	double defaults[] = {0.5, 0.5, 0.0, 100.0, 0.0, 1.0 / 3.0, 0.0};
	NSMutableArray<NSSlider *> *sliders = [NSMutableArray arrayWithCapacity:names.count];
	NSMutableArray<NSTextField *> *fields = [NSMutableArray arrayWithCapacity:names.count];
	for (NSInteger row = 0; row < (NSInteger)names.count; row++) {
		CGFloat y = NSHeight(frame) - 27.0 - row * 27.0;
		NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, y, 230, 20)];
		slider.minValue = minimums[row]; slider.maxValue = maximums[row]; slider.doubleValue = defaults[row];
		slider.continuous = YES; slider.target = self; slider.action = @selector(updateValueLabels:);
		slider.tag = row; slider.accessibilityLabel = names[row];
		[self addSubview:slider]; [sliders addObject:slider];
		NSTextField *value = [NSTextField labelWithString:@""];
		value.frame = NSMakeRect(246, y + 2, 205, 18); value.font = font;
		value.textColor = NSColor.blackColor; value.accessibilityLabel = [names[row] stringByAppendingString:@" value"];
		[self addSubview:value]; [fields addObject:value];
	}
	self.sliders = sliders.copy;
	self.valueFields = fields.copy;
	[self updateValueLabels:nil];
	return self;
}

- (void)updateValueLabels:(id)sender
{
	(void)sender;
	double roomFeedback = 0.7 + self.sliders[0].doubleValue * 0.28;
	self.valueFields[0].stringValue = [NSString stringWithFormat:@"Room size: %.6f size", roomFeedback];
	self.valueFields[1].stringValue = [NSString stringWithFormat:@"Damping: %.0f %%", self.sliders[1].doubleValue * 100.0];
	self.valueFields[2].stringValue = [NSString stringWithFormat:@"Predelay: %.0f msec", self.sliders[2].doubleValue];
	self.valueFields[3].stringValue = [NSString stringWithFormat:@"Lowpass: %.0f %%", 100.0 - self.sliders[3].doubleValue];
	self.valueFields[4].stringValue = [NSString stringWithFormat:@"Highpass: %.0f %%", self.sliders[4].doubleValue];
	for (NSInteger row = 5; row <= 6; row++) {
		double gain = self.sliders[row].doubleValue * (row == 5 ? 3.0 : 2.0);
		NSString *level = gain <= 0.0 ? @"−∞" : [NSString stringWithFormat:@"%.6f", 20.0 * log10(gain)];
		self.valueFields[row].stringValue = [NSString stringWithFormat:@"%@: %@ dB", row == 5 ? @"Wet level" : @"Dry level", level];
	}
}

- (PPFreeverbParameters)parameters
{
	return (PPFreeverbParameters){
		.roomSize = self.sliders[0].doubleValue,
		.damping = self.sliders[1].doubleValue,
		.predelayMilliseconds = self.sliders[2].doubleValue,
		.lowpassPercent = 100.0 - self.sliders[3].doubleValue,
		.highpassPercent = self.sliders[4].doubleValue,
		.wetDecibels = 20.0 * log10(MAX(self.sliders[5].doubleValue * 3.0, 0.001)),
		.dryDecibels = self.sliders[6].doubleValue <= 0.0 ? -60.0 :
			20.0 * log10(self.sliders[6].doubleValue * 2.0)
	};
}

@end

@implementation PPSaturatorSlider
- (void)drawRect:(NSRect)dirtyRect
{
	[super drawRect:dirtyRect];
	CGFloat inset = 7.0;
	CGFloat unityX = inset + (NSWidth(self.bounds) - inset * 2.0) / 10.0;
	[[NSColor colorWithCalibratedWhite:0.22 alpha:0.95] setFill];
	NSRectFill(NSMakeRect(floor(unityX), 1.0, 1.0, 6.0));
	[[NSColor colorWithCalibratedWhite:1.0 alpha:0.75] setFill];
	NSRectFill(NSMakeRect(floor(unityX) + 1.0, 1.0, 1.0, 6.0));
}
@end

static NSInteger const PPHzFilterPointCount = 1025;
static double PPHzFilterGains[1025];
static double PPHzShiftDestinations[1025];
static BOOL PPHzFilterLogarithmic = YES;
static BOOL PPHzFilterPreviewEnabled = YES;

typedef struct {
	BOOL useOctaveAndTone;
	double frequencyHertz;
	NSInteger octave;
	NSInteger tone;
	double toneAmplitudePermille;
	NSInteger formantCount;
	double lastFormantAmplitudePermille;
	double frequencyScalePermille;
	double frequencyAdditionHertz;
	double amplitudeScalePermille;
	BOOL chorusEnabled[4];
	double chorusFrequencyPermille[4];
	double chorusAmplitudePermille[4];
	double globalAmplitudePermille;
} PPAddotrophParameters;

typedef struct {
	NSInteger frequencyHertz;
	double horizontalPercent;
	double verticalPercent;
} PPAderodhiecusParameters;

typedef NS_ENUM(NSInteger, PPBetterFadeMode) {
	PPBetterFadeModeCustom = 1,
	PPBetterFadeModeDown = 2,
	PPBetterFadeModeUp = 3
};

typedef struct {
	NSInteger fromPercent;
	NSInteger toPercent;
	PPBetterFadeMode mode;
} PPBetterFadeParameters;

typedef NS_ENUM(NSInteger, PPConvolveImpulseMode) {
	PPConvolveImpulseSelection = 1,
	PPConvolveImpulseHighPass = 2,
	PPConvolveImpulseLowPass = 3
};

typedef struct {
	BOOL wrapEdges;
	BOOL normalizeImpulse;
	BOOL normalizeToSumOne;
	BOOL includeTail;
	PPConvolveImpulseMode impulseMode;
	NSInteger cutoffHertz;
	double gain;
	double quality;
} PPConvolveParameters;

typedef struct {
	double grainLengthPosition;
	double grainCountPosition;
} PPStardustParameters;

typedef NS_ENUM(NSInteger, PPIIRFilterMode) {
	PPIIRFilterHighPass = 1,
	PPIIRFilterLowPass = 2
};

typedef struct {
	PPIIRFilterMode mode;
	NSInteger startFrequency;
	NSInteger endFrequency;
	BOOL sweepFrequency;
	BOOL wrapAround;
	BOOL repeatEnabled;
	NSInteger repeatCount;
} PPIIRFilterParameters;

typedef NS_ENUM(NSInteger, PPNoiseMode) {
	PPNoiseModeWhite = 1,
	PPNoiseModeGaussian = 2,
	PPNoiseModeRing = 3,
	PPNoiseModeFrequency = 4
};

typedef struct {
	PPNoiseMode mode;
	NSInteger ringComponentCount;
	NSInteger ringMinimumHertz;
	NSInteger ringMaximumHertz;
	NSInteger frequencyBPM;
	NSInteger frequencyMinimumHertz;
	NSInteger frequencyMaximumHertz;
} PPNoiseParameters;

typedef NS_ENUM(NSInteger, PPRingModulateMode) {
	PPRingModulateModeRing = 1,
	PPRingModulateModeDeRing = 2,
	PPRingModulateModeAmplitude = 3
};

typedef NS_ENUM(NSInteger, PPRingFrequencySource) {
	PPRingFrequencyRampUp = 1,
	PPRingFrequencyRampDown = 2,
	PPRingFrequencySine = 3,
	PPRingFrequencySample = 4,
	PPRingFrequencyEnvelope = 5
};

typedef NS_ENUM(NSInteger, PPRingWaveShape) {
	PPRingWaveSine = 0,
	PPRingWaveTriangle = 1,
	PPRingWaveSaw = 2,
	PPRingWaveSquare = 3
};

typedef struct {
	PPRingModulateMode mode;
	NSInteger frequencyHertz;
	NSInteger mixPercent;
	BOOL modulateFrequency;
	NSInteger modulationDepthHertz;
	PPRingFrequencySource frequencySource;
	NSInteger modulationRateHundredthHertz;
	PPRingWaveShape firstWave;
	PPRingWaveShape secondWave;
	BOOL morphWave;
	double envelopeSense;
} PPRingModulateParameters;

static PPRingModulateParameters *PPPersistentRingModulateParameters(void)
{
	static PPRingModulateParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Exact values created by RingModulation 1.1 when its 'pref' resource is absent.
		parameters.mode = PPRingModulateModeRing;
		parameters.frequencyHertz = 846;
		parameters.mixPercent = 100;
		parameters.modulateFrequency = NO;
		parameters.modulationDepthHertz = 12;
		parameters.frequencySource = PPRingFrequencyRampUp;
		parameters.modulationRateHundredthHertz = 100;
		parameters.firstWave = PPRingWaveSine;
		parameters.secondWave = PPRingWaveSine;
		parameters.morphWave = NO;
		parameters.envelopeSense = 0.999;
	});
	return &parameters;
}

static PPNoiseParameters *PPPersistentNoiseParameters(void)
{
	static PPNoiseParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Exact values created by the 2002 plug-in when no 'pref' resource exists.
		parameters.mode = PPNoiseModeRing;
		parameters.ringComponentCount = 20;
		parameters.ringMinimumHertz = 210;
		parameters.ringMaximumHertz = 230;
		parameters.frequencyBPM = 350;
		parameters.frequencyMinimumHertz = 110;
		parameters.frequencyMaximumHertz = 880;
	});
	return &parameters;
}

static PPIIRFilterParameters *PPPersistentIIRFilterParameters(void)
{
	static PPIIRFilterParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Exact values created by the 2002 plug-in when no 'pref' resource exists.
		parameters.mode = PPIIRFilterLowPass;
		parameters.startFrequency = 800;
		parameters.endFrequency = 1802;
		parameters.sweepFrequency = YES;
		parameters.wrapAround = NO;
		parameters.repeatEnabled = YES;
		parameters.repeatCount = 4;
	});
	return &parameters;
}

static PPStardustParameters *PPPersistentStardustParameters(void)
{
	static PPStardustParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Exact defaults written by the original plug-in when its 'pref'
		// resource was absent: 3,500-frame grains and 62 grain passes.
		parameters.grainLengthPosition = 0.25;
		parameters.grainCountPosition = 0.30;
	});
	return &parameters;
}

static size_t PPStardustGrainLength(PPStardustParameters parameters)
{
	double position = MIN(MAX(parameters.grainLengthPosition, 0.0), 1.0);
	return (size_t)(500.0 + 12000.0 * position);
}

static size_t PPStardustGrainCount(PPStardustParameters parameters)
{
	double position = MIN(MAX(parameters.grainCountPosition, 0.0), 1.0);
	return (size_t)(2.0 + 200.0 * position);
}

static PPConvolveParameters *PPPersistentConvolveParameters(void)
{
	static PPConvolveParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Match the state visible in the surviving PlayerPRO dialog. Gain and
		// quality use the exact values retained in the plug-in's 'pref' resource.
		parameters.wrapEdges = YES;
		parameters.normalizeImpulse = NO;
		parameters.normalizeToSumOne = NO;
		parameters.includeTail = NO;
		parameters.impulseMode = PPConvolveImpulseSelection;
		parameters.cutoffHertz = 10;
		parameters.gain = 0.015625;
		parameters.quality = 0.18055555555555555;
	});
	return &parameters;
}

static PPBetterFadeParameters *PPPersistentBetterFadeParameters(void)
{
	static PPBetterFadeParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		parameters.fromPercent = 100;
		parameters.toPercent = 0;
		parameters.mode = PPBetterFadeModeUp;
	});
	return &parameters;
}

static PPBetterFadeParameters PPBetterFadeEffectiveParameters(PPBetterFadeParameters parameters)
{
	if (parameters.mode == PPBetterFadeModeDown) {
		parameters.fromPercent = 100;
		parameters.toPercent = 0;
	} else if (parameters.mode == PPBetterFadeModeUp) {
		parameters.fromPercent = 0;
		parameters.toPercent = 100;
	}
	return parameters;
}

static PPAderodhiecusParameters *PPPersistentAderodhiecusParameters(void)
{
	static PPAderodhiecusParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Exact defaults stored in the classic plug-in's 'pref' resource.
		parameters.frequencyHertz = 448;
		parameters.horizontalPercent = 50.0;
		parameters.verticalPercent = 50.0;
	});
	return &parameters;
}

static PPAddotrophParameters *PPPersistentAddotrophParameters(void)
{
	static PPAddotrophParameters parameters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// These are the values displayed by the original Addotroph plug-in.
		parameters.useOctaveAndTone = YES;
		parameters.frequencyHertz = 110.0;
		parameters.octave = 3;
		parameters.tone = 0;
		parameters.toneAmplitudePermille = 1000.0;
		parameters.formantCount = 43;
		parameters.lastFormantAmplitudePermille = 1000.0;
		parameters.frequencyScalePermille = 1250.0;
		parameters.frequencyAdditionHertz = 10.0;
		parameters.amplitudeScalePermille = 900.0;
		const double chorusFrequencies[] = {4.0, 1000.0, 4.0, 20.0};
		const double chorusAmplitudes[] = {700.0, 700.0, 90.0, 200.0};
		for (NSInteger chorus = 0; chorus < 4; chorus++) {
			parameters.chorusEnabled[chorus] = YES;
			parameters.chorusFrequencyPermille[chorus] = chorusFrequencies[chorus];
			parameters.chorusAmplitudePermille[chorus] = chorusAmplitudes[chorus];
		}
		parameters.globalAmplitudePermille = 200.0;
	});
	return &parameters;
}

static double *PPPersistentHzFilterGains(void)
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		for (NSInteger point = 0; point < PPHzFilterPointCount; point++) PPHzFilterGains[point] = 1.0;
	});
	return PPHzFilterGains;
}

static double *PPPersistentHzShiftDestinations(void)
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		for (NSInteger point = 0; point < PPHzFilterPointCount; point++) {
			PPHzShiftDestinations[point] = (double)point / (double)(PPHzFilterPointCount - 1);
		}
	});
	return PPHzShiftDestinations;
}

static double PPHzFilterCanonicalPosition(double displayPosition, BOOL logarithmic)
{
	displayPosition = MIN(MAX(displayPosition, 0.0), 1.0);
	return logarithmic ? (pow(256.0, displayPosition) - 1.0) / 255.0 : displayPosition;
}

static double PPHzFilterDisplayPosition(double canonicalPosition, BOOL logarithmic)
{
	canonicalPosition = MIN(MAX(canonicalPosition, 0.0), 1.0);
	return logarithmic ? log(1.0 + canonicalPosition * 255.0) / log(256.0) : canonicalPosition;
}

@interface PPHzFilterContentView : NSView
@end

@implementation PPHzFilterContentView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
}
@end

@interface PPHzFilterCurveView : NSView
@property(nonatomic, assign) double *gains;
@property(nonatomic) BOOL logarithmic;
@property(nonatomic, copy) void (^editingEndedHandler)(void);
- (void)resetCurve;
@end

@implementation PPHzFilterCurveView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (double)gainAtDisplayPosition:(double)position
{
	double canonical = PPHzFilterCanonicalPosition(position, self.logarithmic);
	double index = canonical * (PPHzFilterPointCount - 1);
	NSInteger left = MIN(MAX((NSInteger)floor(index), 0), PPHzFilterPointCount - 1);
	NSInteger right = MIN(left + 1, PPHzFilterPointCount - 1);
	double fraction = index - left;
	return self.gains[left] + (self.gains[right] - self.gains[left]) * fraction;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.blackColor setFill];
	NSRectFill(self.bounds);
	CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
	[[NSColor colorWithCalibratedRed:0.0 green:0.72 blue:0.0 alpha:1.0] setStroke];
	NSBezierPath *grid = [NSBezierPath bezierPath];
	grid.lineWidth = 0.75;
	for (NSInteger division = 0; division <= 10; division++) {
		CGFloat y = floor(height * division / 10.0) + 0.5;
		[grid moveToPoint:NSMakePoint(0, y)];
		[grid lineToPoint:NSMakePoint(width, y)];
	}
	if (self.logarithmic) {
		// The 2002 LogC table placed equal reference divisions ever more
		// tightly toward the right edge. This is its exponential mapping.
		for (NSInteger division = 0; division < 16; division++) {
			double canonical = PPHzFilterCanonicalPosition(division / 16.0, YES);
			CGFloat x = floor(width * (1.0 - canonical)) + 0.5;
			[grid moveToPoint:NSMakePoint(x, 0)];
			[grid lineToPoint:NSMakePoint(x, height)];
		}
	} else {
		for (NSInteger division = 0; division <= 10; division++) {
			CGFloat x = floor(width * division / 10.0) + 0.5;
			[grid moveToPoint:NSMakePoint(x, 0)];
			[grid lineToPoint:NSMakePoint(x, height)];
		}
	}
	[grid stroke];

	NSBezierPath *curve = [NSBezierPath bezierPath];
	curve.lineWidth = 2.0;
	NSInteger pixels = MAX((NSInteger)ceil(width), 1);
	for (NSInteger pixel = 0; pixel <= pixels; pixel++) {
		double x = (double)pixel / (double)pixels;
		double gain = MIN(MAX([self gainAtDisplayPosition:x], 0.0), 2.0);
		NSPoint point = NSMakePoint(x * width, (2.0 - gain) * height / 2.0);
		if (pixel == 0) [curve moveToPoint:point]; else [curve lineToPoint:point];
	}
	[NSColor.yellowColor setStroke];
	[curve stroke];
	[[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setStroke];
	NSFrameRect(self.bounds);
}

- (void)setCurveFromPoint:(NSPoint)fromPoint toPoint:(NSPoint)toPoint
{
	double width = MAX(NSWidth(self.bounds), 1.0), height = MAX(NSHeight(self.bounds), 1.0);
	double fromDisplay = MIN(MAX(fromPoint.x / width, 0.0), 1.0);
	double toDisplay = MIN(MAX(toPoint.x / width, 0.0), 1.0);
	double fromGain = MIN(MAX(2.0 * (1.0 - fromPoint.y / height), 0.0), 2.0);
	double toGain = MIN(MAX(2.0 * (1.0 - toPoint.y / height), 0.0), 2.0);
	double fromCanonical = PPHzFilterCanonicalPosition(fromDisplay, self.logarithmic);
	double toCanonical = PPHzFilterCanonicalPosition(toDisplay, self.logarithmic);
	NSInteger first = MIN(MAX((NSInteger)floor(MIN(fromCanonical, toCanonical) *
		(PPHzFilterPointCount - 1)), 0), PPHzFilterPointCount - 1);
	NSInteger last = MIN(MAX((NSInteger)ceil(MAX(fromCanonical, toCanonical) *
		(PPHzFilterPointCount - 1)), 0), PPHzFilterPointCount - 1);
	if (first == last) {
		self.gains[first] = toGain;
	} else {
		for (NSInteger index = first; index <= last; index++) {
			double canonical = (double)index / (double)(PPHzFilterPointCount - 1);
			double display = PPHzFilterDisplayPosition(canonical, self.logarithmic);
			double divisor = toDisplay - fromDisplay;
			double progress = fabs(divisor) < 0.0000001 ? 1.0 :
				MIN(MAX((display - fromDisplay) / divisor, 0.0), 1.0);
			self.gains[index] = fromGain + (toGain - fromGain) * progress;
		}
	}
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	NSPoint previous = [self convertPoint:event.locationInWindow fromView:nil];
	[self setCurveFromPoint:previous toPoint:previous];
	while (YES) {
		NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		NSPoint point = [self convertPoint:next.locationInWindow fromView:nil];
		if (next.type == NSEventTypeLeftMouseUp) break;
		[self setCurveFromPoint:previous toPoint:point];
		previous = point;
	}
	if (self.editingEndedHandler != nil) self.editingEndedHandler();
}

- (void)resetCurve
{
	for (NSInteger point = 0; point < PPHzFilterPointCount; point++) self.gains[point] = 1.0;
	[self setNeedsDisplay:YES];
}

@end

@interface PPHzFilterDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) PPHzFilterCurveView *curveView;
@property(nonatomic, strong) NSButton *linearButton;
@property(nonatomic, strong) NSButton *logButton;
@property(nonatomic, strong) NSButton *previewButton;
@property(nonatomic, copy) void (^curveChangedHandler)(void);
@property(nonatomic, copy) void (^playHandler)(void);
@property(nonatomic, copy) void (^previewChangedHandler)(BOOL enabled);
@end

@implementation PPHzFilterDialogController

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 366, 276)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Hz Filter";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	PPHzFilterContentView *content = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 366, 276)];
	_window.contentView = content;
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSFont *boldFont = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];

	_curveView = [[PPHzFilterCurveView alloc] initWithFrame:NSMakeRect(99, 10, 256, 256)];
	_curveView.gains = PPPersistentHzFilterGains();
	_curveView.logarithmic = PPHzFilterLogarithmic;
	_curveView.accessibilityLabel = @"Frequency response curve";
	_curveView.accessibilityHelp = @"Drag to set gain from zero to two times across the frequency spectrum.";
	__weak typeof(self) weakSelf = self;
	_curveView.editingEndedHandler = ^{ if (weakSelf.curveChangedHandler != nil) weakSelf.curveChangedHandler(); };
	[content addSubview:_curveView];

	NSArray<NSString *> *titles = @[@"OK", @"Cancel", @"Reset", @"Play"];
	SEL actions[] = {@selector(accept:), @selector(cancel:), @selector(reset:), @selector(play:)};
	CGFloat positions[] = {230, 195, 150, 106};
	for (NSInteger index = 0; index < 4; index++) {
		NSButton *button = [NSButton buttonWithTitle:titles[index] target:self action:actions[index]];
		button.frame = NSMakeRect(13, positions[index], 72, 25);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = boldFont;
		button.focusRingType = NSFocusRingTypeNone;
		if (index == 0) button.keyEquivalent = @"\r";
		if (index == 1) button.keyEquivalent = @"\e";
		[content addSubview:button];
	}

	NSTextField *modeLabel = [NSTextField labelWithString:@"Mode:"];
	modeLabel.frame = NSMakeRect(13, 65, 72, 18);
	modeLabel.font = font;
	modeLabel.textColor = NSColor.blackColor;
	[content addSubview:modeLabel];
	_linearButton = [NSButton radioButtonWithTitle:@"Linear" target:self action:@selector(selectMode:)];
	_logButton = [NSButton radioButtonWithTitle:@"Log" target:self action:@selector(selectMode:)];
	_linearButton.tag = 0;
	_logButton.tag = 1;
	_linearButton.frame = NSMakeRect(14, 43, 72, 20);
	_logButton.frame = NSMakeRect(14, 26, 72, 20);
	for (NSButton *button in @[_linearButton, _logButton]) {
		button.font = font;
		[content addSubview:button];
	}
	_linearButton.state = PPHzFilterLogarithmic ? NSControlStateValueOff : NSControlStateValueOn;
	_logButton.state = PPHzFilterLogarithmic ? NSControlStateValueOn : NSControlStateValueOff;
	_previewButton = [NSButton checkboxWithTitle:@"Preview" target:self action:@selector(togglePreview:)];
	_previewButton.frame = NSMakeRect(13, 3, 80, 20);
	_previewButton.font = font;
	_previewButton.state = PPHzFilterPreviewEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	[content addSubview:_previewButton];
	return self;
}

- (void)selectMode:(NSButton *)sender
{
	PPHzFilterLogarithmic = sender.tag == 1;
	self.linearButton.state = PPHzFilterLogarithmic ? NSControlStateValueOff : NSControlStateValueOn;
	self.logButton.state = PPHzFilterLogarithmic ? NSControlStateValueOn : NSControlStateValueOff;
	self.curveView.logarithmic = PPHzFilterLogarithmic;
	[self.curveView setNeedsDisplay:YES];
}

- (void)togglePreview:(NSButton *)sender
{
	PPHzFilterPreviewEnabled = sender.state == NSControlStateValueOn;
	if (self.previewChangedHandler != nil) self.previewChangedHandler(PPHzFilterPreviewEnabled);
}

- (void)reset:(id)sender
{
	(void)sender;
	[self.curveView resetCurve];
	if (self.curveChangedHandler != nil) self.curveChangedHandler();
}

- (void)play:(id)sender
{
	(void)sender;
	if (self.playHandler != nil) self.playHandler();
}

- (void)accept:(id)sender { (void)sender; [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPHzShiftCurveView : NSView
@property(nonatomic, assign) double *destinations;
@property(nonatomic) BOOL logarithmic;
@property(nonatomic, copy) void (^editingEndedHandler)(void);
- (void)resetCurve;
- (void)convertCurveFromLogarithmic:(BOOL)oldLogarithmic toLogarithmic:(BOOL)newLogarithmic;
@end

@implementation PPHzShiftCurveView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (double)destinationAtSourcePosition:(double)position
{
	position = MIN(MAX(position, 0.0), 1.0);
	double index = position * (PPHzFilterPointCount - 1);
	NSInteger first = MIN(MAX((NSInteger)floor(index), 0), PPHzFilterPointCount - 1);
	NSInteger second = MIN(first + 1, PPHzFilterPointCount - 1);
	double fraction = index - first;
	return self.destinations[first] +
		(self.destinations[second] - self.destinations[first]) * fraction;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.blackColor setFill];
	NSRectFill(self.bounds);
	CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
	[[NSColor colorWithCalibratedRed:0.0 green:0.72 blue:0.0 alpha:1.0] setStroke];
	NSBezierPath *grid = [NSBezierPath bezierPath];
	grid.lineWidth = 0.75;
	if (self.logarithmic) {
		for (NSInteger division = 0; division < 16; division++) {
			double canonical = PPHzFilterCanonicalPosition(division / 16.0, YES);
			CGFloat x = floor(width * (1.0 - canonical)) + 0.5;
			CGFloat y = floor(height * (1.0 - canonical)) + 0.5;
			[grid moveToPoint:NSMakePoint(x, 0)];
			[grid lineToPoint:NSMakePoint(x, height)];
			[grid moveToPoint:NSMakePoint(0, y)];
			[grid lineToPoint:NSMakePoint(width, y)];
		}
	} else {
		for (NSInteger division = 0; division <= 10; division++) {
			CGFloat x = floor(width * division / 10.0) + 0.5;
			CGFloat y = floor(height * division / 10.0) + 0.5;
			[grid moveToPoint:NSMakePoint(x, 0)];
			[grid lineToPoint:NSMakePoint(x, height)];
			[grid moveToPoint:NSMakePoint(0, y)];
			[grid lineToPoint:NSMakePoint(width, y)];
		}
	}
	[grid stroke];

	// The original draws the unshifted response in red. In Log mode this is
	// the characteristic bowed LogC reference visible in the 2002 window.
	NSBezierPath *reference = [NSBezierPath bezierPath];
	reference.lineWidth = 2.0;
	NSInteger pixels = MAX((NSInteger)ceil(height), 1);
	for (NSInteger pixel = 0; pixel <= pixels; pixel++) {
		double source = (double)pixel / (double)pixels;
		double destination = PPHzFilterCanonicalPosition(source, self.logarithmic);
		NSPoint point = NSMakePoint(destination * width, source * height);
		if (pixel == 0) [reference moveToPoint:point]; else [reference lineToPoint:point];
	}
	[NSColor.redColor setStroke];
	[reference stroke];

	NSBezierPath *curve = [NSBezierPath bezierPath];
	curve.lineWidth = 2.0;
	for (NSInteger pixel = 0; pixel <= pixels; pixel++) {
		double source = (double)pixel / (double)pixels;
		double destination = [self destinationAtSourcePosition:source];
		NSPoint point = NSMakePoint(destination * width, source * height);
		if (pixel == 0) [curve moveToPoint:point]; else [curve lineToPoint:point];
	}
	[NSColor.yellowColor setStroke];
	[curve stroke];
	[[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setStroke];
	NSFrameRect(self.bounds);
}

- (void)setCurveFromPoint:(NSPoint)fromPoint toPoint:(NSPoint)toPoint
{
	double width = MAX(NSWidth(self.bounds), 1.0), height = MAX(NSHeight(self.bounds), 1.0);
	double fromSource = MIN(MAX(fromPoint.y / height, 0.0), 1.0);
	double toSource = MIN(MAX(toPoint.y / height, 0.0), 1.0);
	double fromDestination = MIN(MAX(fromPoint.x / width, 0.0), 1.0);
	double toDestination = MIN(MAX(toPoint.x / width, 0.0), 1.0);
	NSInteger first = MIN(MAX((NSInteger)floor(MIN(fromSource, toSource) *
		(PPHzFilterPointCount - 1)), 0), PPHzFilterPointCount - 1);
	NSInteger last = MIN(MAX((NSInteger)ceil(MAX(fromSource, toSource) *
		(PPHzFilterPointCount - 1)), 0), PPHzFilterPointCount - 1);
	if (first == last) {
		self.destinations[first] = toDestination;
	} else {
		for (NSInteger index = first; index <= last; index++) {
			double source = (double)index / (double)(PPHzFilterPointCount - 1);
			double divisor = toSource - fromSource;
			double progress = fabs(divisor) < 0.0000001 ? 1.0 :
				MIN(MAX((source - fromSource) / divisor, 0.0), 1.0);
			self.destinations[index] = fromDestination +
				(toDestination - fromDestination) * progress;
		}
	}
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	NSPoint firstPoint = [self convertPoint:event.locationInWindow fromView:nil];
	if ((event.modifierFlags & NSEventModifierFlagOption) != 0) {
		double width = MAX(NSWidth(self.bounds), 1.0), height = MAX(NSHeight(self.bounds), 1.0);
		NSPoint point = firstPoint;
		while (YES) {
			double offset = point.x / width - point.y / height;
			for (NSInteger index = 0; index < PPHzFilterPointCount; index++) {
				self.destinations[index] =
					(double)index / (double)(PPHzFilterPointCount - 1) + offset;
			}
			[self setNeedsDisplay:YES];
			NSEvent *next = [self.window nextEventMatchingMask:
				NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
			point = [self convertPoint:next.locationInWindow fromView:nil];
			if (next.type == NSEventTypeLeftMouseUp) break;
		}
		if (self.editingEndedHandler != nil) self.editingEndedHandler();
		return;
	}
	NSPoint previous = firstPoint;
	[self setCurveFromPoint:previous toPoint:previous];
	while (YES) {
		NSEvent *next = [self.window nextEventMatchingMask:
			NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		NSPoint point = [self convertPoint:next.locationInWindow fromView:nil];
		if (next.type == NSEventTypeLeftMouseUp) break;
		[self setCurveFromPoint:previous toPoint:point];
		previous = point;
	}
	if (self.editingEndedHandler != nil) self.editingEndedHandler();
}

- (void)resetCurve
{
	for (NSInteger point = 0; point < PPHzFilterPointCount; point++) {
		double source = (double)point / (double)(PPHzFilterPointCount - 1);
		self.destinations[point] = PPHzFilterCanonicalPosition(source, self.logarithmic);
	}
	[self setNeedsDisplay:YES];
}

- (void)convertCurveFromLogarithmic:(BOOL)oldLogarithmic toLogarithmic:(BOOL)newLogarithmic
{
	if (oldLogarithmic == newLogarithmic) return;
	for (NSInteger point = 0; point < PPHzFilterPointCount; point++) {
		double actualDestination = oldLogarithmic ?
			PPHzFilterDisplayPosition(self.destinations[point], YES) : self.destinations[point];
		self.destinations[point] = newLogarithmic ?
			PPHzFilterCanonicalPosition(actualDestination, YES) : actualDestination;
	}
	[self setNeedsDisplay:YES];
}

@end

@interface PPHzShiftDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) PPHzShiftCurveView *curveView;
@property(nonatomic, strong) NSButton *linearButton;
@property(nonatomic, strong) NSButton *logButton;
@property(nonatomic, strong) NSButton *previewButton;
@property(nonatomic, copy) void (^curveChangedHandler)(void);
@property(nonatomic, copy) void (^playHandler)(void);
@property(nonatomic, copy) void (^previewChangedHandler)(BOOL enabled);
@end

@implementation PPHzShiftDialogController

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 366, 276)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Shift Filter";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	PPHzFilterContentView *content = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 366, 276)];
	_window.contentView = content;
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSFont *boldFont = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];

	_curveView = [[PPHzShiftCurveView alloc] initWithFrame:NSMakeRect(99, 10, 256, 256)];
	_curveView.destinations = PPPersistentHzShiftDestinations();
	_curveView.logarithmic = PPHzFilterLogarithmic;
	_curveView.accessibilityLabel = @"Frequency shift curve";
	_curveView.accessibilityHelp = @"Drag vertically through the graph to map source frequencies to destination frequencies. Option-click offsets the entire map.";
	__weak typeof(self) weakSelf = self;
	_curveView.editingEndedHandler = ^{ if (weakSelf.curveChangedHandler != nil) weakSelf.curveChangedHandler(); };
	[content addSubview:_curveView];

	NSArray<NSString *> *titles = @[@"OK", @"Cancel", @"Reset", @"Play"];
	SEL actions[] = {@selector(accept:), @selector(cancel:), @selector(reset:), @selector(play:)};
	CGFloat positions[] = {230, 195, 150, 106};
	for (NSInteger index = 0; index < 4; index++) {
		NSButton *button = [NSButton buttonWithTitle:titles[index] target:self action:actions[index]];
		button.frame = NSMakeRect(13, positions[index], 72, 25);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = boldFont;
		button.focusRingType = NSFocusRingTypeNone;
		if (index == 0) button.keyEquivalent = @"\r";
		if (index == 1) button.keyEquivalent = @"\e";
		[content addSubview:button];
	}

	NSTextField *modeLabel = [NSTextField labelWithString:@"Mode:"];
	modeLabel.frame = NSMakeRect(13, 65, 72, 18);
	modeLabel.font = font;
	modeLabel.textColor = NSColor.blackColor;
	[content addSubview:modeLabel];
	_linearButton = [NSButton radioButtonWithTitle:@"Linear" target:self action:@selector(selectMode:)];
	_logButton = [NSButton radioButtonWithTitle:@"Log" target:self action:@selector(selectMode:)];
	_linearButton.tag = 0;
	_logButton.tag = 1;
	_linearButton.frame = NSMakeRect(14, 43, 72, 20);
	_logButton.frame = NSMakeRect(14, 26, 72, 20);
	for (NSButton *button in @[_linearButton, _logButton]) {
		button.font = font;
		[content addSubview:button];
	}
	_linearButton.state = PPHzFilterLogarithmic ? NSControlStateValueOff : NSControlStateValueOn;
	_logButton.state = PPHzFilterLogarithmic ? NSControlStateValueOn : NSControlStateValueOff;
	_previewButton = [NSButton checkboxWithTitle:@"Preview" target:self action:@selector(togglePreview:)];
	_previewButton.frame = NSMakeRect(13, 3, 80, 20);
	_previewButton.font = font;
	_previewButton.state = PPHzFilterPreviewEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	[content addSubview:_previewButton];
	return self;
}

- (void)selectMode:(NSButton *)sender
{
	BOOL wasLogarithmic = PPHzFilterLogarithmic;
	PPHzFilterLogarithmic = sender.tag == 1;
	self.linearButton.state = PPHzFilterLogarithmic ? NSControlStateValueOff : NSControlStateValueOn;
	self.logButton.state = PPHzFilterLogarithmic ? NSControlStateValueOn : NSControlStateValueOff;
	[self.curveView convertCurveFromLogarithmic:wasLogarithmic toLogarithmic:PPHzFilterLogarithmic];
	self.curveView.logarithmic = PPHzFilterLogarithmic;
	[self.curveView setNeedsDisplay:YES];
	if (self.curveChangedHandler != nil) self.curveChangedHandler();
}

- (void)togglePreview:(NSButton *)sender
{
	PPHzFilterPreviewEnabled = sender.state == NSControlStateValueOn;
	if (self.previewChangedHandler != nil) self.previewChangedHandler(PPHzFilterPreviewEnabled);
}

- (void)reset:(id)sender
{
	(void)sender;
	[self.curveView resetCurve];
	if (self.curveChangedHandler != nil) self.curveChangedHandler();
}

- (void)play:(id)sender
{
	(void)sender;
	if (self.playHandler != nil) self.playHandler();
}

- (void)accept:(id)sender { (void)sender; [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPAddotrophArtworkView : NSView
@end

@implementation PPAddotrophArtworkView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	NSString *path = [NSBundle.mainBundle pathForResource:@"Addotroph" ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image != nil) {
		[image drawInRect:NSInsetRect(self.bounds, 4.0, 4.0) fromRect:NSZeroRect
			operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
	}
	[[NSColor colorWithCalibratedWhite:0.78 alpha:1.0] setStroke];
	NSFrameRect(self.bounds);
}
@end

@interface PPAddotrophDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSButton *frequencyModeButton;
@property(nonatomic, strong) NSButton *noteModeButton;
@property(nonatomic, strong) NSTextField *frequencyField;
@property(nonatomic, strong) NSTextField *octaveField;
@property(nonatomic, strong) NSTextField *toneField;
@property(nonatomic, strong) NSTextField *toneAmplitudeField;
@property(nonatomic, strong) NSTextField *formantCountField;
@property(nonatomic, strong) NSTextField *lastFormantAmplitudeField;
@property(nonatomic, strong) NSTextField *frequencyScaleField;
@property(nonatomic, strong) NSTextField *frequencyAdditionField;
@property(nonatomic, strong) NSTextField *amplitudeScaleField;
@property(nonatomic, strong) NSArray<NSButton *> *chorusButtons;
@property(nonatomic, strong) NSArray<NSTextField *> *chorusFrequencyFields;
@property(nonatomic, strong) NSArray<NSTextField *> *chorusAmplitudeFields;
@property(nonatomic, strong) NSTextField *globalAmplitudeField;
@property(nonatomic, copy) void (^previewHandler)(void);
- (PPAddotrophParameters)parameters;
@end

@implementation PPAddotrophDialogController

- (NSTextField *)label:(NSString *)title frame:(NSRect)frame font:(NSFont *)font
{
	NSTextField *label = [NSTextField labelWithString:title];
	label.frame = frame;
	label.font = font;
	label.textColor = NSColor.blackColor;
	[self.window.contentView addSubview:label];
	return label;
}

- (NSTextField *)field:(double)value frame:(NSRect)frame font:(NSFont *)font
{
	NSTextField *field = [NSTextField textFieldWithString:
		(fabs(value - llround(value)) < 0.000001 ? [NSString stringWithFormat:@"%lld", llround(value)] :
		 [NSString stringWithFormat:@"%.3f", value])];
	field.frame = frame;
	field.font = font;
	field.alignment = NSTextAlignmentRight;
	field.textColor = NSColor.blackColor;
	field.backgroundColor = NSColor.whiteColor;
	field.focusRingType = NSFocusRingTypeExterior;
	[self.window.contentView addSubview:field];
	return field;
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPAddotrophParameters parameters = *PPPersistentAddotrophParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 516, 264)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Addotroph";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 516, 264)];
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSFont *bold = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];

	[self label:@"Tone:" frame:NSMakeRect(8, 232, 42, 18) font:bold];
	_frequencyModeButton = [NSButton radioButtonWithTitle:@"" target:self action:@selector(selectToneMode:)];
	_frequencyModeButton.frame = NSMakeRect(48, 230, 18, 20);
	_frequencyModeButton.tag = 0;
	[self.window.contentView addSubview:_frequencyModeButton];
	_frequencyField = [self field:parameters.frequencyHertz frame:NSMakeRect(68, 228, 44, 22) font:font];
	[self label:@"Hz" frame:NSMakeRect(116, 232, 24, 18) font:font];

	_noteModeButton = [NSButton radioButtonWithTitle:@"" target:self action:@selector(selectToneMode:)];
	_noteModeButton.frame = NSMakeRect(48, 206, 18, 20);
	_noteModeButton.tag = 1;
	[self.window.contentView addSubview:_noteModeButton];
	_octaveField = [self field:parameters.octave frame:NSMakeRect(68, 204, 22, 22) font:font];
	[self label:@"." frame:NSMakeRect(96, 208, 10, 18) font:font];
	_toneField = [self field:parameters.tone frame:NSMakeRect(108, 204, 22, 22) font:font];
	[self label:@"octave . tone" frame:NSMakeRect(136, 208, 110, 18) font:font];

	[self label:@"Amplitude:" frame:NSMakeRect(52, 180, 75, 18) font:bold];
	_toneAmplitudeField = [self field:parameters.toneAmplitudePermille frame:NSMakeRect(132, 176, 48, 22) font:font];
	[self label:@"‰" frame:NSMakeRect(184, 180, 22, 18) font:font];

	[self label:@"( freq +/- ‰ )" frame:NSMakeRect(340, 248, 100, 18) font:bold];
	[self label:@"( amp )" frame:NSMakeRect(428, 248, 65, 18) font:bold];
	NSMutableArray<NSButton *> *chorusButtons = [NSMutableArray arrayWithCapacity:4];
	NSMutableArray<NSTextField *> *chorusFrequencyFields = [NSMutableArray arrayWithCapacity:4];
	NSMutableArray<NSTextField *> *chorusAmplitudeFields = [NSMutableArray arrayWithCapacity:4];
	for (NSInteger chorus = 0; chorus < 4; chorus++) {
		CGFloat y = 224.0 - chorus * 24.0;
		NSButton *enabled = [NSButton checkboxWithTitle:@"Chorus:" target:nil action:nil];
		enabled.frame = NSMakeRect(280, y, 72, 20);
		enabled.font = bold;
		enabled.state = parameters.chorusEnabled[chorus] ? NSControlStateValueOn : NSControlStateValueOff;
		[self.window.contentView addSubview:enabled];
		[chorusButtons addObject:enabled];
		NSTextField *frequency = [self field:parameters.chorusFrequencyPermille[chorus]
			frame:NSMakeRect(356, y, 44, 22) font:font];
		[self label:@"‰" frame:NSMakeRect(408, y + 4, 22, 18) font:font];
		[chorusFrequencyFields addObject:frequency];
		NSTextField *amplitude = [self field:parameters.chorusAmplitudePermille[chorus]
			frame:NSMakeRect(432, y, 44, 22) font:font];
		[self label:@"‰" frame:NSMakeRect(484, y + 4, 22, 18) font:font];
		[chorusAmplitudeFields addObject:amplitude];
	}
	_chorusButtons = chorusButtons.copy;
	_chorusFrequencyFields = chorusFrequencyFields.copy;
	_chorusAmplitudeFields = chorusAmplitudeFields.copy;

	_formantCountField = [self field:parameters.formantCount frame:NSMakeRect(16, 124, 32, 22) font:font];
	[self label:@"formants, amp:" frame:NSMakeRect(52, 128, 105, 18) font:bold];
	_lastFormantAmplitudeField = [self field:parameters.lastFormantAmplitudePermille
		frame:NSMakeRect(160, 124, 44, 22) font:font];
	[self label:@"‰" frame:NSMakeRect(212, 128, 22, 18) font:font];
	[self label:@"( of last formant )" frame:NSMakeRect(24, 102, 150, 18) font:bold];

	[self label:@"freq:" frame:NSMakeRect(12, 76, 44, 18) font:bold];
	_frequencyScaleField = [self field:parameters.frequencyScalePermille frame:NSMakeRect(52, 72, 44, 22) font:font];
	[self label:@"‰ +" frame:NSMakeRect(104, 76, 35, 18) font:font];
	_frequencyAdditionField = [self field:parameters.frequencyAdditionHertz frame:NSMakeRect(140, 72, 32, 22) font:font];
	[self label:@"Hz" frame:NSMakeRect(180, 76, 24, 18) font:font];
	[self label:@"amp:" frame:NSMakeRect(12, 44, 44, 18) font:bold];
	_amplitudeScaleField = [self field:parameters.amplitudeScalePermille frame:NSMakeRect(52, 40, 44, 22) font:font];
	[self label:@"‰" frame:NSMakeRect(104, 44, 22, 18) font:font];

	[self label:@"Global Amplitude:" frame:NSMakeRect(192, 40, 116, 18) font:bold];
	_globalAmplitudeField = [self field:parameters.globalAmplitudePermille frame:NSMakeRect(312, 40, 48, 22) font:font];
	[self label:@"‰" frame:NSMakeRect(364, 44, 22, 18) font:font];

	NSString *creditPath = [NSBundle.mainBundle pathForResource:@"AddotrophCredit"
		ofType:@"png" inDirectory:@"Classic"];
	NSImage *creditImage = creditPath.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:creditPath];
	if (creditImage != nil) {
		NSImageView *credit = [[NSImageView alloc] initWithFrame:NSMakeRect(4, 0, 101, 16)];
		credit.image = creditImage;
		credit.imageScaling = NSImageScaleNone;
		credit.accessibilityLabel = @"Addotroph by Pandaa";
		[self.window.contentView addSubview:credit];
	} else {
		[self label:@"Addotroph by Pandaa" frame:NSMakeRect(4, 0, 150, 18) font:font];
	}
	PPAddotrophArtworkView *art = [[PPAddotrophArtworkView alloc] initWithFrame:NSMakeRect(392, 40, 115, 100)];
	art.accessibilityLabel = @"Original Addotroph artwork";
	[self.window.contentView addSubview:art];

	NSArray<NSString *> *buttonTitles = @[@"Preview", @"OK", @"Cancel"];
	SEL buttonActions[] = {@selector(preview:), @selector(accept:), @selector(cancel:)};
	CGFloat buttonX[] = {300.0, 380.0, 450.0};
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index] target:self action:buttonActions[index]];
		button.frame = NSMakeRect(buttonX[index], 0, index == 0 ? 68 : 58, 25);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = bold;
		button.focusRingType = NSFocusRingTypeNone;
		if (index == 1) button.keyEquivalent = @"\r";
		if (index == 2) button.keyEquivalent = @"\e";
		[self.window.contentView addSubview:button];
	}

	_frequencyModeButton.state = parameters.useOctaveAndTone ? NSControlStateValueOff : NSControlStateValueOn;
	_noteModeButton.state = parameters.useOctaveAndTone ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateToneMode];
	return self;
}

- (void)selectToneMode:(NSButton *)sender
{
	BOOL useNote = sender.tag == 1;
	self.frequencyModeButton.state = useNote ? NSControlStateValueOff : NSControlStateValueOn;
	self.noteModeButton.state = useNote ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateToneMode];
}

- (void)updateToneMode
{
	BOOL useNote = self.noteModeButton.state == NSControlStateValueOn;
	self.frequencyField.enabled = !useNote;
	self.octaveField.enabled = useNote;
	self.toneField.enabled = useNote;
}

- (PPAddotrophParameters)parameters
{
	PPAddotrophParameters parameters = {0};
	parameters.useOctaveAndTone = self.noteModeButton.state == NSControlStateValueOn;
	parameters.frequencyHertz = self.frequencyField.doubleValue;
	parameters.octave = self.octaveField.integerValue;
	parameters.tone = self.toneField.integerValue;
	parameters.toneAmplitudePermille = self.toneAmplitudeField.doubleValue;
	parameters.formantCount = self.formantCountField.integerValue;
	parameters.lastFormantAmplitudePermille = self.lastFormantAmplitudeField.doubleValue;
	parameters.frequencyScalePermille = self.frequencyScaleField.doubleValue;
	parameters.frequencyAdditionHertz = self.frequencyAdditionField.doubleValue;
	parameters.amplitudeScalePermille = self.amplitudeScaleField.doubleValue;
	for (NSInteger chorus = 0; chorus < 4; chorus++) {
		parameters.chorusEnabled[chorus] = self.chorusButtons[chorus].state == NSControlStateValueOn;
		parameters.chorusFrequencyPermille[chorus] = self.chorusFrequencyFields[chorus].doubleValue;
		parameters.chorusAmplitudePermille[chorus] = self.chorusAmplitudeFields[chorus].doubleValue;
	}
	parameters.globalAmplitudePermille = self.globalAmplitudeField.doubleValue;
	return parameters;
}

- (void)preview:(id)sender { (void)sender; if (self.previewHandler != nil) self.previewHandler(); }
- (void)accept:(id)sender { (void)sender; [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPAderodhiecusPanel : NSPanel
@end

@implementation PPAderodhiecusPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

typedef NS_ENUM(NSInteger, PPAderodhiecusDragMode) {
	PPAderodhiecusDragModeNone = 0,
	PPAderodhiecusDragModeFrequency,
	PPAderodhiecusDragModeTarget
};

@interface PPAderodhiecusView : NSView
@property(nonatomic) PPAderodhiecusParameters parameters;
@property(nonatomic, strong) NSImage *backgroundImage;
@property(nonatomic, strong) NSImage *targetImage;
@property(nonatomic) PPAderodhiecusDragMode dragMode;
@property(nonatomic) NSPoint initialDragPoint;
@property(nonatomic) NSInteger initialFrequency;
@property(nonatomic) BOOL parameterChangedDuringDrag;
@property(nonatomic, copy) void (^previewHandler)(void);
@property(nonatomic, copy) void (^acceptHandler)(void);
@property(nonatomic, copy) void (^cancelHandler)(void);
@end

@implementation PPAderodhiecusView

static NSRect const PPAderodhiecusTargetRect = {{46.0, 22.0}, {54.0, 63.0}};
static NSRect const PPAderodhiecusFrequencyRect = {{28.0, 104.0}, {147.0, 18.0}};
static NSRect const PPAderodhiecusCancelRect = {{5.0, 162.0}, {43.0, 14.0}};
static NSRect const PPAderodhiecusOKRect = {{150.0, 159.0}, {20.0, 16.0}};

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self == nil) return nil;
	NSString *backgroundPath = [NSBundle.mainBundle pathForResource:@"Aderodhiecus"
		ofType:@"png" inDirectory:@"Classic"];
	NSString *targetPath = [NSBundle.mainBundle pathForResource:@"AderodhiecusTarget"
		ofType:@"png" inDirectory:@"Classic"];
	_backgroundImage = backgroundPath.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:backgroundPath];
	_targetImage = targetPath.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:targetPath];
	self.accessibilityElement = YES;
	self.accessibilityRole = NSAccessibilityGroupRole;
	self.accessibilityLabel = @"Aderodhiecus frequency modulated curve";
	self.accessibilityHelp = @"Drag the target to change depth and strength. Drag the frequency readout vertically. Press Space to preview.";
	return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (NSPoint)targetCenter
{
	double horizontal = MIN(MAX(self.parameters.horizontalPercent, 0.0), 100.0) / 100.0;
	double vertical = MIN(MAX(self.parameters.verticalPercent, 0.0), 100.0) / 100.0;
	return NSMakePoint(NSMinX(PPAderodhiecusTargetRect) + NSWidth(PPAderodhiecusTargetRect) * horizontal,
		NSMinY(PPAderodhiecusTargetRect) + NSHeight(PPAderodhiecusTargetRect) * vertical);
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	NSDictionary *imageHints = @{NSImageHintInterpolation: @(NSImageInterpolationHigh)};
	if (self.backgroundImage != nil) {
		[self.backgroundImage drawInRect:self.bounds fromRect:NSZeroRect
			operation:NSCompositingOperationCopy fraction:1.0 respectFlipped:YES hints:imageHints];
	}

	NSFont *font = [NSFont fontWithName:@"Monaco-Bold" size:9.0] ?:
		[NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold];
	NSString *frequency = [NSString stringWithFormat:@"%ld", (long)self.parameters.frequencyHertz];
	[frequency drawAtPoint:NSMakePoint(96.0, 106.0) withAttributes:@{
		NSFontAttributeName: font,
		NSForegroundColorAttributeName: NSColor.blackColor
	}];

	NSPoint center = self.targetCenter;
	NSRect targetFrame = NSMakeRect(round(center.x - 4.0), round(center.y - 4.0), 9.0, 9.0);
	if (self.targetImage != nil) {
		[self.targetImage drawInRect:targetFrame fromRect:NSZeroRect
			operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:imageHints];
	} else {
		[[NSColor colorWithCalibratedRed:0.20 green:0.35 blue:1.0 alpha:1.0] setFill];
		[[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(targetFrame, 2.0, 2.0)] fill];
	}
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(self.bounds, 1.0);
}

- (void)resetCursorRects
{
	[super resetCursorRects];
	[self addCursorRect:PPAderodhiecusTargetRect cursor:NSCursor.crosshairCursor];
	[self addCursorRect:PPAderodhiecusFrequencyRect cursor:NSCursor.resizeUpDownCursor];
	[self addCursorRect:PPAderodhiecusCancelRect cursor:NSCursor.pointingHandCursor];
	[self addCursorRect:PPAderodhiecusOKRect cursor:NSCursor.pointingHandCursor];
}

- (void)updateTargetAtPoint:(NSPoint)point
{
	double horizontal = (point.x - NSMinX(PPAderodhiecusTargetRect)) /
		MAX(NSWidth(PPAderodhiecusTargetRect), 1.0) * 100.0;
	double vertical = (point.y - NSMinY(PPAderodhiecusTargetRect)) /
		MAX(NSHeight(PPAderodhiecusTargetRect), 1.0) * 100.0;
	PPAderodhiecusParameters parameters = self.parameters;
	parameters.horizontalPercent = MIN(MAX(horizontal, 0.0), 100.0);
	parameters.verticalPercent = MIN(MAX(vertical, 0.0), 100.0);
	self.parameters = parameters;
	self.parameterChangedDuringDrag = YES;
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if (NSPointInRect(point, PPAderodhiecusOKRect)) {
		if (self.acceptHandler != nil) self.acceptHandler();
		return;
	}
	if (NSPointInRect(point, PPAderodhiecusCancelRect)) {
		if (self.cancelHandler != nil) self.cancelHandler();
		return;
	}
	self.parameterChangedDuringDrag = NO;
	if (NSPointInRect(point, PPAderodhiecusTargetRect)) {
		self.dragMode = PPAderodhiecusDragModeTarget;
		[self updateTargetAtPoint:point];
	} else if (NSPointInRect(point, PPAderodhiecusFrequencyRect)) {
		self.dragMode = PPAderodhiecusDragModeFrequency;
		self.initialDragPoint = point;
		self.initialFrequency = self.parameters.frequencyHertz;
	} else {
		self.dragMode = PPAderodhiecusDragModeNone;
	}
}

- (void)mouseDragged:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if (self.dragMode == PPAderodhiecusDragModeTarget) {
		[self updateTargetAtPoint:point];
	} else if (self.dragMode == PPAderodhiecusDragModeFrequency) {
		// The PowerPC plug-in multiplies vertical travel by its stored 1.94 constant.
		NSInteger delta = (NSInteger)trunc((point.y - self.initialDragPoint.y) * 1.94);
		PPAderodhiecusParameters parameters = self.parameters;
		parameters.frequencyHertz = MIN(MAX(self.initialFrequency - delta, 1), INT16_MAX);
		self.parameters = parameters;
		self.parameterChangedDuringDrag = YES;
		[self setNeedsDisplay:YES];
	}
}

- (void)mouseUp:(NSEvent *)event
{
	if (self.dragMode == PPAderodhiecusDragModeTarget) {
		[self updateTargetAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	}
	BOOL changed = self.parameterChangedDuringDrag;
	self.dragMode = PPAderodhiecusDragModeNone;
	self.parameterChangedDuringDrag = NO;
	if (changed && self.previewHandler != nil) self.previewHandler();
}

- (void)keyDown:(NSEvent *)event
{
	NSString *characters = event.charactersIgnoringModifiers ?: @"";
	if ([characters isEqualToString:@"\r"] || [characters isEqualToString:@"\n"]) {
		if (self.acceptHandler != nil) self.acceptHandler();
	} else if ([characters isEqualToString:@"\e"]) {
		if (self.cancelHandler != nil) self.cancelHandler();
	} else if ([characters isEqualToString:@" "]) {
		if (self.previewHandler != nil) self.previewHandler();
	} else {
		[super keyDown:event];
	}
}

@end

@interface PPAderodhiecusDialogController : NSObject
@property(nonatomic, strong) PPAderodhiecusPanel *window;
@property(nonatomic, strong) PPAderodhiecusView *controlView;
@property(nonatomic, copy) void (^previewHandler)(void);
@property(nonatomic, readonly) PPAderodhiecusParameters parameters;
@end

@implementation PPAderodhiecusDialogController

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	_window = [[PPAderodhiecusPanel alloc] initWithContentRect:NSMakeRect(0, 0, 180, 180)
		styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Aderodhiecus";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.hasShadow = YES;
	_window.opaque = YES;
	_window.backgroundColor = NSColor.whiteColor;
	_controlView = [[PPAderodhiecusView alloc] initWithFrame:NSMakeRect(0, 0, 180, 180)];
	_controlView.parameters = *PPPersistentAderodhiecusParameters();
	__weak typeof(self) weakSelf = self;
	_controlView.previewHandler = ^{ if (weakSelf.previewHandler != nil) weakSelf.previewHandler(); };
	_controlView.acceptHandler = ^{ [NSApp stopModalWithCode:NSModalResponseOK]; };
	_controlView.cancelHandler = ^{ [NSApp abortModal]; };
	_window.contentView = _controlView;
	return self;
}

- (PPAderodhiecusParameters)parameters { return self.controlView.parameters; }

@end

@interface PPBetterFadeDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSTextField *fromField;
@property(nonatomic, strong) NSTextField *toField;
@property(nonatomic, strong) NSArray<NSButton *> *modeButtons;
@property(nonatomic, copy) void (^previewHandler)(void);
@property(nonatomic, readonly) PPBetterFadeParameters parameters;
@property(nonatomic, readonly) PPBetterFadeParameters effectiveParameters;
@end

@implementation PPBetterFadeDialogController

- (NSTextField *)label:(NSString *)title frame:(NSRect)frame font:(NSFont *)font
{
	NSTextField *label = [NSTextField labelWithString:title];
	label.frame = frame;
	label.font = font;
	label.textColor = NSColor.blackColor;
	[self.window.contentView addSubview:label];
	return label;
}

- (NSTextField *)field:(NSInteger)value frame:(NSRect)frame font:(NSFont *)font
{
	NSTextField *field = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)value]];
	field.frame = frame;
	field.font = font;
	field.alignment = NSTextAlignmentRight;
	field.textColor = NSColor.blackColor;
	field.backgroundColor = NSColor.whiteColor;
	field.focusRingType = NSFocusRingTypeExterior;
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.allowsFloats = NO;
	formatter.minimum = @(-32768);
	formatter.maximum = @(32767);
	field.formatter = formatter;
	[self.window.contentView addSubview:field];
	return field;
}

- (void)addArtworkNamed:(NSString *)name frame:(NSRect)frame accessibilityLabel:(NSString *)label
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image == nil) return;
	NSImageView *imageView = [[NSImageView alloc] initWithFrame:frame];
	imageView.image = image;
	imageView.imageScaling = NSImageScaleNone;
	imageView.imageAlignment = NSImageAlignCenter;
	imageView.accessibilityLabel = label;
	[self.window.contentView addSubview:imageView];
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPBetterFadeParameters parameters = *PPPersistentBetterFadeParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 124)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Amplitude";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 340, 124)];

	NSFont *font = [NSFont fontWithName:@"Monaco" size:9.0] ?:
		[NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightRegular];
	NSFont *bold = [NSFont fontWithName:@"Monaco-Bold" size:10.0] ?:
		[NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold];
	[self label:@"Fade from:" frame:NSMakeRect(28, 90, 86, 18) font:bold];
	[self label:@"Fade to:" frame:NSMakeRect(28, 63, 86, 18) font:bold];
	_fromField = [self field:parameters.fromPercent frame:NSMakeRect(118, 88, 44, 22) font:bold];
	_toField = [self field:parameters.toPercent frame:NSMakeRect(118, 61, 44, 22) font:bold];
	[self label:@"%" frame:NSMakeRect(166, 91, 18, 18) font:bold];
	[self label:@"%" frame:NSMakeRect(166, 64, 18, 18) font:bold];

	[self addArtworkNamed:@"BetterFadeDown" frame:NSMakeRect(204, 56, 48, 64)
		accessibilityLabel:@"Fade from 100 percent to zero percent"];
	[self addArtworkNamed:@"BetterFadeUp" frame:NSMakeRect(276, 56, 48, 64)
		accessibilityLabel:@"Fade from zero percent to 100 percent"];
	[self addArtworkNamed:@"BetterFadeCredit" frame:NSMakeRect(4, 12, 96, 16)
		accessibilityLabel:@"Better Fade by Pandaa"];

	NSArray<NSValue *> *radioFrames = @[
		[NSValue valueWithRect:NSMakeRect(0, 80, 18, 18)],
		[NSValue valueWithRect:NSMakeRect(188, 60, 18, 18)],
		[NSValue valueWithRect:NSMakeRect(322, 68, 18, 18)]
	];
	NSArray<NSString *> *radioLabels = @[
		@"Use the Fade from and Fade to fields",
		@"Fade down from 100 percent to zero percent",
		@"Fade up from zero percent to 100 percent"
	];
	NSMutableArray<NSButton *> *modeButtons = [NSMutableArray arrayWithCapacity:3];
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [NSButton radioButtonWithTitle:@"" target:self action:@selector(selectMode:)];
		button.frame = radioFrames[index].rectValue;
		button.tag = index + 1;
		button.state = parameters.mode == index + 1 ? NSControlStateValueOn : NSControlStateValueOff;
		button.accessibilityLabel = radioLabels[index];
		button.toolTip = radioLabels[index];
		[self.window.contentView addSubview:button];
		[modeButtons addObject:button];
	}
	_modeButtons = modeButtons.copy;

	NSArray<NSString *> *buttonTitles = @[@"Preview", @"OK", @"Cancel"];
	SEL buttonActions[] = {@selector(preview:), @selector(accept:), @selector(cancel:)};
	CGFloat buttonX[] = {102.0, 160.0, 230.0};
	CGFloat buttonWidths[] = {54.0, 58.0, 58.0};
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index] target:self action:buttonActions[index]];
		button.frame = NSMakeRect(buttonX[index], 8, buttonWidths[index], 25);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = index == 0 ? font : bold;
		button.focusRingType = NSFocusRingTypeNone;
		if (index == 1) button.keyEquivalent = @"\r";
		if (index == 2) button.keyEquivalent = @"\e";
		[self.window.contentView addSubview:button];
	}
	return self;
}

- (PPBetterFadeParameters)parameters
{
	PPBetterFadeParameters parameters = {
		.fromPercent = MIN(MAX(self.fromField.integerValue, -32768), 32767),
		.toPercent = MIN(MAX(self.toField.integerValue, -32768), 32767),
		.mode = PPBetterFadeModeCustom
	};
	for (NSButton *button in self.modeButtons) {
		if (button.state == NSControlStateValueOn) {
			parameters.mode = (PPBetterFadeMode)button.tag;
			break;
		}
	}
	return parameters;
}

- (PPBetterFadeParameters)effectiveParameters
{
	return PPBetterFadeEffectiveParameters(self.parameters);
}

- (void)selectMode:(NSButton *)sender
{
	for (NSButton *button in self.modeButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)preview:(id)sender { (void)sender; if (self.previewHandler != nil) self.previewHandler(); }
- (void)accept:(id)sender { (void)sender; [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPConvolveSlider : NSControl {
	double _storedDoubleValue;
}
@property(nonatomic) double minimumValue;
@property(nonatomic) double maximumValue;
@property(nonatomic) double doubleValue;
@property(nonatomic) BOOL vertical;
@end

@implementation PPConvolveSlider

- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)setDoubleValue:(double)value
{
	_storedDoubleValue = MIN(MAX(value, self.minimumValue), self.maximumValue);
	[self setNeedsDisplay:YES];
}

- (double)doubleValue { return _storedDoubleValue; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.08 alpha:1.0] setStroke];
	NSBezierPath *path = [NSBezierPath bezierPath];
	path.lineWidth = 1.0;
	double range = MAX(self.maximumValue - self.minimumValue, 0.000000001);
	double position = (self.doubleValue - self.minimumValue) / range;
	if (self.vertical) {
		CGFloat x = floor(NSMidX(self.bounds)) + 0.5;
		[path moveToPoint:NSMakePoint(x, 1.0)];
		[path lineToPoint:NSMakePoint(x, NSHeight(self.bounds) - 1.0)];
		CGFloat y = floor(1.0 + position * (NSHeight(self.bounds) - 2.0)) + 0.5;
		[path moveToPoint:NSMakePoint(x - 6.0, y)];
		[path lineToPoint:NSMakePoint(x + 6.0, y)];
	} else {
		CGFloat y = floor(NSMidY(self.bounds)) + 0.5;
		[path moveToPoint:NSMakePoint(1.0, y)];
		[path lineToPoint:NSMakePoint(NSWidth(self.bounds) - 1.0, y)];
		CGFloat x = floor(1.0 + position * (NSWidth(self.bounds) - 2.0)) + 0.5;
		[path moveToPoint:NSMakePoint(x, y - 6.0)];
		[path lineToPoint:NSMakePoint(x, y + 6.0)];
	}
	[path stroke];
}

- (void)updateFromEvent:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	double length = self.vertical ? NSHeight(self.bounds) : NSWidth(self.bounds);
	double coordinate = self.vertical ? point.y : point.x;
	double position = MIN(MAX((coordinate - 1.0) / MAX(length - 2.0, 1.0), 0.0), 1.0);
	self.doubleValue = self.minimumValue + position * (self.maximumValue - self.minimumValue);
	[self sendAction:self.action to:self.target];
}

- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	[self updateFromEvent:event];
	while (YES) {
		NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		[self updateFromEvent:next];
		if (next.type == NSEventTypeLeftMouseUp) break;
	}
}

@end

@interface PPStardustDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) PPConvolveSlider *grainLengthSlider;
@property(nonatomic, strong) PPConvolveSlider *grainCountSlider;
@property(nonatomic, readonly) PPStardustParameters parameters;
@end

@implementation PPStardustDialogController

- (void)addArtworkNamed:(NSString *)name frame:(NSRect)frame accessibilityLabel:(NSString *)label
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image == nil) return;
	NSImageView *imageView = [[NSImageView alloc] initWithFrame:frame];
	imageView.image = image;
	imageView.imageScaling = NSImageScaleNone;
	imageView.imageAlignment = NSImageAlignCenter;
	imageView.accessibilityLabel = label;
	[self.window.contentView addSubview:imageView];
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPStardustParameters parameters = *PPPersistentStardustParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 328, 136)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 328, 136)];

	// These are the six surviving PICT resources from the 2002 plug-in. Their
	// positions are translated directly from DITL 128 into AppKit coordinates.
	[self addArtworkNamed:@"StardustGrainLength" frame:NSMakeRect(48, 72, 54, 16)
		accessibilityLabel:@"grainlength"];
	[self addArtworkNamed:@"StardustMin" frame:NSMakeRect(8, 11, 21, 13)
		accessibilityLabel:@"minimum grain length"];
	[self addArtworkNamed:@"StardustMax" frame:NSMakeRect(4, 108, 25, 12)
		accessibilityLabel:@"maximum grain length"];
	[self addArtworkNamed:@"StardustGrains" frame:NSMakeRect(152, 73, 32, 15)
		accessibilityLabel:@"grains"];
	[self addArtworkNamed:@"StardustMin" frame:NSMakeRect(112, 11, 21, 13)
		accessibilityLabel:@"minimum grain count"];
	[self addArtworkNamed:@"StardustMax" frame:NSMakeRect(108, 108, 25, 12)
		accessibilityLabel:@"maximum grain count"];
	[self addArtworkNamed:@"StardustCredit" frame:NSMakeRect(216, 0, 91, 16)
		accessibilityLabel:@"Stardust by Pandaa"];
	[self addArtworkNamed:@"StardustArtwork" frame:NSMakeRect(192, 79, 136, 49)
		accessibilityLabel:@"Original Stardust artwork"];

	_grainLengthSlider = [[PPConvolveSlider alloc] initWithFrame:NSMakeRect(32, 12, 13, 108)];
	_grainLengthSlider.minimumValue = 0.0;
	_grainLengthSlider.maximumValue = 1.0;
	_grainLengthSlider.doubleValue = parameters.grainLengthPosition;
	_grainLengthSlider.vertical = YES;
	_grainLengthSlider.target = self;
	_grainLengthSlider.action = @selector(updateValueDescriptions:);
	_grainLengthSlider.accessibilityLabel = @"Grain length";
	[self.window.contentView addSubview:_grainLengthSlider];

	_grainCountSlider = [[PPConvolveSlider alloc] initWithFrame:NSMakeRect(136, 12, 13, 108)];
	_grainCountSlider.minimumValue = 0.0;
	_grainCountSlider.maximumValue = 1.0;
	_grainCountSlider.doubleValue = parameters.grainCountPosition;
	_grainCountSlider.vertical = YES;
	_grainCountSlider.target = self;
	_grainCountSlider.action = @selector(updateValueDescriptions:);
	_grainCountSlider.accessibilityLabel = @"Grains";
	[self.window.contentView addSubview:_grainCountSlider];

	NSArray<NSString *> *buttonTitles = @[@"OK", @"Cancel"];
	SEL buttonActions[] = {@selector(accept:), @selector(cancel:)};
	CGFloat buttonY[] = {54.0, 22.0};
	for (NSInteger index = 0; index < 2; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index] target:self action:buttonActions[index]];
		button.frame = NSMakeRect(239, buttonY[index], 52, 24);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
			[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
		button.focusRingType = NSFocusRingTypeNone;
		button.keyEquivalent = index == 0 ? @"\r" : @"\e";
		[self.window.contentView addSubview:button];
	}
	[self updateValueDescriptions:nil];
	return self;
}

- (PPStardustParameters)parameters
{
	return (PPStardustParameters){
		.grainLengthPosition = self.grainLengthSlider.doubleValue,
		.grainCountPosition = self.grainCountSlider.doubleValue
	};
}

- (void)updateValueDescriptions:(id)sender
{
	(void)sender;
	PPStardustParameters parameters = self.parameters;
	NSString *grainLength = [NSString stringWithFormat:@"%zu sample frames",
		PPStardustGrainLength(parameters)];
	NSString *grainCount = [NSString stringWithFormat:@"%zu grains",
		PPStardustGrainCount(parameters)];
	self.grainLengthSlider.accessibilityValueDescription = grainLength;
	self.grainLengthSlider.toolTip = grainLength;
	self.grainCountSlider.accessibilityValueDescription = grainCount;
	self.grainCountSlider.toolTip = grainCount;
}

- (void)accept:(id)sender { (void)sender; [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPIIRFilterDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSArray<NSButton *> *modeButtons;
@property(nonatomic, strong) NSTextField *startFrequencyField;
@property(nonatomic, strong) NSTextField *endFrequencyField;
@property(nonatomic, strong) NSButton *sweepButton;
@property(nonatomic, strong) NSButton *wrapButton;
@property(nonatomic, strong) NSButton *repeatButton;
@property(nonatomic, strong) PPConvolveSlider *repeatSlider;
@property(nonatomic, readonly) PPIIRFilterParameters parameters;
@end

@implementation PPIIRFilterDialogController

- (NSButton *)smallToggleOfType:(NSButtonType)type frame:(NSRect)frame
{
	NSButton *button = [[NSButton alloc] initWithFrame:frame];
	button.buttonType = type;
	button.title = @"";
	button.target = self;
	button.focusRingType = NSFocusRingTypeNone;
	[self.window.contentView addSubview:button];
	return button;
}

- (NSTextField *)frequencyFieldWithValue:(NSInteger)value frame:(NSRect)frame
{
	NSTextField *field = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)value]];
	field.frame = frame;
	field.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	field.alignment = NSTextAlignmentRight;
	field.textColor = NSColor.blackColor;
	field.backgroundColor = NSColor.whiteColor;
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.allowsFloats = NO;
	formatter.minimum = @0;
	formatter.maximum = @32767;
	field.formatter = formatter;
	[self.window.contentView addSubview:field];
	return field;
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPIIRFilterParameters parameters = *PPPersistentIIRFilterParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 180)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"IIR filter ( 1st order )";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];

	NSString *path = [NSBundle.mainBundle pathForResource:@"IIRFilterBackground"
		ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image != nil) {
		NSImageView *background = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
		background.image = image;
		background.imageScaling = NSImageScaleNone;
		background.imageAlignment = NSImageAlignCenter;
		background.accessibilityLabel = @"Original IIR Filter artwork";
		[self.window.contentView addSubview:background];
	}

	NSButton *high = [self smallToggleOfType:NSButtonTypeRadio frame:NSMakeRect(58, 138, 18, 18)];
	NSButton *low = [self smallToggleOfType:NSButtonTypeRadio frame:NSMakeRect(58, 122, 18, 18)];
	high.tag = PPIIRFilterHighPass;
	low.tag = PPIIRFilterLowPass;
	high.action = @selector(selectMode:);
	low.action = @selector(selectMode:);
	high.accessibilityLabel = @"High pass";
	low.accessibilityLabel = @"Low pass";
	high.state = parameters.mode == PPIIRFilterHighPass ? NSControlStateValueOn : NSControlStateValueOff;
	low.state = parameters.mode == PPIIRFilterLowPass ? NSControlStateValueOn : NSControlStateValueOff;
	_modeButtons = @[high, low];

	_startFrequencyField = [self frequencyFieldWithValue:parameters.startFrequency
		frame:NSMakeRect(132, 108, 48, 24)];
	_startFrequencyField.accessibilityLabel = @"Starting frequency in hertz";
	_endFrequencyField = [self frequencyFieldWithValue:parameters.endFrequency
		frame:NSMakeRect(230, 108, 48, 24)];
	_endFrequencyField.accessibilityLabel = @"Ending frequency in hertz";

	_sweepButton = [self smallToggleOfType:NSSwitchButton frame:NSMakeRect(186, 96, 18, 18)];
	_sweepButton.state = parameters.sweepFrequency ? NSControlStateValueOn : NSControlStateValueOff;
	_sweepButton.accessibilityLabel = @"Sweep between the two frequencies";
	_wrapButton = [self smallToggleOfType:NSSwitchButton frame:NSMakeRect(35, 75, 18, 18)];
	_wrapButton.state = parameters.wrapAround ? NSControlStateValueOn : NSControlStateValueOff;
	_wrapButton.accessibilityLabel = @"Wrap around corners";
	_repeatButton = [self smallToggleOfType:NSSwitchButton frame:NSMakeRect(177, 53, 18, 18)];
	_repeatButton.state = parameters.repeatEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	_repeatButton.accessibilityLabel = @"Repeat the filter";

	_repeatSlider = [[PPConvolveSlider alloc] initWithFrame:NSMakeRect(212, 41, 96, 11)];
	_repeatSlider.minimumValue = 1.0;
	_repeatSlider.maximumValue = 11.0;
	_repeatSlider.doubleValue = MIN(MAX(parameters.repeatCount, 1), 11);
	_repeatSlider.target = self;
	_repeatSlider.action = @selector(updateRepeatDescription:);
	_repeatSlider.accessibilityLabel = @"Repeat count";
	[self.window.contentView addSubview:_repeatSlider];
	[self updateRepeatDescription:nil];

	NSArray<NSString *> *buttonTitles = @[@"OK", @"Cancel"];
	SEL buttonActions[] = {@selector(accept:), @selector(cancel:)};
	CGFloat buttonX[] = {45.0, 89.0};
	CGFloat buttonWidth[] = {46.0, 64.0};
	for (NSInteger index = 0; index < 2; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index]
			target:self action:buttonActions[index]];
		button.frame = NSMakeRect(buttonX[index], 17, buttonWidth[index], 24);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
			[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
		button.focusRingType = NSFocusRingTypeNone;
		button.keyEquivalent = index == 0 ? @"\r" : @"\e";
		[self.window.contentView addSubview:button];
	}
	self.window.initialFirstResponder = self.startFrequencyField;
	return self;
}

- (void)selectMode:(NSButton *)sender
{
	for (NSButton *button in self.modeButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)updateRepeatDescription:(id)sender
{
	(void)sender;
	NSInteger count = MIN(MAX((NSInteger)llround(self.repeatSlider.doubleValue), 1), 11);
	NSString *description = [NSString stringWithFormat:@"%ld passes", (long)count];
	self.repeatSlider.accessibilityValueDescription = description;
	self.repeatSlider.toolTip = description;
}

- (PPIIRFilterParameters)parameters
{
	PPIIRFilterMode mode = PPIIRFilterLowPass;
	for (NSButton *button in self.modeButtons) {
		if (button.state == NSControlStateValueOn) mode = (PPIIRFilterMode)button.tag;
	}
	return (PPIIRFilterParameters){
		.mode = mode,
		.startFrequency = MIN(MAX(self.startFrequencyField.integerValue, 0), 32767),
		.endFrequency = MIN(MAX(self.endFrequencyField.integerValue, 0), 32767),
		.sweepFrequency = self.sweepButton.state == NSControlStateValueOn,
		.wrapAround = self.wrapButton.state == NSControlStateValueOn,
		.repeatEnabled = self.repeatButton.state == NSControlStateValueOn,
		.repeatCount = MIN(MAX((NSInteger)llround(self.repeatSlider.doubleValue), 1), 11)
	};
}

- (void)accept:(id)sender
{
	(void)sender;
	[self.window makeFirstResponder:nil];
	[NSApp stopModalWithCode:NSModalResponseOK];
}
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPNoiseDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSArray<NSButton *> *modeButtons;
@property(nonatomic, strong) NSTextField *ringComponentField;
@property(nonatomic, strong) NSTextField *ringMinimumField;
@property(nonatomic, strong) NSTextField *ringMaximumField;
@property(nonatomic, strong) NSTextField *frequencyBPMField;
@property(nonatomic, strong) NSTextField *frequencyMinimumField;
@property(nonatomic, strong) NSTextField *frequencyMaximumField;
@property(nonatomic, readonly) PPNoiseParameters parameters;
@end

@implementation PPNoiseDialogController

- (void)addArtworkNamed:(NSString *)name frame:(NSRect)frame
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image == nil) return;
	NSImageView *view = [[NSImageView alloc] initWithFrame:frame];
	view.image = image;
	view.imageScaling = NSImageScaleNone;
	view.imageAlignment = NSImageAlignCenter;
	view.accessibilityLabel = [NSString stringWithFormat:@"Original %@ artwork", name];
	[self.window.contentView addSubview:view];
}

- (NSTextField *)integerField:(NSInteger)value frame:(NSRect)frame
	minimum:(NSInteger)minimum maximum:(NSInteger)maximum label:(NSString *)label
{
	NSTextField *field = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)value]];
	field.frame = frame;
	field.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	field.alignment = NSTextAlignmentCenter;
	field.textColor = NSColor.blackColor;
	field.backgroundColor = NSColor.whiteColor;
	field.focusRingType = NSFocusRingTypeExterior;
	field.accessibilityLabel = label;
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.allowsFloats = NO;
	formatter.minimum = @(minimum);
	formatter.maximum = @(maximum);
	field.formatter = formatter;
	[self.window.contentView addSubview:field];
	return field;
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPNoiseParameters parameters = *PPPersistentNoiseParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 219, 402)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Noooiise";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 219, 402)];

	[self addArtworkNamed:@"Noooiise-Ornament" frame:NSMakeRect(32, 14, 7, 384)];
	[self addArtworkNamed:@"Noooiise-Ornament" frame:NSMakeRect(180, 14, 7, 384)];
	[self addArtworkNamed:@"Noooiise-RM-Divider" frame:NSMakeRect(44, 348, 134, 6)];
	[self addArtworkNamed:@"Noooiise-RM-Icon" frame:NSMakeRect(148, 302, 16, 16)];
	[self addArtworkNamed:@"Noooiise-Frequency-Divider" frame:NSMakeRect(44, 257, 124, 5)];
	[self addArtworkNamed:@"Noooiise-Credit" frame:NSMakeRect(64, 4, 85, 14)];

	NSFont *bold = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	NSArray<NSString *> *titles = @[@"White Noise", @"Gaussian Noise", @"RM-Noise", @"Freq Noise"];
	CGFloat tops[] = {8.0, 28.0, 60.0, 156.0};
	NSMutableArray<NSButton *> *buttons = [NSMutableArray arrayWithCapacity:4];
	for (NSInteger index = 0; index < 4; index++) {
		NSButton *button = [NSButton radioButtonWithTitle:titles[index]
			target:self action:@selector(selectMode:)];
		button.frame = NSMakeRect(52, 402.0 - tops[index] - 18.0, 128, 20);
		button.font = bold;
		button.tag = index + 1;
		button.focusRingType = NSFocusRingTypeNone;
		button.state = parameters.mode == index + 1 ? NSControlStateValueOn : NSControlStateValueOff;
		[self.window.contentView addSubview:button];
		[buttons addObject:button];
	}
	_modeButtons = buttons;

	_ringComponentField = [self integerField:parameters.ringComponentCount
		frame:NSMakeRect(112, 300, 32, 20) minimum:2 maximum:256
		label:@"RM-Noise component count"];
	_ringMinimumField = [self integerField:parameters.ringMinimumHertz
		frame:NSMakeRect(56, 272, 32, 20) minimum:0 maximum:32767
		label:@"RM-Noise minimum frequency in hertz"];
	_ringMaximumField = [self integerField:parameters.ringMaximumHertz
		frame:NSMakeRect(112, 272, 32, 20) minimum:0 maximum:32767
		label:@"RM-Noise maximum frequency in hertz"];
	_frequencyBPMField = [self integerField:parameters.frequencyBPM
		frame:NSMakeRect(104, 204, 32, 20) minimum:1 maximum:32767
		label:@"Frequency Noise tempo in beats per minute"];
	_frequencyMinimumField = [self integerField:parameters.frequencyMinimumHertz
		frame:NSMakeRect(56, 176, 32, 20) minimum:0 maximum:32767
		label:@"Frequency Noise minimum frequency in hertz"];
	_frequencyMaximumField = [self integerField:parameters.frequencyMaximumHertz
		frame:NSMakeRect(112, 176, 32, 20) minimum:0 maximum:32767
		label:@"Frequency Noise maximum frequency in hertz"];

	NSArray<NSString *> *buttonTitles = @[@"OK", @"Cancel"];
	SEL actions[] = {@selector(accept:), @selector(cancel:)};
	CGFloat ys[] = {64.0, 32.0};
	for (NSInteger index = 0; index < 2; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index]
			target:self action:actions[index]];
		button.frame = NSMakeRect(72, ys[index], 66, 24);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = bold;
		button.focusRingType = NSFocusRingTypeNone;
		button.keyEquivalent = index == 0 ? @"\r" : @"\e";
		[self.window.contentView addSubview:button];
	}
	self.window.initialFirstResponder = self.ringComponentField;
	return self;
}

- (void)selectMode:(NSButton *)sender
{
	for (NSButton *button in self.modeButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (PPNoiseParameters)parameters
{
	PPNoiseMode mode = PPNoiseModeRing;
	for (NSButton *button in self.modeButtons) {
		if (button.state == NSControlStateValueOn) mode = (PPNoiseMode)button.tag;
	}
	NSInteger ringMinimum = MIN(self.ringMinimumField.integerValue,
		self.ringMaximumField.integerValue);
	NSInteger ringMaximum = MAX(self.ringMinimumField.integerValue,
		self.ringMaximumField.integerValue);
	NSInteger frequencyMinimum = MIN(self.frequencyMinimumField.integerValue,
		self.frequencyMaximumField.integerValue);
	NSInteger frequencyMaximum = MAX(self.frequencyMinimumField.integerValue,
		self.frequencyMaximumField.integerValue);
	return (PPNoiseParameters){
		.mode = mode,
		.ringComponentCount = MIN(MAX(self.ringComponentField.integerValue, 2), 256),
		.ringMinimumHertz = MIN(MAX(ringMinimum, 0), 32767),
		.ringMaximumHertz = MIN(MAX(ringMaximum, 0), 32767),
		.frequencyBPM = MIN(MAX(self.frequencyBPMField.integerValue, 1), 32767),
		.frequencyMinimumHertz = MIN(MAX(frequencyMinimum, 0), 32767),
		.frequencyMaximumHertz = MIN(MAX(frequencyMaximum, 0), 32767)
	};
}

- (void)accept:(id)sender
{
	(void)sender;
	[self.window makeFirstResponder:nil];
	[NSApp stopModalWithCode:NSModalResponseOK];
}
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPRingWaveControl : NSControl
@property(nonatomic) PPRingWaveShape shape;
@end

@implementation PPRingWaveControl

- (BOOL)isOpaque { return NO; }

- (NSString *)shapeName
{
	switch (self.shape) {
		case PPRingWaveTriangle: return @"triangle";
		case PPRingWaveSaw: return @"sawtooth";
		case PPRingWaveSquare: return @"square";
		default: return @"sine";
	}
}

- (void)setShape:(PPRingWaveShape)shape
{
	_shape = shape;
	self.toolTip = [NSString stringWithFormat:@"%@ wave — click to change", self.shapeName];
	self.accessibilityValue = self.shapeName;
	[self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSBezierPath *path = [NSBezierPath bezierPath];
	path.lineWidth = 1.0;
	CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
	for (NSInteger pixel = 0; pixel < (NSInteger)width; pixel++) {
		double phase = width <= 1.0 ? 0.0 : (double)pixel / (width - 1.0);
		double value = 0.0;
		switch (self.shape) {
			case PPRingWaveTriangle: value = 1.0 - 4.0 * fabs(phase - 0.5); break;
			case PPRingWaveSaw: value = 1.0 - 2.0 * phase; break;
			case PPRingWaveSquare: value = phase < 0.5 ? 1.0 : -1.0; break;
			default: value = sin(phase * M_PI * 2.0); break;
		}
		NSPoint point = NSMakePoint(pixel + 0.5, height * 0.5 + value * (height * 0.38));
		if (pixel == 0) [path moveToPoint:point]; else [path lineToPoint:point];
	}
	[path stroke];
}

- (void)mouseDown:(NSEvent *)event
{
	(void)event;
	if (!self.enabled) return;
	self.shape = (PPRingWaveShape)((self.shape + 1) % 4);
	[self sendAction:self.action to:self.target];
}

@end

@interface PPRingModulateDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSArray<NSButton *> *modeButtons;
@property(nonatomic, strong) NSTextField *frequencyField;
@property(nonatomic, strong) NSTextField *mixField;
@property(nonatomic, strong) NSButton *modulateButton;
@property(nonatomic, strong) NSTextField *depthField;
@property(nonatomic, strong) NSArray<NSButton *> *sourceButtons;
@property(nonatomic, strong) NSTextField *rateField;
@property(nonatomic, strong) PPRingWaveControl *firstWaveControl;
@property(nonatomic, strong) PPRingWaveControl *secondWaveControl;
@property(nonatomic, strong) NSButton *morphButton;
@property(nonatomic, strong) NSSlider *senseSlider;
@property(nonatomic, readonly) PPRingModulateParameters parameters;
@end

@implementation PPRingModulateDialogController

- (NSRect)classicRectLeft:(CGFloat)left top:(CGFloat)top right:(CGFloat)right bottom:(CGFloat)bottom
{
	return NSMakeRect(left, 140.0 - bottom, right - left, bottom - top);
}

- (void)addArtworkNamed:(NSString *)name left:(CGFloat)left top:(CGFloat)top
	right:(CGFloat)right bottom:(CGFloat)bottom label:(NSString *)label
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image == nil) return;
	NSImageView *view = [[NSImageView alloc] initWithFrame:[self classicRectLeft:left top:top right:right bottom:bottom]];
	view.image = image;
	view.imageScaling = NSImageScaleNone;
	view.imageAlignment = NSImageAlignCenter;
	view.accessibilityLabel = label;
	[self.window.contentView addSubview:view];
}

- (void)addClassicLabel:(NSString *)title left:(CGFloat)left top:(CGFloat)top
	right:(CGFloat)right bottom:(CGFloat)bottom color:(NSColor *)color alignment:(NSTextAlignment)alignment
{
	NSTextField *label = [NSTextField labelWithString:title];
	label.frame = [self classicRectLeft:left top:top right:right bottom:bottom];
	label.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	label.textColor = color ?: NSColor.blackColor;
	label.alignment = alignment;
	label.drawsBackground = YES;
	label.backgroundColor = NSColor.whiteColor;
	label.lineBreakMode = NSLineBreakByClipping;
	[self.window.contentView addSubview:label];
}

- (NSButton *)toggleOfType:(NSButtonType)type left:(CGFloat)left top:(CGFloat)top
	right:(CGFloat)right bottom:(CGFloat)bottom action:(SEL)action label:(NSString *)label
{
	NSButton *button = [[NSButton alloc] initWithFrame:[self classicRectLeft:left top:top right:right bottom:bottom]];
	button.buttonType = type;
	button.title = @"";
	button.target = self;
	button.action = action;
	button.focusRingType = NSFocusRingTypeNone;
	button.accessibilityLabel = label;
	[self.window.contentView addSubview:button];
	return button;
}

- (NSTextField *)integerField:(NSInteger)value left:(CGFloat)left top:(CGFloat)top
	right:(CGFloat)right bottom:(CGFloat)bottom minimum:(NSInteger)minimum maximum:(NSInteger)maximum
	label:(NSString *)label
{
	NSTextField *field = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)value]];
	field.frame = [self classicRectLeft:left top:top right:right bottom:bottom];
	field.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	field.alignment = NSTextAlignmentCenter;
	field.textColor = NSColor.blackColor;
	field.backgroundColor = NSColor.whiteColor;
	field.focusRingType = NSFocusRingTypeExterior;
	field.accessibilityLabel = label;
	NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
	formatter.allowsFloats = NO;
	formatter.minimum = @(minimum);
	formatter.maximum = @(maximum);
	field.formatter = formatter;
	[self.window.contentView addSubview:field];
	return field;
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPRingModulateParameters parameters = *PPPersistentRingModulateParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 564, 140)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"RingModulate";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 564, 140)];

	NSArray<NSString *> *modeLabels = @[@"Ring modulate", @"De-ring modulate", @"Amplitude demodulate"];
	CGFloat modeTops[] = {8, 32, 56};
	CGFloat labelRights[] = {100, 117, 128};
	NSMutableArray<NSButton *> *modes = [NSMutableArray arrayWithCapacity:3];
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [self toggleOfType:NSButtonTypeRadio left:8 top:modeTops[index]
			right:24 bottom:modeTops[index] + 16 action:@selector(selectMode:) label:modeLabels[index]];
		button.tag = index + 1;
		button.state = parameters.mode == index + 1 ? NSControlStateValueOn : NSControlStateValueOff;
		[modes addObject:button];
		[self addClassicLabel:modeLabels[index] left:24 top:modeTops[index] - 4
			right:labelRights[index] bottom:modeTops[index] + 19 color:NSColor.blackColor
			alignment:NSTextAlignmentLeft];
	}
	_modeButtons = modes;

	[self addClassicLabel:@"Frequency:" left:132 top:6 right:195 bottom:27 color:NSColor.blackColor
		alignment:NSTextAlignmentRight];
	_frequencyField = [self integerField:parameters.frequencyHertz left:200 top:10 right:240 bottom:24
		minimum:1 maximum:32767 label:@"Carrier frequency in hertz"];
	[self addClassicLabel:@"Hz" left:244 top:8 right:268 bottom:27 color:NSColor.blackColor
		alignment:NSTextAlignmentLeft];
	[self addClassicLabel:@"Mix:" left:156 top:40 right:195 bottom:61 color:NSColor.blackColor
		alignment:NSTextAlignmentRight];
	_mixField = [self integerField:parameters.mixPercent left:200 top:42 right:230 bottom:56
		minimum:0 maximum:100 label:@"Effect mix in percent"];
	[self addClassicLabel:@"%" left:236 top:40 right:252 bottom:58 color:NSColor.blackColor
		alignment:NSTextAlignmentLeft];

	_modulateButton = [self toggleOfType:NSSwitchButton left:280 top:8 right:296 bottom:24
		action:@selector(updateEnabledState:) label:@"Modulate frequency"];
	_modulateButton.state = parameters.modulateFrequency ? NSControlStateValueOn : NSControlStateValueOff;
	[self addClassicLabel:@"modulate freq" left:296 top:8 right:369 bottom:24 color:NSColor.blackColor
		alignment:NSTextAlignmentLeft];
	[self addClassicLabel:@"+/−" left:300 top:28 right:318 bottom:42 color:NSColor.blackColor
		alignment:NSTextAlignmentCenter];
	_depthField = [self integerField:parameters.modulationDepthHertz left:324 top:28 right:356 bottom:42
		minimum:0 maximum:32767 label:@"Frequency modulation depth in hertz"];
	[self addClassicLabel:@"Hz" left:360 top:28 right:384 bottom:47 color:NSColor.blackColor
		alignment:NSTextAlignmentLeft];

	NSArray<NSString *> *sourceLabels = @[@"Ramp frequency up", @"Ramp frequency down", @"Sine frequency modulation",
		@"Modulate with sample", @"Envelope follower"];
	NSArray<NSString *> *sourceDisplay = @[@"╱", @"╲", @"∿", @"with Sample", @""];
	CGFloat sourceLeft[] = {292, 304, 320, 340, 360};
	CGFloat sourceTop[] = {48, 68, 84, 100, 120};
	CGFloat artLeft[] = {316, 332, 340, 356, 376};
	CGFloat artTop[] = {48, 68, 84, 100, 122};
	CGFloat artRight[] = {346, 356, 397, 424, 466};
	CGFloat artBottom[] = {61, 81, 100, 119, 137};
	NSMutableArray<NSButton *> *sources = [NSMutableArray arrayWithCapacity:5];
	for (NSInteger index = 0; index < 5; index++) {
		NSButton *button = [self toggleOfType:NSButtonTypeRadio left:sourceLeft[index] top:sourceTop[index]
			right:sourceLeft[index] + 16 bottom:sourceTop[index] + 16
			action:@selector(selectSource:) label:sourceLabels[index]];
		button.tag = index + 1;
		button.state = parameters.frequencySource == index + 1 ? NSControlStateValueOn : NSControlStateValueOff;
		[sources addObject:button];
		if (index == 4) {
			[self addArtworkNamed:@"RingModulate-Envelope-Follower" left:artLeft[index] top:artTop[index]
				right:artRight[index] bottom:artBottom[index] label:sourceLabels[index]];
		} else {
			[self addClassicLabel:sourceDisplay[index] left:artLeft[index] top:artTop[index]
				right:artRight[index] bottom:artBottom[index] color:NSColor.blackColor
				alignment:index == 3 ? NSTextAlignmentLeft : NSTextAlignmentCenter];
		}
	}
	_sourceButtons = sources;
	[self addClassicLabel:@"@" left:400 top:84 right:411 bottom:96 color:NSColor.blackColor
		alignment:NSTextAlignmentCenter];
	_rateField = [self integerField:parameters.modulationRateHundredthHertz left:420 top:80 right:452 bottom:94
		minimum:1 maximum:32767 label:@"Sine modulation rate in hundredths of a hertz"];
	[self addClassicLabel:@"%" left:456 top:80 right:472 bottom:98 color:NSColor.blackColor
		alignment:NSTextAlignmentCenter];
	[self addClassicLabel:@"Hz" left:472 top:80 right:496 bottom:99 color:NSColor.blackColor
		alignment:NSTextAlignmentLeft];

	_firstWaveControl = [[PPRingWaveControl alloc] initWithFrame:[self classicRectLeft:404 top:12 right:436 bottom:44]];
	_firstWaveControl.shape = parameters.firstWave;
	_firstWaveControl.target = self;
	_firstWaveControl.action = @selector(waveChanged:);
	_firstWaveControl.accessibilityLabel = @"First carrier wave";
	[self.window.contentView addSubview:_firstWaveControl];
	_secondWaveControl = [[PPRingWaveControl alloc] initWithFrame:[self classicRectLeft:500 top:12 right:532 bottom:44]];
	_secondWaveControl.shape = parameters.secondWave;
	_secondWaveControl.target = self;
	_secondWaveControl.action = @selector(waveChanged:);
	_secondWaveControl.accessibilityLabel = @"Second carrier wave";
	[self.window.contentView addSubview:_secondWaveControl];
	[self addClassicLabel:@"────→" left:440 top:16 right:495 bottom:25 color:NSColor.blackColor
		alignment:NSTextAlignmentCenter];
	_morphButton = [self toggleOfType:NSSwitchButton left:456 top:28 right:472 bottom:44
		action:@selector(updateEnabledState:) label:@"Morph from first to second wave"];
	_morphButton.state = parameters.morphWave ? NSControlStateValueOn : NSControlStateValueOff;

	_senseSlider = [[NSSlider alloc] initWithFrame:[self classicRectLeft:468 top:112 right:564 bottom:128]];
	_senseSlider.minValue = 0.0;
	_senseSlider.maxValue = 0.999;
	_senseSlider.doubleValue = parameters.envelopeSense;
	_senseSlider.continuous = YES;
	_senseSlider.accessibilityLabel = @"Envelope follower sense";
	[self.window.contentView addSubview:_senseSlider];
	[self addClassicLabel:@"sense" left:484 top:126 right:524 bottom:138
		color:[NSColor colorWithCalibratedRed:0.2 green:0.45 blue:0.2 alpha:1.0]
		alignment:NSTextAlignmentCenter];

	[self addClassicLabel:@"RingModulation by Pandaa" left:0 top:112 right:145 bottom:132
		color:[NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.18 alpha:1.0]
		alignment:NSTextAlignmentLeft];
	NSArray<NSString *> *buttonTitles = @[@"OK", @"Cancel"];
	SEL actions[] = {@selector(accept:), @selector(cancel:)};
	CGFloat buttonLeft[] = {160, 230};
	CGFloat buttonRight[] = {218, 288};
	for (NSInteger index = 0; index < 2; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index] target:self action:actions[index]];
		button.frame = [self classicRectLeft:buttonLeft[index] top:112 right:buttonRight[index] bottom:136];
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
			[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
		button.focusRingType = NSFocusRingTypeNone;
		button.keyEquivalent = index == 0 ? @"\r" : @"\e";
		[self.window.contentView addSubview:button];
	}
	[self updateEnabledState:nil];
	self.window.initialFirstResponder = self.frequencyField;
	return self;
}

- (void)selectMode:(NSButton *)sender
{
	for (NSButton *button in self.modeButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)selectSource:(NSButton *)sender
{
	for (NSButton *button in self.sourceButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateEnabledState:nil];
}

- (void)waveChanged:(id)sender { (void)sender; }

- (void)updateEnabledState:(id)sender
{
	(void)sender;
	BOOL enabled = self.modulateButton.state == NSControlStateValueOn;
	self.depthField.enabled = enabled;
	for (NSButton *button in self.sourceButtons) button.enabled = enabled;
	PPRingFrequencySource source = PPRingFrequencyRampUp;
	for (NSButton *button in self.sourceButtons)
		if (button.state == NSControlStateValueOn) source = (PPRingFrequencySource)button.tag;
	self.rateField.enabled = enabled && source == PPRingFrequencySine;
	self.senseSlider.enabled = enabled && source == PPRingFrequencyEnvelope;
	self.secondWaveControl.enabled = self.morphButton.state == NSControlStateValueOn;
}

- (PPRingModulateParameters)parameters
{
	PPRingModulateMode mode = PPRingModulateModeRing;
	for (NSButton *button in self.modeButtons)
		if (button.state == NSControlStateValueOn) mode = (PPRingModulateMode)button.tag;
	PPRingFrequencySource source = PPRingFrequencyRampUp;
	for (NSButton *button in self.sourceButtons)
		if (button.state == NSControlStateValueOn) source = (PPRingFrequencySource)button.tag;
	return (PPRingModulateParameters){
		.mode = mode,
		.frequencyHertz = MIN(MAX(self.frequencyField.integerValue, 1), 32767),
		.mixPercent = MIN(MAX(self.mixField.integerValue, 0), 100),
		.modulateFrequency = self.modulateButton.state == NSControlStateValueOn,
		.modulationDepthHertz = MIN(MAX(self.depthField.integerValue, 0), 32767),
		.frequencySource = source,
		.modulationRateHundredthHertz = MIN(MAX(self.rateField.integerValue, 1), 32767),
		.firstWave = self.firstWaveControl.shape,
		.secondWave = self.secondWaveControl.shape,
		.morphWave = self.morphButton.state == NSControlStateValueOn,
		.envelopeSense = MIN(MAX(self.senseSlider.doubleValue, 0.0), 0.999)
	};
}

- (void)accept:(id)sender
{
	(void)sender;
	[self.window makeFirstResponder:nil];
	[NSApp stopModalWithCode:NSModalResponseOK];
}
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }
- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

@interface PPConvolveDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSButton *tailButton;
@property(nonatomic, strong) NSButton *wrapButton;
@property(nonatomic, strong) NSButton *normalizeButton;
@property(nonatomic, strong) NSButton *sumOneButton;
@property(nonatomic, strong) NSArray<NSButton *> *impulseButtons;
@property(nonatomic, strong) NSTextField *cutoffField;
@property(nonatomic, strong) PPConvolveSlider *gainSlider;
@property(nonatomic, strong) PPConvolveSlider *qualitySlider;
@property(nonatomic, readonly) PPConvolveParameters parameters;
@end

@implementation PPConvolveDialogController

- (NSFont *)fontWithSize:(CGFloat)size bold:(BOOL)bold
{
	NSString *name = bold ? @"Monaco-Bold" : @"Monaco";
	return [NSFont fontWithName:name size:size] ?:
		[NSFont monospacedSystemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightRegular];
}

- (NSTextField *)label:(NSString *)title frame:(NSRect)frame bold:(BOOL)bold
{
	NSTextField *label = [NSTextField labelWithString:title];
	label.frame = frame;
	label.font = [self fontWithSize:9.0 bold:bold];
	label.textColor = NSColor.blackColor;
	label.lineBreakMode = NSLineBreakByClipping;
	[self.window.contentView addSubview:label];
	return label;
}

- (void)addArtworkNamed:(NSString *)name frame:(NSRect)frame accessibilityLabel:(NSString *)label
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path.length == 0 ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image == nil) return;
	NSImageView *imageView = [[NSImageView alloc] initWithFrame:frame];
	imageView.image = image;
	imageView.imageScaling = NSImageScaleNone;
	imageView.imageAlignment = NSImageAlignCenter;
	imageView.accessibilityLabel = label;
	[self.window.contentView addSubview:imageView];
}

- (instancetype)init
{
	self = [super init];
	if (self == nil) return nil;
	PPConvolveParameters parameters = *PPPersistentConvolveParameters();
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 504, 172)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Convolve with selection";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	_window.contentView = [[PPHzFilterContentView alloc] initWithFrame:NSMakeRect(0, 0, 504, 172)];

	[self addArtworkNamed:@"ConvolveWinged" frame:NSMakeRect(0, 4, 77, 168)
		accessibilityLabel:@"Original Convolve artwork"];
	[self addArtworkNamed:@"ConvolvePulse" frame:NSMakeRect(136, 130, 80, 42)
		accessibilityLabel:@"Impulse pulse artwork"];
	[self addArtworkNamed:@"ConvolveImpulse" frame:NSMakeRect(252, 50, 220, 42)
		accessibilityLabel:@"Impulse response artwork"];
	[self addArtworkNamed:@"ConvolveCredit" frame:NSMakeRect(92, 0, 111, 20)
		accessibilityLabel:@"Convolution by Pandaa"];
	[self addArtworkNamed:@"ConvolveQuality" frame:NSMakeRect(420, 160, 33, 12)
		accessibilityLabel:@"Quality"];
	[self addArtworkNamed:@"ConvolveSpeed" frame:NSMakeRect(472, 101, 28, 11)
		accessibilityLabel:@"Speed"];
	NSArray<NSValue *> *ruleFrames = @[
		[NSValue valueWithRect:NSMakeRect(240, 138, 172, 1)],
		[NSValue valueWithRect:NSMakeRect(256, 94, 247, 1)],
		[NSValue valueWithRect:NSMakeRect(412, 138, 1, 32)]
	];
	for (NSValue *value in ruleFrames) {
		NSBox *rule = [[NSBox alloc] initWithFrame:value.rectValue];
		rule.boxType = NSBoxSeparator;
		[self.window.contentView addSubview:rule];
	}

	_tailButton = [NSButton checkboxWithTitle:@"Tail" target:nil action:nil];
	_tailButton.frame = NSMakeRect(80, 140, 64, 20);
	_tailButton.font = [self fontWithSize:9.0 bold:NO];
	_tailButton.state = parameters.includeTail ? NSControlStateValueOn : NSControlStateValueOff;
	[self.window.contentView addSubview:_tailButton];
	_wrapButton = [NSButton checkboxWithTitle:@"Wrap around edges" target:nil action:nil];
	_wrapButton.frame = NSMakeRect(92, 96, 148, 20);
	_wrapButton.font = [self fontWithSize:9.0 bold:NO];
	_wrapButton.state = parameters.wrapEdges ? NSControlStateValueOn : NSControlStateValueOff;
	[self.window.contentView addSubview:_wrapButton];
	_normalizeButton = [NSButton checkboxWithTitle:@"Normalise Impulse…" target:self action:@selector(updateEnabledControls:)];
	_normalizeButton.frame = NSMakeRect(80, 68, 156, 20);
	_normalizeButton.font = [self fontWithSize:9.0 bold:NO];
	_normalizeButton.state = parameters.normalizeImpulse ? NSControlStateValueOn : NSControlStateValueOff;
	[self.window.contentView addSubview:_normalizeButton];
	_sumOneButton = [NSButton checkboxWithTitle:@"…to a sum of 1" target:nil action:nil];
	_sumOneButton.frame = NSMakeRect(120, 52, 128, 20);
	_sumOneButton.font = [self fontWithSize:9.0 bold:NO];
	_sumOneButton.state = parameters.normalizeToSumOne ? NSControlStateValueOn : NSControlStateValueOff;
	[self.window.contentView addSubview:_sumOneButton];

	[self label:@"Adjust Gain:" frame:NSMakeRect(80, 32, 82, 18) bold:NO];
	_gainSlider = [[PPConvolveSlider alloc] initWithFrame:NSMakeRect(164, 28, 320, 18)];
	_gainSlider.minimumValue = 0.0;
	_gainSlider.maximumValue = 1.0;
	_gainSlider.doubleValue = MIN(MAX(parameters.gain, 0.0), 1.0);
	_gainSlider.accessibilityLabel = @"Adjust Gain";
	_gainSlider.accessibilityValueDescription = [NSString stringWithFormat:@"%.5f times", parameters.gain];
	[self.window.contentView addSubview:_gainSlider];

	[self label:@"Impulse Response:" frame:NSMakeRect(228, 156, 136, 18) bold:YES];
	NSArray<NSString *> *modeNames = @[@"Selection", @"High Pass,", @"Low Pass,"];
	CGFloat modeY[] = {136.0, 116.0, 96.0};
	CGFloat modeX[] = {236.0, 244.0, 260.0};
	NSMutableArray<NSButton *> *modeButtons = [NSMutableArray arrayWithCapacity:3];
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [NSButton radioButtonWithTitle:modeNames[index]
			target:self action:@selector(selectImpulseMode:)];
		button.frame = NSMakeRect(modeX[index], modeY[index], 104, 20);
		button.font = [self fontWithSize:9.0 bold:NO];
		button.tag = index + 1;
		button.state = parameters.impulseMode == index + 1 ? NSControlStateValueOn : NSControlStateValueOff;
		[self.window.contentView addSubview:button];
		[modeButtons addObject:button];
	}
	_impulseButtons = modeButtons.copy;
	[self label:@"cutoff:" frame:NSMakeRect(332, 116, 48, 18) bold:NO];
	_cutoffField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)parameters.cutoffHertz]];
	_cutoffField.frame = NSMakeRect(380, 112, 44, 22);
	_cutoffField.font = [self fontWithSize:9.0 bold:NO];
	_cutoffField.alignment = NSTextAlignmentRight;
	_cutoffField.textColor = NSColor.blackColor;
	_cutoffField.backgroundColor = NSColor.whiteColor;
	NSNumberFormatter *cutoffFormatter = [[NSNumberFormatter alloc] init];
	cutoffFormatter.allowsFloats = NO;
	cutoffFormatter.minimum = @1;
	cutoffFormatter.maximum = @999999;
	_cutoffField.formatter = cutoffFormatter;
	[self.window.contentView addSubview:_cutoffField];
	[self label:@"Hz" frame:NSMakeRect(432, 116, 28, 18) bold:NO];

	_qualitySlider = [[PPConvolveSlider alloc] initWithFrame:NSMakeRect(454, 100, 18, 72)];
	_qualitySlider.minimumValue = 0.0;
	_qualitySlider.maximumValue = 1.0;
	_qualitySlider.doubleValue = MIN(MAX(parameters.quality, 0.0), 1.0);
	_qualitySlider.vertical = YES;
	_qualitySlider.accessibilityLabel = @"Convolution quality versus speed";
	[self.window.contentView addSubview:_qualitySlider];

	NSArray<NSString *> *buttonTitles = @[@"OK", @"Cancel"];
	SEL buttonActions[] = {@selector(accept:), @selector(cancel:)};
	CGFloat buttonX[] = {252.0, 322.0};
	for (NSInteger index = 0; index < 2; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index] target:self action:buttonActions[index]];
		button.frame = NSMakeRect(buttonX[index], 8, 58, 25);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = [self fontWithSize:9.0 bold:YES];
		button.focusRingType = NSFocusRingTypeNone;
		button.keyEquivalent = index == 0 ? @"\r" : @"\e";
		[self.window.contentView addSubview:button];
	}
	self.window.initialFirstResponder = self.cutoffField;
	[self updateEnabledControls:nil];
	return self;
}

- (void)selectImpulseMode:(NSButton *)sender
{
	for (NSButton *button in self.impulseButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateEnabledControls:nil];
}

- (void)updateEnabledControls:(id)sender
{
	(void)sender;
	// The classic dialog leaves these fields editable even when their current
	// mode does not consume them; the settings are retained for the next mode.
	self.cutoffField.enabled = YES;
	self.sumOneButton.enabled = YES;
}

- (PPConvolveParameters)parameters
{
	PPConvolveParameters parameters = {
		.wrapEdges = self.wrapButton.state == NSControlStateValueOn,
		.normalizeImpulse = self.normalizeButton.state == NSControlStateValueOn,
		.normalizeToSumOne = self.sumOneButton.state == NSControlStateValueOn,
		.includeTail = self.tailButton.state == NSControlStateValueOn,
		.impulseMode = PPConvolveImpulseSelection,
		.cutoffHertz = MAX(self.cutoffField.integerValue, 1),
		.gain = self.gainSlider.doubleValue,
		.quality = self.qualitySlider.doubleValue
	};
	for (NSButton *button in self.impulseButtons) {
		if (button.state == NSControlStateValueOn) {
			parameters.impulseMode = (PPConvolveImpulseMode)button.tag;
			break;
		}
	}
	return parameters;
}

- (void)accept:(id)sender { (void)sender; [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)sender { (void)sender; [NSApp abortModal]; }

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

typedef struct __attribute__((packed)) {
	uint32_t magic;
	uint16_t version;
	uint16_t amplitude;
	uint16_t channels;
	uint16_t reserved;
	uint32_t sampleRate;
	uint32_t byteCount;
} PPSampleClipboardHeader;

typedef struct __attribute__((packed)) {
	uint32_t magic;
	int16_t kind;
	uint16_t count;
	uint16_t span;
	uint16_t reserved;
} PPEnvelopeClipboardHeader;

static size_t PPBytesPerFrame(const sData *sample)
{
	if (sample == NULL) return 1;
	size_t bytes = sample->amp == 16 ? 2 : 1;
	return bytes * (sample->stereo ? 2 : 1);
}

static size_t PPAlignedOffset(const sData *sample, NSInteger value)
{
	size_t frameSize = PPBytesPerFrame(sample);
	size_t size = sample == NULL ? 0 : (size_t)MAX(sample->size, 0);
	size_t offset = (size_t)MAX(value, 0);
	if (offset > size) offset = size;
	return offset - (offset % frameSize);
}

static void PPClampLoop(sData *sample)
{
	if (sample == NULL) return;
	if (sample->loopBeg < 0 || sample->loopBeg > sample->size) {
		sample->loopBeg = 0;
		sample->loopSize = 0;
		return;
	}
	if (sample->loopSize < 0) sample->loopSize = 0;
	if (sample->loopBeg + sample->loopSize > sample->size) {
		sample->loopSize = sample->size - sample->loopBeg;
	}
}

static BOOL PPReplaceBytes(sData *sample, const void *bytes, size_t size)
{
	if (sample == NULL || size > INT_MAX) return NO;
	char *replacement = NULL;
	if (size > 0) {
		replacement = malloc(size);
		if (replacement == NULL) return NO;
		memcpy(replacement, bytes, size);
	}
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)size;
	PPClampLoop(sample);
	return YES;
}

static BOOL PPDeleteBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t removed = end - start;
	size_t newSize = (size_t)sample->size - removed;
	char *replacement = newSize == 0 ? NULL : malloc(newSize);
	if (newSize > 0 && replacement == NULL) return NO;
	if (start > 0) memcpy(replacement, sample->data, start);
	if (end < (size_t)sample->size) {
		memcpy(replacement + start, sample->data + end, (size_t)sample->size - end);
	}
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)newSize;
	// Preserve the original 2002 adjustment semantics.
	if (sample->loopBeg > (int)start) sample->loopBeg -= (int)removed;
	PPClampLoop(sample);
	return YES;
}

static BOOL PPInsertBytes(sData *sample, size_t offset, const void *bytes, size_t byteCount)
{
	if (sample == NULL || bytes == NULL || byteCount == 0 || offset > (size_t)sample->size ||
		(size_t)sample->size + byteCount > INT_MAX) return NO;
	size_t newSize = (size_t)sample->size + byteCount;
	char *replacement = malloc(newSize);
	if (replacement == NULL) return NO;
	if (offset > 0) memcpy(replacement, sample->data, offset);
	memcpy(replacement + offset, bytes, byteCount);
	if (offset < (size_t)sample->size) {
		memcpy(replacement + offset + byteCount, sample->data + offset, (size_t)sample->size - offset);
	}
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)newSize;
	if (sample->loopBeg >= (int)offset) sample->loopBeg += (int)byteCount;
	PPClampLoop(sample);
	return YES;
}

static BOOL PPCropBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	NSInteger oldLoopStart = sample->loopBeg;
	NSInteger oldLoopEnd = sample->loopBeg + sample->loopSize;
	if (!PPReplaceBytes(sample, sample->data + start, end - start)) return NO;
	NSInteger intersectionStart = MAX(oldLoopStart, (NSInteger)start);
	NSInteger intersectionEnd = MIN(oldLoopEnd, (NSInteger)end);
	if (intersectionEnd > intersectionStart) {
		sample->loopBeg = (int)(intersectionStart - (NSInteger)start);
		sample->loopSize = (int)(intersectionEnd - intersectionStart);
	} else {
		sample->loopBeg = 0;
		sample->loopSize = 0;
	}
	return YES;
}

static BOOL PPReverseBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	if ((end - start) < frameSize) return NO;
	char temporary[4] = {0};
	for (size_t left = start, right = end - frameSize; left < right; left += frameSize, right -= frameSize) {
		memcpy(temporary, sample->data + left, frameSize);
		memcpy(sample->data + left, sample->data + right, frameSize);
		memcpy(sample->data + right, temporary, frameSize);
	}
	return YES;
}

static BOOL PPNormalizeBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	if (sample->amp == 16) {
		int16_t *values = (int16_t *)(sample->data + start);
		size_t count = (end - start) / sizeof(int16_t);
		int32_t peak = 0;
		for (size_t index = 0; index < count; index++) {
			int32_t magnitude = values[index] == INT16_MIN ? 32768 : abs(values[index]);
			if (magnitude > peak) peak = magnitude;
		}
		if (peak == 0) return YES;
		// The original plug-in uses a signed 16.16 factor derived from
		// 0x80000000 / peak, then truncates toward zero after multiplying.
		int32_t factor = INT32_MIN / peak;
		for (size_t index = 0; index < count; index++) {
			int64_t product = -(int64_t)factor * (int64_t)values[index];
			int64_t scaled = product / 65536;
			values[index] = (int16_t)MAX(MIN(scaled, INT16_MAX), INT16_MIN);
		}
	} else {
		int8_t *values = (int8_t *)(sample->data + start);
		size_t count = end - start;
		int16_t peak = 0;
		for (size_t index = 0; index < count; index++) {
			int16_t magnitude = values[index] == INT8_MIN ? 128 : abs(values[index]);
			if (magnitude > peak) peak = magnitude;
		}
		if (peak == 0) return YES;
		// Classic Normalize uses 128 rather than 127 as its target, with a
		// 16.16 integer multiplier and an explicit symmetric +/-127 clamp.
		int32_t factor = 0x00800000 / peak;
		for (size_t index = 0; index < count; index++) {
			int32_t scaled = ((int32_t)values[index] * factor) / 65536;
			values[index] = (int8_t)MAX(MIN(scaled, 127), -127);
		}
	}
	return YES;
}

static BOOL PPInvertBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	if (sample->amp == 16) {
		int16_t *values = (int16_t *)(sample->data + start);
		size_t count = (end - start) / sizeof(int16_t);
		for (size_t index = 0; index < count; index++) values[index] = (int16_t)~(uint16_t)values[index];
	} else {
		int8_t *values = (int8_t *)(sample->data + start);
		for (size_t index = 0; index < end - start; index++) values[index] = (int8_t)~(uint8_t)values[index];
	}
	return YES;
}

static BOOL PPSilenceBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	memset(sample->data + start, 0, end - start);
	return YES;
}

static BOOL PPAmplifyBytes(sData *sample, size_t start, size_t end, double gain)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size || gain < 0.0) return NO;
	int32_t percent = (int32_t)trunc(gain * 100.0);
	if (sample->amp == 16) {
		int16_t *values = (int16_t *)(sample->data + start);
		size_t count = (end - start) / sizeof(int16_t);
		for (size_t index = 0; index < count; index++) {
			// Classic Amplitude performs signed integer division by 100.
			int64_t scaled = (int64_t)values[index] * percent / 100;
			values[index] = (int16_t)MAX(MIN(scaled, INT16_MAX), INT16_MIN);
		}
	} else {
		int8_t *values = (int8_t *)(sample->data + start);
		for (size_t index = 0; index < end - start; index++) {
			int32_t scaled = (int32_t)values[index] * percent / 100;
			values[index] = (int8_t)MAX(MIN(scaled, 127), -127);
		}
	}
	return YES;
}

static BOOL PPFadeBytes(sData *sample, size_t start, size_t end, BOOL fadeIn)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t frames = (end - start) / frameSize;
	if (frames < 2) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	if (sample->amp == 16) {
		int16_t *values = (int16_t *)(sample->data + start);
		for (size_t frame = 0; frame < frames; frame++) {
			double gain = (double)frame / (double)(frames - 1);
			if (!fadeIn) gain = 1.0 - gain;
			for (size_t channel = 0; channel < channels; channel++) {
				int64_t scaled = llround((double)values[frame * channels + channel] * gain);
				values[frame * channels + channel] = (int16_t)MAX(MIN(scaled, INT16_MAX), INT16_MIN);
			}
		}
	} else {
		int8_t *values = (int8_t *)(sample->data + start);
		for (size_t frame = 0; frame < frames; frame++) {
			double gain = (double)frame / (double)(frames - 1);
			if (!fadeIn) gain = 1.0 - gain;
			for (size_t channel = 0; channel < channels; channel++) {
				int32_t scaled = (int32_t)llround((double)values[frame * channels + channel] * gain);
				values[frame * channels + channel] = (int8_t)MAX(MIN(scaled, INT8_MAX), INT8_MIN);
			}
		}
	}
	return YES;
}

static BOOL PPSmoothBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t frames = (end - start) / frameSize;
	if (frames < 3) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t length = end - start;
	void *source = malloc(length);
	if (source == NULL) return NO;
	memcpy(source, sample->data + start, length);
	if (sample->amp == 16) {
		const int16_t *input = source;
		int16_t *output = (int16_t *)(sample->data + start);
		for (size_t frame = 1; frame + 1 < frames; frame++) {
			for (size_t channel = 0; channel < channels; channel++) {
				size_t index = frame * channels + channel;
				int32_t sum = input[index - channels] + 6 * (int32_t)input[index] + input[index + channels];
				output[index] = (int16_t)(sum >> 3);
			}
		}
	} else {
		const int8_t *input = source;
		int8_t *output = (int8_t *)(sample->data + start);
		for (size_t frame = 1; frame + 1 < frames; frame++) {
			for (size_t channel = 0; channel < channels; channel++) {
				size_t index = frame * channels + channel;
				int16_t sum = input[index - channels] + 6 * (int16_t)input[index] + input[index + channels];
				output[index] = (int8_t)(sum >> 3);
			}
		}
	}
	free(source);
	return YES;
}

static double PPReadNormalizedPCM(const void *data, MADByte amplitude, size_t channels, size_t frame, size_t channel)
{
	size_t index = frame * channels + MIN(channel, channels - 1);
	if (amplitude == 16) {
		int16_t value = ((const int16_t *)data)[index];
		return value / (value < 0 ? 32768.0 : 32767.0);
	}
	int8_t value = ((const int8_t *)data)[index];
	return value / (value < 0 ? 128.0 : 127.0);
}

static void PPWriteNormalizedPCM(void *data, MADByte amplitude, size_t channels, size_t frame, size_t channel, double value)
{
	value = MAX(MIN(value, 1.0), -1.0);
	size_t index = frame * channels + channel;
	if (amplitude == 16) {
		long scaled = lround(value * (value < 0.0 ? 32768.0 : 32767.0));
		((int16_t *)data)[index] = (int16_t)MAX(MIN(scaled, INT16_MAX), INT16_MIN);
	} else {
		long scaled = lround(value * (value < 0.0 ? 128.0 : 127.0));
		((int8_t *)data)[index] = (int8_t)MAX(MIN(scaled, INT8_MAX), INT8_MIN);
	}
}

static BOOL PPFreeverbBytes(sData *sample, size_t start, size_t end, PPFreeverbParameters parameters)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	if (frames > SIZE_MAX / (channels * sizeof(float))) return NO;
	float *interleaved = calloc(frames * channels, sizeof(float));
	if (interleaved == NULL) return NO;
	void *selection = sample->data + start;
	for (size_t frame = 0; frame < frames; frame++) {
		for (size_t channel = 0; channel < channels; channel++) {
			interleaved[frame * channels + channel] = (float)PPReadNormalizedPCM(selection,
				sample->amp, channels, frame, channel);
		}
	}
	BOOL succeeded = PPFreeverbProcessInterleaved(interleaved, frames, (unsigned int)channels,
		MAX((double)sample->c2spd, 1.0), parameters);
	if (succeeded) {
		for (size_t frame = 0; frame < frames; frame++) {
			for (size_t channel = 0; channel < channels; channel++) {
				PPWriteNormalizedPCM(selection, sample->amp, channels, frame, channel,
					interleaved[frame * channels + channel]);
			}
		}
	}
	free(interleaved);
	return succeeded;
}

static BOOL PPFadePercentBytes(sData *sample, size_t start, size_t end, double fromPercent, double toPercent)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size ||
		!isfinite(fromPercent) || !isfinite(toPercent)) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t frames = (end - start) / frameSize;
	if (frames == 0) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	int32_t from = (int32_t)trunc(fromPercent);
	int32_t to = (int32_t)trunc(toPercent);
	void *selection = sample->data + start;
	for (size_t frame = 0; frame < frames; frame++) {
		// This intentionally preserves the 2002 plug-in's ordering: the first
		// sample uses the "to" value and advances toward (but does not quite
		// reach) "from", because the increment is divided by the sample count.
		int32_t percent = to + (int64_t)frame * (from - to) / (int64_t)frames;
		for (size_t channel = 0; channel < channels; channel++) {
			size_t index = frame * channels + channel;
			if (sample->amp == 16) {
				int16_t *values = selection;
				int64_t scaled = (int64_t)values[index] * percent / 100;
				values[index] = (int16_t)MAX(MIN(scaled, INT16_MAX), INT16_MIN);
			} else {
				int8_t *values = selection;
				int32_t scaled = (int32_t)values[index] * percent / 100;
				values[index] = (int8_t)MAX(MIN(scaled, 127), -127);
			}
		}
	}
	return YES;
}

static BOOL PPBetterFadePercentBytes(sData *sample, size_t start, size_t end,
	double fromPercent, double toPercent)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) || !isfinite(fromPercent) || !isfinite(toPercent)) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	size_t frames = (end - start) / frameSize;
	if (frames == 0) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	double gain = fromPercent / 100.0;
	// The classic plug-in divides by the sample count, so the final stored
	// sample is one increment short of the requested destination percentage.
	double increment = (toPercent / 100.0 - gain) / (double)frames;
	for (size_t frame = 0; frame < frames; frame++) {
		for (size_t channel = 0; channel < channels; channel++) {
			size_t index = frame * channels + channel;
			if (sample->amp == 16) {
				long value = (long)trunc(((int16_t *)(sample->data + start))[index] * gain);
				((int16_t *)(sample->data + start))[index] =
					(int16_t)MAX(MIN(value, INT16_MAX), INT16_MIN);
			} else {
				long value = (long)trunc(((int8_t *)(sample->data + start))[index] * gain);
				((int8_t *)(sample->data + start))[index] =
					(int8_t)MAX(MIN(value, INT8_MAX), -INT8_MAX);
			}
		}
		gain += increment;
	}
	return YES;
}

static BOOL PPSaturateBytes(sData *sample, size_t start, size_t end, double gain)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size || gain < 0.0 || gain > 10.0) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t frames = (end - start) / frameSize;
	size_t channels = sample->stereo ? 2 : 1;
	void *data = sample->data + start;
	for (size_t frame = 0; frame < frames; frame++) {
		for (size_t channel = 0; channel < channels; channel++) {
			const double normalizedSignal = PPReadNormalizedPCM(data, sample->amp, channels, frame, channel);
			const double saturatedSignal = tanh(gain * normalizedSignal);
			PPWriteNormalizedPCM(data, sample->amp, channels, frame, channel, saturatedSignal);
		}
	}
	return YES;
}

static BOOL PPEQ3Bytes(sData *sample, size_t start, size_t end,
	double lowDecibels, double midDecibels, double highDecibels,
	double lowCrossover, double highCrossover)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		!isfinite(lowDecibels) || !isfinite(midDecibels) || !isfinite(highDecibels) ||
		!isfinite(lowCrossover) || !isfinite(highCrossover) ||
		lowDecibels < -12.0 || lowDecibels > 12.0 || midDecibels < -12.0 || midDecibels > 12.0 ||
		highDecibels < -12.0 || highDecibels > 12.0) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	// The complementary bands sum back to the input at neutral gain. Bypass the
	// arithmetic entirely at 0 dB so applying the default settings is bit exact.
	if (fabs(lowDecibels) < 0.000001 && fabs(midDecibels) < 0.000001 &&
		fabs(highDecibels) < 0.000001) return YES;

	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	void *data = sample->data + start;
	double sampleRate = MAX((double)sample->c2spd, 1.0);
	if (lowCrossover < 1.0 || highCrossover <= lowCrossover ||
		highCrossover >= sampleRate * 0.5) return NO;
	double lowCoefficient = 1.0 - exp(-2.0 * M_PI * lowCrossover / sampleRate);
	double highCoefficient = 1.0 - exp(-2.0 * M_PI * highCrossover / sampleRate);
	double lowGain = pow(10.0, lowDecibels / 20.0);
	double midGain = pow(10.0, midDecibels / 20.0);
	double highGain = pow(10.0, highDecibels / 20.0);
	double lowState[2] = {0.0, 0.0};
	double highLowpassState[2] = {0.0, 0.0};
	for (size_t channel = 0; channel < channels; channel++) {
		double initial = PPReadNormalizedPCM(data, sample->amp, channels, 0, channel);
		lowState[channel] = initial;
		highLowpassState[channel] = initial;
	}
	for (size_t frame = 0; frame < frames; frame++) {
		for (size_t channel = 0; channel < channels; channel++) {
			double input = PPReadNormalizedPCM(data, sample->amp, channels, frame, channel);
			lowState[channel] += lowCoefficient * (input - lowState[channel]);
			highLowpassState[channel] += highCoefficient * (input - highLowpassState[channel]);
			double low = lowState[channel];
			double mid = highLowpassState[channel] - low;
			double high = input - highLowpassState[channel];
			PPWriteNormalizedPCM(data, sample->amp, channels, frame, channel,
				low * lowGain + mid * midGain + high * highGain);
		}
	}
	return YES;
}

static int32_t PPClassicDCRead(const sData *sample, size_t channels, size_t frame, size_t channel)
{
	size_t index = frame * channels + channel;
	return sample->amp == 16 ? ((const int16_t *)sample->data)[index] : ((const int8_t *)sample->data)[index];
}

static void PPClassicDCWrite(sData *sample, size_t channels, size_t frame, size_t channel,
	int32_t fixedValue)
{
	size_t index = frame * channels + channel;
	int32_t scale = sample->amp == 16 ? 512 : 1024;
	int32_t maximum = (sample->amp == 16 ? 32767 : 127) * scale;
	fixedValue = MIN(MAX(fixedValue, -maximum), maximum);
	int32_t value = fixedValue / scale;
	if (sample->amp == 16) ((int16_t *)sample->data)[index] = (int16_t)value;
	else ((int8_t *)sample->data)[index] = (int8_t)value;
}

static void PPClassicDCStep(const sData *sample, size_t channels, size_t frame, size_t channel,
	double feedforward, double feedback, double *previousInput, double *previousOutput,
	BOOL writeResult)
{
	int32_t scale = sample->amp == 16 ? 512 : 1024;
	double input = (double)PPClassicDCRead(sample, channels, frame, channel) * scale;
	double output = feedforward * (input - *previousInput) + feedback * *previousOutput;
	int32_t truncated = (int32_t)trunc(output);
	*previousInput = input;
	*previousOutput = truncated;
	if (writeResult) PPClassicDCWrite((sData *)sample, channels, frame, channel, truncated);
}

static BOOL PPRemoveDCClassicBytes(sData *sample, size_t start, size_t end, BOOL circular)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16)) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t totalFrames = (size_t)sample->size / frameSize;
	size_t firstFrame = start / frameSize;
	size_t lastFrame = end / frameSize;

	// Recovered from the PowerPC plug-ins: a two-pass first-order high-pass
	// whose pole is derived from the sample rate through nested atan calls.
	double rate = MAX((double)sample->c2spd, 1.0);
	double theta = atan(4.0 * atan(atan(1.0)) * 11.0 / rate);
	double feedback = (1.0 - theta) / (1.0 + theta);
	double feedforward = 0.5 * (1.0 + feedback);

	for (size_t channel = 0; channel < channels; channel++) {
		double previousInput = 0.0, previousOutput = 0.0;
		if (circular && totalFrames > 160) {
			for (size_t warm = 80; warm > 0; warm--) {
				size_t frame = (firstFrame + totalFrames - warm) % totalFrames;
				PPClassicDCStep(sample, channels, frame, channel, feedforward, feedback,
					&previousInput, &previousOutput, NO);
			}
		}
		for (size_t frame = firstFrame; frame < lastFrame; frame++) {
			PPClassicDCStep(sample, channels, frame, channel, feedforward, feedback,
				&previousInput, &previousOutput, YES);
		}

		previousInput = 0.0;
		previousOutput = 0.0;
		if (circular && totalFrames > 160) {
			for (size_t warm = 80; warm > 0; warm--) {
				size_t frame = (lastFrame + warm) % totalFrames;
				PPClassicDCStep(sample, channels, frame, channel, feedforward, feedback,
					&previousInput, &previousOutput, NO);
			}
		}
		for (size_t frame = lastFrame; frame-- > firstFrame;) {
			PPClassicDCStep(sample, channels, frame, channel, feedforward, feedback,
				&previousInput, &previousOutput, YES);
		}
	}
	return YES;
}

static BOOL PPRemoveDCLinearBytes(sData *sample, size_t start, size_t end)
{
	return PPRemoveDCClassicBytes(sample, start, end, NO);
}

static BOOL PPRemoveDCCircularBytes(sData *sample, size_t start, size_t end)
{
	return PPRemoveDCClassicBytes(sample, start, end, YES);
}

static size_t PPConvolveTransformSize(size_t linearLength)
{
	size_t size = 2;
	while (size < linearLength) {
		if (size > (size_t)INT_MAX / 2) return 0;
		size <<= 1;
	}
	return size;
}

static BOOL PPConvolveBuildImpulse(const sData *sample, size_t startFrame, size_t endFrame,
	size_t channel, PPConvolveParameters parameters, double **impulseOut, size_t *lengthOut)
{
	if (sample == NULL || sample->data == NULL || impulseOut == NULL || lengthOut == NULL ||
		!isfinite(parameters.gain) || parameters.gain < 0.0 ||
		!isfinite(parameters.quality) || parameters.quality < 0.0 || parameters.quality > 1.0)
		return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t impulseLength = 0;
	double *impulse = NULL;
	if (parameters.impulseMode == PPConvolveImpulseSelection) {
		if (startFrame >= endFrame) return NO;
		impulseLength = endFrame - startFrame;
		impulse = calloc(impulseLength, sizeof(double));
		if (impulse == NULL) return NO;
		for (size_t frame = 0; frame < impulseLength; frame++) {
			impulse[frame] = PPReadNormalizedPCM(sample->data, sample->amp, channels,
				startFrame + frame, channel);
		}
	} else {
		double sampleRate = MAX((double)sample->c2spd, 1.0);
		double nyquist = sampleRate * 0.5;
		double cutoff = (double)parameters.cutoffHertz;
		if (cutoff < 1.0 || cutoff >= nyquist) return NO;
		double prototypeCutoff = parameters.impulseMode == PPConvolveImpulseHighPass
			? nyquist - cutoff : cutoff;
		double length = (60.0 * parameters.quality + 9.0) * sampleRate / prototypeCutoff;
		if (!isfinite(length) || length < 2.0) length = 2.0;
		// The original has no practical allocation guard. Keep its formula but
		// cap pathological one-Hertz/high-rate settings at roughly one million taps.
		impulseLength = MIN(MAX((size_t)floor(length), 2), (size_t)1048576);
		impulse = calloc(impulseLength, sizeof(double));
		if (impulse == NULL) return NO;
		double angularCutoff = 2.0 * M_PI * prototypeCutoff / sampleRate;
		double divisor = MAX((double)impulseLength - 1.0, 1.0);
		NSInteger center = (NSInteger)impulseLength / 2;
		for (size_t frame = 0; frame < impulseLength; frame++) {
			double offset = (double)((NSInteger)frame - center);
			double phase = angularCutoff * offset;
			double sinc = fabs(phase) < 0.0000000001 ? 1.0 : sin(phase) / phase;
			double position = (double)frame / divisor;
			double blackman = 0.42 - 0.5 * cos(2.0 * M_PI * position) +
				0.08 * cos(4.0 * M_PI * position);
			impulse[frame] = sinc * blackman;
			if (parameters.impulseMode == PPConvolveImpulseHighPass && (frame & 1) == 0)
				impulse[frame] = -impulse[frame];
		}
	}

	if (parameters.normalizeImpulse) {
		double divisor = 0.0;
		if (parameters.normalizeToSumOne) {
			for (size_t frame = 0; frame < impulseLength; frame++) divisor += impulse[frame];
		} else {
			for (size_t frame = 0; frame < impulseLength; frame++)
				divisor = MAX(divisor, fabs(impulse[frame]));
		}
		if (fabs(divisor) > 0.000000000001) {
			for (size_t frame = 0; frame < impulseLength; frame++) impulse[frame] /= divisor;
		}
	}
	*impulseOut = impulse;
	*lengthOut = impulseLength;
	return YES;
}

static BOOL PPConvolveBytes(sData *sample, size_t start, size_t end, PPConvolveParameters parameters)
{
	if (sample == NULL || sample->data == NULL || sample->size <= 0 ||
		(sample->amp != 8 && sample->amp != 16) || start >= end || end > (size_t)sample->size ||
		parameters.impulseMode < PPConvolveImpulseSelection ||
		parameters.impulseMode > PPConvolveImpulseLowPass) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t inputFrames = (size_t)sample->size / frameSize;
	size_t selectionStartFrame = start / frameSize;
	size_t selectionEndFrame = end / frameSize;
	if (inputFrames == 0) return NO;

	double *probeImpulse = NULL;
	size_t impulseLength = 0;
	if (!PPConvolveBuildImpulse(sample, selectionStartFrame, selectionEndFrame, 0,
		parameters, &probeImpulse, &impulseLength)) return NO;
	free(probeImpulse);
	if (impulseLength == 0 || inputFrames > SIZE_MAX - impulseLength + 1) return NO;
	size_t linearLength = inputFrames + impulseLength - 1;
	size_t outputFrames = parameters.wrapEdges ? inputFrames :
		(parameters.includeTail ? linearLength : inputFrames);
	if (outputFrames > (size_t)INT_MAX / frameSize) return NO;
	size_t transformSize = PPConvolveTransformSize(linearLength);
	if (transformSize == 0 || transformSize > (size_t)INT_MAX) return NO;
	size_t transformValues = transformSize + 2;
	double *signalFFT = calloc(transformValues, sizeof(double));
	double *impulseFFT = calloc(transformValues, sizeof(double));
	double *channelOutput = calloc(outputFrames, sizeof(double));
	void *replacement = calloc(outputFrames, frameSize);
	if (signalFFT == NULL || impulseFFT == NULL || channelOutput == NULL || replacement == NULL) {
		free(signalFFT); free(impulseFFT); free(channelOutput); free(replacement);
		return NO;
	}

	BOOL succeeded = YES;
	for (size_t channel = 0; channel < channels && succeeded; channel++) {
		double *impulse = NULL;
		size_t channelImpulseLength = 0;
		if (!PPConvolveBuildImpulse(sample, selectionStartFrame, selectionEndFrame, channel,
			parameters, &impulse, &channelImpulseLength) || channelImpulseLength != impulseLength) {
			free(impulse); succeeded = NO; break;
		}
		memset(signalFFT, 0, transformValues * sizeof(double));
		memset(impulseFFT, 0, transformValues * sizeof(double));
		memset(channelOutput, 0, outputFrames * sizeof(double));
		for (size_t frame = 0; frame < inputFrames; frame++)
			signalFFT[frame + 1] = PPReadNormalizedPCM(sample->data, sample->amp, channels, frame, channel);
		for (size_t frame = 0; frame < impulseLength; frame++) impulseFFT[frame + 1] = impulse[frame];
		free(impulse);
		MADrealft(signalFFT, (int)(transformSize / 2), true);
		MADrealft(impulseFFT, (int)(transformSize / 2), true);
		signalFFT[1] *= impulseFFT[1];
		signalFFT[2] *= impulseFFT[2];
		for (size_t bin = 1; bin < transformSize / 2; bin++) {
			double signalReal = signalFFT[bin * 2 + 1];
			double signalImaginary = signalFFT[bin * 2 + 2];
			double impulseReal = impulseFFT[bin * 2 + 1];
			double impulseImaginary = impulseFFT[bin * 2 + 2];
			signalFFT[bin * 2 + 1] = signalReal * impulseReal - signalImaginary * impulseImaginary;
			signalFFT[bin * 2 + 2] = signalReal * impulseImaginary + signalImaginary * impulseReal;
		}
		MADrealft(signalFFT, (int)(transformSize / 2), false);
		double scale = parameters.gain / (double)(transformSize / 2);
		for (size_t frame = 0; frame < linearLength; frame++) {
			size_t destination = parameters.wrapEdges ? frame % inputFrames : frame;
			if (destination < outputFrames) channelOutput[destination] += signalFFT[frame + 1] * scale;
		}
		for (size_t frame = 0; frame < outputFrames; frame++)
			PPWriteNormalizedPCM(replacement, sample->amp, channels, frame, channel, channelOutput[frame]);
	}
	free(signalFFT);
	free(impulseFFT);
	free(channelOutput);
	if (!succeeded) { free(replacement); return NO; }
	BOOL replaced = PPReplaceBytes(sample, replacement, outputFrames * frameSize);
	free(replacement);
	return replaced;
}

static double PPIIRReadScalar(const void *data, MADByte amplitude, size_t channels,
	size_t frame, size_t channel)
{
	size_t index = frame * channels + channel;
	return amplitude == 16 ? ((const int16_t *)data)[index] : ((const int8_t *)data)[index];
}

static void PPIIRWriteScalar(void *data, MADByte amplitude, size_t channels,
	size_t frame, size_t channel, double value)
{
	size_t index = frame * channels + channel;
	long integer = (long)trunc(value);
	if (amplitude == 16) {
		((int16_t *)data)[index] = (int16_t)MIN(MAX(integer, (long)INT16_MIN), (long)INT16_MAX);
	} else {
		// The original 8-bit routine deliberately clamps to symmetric ±127.
		((int8_t *)data)[index] = (int8_t)MIN(MAX(integer, -127L), 127L);
	}
}

static void PPIIRFilterCoefficients(PPIIRFilterParameters parameters, double sampleRate,
	double frequency, double *feedForward, double *feedback)
{
	// This unusual atan-based bilinear form is exact to the original plug-in.
	// Replacing it with a conventional exponential one-pole changes both its
	// cutoff response and high-pass polarity.
	double angularScale = 4.0 * atan(sampleRate);
	double warped = atan(angularScale * frequency / sampleRate);
	double recursive = (1.0 - warped) / (1.0 + warped);
	*feedback = recursive;
	*feedForward = parameters.mode == PPIIRFilterLowPass
		? 0.5 * (1.0 - recursive) : 0.5 * (1.0 + recursive);
}

static double PPIIRFilterStep(PPIIRFilterParameters parameters, double sampleRate,
	double frequency, double input, double *previousInput, double *previousOutput)
{
	double feedForward = 0.0, feedback = 0.0;
	PPIIRFilterCoefficients(parameters, sampleRate, frequency, &feedForward, &feedback);
	double output = parameters.mode == PPIIRFilterLowPass
		? feedForward * *previousInput + feedForward * input + feedback * *previousOutput
		: feedForward * *previousInput - feedForward * input + feedback * *previousOutput;
	*previousInput = input;
	*previousOutput = output;
	return output;
}

static BOOL PPIIRFilterBytes(sData *sample, size_t start, size_t end,
	PPIIRFilterParameters parameters)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) ||
		(parameters.mode != PPIIRFilterHighPass && parameters.mode != PPIIRFilterLowPass) ||
		parameters.startFrequency < 0 || parameters.startFrequency > 32767 ||
		parameters.endFrequency < 0 || parameters.endFrequency > 32767 ||
		parameters.repeatCount < 1 || parameters.repeatCount > 11) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	if (frames == 0) return NO;
	void *data = sample->data + start;
	double sampleRate = MAX((double)sample->c2spd, 1.0);
	NSInteger passes = parameters.repeatEnabled ? parameters.repeatCount : 1;
	for (NSInteger pass = 0; pass < passes; pass++) {
		for (size_t channel = 0; channel < channels; channel++) {
			double previousInput = 0.0, previousOutput = 0.0;
			if (parameters.wrapAround && end - start > 100) {
				// The classic wrap option warms the recursive state with the final
				// twenty values before returning to the first selected value.
				size_t warmFrames = MIN(frames, (size_t)20);
				for (size_t frame = frames - warmFrames; frame < frames; frame++) {
					double input = PPIIRReadScalar(data, sample->amp, channels, frame, channel);
					(void)PPIIRFilterStep(parameters, sampleRate,
						(double)parameters.startFrequency, input, &previousInput, &previousOutput);
				}
			}
			for (size_t frame = 0; frame < frames; frame++) {
				double frequency = (double)parameters.startFrequency;
				if (parameters.sweepFrequency) {
					double progress = (double)frame / (double)frames;
					frequency += ((double)parameters.endFrequency - parameters.startFrequency) * progress;
				}
				double input = PPIIRReadScalar(data, sample->amp, channels, frame, channel);
				double output = PPIIRFilterStep(parameters, sampleRate, frequency,
					input, &previousInput, &previousOutput);
				PPIIRWriteScalar(data, sample->amp, channels, frame, channel, output);
			}
		}
	}
	return YES;
}

static BOOL PPFrequencyCurveFilterBytes(sData *sample, size_t start, size_t end,
	const double *gains, size_t gainCount)
{
	if (sample == NULL || sample->data == NULL || gains == NULL || gainCount < 2 ||
		start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	BOOL unity = YES;
	for (size_t point = 0; point < gainCount; point++) {
		if (!isfinite(gains[point])) return NO;
		if (fabs(gains[point] - 1.0) > 0.0000001) unity = NO;
	}
	// Reset's unity line must be completely transparent, including at the
	// selection edges where an FFT window would otherwise introduce rounding.
	if (unity) return YES;

	static size_t const transformSize = 1024;
	static size_t const hopSize = 512;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	if (frames == 0 || frames > SIZE_MAX / channels / sizeof(double)) return NO;
	void *source = malloc(end - start);
	double *filtered = calloc(frames * channels, sizeof(double));
	double *normalization = calloc(frames, sizeof(double));
	double *fft = calloc(transformSize + 2, sizeof(double));
	if (source == NULL || filtered == NULL || normalization == NULL || fft == NULL) {
		free(source); free(filtered); free(normalization); free(fft);
		return NO;
	}
	memcpy(source, sample->data + start, end - start);

	for (size_t channel = 0; channel < channels; channel++) {
		for (NSInteger blockStart = -(NSInteger)hopSize; blockStart < (NSInteger)frames;
			blockStart += (NSInteger)hopSize) {
			memset(fft, 0, (transformSize + 2) * sizeof(double));
			for (size_t position = 0; position < transformSize; position++) {
				NSInteger frame = blockStart + (NSInteger)position;
				double window = sin(M_PI * ((double)position + 0.5) / (double)transformSize);
				if (frame >= 0 && frame < (NSInteger)frames) {
					fft[position + 1] = PPReadNormalizedPCM(source, sample->amp, channels,
						(size_t)frame, channel) * window;
					if (channel == 0) normalization[frame] += window * window;
				}
			}
			MADrealft(fft, (int)(transformSize / 2), true);
			fft[1] *= MIN(MAX(gains[0], 0.0), 2.0);
			fft[2] *= MIN(MAX(gains[gainCount - 1], 0.0), 2.0);
			for (size_t bin = 1; bin < transformSize / 2; bin++) {
				double gainPosition = (double)bin * (double)(gainCount - 1) /
					(double)(transformSize / 2);
				size_t left = MIN((size_t)floor(gainPosition), gainCount - 1);
				size_t right = MIN(left + 1, gainCount - 1);
				double fraction = gainPosition - (double)left;
				double gain = gains[left] + (gains[right] - gains[left]) * fraction;
				gain = MIN(MAX(gain, 0.0), 2.0);
				fft[bin * 2 + 1] *= gain;
				fft[bin * 2 + 2] *= gain;
			}
			MADrealft(fft, (int)(transformSize / 2), false);
			for (size_t position = 0; position < transformSize; position++) {
				NSInteger frame = blockStart + (NSInteger)position;
				if (frame < 0 || frame >= (NSInteger)frames) continue;
				double window = sin(M_PI * ((double)position + 0.5) / (double)transformSize);
				filtered[(size_t)frame * channels + channel] +=
					fft[position + 1] / (double)(transformSize / 2) * window;
			}
		}
	}
	for (size_t frame = 0; frame < frames; frame++) {
		double divisor = MAX(normalization[frame], 0.000000001);
		for (size_t channel = 0; channel < channels; channel++) {
			PPWriteNormalizedPCM(sample->data + start, sample->amp, channels, frame, channel,
				filtered[frame * channels + channel] / divisor);
		}
	}
	free(source);
	free(filtered);
	free(normalization);
	free(fft);
	return YES;
}

static double PPFrequencyMapDestination(const double *destinations, size_t destinationCount,
	double sourcePosition, BOOL logarithmic)
{
	double index = MIN(MAX(sourcePosition, 0.0), 1.0) * (destinationCount - 1);
	size_t first = MIN((size_t)floor(index), destinationCount - 1);
	size_t second = MIN(first + 1, destinationCount - 1);
	double fraction = index - (double)first;
	double graphDestination = destinations[first] +
		(destinations[second] - destinations[first]) * fraction;
	if (!isfinite(graphDestination) || graphDestination < 0.0 || graphDestination > 1.0) return -1.0;
	return logarithmic ? PPHzFilterDisplayPosition(graphDestination, YES) : graphDestination;
}

static BOOL PPFrequencyMapShiftBytes(sData *sample, size_t start, size_t end,
	const double *destinations, size_t destinationCount, BOOL logarithmic)
{
	if (sample == NULL || sample->data == NULL || destinations == NULL || destinationCount < 2 ||
		start >= end || end > (size_t)sample->size) return NO;
	for (size_t point = 0; point < destinationCount; point++) {
		if (!isfinite(destinations[point])) return NO;
	}
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	if (frames < 2) return NO;

	BOOL identity = YES;
	for (size_t point = 0; point < destinationCount; point++) {
		double sourcePosition = (double)point / (double)(destinationCount - 1);
		double destination = PPFrequencyMapDestination(destinations, destinationCount,
			sourcePosition, logarithmic);
		if (destination < 0.0 || fabs(destination - sourcePosition) > 0.0000001) {
			identity = NO;
			break;
		}
	}
	// Reset is the red reference curve and must be perfectly transparent.
	if (identity) return YES;

	size_t transformSize = 2;
	while (transformSize < frames) {
		if (transformSize > SIZE_MAX / 2) return NO;
		transformSize *= 2;
	}
	if (transformSize > (size_t)INT_MAX ||
		transformSize > (SIZE_MAX / sizeof(double)) - 2) return NO;
	size_t binCount = transformSize / 2 + 1;
	void *source = malloc(end - start);
	double *fft = calloc(transformSize + 2, sizeof(double));
	double *shiftedReal = calloc(binCount, sizeof(double));
	double *shiftedImaginary = calloc(binCount, sizeof(double));
	if (source == NULL || fft == NULL || shiftedReal == NULL || shiftedImaginary == NULL) {
		free(source); free(fft); free(shiftedReal); free(shiftedImaginary);
		return NO;
	}
	memcpy(source, sample->data + start, end - start);

	for (size_t channel = 0; channel < channels; channel++) {
		memset(fft, 0, (transformSize + 2) * sizeof(double));
		memset(shiftedReal, 0, binCount * sizeof(double));
		memset(shiftedImaginary, 0, binCount * sizeof(double));
		for (size_t frame = 0; frame < frames; frame++) {
			fft[frame + 1] = PPReadNormalizedPCM(source, sample->amp, channels, frame, channel);
		}
		MADrealft(fft, (int)(transformSize / 2), true);
		for (size_t sourceBin = 0; sourceBin < binCount; sourceBin++) {
			double sourcePosition = (double)sourceBin / (double)(binCount - 1);
			double destination = PPFrequencyMapDestination(destinations, destinationCount,
				sourcePosition, logarithmic);
			if (destination < 0.0 || destination > 1.0) continue;
			double target = destination * (double)(binCount - 1);
			size_t firstTarget = MIN((size_t)floor(target), binCount - 1);
			size_t secondTarget = MIN(firstTarget + 1, binCount - 1);
			double secondWeight = target - (double)firstTarget;
			double firstWeight = 1.0 - secondWeight;
			double real = 0.0, imaginary = 0.0;
			if (sourceBin == 0) real = fft[1];
			else if (sourceBin == binCount - 1) real = fft[2];
			else {
				real = fft[sourceBin * 2 + 1];
				imaginary = fft[sourceBin * 2 + 2];
			}
			shiftedReal[firstTarget] += real * firstWeight;
			shiftedImaginary[firstTarget] += imaginary * firstWeight;
			if (secondTarget != firstTarget) {
				shiftedReal[secondTarget] += real * secondWeight;
				shiftedImaginary[secondTarget] += imaginary * secondWeight;
			}
		}
		memset(fft, 0, (transformSize + 2) * sizeof(double));
		fft[1] = shiftedReal[0];
		fft[2] = shiftedReal[binCount - 1];
		for (size_t bin = 1; bin + 1 < binCount; bin++) {
			fft[bin * 2 + 1] = shiftedReal[bin];
			fft[bin * 2 + 2] = shiftedImaginary[bin];
		}
		MADrealft(fft, (int)(transformSize / 2), false);
		for (size_t frame = 0; frame < frames; frame++) {
			PPWriteNormalizedPCM(sample->data + start, sample->amp, channels, frame, channel,
				fft[frame + 1] / (double)(transformSize / 2));
		}
	}
	free(source);
	free(fft);
	free(shiftedReal);
	free(shiftedImaginary);
	return YES;
}

static int16_t PPClassicRandom(uint32_t *seed);
static uint32_t *PPSharedClassicRandomSeed(void);

static void PPNoiseWriteScalar(void *data, MADByte amplitude, size_t index, double value)
{
	long integer = (long)trunc(value);
	if (amplitude == 16) {
		((int16_t *)data)[index] = (int16_t)MIN(MAX(integer, (long)INT16_MIN), (long)INT16_MAX);
	} else {
		// The 2002 plug-in uses the symmetric 8-bit range, deliberately excluding -128.
		((int8_t *)data)[index] = (int8_t)MIN(MAX(integer, -127L), 127L);
	}
}

static BOOL PPNoiseBytesWithSeed(sData *sample, size_t start, size_t end,
	PPNoiseParameters parameters, uint32_t *randomSeed)
{
	if (sample == NULL || sample->data == NULL || randomSeed == NULL ||
		start >= end || end > (size_t)sample->size || (sample->amp != 8 && sample->amp != 16) ||
		parameters.mode < PPNoiseModeWhite || parameters.mode > PPNoiseModeFrequency ||
		parameters.ringComponentCount < 2 || parameters.ringComponentCount > 256 ||
		parameters.ringMinimumHertz < 0 || parameters.ringMaximumHertz < parameters.ringMinimumHertz ||
		parameters.frequencyBPM < 1 || parameters.frequencyMinimumHertz < 0 ||
		parameters.frequencyMaximumHertz < parameters.frequencyMinimumHertz) return NO;

	size_t sampleBytes = sample->amp == 16 ? sizeof(int16_t) : sizeof(int8_t);
	start -= start % sampleBytes;
	end -= end % sampleBytes;
	if (start >= end) return NO;
	size_t scalarCount = (end - start) / sampleBytes;
	void *destination = sample->data + start;
	double sampleRate = MAX((double)sample->c2spd, 1.0);
	double maximumAmplitude = sample->amp == 16 ? 32767.0 : 127.0;

	if (parameters.mode == PPNoiseModeWhite || parameters.mode == PPNoiseModeGaussian) {
		for (size_t index = 0; index < scalarCount; index++) {
			double value = 0.0;
			NSInteger randomCount = parameters.mode == PPNoiseModeGaussian ? 20 : 1;
			for (NSInteger draw = 0; draw < randomCount; draw++)
				value += (double)PPClassicRandom(randomSeed);
			value /= (double)randomCount;
			PPNoiseWriteScalar(destination, sample->amp, index,
				value * maximumAmplitude / 32767.0);
		}
		return YES;
	}

	if (parameters.mode == PPNoiseModeRing) {
		double *angularSteps = calloc((size_t)parameters.ringComponentCount, sizeof(double));
		if (angularSteps == NULL) return NO;
		double fullCircle = 8.0 * atan(1.0);
		for (NSInteger component = 0; component < parameters.ringComponentCount; component++) {
			// QuickDraw Random is signed. The original therefore extrapolates below
			// the lower field as well as interpolating toward the upper field.
			double randomUnit = (double)PPClassicRandom(randomSeed) / 32767.0;
			double frequency = parameters.ringMinimumHertz +
				(parameters.ringMaximumHertz - parameters.ringMinimumHertz) * randomUnit;
			angularSteps[component] = frequency * fullCircle / sampleRate;
		}
		double componentScale = (double)parameters.ringComponentCount / 8.0;
		double normalization = componentScale * componentScale;
		normalization = componentScale * normalization;
		normalization = componentScale * normalization;
		normalization = componentScale * normalization;
		for (size_t index = 0; index < scalarCount; index++) {
			double value = normalization;
			for (NSInteger component = 0; component < parameters.ringComponentCount; component++)
				value *= sin((double)index * angularSteps[component]);
			PPNoiseWriteScalar(destination, sample->amp, index, value * maximumAmplitude);
		}
		free(angularSteps);
		return YES;
	}

	// Freq Noise is a full-scale oscillator. At each sixteenth-note boundary
	// it selects a new signed-random frequency within the two stored endpoints.
	NSInteger intervalFrames = (NSInteger)trunc(sampleRate * 15.0 /
		(double)parameters.frequencyBPM);
	NSInteger nextChange = 0;
	double angularStep = 0.0;
	for (size_t index = 0; index < scalarCount; index++) {
		if ((NSInteger)index >= nextChange) {
			double randomUnit = (double)PPClassicRandom(randomSeed) / 32767.0;
			double frequency = parameters.frequencyMinimumHertz +
				(parameters.frequencyMaximumHertz - parameters.frequencyMinimumHertz) * randomUnit;
			angularStep = frequency * (8.0 * atan(1.0)) / sampleRate;
			nextChange += intervalFrames;
		}
		PPNoiseWriteScalar(destination, sample->amp, index,
			sin((double)index * angularStep) * maximumAmplitude);
	}
	return YES;
}

static BOOL PPNoiseBytes(sData *sample, size_t start, size_t end, PPNoiseParameters parameters)
{
	// The original shares QuickDraw's process-wide random stream with other Pandaa filters.
	return PPNoiseBytesWithSeed(sample, start, end, parameters, PPSharedClassicRandomSeed());
}

static double PPRingWaveValue(PPRingWaveShape shape, double phase)
{
	double turn = phase / (2.0 * M_PI);
	turn -= floor(turn);
	switch (shape) {
		case PPRingWaveTriangle: return 1.0 - 4.0 * fabs(turn - 0.5);
		case PPRingWaveSaw: return 1.0 - 2.0 * turn;
		case PPRingWaveSquare: return turn < 0.5 ? 1.0 : -1.0;
		default: return sin(phase);
	}
}

static BOOL PPRingModulateBytes(sData *sample, size_t start, size_t end,
	PPRingModulateParameters parameters)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) ||
		parameters.mode < PPRingModulateModeRing || parameters.mode > PPRingModulateModeAmplitude ||
		parameters.frequencyHertz < 1 || parameters.frequencyHertz > 32767 ||
		parameters.mixPercent < 0 || parameters.mixPercent > 100 ||
		parameters.modulationDepthHertz < 0 || parameters.modulationDepthHertz > 32767 ||
		parameters.frequencySource < PPRingFrequencyRampUp ||
		parameters.frequencySource > PPRingFrequencyEnvelope ||
		parameters.modulationRateHundredthHertz < 1 ||
		parameters.firstWave < PPRingWaveSine || parameters.firstWave > PPRingWaveSquare ||
		parameters.secondWave < PPRingWaveSine || parameters.secondWave > PPRingWaveSquare ||
		!isfinite(parameters.envelopeSense) || parameters.envelopeSense < 0.0 ||
		parameters.envelopeSense > 0.999) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	void *data = sample->data + start;
	double sampleRate = MAX((double)sample->c2spd, 1.0);
	double phase = 0.0;
	double wetMix = (double)parameters.mixPercent / 100.0;
	double dryMix = 1.0 - wetMix;
	double envelope = 0.5;
	double previousDeRing[2] = {0.0, 0.0};
	for (size_t frame = 0; frame < frames; frame++) {
		double progress = frames <= 1 ? 0.0 : (double)frame / (double)(frames - 1);
		double modulationInput = 0.0;
		for (size_t channel = 0; channel < channels; channel++)
			modulationInput += PPReadNormalizedPCM(data, sample->amp, channels, frame, channel);
		modulationInput /= (double)channels;
		double frequency = (double)parameters.frequencyHertz;
		if (parameters.modulateFrequency) {
			double depth = (double)parameters.modulationDepthHertz;
			switch (parameters.frequencySource) {
				case PPRingFrequencyRampUp:
					frequency += depth * (progress - 0.5);
					break;
				case PPRingFrequencyRampDown:
					frequency += depth * (0.5 - progress);
					break;
				case PPRingFrequencySine: {
					double rate = (double)parameters.modulationRateHundredthHertz / 100.0;
					frequency += depth * sin(2.0 * M_PI * rate * (double)frame / sampleRate);
					break;
				}
				case PPRingFrequencySample:
					frequency += depth * modulationInput;
					break;
				case PPRingFrequencyEnvelope:
					envelope = parameters.envelopeSense * envelope +
						(1.001 - parameters.envelopeSense) * fabs(modulationInput);
					frequency += depth * (envelope - 0.5);
					break;
			}
		}
		// RingModulation advances the oscillator before processing the first sample.
		phase += 2.0 * M_PI * frequency / sampleRate;
		double first = PPRingWaveValue(parameters.firstWave, phase);
		double carrier = first;
		if (parameters.morphWave) {
			double second = PPRingWaveValue(parameters.secondWave, phase);
			carrier = first + (second - first) * progress;
		}
		for (size_t channel = 0; channel < channels; channel++) {
			double input = PPReadNormalizedPCM(data, sample->amp, channels, frame, channel);
			double effected = input;
			switch (parameters.mode) {
				case PPRingModulateModeRing:
					effected = input * carrier;
					break;
				case PPRingModulateModeDeRing:
					if (fabs(carrier) > 1.0e-9) {
						effected = input / carrier;
						previousDeRing[channel] = effected;
					} else {
						effected = previousDeRing[channel];
					}
					break;
				case PPRingModulateModeAmplitude:
					effected = input * (carrier * 0.5 + 0.5);
					break;
			}
			PPWriteNormalizedPCM(data, sample->amp, channels, frame, channel,
				effected * wetMix + input * dryMix);
		}
	}
	return YES;
}

static double PPStardustRandomUnit(double *state)
{
	// The PowerPC plug-in has its own fractional generator rather than calling
	// Random for every grain. These two constants come directly from its code.
	double value = 2.875498732135781 * *state + 0.2696873514313574;
	value -= trunc(value);
	if (value < 0.0) value += 1.0;
	*state = value;
	return value;
}

static NSInteger PPStardustWrappedFrame(NSInteger frame, size_t frameCount)
{
	NSInteger divisor = (NSInteger)frameCount;
	frame %= divisor;
	return frame < 0 ? frame + divisor : frame;
}

static BOOL PPStardustBytesWithRandomState(sData *sample, size_t start, size_t end,
	PPStardustParameters parameters, double *randomState)
{
	if (sample == NULL || sample->data == NULL || randomState == NULL ||
		start >= end || end > (size_t)sample->size ||
		!isfinite(parameters.grainLengthPosition) || !isfinite(parameters.grainCountPosition) ||
		parameters.grainLengthPosition < 0.0 || parameters.grainLengthPosition > 1.0 ||
		parameters.grainCountPosition < 0.0 || parameters.grainCountPosition > 1.0)
		return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frameCount = (end - start) / frameSize;
	if (frameCount == 0 || frameCount > (size_t)NSIntegerMax) return NO;
	size_t grainLength = MIN(PPStardustGrainLength(parameters), frameCount);
	size_t grainCount = PPStardustGrainCount(parameters);
	void *audio = sample->data + start;

	// This is the original Stardust operation: each pass chooses independent
	// source and destination centres, wraps both grains around the selection,
	// then replaces the destination through a 0 -> 1 -> 0 power envelope.
	// It intentionally works in place, so later grains can pick up earlier dust.
	for (size_t grain = 0; grain < grainCount; grain++) {
		NSInteger sourceCenter = (NSInteger)((double)(frameCount - 1) *
			PPStardustRandomUnit(randomState));
		NSInteger destinationCenter = (NSInteger)((double)(frameCount - 1) *
			PPStardustRandomUnit(randomState));
		NSInteger sourceFrame = sourceCenter - (NSInteger)(grainLength / 2);
		NSInteger destinationFrame = destinationCenter - (NSInteger)(grainLength / 2);
		for (size_t offset = 0; offset < grainLength; offset++) {
			double position = (double)offset / (double)grainLength;
			double envelope = position < 0.5
				? 1.0 - pow(1.0 - 2.0 * position, 0.7)
				: 1.0 - pow(2.0 * (position - 0.5), 0.7);
			size_t sourceIndex = (size_t)PPStardustWrappedFrame(sourceFrame, frameCount);
			size_t destinationIndex = (size_t)PPStardustWrappedFrame(destinationFrame, frameCount);
			for (size_t channel = 0; channel < channels; channel++) {
				double sourceValue = PPReadNormalizedPCM(audio, sample->amp, channels,
					sourceIndex, channel);
				double destinationValue = PPReadNormalizedPCM(audio, sample->amp, channels,
					destinationIndex, channel);
				PPWriteNormalizedPCM(audio, sample->amp, channels, destinationIndex, channel,
					sourceValue * envelope + destinationValue * (1.0 - envelope));
			}
			sourceFrame++;
			destinationFrame++;
		}
	}
	return YES;
}

static BOOL PPStardustBytes(sData *sample, size_t start, size_t end,
	PPStardustParameters parameters)
{
	// The classic plug-in seeded its fractional generator once per invocation
	// from QuickDraw Random. Keep that per-application variation without making
	// the grain locations depend on C library rand implementations.
	static uint32_t seed = 0;
	if (seed == 0) {
		uint64_t macSeconds = (uint64_t)time(NULL) + UINT64_C(2082844800);
		seed = (uint32_t)(macSeconds ^ (macSeconds >> 32));
		if (seed == 0) seed = UINT32_C(0x53544152);
	}
	seed = seed * UINT32_C(1664525) + UINT32_C(1013904223);
	double randomState = (double)(seed & UINT32_C(0x7fffffff)) / 2009.0;
	return PPStardustBytesWithRandomState(sample, start, end, parameters, &randomState);
}

static double PPAddotrophBaseFrequency(PPAddotrophParameters parameters)
{
	if (!parameters.useOctaveAndTone) return parameters.frequencyHertz;
	// This is the exact note conversion in Addotroph's PowerPC plug-in:
	// 8.175798916 * 2 ^ ((octave * 12 + tone) / 12).
	return 8.175798916 * pow(2.0,
		((double)parameters.octave * 12.0 + (double)parameters.tone) / 12.0);
}

static BOOL PPAddotrophParametersAreValid(PPAddotrophParameters parameters, double sampleRate)
{
	double frequency = PPAddotrophBaseFrequency(parameters);
	if (!isfinite(frequency) || frequency < 0.1 ||
		parameters.octave < 0 || parameters.octave > 9 || parameters.tone < 0 || parameters.tone > 11 ||
		!isfinite(parameters.toneAmplitudePermille) || parameters.toneAmplitudePermille < 0.0 ||
		parameters.toneAmplitudePermille > 10000.0 || parameters.formantCount < 1 || parameters.formantCount > 256 ||
		!isfinite(parameters.lastFormantAmplitudePermille) || parameters.lastFormantAmplitudePermille < 0.0 ||
		parameters.lastFormantAmplitudePermille > 10000.0 || !isfinite(parameters.frequencyScalePermille) ||
		parameters.frequencyScalePermille < 0.0 || parameters.frequencyScalePermille > 10000.0 ||
		!isfinite(parameters.frequencyAdditionHertz) || fabs(parameters.frequencyAdditionHertz) > sampleRate ||
		!isfinite(parameters.amplitudeScalePermille) || parameters.amplitudeScalePermille < 0.0 ||
		parameters.amplitudeScalePermille > 10000.0 || !isfinite(parameters.globalAmplitudePermille) ||
		parameters.globalAmplitudePermille < 0.0 || parameters.globalAmplitudePermille > 10000.0) return NO;
	for (NSInteger chorus = 0; chorus < 4; chorus++) {
		if (!isfinite(parameters.chorusFrequencyPermille[chorus]) ||
			parameters.chorusFrequencyPermille[chorus] < 0.0 || parameters.chorusFrequencyPermille[chorus] > 10000.0 ||
			!isfinite(parameters.chorusAmplitudePermille[chorus]) ||
			parameters.chorusAmplitudePermille[chorus] < 0.0 || parameters.chorusAmplitudePermille[chorus] > 10000.0) return NO;
	}
	return YES;
}

static BOOL PPAddotrophBytes(sData *sample, size_t start, size_t end, PPAddotrophParameters parameters)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	double sampleRate = MAX((double)sample->c2spd, 1.0);
	if (!PPAddotrophParametersAreValid(parameters, sampleRate)) return NO;

	// The classic code treats the tone as entry zero and appends the requested
	// number of formants. It then replaces the selection with the resulting
	// additive waveform; the old sample is not mixed back into the result.
	size_t componentCount = (size_t)parameters.formantCount + 1;
	double *steps = calloc(componentCount, sizeof(*steps));
	double *amplitudes = calloc(componentCount, sizeof(*amplitudes));
	if (steps == NULL || amplitudes == NULL) {
		free(steps); free(amplitudes); return NO;
	}
	double frequency = PPAddotrophBaseFrequency(parameters);
	steps[0] = frequency * (8.0 * atan(1.0)) / sampleRate;
	amplitudes[0] = parameters.toneAmplitudePermille / 1000.0;
	double formantAmplitude = parameters.lastFormantAmplitudePermille / 1000.0;
	for (NSInteger formant = 0; formant < parameters.formantCount; formant++) {
		frequency = frequency * parameters.frequencyScalePermille / 1000.0 +
			parameters.frequencyAdditionHertz;
		steps[(size_t)formant + 1] = frequency * (8.0 * atan(1.0)) / sampleRate;
		amplitudes[(size_t)formant + 1] = formantAmplitude;
		formantAmplitude *= parameters.amplitudeScalePermille / 1000.0;
	}
	double normalizer = 0.0;
	for (size_t component = 0; component < componentCount; component++)
		normalizer += amplitudes[component];
	for (NSInteger chorus = 0; chorus < 4; chorus++) {
		if (parameters.chorusEnabled[chorus])
			normalizer += (double)componentCount *
				parameters.chorusAmplitudePermille[chorus] / 1000.0;
	}
	if (fabs(normalizer) < 0.000000000001) {
		free(steps); free(amplitudes); return YES;
	}
	double outputScale = parameters.globalAmplitudePermille / 1000.0 / normalizer;
	size_t scalarCount = (end - start) / (sample->amp == 16 ? 2 : 1);
	for (size_t scalar = 0; scalar < scalarCount; scalar++) {
		double generated = 0.0;
		for (size_t component = 0; component < componentCount; component++) {
			double phase = (double)scalar * steps[component];
			generated += sin(phase) * amplitudes[component];
			for (NSInteger chorus = 0; chorus < 4; chorus++) {
				if (!parameters.chorusEnabled[chorus]) continue;
				double detune = parameters.chorusFrequencyPermille[chorus] / 1000.0;
				double chorusAmplitude = amplitudes[component] *
					parameters.chorusAmplitudePermille[chorus] / 1000.0;
				generated += sin(phase * (1.0 - detune)) * chorusAmplitude;
				generated += sin(phase * (1.0 + detune)) * chorusAmplitude;
			}
		}
		generated *= outputScale;
		if (sample->amp == 16) {
			long value = (long)trunc(generated * 32767.0);
			((int16_t *)(sample->data + start))[scalar] =
				(int16_t)MAX(MIN(value, INT16_MAX), INT16_MIN);
		} else {
			long value = (long)trunc(generated * 127.0);
			((int8_t *)(sample->data + start))[scalar] =
				(int8_t)MAX(MIN(value, INT8_MAX), -INT8_MAX);
		}
	}
	free(steps);
	free(amplitudes);
	return YES;
}

static BOOL PPAderodhiecusParametersAreValid(PPAderodhiecusParameters parameters)
{
	return parameters.frequencyHertz >= 1 && parameters.frequencyHertz <= INT16_MAX &&
		isfinite(parameters.horizontalPercent) && parameters.horizontalPercent >= 0.0 &&
		parameters.horizontalPercent <= 100.0 &&
		isfinite(parameters.verticalPercent) && parameters.verticalPercent >= 0.0 &&
		parameters.verticalPercent <= 100.0;
}

static BOOL PPAderodhiecusBytes(sData *sample, size_t start, size_t end,
	PPAderodhiecusParameters parameters)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) || !PPAderodhiecusParametersAreValid(parameters)) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	double phaseIncrement = 8.0 * atan(1.0) * (double)parameters.frequencyHertz / 44100.0;
	double modulationDepth = parameters.horizontalPercent / 25.0;
	double curveScale = parameters.verticalPercent / 50.0 + 0.16;
	for (size_t frame = 0; frame < frames; frame++) {
		double phase = phaseIncrement * (double)frame;
		double modulatedPhase = phase + modulationDepth * sin(0.5 * phase);
		double exponent = (0.5 * sin(modulatedPhase) + 1.5) * curveScale;
		for (size_t channel = 0; channel < channels; channel++) {
			size_t index = frame * channels + channel;
			if (sample->amp == 16) {
				int value = ((int16_t *)(sample->data + start))[index];
				int sign = value < 0 ? -1 : 1;
				double magnitude = value < 0 ? -(double)value : (double)value;
				long shaped = (long)trunc(32767.0 * pow(magnitude / 32767.0, exponent));
				shaped *= sign;
				((int16_t *)(sample->data + start))[index] =
					(int16_t)MAX(MIN(shaped, INT16_MAX), INT16_MIN);
			} else {
				int value = ((int8_t *)(sample->data + start))[index];
				int sign = value < 0 ? -1 : 1;
				double magnitude = value < 0 ? -(double)value : (double)value;
				long shaped = (long)trunc(127.0 * pow(magnitude / 127.0, exponent));
				shaped *= sign;
				((int8_t *)(sample->data + start))[index] =
					(int8_t)MAX(MIN(shaped, INT8_MAX), -INT8_MAX);
			}
		}
	}
	return YES;
}

static BOOL PPEnvelopeTestBytes(sData *sample, size_t start, size_t end,
	double attackCurve, double plateauWidth, double releaseCurve)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) ||
		!isfinite(attackCurve) || !isfinite(plateauWidth) || !isfinite(releaseCurve) ||
		attackCurve < 0.0 || releaseCurve < 0.0 || plateauWidth < 0.0 || plateauWidth > 1.0) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	size_t scalarCount = frames * channels;
	double attackEnd = 0.5 - 0.5 * plateauWidth;
	double releaseStart = 0.5 + 0.5 * plateauWidth;
	void *data = sample->data + start;
	for (size_t frame = 0; frame < frames; frame++) {
		// EnvTest's interactive picture controlled these three values. The
		// transfer function is two power curves around a flat centre section.
		// Its stereo loop advances the envelope once per frame while dividing by
		// the scalar sample count; retain that original half-speed stereo quirk.
		double position = (double)frame / (double)scalarCount;
		double gain;
		if (position < attackEnd && attackEnd > 0.0) {
			double normalized = position / attackEnd;
			gain = 1.0 - pow(1.0 - normalized, attackCurve);
		} else if (position > releaseStart && attackEnd > 0.0) {
			double normalized = (position - releaseStart) / attackEnd;
			gain = 1.0 - pow(normalized, releaseCurve);
		} else {
			gain = 1.0;
		}
		gain = MIN(MAX(gain, 0.0), 1.0);
		for (size_t channel = 0; channel < channels; channel++) {
			size_t index = frame * channels + channel;
			if (sample->amp == 16) {
				long value = (long)trunc((double)((int16_t *)data)[index] * gain);
				((int16_t *)data)[index] = (int16_t)MIN(MAX(value, -32768L), 32767L);
			} else {
				long value = (long)trunc((double)((int8_t *)data)[index] * gain);
				((int8_t *)data)[index] = (int8_t)MIN(MAX(value, -127L), 127L);
			}
		}
	}
	return YES;
}

static BOOL PPFingawalixBytesWithSeed(sData *sample, size_t start, size_t end, uint32_t *randomSeed)
{
	if (sample == NULL || sample->data == NULL || start >= end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) || randomSeed == NULL) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	start -= start % frameSize;
	end -= end % frameSize;
	if (start >= end) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	size_t frames = (end - start) / frameSize;
	NSInteger componentCount = 0;
	do {
		double randomUnit = (double)PPClassicRandom(randomSeed) / 32767.0;
		componentCount = labs((long)trunc(80.0 * randomUnit));
	} while (componentCount < 2);
	double *angularSteps = calloc((size_t)componentCount, sizeof(double));
	if (angularSteps == NULL) return NO;
	for (NSInteger component = 0; component < componentCount; component++) {
		double randomUnit = (double)PPClassicRandom(randomSeed) / 32767.0;
		double frequency = 60.0 + 7040.0 * randomUnit;
		angularSteps[component] = 2.0 * 3.141592654 * frequency / 44100.0;
	}
	void *data = sample->data + start;
	for (size_t frame = 0; frame < frames; frame++) {
		double generated;
		if (sample->amp == 8) {
			generated = 0.0;
			for (NSInteger component = 0; component < componentCount; component++)
				generated += sin((double)frame * angularSteps[component]);
			generated = generated / (double)componentCount * 127.0;
		} else {
			generated = 1.0;
			for (NSInteger component = 0; component < componentCount; component++)
				generated *= sin((double)frame * angularSteps[component]);
			generated *= 32767.0;
		}
		long value = (long)trunc(generated);
		for (size_t channel = 0; channel < channels; channel++) {
			size_t index = frame * channels + channel;
			if (sample->amp == 16)
				((int16_t *)data)[index] = (int16_t)MIN(MAX(value, -32768L), 32767L);
			else
				((int8_t *)data)[index] = (int8_t)MIN(MAX(value, -127L), 127L);
		}
	}
	free(angularSteps);
	return YES;
}

static BOOL PPFingawalixBytes(sData *sample, size_t start, size_t end)
{
	return PPFingawalixBytesWithSeed(sample, start, end, PPSharedClassicRandomSeed());
}

// QuickDraw's Random routine advances randSeed with the Park-Miller generator
// and returns its low signed word. Memphif calls that routine directly.
static int16_t PPClassicRandom(uint32_t *seed)
{
	if (seed == NULL) return 0;
	uint64_t next = ((uint64_t)*seed * UINT64_C(16807)) % UINT64_C(2147483647);
	if (next == 0) next = 1;
	*seed = (uint32_t)next;
	return (int16_t)(*seed & UINT32_C(0xffff));
}

static uint32_t *PPSharedClassicRandomSeed(void)
{
	static uint32_t randomSeed = 0;
	if (randomSeed == 0) {
		uint64_t macSeconds = (uint64_t)time(NULL) + UINT64_C(2082844800);
		randomSeed = (uint32_t)(macSeconds % UINT64_C(2147483647));
		if (randomSeed == 0) randomSeed = 1;
	}
	return &randomSeed;
}

static BOOL PPMemphifBytesWithSeed(sData *sample, size_t start, size_t end, uint32_t *randomSeed)
{
	if (sample == NULL || sample->data == NULL || randomSeed == NULL ||
		start >= end || end > (size_t)sample->size || (sample->amp != 8 && sample->amp != 16)) return NO;

	// The original operates on scalar PCM values rather than frames. In a
	// stereo sample this advances the oscillator once for the left value and
	// once again for the right value, matching the plug-in's default channel mode.
	size_t sampleBytes = sample->amp == 16 ? sizeof(int16_t) : sizeof(int8_t);
	start -= start % sampleBytes;
	end -= end % sampleBytes;
	if (start >= end) return NO;

	NSInteger componentCount = 0;
	do {
		double randomUnit = (double)PPClassicRandom(randomSeed) / 32767.0;
		componentCount = labs((long)trunc(10.0 * randomUnit));
	} while (componentCount < 2);

	// Disassembly of the 2002 PowerPC plug-in gives these exact constants:
	// random component frequencies are 10 + 440 * Random()/32767 Hz, and
	// angular steps use a fixed 44.1 kHz timebase rather than the sample rate.
	double angularSteps[10] = {0};
	for (NSInteger component = 0; component < componentCount; component++) {
		double randomUnit = (double)PPClassicRandom(randomSeed) / 32767.0;
		double frequency = 10.0 + 440.0 * randomUnit;
		angularSteps[component] = 3.141592654 * 2.0 * frequency / 44100.0;
	}

	size_t scalarCount = (end - start) / sampleBytes;
	if (sample->amp == 8) {
		int8_t *destination = (int8_t *)(sample->data + start);
		for (size_t index = 0; index < scalarCount; index++) {
			double generated = 1.0;
			for (NSInteger component = 0; component < componentCount; component++)
				generated *= sin((double)index * angularSteps[component]);
			long value = (long)trunc(generated * 127.0);
			destination[index] = (int8_t)MIN(MAX(value, -127L), 127L);
		}
	} else {
		int16_t *destination = (int16_t *)(sample->data + start);
		for (size_t index = 0; index < scalarCount; index++) {
			double generated = 1.0;
			for (NSInteger component = 0; component < componentCount; component++)
				generated *= sin((double)index * angularSteps[component]);
			long value = (long)trunc(generated * 32767.0);
			destination[index] = (int16_t)MIN(MAX(value, -32768L), 32767L);
		}
	}
	return YES;
}

static BOOL PPMemphifBytes(sData *sample, size_t start, size_t end)
{
	return PPMemphifBytesWithSeed(sample, start, end, PPSharedClassicRandomSeed());
}

static BOOL PPQuantizeDepthBytes(sData *sample, size_t start, size_t end, NSInteger bits)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	NSInteger nativeBits = sample->amp == 16 ? 16 : 8;
	if (bits < 1 || bits > nativeBits) return NO;
	int32_t levels = 1 << bits;
	if (sample->amp == 16) {
		int16_t *values = (int16_t *)(sample->data + start);
		size_t count = (end - start) / sizeof(int16_t);
		for (size_t index = 0; index < count; index++) {
			// The original works in 65,535 signed quantization units rather
			// than masking low bits directly.
			int32_t bucket = (int64_t)values[index] * levels / 65535;
			values[index] = (int16_t)((int64_t)bucket * 65535 / levels);
		}
	} else {
		int8_t *values = (int8_t *)(sample->data + start);
		for (size_t index = 0; index < end - start; index++) {
			// Classic Depth deliberately quantizes the stored unsigned byte,
			// which makes negative PCM values round toward the next lower code.
			uint32_t code = (uint8_t)values[index];
			uint32_t bucket = code * (uint32_t)levels / 256U;
			values[index] = (int8_t)(uint8_t)(bucket * 256U / (uint32_t)levels);
		}
	}
	return YES;
}

static BOOL PPEchoBytes(sData *sample, size_t start, size_t end, double delayMilliseconds, double strengthPercent)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size || delayMilliseconds <= 0.0 ||
		!isfinite(delayMilliseconds) || !isfinite(strengthPercent)) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t channels = sample->stereo ? 2 : 1;
	size_t startFrame = start / frameSize;
	size_t endFrame = end / frameSize;
	// The plug-in's delay conversion is fixed at 22,254 samples/second; it
	// does not consult c2spd. Preserve that quirk for audible parity.
	size_t delayFrames = (size_t)MAX((int64_t)trunc(delayMilliseconds * 22254.0 / 1000.0), 1);
	if (delayFrames >= endFrame - startFrame) return NO;
	int32_t strength = (int32_t)trunc(strengthPercent);
	// Echo defines its working length as selectionLength - 1, leaving the
	// selection's final scalar value untouched.
	for (size_t frame = startFrame; frame + delayFrames + 1 < endFrame; frame++) {
		for (size_t channel = 0; channel < channels; channel++) {
			size_t sourceIndex = frame * channels + channel;
			size_t destinationIndex = (frame + delayFrames) * channels + channel;
			if (sample->amp == 16) {
				int16_t *values = (int16_t *)sample->data;
				int32_t mixed = values[destinationIndex] + (int32_t)values[sourceIndex] * strength / 100;
				values[destinationIndex] = (int16_t)MAX(MIN(mixed, INT16_MAX), INT16_MIN);
			} else {
				int8_t *values = (int8_t *)sample->data;
				int32_t mixed = values[destinationIndex] + (int32_t)values[sourceIndex] * strength / 100;
				values[destinationIndex] = (int8_t)MAX(MIN(mixed, INT8_MAX), INT8_MIN);
			}
		}
	}
	return YES;
}

static BOOL PPCrossfadeBytes(sData *sample, size_t start, size_t end)
{
	if (sample == NULL || start >= end || end > (size_t)sample->size) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t channels = sample->stereo ? 2 : 1;
	size_t totalFrames = (size_t)sample->size / frameSize;
	size_t startFrame = start / frameSize;
	size_t endFrame = end / frameSize;
	size_t selectedFrames = endFrame - startFrame;
	size_t half = MIN(selectedFrames / 2, MIN(startFrame, totalFrames - endFrame));
	if (half == 0) return NO;
	size_t windowFrames = half * 2;
	size_t leftStart = startFrame - half;
	size_t rightStart = endFrame - half;
	for (NSInteger pass = 0; pass < 2; pass++) {
		for (size_t frame = 0; frame < windowFrames; frame++) {
			int64_t leftWeight = (int64_t)windowFrames - (int64_t)frame;
			int64_t rightWeight = (int64_t)frame;
			for (size_t channel = 0; channel < channels; channel++) {
				size_t leftIndex = (leftStart + frame) * channels + channel;
				size_t rightIndex = (rightStart + frame) * channels + channel;
				if (sample->amp == 16) {
					int16_t *values = (int16_t *)sample->data;
					int32_t left = values[leftIndex], right = values[rightIndex];
					int64_t mixedLeft = (left * leftWeight + right * rightWeight) / (int64_t)windowFrames;
					int64_t mixedRight = (left * rightWeight + right * leftWeight) / (int64_t)windowFrames;
					values[leftIndex] = (int16_t)MAX(MIN(mixedLeft, INT16_MAX), INT16_MIN);
					values[rightIndex] = (int16_t)MAX(MIN(mixedRight, INT16_MAX), INT16_MIN);
				} else {
					int8_t *values = (int8_t *)sample->data;
					int32_t left = values[leftIndex], right = values[rightIndex];
					int32_t mixedLeft = (left * leftWeight + right * rightWeight) / (int64_t)windowFrames;
					int32_t mixedRight = (left * rightWeight + right * leftWeight) / (int64_t)windowFrames;
					values[leftIndex] = (int8_t)MAX(MIN(mixedLeft, 127), -127);
					values[rightIndex] = (int8_t)MAX(MIN(mixedRight, 127), -127);
				}
			}
		}
	}
	return YES;
}

static BOOL PPCreateClassicResampledBytes(const sData *sample, size_t newFrames,
	size_t sourceUnits, size_t destinationUnits, void **bytesOut, size_t *sizeOut)
{
	if (sample == NULL || sample->data == NULL || sample->size <= 0 || newFrames == 0 || bytesOut == NULL || sizeOut == NULL) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t oldFrames = (size_t)sample->size / frameSize;
	if (oldFrames == 0 || newFrames > INT_MAX / frameSize) return NO;
	size_t newSize = newFrames * frameSize;
	void *replacement = calloc(newSize, 1);
	if (replacement == NULL) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	if (sourceUnits == 0 || destinationUnits == 0) {
		sourceUnits = oldFrames;
		destinationUnits = newFrames;
	}
	for (size_t frame = 0; frame < newFrames; frame++) {
		uint64_t eighthPosition = (uint64_t)frame * (uint64_t)sourceUnits * 8ULL /
			(uint64_t)destinationUnits;
		size_t leftFrame = (size_t)(eighthPosition >> 3);
		unsigned int fraction = (unsigned int)(eighthPosition & 7U);
		if (leftFrame >= oldFrames) {
			leftFrame = oldFrames - 1;
			fraction = 0;
		}
		size_t rightFrame = MIN(leftFrame + 1, oldFrames - 1);
		int32_t inverse = 8 - (int32_t)fraction;
		for (size_t channel = 0; channel < channels; channel++) {
			size_t sourceLeft = leftFrame * channels + channel;
			size_t sourceRight = rightFrame * channels + channel;
			size_t destination = frame * channels + channel;
			if (sample->amp == 16) {
				const int16_t *input = (const int16_t *)sample->data;
				int16_t *output = replacement;
				int32_t mixed = (inverse * input[sourceLeft] + (int32_t)fraction * input[sourceRight]) >> 3;
				output[destination] = (int16_t)mixed;
			} else {
				const int8_t *input = (const int8_t *)sample->data;
				int8_t *output = replacement;
				int16_t mixed = (inverse * input[sourceLeft] + (int32_t)fraction * input[sourceRight]) >> 3;
				output[destination] = (int8_t)mixed;
			}
		}
	}
	*bytesOut = replacement;
	*sizeOut = newSize;
	return YES;
}

static BOOL PPCreateResampledBytes(const sData *sample, size_t newFrames, void **bytesOut, size_t *sizeOut)
{
	size_t oldBytes = sample == NULL ? 0 : (size_t)MAX(sample->size, 0);
	size_t newBytes = sample == NULL ? 0 : newFrames * PPBytesPerFrame(sample);
	// Length divides both byte counts by 100 before calculating source
	// positions. Retain that coarse classic ratio, with a safe fallback for
	// tiny samples that would have divided by zero in the original.
	size_t sourceUnits = oldBytes / 100;
	size_t destinationUnits = newBytes / 100;
	if (sourceUnits == 0 || destinationUnits == 0) {
		sourceUnits = oldBytes;
		destinationUnits = newBytes;
	}
	return PPCreateClassicResampledBytes(sample, newFrames, sourceUnits, destinationUnits,
		bytesOut, sizeOut);
}

static BOOL PPResampleFrames(sData *sample, size_t newFrames, BOOL updatePlaybackRate)
{
	if (sample == NULL) return NO;
	size_t oldSize = (size_t)MAX(sample->size, 0);
	size_t frameSize = PPBytesPerFrame(sample);
	size_t oldFrames = oldSize / frameSize;
	if (oldFrames == 0) return NO;
	void *replacement = NULL;
	size_t newSize = 0;
	if (!PPCreateResampledBytes(sample, newFrames, &replacement, &newSize)) return NO;
	size_t oldUnits = oldSize / 100;
	size_t newUnits = newSize / 100;
	NSInteger newLoopBeg, newLoopSize;
	unsigned int newRate = sample->c2spd;
	if (oldUnits > 0 && newUnits > 0) {
		newLoopBeg = (NSInteger)((int64_t)sample->loopBeg * (int64_t)newUnits / (int64_t)oldUnits);
		newLoopSize = (NSInteger)((int64_t)sample->loopSize * (int64_t)newUnits / (int64_t)oldUnits);
		if (updatePlaybackRate)
			newRate = (unsigned int)((uint64_t)MAX(sample->c2spd, 1) * newUnits / oldUnits);
	} else {
		// The classic code divides by zero for sub-100-byte samples. Keep those
		// usable while retaining its integer scaling everywhere it was defined.
		double ratio = (double)newFrames / (double)oldFrames;
		newLoopBeg = (NSInteger)trunc((double)sample->loopBeg * ratio);
		newLoopSize = (NSInteger)trunc((double)sample->loopSize * ratio);
		if (updatePlaybackRate) newRate = (unsigned int)trunc((double)MAX(sample->c2spd, 1) * ratio);
	}
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)newSize;
	sample->loopBeg = (int)newLoopBeg;
	sample->loopSize = (int)newLoopSize;
	sample->c2spd = (unsigned short)MIN(MAX(newRate, 1U), (unsigned int)UINT16_MAX);
	PPClampLoop(sample);
	return YES;
}

static BOOL PPChangeSamplingRate(sData *sample, unsigned int newRate)
{
	if (sample == NULL || sample->c2spd == 0 || newRate < 1) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	size_t oldFrames = (size_t)sample->size / frameSize;
	size_t oldUnits = sample->c2spd / 100U;
	size_t newUnits = newRate / 100U;
	if (oldUnits == 0 || newUnits == 0) {
		oldUnits = sample->c2spd;
		newUnits = newRate;
	}
	size_t newFrames = MAX(oldFrames * newUnits / oldUnits, (size_t)1);
	void *replacement = NULL;
	size_t newSize = 0;
	if (!PPCreateClassicResampledBytes(sample, newFrames, oldUnits, newUnits,
		&replacement, &newSize)) return NO;
	sample->loopBeg = (int)((int64_t)sample->loopBeg * (int64_t)newUnits / (int64_t)oldUnits);
	sample->loopSize = (int)((int64_t)sample->loopSize * (int64_t)newUnits / (int64_t)oldUnits);
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)newSize;
	sample->c2spd = (unsigned short)MIN(newRate, (unsigned int)UINT16_MAX);
	PPClampLoop(sample);
	return YES;
}

typedef NS_ENUM(NSInteger, PPSampleLengthMode) {
	PPSampleLengthMoveLeft = 0,
	PPSampleLengthMoveRight,
	PPSampleLengthStretch
};

static BOOL PPChangeLengthFrames(sData *sample, size_t newFrames, PPSampleLengthMode mode, BOOL updatePlaybackRate)
{
	if (sample == NULL || sample->data == NULL || newFrames == 0) return NO;
	if (mode == PPSampleLengthStretch) return PPResampleFrames(sample, newFrames, updatePlaybackRate);
	size_t frameSize = PPBytesPerFrame(sample);
	size_t oldSize = (size_t)sample->size;
	if (newFrames > INT_MAX / frameSize) return NO;
	size_t newSize = newFrames * frameSize;
	void *replacement = calloc(newSize, 1);
	if (replacement == NULL) return NO;
	size_t copied = MIN(oldSize, newSize);
	if (mode == PPSampleLengthMoveRight) {
		memcpy((char *)replacement + newSize - copied, sample->data + oldSize - copied, copied);
		sample->loopBeg += (int)newSize - (int)oldSize;
	} else {
		memcpy(replacement, sample->data, copied);
	}
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)newSize;
	PPClampLoop(sample);
	return YES;
}

static BOOL PPReplaceRangeBytes(sData *sample, size_t start, size_t end, const void *bytes, size_t byteCount)
{
	if (sample == NULL || start > end || end > (size_t)sample->size || (byteCount > 0 && bytes == NULL) ||
		(size_t)sample->size - (end - start) + byteCount > INT_MAX) return NO;
	size_t oldSize = (size_t)sample->size;
	size_t newSize = oldSize - (end - start) + byteCount;
	char *replacement = newSize == 0 ? NULL : malloc(newSize);
	if (newSize > 0 && replacement == NULL) return NO;
	if (start > 0) memcpy(replacement, sample->data, start);
	if (byteCount > 0) memcpy(replacement + start, bytes, byteCount);
	if (end < oldSize) memcpy(replacement + start + byteCount, sample->data + end, oldSize - end);
	NSInteger oldLoopEnd = sample->loopBeg + sample->loopSize;
	NSInteger delta = (NSInteger)byteCount - (NSInteger)(end - start);
	if (sample->loopSize > 0 && sample->loopBeg >= (NSInteger)end) sample->loopBeg += (int)delta;
	else if (sample->loopSize > 0 && oldLoopEnd > (NSInteger)start) { sample->loopBeg = 0; sample->loopSize = 0; }
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)newSize;
	PPClampLoop(sample);
	return YES;
}

typedef NS_ENUM(NSInteger, PPToneWaveform) {
	PPToneSilence = 0,
	PPToneTriangle,
	PPToneSquare,
	PPToneSine
};

static BOOL PPGenerateTone(sData *sample, size_t start, size_t end, size_t frames, double frequency,
	double amplitudePercent, PPToneWaveform waveform)
{
	if (sample == NULL || frames == 0 || start > end || end > (size_t)sample->size ||
		(sample->amp != 8 && sample->amp != 16) ||
		waveform < PPToneSilence || waveform > PPToneSine ||
		!isfinite(frequency) || !isfinite(amplitudePercent) ||
		amplitudePercent < 0.0 ||
		(waveform != PPToneSilence && frequency <= 0.0)) return NO;
	size_t frameSize = PPBytesPerFrame(sample);
	if (frames > INT_MAX / frameSize) return NO;
	size_t byteCount = frames * frameSize;
	void *generated = calloc(byteCount, 1);
	if (generated == NULL) return NO;
	size_t channels = sample->stereo ? 2 : 1;
	// The original Tone Generator is intentionally independent of the sample's
	// C-2 playback rate. Its four oscillators use this fixed Sound Manager
	// timebase and integer percentage scaling.
	const double classicRate = 22254.54545;
	const NSInteger percent = (NSInteger)trunc(amplitudePercent);
	size_t cycle = 0;
	NSInteger destination = -1;
	NSInteger interval = 1;
	BOOL rising = YES;
	// The old source left this local uninitialised; its normal first branch
	// chooses the negative rail unless stale stack data happens to equal it.
	// Use that stable, audible result rather than reproducing undefined memory.
	long squareValue = 0;
	for (size_t frame = 0; frame < frames; frame++) {
		long rawValue = 0;
		long maximum = sample->amp == 16 ? 32767L : 127L;
		if (waveform == PPToneSine) {
			double phase = 2.0 * M_PI * frequency * (double)frame / classicRate;
			rawValue = (long)trunc(sin(phase) * (double)maximum);
		} else if (waveform == PPToneSquare) {
			NSInteger scalarPosition = (NSInteger)(frame * channels);
			if (scalarPosition > destination) {
				cycle++;
				destination = (NSInteger)trunc((double)cycle * classicRate / (frequency * 2.0));
				if (channels == 2) destination *= 2;
				squareValue = squareValue == -maximum ? maximum : -maximum;
			}
			rawValue = squareValue;
		} else if (waveform == PPToneTriangle) {
			NSInteger scalarPosition = (NSInteger)(frame * channels);
			if (scalarPosition > destination) {
				cycle++;
				destination = (NSInteger)trunc((double)cycle * classicRate / (frequency * 2.0));
				if (channels == 2) destination *= 2;
				interval = MAX(destination - scalarPosition, (NSInteger)1);
				rising = !rising;
			}
			NSInteger remaining = destination - scalarPosition;
			if (sample->amp == 16) {
				rawValue = rising ? (65535L * remaining) / interval :
					(65535L * (interval - remaining)) / interval;
				rawValue -= 32767L;
			} else {
				rawValue = rising ? (256L * remaining) / interval :
					(256L * (interval - remaining)) / interval;
				rawValue -= 127L;
			}
		}
		long value = rawValue * percent / 100;
		value = sample->amp == 16 ? MIN(MAX(value, -32768L), 32767L) :
			MIN(MAX(value, -127L), 127L);
		for (size_t channel = 0; channel < channels; channel++) {
			size_t index = frame * channels + channel;
			if (sample->amp == 16) ((int16_t *)generated)[index] = (int16_t)value;
			else ((int8_t *)generated)[index] = (int8_t)value;
		}
	}
	BOOL result = PPReplaceRangeBytes(sample, start, end, generated, byteCount);
	free(generated);
	return result;
}

static double PPClipboardValue(const uint8_t *bytes, const PPSampleClipboardHeader *header,
	double sourcePosition, size_t destinationChannel, size_t destinationChannels)
{
	size_t sourceChannels = header->channels;
	size_t bytesPerSample = header->amplitude == 16 ? 2 : 1;
	size_t frames = header->byteCount / (bytesPerSample * sourceChannels);
	if (frames == 0) return 0.0;
	size_t leftFrame = MIN((size_t)floor(sourcePosition), frames - 1);
	size_t rightFrame = MIN(leftFrame + 1, frames - 1);
	double fraction = sourcePosition - floor(sourcePosition);
	double value = 0.0;
	if (destinationChannels == 1 && sourceChannels == 2) {
		for (size_t channel = 0; channel < 2; channel++) {
			double left = PPReadNormalizedPCM(bytes, header->amplitude, sourceChannels, leftFrame, channel);
			double right = PPReadNormalizedPCM(bytes, header->amplitude, sourceChannels, rightFrame, channel);
			value += left + (right - left) * fraction;
		}
		return value / 2.0;
	}
	size_t sourceChannel = sourceChannels == 1 ? 0 : MIN(destinationChannel, sourceChannels - 1);
	double left = PPReadNormalizedPCM(bytes, header->amplitude, sourceChannels, leftFrame, sourceChannel);
	double right = PPReadNormalizedPCM(bytes, header->amplitude, sourceChannels, rightFrame, sourceChannel);
	return left + (right - left) * fraction;
}

static BOOL PPMixClipboard(sData *sample, size_t offset, const PPSampleClipboardHeader *header,
	const uint8_t *clipboardBytes, double samplePercent, double clipboardPercent)
{
	if (sample == NULL || header == NULL || clipboardBytes == NULL || header->version != 1 ||
		(header->amplitude != 8 && header->amplitude != 16) || (header->channels != 1 && header->channels != 2) ||
		header->sampleRate == 0 || offset > (size_t)sample->size) return NO;
	size_t destinationFrameSize = PPBytesPerFrame(sample);
	size_t destinationChannels = sample->stereo ? 2 : 1;
	size_t sourceFrameSize = (header->amplitude == 16 ? 2 : 1) * header->channels;
	if (header->byteCount == 0 || header->byteCount % sourceFrameSize != 0) return NO;
	size_t sourceFrames = header->byteCount / sourceFrameSize;
	size_t mixedFrames = (size_t)MAX(ceil((double)sourceFrames * (double)MAX(sample->c2spd, 1) /
		(double)header->sampleRate), 1.0);
	size_t offsetFrame = offset / destinationFrameSize;
	size_t existingFrames = (size_t)sample->size / destinationFrameSize;
	size_t resultFrames = MAX(existingFrames, offsetFrame + mixedFrames);
	if (resultFrames > INT_MAX / destinationFrameSize) return NO;
	size_t resultSize = resultFrames * destinationFrameSize;
	void *replacement = calloc(resultSize, 1);
	if (replacement == NULL) return NO;
	double baseGain = samplePercent / 100.0;
	double clipGain = clipboardPercent / 100.0;
	double peak = 0.0;
	for (size_t frame = 0; frame < resultFrames; frame++) {
		for (size_t channel = 0; channel < destinationChannels; channel++) {
			double base = frame < existingFrames ? PPReadNormalizedPCM(sample->data, sample->amp,
				destinationChannels, frame, channel) : 0.0;
			double clip = 0.0;
			if (frame >= offsetFrame && frame < offsetFrame + mixedFrames) {
				double sourcePosition = mixedFrames == 1 ? 0.0 : (double)(frame - offsetFrame) *
					(double)(sourceFrames - 1) / (double)(mixedFrames - 1);
				clip = PPClipboardValue(clipboardBytes, header, sourcePosition, channel, destinationChannels);
			}
			peak = MAX(peak, fabs(base * baseGain + clip * clipGain));
		}
	}
	double normalization = peak > 0.0 ? 1.0 / peak : 1.0;
	for (size_t frame = 0; frame < resultFrames; frame++) {
		for (size_t channel = 0; channel < destinationChannels; channel++) {
			double base = frame < existingFrames ? PPReadNormalizedPCM(sample->data, sample->amp,
				destinationChannels, frame, channel) : 0.0;
			double clip = 0.0;
			if (frame >= offsetFrame && frame < offsetFrame + mixedFrames) {
				double sourcePosition = mixedFrames == 1 ? 0.0 : (double)(frame - offsetFrame) *
					(double)(sourceFrames - 1) / (double)(mixedFrames - 1);
				clip = PPClipboardValue(clipboardBytes, header, sourcePosition, channel, destinationChannels);
			}
			PPWriteNormalizedPCM(replacement, sample->amp, destinationChannels, frame, channel,
				(base * baseGain + clip * clipGain) * normalization);
		}
	}
	free(sample->data);
	sample->data = replacement;
	sample->size = (int)resultSize;
	PPClampLoop(sample);
	return YES;
}

@interface PPSampleSnapshot : NSObject
@property(nonatomic) NSInteger sampleIndex;
@property(nonatomic) int size;
@property(nonatomic) int loopBeg;
@property(nonatomic) int loopSize;
@property(nonatomic) MADByte vol;
@property(nonatomic) unsigned short c2spd;
@property(nonatomic) MADLoopType loopType;
@property(nonatomic) MADByte amp;
@property(nonatomic) char realNote;
@property(nonatomic) MADBool stereo;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSData *data;
@property(nonatomic, copy) NSData *instrumentData;
@end

@implementation PPSampleSnapshot
@end

@class PPSampleWaveformView;

@protocol PPSampleWaveformDelegate <NSObject>
- (void)waveformSelectionDidChange:(PPSampleWaveformView *)view;
- (void)waveformWillBeginPencilEdit:(PPSampleWaveformView *)view;
- (void)waveformDidEditWithPencil:(PPSampleWaveformView *)view;
- (void)waveform:(PPSampleWaveformView *)view previewNote:(MADByte)note selectionOnly:(BOOL)selectionOnly;
- (void)waveformStopPreview:(PPSampleWaveformView *)view;
@end

@interface PPSampleWaveformView : NSView
@property(nonatomic, weak) id<PPSampleWaveformDelegate> delegate;
@property(nonatomic) sData *sample;
@property(nonatomic) InstrData *instrument;
@property(nonatomic) NSInteger displayMode;
@property(nonatomic) NSInteger selectionStart;
@property(nonatomic) NSInteger selectionEnd;
@property(nonatomic) NSInteger visibleStart;
@property(nonatomic) NSInteger visibleLength;
@property(nonatomic) PPSampleTool tool;
- (void)showAll;
- (void)showSelection;
- (void)adjustEnvelopeMarkersForInsertAtIndex:(NSInteger)index;
- (void)deleteEnvelopePointAtIndex:(NSInteger)index;
@end

@implementation PPSampleWaveformView {
	NSInteger _selectionAnchor;
	NSInteger _editingEnvelopeIndex;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)isFlipped { return YES; }

- (void)showAll
{
	self.visibleStart = 0;
	self.visibleLength = self.displayMode < 0 ? PPEnvelopeLength : MAX(self.sample->size, 1);
	[self setNeedsDisplay:YES];
}

- (void)showSelection
{
	NSInteger start = MIN(self.selectionStart, self.selectionEnd);
	NSInteger end = MAX(self.selectionStart, self.selectionEnd);
	if (end > start) {
		self.visibleStart = start;
		self.visibleLength = end - start;
		[self setNeedsDisplay:YES];
	}
}

- (NSInteger)byteAtX:(CGFloat)x
{
	NSInteger contentLength = self.displayMode < 0 ? PPEnvelopeLength : (self.sample == NULL ? 0 : self.sample->size);
	if (contentLength <= 0 || self.bounds.size.width <= 1) return 0;
	CGFloat unit = MIN(MAX(x / self.bounds.size.width, 0.0), 1.0);
	NSInteger value = self.visibleStart + (NSInteger)llround(unit * self.visibleLength);
	if (self.displayMode < 0) return MIN(MAX(value, 0), PPEnvelopeLength);
	return (NSInteger)PPAlignedOffset(self.sample, value);
}

- (CGFloat)xForByte:(NSInteger)offset
{
	if (self.visibleLength <= 0) return 0;
	return ((CGFloat)(offset - self.visibleStart) / (CGFloat)self.visibleLength) * self.bounds.size.width;
}

- (CGFloat)normalizedSampleAtByte:(size_t)offset channel:(NSInteger)channel
{
	size_t sampleBytes = self.sample->amp == 16 ? 2 : 1;
	size_t channelOffset = offset + (size_t)channel * sampleBytes;
	if (channelOffset + sampleBytes > (size_t)self.sample->size) return 0;
	if (self.sample->amp == 16) {
		int16_t value;
		memcpy(&value, self.sample->data + channelOffset, sizeof(value));
		return (CGFloat)value / 32768.0;
	}
	return (CGFloat)*(int8_t *)(self.sample->data + channelOffset) / 128.0;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	[[NSColor colorWithCalibratedWhite:0.72 alpha:1.0] setStroke];
	NSFrameRect(self.bounds);
	if (self.displayMode < 0) {
		[self drawEnvelope];
		return;
	}
	if (self.sample == NULL || self.sample->data == NULL || self.sample->size <= 0) {
		NSDictionary *attributes = @{NSFontAttributeName: [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont systemFontOfSize:9],
			NSForegroundColorAttributeName: NSColor.disabledControlTextColor};
		[@"No sample data" drawAtPoint:NSMakePoint(8, 8) withAttributes:attributes];
		return;
	}

	NSInteger selectionStart = MIN(self.selectionStart, self.selectionEnd);
	NSInteger selectionEnd = MAX(self.selectionStart, self.selectionEnd);
	if (selectionEnd > selectionStart) {
		CGFloat left = [self xForByte:selectionStart];
		CGFloat right = [self xForByte:selectionEnd];
		[[NSColor colorWithCalibratedRed:0.73 green:0.84 blue:1.0 alpha:0.7] setFill];
		NSRectFill(NSMakeRect(left, 1, MAX(right - left, 1), self.bounds.size.height - 2));
	}

	NSInteger channels = self.sample->stereo ? 2 : 1;
	CGFloat channelHeight = self.bounds.size.height / channels;
	for (NSInteger channel = 0; channel < channels; channel++) {
		CGFloat center = channel * channelHeight + channelHeight / 2.0;
		[[NSColor colorWithCalibratedWhite:0.84 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, center) toPoint:NSMakePoint(self.bounds.size.width, center)];
		NSBezierPath *wave = [NSBezierPath bezierPath];
		wave.lineWidth = 1.0;
		size_t frameSize = PPBytesPerFrame(self.sample);
		NSInteger pixelCount = MAX((NSInteger)ceil(self.bounds.size.width), 1);
		for (NSInteger pixel = 0; pixel < pixelCount; pixel++) {
			size_t begin = PPAlignedOffset(self.sample, self.visibleStart + (self.visibleLength * pixel) / pixelCount);
			size_t finish = PPAlignedOffset(self.sample, self.visibleStart + (self.visibleLength * (pixel + 1)) / pixelCount);
			if (finish <= begin) finish = MIN(begin + frameSize, (size_t)self.sample->size);
			CGFloat low = 1.0, high = -1.0;
			for (size_t offset = begin; offset < finish; offset += frameSize) {
				CGFloat value = [self normalizedSampleAtByte:offset channel:channel];
				low = MIN(low, value);
				high = MAX(high, value);
			}
			if (high < low) low = high = 0;
			CGFloat x = pixel + 0.5;
			CGFloat y1 = center - high * (channelHeight * 0.46);
			CGFloat y2 = center - low * (channelHeight * 0.46);
			[wave moveToPoint:NSMakePoint(x, y1)];
			[wave lineToPoint:NSMakePoint(x, y2)];
		}
		[(channel == 0 ? [NSColor colorWithCalibratedRed:0.72 green:0.08 blue:0.08 alpha:1.0]
			: [NSColor colorWithCalibratedRed:0.05 green:0.18 blue:0.72 alpha:1.0]) setStroke];
		[wave stroke];
	}

	if (self.sample->loopSize > 0) {
		[[NSColor colorWithCalibratedRed:0.0 green:0.48 blue:0.0 alpha:1.0] setStroke];
		CGFloat start = [self xForByte:self.sample->loopBeg];
		CGFloat end = [self xForByte:self.sample->loopBeg + self.sample->loopSize];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(start, 1) toPoint:NSMakePoint(start, self.bounds.size.height - 1)];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(end, 1) toPoint:NSMakePoint(end, self.bounds.size.height - 1)];
	}
}

- (EnvRec *)envelopePoints
{
	if (self.instrument == NULL) return NULL;
	return self.displayMode == PPVolumeEnvelopeMode ? self.instrument->volEnv : self.instrument->pannEnv;
}

- (MADByte *)envelopeSizePointer
{
	if (self.instrument == NULL) return NULL;
	return self.displayMode == PPVolumeEnvelopeMode ? &self.instrument->volSize : &self.instrument->pannSize;
}

- (EFType *)envelopeTypePointer
{
	if (self.instrument == NULL) return NULL;
	return self.displayMode == PPVolumeEnvelopeMode ? &self.instrument->volType : &self.instrument->pannType;
}

- (MADByte *)envelopeSustainPointer
{
	return self.displayMode == PPVolumeEnvelopeMode ? &self.instrument->volSus : &self.instrument->pannSus;
}

- (MADByte *)envelopeLoopBeginPointer
{
	return self.displayMode == PPVolumeEnvelopeMode ? &self.instrument->volBeg : &self.instrument->pannBeg;
}

- (MADByte *)envelopeLoopEndPointer
{
	return self.displayMode == PPVolumeEnvelopeMode ? &self.instrument->volEnd : &self.instrument->pannEnd;
}

- (void)drawEnvelope
{
	NSInteger selectionStart = MIN(self.selectionStart, self.selectionEnd);
	NSInteger selectionEnd = MAX(self.selectionStart, self.selectionEnd);
	if (selectionEnd > selectionStart) {
		CGFloat left = [self xForByte:selectionStart];
		CGFloat right = [self xForByte:selectionEnd];
		[[NSColor colorWithCalibratedRed:0.73 green:0.84 blue:1.0 alpha:0.7] setFill];
		NSRectFill(NSMakeRect(left, 1, MAX(right - left, 1), self.bounds.size.height - 2));
	}
	if (self.displayMode == PPPanningEnvelopeMode) {
		[[NSColor colorWithCalibratedWhite:0.82 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(1, self.bounds.size.height / 2.0)
			toPoint:NSMakePoint(self.bounds.size.width - 1, self.bounds.size.height / 2.0)];
	}
	EnvRec *points = [self envelopePoints];
	MADByte *sizePointer = [self envelopeSizePointer];
	if (points == NULL || sizePointer == NULL || *sizePointer == 0) {
		NSDictionary *attributes = @{NSFontAttributeName: [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont systemFontOfSize:9],
			NSForegroundColorAttributeName: NSColor.disabledControlTextColor};
		[@"Pencil: click to add the first envelope point" drawAtPoint:NSMakePoint(8, 8) withAttributes:attributes];
		return;
	}
	NSInteger count = MIN((NSInteger)*sizePointer, 12);
	EFType type = *[self envelopeTypePointer];
	if ((type & EFTypeLoop) != 0) {
		NSInteger begin = MIN(*[self envelopeLoopBeginPointer], count - 1);
		NSInteger end = MIN(*[self envelopeLoopEndPointer], count - 1);
		CGFloat x1 = [self xForByte:points[begin].pos];
		CGFloat x2 = [self xForByte:points[end].pos];
		[[NSColor colorWithCalibratedRed:0.0 green:0.48 blue:0.0 alpha:1.0] setStroke];
		NSBezierPath *loop = [NSBezierPath bezierPathWithRect:NSMakeRect(MIN(x1, x2), 2, MAX(fabs(x2 - x1), 1), self.bounds.size.height - 4)];
		[loop stroke];
	}
	if ((type & EFTypeSustain) != 0) {
		NSInteger sustain = MIN(*[self envelopeSustainPointer], count - 1);
		CGFloat x = [self xForByte:points[sustain].pos];
		[[NSColor colorWithCalibratedRed:0.55 green:0.1 blue:0.55 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(x, 1) toPoint:NSMakePoint(x, self.bounds.size.height - 1)];
	}
	NSBezierPath *path = [NSBezierPath bezierPath];
	CGFloat firstY = (64 - MIN(MAX(points[0].val, 0), 64)) * (self.bounds.size.height - 4) / 64.0 + 2;
	[path moveToPoint:NSMakePoint(0, firstY)];
	for (NSInteger index = 0; index < count; index++) {
		CGFloat x = [self xForByte:points[index].pos];
		CGFloat y = (64 - MIN(MAX(points[index].val, 0), 64)) * (self.bounds.size.height - 4) / 64.0 + 2;
		[path lineToPoint:NSMakePoint(x, y)];
	}
	CGFloat lastY = (64 - MIN(MAX(points[count - 1].val, 0), 64)) * (self.bounds.size.height - 4) / 64.0 + 2;
	[path lineToPoint:NSMakePoint(self.bounds.size.width, lastY)];
	[[NSColor colorWithCalibratedRed:0.72 green:0.08 blue:0.08 alpha:1.0] setStroke];
	path.lineWidth = 1.5;
	[path stroke];
	for (NSInteger index = 0; index < count; index++) {
		CGFloat x = [self xForByte:points[index].pos];
		CGFloat y = (64 - MIN(MAX(points[index].val, 0), 64)) * (self.bounds.size.height - 4) / 64.0 + 2;
		[[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
		[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - 3, y - 3, 6, 6)] fill];
	}
}

- (void)adjustEnvelopeMarkersForInsertAtIndex:(NSInteger)index
{
	MADByte *sustain = [self envelopeSustainPointer];
	MADByte *begin = [self envelopeLoopBeginPointer];
	MADByte *end = [self envelopeLoopEndPointer];
	if (*sustain >= index && *sustain < 11) (*sustain)++;
	if (*begin >= index && *begin < 11) (*begin)++;
	if (*end >= index && *end < 11) (*end)++;
}

- (void)deleteEnvelopePointAtIndex:(NSInteger)index
{
	MADByte *sizePointer = [self envelopeSizePointer];
	EnvRec *points = [self envelopePoints];
	if (sizePointer == NULL || index < 0 || index >= *sizePointer) return;
	for (NSInteger cursor = index; cursor < *sizePointer - 1; cursor++) points[cursor] = points[cursor + 1];
	(*sizePointer)--;
	MADByte *sustain = [self envelopeSustainPointer];
	MADByte *begin = [self envelopeLoopBeginPointer];
	MADByte *end = [self envelopeLoopEndPointer];
	if (*sustain >= index && *sustain > 0) (*sustain)--;
	if (*begin >= index && *begin > 0) (*begin)--;
	if (*end >= index && *end > 0) (*end)--;
	if (*sizePointer == 0) *[self envelopeTypePointer] &= ~EFTypeOn;
}

- (void)beginEnvelopeEditAtPoint:(NSPoint)point
{
	EnvRec *points = [self envelopePoints];
	MADByte *sizePointer = [self envelopeSizePointer];
	if (points == NULL || sizePointer == NULL) return;
	NSInteger position = [self byteAtX:point.x];
	_editingEnvelopeIndex = -1;
	for (NSInteger index = 0; index < *sizePointer; index++) {
		if (fabs([self xForByte:points[index].pos] - point.x) <= 5) {
			_editingEnvelopeIndex = index;
			break;
		}
	}
	if (_editingEnvelopeIndex < 0 && *sizePointer < 12) {
		NSInteger insertion = 0;
		while (insertion < *sizePointer && points[insertion].pos < position) insertion++;
		for (NSInteger cursor = *sizePointer; cursor > insertion; cursor--) points[cursor] = points[cursor - 1];
		[self adjustEnvelopeMarkersForInsertAtIndex:insertion];
		(*sizePointer)++;
		_editingEnvelopeIndex = insertion;
		points[insertion] = (EnvRec){.pos = (short)position, .val = 32};
		*[self envelopeTypePointer] |= EFTypeOn;
	}
	[self updateEnvelopeEditAtPoint:point allowDelete:NO];
}

- (void)updateEnvelopeEditAtPoint:(NSPoint)point allowDelete:(BOOL)allowDelete
{
	MADByte *sizePointer = [self envelopeSizePointer];
	EnvRec *points = [self envelopePoints];
	if (_editingEnvelopeIndex < 0 || sizePointer == NULL || _editingEnvelopeIndex >= *sizePointer) return;
	if (allowDelete && (point.y < -8 || point.y > self.bounds.size.height + 8)) {
		[self deleteEnvelopePointAtIndex:_editingEnvelopeIndex];
		_editingEnvelopeIndex = -1;
		[self setNeedsDisplay:YES];
		return;
	}
	NSInteger position = [self byteAtX:point.x];
	NSInteger minimum = _editingEnvelopeIndex > 0 ? points[_editingEnvelopeIndex - 1].pos : 0;
	NSInteger maximum = _editingEnvelopeIndex + 1 < *sizePointer ? points[_editingEnvelopeIndex + 1].pos : PPEnvelopeLength;
	position = MIN(MAX(position, minimum), maximum);
	NSInteger value = (NSInteger)llround((1.0 - MIN(MAX(point.y / MAX(self.bounds.size.height, 1.0), 0.0), 1.0)) * 64.0);
	points[_editingEnvelopeIndex].pos = (short)position;
	points[_editingEnvelopeIndex].val = (short)MIN(MAX(value, 0), 64);
	[self setNeedsDisplay:YES];
}

- (void)setPencilValueAtPoint:(NSPoint)point
{
	if (self.sample == NULL || self.sample->data == NULL || self.sample->size <= 0) return;
	NSInteger channels = self.sample->stereo ? 2 : 1;
	CGFloat channelHeight = self.bounds.size.height / channels;
	NSInteger channel = MIN(MAX((NSInteger)(point.y / channelHeight), 0), channels - 1);
	CGFloat center = channel * channelHeight + channelHeight / 2.0;
	CGFloat normalized = MIN(MAX((center - point.y) / (channelHeight * 0.46), -1.0), 1.0);
	size_t offset = PPAlignedOffset(self.sample, [self byteAtX:point.x]);
	if (self.sample->amp == 16) {
		int16_t value = (int16_t)llround(normalized * 32767.0);
		offset += (size_t)channel * 2;
		if (offset + 2 <= (size_t)self.sample->size) memcpy(self.sample->data + offset, &value, 2);
	} else {
		int8_t value = (int8_t)llround(normalized * 127.0);
		offset += (size_t)channel;
		if (offset < (size_t)self.sample->size) memcpy(self.sample->data + offset, &value, 1);
	}
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	if (self.tool == PPSampleToolZoom) {
		NSInteger contentLength = self.displayMode < 0 ? PPEnvelopeLength : MAX(self.sample->size, 1);
		if ((event.modifierFlags & NSEventModifierFlagOption) != 0) {
			NSInteger expanded = MIN(MAX(self.visibleLength * 2, 1), contentLength);
			NSInteger center = [self byteAtX:point.x];
			self.visibleStart = MAX(MIN(center - expanded / 2, contentLength - expanded), 0);
			self.visibleLength = expanded;
		} else if (self.selectionStart != self.selectionEnd) {
			[self showSelection];
		} else {
			NSInteger reduced = MAX(self.visibleLength / 2, self.displayMode < 0 ? 1 : (NSInteger)PPBytesPerFrame(self.sample));
			NSInteger center = [self byteAtX:point.x];
			self.visibleStart = MAX(MIN(center - reduced / 2, contentLength - reduced), 0);
			self.visibleLength = reduced;
		}
		[self setNeedsDisplay:YES];
		[self.delegate waveformSelectionDidChange:self];
		return;
	}

	if (self.tool == PPSampleToolPencil) {
		[self.delegate waveformWillBeginPencilEdit:self];
		if (self.displayMode < 0) [self beginEnvelopeEditAtPoint:point];
		else [self setPencilValueAtPoint:point];
		while (YES) {
			NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
			if (next.type == NSEventTypeLeftMouseUp) break;
			NSPoint nextPoint = [self convertPoint:next.locationInWindow fromView:nil];
			if (self.displayMode < 0) [self updateEnvelopeEditAtPoint:nextPoint allowDelete:YES];
			else [self setPencilValueAtPoint:nextPoint];
		}
		[self.delegate waveformDidEditWithPencil:self];
		return;
	}

	_selectionAnchor = [self byteAtX:point.x];
	self.selectionStart = _selectionAnchor;
	self.selectionEnd = _selectionAnchor;
	[self.delegate waveformSelectionDidChange:self];
	while (YES) {
		NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		if (next.type == NSEventTypeLeftMouseUp) break;
		NSInteger current = [self byteAtX:[self convertPoint:next.locationInWindow fromView:nil].x];
		self.selectionStart = MIN(_selectionAnchor, current);
		self.selectionEnd = MAX(_selectionAnchor, current);
		[self.delegate waveformSelectionDidChange:self];
		[self setNeedsDisplay:YES];
	}
	[self.delegate waveformSelectionDidChange:self];
}

- (void)keyDown:(NSEvent *)event
{
	NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
	if ([characters isEqualToString:@" "]) {
		[self.delegate waveform:self previewNote:48 selectionOnly:YES];
		return;
	}
	if (event.keyCode == 53) {
		[self.delegate waveformStopPreview:self];
		return;
	}
	static NSDictionary<NSString *, NSNumber *> *piano;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		piano = @{@"a":@0, @"w":@1, @"s":@2, @"e":@3, @"d":@4, @"f":@5,
			@"t":@6, @"g":@7, @"y":@8, @"h":@9, @"u":@10, @"j":@11, @"k":@12};
	});
	NSNumber *offset = piano[characters];
	if (offset != nil) {
		[self.delegate waveform:self previewNote:(MADByte)(48 + offset.integerValue) selectionOnly:YES];
		return;
	}
	[super keyDown:event];
}

- (void)cut:(id)sender { (void)sender; [(id)self.delegate cut:sender]; }
- (void)copy:(id)sender { (void)sender; [(id)self.delegate copy:sender]; }
- (void)paste:(id)sender { (void)sender; [(id)self.delegate paste:sender]; }
- (void)delete:(id)sender { (void)sender; [(id)self.delegate delete:sender]; }
- (void)selectAll:(id)sender
{
	(void)sender;
	self.selectionStart = 0;
	self.selectionEnd = self.displayMode < 0 ? PPEnvelopeLength : (self.sample == NULL ? 0 : self.sample->size);
	[self.delegate waveformSelectionDidChange:self];
	[self setNeedsDisplay:YES];
}

@end

@interface PPSampleEditorController () <NSWindowDelegate, PPSampleWaveformDelegate>
@property(nonatomic) MADMusic *music;
@property(nonatomic) MADDriverRec *driver;
@property(nonatomic) NSInteger instrument;
@property(nonatomic) NSInteger sampleIndex;
@property(nonatomic) NSInteger displayMode;
@property(nonatomic, strong) PPSampleWaveformView *waveform;
@property(nonatomic, strong) NSPopUpButton *modePopup;
@property(nonatomic, strong) NSArray<NSButton *> *envelopeButtons;
@property(nonatomic, strong) NSTextField *sizeField;
@property(nonatomic, strong) NSTextField *selectionField;
@property(nonatomic, strong) NSTextField *loopField;
@property(nonatomic, strong) NSTextField *displayField;
@property(nonatomic, strong) NSTextField *rateField;
@property(nonatomic, strong) NSTextField *noteField;
@property(nonatomic, strong) NSTextField *offsetField;
@property(nonatomic, strong) NSSlider *scrollSlider;
@property(nonatomic, strong) NSArray<NSButton *> *toolButtons;
@property(nonatomic, copy) PPSampleEditorHandler changeHandler;
@property(nonatomic, copy) PPSampleEditorHandler closeHandler;
@property(nonatomic, strong) PPSampleSnapshot *pendingPencilSnapshot;
@property(nonatomic, strong) NSData *filterPreviewData;
@property(nonatomic, weak) NSTextField *saturatorGainValue;
@end

@implementation PPSampleEditorController

- (instancetype)initWithMusic:(MADMusic *)music driver:(MADDriverRec *)driver instrument:(NSInteger)instrument
	sample:(NSInteger)sample changeHandler:(PPSampleEditorHandler)changeHandler closeHandler:(PPSampleEditorHandler)closeHandler
{
	self = [super initWithWindow:nil];
	if (self == nil) return nil;
	_music = music;
	_driver = driver;
	_instrument = instrument;
	_sampleIndex = sample;
	_displayMode = sample;
	_changeHandler = [changeHandler copy];
	_closeHandler = [closeHandler copy];
	[self buildWindow];
	return self;
}

- (sData *)sample
{
	if (self.music == NULL || self.sampleIndex < 0 || self.sampleIndex >= self.music->fid[self.instrument].numSamples) return NULL;
	return self.music->sample[self.music->fid[self.instrument].firstSample + self.sampleIndex];
}

- (NSFont *)classicFont
{
	return [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
}

- (NSString *)stringForSampleName:(sData *)sample fallback:(NSString *)fallback
{
	if (sample == NULL) return fallback;
	size_t length = strnlen(sample->name, sizeof(sample->name));
	if (length == 0) return fallback;
	return [[NSString alloc] initWithBytes:sample->name length:length encoding:NSMacOSRomanStringEncoding] ?: fallback;
}

- (void)reloadModePopupSelectingTag:(NSInteger)selectedTag
{
	if (self.modePopup == nil || self.music == NULL) return;
	[self.modePopup removeAllItems];
	NSMenuItem *volumeItem = [[NSMenuItem alloc] initWithTitle:@"Volume Envelope" action:nil keyEquivalent:@""];
	volumeItem.tag = PPVolumeEnvelopeMode;
	[self.modePopup.menu addItem:volumeItem];
	NSMenuItem *panningItem = [[NSMenuItem alloc] initWithTitle:@"Panning Envelope" action:nil keyEquivalent:@""];
	panningItem.tag = PPPanningEnvelopeMode;
	[self.modePopup.menu addItem:panningItem];
	[self.modePopup.menu addItem:NSMenuItem.separatorItem];

	InstrData *instrument = &self.music->fid[self.instrument];
	for (NSInteger index = 0; index < instrument->numSamples; index++) {
		sData *sample = self.music->sample[instrument->firstSample + index];
		NSString *fallback = [NSString stringWithFormat:@"Sample %03ld", (long)index + 1];
		NSString *name = [self stringForSampleName:sample fallback:fallback];
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:
			[NSString stringWithFormat:@"%03ld  %@", (long)index + 1, name]
			action:nil keyEquivalent:@""];
		item.tag = index;
		[self.modePopup.menu addItem:item];
	}

	NSMenuItem *selection = nil;
	for (NSMenuItem *item in self.modePopup.itemArray) {
		if (!item.isSeparatorItem && item.tag == selectedTag) { selection = item; break; }
	}
	if (selection == nil && instrument->numSamples > 0) {
		for (NSMenuItem *item in self.modePopup.itemArray) {
			if (!item.isSeparatorItem && item.tag == 0) { selection = item; break; }
		}
	}
	if (selection == nil) selection = volumeItem;
	[self.modePopup selectItem:selection];
}

- (NSImage *)classicImageNamed:(NSString *)name
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	return path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:path];
}

- (NSTextField *)labelAt:(NSRect)frame
{
	NSTextField *field = [NSTextField labelWithString:@""];
	field.frame = frame;
	field.font = [self classicFont];
	field.lineBreakMode = NSLineBreakByClipping;
	field.autoresizingMask = NSViewMinYMargin;
	[self.window.contentView addSubview:field];
	return field;
}

- (NSButton *)toolButtonAtX:(CGFloat)x image:(NSString *)image action:(SEL)action toolTip:(NSString *)toolTip
{
	NSButton *button = [NSButton buttonWithImage:[self classicImageNamed:image] target:self action:action];
	button.frame = NSMakeRect(x, 209, 20, 20);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.buttonType = NSButtonTypePushOnPushOff;
	button.imageScaling = NSImageScaleProportionallyDown;
	button.focusRingType = NSFocusRingTypeNone;
	button.refusesFirstResponder = YES;
	button.toolTip = toolTip;
	button.autoresizingMask = NSViewMinYMargin;
	[self.window.contentView addSubview:button];
	return button;
}

- (NSButton *)envelopeButtonAtX:(CGFloat)x image:(NSString *)image action:(SEL)action toolTip:(NSString *)toolTip
{
	NSButton *button = [NSButton buttonWithImage:[self classicImageNamed:image] target:self action:action];
	button.frame = NSMakeRect(x, 190, 20, 16);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.buttonType = NSButtonTypePushOnPushOff;
	button.imageScaling = NSImageScaleProportionallyDown;
	button.focusRingType = NSFocusRingTypeNone;
	button.refusesFirstResponder = YES;
	button.autoresizingMask = NSViewMinYMargin;
	button.toolTip = toolTip;
	[self.window.contentView addSubview:button];
	return button;
}

- (void)buildWindow
{
	NSRect frame = NSMakeRect(160, 260, 612, 248);
	NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.minSize = NSMakeSize(536, 152);
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.title = [NSString stringWithFormat:@"Samples — Instrument %03ld", (long)self.instrument + 1];
	self.window = window;

	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 188, 612, 60)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	strip.wantsLayer = YES;
	strip.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.88 alpha:1.0].CGColor;
	strip.layer.borderColor = NSColor.blackColor.CGColor;
	strip.layer.borderWidth = 1.0;
	[window.contentView addSubview:strip positioned:NSWindowBelow relativeTo:nil];

	NSTextField *filtersLabel = [self labelAt:NSMakeRect(3, 232, 55, 13)];
	filtersLabel.stringValue = @"Do Filters:";
	NSPopUpButton *effects = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(60, 231, 25, 16) pullsDown:YES];
	effects.font = [self classicFont];
	effects.autoresizingMask = NSViewMinYMargin;
	effects.refusesFirstResponder = YES;
	[effects addItemWithTitle:@"Effects"];
	NSArray<NSString *> *items = @[@"Selection → Loop", @"Loop → Selection", @"Set Sustain Point", @"Delete", @"-",
		@"FFT - Hz Filter…", @"FFT - Hz Shift…", @"-",
		@"Addotroph…", @"Aderodhiecus", @"Amplitude…", @"Backwards", @"Better Fade…", @"Bit Depth…",
		@"Convolve…", @"Crop", @"CrossFade", @"DC - Circular", @"DC - Linear", @"Echo…", @"EnvTest",
		@"EQ-3…", @"Fade…", @"Fingawalix", @"IIR Filter…", @"Invert", @"Length…", @"Memphif",
		@"Mix…", @"Noooiise…", @"Normalize", @"RingModulate…", @"Sampling Rate…", @"Saturator…",
		@"Silence", @"Smooth", @"Stardust…", @"Tone Generator…",
		@"-", @"Freeverb"];
	for (NSString *item in items) {
		if ([item isEqualToString:@"-"]) [effects.menu addItem:NSMenuItem.separatorItem];
		else {
			NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:item action:@selector(effectChosen:) keyEquivalent:@""];
			menuItem.target = self;
			[effects.menu addItem:menuItem];
		}
	}
	[window.contentView addSubview:effects];

	self.sizeField = [self labelAt:NSMakeRect(102, 219, 94, 13)];
	self.selectionField = [self labelAt:NSMakeRect(185, 232, 180, 13)];
	self.loopField = [self labelAt:NSMakeRect(206, 219, 158, 13)];
	self.displayField = [self labelAt:NSMakeRect(193, 206, 171, 13)];
	self.rateField = [self labelAt:NSMakeRect(377, 232, 173, 13)];
	self.noteField = [self labelAt:NSMakeRect(392, 219, 164, 13)];
	self.offsetField = [self labelAt:NSMakeRect(389, 206, 208, 13)];

	NSButton *info = [self toolButtonAtX:4 image:@"sample-info" action:@selector(showInfo:) toolTip:@"Sample information"];
	NSButton *select = [self toolButtonAtX:29 image:@"sample-select" action:@selector(selectTool:) toolTip:@"Select"];
	NSButton *pencil = [self toolButtonAtX:54 image:@"sample-pencil" action:@selector(pencilTool:) toolTip:@"Pencil (destructive)"];
	NSButton *zoom = [self toolButtonAtX:79 image:@"sample-zoom" action:@selector(zoomTool:) toolTip:@"Zoom; Option-click to zoom out"];
	self.toolButtons = @[select, pencil, zoom];
	(void)info;
	[self selectTool:nil];
	NSButton *envelopeEnabled = [self envelopeButtonAtX:35 image:@"sample-envelope" action:@selector(toggleEnvelope:)
		toolTip:@"Enable envelope"];
	NSButton *fixed = [self envelopeButtonAtX:58 image:@"sample-fixed" action:@selector(toggleFixedSpeed:)
		toolTip:@"Fixed speed"];
	NSButton *sustain = [self envelopeButtonAtX:81 image:@"sample-sustain" action:@selector(toggleSustain:)
		toolTip:@"Enable sustain point"];
	NSButton *loop = [self envelopeButtonAtX:104 image:@"sample-loop" action:@selector(toggleEnvelopeLoop:)
		toolTip:@"Enable envelope loop"];
	self.envelopeButtons = @[envelopeEnabled, fixed, sustain, loop];

	NSButton *fullPreview = [NSButton buttonWithTitle:@"Play all" target:self action:@selector(previewAll:)];
	fullPreview.frame = NSMakeRect(130, 190, 62, 20);
	fullPreview.bezelStyle = NSBezelStyleSmallSquare;
	fullPreview.font = [self classicFont];
	fullPreview.keyEquivalent = @"";
	fullPreview.refusesFirstResponder = YES;
	fullPreview.toolTip = @"Preview the complete sample";
	fullPreview.autoresizingMask = NSViewMinYMargin;
	[window.contentView addSubview:fullPreview];
	NSButton *selectionPreview = [NSButton buttonWithTitle:@"Play selection" target:self action:@selector(previewSelection:)];
	selectionPreview.frame = NSMakeRect(196, 190, 91, 20);
	selectionPreview.bezelStyle = NSBezelStyleSmallSquare;
	selectionPreview.font = [self classicFont];
	selectionPreview.refusesFirstResponder = YES;
	selectionPreview.toolTip = @"Preview the selected byte range (Space)";
	selectionPreview.autoresizingMask = NSViewMinYMargin;
	[window.contentView addSubview:selectionPreview];
	NSButton *stop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopPreviewAction:)];
	stop.frame = NSMakeRect(291, 190, 48, 20);
	stop.bezelStyle = NSBezelStyleSmallSquare;
	stop.font = [self classicFont];
	stop.refusesFirstResponder = YES;
	stop.autoresizingMask = NSViewMinYMargin;
	[window.contentView addSubview:stop];

	self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(344, 190, 155, 20) pullsDown:NO];
	self.modePopup.font = [self classicFont];
	self.modePopup.autoresizingMask = NSViewMinYMargin;
	self.modePopup.target = self;
	self.modePopup.action = @selector(modeChanged:);
	[self reloadModePopupSelectingTag:self.sampleIndex];
	[window.contentView addSubview:self.modePopup];

	self.waveform = [[PPSampleWaveformView alloc] initWithFrame:NSMakeRect(0, 16, 612, 172)];
	self.waveform.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.waveform.delegate = self;
	self.waveform.sample = self.sample;
	self.waveform.instrument = &self.music->fid[self.instrument];
	self.waveform.displayMode = self.displayMode;
	[self.waveform showAll];
	[window.contentView addSubview:self.waveform];

	self.scrollSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(2, 0, 608, 16)];
	self.scrollSlider.minValue = 0;
	self.scrollSlider.maxValue = 1;
	self.scrollSlider.doubleValue = 0;
	self.scrollSlider.controlSize = NSControlSizeMini;
	self.scrollSlider.target = self;
	self.scrollSlider.action = @selector(scrollWaveform:);
	self.scrollSlider.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	[window.contentView addSubview:self.scrollSlider];

	[self updateFields];
	[self updateEnvelopeControls];
	dispatch_async(dispatch_get_main_queue(), ^{ [window makeFirstResponder:self.waveform]; });
}

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	[self stopPreview];
	if (self.closeHandler != nil) self.closeHandler();
}

- (PPSampleSnapshot *)snapshot
{
	sData *sample = self.sample;
	PPSampleSnapshot *snapshot = [[PPSampleSnapshot alloc] init];
	snapshot.sampleIndex = self.sampleIndex;
	snapshot.size = sample->size;
	snapshot.loopBeg = sample->loopBeg;
	snapshot.loopSize = sample->loopSize;
	snapshot.vol = sample->vol;
	snapshot.c2spd = sample->c2spd;
	snapshot.loopType = sample->loopType;
	snapshot.amp = sample->amp;
	snapshot.realNote = sample->realNote;
	snapshot.stereo = sample->stereo;
	snapshot.name = [[NSString alloc] initWithBytes:sample->name length:strnlen(sample->name, sizeof(sample->name))
		encoding:NSMacOSRomanStringEncoding] ?: @"";
	snapshot.data = sample->size > 0 ? [NSData dataWithBytes:sample->data length:(NSUInteger)sample->size] : NSData.data;
	snapshot.instrumentData = [NSData dataWithBytes:&self.music->fid[self.instrument] length:sizeof(InstrData)];
	return snapshot;
}

- (void)restoreSnapshot:(PPSampleSnapshot *)snapshot actionName:(NSString *)actionName
{
	NSInteger targetSample = MIN(MAX(snapshot.sampleIndex, 0),
		MAX((NSInteger)self.music->fid[self.instrument].numSamples - 1, 0));
	self.sampleIndex = targetSample;
	PPSampleSnapshot *current = [self snapshot];
	[[self.window.undoManager prepareWithInvocationTarget:self] restoreSnapshot:current actionName:actionName];
	sData *sample = self.sample;
	if (snapshot.instrumentData.length == sizeof(InstrData)) {
		memcpy(&self.music->fid[self.instrument], snapshot.instrumentData.bytes, sizeof(InstrData));
	}
	PPReplaceBytes(sample, snapshot.data.bytes, snapshot.data.length);
	sample->loopBeg = snapshot.loopBeg;
	sample->loopSize = snapshot.loopSize;
	sample->vol = snapshot.vol;
	sample->c2spd = snapshot.c2spd;
	sample->loopType = snapshot.loopType;
	sample->amp = snapshot.amp;
	sample->realNote = snapshot.realNote;
	sample->stereo = snapshot.stereo;
	memset(sample->name, 0, sizeof(sample->name));
	NSData *name = [snapshot.name dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	memcpy(sample->name, name.bytes, MIN(name.length, sizeof(sample->name) - 1));
	[self.window.undoManager setActionName:actionName];
	if (self.displayMode >= 0) self.displayMode = targetSample;
	[self reloadModePopupSelectingTag:self.displayMode];
	self.waveform.displayMode = self.displayMode;
	self.waveform.sample = sample;
	self.waveform.instrument = &self.music->fid[self.instrument];
	self.waveform.selectionStart = MIN(self.waveform.selectionStart, sample->size);
	self.waveform.selectionEnd = MIN(self.waveform.selectionEnd, sample->size);
	[self.waveform showAll];
	[self updateEnvelopeControls];
	[self didChange];
}

- (void)beginUndo:(NSString *)name snapshot:(PPSampleSnapshot *)snapshot
{
	[[self.window.undoManager prepareWithInvocationTarget:self] restoreSnapshot:snapshot actionName:name];
	[self.window.undoManager setActionName:name];
}

- (void)didChange
{
	if (self.music != NULL) self.music->hasChanged = true;
	[self updateEnvelopeControls];
	[self updateFields];
	[self.waveform setNeedsDisplay:YES];
	if (self.changeHandler != nil) self.changeHandler();
}

- (NSRange)selectionRangeAllowWholeSample:(BOOL)allowWhole
{
	if (self.displayMode < 0) {
		NSInteger start = MIN(MAX(MIN(self.waveform.selectionStart, self.waveform.selectionEnd), 0), PPEnvelopeLength);
		NSInteger end = MIN(MAX(MAX(self.waveform.selectionStart, self.waveform.selectionEnd), 0), PPEnvelopeLength);
		if (start == end && allowWhole) { start = 0; end = PPEnvelopeLength; }
		return NSMakeRange((NSUInteger)start, (NSUInteger)(end - start));
	}
	sData *sample = self.sample;
	if (sample == NULL) return NSMakeRange(NSNotFound, 0);
	size_t start = PPAlignedOffset(sample, MIN(self.waveform.selectionStart, self.waveform.selectionEnd));
	size_t end = PPAlignedOffset(sample, MAX(self.waveform.selectionStart, self.waveform.selectionEnd));
	if (start == end && allowWhole) {
		start = 0;
		end = (size_t)sample->size;
	}
	return NSMakeRange(start, end - start);
}

- (void)updateFields
{
	sData *sample = self.sample;
	NSInteger start = MIN(self.waveform.selectionStart, self.waveform.selectionEnd);
	NSInteger end = MAX(self.waveform.selectionStart, self.waveform.selectionEnd);
	if (self.displayMode < 0) {
		InstrData *instrument = &self.music->fid[self.instrument];
		BOOL volume = self.displayMode == PPVolumeEnvelopeMode;
		EnvRec *points = volume ? instrument->volEnv : instrument->pannEnv;
		NSInteger count = volume ? instrument->volSize : instrument->pannSize;
		EFType type = volume ? instrument->volType : instrument->pannType;
		NSInteger loopBegin = volume ? instrument->volBeg : instrument->pannBeg;
		NSInteger loopEnd = volume ? instrument->volEnd : instrument->pannEnd;
		self.sizeField.stringValue = [NSString stringWithFormat:@"Size: %ld Pts", (long)count];
		self.selectionField.stringValue = [NSString stringWithFormat:@"Selection: %ld to: %ld", (long)start, (long)end];
		if ((type & EFTypeLoop) != 0 && count > 0) {
			loopBegin = MIN(loopBegin, count - 1); loopEnd = MIN(loopEnd, count - 1);
			self.loopField.stringValue = [NSString stringWithFormat:@"Loop: %d to: %d", points[loopBegin].pos, points[loopEnd].pos];
		} else self.loopField.stringValue = @"Loop: —";
		self.displayField.stringValue = [NSString stringWithFormat:@"Display: %ld to: %ld", (long)self.waveform.visibleStart,
			(long)(self.waveform.visibleStart + self.waveform.visibleLength)];
		self.rateField.stringValue = volume ? @"Volume Envelope" : @"Panning Envelope";
		self.noteField.stringValue = (type & EFTypeNote) != 0 ? @"Speed: Note-relative" : @"Speed: Fixed";
		self.offsetField.stringValue = [NSString stringWithFormat:@"X/Offsets: %ld / %ld", (long)start, (long)end];
		return;
	}
	if (sample == NULL) return;
	self.sizeField.stringValue = [NSString stringWithFormat:@"Size: %d", sample->size];
	self.selectionField.stringValue = [NSString stringWithFormat:@"Selection: %ld to: %ld", (long)start, (long)end];
	self.loopField.stringValue = [NSString stringWithFormat:@"Loop: %d to: %d", sample->loopBeg, sample->loopBeg + sample->loopSize];
	self.displayField.stringValue = [NSString stringWithFormat:@"Display: %ld to: %ld", (long)self.waveform.visibleStart,
		(long)(self.waveform.visibleStart + self.waveform.visibleLength)];
	self.rateField.stringValue = [NSString stringWithFormat:@"Rate (c4spd): %u Hz", sample->c2spd];
	self.noteField.stringValue = [NSString stringWithFormat:@"Real Note: %d", sample->realNote];
	self.offsetField.stringValue = [NSString stringWithFormat:@"X/Offsets: %ld / 0x%lX", (long)start, (long)start];
}

- (EFType *)currentEnvelopeTypePointer
{
	if (self.displayMode == PPVolumeEnvelopeMode) return &self.music->fid[self.instrument].volType;
	if (self.displayMode == PPPanningEnvelopeMode) return &self.music->fid[self.instrument].pannType;
	return NULL;
}

- (EnvRec *)currentEnvelopePoints
{
	return self.displayMode == PPVolumeEnvelopeMode ? self.music->fid[self.instrument].volEnv
		: self.music->fid[self.instrument].pannEnv;
}

- (MADByte)currentEnvelopeSize
{
	return self.displayMode == PPVolumeEnvelopeMode ? self.music->fid[self.instrument].volSize
		: self.music->fid[self.instrument].pannSize;
}

- (MADByte *)currentEnvelopeSustainPointer
{
	return self.displayMode == PPVolumeEnvelopeMode ? &self.music->fid[self.instrument].volSus
		: &self.music->fid[self.instrument].pannSus;
}

- (MADByte *)currentEnvelopeLoopBeginPointer
{
	return self.displayMode == PPVolumeEnvelopeMode ? &self.music->fid[self.instrument].volBeg
		: &self.music->fid[self.instrument].pannBeg;
}

- (MADByte *)currentEnvelopeLoopEndPointer
{
	return self.displayMode == PPVolumeEnvelopeMode ? &self.music->fid[self.instrument].volEnd
		: &self.music->fid[self.instrument].pannEnd;
}

- (NSInteger)nearestEnvelopePointToPosition:(NSInteger)position
{
	NSInteger count = [self currentEnvelopeSize];
	if (count <= 0) return NSNotFound;
	EnvRec *points = [self currentEnvelopePoints];
	NSInteger nearest = 0;
	NSInteger distance = labs(points[0].pos - position);
	for (NSInteger index = 1; index < count; index++) {
		NSInteger candidate = labs(points[index].pos - position);
		if (candidate < distance) { nearest = index; distance = candidate; }
	}
	return nearest;
}

- (void)updateEnvelopeControls
{
	BOOL envelopeMode = self.displayMode < 0;
	for (NSButton *button in self.envelopeButtons) button.hidden = !envelopeMode;
	if (!envelopeMode) return;
	EFType type = *[self currentEnvelopeTypePointer];
	self.envelopeButtons[0].state = (type & EFTypeOn) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
	self.envelopeButtons[1].state = (type & EFTypeNote) == 0 ? NSControlStateValueOn : NSControlStateValueOff;
	self.envelopeButtons[2].state = (type & EFTypeSustain) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
	self.envelopeButtons[3].state = (type & EFTypeLoop) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
}

- (IBAction)modeChanged:(NSPopUpButton *)sender
{
	[self stopPreview];
	NSInteger selectedMode = sender.selectedItem.tag;
	if (selectedMode >= 0) {
		InstrData *instrument = &self.music->fid[self.instrument];
		if (selectedMode >= instrument->numSamples) { NSBeep(); return; }
		self.sampleIndex = selectedMode;
	}
	self.displayMode = selectedMode;
	self.waveform.displayMode = self.displayMode;
	self.waveform.sample = self.sample;
	self.waveform.instrument = &self.music->fid[self.instrument];
	self.waveform.selectionStart = 0;
	self.waveform.selectionEnd = 0;
	[self.waveform showAll];
	self.scrollSlider.doubleValue = 0;
	[self updateEnvelopeControls];
	[self updateFields];
	[self.window makeFirstResponder:self.waveform];
}

- (void)toggleEnvelopeFlag:(EFType)flag actionName:(NSString *)actionName inverted:(BOOL)inverted
{
	if (self.displayMode >= 0) return;
	PPSampleSnapshot *before = [self snapshot];
	EFType *type = [self currentEnvelopeTypePointer];
	if ((*type & flag) != 0) *type &= ~flag; else *type |= flag;
	[self beginUndo:actionName snapshot:before];
	[self updateEnvelopeControls];
	[self didChange];
	(void)inverted;
}

- (IBAction)toggleEnvelope:(id)sender { (void)sender; [self toggleEnvelopeFlag:EFTypeOn actionName:@"Toggle Envelope" inverted:NO]; }
- (IBAction)toggleFixedSpeed:(id)sender { (void)sender; [self toggleEnvelopeFlag:EFTypeNote actionName:@"Toggle Fixed Envelope Speed" inverted:YES]; }
- (IBAction)toggleSustain:(id)sender { (void)sender; [self toggleEnvelopeFlag:EFTypeSustain actionName:@"Toggle Envelope Sustain" inverted:NO]; }
- (IBAction)toggleEnvelopeLoop:(id)sender { (void)sender; [self toggleEnvelopeFlag:EFTypeLoop actionName:@"Toggle Envelope Loop" inverted:NO]; }

- (void)setTool:(PPSampleTool)tool
{
	self.waveform.tool = tool;
	for (NSInteger index = 0; index < self.toolButtons.count; index++) {
		self.toolButtons[index].state = index == tool ? NSControlStateValueOn : NSControlStateValueOff;
	}
	[self.window makeFirstResponder:self.waveform];
}

- (IBAction)selectTool:(id)sender { (void)sender; [self setTool:PPSampleToolSelect]; }
- (IBAction)pencilTool:(id)sender { (void)sender; [self setTool:PPSampleToolPencil]; }
- (IBAction)zoomTool:(id)sender { (void)sender; [self setTool:PPSampleToolZoom]; }

- (IBAction)scrollWaveform:(NSSlider *)sender
{
	NSInteger contentLength = self.displayMode < 0 ? PPEnvelopeLength : self.sample->size;
	NSInteger available = MAX(contentLength - self.waveform.visibleLength, 0);
	self.waveform.visibleStart = (NSInteger)llround(sender.doubleValue * available);
	[self.waveform setNeedsDisplay:YES];
	[self updateFields];
}

- (IBAction)effectChosen:(NSMenuItem *)sender
{
	if ([sender.title isEqualToString:@"Selection → Loop"]) [self selectionToLoop:sender];
	else if ([sender.title isEqualToString:@"Loop → Selection"]) [self loopToSelection:sender];
	else if ([sender.title isEqualToString:@"Set Sustain Point"]) [self setSustainPoint:sender];
	else if ([sender.title isEqualToString:@"Delete"]) [self delete:sender];
	else if ([sender.title isEqualToString:@"FFT - Hz Filter…"]) [self frequencyFilter:sender];
	else if ([sender.title isEqualToString:@"FFT - Hz Shift…"]) [self frequencyShift:sender];
	else if ([sender.title isEqualToString:@"Addotroph…"]) [self addotroph:sender];
	else if ([sender.title isEqualToString:@"Aderodhiecus"]) [self aderodhiecus:sender];
	else if ([sender.title isEqualToString:@"Amplitude…"]) [self amplitude:sender];
	else if ([sender.title isEqualToString:@"Backwards"]) [self reverse:sender];
	else if ([sender.title isEqualToString:@"Better Fade…"]) [self betterFade:sender];
	else if ([sender.title isEqualToString:@"Bit Depth…"]) [self bitDepth:sender];
	else if ([sender.title isEqualToString:@"Convolve…"]) [self convolve:sender];
	else if ([sender.title isEqualToString:@"Crop"]) [self crop:sender];
	else if ([sender.title isEqualToString:@"CrossFade"]) [self crossfade:sender];
	else if ([sender.title isEqualToString:@"DC - Circular"]) [self removeDCCircular:sender];
	else if ([sender.title isEqualToString:@"DC - Linear"]) [self removeDCLinear:sender];
	else if ([sender.title isEqualToString:@"Echo…"]) [self echo:sender];
	else if ([sender.title isEqualToString:@"EnvTest"]) [self envelopeTest:sender];
	else if ([sender.title isEqualToString:@"EQ-3…"]) [self eq3:sender];
	else if ([sender.title isEqualToString:@"Fade…"]) [self fade:sender];
	else if ([sender.title isEqualToString:@"Fingawalix"]) [self fingawalix:sender];
	else if ([sender.title isEqualToString:@"IIR Filter…"]) [self iirFilter:sender];
	else if ([sender.title isEqualToString:@"Normalize"]) [self normalize:sender];
	else if ([sender.title isEqualToString:@"Invert"]) [self invert:sender];
	else if ([sender.title isEqualToString:@"Length…"]) [self changeLength:sender];
	else if ([sender.title isEqualToString:@"Memphif"]) [self memphif:sender];
	else if ([sender.title isEqualToString:@"Mix…"]) [self mix:sender];
	else if ([sender.title isEqualToString:@"Noooiise…"]) [self noise:sender];
	else if ([sender.title isEqualToString:@"RingModulate…"]) [self ringModulate:sender];
	else if ([sender.title isEqualToString:@"Sampling Rate…"]) [self changeSamplingRate:sender];
	else if ([sender.title isEqualToString:@"Saturator…"]) [self saturator:sender];
	else if ([sender.title isEqualToString:@"Silence"]) [self silence:sender];
	else if ([sender.title isEqualToString:@"Smooth"]) [self smooth:sender];
	else if ([sender.title isEqualToString:@"Stardust…"]) [self stardust:sender];
	else if ([sender.title isEqualToString:@"Tone Generator…"]) [self toneGenerator:sender];
	else if ([sender.title isEqualToString:@"Freeverb"]) [self freeverb:sender];
}

- (IBAction)selectionToLoop:(id)sender
{
	(void)sender;
	NSRange range = [self selectionRangeAllowWholeSample:NO];
	if (range.location == NSNotFound || range.length == 0) { NSBeep(); return; }
	PPSampleSnapshot *before = [self snapshot];
	if (self.displayMode < 0) {
		NSInteger count = [self currentEnvelopeSize];
		if (count <= 0) { NSBeep(); return; }
		EnvRec *points = [self currentEnvelopePoints];
		NSInteger begin = [self nearestEnvelopePointToPosition:(NSInteger)range.location];
		NSInteger end = [self nearestEnvelopePointToPosition:(NSInteger)NSMaxRange(range)];
		*[self currentEnvelopeLoopBeginPointer] = (MADByte)MIN(begin, end);
		*[self currentEnvelopeLoopEndPointer] = (MADByte)MAX(begin, end);
		*[self currentEnvelopeTypePointer] |= EFTypeLoop;
		[self beginUndo:@"Set Envelope Loop from Selection" snapshot:before];
		[self updateEnvelopeControls];
		[self didChange];
		return;
	}
	[self beginUndo:@"Set Loop from Selection" snapshot:before];
	self.sample->loopBeg = (int)range.location;
	self.sample->loopSize = (int)range.length;
	[self didChange];
}

- (IBAction)loopToSelection:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) {
		EFType type = *[self currentEnvelopeTypePointer];
		NSInteger count = [self currentEnvelopeSize];
		if ((type & EFTypeLoop) == 0 || count <= 0) { NSBeep(); return; }
		EnvRec *points = [self currentEnvelopePoints];
		NSInteger begin = MIN(*[self currentEnvelopeLoopBeginPointer], count - 1);
		NSInteger end = MIN(*[self currentEnvelopeLoopEndPointer], count - 1);
		self.waveform.selectionStart = points[MIN(begin, end)].pos;
		self.waveform.selectionEnd = MIN(points[MAX(begin, end)].pos + 2, PPEnvelopeLength);
		[self waveformSelectionDidChange:self.waveform];
		return;
	}
	if (self.sample->loopSize <= 0) { NSBeep(); return; }
	self.waveform.selectionStart = self.sample->loopBeg;
	self.waveform.selectionEnd = self.sample->loopBeg + self.sample->loopSize;
	[self waveformSelectionDidChange:self.waveform];
}

- (IBAction)setSustainPoint:(id)sender
{
	(void)sender;
	if (self.displayMode >= 0 || [self currentEnvelopeSize] == 0) { NSBeep(); return; }
	PPSampleSnapshot *before = [self snapshot];
	NSInteger index = [self nearestEnvelopePointToPosition:MIN(self.waveform.selectionStart, self.waveform.selectionEnd)];
	*[self currentEnvelopeSustainPointer] = (MADByte)index;
	*[self currentEnvelopeTypePointer] |= EFTypeSustain;
	[self beginUndo:@"Set Envelope Sustain Point" snapshot:before];
	[self updateEnvelopeControls];
	[self didChange];
}

- (void)copy:(id)sender
{
	(void)sender;
	NSRange range = [self selectionRangeAllowWholeSample:NO];
	if (range.location == NSNotFound || range.length == 0) { NSBeep(); return; }
	if (self.displayMode < 0) {
		EnvRec *points = [self currentEnvelopePoints];
		NSInteger count = [self currentEnvelopeSize];
		NSMutableData *records = [NSMutableData data];
		for (NSInteger index = 0; index < count; index++) {
			if (points[index].pos >= (NSInteger)range.location && points[index].pos <= (NSInteger)NSMaxRange(range)) {
				EnvRec record = points[index];
				record.pos -= (short)range.location;
				[records appendBytes:&record length:sizeof(record)];
			}
		}
		PPEnvelopeClipboardHeader header = {.magic = 'PENV', .kind = (int16_t)self.displayMode,
			.count = (uint16_t)(records.length / sizeof(EnvRec)), .span = (uint16_t)MIN(range.length, UINT16_MAX)};
		if (header.count == 0) { NSBeep(); return; }
		NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
		[data appendData:records];
		[NSPasteboard.generalPasteboard clearContents];
		[NSPasteboard.generalPasteboard setData:data forType:PPEnvelopePasteboardType];
		return;
	}
	PPSampleClipboardHeader header = {
		.magic = 'PPCM', .version = 1, .amplitude = self.sample->amp,
		.channels = self.sample->stereo ? 2 : 1, .sampleRate = self.sample->c2spd,
		.byteCount = (uint32_t)range.length
	};
	NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
	[data appendBytes:self.sample->data + range.location length:range.length];
	NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
	[pasteboard clearContents];
	[pasteboard setData:data forType:PPSamplePasteboardType];
}

- (void)cut:(id)sender
{
	[self copy:sender];
	[self delete:sender];
}

- (void)paste:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) {
		NSData *data = [NSPasteboard.generalPasteboard dataForType:PPEnvelopePasteboardType];
		if (data.length < sizeof(PPEnvelopeClipboardHeader)) { NSBeep(); return; }
		PPEnvelopeClipboardHeader header;
		[data getBytes:&header length:sizeof(header)];
		if (header.magic != 'PENV' || header.kind != self.displayMode ||
			data.length != sizeof(header) + header.count * sizeof(EnvRec)) { NSBeep(); return; }
		PPSampleSnapshot *before = [self snapshot];
		NSRange selection = [self selectionRangeAllowWholeSample:NO];
		NSInteger insertionPosition = selection.location == NSNotFound ? 0 : (NSInteger)selection.location;
		if (selection.length > 0) {
			EnvRec *existing = [self currentEnvelopePoints];
			for (NSInteger index = [self currentEnvelopeSize] - 1; index >= 0; index--) {
				if (existing[index].pos >= (NSInteger)selection.location && existing[index].pos <= (NSInteger)NSMaxRange(selection))
					[self.waveform deleteEnvelopePointAtIndex:index];
			}
		}
		const EnvRec *records = (const EnvRec *)((const uint8_t *)data.bytes + sizeof(header));
		for (NSInteger recordIndex = 0; recordIndex < header.count && [self currentEnvelopeSize] < 12; recordIndex++) {
			EnvRec *points = [self currentEnvelopePoints];
			MADByte *sizePointer = self.displayMode == PPVolumeEnvelopeMode ? &self.music->fid[self.instrument].volSize
				: &self.music->fid[self.instrument].pannSize;
			EnvRec record = records[recordIndex];
			record.pos = (short)MIN(insertionPosition + record.pos, PPEnvelopeLength);
			NSInteger insertion = 0;
			while (insertion < *sizePointer && points[insertion].pos < record.pos) insertion++;
			for (NSInteger cursor = *sizePointer; cursor > insertion; cursor--) points[cursor] = points[cursor - 1];
			[self.waveform adjustEnvelopeMarkersForInsertAtIndex:insertion];
			points[insertion] = record;
			(*sizePointer)++;
		}
		*[self currentEnvelopeTypePointer] |= EFTypeOn;
		[self beginUndo:@"Paste Envelope" snapshot:before];
		self.waveform.selectionStart = insertionPosition;
		self.waveform.selectionEnd = MIN(insertionPosition + header.span, PPEnvelopeLength);
		[self updateEnvelopeControls];
		[self didChange];
		return;
	}
	NSData *data = [NSPasteboard.generalPasteboard dataForType:PPSamplePasteboardType];
	if (data.length < sizeof(PPSampleClipboardHeader)) { NSBeep(); return; }
	PPSampleClipboardHeader header;
	[data getBytes:&header length:sizeof(header)];
	if (header.magic != 'PPCM' || header.version != 1 || data.length != sizeof(header) + header.byteCount ||
		header.amplitude != self.sample->amp || header.channels != (self.sample->stereo ? 2 : 1)) {
		NSBeep();
		return;
	}
	[self stopPreview];
	PPSampleSnapshot *before = [self snapshot];
	NSRange range = [self selectionRangeAllowWholeSample:NO];
	size_t offset = range.location == NSNotFound ? 0 : range.location;
	if (range.length > 0 && !PPDeleteBytes(self.sample, range.location, NSMaxRange(range))) return;
	if (!PPInsertBytes(self.sample, offset, (const char *)data.bytes + sizeof(header), header.byteCount)) return;
	[self beginUndo:@"Paste Sample" snapshot:before];
	self.waveform.selectionStart = (NSInteger)offset;
	self.waveform.selectionEnd = (NSInteger)(offset + header.byteCount);
	[self.waveform showAll];
	[self didChange];
}

- (void)delete:(id)sender
{
	(void)sender;
	NSRange range = [self selectionRangeAllowWholeSample:NO];
	if (range.location == NSNotFound || range.length == 0) { NSBeep(); return; }
	if (self.displayMode < 0) {
		PPSampleSnapshot *before = [self snapshot];
		EnvRec *points = [self currentEnvelopePoints];
		for (NSInteger index = [self currentEnvelopeSize] - 1; index >= 0; index--) {
			if (points[index].pos >= (NSInteger)range.location && points[index].pos <= (NSInteger)NSMaxRange(range))
				[self.waveform deleteEnvelopePointAtIndex:index];
		}
		[self beginUndo:@"Delete Envelope Points" snapshot:before];
		self.waveform.selectionStart = (NSInteger)range.location;
		self.waveform.selectionEnd = (NSInteger)range.location;
		[self updateEnvelopeControls];
		[self didChange];
		return;
	}
	[self stopPreview];
	PPSampleSnapshot *before = [self snapshot];
	if (!PPDeleteBytes(self.sample, range.location, NSMaxRange(range))) return;
	[self beginUndo:@"Delete Sample Selection" snapshot:before];
	self.waveform.selectionStart = (NSInteger)range.location;
	self.waveform.selectionEnd = (NSInteger)range.location;
	[self.waveform showAll];
	[self didChange];
}

- (IBAction)crop:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSRange range = [self selectionRangeAllowWholeSample:NO];
	if (range.location == NSNotFound || range.length == 0) { NSBeep(); return; }
	[self presentSimpleFilterNamed:@"Crop" actionName:@"Crop Sample"
		operation:^BOOL(sData *sample, size_t start, size_t end) { return PPCropBytes(sample, start, end); }];
}

- (IBAction)reverse:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Backwards" actionName:@"Reverse Sample"
		operation:^BOOL(sData *sample, size_t start, size_t end) { return PPReverseBytes(sample, start, end); }];
}

- (IBAction)normalize:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Normalize" actionName:@"Normalize Sample"
		operation:^BOOL(sData *sample, size_t start, size_t end) { return PPNormalizeBytes(sample, start, end); }];
}

- (BOOL)applySampleFilterNamed:(NSString *)name operation:(BOOL (^)(sData *, size_t, size_t))operation
{
	if (self.displayMode < 0 || operation == nil) { NSBeep(); return NO; }
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length == 0) { NSBeep(); return NO; }
	[self stopPreview];
	PPSampleSnapshot *before = [self snapshot];
	if (!operation(self.sample, range.location, NSMaxRange(range))) { NSBeep(); return NO; }
	[self beginUndo:name snapshot:before];
	if (self.sample->size != before.size) {
		self.waveform.selectionStart = 0;
		self.waveform.selectionEnd = self.sample->size;
		[self.waveform showAll];
	}
	[self didChange];
	return YES;
}

- (NSTextField *)filterFieldWithString:(NSString *)value
{
	NSTextField *field = [NSTextField textFieldWithString:value ?: @""];
	field.font = [self classicFont];
	field.alignment = NSTextAlignmentRight;
	field.textColor = NSColor.blackColor;
	field.backgroundColor = NSColor.whiteColor;
	return field;
}

- (NSView *)filterFormWithLabels:(NSArray<NSString *> *)labels values:(NSArray<NSString *> *)values
	fields:(NSArray<NSTextField *> * __autoreleasing *)fieldsOut
{
	CGFloat rowHeight = 28.0;
	NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 310, rowHeight * labels.count)];
	NSMutableArray<NSTextField *> *fields = [NSMutableArray arrayWithCapacity:labels.count];
	for (NSInteger row = 0; row < (NSInteger)labels.count; row++) {
		CGFloat y = rowHeight * (labels.count - row - 1);
		NSTextField *label = [NSTextField labelWithString:labels[row]];
		label.frame = NSMakeRect(0, y + 4, 190, 18);
		label.font = [self classicFont];
		label.textColor = NSColor.blackColor;
		[view addSubview:label];
		NSTextField *field = [self filterFieldWithString:row < (NSInteger)values.count ? values[row] : @""];
		field.frame = NSMakeRect(198, y + 1, 92, 22);
		[view addSubview:field];
		[fields addObject:field];
	}
	if (fieldsOut != NULL) *fieldsOut = fields.copy;
	return view;
}

- (BOOL)integerFromField:(NSTextField *)field minimum:(NSInteger)minimum maximum:(NSInteger)maximum value:(NSInteger *)value
{
	NSScanner *scanner = [NSScanner scannerWithString:field.stringValue];
	scanner.charactersToBeSkipped = nil;
	NSInteger parsed = 0;
	if (![scanner scanInteger:&parsed] || !scanner.isAtEnd || parsed < minimum || parsed > maximum) {
		NSBeep(); [self.window makeFirstResponder:field]; return NO;
	}
	if (value != NULL) *value = parsed;
	return YES;
}

- (BOOL)doubleFromField:(NSTextField *)field minimum:(double)minimum maximum:(double)maximum value:(double *)value
{
	NSScanner *scanner = [NSScanner scannerWithString:field.stringValue];
	scanner.charactersToBeSkipped = nil;
	double parsed = 0.0;
	if (![scanner scanDouble:&parsed] || !scanner.isAtEnd || !isfinite(parsed) || parsed < minimum || parsed > maximum) {
		NSBeep(); [self.window makeFirstResponder:field]; return NO;
	}
	if (value != NULL) *value = parsed;
	return YES;
}

- (BOOL)previewFilterOperation:(BOOL (^)(sData *, size_t, size_t))operation
{
	if (self.driver == NULL || self.sample == NULL || operation == nil) { NSBeep(); return NO; }
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length == 0) { NSBeep(); return NO; }
	sData preview = *self.sample;
	preview.data = malloc((size_t)preview.size);
	if (preview.data == NULL) { NSBeep(); return NO; }
	memcpy(preview.data, self.sample->data, (size_t)preview.size);
	if (!operation(&preview, range.location, NSMaxRange(range)) || preview.data == NULL || preview.size < 4) {
		free(preview.data); NSBeep(); return NO;
	}
	NSData *audio = [NSData dataWithBytes:preview.data length:(NSUInteger)preview.size];
	free(preview.data);
	[self stopPreview];
	self.filterPreviewData = audio;
	NSInteger note = MIN(MAX(48 + preview.realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(self.driver, audio.bytes, audio.length, 0, (MADByte)note, preview.amp,
		0, 0, preview.c2spd, preview.stereo);
	if (error != MADNoErr) { NSBeep(); return NO; }
	return YES;
}

- (void)runFilterAlert:(NSAlert *)alert actionName:(NSString *)actionName
	operation:(BOOL (^)(sData *, size_t, size_t))operation
{
	__weak typeof(self) weakSelf = self;
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
		__strong typeof(weakSelf) self = weakSelf;
		if (self == nil) return;
		if (response != NSAlertFirstButtonReturn && response != NSAlertSecondButtonReturn) {
			[self stopPreview]; return;
		}
		BOOL succeeded = response == NSAlertSecondButtonReturn
			? [self previewFilterOperation:operation]
			: [self applySampleFilterNamed:actionName operation:operation];
		if (response == NSAlertSecondButtonReturn || !succeeded) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self runFilterAlert:alert actionName:actionName operation:operation]; });
		}
	}];
}

- (void)presentFilterAlert:(NSAlert *)alert actionName:(NSString *)actionName
	operation:(BOOL (^)(sData *, size_t, size_t))operation
{
	// Add the buttons before reading alert.buttons. NSAlert owns an implicit OK
	// button until the first explicit button is added; renaming that implicit
	// button and then adding another causes AppKit to discard the renamed one.
	[alert addButtonWithTitle:@"Apply"];
	[alert addButtonWithTitle:@"Preview"];
	[alert addButtonWithTitle:@"Cancel"];
	[self runFilterAlert:alert actionName:actionName operation:operation];
}

- (void)presentSimpleFilterNamed:(NSString *)title actionName:(NSString *)actionName
	operation:(BOOL (^)(sData *, size_t, size_t))operation
{
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = title;
	[self presentFilterAlert:alert actionName:actionName operation:operation];
}

- (IBAction)invert:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Invert" actionName:@"Invert Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPInvertBytes(sample, start, end);
	}];
}

- (IBAction)silence:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Silence" actionName:@"Silence Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPSilenceBytes(sample, start, end);
	}];
}

- (IBAction)fadeIn:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Fade In" actionName:@"Fade In Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPFadeBytes(sample, start, end, YES);
	}];
}

- (IBAction)fadeOut:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Fade Out" actionName:@"Fade Out Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPFadeBytes(sample, start, end, NO);
	}];
}

- (IBAction)smooth:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"Smooth" actionName:@"Smooth Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPSmoothBytes(sample, start, end);
	}];
}

- (IBAction)removeDCLinear:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"DC - Linear" actionName:@"Remove Linear DC Offset"
		operation:^BOOL(sData *sample, size_t start, size_t end) {
			return PPRemoveDCLinearBytes(sample, start, end);
		}];
}

- (IBAction)removeDCCircular:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"DC - Circular" actionName:@"Remove Circular DC Offset"
		operation:^BOOL(sData *sample, size_t start, size_t end) {
			return PPRemoveDCCircularBytes(sample, start, end);
		}];
}

- (IBAction)convolve:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL) { NSBeep(); return; }
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < PPBytesPerFrame(self.sample)) { NSBeep(); return; }
	PPConvolveDialogController *controller = [[PPConvolveDialogController alloc] init];
	[controller.window center];
	[self.window addChildWindow:controller.window ordered:NSWindowAbove];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[self.window removeChildWindow:controller.window];
	[controller.window orderOut:nil];
	if (response != NSModalResponseOK) return;
	PPConvolveParameters parameters = controller.parameters;
	double nyquist = MAX((double)self.sample->c2spd * 0.5, 1.0);
	if (parameters.impulseMode != PPConvolveImpulseSelection &&
		(parameters.cutoffHertz < 1 || (double)parameters.cutoffHertz >= nyquist)) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = @"The cutoff frequency is too high";
		alert.informativeText = @"The cutoff must be below half of the sample rate.";
		[alert runModal];
		return;
	}
	if ([self applySampleFilterNamed:@"Convolve Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPConvolveBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentConvolveParameters() = parameters;
	}
}

- (IBAction)frequencyFilter:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL ||
		self.sample->size < 4) { NSBeep(); return; }
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < PPBytesPerFrame(self.sample)) { NSBeep(); return; }
	PPSampleSnapshot *original = [self snapshot];
	double *gains = PPPersistentHzFilterGains();
	BOOL (^operation)(sData *, size_t, size_t) = ^BOOL(sData *sample, size_t start, size_t end) {
		return PPFrequencyCurveFilterBytes(sample, start, end, gains, PPHzFilterPointCount);
	};

	void (^restoreOriginal)(void) = ^{
		if (self.sample == NULL) return;
		if (!PPReplaceBytes(self.sample, original.data.bytes, original.data.length)) { NSBeep(); return; }
		[self.waveform setNeedsDisplay:YES];
	};
	void (^updateVisiblePreview)(void) = ^{
		[self stopPreview];
		self.filterPreviewData = nil;
		restoreOriginal();
		if (PPHzFilterPreviewEnabled &&
			!operation(self.sample, range.location, NSMaxRange(range))) NSBeep();
		[self.waveform setNeedsDisplay:YES];
	};
	void (^playFilteredSample)(void) = ^{
		if (self.driver == NULL || self.sample == NULL) { NSBeep(); return; }
		[self stopPreview];
		self.filterPreviewData = nil;
		sData preview = *self.sample;
		preview.size = original.size;
		preview.data = malloc(original.data.length);
		if (preview.data == NULL) { NSBeep(); return; }
		memcpy(preview.data, original.data.bytes, original.data.length);
		if (!operation(&preview, range.location, NSMaxRange(range)) || preview.size < 4) {
			free(preview.data); NSBeep(); return;
		}
		self.filterPreviewData = [NSData dataWithBytesNoCopy:preview.data
			length:(NSUInteger)preview.size freeWhenDone:YES];
		NSInteger note = MIN(MAX(48 + preview.realNote, 0), NUMBER_NOTES - 1);
		MADErr error = MADPlaySoundData(self.driver, self.filterPreviewData.bytes,
			self.filterPreviewData.length, 0, (MADByte)note, preview.amp, 0, 0,
			preview.c2spd, preview.stereo);
		if (error != MADNoErr) { self.filterPreviewData = nil; NSBeep(); }
	};

	PPHzFilterDialogController *controller = [[PPHzFilterDialogController alloc] init];
	controller.curveChangedHandler = updateVisiblePreview;
	controller.previewChangedHandler = ^(BOOL enabled) { (void)enabled; updateVisiblePreview(); };
	controller.playHandler = playFilteredSample;
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[controller.window makeKeyAndOrderFront:nil];
	[controller.window makeFirstResponder:controller.curveView];
	updateVisiblePreview();
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[controller.window orderOut:nil];
	[self stopPreview];
	self.filterPreviewData = nil;
	restoreOriginal();
	if (response == NSModalResponseOK) {
		[self applySampleFilterNamed:@"Filter Sample by Frequency" operation:operation];
	}
}

- (IBAction)frequencyShift:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL ||
		self.sample->size < 4) { NSBeep(); return; }
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < PPBytesPerFrame(self.sample) * 2) {
		NSBeep(); return;
	}
	PPSampleSnapshot *original = [self snapshot];
	double *destinations = PPPersistentHzShiftDestinations();
	BOOL (^operation)(sData *, size_t, size_t) = ^BOOL(sData *sample, size_t start, size_t end) {
		return PPFrequencyMapShiftBytes(sample, start, end, destinations,
			PPHzFilterPointCount, PPHzFilterLogarithmic);
	};

	void (^restoreOriginal)(void) = ^{
		if (self.sample == NULL) return;
		if (!PPReplaceBytes(self.sample, original.data.bytes, original.data.length)) { NSBeep(); return; }
		[self.waveform setNeedsDisplay:YES];
	};
	void (^updateVisiblePreview)(void) = ^{
		[self stopPreview];
		self.filterPreviewData = nil;
		restoreOriginal();
		if (PPHzFilterPreviewEnabled &&
			!operation(self.sample, range.location, NSMaxRange(range))) NSBeep();
		[self.waveform setNeedsDisplay:YES];
	};
	void (^playShiftedSample)(void) = ^{
		if (self.driver == NULL || self.sample == NULL) { NSBeep(); return; }
		[self stopPreview];
		self.filterPreviewData = nil;
		sData preview = *self.sample;
		preview.size = original.size;
		preview.data = malloc(original.data.length);
		if (preview.data == NULL) { NSBeep(); return; }
		memcpy(preview.data, original.data.bytes, original.data.length);
		if (!operation(&preview, range.location, NSMaxRange(range)) || preview.size < 4) {
			free(preview.data); NSBeep(); return;
		}
		self.filterPreviewData = [NSData dataWithBytesNoCopy:preview.data
			length:(NSUInteger)preview.size freeWhenDone:YES];
		NSInteger note = MIN(MAX(48 + preview.realNote, 0), NUMBER_NOTES - 1);
		MADErr error = MADPlaySoundData(self.driver, self.filterPreviewData.bytes,
			self.filterPreviewData.length, 0, (MADByte)note, preview.amp, 0, 0,
			preview.c2spd, preview.stereo);
		if (error != MADNoErr) { self.filterPreviewData = nil; NSBeep(); }
	};

	PPHzShiftDialogController *controller = [[PPHzShiftDialogController alloc] init];
	controller.curveChangedHandler = updateVisiblePreview;
	controller.previewChangedHandler = ^(BOOL enabled) { (void)enabled; updateVisiblePreview(); };
	controller.playHandler = playShiftedSample;
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[controller.window makeKeyAndOrderFront:nil];
	[controller.window makeFirstResponder:controller.curveView];
	updateVisiblePreview();
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[controller.window orderOut:nil];
	[self stopPreview];
	self.filterPreviewData = nil;
	restoreOriginal();
	if (response == NSModalResponseOK) {
		[self applySampleFilterNamed:@"Shift Sample Frequencies" operation:operation];
	}
}

- (IBAction)iirFilter:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL) {
		NSBeep(); return;
	}
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < PPBytesPerFrame(self.sample)) {
		NSBeep(); return;
	}
	PPIIRFilterDialogController *controller = [[PPIIRFilterDialogController alloc] init];
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[self.window addChildWindow:controller.window ordered:NSWindowAbove];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[self.window removeChildWindow:controller.window];
	[controller.window orderOut:nil];
	if (response != NSModalResponseOK) return;
	PPIIRFilterParameters parameters = controller.parameters;
	if ([self applySampleFilterNamed:@"Apply IIR Filter" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPIIRFilterBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentIIRFilterParameters() = parameters;
	}
}

- (IBAction)noise:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL) {
		NSBeep(); return;
	}
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < (self.sample->amp == 16 ? 2 : 1)) {
		NSBeep(); return;
	}
	PPNoiseDialogController *controller = [[PPNoiseDialogController alloc] init];
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[self.window addChildWindow:controller.window ordered:NSWindowAbove];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[self.window removeChildWindow:controller.window];
	[controller.window orderOut:nil];
	if (response != NSModalResponseOK) return;
	PPNoiseParameters parameters = controller.parameters;
	if ([self applySampleFilterNamed:@"Apply Noooiise" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPNoiseBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentNoiseParameters() = parameters;
	}
}

- (IBAction)ringModulate:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL) {
		NSBeep(); return;
	}
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < PPBytesPerFrame(self.sample)) {
		NSBeep(); return;
	}
	PPRingModulateDialogController *controller = [[PPRingModulateDialogController alloc] init];
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[self.window addChildWindow:controller.window ordered:NSWindowAbove];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[self.window removeChildWindow:controller.window];
	[controller.window orderOut:nil];
	if (response != NSModalResponseOK) return;
	PPRingModulateParameters parameters = controller.parameters;
	if ([self applySampleFilterNamed:@"Apply RingModulate" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPRingModulateBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentRingModulateParameters() = parameters;
	}
}

- (IBAction)stardust:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL) {
		NSBeep(); return;
	}
	NSRange range = [self selectionRangeAllowWholeSample:YES];
	if (range.location == NSNotFound || range.length < PPBytesPerFrame(self.sample)) {
		NSBeep(); return;
	}
	PPStardustDialogController *controller = [[PPStardustDialogController alloc] init];
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[self.window addChildWindow:controller.window ordered:NSWindowAbove];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[self.window removeChildWindow:controller.window];
	[controller.window orderOut:nil];
	if (response != NSModalResponseOK) return;
	PPStardustParameters parameters = controller.parameters;
	if ([self applySampleFilterNamed:@"Apply Stardust" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPStardustBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentStardustParameters() = parameters;
	}
}

- (IBAction)addotroph:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL ||
		self.sample->size < 1) { NSBeep(); return; }
	PPAddotrophDialogController *controller = [[PPAddotrophDialogController alloc] init];
	__weak typeof(self) weakSelf = self;
	__weak PPAddotrophDialogController *weakController = controller;
	controller.previewHandler = ^{
		__strong typeof(weakSelf) self = weakSelf;
		PPAddotrophDialogController *controller = weakController;
		if (self == nil || controller == nil) return;
		PPAddotrophParameters parameters = controller.parameters;
		if (!PPAddotrophParametersAreValid(parameters, MAX((double)self.sample->c2spd, 1.0))) {
			NSBeep(); return;
		}
		[self previewFilterOperation:^BOOL(sData *sample, size_t start, size_t end) {
			return PPAddotrophBytes(sample, start, end, parameters);
		}];
	};
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[controller.window makeKeyAndOrderFront:nil];
	[controller.window makeFirstResponder:controller.noteModeButton.state == NSControlStateValueOn ?
		controller.octaveField : controller.frequencyField];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[controller.window orderOut:nil];
	[self stopPreview];
	if (response != NSModalResponseOK) return;
	PPAddotrophParameters parameters = controller.parameters;
	if (!PPAddotrophParametersAreValid(parameters, MAX((double)self.sample->c2spd, 1.0))) {
		NSBeep(); return;
	}
	if ([self applySampleFilterNamed:@"Apply Addotroph" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPAddotrophBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentAddotrophParameters() = parameters;
	}
}

- (IBAction)aderodhiecus:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL ||
		self.sample->size < 1) { NSBeep(); return; }
	PPAderodhiecusDialogController *controller = [[PPAderodhiecusDialogController alloc] init];
	__weak typeof(self) weakSelf = self;
	__weak PPAderodhiecusDialogController *weakController = controller;
	controller.previewHandler = ^{
		__strong typeof(weakSelf) self = weakSelf;
		PPAderodhiecusDialogController *controller = weakController;
		if (self == nil || controller == nil) return;
		PPAderodhiecusParameters parameters = controller.parameters;
		if (!PPAderodhiecusParametersAreValid(parameters)) { NSBeep(); return; }
		[self previewFilterOperation:^BOOL(sData *sample, size_t start, size_t end) {
			return PPAderodhiecusBytes(sample, start, end, parameters);
		}];
	};
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[controller.window makeKeyAndOrderFront:nil];
	[controller.window makeFirstResponder:controller.controlView];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[controller.window orderOut:nil];
	[self stopPreview];
	if (response != NSModalResponseOK) return;
	PPAderodhiecusParameters parameters = controller.parameters;
	if (!PPAderodhiecusParametersAreValid(parameters)) { NSBeep(); return; }
	if ([self applySampleFilterNamed:@"Apply Aderodhiecus" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPAderodhiecusBytes(sample, start, end, parameters);
	}]) {
		*PPPersistentAderodhiecusParameters() = parameters;
	}
}

- (IBAction)envelopeTest:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"EnvTest";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[@"Attack curve", @"Plateau width  (0–1)", @"Release curve"]
		values:@[@"1.2", @"0.1", @"0.7"] fields:&fields];
	[self presentFilterAlert:alert actionName:@"Apply EnvTest" operation:^BOOL(sData *sample, size_t start, size_t end) {
		double attack = 0.0, width = 0.0, release = 0.0;
		if (![self doubleFromField:fields[0] minimum:0 maximum:20 value:&attack] ||
			![self doubleFromField:fields[1] minimum:0 maximum:1 value:&width] ||
			![self doubleFromField:fields[2] minimum:0 maximum:20 value:&release]) return NO;
		return PPEnvelopeTestBytes(sample, start, end, attack, width, release);
	}];
}

- (IBAction)fingawalix:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	// Like the original plug-in (whose menu title has no ellipsis), this is an
	// immediate destructive generator rather than a parameter dialog. Undo is
	// the modern safety net.
	[self applySampleFilterNamed:@"Fingawalix Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPFingawalixBytes(sample, start, end);
	}];
}

- (IBAction)memphif:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	// The original menu item has no ellipsis and invokes the DSP immediately.
	// Undo is the modern safety net for this destructive operation.
	[self applySampleFilterNamed:@"Memphif Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPMemphifBytes(sample, start, end);
	}];
}

- (IBAction)amplitude:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Amplitude";
	alert.informativeText = @"Scale the selected audio, or the complete sample when there is no selection.";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[@"Amplitude:  %  (0–800)"] values:@[@"120"] fields:&fields];
	NSTextField *amplitudeField = fields[0];
	[self presentFilterAlert:alert actionName:@"Change Sample Amplitude" operation:^BOOL(sData *sample, size_t start, size_t end) {
		double percent = 0.0;
		if (![self doubleFromField:amplitudeField minimum:0 maximum:800 value:&percent]) return NO;
		return PPAmplifyBytes(sample, start, end, percent / 100.0);
	}];
}

- (IBAction)bitDepth:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSInteger nativeBits = self.sample->amp == 16 ? 16 : 8;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Bit Depth";
	alert.informativeText = @"Simulate a lower sample bit depth without changing the stored 8/16-bit format.";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[[NSString stringWithFormat:@"Simulate a bit depth of:  (1–%ld)",
		(long)nativeBits]] values:@[[NSString stringWithFormat:@"%ld", (long)MIN(nativeBits, 8)]] fields:&fields];
	NSTextField *bitsField = fields[0];
	[self presentFilterAlert:alert actionName:@"Change Sample Bit Depth" operation:^BOOL(sData *sample, size_t start, size_t end) {
		NSInteger bits = 0;
		if (![self integerFromField:bitsField minimum:1 maximum:nativeBits value:&bits]) return NO;
		return PPQuantizeDepthBytes(sample, start, end, bits);
	}];
}

- (IBAction)crossfade:(id)sender
{
	(void)sender;
	[self presentSimpleFilterNamed:@"CrossFade" actionName:@"CrossFade Sample Loop" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPCrossfadeBytes(sample, start, end);
	}];
}

- (IBAction)echo:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Echo";
	alert.informativeText = @"Apply the original in-place repeating echo to the selection.";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[@"Echo Delay:  milliseconds", @"Echo Strength:  %"]
		values:@[@"250", @"50"] fields:&fields];
	NSTextField *delayField = fields[0], *strengthField = fields[1];
	[self presentFilterAlert:alert actionName:@"Echo Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		double delay = 0.0, strength = 0.0;
		if (![self doubleFromField:delayField minimum:1 maximum:10000 value:&delay] ||
			![self doubleFromField:strengthField minimum:0 maximum:200 value:&strength]) return NO;
		return PPEchoBytes(sample, start, end, delay, strength);
	}];
}

- (IBAction)fade:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Fade";
	alert.informativeText = @"Linearly change amplitude across the selection.";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[@"Fade from:  %", @"Fade to:  %"]
		values:@[@"100", @"70"] fields:&fields];
	NSTextField *fromField = fields[0], *toField = fields[1];
	[self presentFilterAlert:alert actionName:@"Fade Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		double from = 0.0, to = 0.0;
		if (![self doubleFromField:fromField minimum:0 maximum:800 value:&from] ||
			![self doubleFromField:toField minimum:0 maximum:800 value:&to]) return NO;
		return PPFadePercentBytes(sample, start, end, from, to);
	}];
}

- (IBAction)betterFade:(id)sender
{
	(void)sender;
	if (self.displayMode < 0 || self.sample == NULL || self.sample->data == NULL ||
		self.sample->size < 1) { NSBeep(); return; }
	PPBetterFadeDialogController *controller = [[PPBetterFadeDialogController alloc] init];
	__weak typeof(self) weakSelf = self;
	__weak PPBetterFadeDialogController *weakController = controller;
	controller.previewHandler = ^{
		__strong typeof(weakSelf) self = weakSelf;
		PPBetterFadeDialogController *controller = weakController;
		if (self == nil || controller == nil) return;
		PPBetterFadeParameters parameters = controller.effectiveParameters;
		[self previewFilterOperation:^BOOL(sData *sample, size_t start, size_t end) {
			return PPBetterFadePercentBytes(sample, start, end,
				parameters.fromPercent, parameters.toPercent);
		}];
	};
	NSRect parentFrame = self.window.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[controller.window makeKeyAndOrderFront:nil];
	[controller.window makeFirstResponder:controller.fromField];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[controller.window orderOut:nil];
	[self stopPreview];
	if (response != NSModalResponseOK) return;
	PPBetterFadeParameters storedParameters = controller.parameters;
	PPBetterFadeParameters parameters = PPBetterFadeEffectiveParameters(storedParameters);
	if ([self applySampleFilterNamed:@"Better Fade Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPBetterFadePercentBytes(sample, start, end,
			parameters.fromPercent, parameters.toPercent);
	}]) {
		*PPPersistentBetterFadeParameters() = storedParameters;
	}
}

- (IBAction)changeLength:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	size_t currentFrames = (size_t)self.sample->size / PPBytesPerFrame(self.sample);
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Change Length";
	alert.informativeText = @"Move/pad the waveform from either edge, or stretch it by resampling.";
	NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 112)];
	NSTextField *current = [NSTextField labelWithString:[NSString stringWithFormat:@"Current size:  %zu Samples  (%d Bytes)",
		currentFrames, self.sample->size]];
	current.frame = NSMakeRect(0, 88, 330, 18); current.font = [self classicFont]; [view addSubview:current];
	NSTextField *newLabel = [NSTextField labelWithString:@"New size (Samples):"];
	newLabel.frame = NSMakeRect(0, 61, 170, 18); newLabel.font = [self classicFont]; [view addSubview:newLabel];
	NSTextField *newField = [self filterFieldWithString:[NSString stringWithFormat:@"%zu", currentFrames]];
	newField.frame = NSMakeRect(180, 58, 110, 22); [view addSubview:newField];
	NSPopUpButton *mode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 29, 170, 24) pullsDown:NO];
	[mode addItemsWithTitles:@[@"Move to left", @"Move to right", @"Stretch"]];
	mode.font = [self classicFont]; [view addSubview:mode];
	NSButton *updateRate = [NSButton checkboxWithTitle:@"Update Sampling rate" target:nil action:nil];
	updateRate.frame = NSMakeRect(180, 31, 150, 20); updateRate.font = [self classicFont]; [view addSubview:updateRate];
	NSTextField *hint = [NSTextField labelWithString:@"Update Sampling rate applies to Stretch mode."];
	hint.frame = NSMakeRect(0, 3, 320, 18); hint.font = [self classicFont]; [view addSubview:hint];
	alert.accessoryView = view;
	[self presentFilterAlert:alert actionName:@"Change Sample Length" operation:^BOOL(sData *sample, size_t start, size_t end) {
		(void)start; (void)end;
		NSInteger frames = 0;
		if (![self integerFromField:newField minimum:1 maximum:20 * 1024 * 1024 value:&frames]) return NO;
		return PPChangeLengthFrames(sample, (size_t)frames, (PPSampleLengthMode)mode.indexOfSelectedItem,
			updateRate.state == NSControlStateValueOn);
	}];
}

- (IBAction)changeSamplingRate:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Change Sampling Rate";
	alert.informativeText = @"Resample the waveform and update c4spd while retaining its duration and pitch.";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[@"Current Sampling Rate:  Hz", @"New Sampling Rate:  Hz"]
		values:@[[NSString stringWithFormat:@"%u", self.sample->c2spd], [NSString stringWithFormat:@"%u", self.sample->c2spd]]
		fields:&fields];
	fields[0].editable = NO; fields[0].selectable = YES;
	NSTextField *newRateField = fields[1];
	[self presentFilterAlert:alert actionName:@"Change Sample Rate" operation:^BOOL(sData *sample, size_t start, size_t end) {
		(void)start; (void)end;
		NSInteger newRate = 0;
		if (![self integerFromField:newRateField minimum:2000 maximum:50000 value:&newRate]) return NO;
		return PPChangeSamplingRate(sample, (unsigned int)newRate);
	}];
}

- (IBAction)mix:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSData *clipboard = [NSPasteboard.generalPasteboard dataForType:PPSamplePasteboardType];
	if (clipboard.length < sizeof(PPSampleClipboardHeader)) { NSBeep(); return; }
	PPSampleClipboardHeader header;
	[clipboard getBytes:&header length:sizeof(header)];
	if (header.magic != 'PPCM' || header.version != 1 || clipboard.length != sizeof(header) + header.byteCount) {
		NSBeep(); return;
	}
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Mix";
	alert.informativeText = @"Mix the sample clipboard over this instrument beginning at the selection start, then normalize.";
	NSArray<NSTextField *> *fields = nil;
	alert.accessoryView = [self filterFormWithLabels:@[@"Instrument:  %", @"Clipboard:  %"]
		values:@[@"50", @"50"] fields:&fields];
	NSTextField *instrumentField = fields[0], *clipboardField = fields[1];
	[self presentFilterAlert:alert actionName:@"Mix Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		(void)end;
		double instrumentPercent = 0.0, clipboardPercent = 0.0;
		if (![self doubleFromField:instrumentField minimum:0 maximum:100 value:&instrumentPercent] ||
			![self doubleFromField:clipboardField minimum:0 maximum:100 value:&clipboardPercent]) return NO;
		return PPMixClipboard(sample, start, &header, (const uint8_t *)clipboard.bytes + sizeof(header),
			instrumentPercent, clipboardPercent);
	}];
}

- (IBAction)saturator:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Saturator";
	NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 58)];
	NSTextField *gainLabel = [NSTextField labelWithString:@"Gain:"];
	gainLabel.frame = NSMakeRect(0, 34, 48, 18); gainLabel.font = [self classicFont]; [view addSubview:gainLabel];
	PPSaturatorSlider *gain = [[PPSaturatorSlider alloc] initWithFrame:NSMakeRect(48, 29, 222, 24)];
	gain.minValue = 0.0; gain.maxValue = 10.0; gain.doubleValue = 1.0; gain.continuous = YES;
	gain.numberOfTickMarks = 0; gain.allowsTickMarkValuesOnly = NO;
	gain.target = self; gain.action = @selector(saturatorGainChanged:);
	gain.accessibilityLabel = @"Saturator gain";
	[view addSubview:gain];
	NSTextField *gainValue = [NSTextField labelWithString:@"1.00"];
	gainValue.frame = NSMakeRect(276, 34, 54, 18); gainValue.font = [self classicFont]; gainValue.alignment = NSTextAlignmentRight;
	gainValue.accessibilityLabel = @"Current gain";
	self.saturatorGainValue = gainValue;
	[view addSubview:gainValue];
	NSTextField *minimum = [NSTextField labelWithString:@"0"];
	minimum.frame = NSMakeRect(48, 5, 20, 18); minimum.font = [self classicFont]; [view addSubview:minimum];
	NSTextField *maximum = [NSTextField labelWithString:@"10"];
	maximum.frame = NSMakeRect(248, 5, 22, 18); maximum.font = [self classicFont]; maximum.alignment = NSTextAlignmentRight;
	[view addSubview:maximum];
	alert.accessoryView = view;
	[self presentFilterAlert:alert actionName:@"Saturate Sample" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPSaturateBytes(sample, start, end, gain.doubleValue);
	}];
}

- (IBAction)saturatorGainChanged:(NSSlider *)sender
{
	self.saturatorGainValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
	sender.accessibilityValueDescription = self.saturatorGainValue.stringValue;
}

- (IBAction)eq3:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"EQ-3";
	PPEQ3ControlView *controls = [[PPEQ3ControlView alloc] initWithFrame:NSMakeRect(0, 0, 360, 145)
		sampleRate:MAX((double)self.sample->c2spd, 1.0)];
	alert.accessoryView = controls;
	[self presentFilterAlert:alert actionName:@"Apply EQ-3" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPEQ3Bytes(sample, start, end, controls.lowGainDecibels,
			controls.midGainDecibels, controls.highGainDecibels,
			controls.lowCrossoverHertz, controls.highCrossoverHertz);
	}];
}

- (IBAction)freeverb:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Freeverb";
	PPFreeverbControlView *controls = [[PPFreeverbControlView alloc] initWithFrame:NSMakeRect(0, 0, 455, 190)];
	alert.accessoryView = controls;
	[self presentFilterAlert:alert actionName:@"Apply Freeverb" operation:^BOOL(sData *sample, size_t start, size_t end) {
		return PPFreeverbBytes(sample, start, end, controls.parameters);
	}];
}

- (IBAction)toneGenerator:(id)sender
{
	(void)sender;
	if (self.displayMode < 0) { NSBeep(); return; }
	NSRange selection = [self selectionRangeAllowWholeSample:YES];
	size_t defaultFrames = MAX(selection.length / PPBytesPerFrame(self.sample), 1);
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Tone Generator";
	alert.informativeText = @"Replace the selection with generated audio in the sample's current depth and channel mode.";
	NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 136)];
	NSArray<NSString *> *labels = @[@"Length:  Samples", @"Frequency:  Hz", @"Amplitude:  %"];
	NSArray<NSString *> *values = @[[NSString stringWithFormat:@"%zu", defaultFrames], @"440", @"100"];
	NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
	for (NSInteger row = 0; row < 3; row++) {
		CGFloat y = 106 - row * 28;
		NSTextField *label = [NSTextField labelWithString:labels[row]];
		label.frame = NSMakeRect(0, y + 4, 190, 18); label.font = [self classicFont]; [view addSubview:label];
		NSTextField *field = [self filterFieldWithString:values[row]];
		field.frame = NSMakeRect(198, y + 1, 92, 22); [view addSubview:field]; [fields addObject:field];
	}
	NSTextField *waveLabel = [NSTextField labelWithString:@"Wave type:"];
	waveLabel.frame = NSMakeRect(0, 8, 90, 18); waveLabel.font = [self classicFont]; [view addSubview:waveLabel];
	NSPopUpButton *waveform = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(95, 4, 195, 24) pullsDown:NO];
	[waveform addItemsWithTitles:@[@"Silence", @"Triangle", @"Square", @"Sine Wave"]]; waveform.font = [self classicFont];
	[view addSubview:waveform]; alert.accessoryView = view;
	[self presentFilterAlert:alert actionName:@"Generate Sample Tone" operation:^BOOL(sData *sample, size_t start, size_t end) {
		NSInteger frames = 0; double frequency = 0.0, amplitude = 0.0;
		if (![self integerFromField:fields[0] minimum:1 maximum:20 * 1024 * 1024 value:&frames] ||
			![self doubleFromField:fields[1] minimum:1 maximum:50000 value:&frequency] ||
			![self doubleFromField:fields[2] minimum:0 maximum:100 value:&amplitude]) return NO;
		return PPGenerateTone(sample, start, end, (size_t)frames, frequency, amplitude,
			(PPToneWaveform)waveform.indexOfSelectedItem);
	}];
}

- (void)selectAll:(id)sender
{
	(void)sender;
	self.waveform.selectionStart = 0;
	self.waveform.selectionEnd = self.displayMode < 0 ? PPEnvelopeLength : self.sample->size;
	[self waveformSelectionDidChange:self.waveform];
}

- (IBAction)previewAll:(id)sender
{
	(void)sender;
	[self waveform:self.waveform previewNote:48 selectionOnly:NO];
}

- (IBAction)previewSelection:(id)sender
{
	(void)sender;
	[self waveform:self.waveform previewNote:48 selectionOnly:YES];
}

- (IBAction)stopPreviewAction:(id)sender { (void)sender; [self stopPreview]; }

- (void)stopPreview
{
	if (self.driver != NULL) MADDriverClearChannel(self.driver, 0);
}

- (void)waveform:(PPSampleWaveformView *)view previewNote:(MADByte)note selectionOnly:(BOOL)selectionOnly
{
	(void)view;
	sData *sample = self.sample;
	if (self.displayMode < 0) {
		NSInteger mapped = self.music->fid[self.instrument].what[MIN((NSInteger)note, NUMBER_NOTES - 1)];
		if (mapped < 0 || mapped >= self.music->fid[self.instrument].numSamples) mapped = self.sampleIndex;
		sample = self.music->sample[self.music->fid[self.instrument].firstSample + mapped];
		selectionOnly = NO;
	}
	if (self.driver == NULL || sample == NULL || sample->data == NULL || sample->size < 4) { NSBeep(); return; }
	NSRange range = selectionOnly ? [self selectionRangeAllowWholeSample:YES] : NSMakeRange(0, (NSUInteger)sample->size);
	if (range.length < 4) { NSBeep(); return; }
	[self stopPreview];
	NSInteger playbackNote = MIN(MAX((NSInteger)note + sample->realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(self.driver, sample->data + range.location, range.length, 0, (MADByte)playbackNote,
		sample->amp, 0, 0, sample->c2spd, sample->stereo);
	if (error != MADNoErr) NSBeep();
}

- (void)waveformStopPreview:(PPSampleWaveformView *)view { (void)view; [self stopPreview]; }

- (void)waveformSelectionDidChange:(PPSampleWaveformView *)view
{
	(void)view;
	[self updateFields];
	[self.waveform setNeedsDisplay:YES];
}

- (void)waveformWillBeginPencilEdit:(PPSampleWaveformView *)view
{
	(void)view;
	[self stopPreview];
	self.pendingPencilSnapshot = [self snapshot];
}

- (void)waveformDidEditWithPencil:(PPSampleWaveformView *)view
{
	(void)view;
	if (self.pendingPencilSnapshot != nil) {
		[self beginUndo:@"Draw Sample" snapshot:self.pendingPencilSnapshot];
		self.pendingPencilSnapshot = nil;
	}
	[self didChange];
}

- (IBAction)showInfo:(id)sender
{
	(void)sender;
	sData *sample = self.sample;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Sample Information";
	alert.informativeText = @"Name, rate, volume, real-note offset, and loop points use the original sample fields.";
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:5];
	grid.frame = NSMakeRect(0, 0, 300, 118);
	NSArray<NSString *> *labels = @[@"Name", @"Rate", @"Volume", @"Real Note", @"Loop start / size"];
	NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
	NSString *name = [[NSString alloc] initWithBytes:sample->name length:strnlen(sample->name, sizeof(sample->name))
		encoding:NSMacOSRomanStringEncoding] ?: @"";
	NSArray<NSString *> *values = @[name, [NSString stringWithFormat:@"%u", sample->c2spd],
		[NSString stringWithFormat:@"%u", sample->vol], [NSString stringWithFormat:@"%d", sample->realNote],
		[NSString stringWithFormat:@"%d / %d", sample->loopBeg, sample->loopSize]];
	for (NSInteger row = 0; row < labels.count; row++) {
		NSTextField *label = [NSTextField labelWithString:labels[row]];
		label.font = [self classicFont];
		NSTextField *field = [NSTextField textFieldWithString:values[row]];
		field.font = [self classicFont];
		[grid cellAtColumnIndex:0 rowIndex:row].contentView = label;
		[grid cellAtColumnIndex:1 rowIndex:row].contentView = field;
		[fields addObject:field];
	}
	alert.accessoryView = grid;
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn) return;
		PPSampleSnapshot *before = [self snapshot];
		memset(sample->name, 0, sizeof(sample->name));
		NSData *nameData = [fields[0].stringValue dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
		memcpy(sample->name, nameData.bytes, MIN(nameData.length, sizeof(sample->name) - 1));
		sample->c2spd = (unsigned short)MIN(MAX(fields[1].integerValue, 1), USHRT_MAX);
		sample->vol = (MADByte)MIN(MAX(fields[2].integerValue, 0), MAX_VOLUME);
		sample->realNote = (char)MIN(MAX(fields[3].integerValue, -96), 96);
		NSArray<NSString *> *loop = [fields[4].stringValue componentsSeparatedByString:@"/"];
		if (loop.count == 2) {
			sample->loopBeg = (int)[loop[0] integerValue];
			sample->loopSize = (int)[loop[1] integerValue];
			PPClampLoop(sample);
		}
		[self beginUndo:@"Edit Sample Information" snapshot:before];
		[self reloadModePopupSelectingTag:self.displayMode];
		[self didChange];
	}];
}

@end

BOOL PPSampleRunEditingSelfTest(void)
{
	sData sample = {0};
	sample.amp = 8;
	sample.c2spd = 8363;
	sample.vol = 64;
	int8_t original[] = {-10, -5, 0, 5, 10, 20};
	sample.data = malloc(sizeof(original));
	if (sample.data == NULL) return NO;
	memcpy(sample.data, original, sizeof(original));
	sample.size = (int)sizeof(original);
	sample.loopBeg = 3;
	sample.loopSize = 3;
	BOOL passed = PPDeleteBytes(&sample, 1, 3) && sample.size == 4 &&
		((int8_t *)sample.data)[0] == -10 && ((int8_t *)sample.data)[1] == 5 && sample.loopBeg == 1;
	passed = passed && PPReverseBytes(&sample, 0, 4) && ((int8_t *)sample.data)[0] == 20;
	passed = passed && PPNormalizeBytes(&sample, 0, 4) && ((int8_t *)sample.data)[0] == 127;
	int8_t insertion[] = {1, 2};
	passed = passed && PPInsertBytes(&sample, 2, insertion, sizeof(insertion)) && sample.size == 6;
	passed = passed && PPCropBytes(&sample, 1, 5) && sample.size == 4;
	free(sample.data);

	sData stereo = {0};
	stereo.amp = 16;
	stereo.stereo = MADTrue;
	int16_t stereoFrames[] = {1, 2, 3, 4, 5, 6};
	stereo.data = malloc(sizeof(stereoFrames));
	if (stereo.data == NULL) return NO;
	memcpy(stereo.data, stereoFrames, sizeof(stereoFrames));
	stereo.size = (int)sizeof(stereoFrames);
	passed = passed && PPReverseBytes(&stereo, 0, sizeof(stereoFrames)) &&
		((int16_t *)stereo.data)[0] == 5 && ((int16_t *)stereo.data)[1] == 6 &&
		((int16_t *)stereo.data)[4] == 1 && ((int16_t *)stereo.data)[5] == 2;
	free(stereo.data);

	sData filters = {0};
	filters.amp = 8;
	int8_t filterValues[] = {10, 20, 30, 40, 50};
	filters.data = malloc(sizeof(filterValues));
	if (filters.data == NULL) return NO;
	memcpy(filters.data, filterValues, sizeof(filterValues));
	filters.size = (int)sizeof(filterValues);
	passed = passed && PPInvertBytes(&filters, 0, filters.size) && ((int8_t *)filters.data)[0] == -11;
	passed = passed && PPAmplifyBytes(&filters, 0, filters.size, 2.0) && ((int8_t *)filters.data)[0] == -22;
	passed = passed && PPFadeBytes(&filters, 0, filters.size, YES) && ((int8_t *)filters.data)[0] == 0 &&
		((int8_t *)filters.data)[4] == -102;
	passed = passed && PPSilenceBytes(&filters, 1, 3) && ((int8_t *)filters.data)[1] == 0 &&
		((int8_t *)filters.data)[2] == 0;
	int8_t smoothValues[] = {0, 30, 0};
	memcpy(filters.data, smoothValues, sizeof(smoothValues));
	filters.size = (int)sizeof(smoothValues);
	passed = passed && PPSmoothBytes(&filters, 0, filters.size) && ((int8_t *)filters.data)[1] == 22;
	free(filters.data);

	sData betterFade = {0};
	betterFade.amp = 8;
	int8_t betterFadeValues[] = {100, 100, 100, 100, 100};
	betterFade.data = malloc(sizeof(betterFadeValues));
	if (betterFade.data == NULL) return NO;
	memcpy(betterFade.data, betterFadeValues, sizeof(betterFadeValues));
	betterFade.size = (int)sizeof(betterFadeValues);
	passed = passed && PPBetterFadePercentBytes(&betterFade, 0, betterFade.size, 0.0, 100.0) &&
		((int8_t *)betterFade.data)[0] == 0 && ((int8_t *)betterFade.data)[1] == 20 &&
		((int8_t *)betterFade.data)[2] == 40 && ((int8_t *)betterFade.data)[4] == 80;
	PPBetterFadeParameters fadePreset = {.fromPercent = -100, .toPercent = -100,
		.mode = PPBetterFadeModeDown};
	fadePreset = PPBetterFadeEffectiveParameters(fadePreset);
	passed = passed && fadePreset.fromPercent == 100 && fadePreset.toPercent == 0;
	free(betterFade.data);

	sData legacyDSP = {0};
	legacyDSP.amp = 16;
	legacyDSP.c2spd = 8000;
	int16_t dcValues[] = {1000, 2000, 3000, 4000};
	legacyDSP.data = malloc(sizeof(dcValues));
	if (legacyDSP.data == NULL) return NO;
	memcpy(legacyDSP.data, dcValues, sizeof(dcValues));
	legacyDSP.size = (int)sizeof(dcValues);
	passed = passed && PPRemoveDCLinearBytes(&legacyDSP, 0, legacyDSP.size) &&
		((int16_t *)legacyDSP.data)[0] == 928 && ((int16_t *)legacyDSP.data)[3] == 3926;
	int16_t constantValues[] = {1234, 1234, 1234, 1234};
	memcpy(legacyDSP.data, constantValues, sizeof(constantValues));
	passed = passed && PPRemoveDCCircularBytes(&legacyDSP, 0, legacyDSP.size) &&
		((int16_t *)legacyDSP.data)[0] == 1198 && ((int16_t *)legacyDSP.data)[3] == 1197;
	int16_t stepValues[] = {0, 0, 16000, 16000};
	memcpy(legacyDSP.data, stepValues, sizeof(stepValues));
	PPIIRFilterParameters iirTest = {
		.mode = PPIIRFilterLowPass,
		.startFrequency = 1000,
		.endFrequency = 1000,
		.sweepFrequency = NO,
		.wrapAround = NO,
		.repeatEnabled = NO,
		.repeatCount = 1
	};
	passed = passed && PPIIRFilterBytes(&legacyDSP, 0, legacyDSP.size, iirTest) &&
		((int16_t *)legacyDSP.data)[2] > 0 && ((int16_t *)legacyDSP.data)[2] < 16000 &&
		((int16_t *)legacyDSP.data)[3] > ((int16_t *)legacyDSP.data)[2];
	PPIIRFilterParameters iirDefaults = *PPPersistentIIRFilterParameters();
	passed = passed && iirDefaults.mode == PPIIRFilterLowPass &&
		iirDefaults.startFrequency == 800 && iirDefaults.endFrequency == 1802 &&
		iirDefaults.sweepFrequency && !iirDefaults.wrapAround &&
		iirDefaults.repeatEnabled && iirDefaults.repeatCount == 4;
	free(legacyDSP.data);

	// The graphical Hz Filter must reconstruct a flat response without the
	// harsh whole-selection FFT error, including its stereo overlap path.
	sData hzCurve = {0};
	hzCurve.amp = 16;
	hzCurve.stereo = MADTrue;
	hzCurve.c2spd = 44100;
	const size_t hzFrames = 2048;
	hzCurve.data = calloc(hzFrames * 2, sizeof(int16_t));
	if (hzCurve.data == NULL) return NO;
	hzCurve.size = (int)(hzFrames * 2 * sizeof(int16_t));
	((int16_t *)hzCurve.data)[1024 * 2] = 20000;
	((int16_t *)hzCurve.data)[1024 * 2 + 1] = -12000;
	NSData *hzOriginal = [NSData dataWithBytes:hzCurve.data length:(NSUInteger)hzCurve.size];
	double hzGains[1025];
	for (size_t point = 0; point < 1025; point++) hzGains[point] = 1.0;
	passed = passed && PPFrequencyCurveFilterBytes(&hzCurve, 0, hzCurve.size, hzGains, 1025) &&
		memcmp(hzCurve.data, hzOriginal.bytes, hzOriginal.length) == 0;
	for (size_t point = 0; point < 1025; point++) hzGains[point] = 0.5;
	passed = passed && PPFrequencyCurveFilterBytes(&hzCurve, 0, hzCurve.size, hzGains, 1025) &&
		abs(((int16_t *)hzCurve.data)[1024 * 2] - 10000) <= 1 &&
		abs(((int16_t *)hzCurve.data)[1024 * 2 + 1] + 6000) <= 1;
	for (size_t point = 0; point < 1025; point++) hzGains[point] = 0.0;
	passed = passed && PPFrequencyCurveFilterBytes(&hzCurve, 0, hzCurve.size, hzGains, 1025);
	for (size_t value = 0; value < hzFrames * 2; value++)
		passed = passed && ((int16_t *)hzCurve.data)[value] == 0;
	free(hzCurve.data);

	sData restoredExperimental = {0};
	restoredExperimental.amp = 16;
	restoredExperimental.c2spd = 8000;
	int16_t impulseValues[] = {16384, 8192, 0, 0};
	restoredExperimental.data = malloc(sizeof(impulseValues));
	if (restoredExperimental.data == NULL) return NO;
	memcpy(restoredExperimental.data, impulseValues, sizeof(impulseValues));
	restoredExperimental.size = (int)sizeof(impulseValues);
	PPConvolveParameters convolveParameters = {
		.wrapEdges = NO, .normalizeImpulse = NO, .normalizeToSumOne = NO,
		.includeTail = YES, .impulseMode = PPConvolveImpulseSelection,
		.cutoffHertz = 10, .gain = 1.0, .quality = 0.18055555555555555
	};
	passed = passed && PPConvolveBytes(&restoredExperimental, 0, sizeof(int16_t) * 2,
		convolveParameters) && restoredExperimental.size == (int)(5 * sizeof(int16_t)) &&
		abs(((int16_t *)restoredExperimental.data)[0] - 8192) <= 1 &&
		abs(((int16_t *)restoredExperimental.data)[1] - 8192) <= 1 &&
		abs(((int16_t *)restoredExperimental.data)[2] - 2048) <= 1;
	free(restoredExperimental.data);
	restoredExperimental.amp = 8;
	int8_t ringValues[] = {100, 100, 100, 100, 100, 100, 100, 100};
	restoredExperimental.data = malloc(sizeof(ringValues));
	if (restoredExperimental.data == NULL) return NO;
	restoredExperimental.size = (int)sizeof(ringValues);
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	PPRingModulateParameters ringParameters = *PPPersistentRingModulateParameters();
	passed = passed && ringParameters.mode == PPRingModulateModeRing &&
		ringParameters.frequencyHertz == 846 && ringParameters.mixPercent == 100 &&
		!ringParameters.modulateFrequency && ringParameters.modulationDepthHertz == 12 &&
		ringParameters.frequencySource == PPRingFrequencyRampUp &&
		ringParameters.modulationRateHundredthHertz == 100 &&
		fabs(ringParameters.envelopeSense - 0.999) < 1.0e-12;
	ringParameters.frequencyHertz = 1000;
	passed = passed && PPRingModulateBytes(&restoredExperimental, 0, restoredExperimental.size,
		ringParameters) && ((int8_t *)restoredExperimental.data)[0] == 71 &&
		((int8_t *)restoredExperimental.data)[1] == 100 &&
		((int8_t *)restoredExperimental.data)[3] == 0 &&
		((int8_t *)restoredExperimental.data)[5] == -101;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	double shiftDestinations[1025];
	for (size_t point = 0; point < 1025; point++) {
		shiftDestinations[point] = (double)point / 1024.0;
	}
	passed = passed && PPFrequencyMapShiftBytes(&restoredExperimental, 0,
		restoredExperimental.size, shiftDestinations, 1025, NO) &&
		memcmp(restoredExperimental.data, ringValues, sizeof(ringValues)) == 0;
	for (size_t point = 0; point < 1025; point++) {
		shiftDestinations[point] = PPHzFilterCanonicalPosition((double)point / 1024.0, YES);
	}
	passed = passed && PPFrequencyMapShiftBytes(&restoredExperimental, 0,
		restoredExperimental.size, shiftDestinations, 1025, YES) &&
		memcmp(restoredExperimental.data, ringValues, sizeof(ringValues)) == 0;
	int8_t noiseFirst[sizeof(ringValues)];
	int8_t noiseSecond[sizeof(ringValues)];
	PPNoiseParameters noiseParameters = *PPPersistentNoiseParameters();
	noiseParameters.mode = PPNoiseModeWhite;
	uint32_t noiseSeed = 1;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	passed = passed && PPNoiseBytesWithSeed(&restoredExperimental, 0,
		restoredExperimental.size, noiseParameters, &noiseSeed);
	memcpy(noiseFirst, restoredExperimental.data, sizeof(noiseFirst));
	noiseSeed = 1;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	passed = passed && PPNoiseBytesWithSeed(&restoredExperimental, 0,
		restoredExperimental.size, noiseParameters, &noiseSeed);
	memcpy(noiseSecond, restoredExperimental.data, sizeof(noiseSecond));
	passed = passed && memcmp(noiseFirst, noiseSecond, sizeof(noiseFirst)) == 0 &&
		memcmp(noiseFirst, ringValues, sizeof(noiseFirst)) != 0;
	PPNoiseParameters noiseDefaults = *PPPersistentNoiseParameters();
	passed = passed && noiseDefaults.mode == PPNoiseModeRing &&
		noiseDefaults.ringComponentCount == 20 && noiseDefaults.ringMinimumHertz == 210 &&
		noiseDefaults.ringMaximumHertz == 230 && noiseDefaults.frequencyBPM == 350 &&
		noiseDefaults.frequencyMinimumHertz == 110 && noiseDefaults.frequencyMaximumHertz == 880;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	PPStardustParameters stardustParameters = *PPPersistentStardustParameters();
	double stardustRandomState = 0.125;
	passed = passed && PPStardustGrainLength(stardustParameters) == 3500 &&
		PPStardustGrainCount(stardustParameters) == 62 &&
		PPStardustBytesWithRandomState(&restoredExperimental, 0, restoredExperimental.size,
			stardustParameters, &stardustRandomState) &&
		memcmp(restoredExperimental.data, ringValues, sizeof(ringValues)) == 0;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	PPAddotrophParameters addotrophParameters = *PPPersistentAddotrophParameters();
	passed = passed && fabs(PPAddotrophBaseFrequency(addotrophParameters) - 65.406391328) < 0.000001 &&
		PPAddotrophBytes(&restoredExperimental, 0,
		restoredExperimental.size, addotrophParameters) &&
		((int8_t *)restoredExperimental.data)[0] == 0 &&
		memcmp(restoredExperimental.data, ringValues, sizeof(ringValues)) != 0;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	PPAderodhiecusParameters aderodhiecusParameters = *PPPersistentAderodhiecusParameters();
	passed = passed && PPAderodhiecusBytes(&restoredExperimental, 0, restoredExperimental.size,
		aderodhiecusParameters) && ((int8_t *)restoredExperimental.data)[0] < ringValues[0] &&
		((int8_t *)restoredExperimental.data)[0] > 0;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	passed = passed && PPEnvelopeTestBytes(&restoredExperimental, 0, restoredExperimental.size,
		1.2, 0.1, 0.7) && ((int8_t *)restoredExperimental.data)[0] == 0 &&
		((int8_t *)restoredExperimental.data)[4] == 100 &&
		((int8_t *)restoredExperimental.data)[7] > 0;
	memcpy(restoredExperimental.data, ringValues, sizeof(ringValues));
	uint32_t fingawalixSeed = 1;
	passed = passed && PPFingawalixBytesWithSeed(&restoredExperimental, 0,
		restoredExperimental.size, &fingawalixSeed) &&
		((int8_t *)restoredExperimental.data)[0] == 0 &&
		memcmp(restoredExperimental.data, ringValues, sizeof(ringValues)) != 0;
	free(restoredExperimental.data);
	restoredExperimental.data = calloc(512, sizeof(int8_t));
	if (restoredExperimental.data == NULL) return NO;
	restoredExperimental.size = 512;
	uint32_t memphifSeed = 1;
	passed = passed && PPMemphifBytesWithSeed(&restoredExperimental, 0,
		restoredExperimental.size, &memphifSeed) &&
		((int8_t *)restoredExperimental.data)[31] == -9 &&
		((int8_t *)restoredExperimental.data)[127] == 50 &&
		((int8_t *)restoredExperimental.data)[255] == -41;
	free(restoredExperimental.data);

	sData saturator = {0};
	saturator.amp = 8;
	int8_t saturatorValues[] = {-64, 0, 64};
	saturator.data = malloc(sizeof(saturatorValues));
	if (saturator.data == NULL) return NO;
	memcpy(saturator.data, saturatorValues, sizeof(saturatorValues));
	saturator.size = (int)sizeof(saturatorValues);
	passed = passed && PPSaturateBytes(&saturator, 0, saturator.size, 1.0) &&
		((int8_t *)saturator.data)[0] == -59 && ((int8_t *)saturator.data)[1] == 0 &&
		((int8_t *)saturator.data)[2] == 59;
	passed = passed && PPSaturateBytes(&saturator, 0, saturator.size, 0.0) &&
		((int8_t *)saturator.data)[0] == 0 && ((int8_t *)saturator.data)[2] == 0;
	free(saturator.data);

	// These gain-2 knee points are deliberately far from hard clipping:
	// clip(2*x) would yield -32768/-32768/-16384 and 16384/32767/32767.
	sData saturator16 = {0};
	saturator16.amp = 16;
	int16_t saturator16Values[] = {-24576, -16384, -8192, 0, 8192, 16384, 24576};
	saturator16.data = malloc(sizeof(saturator16Values));
	if (saturator16.data == NULL) return NO;
	memcpy(saturator16.data, saturator16Values, sizeof(saturator16Values));
	saturator16.size = (int)sizeof(saturator16Values);
	passed = passed && PPSaturateBytes(&saturator16, 0, saturator16.size, 2.0) &&
		((int16_t *)saturator16.data)[0] == -29660 && ((int16_t *)saturator16.data)[1] == -24956 &&
		((int16_t *)saturator16.data)[2] == -15143 && ((int16_t *)saturator16.data)[3] == 0 &&
		((int16_t *)saturator16.data)[4] == 15143 && ((int16_t *)saturator16.data)[5] == 24956 &&
		((int16_t *)saturator16.data)[6] == 29659;
	free(saturator16.data);

	// EQ-3 at its default 0 dB settings must be a bit-exact no-op, including
	// interleaved stereo samples.
	sData eq3Neutral = {0};
	eq3Neutral.amp = 16;
	eq3Neutral.stereo = MADTrue;
	eq3Neutral.c2spd = 44100;
	int16_t eq3NeutralValues[] = {1000, -1000, 2000, -2000, -3000, 3000, 0, 0};
	int16_t eq3NeutralOriginal[sizeof(eq3NeutralValues) / sizeof(eq3NeutralValues[0])];
	memcpy(eq3NeutralOriginal, eq3NeutralValues, sizeof(eq3NeutralValues));
	eq3Neutral.data = malloc(sizeof(eq3NeutralValues));
	if (eq3Neutral.data == NULL) return NO;
	memcpy(eq3Neutral.data, eq3NeutralValues, sizeof(eq3NeutralValues));
	eq3Neutral.size = (int)sizeof(eq3NeutralValues);
	passed = passed && PPEQ3Bytes(&eq3Neutral, 0, eq3Neutral.size, 0.0, 0.0, 0.0, 250.0, 4000.0) &&
		memcmp(eq3Neutral.data, eq3NeutralOriginal, sizeof(eq3NeutralValues)) == 0;
	free(eq3Neutral.data);

	// A DC signal belongs to the low band. Boosting it also verifies that the
	// two stereo filter-state pairs remain independent.
	sData eq3Stereo = {0};
	eq3Stereo.amp = 16;
	eq3Stereo.stereo = MADTrue;
	eq3Stereo.c2spd = 44100;
	const size_t eq3StereoFrames = 32;
	eq3Stereo.data = calloc(eq3StereoFrames * 2, sizeof(int16_t));
	if (eq3Stereo.data == NULL) return NO;
	eq3Stereo.size = (int)(eq3StereoFrames * 2 * sizeof(int16_t));
	for (size_t frame = 0; frame < eq3StereoFrames; frame++) ((int16_t *)eq3Stereo.data)[frame * 2] = 1000;
	passed = passed && PPEQ3Bytes(&eq3Stereo, 0, eq3Stereo.size, 6.0, 0.0, 0.0, 250.0, 4000.0) &&
		((int16_t *)eq3Stereo.data)[(eq3StereoFrames - 1) * 2] > 1900;
	for (size_t frame = 0; frame < eq3StereoFrames; frame++) {
		passed = passed && ((int16_t *)eq3Stereo.data)[frame * 2 + 1] == 0;
	}
	free(eq3Stereo.data);

	// Exercise the 8-bit path with a transient whose high-frequency component
	// must become larger after a high-band boost.
	sData eq3EightBit = {0};
	eq3EightBit.amp = 8;
	eq3EightBit.c2spd = 44100;
	int8_t eq3EightBitValues[] = {0, 64, 0, 0, 0, 0, 0, 0};
	eq3EightBit.data = malloc(sizeof(eq3EightBitValues));
	if (eq3EightBit.data == NULL) return NO;
	memcpy(eq3EightBit.data, eq3EightBitValues, sizeof(eq3EightBitValues));
	eq3EightBit.size = (int)sizeof(eq3EightBitValues);
	passed = passed && PPEQ3Bytes(&eq3EightBit, 0, eq3EightBit.size, 0.0, 0.0, 6.0, 250.0, 4000.0) &&
		((int8_t *)eq3EightBit.data)[1] > 90;
	free(eq3EightBit.data);

	// Moving either crossover must change the actual filter response, not just
	// the displayed band label.
	sData eq3CrossoverLow = {0}, eq3CrossoverHigh = {0};
	eq3CrossoverLow.amp = eq3CrossoverHigh.amp = 16;
	eq3CrossoverLow.c2spd = eq3CrossoverHigh.c2spd = 44100;
	int16_t crossoverImpulse[] = {0, 16000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
	eq3CrossoverLow.data = malloc(sizeof(crossoverImpulse));
	eq3CrossoverHigh.data = malloc(sizeof(crossoverImpulse));
	if (eq3CrossoverLow.data == NULL || eq3CrossoverHigh.data == NULL) {
		free(eq3CrossoverLow.data); free(eq3CrossoverHigh.data); return NO;
	}
	memcpy(eq3CrossoverLow.data, crossoverImpulse, sizeof(crossoverImpulse));
	memcpy(eq3CrossoverHigh.data, crossoverImpulse, sizeof(crossoverImpulse));
	eq3CrossoverLow.size = eq3CrossoverHigh.size = (int)sizeof(crossoverImpulse);
	passed = passed && PPEQ3Bytes(&eq3CrossoverLow, 0, eq3CrossoverLow.size,
		0.0, 0.0, 6.0, 250.0, 1000.0);
	passed = passed && PPEQ3Bytes(&eq3CrossoverHigh, 0, eq3CrossoverHigh.size,
		0.0, 0.0, 6.0, 250.0, 8000.0);
	passed = passed && memcmp(eq3CrossoverLow.data, eq3CrossoverHigh.data,
		sizeof(crossoverImpulse)) != 0;
	free(eq3CrossoverLow.data);
	free(eq3CrossoverHigh.data);

	sData freeverb = {0};
	freeverb.amp = 16;
	freeverb.c2spd = 44100;
	const size_t freeverbFrames = 8192;
	freeverb.data = calloc(freeverbFrames, sizeof(int16_t));
	if (freeverb.data == NULL) return NO;
	freeverb.size = (int)(freeverbFrames * sizeof(int16_t));
	((int16_t *)freeverb.data)[0] = 20000;
	PPFreeverbParameters freeverbParameters = {
		.roomSize = 0.5,
		.damping = 0.5,
		.predelayMilliseconds = 0.0,
		.lowpassPercent = 0.0,
		.highpassPercent = 0.0,
		.wetDecibels = 0.0,
		.dryDecibels = -60.0
	};
	passed = passed && PPFreeverbBytes(&freeverb, 0, freeverb.size, freeverbParameters) &&
		((int16_t *)freeverb.data)[0] == 0;
	BOOL foundReverbTail = NO;
	for (size_t frame = 2000; frame < freeverbFrames; frame++) {
		if (((int16_t *)freeverb.data)[frame] != 0) { foundReverbTail = YES; break; }
	}
	passed = passed && foundReverbTail;
	free(freeverb.data);

	// The Mixer uses a persistent Freeverb instance, so its tail must cross
	// PlayerPRO render-buffer boundaries without reallocating or resetting.
	PPFreeverbParameters realtimeParameters = freeverbParameters;
	PPFreeverbRealtime *realtime = PPFreeverbRealtimeCreate(44100.0, 256, realtimeParameters);
	if (realtime == NULL) return NO;
	int32_t realtimeBlock[256 * 2] = {0};
	realtimeBlock[0] = 20000;
	realtimeBlock[1] = 20000;
	passed = passed && PPFreeverbRealtimeProcessInt32(realtime, realtimeBlock, 256);
	BOOL foundRealtimeTail = NO;
	for (NSInteger block = 0; block < 16; block++) {
		memset(realtimeBlock, 0, sizeof(realtimeBlock));
		passed = passed && PPFreeverbRealtimeProcessInt32(realtime, realtimeBlock, 256);
		for (size_t sample = 0; sample < 256 * 2; sample++) {
			if (realtimeBlock[sample] != 0) { foundRealtimeTail = YES; break; }
		}
	}
	passed = passed && foundRealtimeTail;
	PPFreeverbRealtimeDestroy(realtime);

	sData restoredFilters = {0};
	restoredFilters.amp = 8;
	restoredFilters.c2spd = 1000;
	int8_t restoredValues[48] = {64};
	restoredFilters.data = malloc(sizeof(restoredValues));
	if (restoredFilters.data == NULL) return NO;
	memcpy(restoredFilters.data, restoredValues, sizeof(restoredValues));
	restoredFilters.size = (int)sizeof(restoredValues);
	passed = passed && PPEchoBytes(&restoredFilters, 0, restoredFilters.size, 1.0, 50.0) &&
		((int8_t *)restoredFilters.data)[22] == 32 && ((int8_t *)restoredFilters.data)[44] == 16;
	int8_t depthValues[] = {31, -31, 127, -128};
	memcpy(restoredFilters.data, depthValues, sizeof(depthValues));
	restoredFilters.size = (int)sizeof(depthValues);
	passed = passed && PPQuantizeDepthBytes(&restoredFilters, 0, restoredFilters.size, 4) &&
		((int8_t *)restoredFilters.data)[0] == 16 && ((int8_t *)restoredFilters.data)[1] == -32;
	int8_t fadeValues[] = {100, 100, 100, 100};
	memcpy(restoredFilters.data, fadeValues, sizeof(fadeValues));
	passed = passed && PPFadePercentBytes(&restoredFilters, 0, restoredFilters.size, 100.0, 0.0) &&
		((int8_t *)restoredFilters.data)[0] == 0 && ((int8_t *)restoredFilters.data)[3] == 75;
	int8_t crossfadeValues[] = {0, 0, 0, 0, 0, 0, 100, 100, 100, 100, 0, 0};
	memcpy(restoredFilters.data, crossfadeValues, sizeof(crossfadeValues));
	restoredFilters.size = (int)sizeof(crossfadeValues);
	passed = passed && PPCrossfadeBytes(&restoredFilters, 4, 8) &&
		((int8_t *)restoredFilters.data)[3] == 37 &&
		((int8_t *)restoredFilters.data)[4] == 50 &&
		((int8_t *)restoredFilters.data)[7] == 62 &&
		((int8_t *)restoredFilters.data)[8] == 50;
	free(restoredFilters.data);

	sData resized = {0};
	resized.amp = 8;
	resized.c2spd = 4;
	int8_t resizeValues[] = {1, 2, 3, 4};
	resized.data = malloc(sizeof(resizeValues));
	if (resized.data == NULL) return NO;
	memcpy(resized.data, resizeValues, sizeof(resizeValues));
	resized.size = (int)sizeof(resizeValues);
	passed = passed && PPChangeLengthFrames(&resized, 6, PPSampleLengthMoveRight, NO) && resized.size == 6 &&
		((int8_t *)resized.data)[0] == 0 && ((int8_t *)resized.data)[2] == 1 && ((int8_t *)resized.data)[5] == 4;
	passed = passed && PPChangeSamplingRate(&resized, 8) && resized.size == 12 && resized.c2spd == 8;
	passed = passed && PPGenerateTone(&resized, 0, resized.size, 4, 22254.54545 / 4.0,
		100.0, PPToneSine) && resized.size == 4 &&
		((int8_t *)resized.data)[0] == 0 && ((int8_t *)resized.data)[1] == 127 &&
		labs(((int8_t *)resized.data)[2]) <= 1 && ((int8_t *)resized.data)[3] == -127;
	free(resized.data);
	return passed;
}
