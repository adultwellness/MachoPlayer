#import "PPMixerController.h"
#import "PPPreferences.h"

#include "MADDriver.h"
#include "VSTFunctions.h"
#include <math.h>

static uint16_t PPMixerRead16(const uint8_t *bytes, BOOL littleEndian)
{
	return littleEndian ? (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8))
		: (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
}

static uint32_t PPMixerRead32(const uint8_t *bytes, BOOL littleEndian)
{
	return littleEndian ? (uint32_t)(bytes[0] | ((uint32_t)bytes[1] << 8) |
		((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24))
		: (uint32_t)(((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
		((uint32_t)bytes[2] << 8) | bytes[3]);
}

static void PPMixerAppend16(NSMutableData *data, uint16_t value)
{
	uint8_t bytes[2] = {(uint8_t)(value >> 8), (uint8_t)value};
	[data appendBytes:bytes length:sizeof(bytes)];
}

static void PPMixerAppend32(NSMutableData *data, uint32_t value)
{
	uint8_t bytes[4] = {(uint8_t)(value >> 24), (uint8_t)(value >> 16),
		(uint8_t)(value >> 8), (uint8_t)value};
	[data appendBytes:bytes length:sizeof(bytes)];
}

@interface PPMixerFlippedView : NSView
@end

@implementation PPMixerFlippedView
- (BOOL)isFlipped { return YES; }
@end

// The original mixer was a compact, ruled utility window. Keeping the rules
// in one background view preserves that hierarchy when the track list grows.
@interface PPMixerContentView : NSView
@end

@implementation PPMixerContentView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	CGFloat height = NSHeight(self.bounds);
	[NSColor.blackColor setStroke];
	NSBezierPath *rules = [NSBezierPath bezierPath];
	rules.lineWidth = 1.0;
	for (NSNumber *offset in @[@30.5, @54.5, @120.5, @140.5, @162.5, @180.5]) {
		CGFloat y = floor(height - offset.doubleValue) + 0.5;
		[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), y)];
		[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), y)];
	}
	[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), 14.5)];
	[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), 14.5)];
	[rules stroke];
}
@end

typedef NS_ENUM(NSInteger, PPMixerGlobalIconKind) {
	PPMixerGlobalIconPitch,
	PPMixerGlobalIconSpeed,
	PPMixerGlobalIconPanning
};

@interface PPMixerGlobalIconView : NSView
@property(nonatomic) PPMixerGlobalIconKind kind;
@end

@implementation PPMixerGlobalIconView
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.blackColor setStroke];
	[NSColor.blackColor setFill];
	NSBezierPath *path = [NSBezierPath bezierPath];
	path.lineWidth = 1.25;
	if (self.kind == PPMixerGlobalIconPitch) {
		[path moveToPoint:NSMakePoint(12.5, 14.5)];
		[path lineToPoint:NSMakePoint(12.5, 5.0)];
		[path lineToPoint:NSMakePoint(17.0, 6.5)];
		[path stroke];
		[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(7, 2, 7, 5)] fill];
		[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(14, 5, 5, 4)] fill];
	} else if (self.kind == PPMixerGlobalIconSpeed) {
		for (NSInteger x = 2; x <= 6; x += 2) NSRectFill(NSMakeRect(x, 5, 1, 8));
		[path moveToPoint:NSMakePoint(8, 9)];
		[path lineToPoint:NSMakePoint(16, 9)];
		[path stroke];
		[path removeAllPoints];
		[path moveToPoint:NSMakePoint(16, 5)];
		[path lineToPoint:NSMakePoint(20, 9)];
		[path lineToPoint:NSMakePoint(16, 13)];
		[path closePath];
		[path fill];
	} else {
		NSRectFill(NSMakeRect(1, 7, 4, 5));
		[path moveToPoint:NSMakePoint(5, 7)];
		[path lineToPoint:NSMakePoint(8, 4)];
		[path lineToPoint:NSMakePoint(8, 15)];
		[path lineToPoint:NSMakePoint(5, 12)];
		[path closePath];
		[path fill];
		NSRectFill(NSMakeRect(17, 7, 4, 5));
		[path removeAllPoints];
		[path moveToPoint:NSMakePoint(17, 7)];
		[path lineToPoint:NSMakePoint(14, 4)];
		[path lineToPoint:NSMakePoint(14, 15)];
		[path lineToPoint:NSMakePoint(17, 12)];
		[path closePath];
		[path fill];
		[path removeAllPoints];
		[path moveToPoint:NSMakePoint(9, 9.5)];
		[path lineToPoint:NSMakePoint(13, 9.5)];
		[path stroke];
	}
}
@end

static void PPMixerDefaultEffectValues(uint32_t effectID,
	float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT])
{
	memset(values, 0, sizeof(float) * PP_BUILTIN_EFFECT_PARAMETER_COUNT);
	if (effectID == PP_BUILTIN_FREEVERB_ID) {
		values[0] = 0.84f;
		values[1] = 0.50f;
		values[5] = -6.0f;
		values[6] = 0.0f;
	} else if (effectID == PP_BUILTIN_DJ_FILTER_ID) {
		values[0] = 0.0f;
	} else if (effectID == PP_BUILTIN_COMPRESSOR_ID) {
		values[0] = -12.0f;
		values[1] = 4.0f;
		values[2] = 10.0f;
		values[3] = 100.0f;
		values[4] = 0.0f;
	}
}

static NSFont *PPMixerClassicFont(void);

static void PPMixerInitialTempoAndSpeed(MADMusic *music, NSInteger *tempo, NSInteger *speed)
{
	NSInteger resolvedTempo = 125;
	NSInteger resolvedSpeed = 6;
	if (music != NULL && music->header != NULL) {
		if (music->header->tempo > 0) resolvedTempo = music->header->tempo;
		if (music->header->speed > 0) resolvedSpeed = music->header->speed;

		if (music->header->numPointers > 0) {
			NSInteger patternIndex = music->header->oPointers[0];
			if (patternIndex < music->header->numPat && patternIndex < MAXPATTERN) {
				PatData *pattern = music->partition[patternIndex];
				if (pattern != NULL && pattern->header.size > 0) {
					NSInteger channels = MIN((NSInteger)music->header->numChn, (NSInteger)MAXTRACK);
					// Playback evaluates a row from the first through the last
					// channel, so later commands on row zero take precedence.
					for (NSInteger channel = 0; channel < channels; channel++) {
						Cmd *command = GetMADCommand(0, (short)channel, pattern);
						if (command == NULL || command->cmd != MADEffectSpeed || command->arg == 0) continue;
						if (command->arg < 32) resolvedSpeed = command->arg;
						else resolvedTempo = command->arg;
					}
				}
			}
		}
	}
	if (tempo != NULL) *tempo = resolvedTempo;
	if (speed != NULL) *speed = resolvedSpeed;
}

typedef void (^PPMixerEffectChangeHandler)(
	const float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT]);

@interface PPMixerEffectEditorView : NSView {
	float _storedValues[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
}
- (instancetype)initWithEffectID:(uint32_t)effectID
	values:(const float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values;
- (void)copyValues:(float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values;
@end

@interface PPMixerEffectEditorView ()
@property(nonatomic) uint32_t effectID;
@property(nonatomic, strong) NSArray<NSDictionary *> *descriptors;
@property(nonatomic, strong) NSMutableArray<NSSlider *> *sliders;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *valueFields;
@property(nonatomic, copy) PPMixerEffectChangeHandler valuesChangedHandler;
@end

@implementation PPMixerEffectEditorView

- (instancetype)initWithEffectID:(uint32_t)effectID
	values:(const float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values
{
	NSArray<NSDictionary *> *descriptors;
	if (effectID == PP_BUILTIN_FREEVERB_ID) {
		descriptors = @[
			@{@"title": @"Room Size:", @"index": @0, @"min": @0.0, @"max": @1.0, @"kind": @"decimal"},
			@{@"title": @"Damping:", @"index": @1, @"min": @0.0, @"max": @1.0, @"kind": @"percent01"},
			@{@"title": @"Wet Level:", @"index": @5, @"min": @-60.0, @"max": @0.0, @"kind": @"db"},
			@{@"title": @"Dry Level:", @"index": @6, @"min": @-60.0, @"max": @0.0, @"kind": @"db"}
		];
	} else if (effectID == PP_BUILTIN_DJ_FILTER_ID) {
		descriptors = @[
			@{@"title": @"Filter:", @"index": @0, @"min": @-1.0, @"max": @1.0, @"kind": @"dj"}
		];
	} else {
		descriptors = @[
			@{@"title": @"Threshold:", @"index": @0, @"min": @-60.0, @"max": @0.0, @"kind": @"db"},
			@{@"title": @"Ratio:", @"index": @1, @"min": @1.0, @"max": @20.0, @"kind": @"ratio"},
			@{@"title": @"Attack:", @"index": @2, @"min": @0.1, @"max": @200.0, @"kind": @"ms"},
			@{@"title": @"Release:", @"index": @3, @"min": @1.0, @"max": @2000.0, @"kind": @"ms"},
			@{@"title": @"Makeup:", @"index": @4, @"min": @0.0, @"max": @24.0, @"kind": @"db"}
		];
	}
	self = [super initWithFrame:NSMakeRect(0, 0, 390, 16 + descriptors.count * 34)];
	if (self == nil) return nil;
	_effectID = effectID;
	_descriptors = descriptors;
	_sliders = [NSMutableArray arrayWithCapacity:descriptors.count];
	_valueFields = [NSMutableArray arrayWithCapacity:descriptors.count];
	memcpy(_storedValues, values, sizeof(_storedValues));

	for (NSInteger row = 0; row < (NSInteger)descriptors.count; row++) {
		NSDictionary *descriptor = descriptors[row];
		CGFloat y = NSHeight(self.bounds) - 29 - row * 34;
		NSTextField *label = [NSTextField labelWithString:descriptor[@"title"]];
		label.frame = NSMakeRect(0, y + 3, 82, 16);
		label.font = PPMixerClassicFont();
		label.textColor = NSColor.blackColor;
		[self addSubview:label];
		NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(84, y, 220, 20)];
		slider.minValue = [descriptor[@"min"] doubleValue];
		slider.maxValue = [descriptor[@"max"] doubleValue];
		slider.doubleValue = _storedValues[[descriptor[@"index"] integerValue]];
		slider.continuous = YES;
		slider.controlSize = NSControlSizeSmall;
		slider.tag = row;
		slider.target = self;
		slider.action = @selector(sliderChanged:);
		[self addSubview:slider];
		[_sliders addObject:slider];
		NSTextField *value = [NSTextField labelWithString:@""];
		value.frame = NSMakeRect(309, y + 3, 81, 16);
		value.font = PPMixerClassicFont();
		value.textColor = NSColor.blackColor;
		value.alignment = NSTextAlignmentRight;
		[self addSubview:value];
		[_valueFields addObject:value];
	}
	[self refreshLabels];
	return self;
}

- (NSString *)displayStringForValue:(double)value kind:(NSString *)kind
{
	if ([kind isEqualToString:@"percent01"]) return [NSString stringWithFormat:@"%.0f %%", value * 100.0];
	if ([kind isEqualToString:@"db"]) return value <= -59.95 ? @"-∞ dB" : [NSString stringWithFormat:@"%.1f dB", value];
	if ([kind isEqualToString:@"ratio"]) return [NSString stringWithFormat:@"%.1f:1", value];
	if ([kind isEqualToString:@"ms"]) return [NSString stringWithFormat:@"%.1f ms", value];
	if ([kind isEqualToString:@"dj"]) {
		if (fabs(value) < 0.005) return @"Off";
		return [NSString stringWithFormat:@"%@ %.0f %%", value < 0.0 ? @"LP" : @"HP", fabs(value) * 100.0];
	}
	return [NSString stringWithFormat:@"%.2f", value];
}

- (void)refreshLabels
{
	for (NSInteger row = 0; row < (NSInteger)self.descriptors.count; row++) {
		NSDictionary *descriptor = self.descriptors[row];
		NSInteger index = [descriptor[@"index"] integerValue];
		self.valueFields[row].stringValue = [self displayStringForValue:_storedValues[index]
			kind:descriptor[@"kind"]];
	}
}

- (IBAction)sliderChanged:(NSSlider *)sender
{
	if (sender.tag < 0 || sender.tag >= (NSInteger)self.descriptors.count) return;
	NSInteger index = [self.descriptors[sender.tag][@"index"] integerValue];
	_storedValues[index] = (float)sender.doubleValue;
	[self refreshLabels];
	if (self.valuesChangedHandler != nil) self.valuesChangedHandler(_storedValues);
}

- (void)copyValues:(float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values
{
	memcpy(values, _storedValues, sizeof(_storedValues));
}

@end

@interface PPMixerMeterView : NSView
@property(nonatomic) CGFloat level;
@property(nonatomic) NSInteger track;
@property(nonatomic) NSInteger instrument;
@end

@implementation PPMixerMeterView

- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.blackColor setFill];
	NSRectFill(self.bounds);
	NSRect inside = NSInsetRect(self.bounds, 1, 2);
	NSRect fill = inside;
	fill.size.width *= MIN(MAX(self.level, 0.0), 1.0);
	[PPPreferredTrackColor(self.track) setFill];
	NSRectFill(fill);
	[NSColor.blackColor setStroke];
	NSFrameRect(self.bounds);
}

@end

static NSFont *PPMixerClassicFont(void)
{
	return [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
}

static NSImage *PPMixerOriginalIcon(const uint32_t rows[20])
{
	NSImage *image = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:NO drawingHandler:^BOOL(NSRect destination) {
		[NSColor.blackColor setFill];
		CGFloat pixelWidth = NSWidth(destination) / 20.0;
		CGFloat pixelHeight = NSHeight(destination) / 20.0;
		for (NSInteger y = 0; y < 20; y++) {
			for (NSInteger x = 0; x < 20; x++) {
				if ((rows[y] & (0x80000000U >> x)) == 0) continue;
				NSRectFill(NSMakeRect(NSMinX(destination) + x * pixelWidth,
					NSMaxY(destination) - (y + 1) * pixelHeight, pixelWidth, pixelHeight));
			}
		}
		return YES;
	}];
	image.template = NO;
	return image;
}

static NSImage *PPMixerIcon(NSInteger resourceID)
{
	static NSDictionary<NSNumber *, NSImage *> *images;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// Upper-left 20 × 20 pixels of the matching PlayerPRO 2002 ICN# resources.
		static const uint32_t saveRows[20] = {
			0, 0, 0, 0x0FFE0000, 0x12010000, 0x12188000, 0x12008000, 0x10008000,
			0x10008000, 0x10008000, 0x10608000, 0x10608000, 0x10608000, 0x10F08000,
			0x10608000, 0x10008000, 0x1FFF8000, 0, 0, 0
		};
		static const uint32_t loadRows[20] = {
			0, 0, 0, 0x0FFE0000, 0x12010000, 0x12188000, 0x12008000, 0x10008000,
			0x10008000, 0x10008000, 0x10608000, 0x10F08000, 0x10608000, 0x10608000,
			0x10608000, 0x10008000, 0x1FFF8000, 0, 0, 0
		};
		static const uint32_t resetRows[20] = {
			0, 0, 0, 0x1E000000, 0x1F000000, 0x1B000000, 0x1E000000, 0x1B000000,
			0x1B000000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
		};
		static const uint32_t flipRows[20] = {
			0, 0, 0, 0, 0, 0x04020000, 0x08010000, 0x09090000, 0x12648000,
			0x12648000, 0x12648000, 0x09090000, 0x08010000, 0x04020000, 0, 0, 0, 0, 0, 0
		};
		static const uint32_t fineRows[20] = {
			0, 0, 0, 0, 0x00040000, 0x07BE0000, 0x07BF0000, 0x07BE0000,
			0x00040000, 0, 0x00700000, 0x00700000, 0x00200000, 0x00E00000,
			0x01700000, 0x00E00000, 0, 0, 0, 0
		};
		images = @{
			@151: PPMixerOriginalIcon(saveRows), @152: PPMixerOriginalIcon(loadRows),
			@168: PPMixerOriginalIcon(resetRows), @172: PPMixerOriginalIcon(flipRows),
			@212: PPMixerOriginalIcon(fineRows)
		};
	});
	return images[@(resourceID)];
}

@interface PPMixerController () <NSWindowDelegate>
@property(nonatomic) MADMusic *music;
@property(nonatomic) MADDriverRec *driver;
@property(nonatomic, strong) NSScrollView *channelScroll;
@property(nonatomic, strong) NSMutableArray<NSButton *> *activeButtons;
@property(nonatomic, strong) NSMutableArray<NSButton *> *monoButtons;
@property(nonatomic, strong) NSMutableArray<NSSlider *> *volumeSliders;
@property(nonatomic, strong) NSMutableArray<NSSlider *> *panSliders;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *volumeFields;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *panFields;
@property(nonatomic, strong) NSMutableArray<PPMixerMeterView *> *meters;
@property(nonatomic, strong) NSMutableArray<NSButton *> *trackFXToggles;
@property(nonatomic, strong) NSMutableArray<NSButton *> *trackEffectButtons;
@property(nonatomic, strong) NSMutableArray<NSButton *> *trackEffectSettingsButtons;
@property(nonatomic, strong) NSSlider *masterVolumeSlider;
@property(nonatomic, strong) NSSlider *masterPanSlider;
@property(nonatomic, strong) NSSlider *pitchSlider;
@property(nonatomic, strong) NSSlider *speedSlider;
@property(nonatomic, strong) NSTextField *masterVolumeField;
@property(nonatomic, strong) NSTextField *masterPanField;
@property(nonatomic, strong) NSTextField *pitchField;
@property(nonatomic, strong) NSTextField *speedField;
@property(nonatomic, strong) NSTextField *tempoField;
@property(nonatomic, strong) NSTextField *effectTitleField;
@property(nonatomic, strong) NSButton *globalFXToggle;
@property(nonatomic, strong) NSMutableArray<NSButton *> *globalEffectButtons;
@property(nonatomic, strong) NSButton *reverbToggle;
@property(nonatomic, strong) NSSlider *reverbDelaySlider;
@property(nonatomic, strong) NSSlider *reverbStrengthSlider;
@property(nonatomic, strong) NSTextField *reverbDelayField;
@property(nonatomic, strong) NSTextField *reverbStrengthField;
@property(nonatomic, strong) NSTimer *meterTimer;
@end

@implementation PPMixerController

- (instancetype)initWithMusic:(MADMusic *)music driver:(MADDriverRec *)driver
{
	self = [super initWithWindow:nil];
	if (self == nil) return nil;
	_music = music;
	_driver = driver;
	[self buildWindow];
	_meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self
		selector:@selector(updateMeters:) userInfo:nil repeats:YES];
	return self;
}

- (void)dealloc
{
	[_meterTimer invalidate];
}

- (NSTextField *)label:(NSString *)title frame:(NSRect)frame inView:(NSView *)view
{
	NSTextField *field = [NSTextField labelWithString:title ?: @""];
	field.frame = frame;
	field.font = PPMixerClassicFont();
	field.textColor = NSColor.blackColor;
	field.lineBreakMode = NSLineBreakByClipping;
	[view addSubview:field];
	return field;
}

- (NSButton *)iconButton:(NSInteger)resourceID x:(CGFloat)x action:(SEL)action toolTip:(NSString *)toolTip
{
	NSButton *button = [NSButton buttonWithImage:PPMixerIcon(resourceID) target:self action:action];
	button.frame = NSMakeRect(x, 253, 20, 20);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.imageScaling = NSImageScaleProportionallyDown;
	button.focusRingType = NSFocusRingTypeNone;
	button.toolTip = toolTip;
	button.autoresizingMask = NSViewMinYMargin;
	[self.window.contentView addSubview:button];
	return button;
}

- (NSSlider *)globalSliderAtY:(CGFloat)y minimum:(double)minimum maximum:(double)maximum action:(SEL)action
{
	NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(35, y, 124, 18)];
	slider.minValue = minimum;
	slider.maxValue = maximum;
	slider.controlSize = NSControlSizeMini;
	slider.continuous = YES;
	slider.target = self;
	slider.action = action;
	slider.autoresizingMask = NSViewMinYMargin;
	[self.window.contentView addSubview:slider];
	return slider;
}

- (void)addGlobalIcon:(PPMixerGlobalIconKind)kind y:(CGFloat)y toView:(NSView *)view
{
	PPMixerGlobalIconView *icon = [[PPMixerGlobalIconView alloc] initWithFrame:NSMakeRect(7, y, 22, 18)];
	icon.kind = kind;
	icon.autoresizingMask = NSViewMinYMargin;
	[view addSubview:icon];
}

- (NSButton *)globalResetButtonAtY:(CGFloat)y tag:(NSInteger)tag
{
	NSButton *button = [NSButton buttonWithTitle:@"R" target:self action:@selector(resetGlobalControl:)];
	button.frame = NSMakeRect(176, y, 20, 18);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.controlSize = NSControlSizeMini;
	button.font = [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightBold];
	button.focusRingType = NSFocusRingTypeNone;
	button.tag = tag;
	button.autoresizingMask = NSViewMinYMargin;
	[self.window.contentView addSubview:button];
	return button;
}

- (void)buildWindow
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(230, 120, 375, 278)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = @"Mixer";
	window.contentMinSize = NSMakeSize(375, 278);
	window.contentMaxSize = NSMakeSize(375, 1400);
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.backgroundColor = [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	self.window = window;
	PPMixerContentView *content = [[PPMixerContentView alloc] initWithFrame:NSMakeRect(0, 0, 375, 278)];
	content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	window.contentView = content;

	// Four compact toolbar buttons followed by the active effect name match the
	// 2002 mixer. Reset remains available through the settings files and menu.
	[self iconButton:152 x:4 action:@selector(loadSettings:) toolTip:@"Load mixer settings"];
	[self iconButton:151 x:28 action:@selector(saveSettings:) toolTip:@"Save mixer settings"];
	[self iconButton:172 x:52 action:@selector(adaptStereo:) toolTip:@"Adapt track panning from the first track"];
	[self iconButton:212 x:76 action:@selector(showFineSettings:) toolTip:@"Fine settings and PlayerPRO reverb"];
	self.effectTitleField = [self label:@"" frame:NSMakeRect(108, 255, 254, 14) inView:content];
	self.effectTitleField.alignment = NSTextAlignmentCenter;
	self.effectTitleField.font = [NSFont fontWithName:@"Monaco" size:10] ?: PPMixerClassicFont();
	self.effectTitleField.autoresizingMask = NSViewMinYMargin;

	NSTextField *globalTitle = [self label:@"Global" frame:NSMakeRect(0, 229, 375, 14) inView:content];
	globalTitle.alignment = NSTextAlignmentCenter;
	globalTitle.font = [NSFont fontWithName:@"Monaco" size:10] ?: PPMixerClassicFont();
	globalTitle.autoresizingMask = NSViewMinYMargin;

	[self addGlobalIcon:PPMixerGlobalIconPitch y:201 toView:content];
	NSTextField *pitchLabel = [self label:@"Pitch:" frame:NSMakeRect(29, 203, 47, 14) inView:content];
	pitchLabel.autoresizingMask = NSViewMinYMargin;
	self.pitchSlider = [self globalSliderAtY:201 minimum:160 maximum:16000 action:@selector(changePitch:)];
	self.pitchSlider.frame = NSMakeRect(76, 201, 94, 18);
	[self globalResetButtonAtY:201 tag:0];
	self.pitchField = [NSTextField labelWithString:@"100 %"];

	[self addGlobalIcon:PPMixerGlobalIconSpeed y:180 toView:content];
	NSTextField *speedLabel = [self label:@"Speed:" frame:NSMakeRect(29, 182, 47, 14) inView:content];
	speedLabel.autoresizingMask = NSViewMinYMargin;
	self.speedSlider = [self globalSliderAtY:180 minimum:160 maximum:16000 action:@selector(changeSpeed:)];
	self.speedSlider.frame = NSMakeRect(76, 180, 94, 18);
	[self globalResetButtonAtY:180 tag:1];
	self.speedField = [NSTextField labelWithString:@"100 %"];

	[self addGlobalIcon:PPMixerGlobalIconPanning y:159 toView:content];
	NSTextField *panningLabel = [self label:@"Panning:" frame:NSMakeRect(29, 161, 47, 14) inView:content];
	panningLabel.autoresizingMask = NSViewMinYMargin;
	self.masterPanSlider = [self globalSliderAtY:159 minimum:0 maximum:128 action:@selector(changeMasterPan:)];
	self.masterPanSlider.frame = NSMakeRect(76, 159, 94, 18);
	[self globalResetButtonAtY:159 tag:2];
	self.masterPanField = [NSTextField labelWithString:@"Center"];

	NSTextField *hardLabel = [self label:@"hard 🔊" frame:NSMakeRect(199, 203, 46, 14) inView:content];
	hardLabel.autoresizingMask = NSViewMinYMargin;
	NSSlider *hardVolume = [[NSSlider alloc] initWithFrame:NSMakeRect(246, 201, 120, 18)];
	hardVolume.minValue = 0; hardVolume.maxValue = 128; hardVolume.integerValue = 64;
	hardVolume.controlSize = NSControlSizeMini; hardVolume.enabled = NO;
	hardVolume.toolTip = @"Classic hardware volume (not applicable to Core Audio)";
	hardVolume.autoresizingMask = NSViewMinYMargin;
	[content addSubview:hardVolume];

	NSTextField *softLabel = [self label:@"soft 🔊" frame:NSMakeRect(199, 182, 46, 14) inView:content];
	softLabel.autoresizingMask = NSViewMinYMargin;
	self.masterVolumeSlider = [self globalSliderAtY:180 minimum:0 maximum:128 action:@selector(changeMasterVolume:)];
	self.masterVolumeSlider.frame = NSMakeRect(246, 180, 120, 18);
	self.masterVolumeField = [NSTextField labelWithString:@"100 %"];

	self.tempoField = [self label:@"BPM: --- / ---" frame:NSMakeRect(199, 161, 167, 14) inView:content];
	self.tempoField.alignment = NSTextAlignmentCenter;
	self.tempoField.autoresizingMask = NSViewMinYMargin;

	NSTextField *fxLabel = [self label:@"FX:" frame:NSMakeRect(7, 142, 26, 14) inView:content];
	fxLabel.font = [NSFont fontWithName:@"Monaco-Bold" size:10] ?: PPMixerClassicFont();
	fxLabel.autoresizingMask = NSViewMinYMargin;
	self.globalFXToggle = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleGlobalEffects:)];
	self.globalFXToggle.frame = NSMakeRect(31, 139, 20, 18);
	self.globalFXToggle.controlSize = NSControlSizeMini;
	self.globalFXToggle.toolTip = @"Enable the global effect bus";
	self.globalFXToggle.autoresizingMask = NSViewMinYMargin;
	[content addSubview:self.globalFXToggle];
	self.globalEffectButtons = [NSMutableArray arrayWithCapacity:10];
	for (NSInteger slot = 0; slot < 10; slot++) {
		NSButton *button = [NSButton buttonWithTitle:@"E" target:self action:@selector(showGlobalEffectMenu:)];
		button.frame = NSMakeRect(54 + slot * 24, 140, 21, 18);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.controlSize = NSControlSizeMini;
		button.font = PPMixerClassicFont();
		button.focusRingType = NSFocusRingTypeNone;
		button.tag = slot;
		button.autoresizingMask = NSViewMinYMargin;
		button.toolTip = [NSString stringWithFormat:@"Global effect slot %ld", (long)slot + 1];
		[content addSubview:button];
		[self.globalEffectButtons addObject:button];
	}

	// The portable engine's original reverb stays available in Fine Settings.
	self.reverbToggle = [NSButton checkboxWithTitle:@"PlayerPRO Reverb" target:self action:@selector(reverbControlChanged:)];
	self.reverbToggle.font = PPMixerClassicFont();
	self.reverbDelaySlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
	self.reverbDelaySlider.minValue = 25; self.reverbDelaySlider.maxValue = 1000;
	self.reverbDelaySlider.controlSize = NSControlSizeMini; self.reverbDelaySlider.continuous = NO;
	self.reverbDelaySlider.target = self; self.reverbDelaySlider.action = @selector(reverbControlChanged:);
	self.reverbDelayField = [NSTextField labelWithString:@"100 ms"];
	self.reverbStrengthSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
	self.reverbStrengthSlider.minValue = 0; self.reverbStrengthSlider.maxValue = 70;
	self.reverbStrengthSlider.controlSize = NSControlSizeMini; self.reverbStrengthSlider.continuous = NO;
	self.reverbStrengthSlider.target = self; self.reverbStrengthSlider.action = @selector(reverbControlChanged:);
	self.reverbStrengthField = [NSTextField labelWithString:@"20 %"];

	NSTextField *tracksTitle = [self label:@"Tracks" frame:NSMakeRect(0, 120, 375, 14) inView:content];
	tracksTitle.alignment = NSTextAlignmentCenter;
	tracksTitle.font = [NSFont fontWithName:@"Monaco" size:10] ?: PPMixerClassicFont();
	tracksTitle.autoresizingMask = NSViewMinYMargin;
	NSArray<NSString *> *headers = @[@"Track ID", @"Volume", @"Panning", @"FX - (VST Plugs)", @"Activity"];
	NSArray<NSNumber *> *headerXs = @[@2, @63, @155, @222, @321];
	NSArray<NSNumber *> *headerWidths = @[@55, @70, @65, @99, @52];
	for (NSInteger index = 0; index < headers.count; index++) {
		NSTextField *header = [self label:headers[index]
			frame:NSMakeRect(headerXs[index].doubleValue, 100, headerWidths[index].doubleValue, 14) inView:content];
		header.autoresizingMask = NSViewMinYMargin;
		if (index == headers.count - 1)
			header.font = [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightRegular];
	}
	self.channelScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 15, 375, 83)];
	self.channelScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.channelScroll.hasVerticalScroller = YES;
	self.channelScroll.borderType = NSLineBorder;
	self.channelScroll.scrollerStyle = NSScrollerStyleLegacy;
	[content addSubview:self.channelScroll];
	[self rebuildChannelRows];
	[self refreshFromDriver];
	[self configureBuiltinEffectsFromMusic];
}

- (void)attachMusic:(MADMusic *)music driver:(MADDriverRec *)driver
{
	self.music = music;
	self.driver = driver;
	[self rebuildChannelRows];
	[self refreshFromDriver];
	[self configureBuiltinEffectsFromMusic];
}

- (void)rebuildChannelRows
{
	NSInteger channels = self.music == NULL || self.music->header == NULL ? 0 : self.music->header->numChn;
	CGFloat documentHeight = MAX(NSHeight(self.channelScroll.contentView.bounds), channels * 20.0);
	PPMixerFlippedView *document = [[PPMixerFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 358, documentHeight)];
	document.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	self.activeButtons = [NSMutableArray arrayWithCapacity:channels];
	self.monoButtons = [NSMutableArray arrayWithCapacity:channels];
	self.volumeSliders = [NSMutableArray arrayWithCapacity:channels];
	self.panSliders = [NSMutableArray arrayWithCapacity:channels];
	self.volumeFields = [NSMutableArray arrayWithCapacity:channels];
	self.panFields = [NSMutableArray arrayWithCapacity:channels];
	self.meters = [NSMutableArray arrayWithCapacity:channels];
	self.trackFXToggles = [NSMutableArray arrayWithCapacity:channels];
	self.trackEffectButtons = [NSMutableArray arrayWithCapacity:channels * 4];
	self.trackEffectSettingsButtons = [NSMutableArray arrayWithCapacity:channels];
	for (NSInteger channel = 0; channel < channels; channel++) {
		CGFloat y = channel * 20;
		NSTextField *track = [self label:[NSString stringWithFormat:@"%03ld", (long)channel + 1]
			frame:NSMakeRect(3, y + 2, 35, 15) inView:document];
		track.alignment = NSTextAlignmentCenter;
		track.drawsBackground = YES;
		track.backgroundColor = PPPreferredTrackColor(channel);
		track.bordered = YES;

		NSButton *active = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleChannelActive:)];
		active.frame = NSMakeRect(39, y + 1, 20, 18); active.tag = channel; active.controlSize = NSControlSizeMini;
		active.toolTip = @"Option-click to solo this track or restore all tracks";
		[document addSubview:active]; [self.activeButtons addObject:active];

		NSSlider *volume = [[NSSlider alloc] initWithFrame:NSMakeRect(62, y + 2, 68, 16)];
		volume.minValue = 0; volume.maxValue = MAX_CHANVOL; volume.tag = channel;
		volume.controlSize = NSControlSizeMini; volume.continuous = YES;
		volume.target = self; volume.action = @selector(changeChannelVolume:);
		volume.toolTip = @"Track volume; Option-drag applies to all tracks";
		[document addSubview:volume]; [self.volumeSliders addObject:volume];
		NSTextField *volumeValue = [NSTextField labelWithString:@"100"];
		[self.volumeFields addObject:volumeValue];

		NSButton *mono = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleChannelMono:)];
		mono.frame = NSMakeRect(134, y + 1, 20, 18); mono.tag = channel; mono.controlSize = NSControlSizeMini;
		mono.toolTip = @"Center this track; Option-click centers every track";
		[document addSubview:mono]; [self.monoButtons addObject:mono];

		NSSlider *pan = [[NSSlider alloc] initWithFrame:NSMakeRect(157, y + 2, 64, 16)];
		pan.minValue = 0; pan.maxValue = MAX_PANNING; pan.tag = channel;
		pan.controlSize = NSControlSizeMini; pan.continuous = YES;
		pan.target = self; pan.action = @selector(changeChannelPan:);
		pan.toolTip = @"Track panning; Option-drag mirrors it across alternating tracks";
		[document addSubview:pan]; [self.panSliders addObject:pan];
		NSTextField *panValue = [NSTextField labelWithString:@"C"];
		[self.panFields addObject:panValue];

		NSButton *trackFX = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleTrackEffects:)];
		trackFX.frame = NSMakeRect(222, y + 1, 20, 18);
		trackFX.controlSize = NSControlSizeMini;
		trackFX.tag = channel;
		trackFX.toolTip = @"Enable this track's effect bus";
		[document addSubview:trackFX];
		[self.trackFXToggles addObject:trackFX];

		for (NSInteger slot = 0; slot < 4; slot++) {
			NSButton *effect = [NSButton buttonWithTitle:@"E" target:self action:@selector(showTrackEffectMenu:)];
			effect.frame = NSMakeRect(242 + slot * 17, y + 2, 16, 16);
			effect.bezelStyle = NSBezelStyleSmallSquare;
			effect.controlSize = NSControlSizeMini;
			effect.font = [NSFont monospacedSystemFontOfSize:7 weight:NSFontWeightRegular];
			effect.focusRingType = NSFocusRingTypeNone;
			effect.tag = channel * 4 + slot;
			effect.toolTip = [NSString stringWithFormat:@"Track %ld effect slot %ld", (long)channel + 1, (long)slot + 1];
			[document addSubview:effect];
			[self.trackEffectButtons addObject:effect];
		}
		NSButton *settings = [NSButton buttonWithTitle:@"•" target:self action:@selector(showTrackEffectSettings:)];
		settings.frame = NSMakeRect(310, y + 2, 15, 16);
		settings.bezelStyle = NSBezelStyleSmallSquare;
		settings.controlSize = NSControlSizeMini;
		settings.font = PPMixerClassicFont();
		settings.focusRingType = NSFocusRingTypeNone;
		settings.tag = channel;
		settings.toolTip = @"Track effect information";
		[document addSubview:settings];
		[self.trackEffectSettingsButtons addObject:settings];

		PPMixerMeterView *meter = [[PPMixerMeterView alloc] initWithFrame:NSMakeRect(328, y + 2, 29, 16)];
		meter.track = channel; meter.instrument = -1;
		[document addSubview:meter]; [self.meters addObject:meter];
	}
	self.channelScroll.documentView = document;
}

- (NSString *)panString:(NSInteger)value center:(NSInteger)center
{
	if (value == center) return @"C";
	NSInteger percent = (NSInteger)llround(100.0 * fabs((double)value - center) / MAX(center, 1));
	return [NSString stringWithFormat:@"%@%ld", value < center ? @"L" : @"R", (long)percent];
}

- (NSString *)nameForEffectID:(uint32_t)effectID
{
	if (effectID == PP_BUILTIN_FREEVERB_ID) return @"Freeverb";
	if (effectID == PP_BUILTIN_DJ_FILTER_ID) return @"DJ Filter";
	if (effectID == PP_BUILTIN_COMPRESSOR_ID) return @"Compressor";
	return effectID == 0 ? @"No Effect" : @"Unknown Effect";
}

- (BOOL)isSupportedEffectID:(uint32_t)effectID
{
	return effectID == PP_BUILTIN_FREEVERB_ID || effectID == PP_BUILTIN_DJ_FILTER_ID ||
		effectID == PP_BUILTIN_COMPRESSOR_ID;
}

- (FXSets *)effectSetForTrack:(NSInteger)track slot:(NSInteger)slot effectID:(uint32_t)effectID
{
	if (self.music == NULL || self.music->sets == NULL || effectID == 0) return NULL;
	for (NSInteger index = 0; index < MAXTRACK; index++) {
		FXSets *set = &self.music->sets[index];
		if (set->track == track && set->id == slot && (uint32_t)set->FXID == effectID) return set;
	}
	return NULL;
}

- (void)effectValuesForTrack:(NSInteger)track slot:(NSInteger)slot effectID:(uint32_t)effectID
	values:(float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values
{
	PPMixerDefaultEffectValues(effectID, values);
	FXSets *set = [self effectSetForTrack:track slot:slot effectID:effectID];
	if (set != NULL) memcpy(values, set->values, sizeof(float) * PP_BUILTIN_EFFECT_PARAMETER_COUNT);
}

- (void)synchronizeEffectSets
{
	if (self.music == NULL || self.music->header == NULL || self.music->sets == NULL) return;
	FXSets *previous = calloc(MAXTRACK, sizeof(FXSets));
	if (previous == NULL) return;
	memcpy(previous, self.music->sets, MAXTRACK * sizeof(FXSets));
	memset(self.music->sets, 0, MAXTRACK * sizeof(FXSets));
	NSInteger output = 0;

	for (NSInteger pass = 0; pass < 2; pass++) {
		NSInteger tracks = pass == 0 ? 1 : MAXTRACK;
		NSInteger slots = pass == 0 ? 10 : 4;
		for (NSInteger trackIndex = 0; trackIndex < tracks; trackIndex++) {
			NSInteger track = pass == 0 ? -1 : trackIndex;
			for (NSInteger slot = 0; slot < slots; slot++) {
				uint32_t effectID = pass == 0 ? (uint32_t)self.music->header->globalEffect[slot]
					: (uint32_t)self.music->header->chanEffect[track][slot];
				if (effectID == 0 || output >= MAXTRACK) continue;
				FXSets *set = &self.music->sets[output++];
				BOOL copied = NO;
				for (NSInteger old = 0; old < MAXTRACK; old++) {
					if ((uint32_t)previous[old].FXID == effectID && previous[old].track == track && previous[old].id == slot) {
						*set = previous[old];
						copied = YES;
						break;
					}
				}
				set->track = (short)track;
				set->id = (short)slot;
				set->FXID = (int)effectID;
				if ([self isSupportedEffectID:effectID]) {
					if (!copied) PPMixerDefaultEffectValues(effectID, set->values);
					const char *name = effectID == PP_BUILTIN_FREEVERB_ID ? "Freeverb" :
						(effectID == PP_BUILTIN_DJ_FILTER_ID ? "DJ Filter" : "Compressor");
					set->noArg = effectID == PP_BUILTIN_FREEVERB_ID ? 7 :
						(effectID == PP_BUILTIN_DJ_FILTER_ID ? 1 : 5);
					size_t length = strlen(name);
					memset(set->name, 0, sizeof(set->name));
					set->name[0] = (unsigned char)MIN(length, sizeof(set->name) - 1);
					memcpy(&set->name[1], name, set->name[0]);
				}
			}
		}
	}
	free(previous);
}

- (void)configureBuiltinEffectsFromMusic
{
	if (self.driver == NULL) return;
	bool trackEnabled[MAXTRACK] = {false};
	PPBuiltinEffectSlot globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS] = {0};
	PPBuiltinEffectSlot (*trackSlots)[PP_BUILTIN_TRACK_EFFECT_SLOTS] = calloc(MAXTRACK, sizeof(*trackSlots));
	BOOL globalEnabled = NO;
	if (self.music != NULL && self.music->header != NULL) {
		for (NSInteger slot = 0; slot < PP_BUILTIN_GLOBAL_EFFECT_SLOTS; slot++) {
			uint32_t effectID = (uint32_t)self.music->header->globalEffect[slot];
			if (![self isSupportedEffectID:effectID]) continue;
			globalSlots[slot].effectID = effectID;
			[self effectValuesForTrack:-1 slot:slot effectID:effectID values:globalSlots[slot].values];
			globalEnabled = YES;
		}
		globalEnabled &= self.music->header->globalFXActive;
		NSInteger channels = MIN((NSInteger)self.music->header->numChn, (NSInteger)MAXTRACK);
		for (NSInteger track = 0; track < channels; track++) {
			BOOL hasEffect = NO;
			for (NSInteger slot = 0; slot < PP_BUILTIN_TRACK_EFFECT_SLOTS; slot++) {
				uint32_t effectID = (uint32_t)self.music->header->chanEffect[track][slot];
				if (![self isSupportedEffectID:effectID] || trackSlots == NULL) continue;
				trackSlots[track][slot].effectID = effectID;
				[self effectValuesForTrack:track slot:slot effectID:effectID values:trackSlots[track][slot].values];
				hasEffect = YES;
			}
			trackEnabled[track] = hasEffect && self.music->header->chanBus[track].Active &&
				!self.music->header->chanBus[track].ByPass;
		}
	}
	MADConfigureBuiltinEffectChains(self.driver, globalEnabled, globalSlots,
		trackEnabled, trackSlots, MAXTRACK);
	free(trackSlots);
}

- (void)refreshEffectControls
{
	BOOL hasMusic = self.music != NULL && self.music->header != NULL;
	self.globalFXToggle.enabled = hasMusic;
	self.globalFXToggle.state = hasMusic && self.music->header->globalFXActive ? NSControlStateValueOn : NSControlStateValueOff;
	NSString *displayName = @"";
	for (NSInteger slot = 0; slot < (NSInteger)self.globalEffectButtons.count; slot++) {
		uint32_t effectID = hasMusic ? (uint32_t)self.music->header->globalEffect[slot] : 0;
		NSButton *button = self.globalEffectButtons[slot];
		button.enabled = hasMusic;
		button.contentTintColor = effectID == 0 ? NSColor.disabledControlTextColor : NSColor.controlAccentColor;
		if (effectID != 0 && displayName.length == 0) displayName = [self nameForEffectID:effectID];
	}
	NSInteger channels = hasMusic ? self.music->header->numChn : 0;
	for (NSInteger track = 0; track < channels && track < (NSInteger)self.trackFXToggles.count; track++) {
		self.trackFXToggles[track].state = self.music->header->chanBus[track].Active &&
			!self.music->header->chanBus[track].ByPass ? NSControlStateValueOn : NSControlStateValueOff;
		for (NSInteger slot = 0; slot < 4; slot++) {
			uint32_t effectID = (uint32_t)self.music->header->chanEffect[track][slot];
			NSButton *button = self.trackEffectButtons[track * 4 + slot];
			button.contentTintColor = effectID == 0 ? NSColor.disabledControlTextColor : NSColor.controlAccentColor;
			if (effectID != 0 && displayName.length == 0) displayName = [self nameForEffectID:effectID];
		}
	}
	self.effectTitleField.stringValue = displayName;
}

- (void)presentEffectMenuForButton:(NSButton *)button track:(NSInteger)track slot:(NSInteger)slot
{
	if (self.music == NULL || self.music->header == NULL) return;
	BOOL global = track < 0;
	uint32_t currentID = global ? (uint32_t)self.music->header->globalEffect[slot]
		: (uint32_t)self.music->header->chanEffect[track][slot];
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Effect"];
	NSMenuItem *selected = nil;
	for (NSDictionary *choice in @[
		@{@"title": @"No Effect", @"id": @0},
		@{@"title": @"Freeverb", @"id": @(PP_BUILTIN_FREEVERB_ID)},
		@{@"title": @"DJ Filter", @"id": @(PP_BUILTIN_DJ_FILTER_ID)},
		@{@"title": @"Compressor", @"id": @(PP_BUILTIN_COMPRESSOR_ID)}
	]) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:choice[@"title"] action:@selector(chooseEffect:) keyEquivalent:@""];
		item.target = self;
		item.representedObject = @{@"track": @(track), @"slot": @(slot), @"id": choice[@"id"]};
		if ([choice[@"id"] unsignedIntValue] == currentID) {
			item.state = NSControlStateValueOn;
			selected = item;
		}
		[menu addItem:item];
	}
	self.effectTitleField.stringValue = [self nameForEffectID:currentID];
	[menu popUpMenuPositioningItem:selected atLocation:NSMakePoint(0, NSHeight(button.bounds)) inView:button];
}

- (IBAction)showGlobalEffectMenu:(NSButton *)sender
{
	[self presentEffectMenuForButton:sender track:-1 slot:sender.tag];
}

- (IBAction)showTrackEffectMenu:(NSButton *)sender
{
	[self presentEffectMenuForButton:sender track:sender.tag / 4 slot:sender.tag % 4];
}

- (IBAction)chooseEffect:(NSMenuItem *)sender
{
	if (self.music == NULL || self.music->header == NULL) return;
	NSDictionary *selection = sender.representedObject;
	NSInteger track = [selection[@"track"] integerValue];
	NSInteger slot = [selection[@"slot"] integerValue];
	uint32_t effectID = [selection[@"id"] unsignedIntValue];
	if (effectID == 0) {
		[self commitEffectID:0 track:track slot:slot values:NULL];
		return;
	}
	uint32_t currentID = track < 0 ? (uint32_t)self.music->header->globalEffect[slot]
		: (uint32_t)self.music->header->chanEffect[track][slot];
	float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
	if (currentID == effectID) [self effectValuesForTrack:track slot:slot effectID:effectID values:values];
	else {
		PPMixerDefaultEffectValues(effectID, values);
		[self commitEffectID:effectID track:track slot:slot values:values];
	}
	[self presentEditorForEffectID:effectID track:track slot:slot values:values];
}

- (void)commitEffectID:(uint32_t)effectID track:(NSInteger)track slot:(NSInteger)slot
	values:(const float *)values
{
	if (self.music == NULL || self.music->header == NULL) return;
	if (track < 0) {
		if (slot < 0 || slot >= PP_BUILTIN_GLOBAL_EFFECT_SLOTS) return;
		self.music->header->globalEffect[slot] = (int)effectID;
		if (effectID != 0) self.music->header->globalFXActive = true;
	} else if (track < self.music->header->numChn && slot >= 0 && slot < PP_BUILTIN_TRACK_EFFECT_SLOTS) {
		self.music->header->chanEffect[track][slot] = (int)effectID;
		self.music->header->chanBus[track].copyId = (short)track;
		if (effectID != 0) {
			self.music->header->chanBus[track].Active = true;
			self.music->header->chanBus[track].ByPass = false;
		}
	}
	self.music->hasChanged = true;
	[self synchronizeEffectSets];
	if (effectID != 0 && values != NULL) {
		FXSets *set = [self effectSetForTrack:track slot:slot effectID:effectID];
		if (set != NULL) memcpy(set->values, values, sizeof(float) * PP_BUILTIN_EFFECT_PARAMETER_COUNT);
	}
	[self configureBuiltinEffectsFromMusic];
	[self refreshEffectControls];
	self.effectTitleField.stringValue = [self nameForEffectID:effectID];
}

- (void)updateEffectID:(uint32_t)effectID track:(NSInteger)track slot:(NSInteger)slot
	values:(const float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values
{
	if (self.music == NULL || self.music->header == NULL || values == NULL) return;
	uint32_t currentID = track < 0
		? (slot >= 0 && slot < PP_BUILTIN_GLOBAL_EFFECT_SLOTS
			? (uint32_t)self.music->header->globalEffect[slot] : 0)
		: (track < self.music->header->numChn && slot >= 0 &&
			slot < PP_BUILTIN_TRACK_EFFECT_SLOTS
			? (uint32_t)self.music->header->chanEffect[track][slot] : 0);
	if (currentID != effectID) return;
	FXSets *set = [self effectSetForTrack:track slot:slot effectID:effectID];
	if (set == NULL) {
		[self synchronizeEffectSets];
		set = [self effectSetForTrack:track slot:slot effectID:effectID];
	}
	if (set != NULL) memcpy(set->values, values,
		sizeof(float) * PP_BUILTIN_EFFECT_PARAMETER_COUNT);
	self.music->hasChanged = true;
	if (!MADUpdateBuiltinEffectParameters(self.driver, track < 0,
		track < 0 ? 0 : (size_t)track, (size_t)slot, effectID, values)) {
		[self configureBuiltinEffectsFromMusic];
	}
}

- (void)presentEditorForEffectID:(uint32_t)effectID track:(NSInteger)track slot:(NSInteger)slot
	values:(const float[PP_BUILTIN_EFFECT_PARAMETER_COUNT])values
{
	if (![self isSupportedEffectID:effectID]) return;
	PPMixerEffectEditorView *editor = [[PPMixerEffectEditorView alloc] initWithEffectID:effectID values:values];
	__weak typeof(self) weakSelf = self;
	editor.valuesChangedHandler = ^(const float changedValues[PP_BUILTIN_EFFECT_PARAMETER_COUNT]) {
		[weakSelf updateEffectID:effectID track:track slot:slot values:changedValues];
	};
	NSAlert *alert = [[NSAlert alloc] init];
	NSString *location = track < 0 ? [NSString stringWithFormat:@"Global Slot %ld", (long)slot + 1]
		: [NSString stringWithFormat:@"Track %ld, Slot %ld", (long)track + 1, (long)slot + 1];
	alert.messageText = [NSString stringWithFormat:@"%@ — %@", [self nameForEffectID:effectID], location];
	if (effectID == PP_BUILTIN_DJ_FILTER_ID) {
		alert.informativeText = @"Move left for a low-pass sweep, use the center detent for bypass, or move right for a high-pass sweep.";
	} else if (effectID == PP_BUILTIN_COMPRESSOR_ID) {
		alert.informativeText = @"Stereo-linked dynamics processing with threshold, ratio, attack, release, and makeup gain.";
	} else {
		alert.informativeText = @"Adjust the basic Freeverb room, damping, wet, and dry controls.";
	}
	[alert addButtonWithTitle:@"Close"];
	alert.accessoryView = editor;
	dispatch_async(dispatch_get_main_queue(), ^{
		[alert beginSheetModalForWindow:self.window completionHandler:nil];
	});
}

- (IBAction)toggleGlobalEffects:(NSButton *)sender
{
	if (self.music == NULL || self.music->header == NULL) return;
	self.music->header->globalFXActive = sender.state == NSControlStateValueOn;
	self.music->hasChanged = true;
	[self configureBuiltinEffectsFromMusic];
}

- (IBAction)toggleTrackEffects:(NSButton *)sender
{
	if (self.music == NULL || self.music->header == NULL || sender.tag < 0 || sender.tag >= self.music->header->numChn) return;
	self.music->header->chanBus[sender.tag].copyId = (short)sender.tag;
	self.music->header->chanBus[sender.tag].Active = sender.state == NSControlStateValueOn;
	self.music->header->chanBus[sender.tag].ByPass = sender.state != NSControlStateValueOn;
	self.music->hasChanged = true;
	[self configureBuiltinEffectsFromMusic];
}

- (IBAction)showTrackEffectSettings:(NSButton *)sender
{
	if (self.music == NULL || self.music->header == NULL || sender.tag < 0 || sender.tag >= self.music->header->numChn) return;
	for (NSInteger slot = 0; slot < PP_BUILTIN_TRACK_EFFECT_SLOTS; slot++) {
		uint32_t effectID = (uint32_t)self.music->header->chanEffect[sender.tag][slot];
		if (![self isSupportedEffectID:effectID]) continue;
		float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
		[self effectValuesForTrack:sender.tag slot:slot effectID:effectID values:values];
		[self presentEditorForEffectID:effectID track:sender.tag slot:slot values:values];
		return;
	}
	NSBeep();
}

- (void)refreshFromDriver
{
	if (self.driver == NULL) {
		[self refreshEffectControls];
		return;
	}
	self.masterVolumeSlider.integerValue = self.driver->base.VolGlobal;
	self.masterPanSlider.integerValue = self.driver->globPan;
	self.pitchSlider.integerValue = self.driver->base.FreqExt;
	self.speedSlider.integerValue = self.driver->base.VExt;
	self.reverbToggle.state = self.driver->DriverSettings.Reverb ? NSControlStateValueOn : NSControlStateValueOff;
	self.reverbDelaySlider.integerValue = self.driver->DriverSettings.ReverbSize;
	self.reverbStrengthSlider.integerValue = self.driver->DriverSettings.ReverbStrength;
	[self updateGlobalValueLabels];
	NSInteger channels = self.music == NULL || self.music->header == NULL ? 0 : self.music->header->numChn;
	if (self.volumeSliders.count != channels) [self rebuildChannelRows];
	for (NSInteger channel = 0; channel < channels; channel++) {
		NSInteger volume = self.music->header->chanVol[channel];
		NSInteger pan = self.music->header->chanPan[channel];
		self.activeButtons[channel].state = self.driver->base.Active[channel] ? NSControlStateValueOn : NSControlStateValueOff;
		self.volumeSliders[channel].integerValue = volume;
		self.volumeFields[channel].integerValue = (100 * volume) / 64;
		self.monoButtons[channel].state = pan == MAX_PANNING / 2 ? NSControlStateValueOn : NSControlStateValueOff;
		self.panSliders[channel].integerValue = pan;
		self.panFields[channel].stringValue = [self panString:pan center:MAX_PANNING / 2];
	}
	[self refreshEffectControls];
}

- (void)updateGlobalValueLabels
{
	if (self.driver == NULL) return;
	self.masterVolumeField.stringValue = [NSString stringWithFormat:@"%ld %%", (long)(100 * self.driver->base.VolGlobal) / 64];
	self.masterPanField.stringValue = [self panString:self.driver->globPan center:64];
	double pitch = self.driver->base.FreqExt == 0 ? 0 : 100.0 * 8000.0 / self.driver->base.FreqExt;
	double speed = 100.0 * self.driver->base.VExt / 8000.0;
	self.pitchField.stringValue = [NSString stringWithFormat:@"%.1f %%", pitch];
	self.speedField.stringValue = [NSString stringWithFormat:@"%.1f %%", speed];
	NSInteger displayedTempo = self.driver->base.finespeed;
	NSInteger displayedSpeed = self.driver->base.speed;
	if (!MADWasReading(self.driver)) {
		PPMixerInitialTempoAndSpeed(self.music, &displayedTempo, &displayedSpeed);
	}
	self.tempoField.stringValue = [NSString stringWithFormat:@"BPM: %03ld / %03ld",
		(long)displayedTempo, (long)displayedSpeed];
	self.reverbDelayField.stringValue = [NSString stringWithFormat:@"%ld ms", (long)self.reverbDelaySlider.integerValue];
	self.reverbStrengthField.stringValue = [NSString stringWithFormat:@"%ld %%", (long)self.reverbStrengthSlider.integerValue];
}

- (void)updateMeters:(NSTimer *)timer
{
	(void)timer;
	if (!self.window.isVisible || self.driver == NULL || self.music == NULL) return;
	NSInteger channels = MIN((NSInteger)self.music->header->numChn, (NSInteger)self.meters.count);
	for (NSInteger channel = 0; channel < channels; channel++) {
		PPMixerMeterView *meter = self.meters[channel];
		NSInteger tube = self.driver->base.Tube[channel];
		meter.level = self.driver->base.Active[channel] ? MIN(MAX((tube + 46.0) / 110.0, 0.04), 1.0) : 0.0;
		meter.instrument = self.driver->base.chan[channel].ins;
		[meter setNeedsDisplay:YES];
	}
	[self updateGlobalValueLabels];
}

- (IBAction)changeMasterVolume:(NSSlider *)sender
{
	if (self.driver == NULL) return;
	self.driver->base.VolGlobal = (short)sender.integerValue;
	[self updateGlobalValueLabels];
}

- (IBAction)changeMasterPan:(NSSlider *)sender
{
	if (self.driver == NULL) return;
	self.driver->globPan = (int)sender.integerValue;
	if (self.music != NULL) self.music->hasChanged = true;
	[self updateGlobalValueLabels];
}

- (IBAction)changePitch:(NSSlider *)sender
{
	if (self.driver == NULL) return;
	self.driver->base.FreqExt = (short)sender.integerValue;
	if (self.music != NULL) self.music->hasChanged = true;
	[self updateGlobalValueLabels];
}

- (IBAction)changeSpeed:(NSSlider *)sender
{
	if (self.driver == NULL) return;
	self.driver->base.VExt = (short)sender.integerValue;
	if (self.music != NULL) self.music->hasChanged = true;
	[self updateGlobalValueLabels];
}

- (IBAction)resetGlobalControl:(NSButton *)sender
{
	if (self.driver == NULL) return;
	if (sender.tag == 0) {
		self.pitchSlider.integerValue = 8000;
		[self changePitch:self.pitchSlider];
	} else if (sender.tag == 1) {
		self.speedSlider.integerValue = 8000;
		[self changeSpeed:self.speedSlider];
	} else {
		self.masterPanSlider.integerValue = 64;
		[self changeMasterPan:self.masterPanSlider];
	}
}

- (IBAction)changeChannelVolume:(NSSlider *)sender
{
	if (self.music == NULL || sender.tag < 0 || sender.tag >= self.music->header->numChn) return;
	NSInteger value = sender.integerValue;
	BOOL all = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) != 0;
	for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
		if (!all && channel != sender.tag) continue;
		self.music->header->chanVol[channel] = (MADByte)value;
		self.volumeSliders[channel].integerValue = value;
		self.volumeFields[channel].integerValue = (100 * value) / 64;
	}
	self.music->hasChanged = true;
}

- (IBAction)changeChannelPan:(NSSlider *)sender
{
	if (self.music == NULL || self.driver == NULL || sender.tag < 0 || sender.tag >= self.music->header->numChn) return;
	NSInteger value = sender.integerValue;
	BOOL all = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) != 0;
	for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
		if (!all && channel != sender.tag) continue;
		NSInteger channelValue = all && channel % 2 != sender.tag % 2 ? MAX_PANNING - value : value;
		self.music->header->chanPan[channel] = (MADByte)channelValue;
		self.driver->base.chan[channel].pann = (short)channelValue;
		self.panSliders[channel].integerValue = channelValue;
		self.panFields[channel].stringValue = [self panString:channelValue center:MAX_PANNING / 2];
		self.monoButtons[channel].state = channelValue == MAX_PANNING / 2 ? NSControlStateValueOn : NSControlStateValueOff;
	}
	self.music->hasChanged = true;
}

- (IBAction)toggleChannelMono:(NSButton *)sender
{
	if (self.music == NULL || self.driver == NULL || sender.tag < 0 || sender.tag >= self.music->header->numChn) return;
	BOOL all = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) != 0;
	for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
		if (!all && channel != sender.tag) continue;
		self.music->header->chanPan[channel] = MAX_PANNING / 2;
		self.driver->base.chan[channel].pann = MAX_PANNING / 2;
		self.panSliders[channel].integerValue = MAX_PANNING / 2;
		self.panFields[channel].stringValue = @"C";
		self.monoButtons[channel].state = NSControlStateValueOn;
	}
	self.music->hasChanged = true;
}

- (IBAction)toggleChannelActive:(NSButton *)sender
{
	if (self.music == NULL || self.driver == NULL || sender.tag < 0 || sender.tag >= self.music->header->numChn) return;
	BOOL solo = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagOption) != 0;
	if (solo) {
		BOOL onlySelected = self.driver->base.Active[sender.tag];
		for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
			if (channel != sender.tag && self.driver->base.Active[channel]) onlySelected = NO;
		}
		for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
			self.driver->base.Active[channel] = onlySelected ? true : channel == sender.tag;
			self.activeButtons[channel].state = self.driver->base.Active[channel] ? NSControlStateValueOn : NSControlStateValueOff;
		}
	} else {
		self.driver->base.Active[sender.tag] = sender.state == NSControlStateValueOn;
	}
}

- (IBAction)adaptStereo:(id)sender
{
	(void)sender;
	if (self.music == NULL || self.driver == NULL || self.music->header->numChn == 0) return;
	NSInteger first = self.music->header->chanPan[0];
	for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
		NSInteger value = channel % 2 == 0 ? first : MAX_PANNING - first;
		self.music->header->chanPan[channel] = (MADByte)value;
		self.driver->base.chan[channel].pann = (short)value;
	}
	self.music->hasChanged = true;
	[self refreshFromDriver];
}

- (IBAction)resetMixer:(id)sender
{
	(void)sender;
	if (self.driver == NULL) return;
	self.driver->base.VolGlobal = 64;
	self.driver->globPan = 64;
	self.driver->base.FreqExt = 8000;
	self.driver->base.VExt = 8000;
	if (self.music != NULL) {
		memset(self.music->header->globalEffect, 0, sizeof(self.music->header->globalEffect));
		memset(self.music->header->chanEffect, 0, sizeof(self.music->header->chanEffect));
		self.music->header->globalFXActive = false;
		for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
			self.music->header->chanVol[channel] = 64;
			self.music->header->chanPan[channel] = MAX_PANNING / 2;
			self.music->header->chanBus[channel].Active = false;
			self.music->header->chanBus[channel].ByPass = false;
			self.music->header->chanBus[channel].copyId = (short)channel;
			self.driver->base.chan[channel].pann = MAX_PANNING / 2;
			self.driver->base.Active[channel] = true;
		}
		self.music->hasChanged = true;
		[self synchronizeEffectSets];
	}
	[self configureBuiltinEffectsFromMusic];
	[self refreshFromDriver];
}

- (IBAction)showFineSettings:(id)sender
{
	(void)sender;
	if (self.driver == NULL) return;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Fine Mixer Settings";
	alert.informativeText = @"Pitch and speed use PlayerPRO's original 8000-unit scale. This reverb is the portable engine's original effect, separate from Freeverb slots.";
	[alert addButtonWithTitle:@"Apply"];
	[alert addButtonWithTitle:@"Cancel"];
	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 134)];
	[self label:@"Pitch %:" frame:NSMakeRect(0, 110, 70, 16) inView:accessory];
	NSTextField *pitch = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%.1f", 100.0 * 8000.0 / self.driver->base.FreqExt]];
	pitch.frame = NSMakeRect(76, 107, 90, 22); pitch.font = PPMixerClassicFont(); pitch.textColor = NSColor.blackColor; pitch.backgroundColor = NSColor.whiteColor;
	[accessory addSubview:pitch];
	[self label:@"Speed %:" frame:NSMakeRect(0, 82, 70, 16) inView:accessory];
	NSTextField *speed = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%.1f", 100.0 * self.driver->base.VExt / 8000.0]];
	speed.frame = NSMakeRect(76, 79, 90, 22); speed.font = PPMixerClassicFont(); speed.textColor = NSColor.blackColor; speed.backgroundColor = NSColor.whiteColor;
	[accessory addSubview:speed];
	NSButton *reverb = [NSButton checkboxWithTitle:@"PlayerPRO Reverb" target:nil action:nil];
	reverb.frame = NSMakeRect(0, 51, 170, 20); reverb.font = PPMixerClassicFont();
	reverb.state = self.reverbToggle.state;
	[accessory addSubview:reverb];
	[self label:@"Delay (ms):" frame:NSMakeRect(0, 29, 76, 16) inView:accessory];
	NSTextField *delay = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)self.reverbDelaySlider.integerValue]];
	delay.frame = NSMakeRect(76, 26, 64, 22); delay.font = PPMixerClassicFont(); delay.textColor = NSColor.blackColor; delay.backgroundColor = NSColor.whiteColor;
	[accessory addSubview:delay];
	[self label:@"Strength %:" frame:NSMakeRect(0, 3, 76, 16) inView:accessory];
	NSTextField *strength = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)self.reverbStrengthSlider.integerValue]];
	strength.frame = NSMakeRect(76, 0, 64, 22); strength.font = PPMixerClassicFont(); strength.textColor = NSColor.blackColor; strength.backgroundColor = NSColor.whiteColor;
	[accessory addSubview:strength];
	alert.accessoryView = accessory;
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn || self.driver == NULL) return;
		double pitchPercent = pitch.doubleValue;
		double speedPercent = speed.doubleValue;
		NSInteger pitchValue = pitchPercent > 0 ? (NSInteger)llround(800000.0 / pitchPercent) : 0;
		NSInteger speedValue = (NSInteger)llround(80.0 * speedPercent);
		NSInteger delayValue = delay.integerValue;
		NSInteger strengthValue = strength.integerValue;
		if (pitchValue < 160 || pitchValue > 16000 || speedValue < 160 || speedValue > 16000 ||
			delayValue < 25 || delayValue > 1000 || strengthValue < 0 || strengthValue > 70) { NSBeep(); return; }
		self.driver->base.FreqExt = (short)pitchValue;
		self.driver->base.VExt = (short)speedValue;
		self.reverbToggle.state = reverb.state;
		self.reverbDelaySlider.integerValue = delayValue;
		self.reverbStrengthSlider.integerValue = strengthValue;
		if (self.music != NULL) self.music->hasChanged = true;
		[self reverbControlChanged:nil];
		[self refreshFromDriver];
	}];
}

- (IBAction)reverbControlChanged:(id)sender
{
	(void)sender;
	[self updateGlobalValueLabels];
	if (self.reverbHandler != nil) {
		self.reverbHandler(self.reverbToggle.state == NSControlStateValueOn,
			self.reverbDelaySlider.integerValue, self.reverbStrengthSlider.integerValue);
	}
}

- (NSDictionary *)settingsDictionary
{
	NSMutableArray *volumes = [NSMutableArray array];
	NSMutableArray *pans = [NSMutableArray array];
	NSMutableArray *globalEffects = [NSMutableArray arrayWithCapacity:10];
	NSMutableArray *globalEffectParameters = [NSMutableArray arrayWithCapacity:10];
	NSMutableArray *trackEffects = [NSMutableArray array];
	NSMutableArray *trackEffectParameters = [NSMutableArray array];
	NSMutableArray *trackFXActive = [NSMutableArray array];
	if (self.music != NULL) {
		for (NSInteger slot = 0; slot < 10; slot++) {
			uint32_t effectID = (uint32_t)self.music->header->globalEffect[slot];
			[globalEffects addObject:@(effectID)];
			float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
			[self effectValuesForTrack:-1 slot:slot effectID:effectID values:values];
			NSMutableArray *parameters = [NSMutableArray arrayWithCapacity:PP_BUILTIN_EFFECT_PARAMETER_COUNT];
			for (NSInteger value = 0; value < PP_BUILTIN_EFFECT_PARAMETER_COUNT; value++) [parameters addObject:@(values[value])];
			[globalEffectParameters addObject:parameters];
		}
		for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
			[volumes addObject:@(self.music->header->chanVol[channel])];
			[pans addObject:@(self.music->header->chanPan[channel])];
			NSMutableArray *effects = [NSMutableArray arrayWithCapacity:4];
			NSMutableArray *effectParameters = [NSMutableArray arrayWithCapacity:4];
			for (NSInteger slot = 0; slot < 4; slot++) {
				uint32_t effectID = (uint32_t)self.music->header->chanEffect[channel][slot];
				[effects addObject:@(effectID)];
				float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
				[self effectValuesForTrack:channel slot:slot effectID:effectID values:values];
				NSMutableArray *parameters = [NSMutableArray arrayWithCapacity:PP_BUILTIN_EFFECT_PARAMETER_COUNT];
				for (NSInteger value = 0; value < PP_BUILTIN_EFFECT_PARAMETER_COUNT; value++) [parameters addObject:@(values[value])];
				[effectParameters addObject:parameters];
			}
			[trackEffects addObject:effects];
			[trackEffectParameters addObject:effectParameters];
			[trackFXActive addObject:@(self.music->header->chanBus[channel].Active && !self.music->header->chanBus[channel].ByPass)];
		}
	}
	return @{
		@"version": @3, @"channelVolumes": volumes, @"channelPans": pans,
		@"masterVolume": @(self.driver == NULL ? 64 : self.driver->base.VolGlobal),
		@"masterPan": @(self.driver == NULL ? 64 : self.driver->globPan),
		@"pitch": @(self.driver == NULL ? 8000 : self.driver->base.FreqExt),
		@"speed": @(self.driver == NULL ? 8000 : self.driver->base.VExt),
		@"reverb": @(self.reverbToggle.state == NSControlStateValueOn),
		@"reverbDelay": @(self.reverbDelaySlider.integerValue),
		@"reverbStrength": @(self.reverbStrengthSlider.integerValue),
		@"globalFXActive": @(self.music != NULL && self.music->header->globalFXActive),
		@"globalEffects": globalEffects,
		@"globalEffectParameters": globalEffectParameters,
		@"trackEffects": trackEffects,
		@"trackEffectParameters": trackEffectParameters,
		@"trackFXActive": trackFXActive
	};
}

- (NSData *)legacyTuningData
{
	if (self.music == NULL || self.music->header == NULL || self.driver == NULL) return nil;
	[self synchronizeEffectSets];
	NSMutableData *data = [NSMutableData data];
	// SaveAdaptorsFile() wrote this structure directly on PowerPC. Keep its
	// original big-endian field order, including the now-unused hardware volume.
	[data appendBytes:self.music->header->chanVol length:MAXTRACK];
	[data appendBytes:self.music->header->chanPan length:MAXTRACK];
	PPMixerAppend16(data, (uint16_t)self.driver->base.FreqExt);
	PPMixerAppend16(data, 256); // Classic 100% hardware-volume preference.
	PPMixerAppend16(data, (uint16_t)self.driver->base.VExt);
	PPMixerAppend32(data, (uint32_t)self.driver->base.VolGlobal);
	PPMixerAppend32(data, (uint32_t)self.driver->globPan);
	for (NSInteger slot = 0; slot < 10; slot++) PPMixerAppend32(data, (uint32_t)self.music->header->globalEffect[slot]);
	uint8_t enabled = self.music->header->globalFXActive ? 1 : 0;
	[data appendBytes:&enabled length:1];
	for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
		for (NSInteger slot = 0; slot < 4; slot++) PPMixerAppend32(data, (uint32_t)self.music->header->chanEffect[channel][slot]);
	}
	for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
		FXBus bus = self.music->header->chanBus[channel];
		uint8_t prefix[2] = {bus.ByPass ? 1 : 0, 0};
		uint8_t suffix[2] = {bus.Active ? 1 : 0, 0};
		[data appendBytes:prefix length:sizeof(prefix)];
		PPMixerAppend16(data, (uint16_t)bus.copyId);
		[data appendBytes:suffix length:sizeof(suffix)];
	}
	NSInteger effectCount = 0;
	for (NSInteger slot = 0; slot < 10; slot++) if (self.music->header->globalEffect[slot] != 0) effectCount++;
	for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
		for (NSInteger slot = 0; slot < 4; slot++) if (self.music->header->chanEffect[channel][slot] != 0) effectCount++;
	}
	for (NSInteger index = 0; self.music->sets != NULL && index < MIN(effectCount, MAXTRACK); index++) {
		FXSets *set = &self.music->sets[index];
		PPMixerAppend16(data, (uint16_t)set->track);
		PPMixerAppend16(data, (uint16_t)set->id);
		PPMixerAppend32(data, (uint32_t)set->FXID);
		PPMixerAppend16(data, (uint16_t)set->noArg);
		for (NSInteger value = 0; value < 100; value++) {
			union { float floating; uint32_t bits; } encoded = {.floating = set->values[value]};
			PPMixerAppend32(data, encoded.bits);
		}
		[data appendBytes:set->name length:sizeof(set->name)];
	}
	return data;
}

- (BOOL)loadLegacyTuningData:(NSData *)data
{
	// Through globPan, the common portion is 526 bytes. Later revisions append
	// VST routing and parameter sets; those fields are accepted when present.
	if (data.length < 526 || self.music == NULL || self.music->header == NULL || self.driver == NULL) return NO;
	const uint8_t *bytes = data.bytes;
	uint16_t pitchBE = PPMixerRead16(bytes + 512, NO);
	uint16_t pitchLE = PPMixerRead16(bytes + 512, YES);
	uint32_t volumeBE = PPMixerRead32(bytes + 518, NO);
	uint32_t volumeLE = PPMixerRead32(bytes + 518, YES);
	BOOL bigPlausible = pitchBE > 0 && pitchBE <= 16000 && volumeBE <= 128;
	BOOL littlePlausible = pitchLE > 0 && pitchLE <= 16000 && volumeLE <= 128;
	BOOL littleEndian = littlePlausible && !bigPlausible;
	if (!bigPlausible && !littlePlausible) return NO;

	memcpy(self.music->header->chanVol, bytes, MAXTRACK);
	memcpy(self.music->header->chanPan, bytes + MAXTRACK, MAXTRACK);
	NSInteger pitch = PPMixerRead16(bytes + 512, littleEndian);
	NSInteger speed = PPMixerRead16(bytes + 516, littleEndian);
	if (pitch <= 160) pitch *= 100;
	if (speed <= 160) speed *= 100;
	NSInteger volume = PPMixerRead32(bytes + 518, littleEndian);
	NSInteger pan = PPMixerRead32(bytes + 522, littleEndian);
	self.driver->base.FreqExt = (short)MIN(MAX(pitch, 160), 16000);
	self.driver->base.VExt = (short)MIN(MAX(speed, 160), 16000);
	self.driver->base.VolGlobal = (short)MIN(MAX(volume, 0), 128);
	self.driver->globPan = (int)MIN(MAX(pan, 0), 128);
	for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
		self.music->header->chanVol[channel] = MIN(self.music->header->chanVol[channel], MAX_CHANVOL);
		self.music->header->chanPan[channel] = MIN(self.music->header->chanPan[channel], MAX_PANNING);
		self.driver->base.chan[channel].pann = self.music->header->chanPan[channel];
	}
	self.music->header->generalVol = (MADByte)self.driver->base.VolGlobal;
	self.music->header->generalPan = (MADByte)self.driver->globPan;
	self.music->header->generalSpeed = 252;
	self.music->header->ESpeed = self.driver->base.VExt;
	self.music->header->EPitch = self.driver->base.FreqExt;

	NSUInteger offset = 526;
	NSUInteger routingBytes = 10 * 4 + 1 + MAXTRACK * 4 * 4 + MAXTRACK * 6;
	if (data.length >= offset + routingBytes) {
		for (NSInteger slot = 0; slot < 10; slot++, offset += 4) {
			self.music->header->globalEffect[slot] = (int)PPMixerRead32(bytes + offset, littleEndian);
		}
		self.music->header->globalFXActive = bytes[offset++] != 0;
		for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
			for (NSInteger slot = 0; slot < 4; slot++, offset += 4) {
				self.music->header->chanEffect[channel][slot] = (int)PPMixerRead32(bytes + offset, littleEndian);
			}
		}
		for (NSInteger channel = 0; channel < MAXTRACK; channel++, offset += 6) {
			self.music->header->chanBus[channel].ByPass = bytes[offset] != 0;
			NSInteger copy = PPMixerRead16(bytes + offset + 2, littleEndian);
			self.music->header->chanBus[channel].copyId = (short)(copy < MAXTRACK ? copy : channel);
			self.music->header->chanBus[channel].Active = bytes[offset + 4] != 0;
		}
		NSInteger effectCount = 0;
		for (NSInteger slot = 0; slot < 10; slot++) if (self.music->header->globalEffect[slot] != 0) effectCount++;
		for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
			for (NSInteger slot = 0; slot < 4; slot++) if (self.music->header->chanEffect[channel][slot] != 0) effectCount++;
		}
		const NSUInteger setSize = 474;
		if (self.music->sets != NULL) memset(self.music->sets, 0, sizeof(FXSets) * MAXTRACK);
		for (NSInteger index = 0; self.music->sets != NULL && index < MIN(effectCount, MAXTRACK) && offset + setSize <= data.length; index++, offset += setSize) {
			FXSets *set = &self.music->sets[index];
			set->track = (short)PPMixerRead16(bytes + offset, littleEndian);
			set->id = (short)PPMixerRead16(bytes + offset + 2, littleEndian);
			set->FXID = (int)PPMixerRead32(bytes + offset + 4, littleEndian);
			set->noArg = (short)PPMixerRead16(bytes + offset + 8, littleEndian);
			for (NSInteger value = 0; value < 100; value++) {
				union { uint32_t bits; float floating; } decoded = {.bits = PPMixerRead32(bytes + offset + 10 + value * 4, littleEndian)};
				set->values[value] = decoded.floating;
			}
			memcpy(set->name, bytes + offset + 410, sizeof(set->name));
		}
	}
	self.music->hasChanged = true;
	[self configureBuiltinEffectsFromMusic];
	[self refreshFromDriver];
	return YES;
}

- (IBAction)saveSettings:(id)sender
{
	(void)sender;
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = @"Mixer Settings.tuni";
	panel.allowedFileTypes = @[@"tuni", @"ppmixer"];
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		BOOL legacy = [panel.URL.pathExtension.lowercaseString isEqualToString:@"tuni"];
		NSData *data = legacy ? [self legacyTuningData] :
			[NSPropertyListSerialization dataWithPropertyList:[self settingsDictionary]
				format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
		[data writeToURL:panel.URL atomically:YES];
	}];
}

- (IBAction)loadSettings:(id)sender
{
	(void)sender;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedFileTypes = @[@"tuni", @"ppmixer"];
	panel.allowsMultipleSelection = NO;
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK || self.driver == NULL) return;
		NSData *data = [NSData dataWithContentsOfURL:panel.URL];
		NSDictionary *settings = data == nil ? nil : [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
		if (![settings isKindOfClass:NSDictionary.class]) {
			if (![self loadLegacyTuningData:data]) NSBeep();
			return;
		}
		NSArray *volumes = settings[@"channelVolumes"];
		NSArray *pans = settings[@"channelPans"];
		NSArray *globalEffects = settings[@"globalEffects"];
		NSArray *globalEffectParameters = settings[@"globalEffectParameters"];
		NSArray *trackEffects = settings[@"trackEffects"];
		NSArray *trackEffectParameters = settings[@"trackEffectParameters"];
		NSArray *trackFXActive = settings[@"trackFXActive"];
		if (self.music != NULL) {
			if ([globalEffects isKindOfClass:NSArray.class]) {
				for (NSInteger slot = 0; slot < 10; slot++) self.music->header->globalEffect[slot] =
					slot < (NSInteger)globalEffects.count ? (int)[globalEffects[slot] unsignedIntValue] : 0;
				self.music->header->globalFXActive = [settings[@"globalFXActive"] boolValue];
			}
			for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
				if (channel < (NSInteger)volumes.count) self.music->header->chanVol[channel] = (MADByte)MIN(MAX([volumes[channel] integerValue], 0), MAX_CHANVOL);
				if (channel < (NSInteger)pans.count) {
					self.music->header->chanPan[channel] = (MADByte)MIN(MAX([pans[channel] integerValue], 0), MAX_PANNING);
					self.driver->base.chan[channel].pann = self.music->header->chanPan[channel];
				}
				if (channel < (NSInteger)trackEffects.count && [trackEffects[channel] isKindOfClass:NSArray.class]) {
					NSArray *effects = trackEffects[channel];
					for (NSInteger slot = 0; slot < 4; slot++) self.music->header->chanEffect[channel][slot] =
						slot < (NSInteger)effects.count ? (int)[effects[slot] unsignedIntValue] : 0;
					BOOL active = channel < (NSInteger)trackFXActive.count && [trackFXActive[channel] boolValue];
					self.music->header->chanBus[channel].Active = active;
					self.music->header->chanBus[channel].ByPass = !active;
					self.music->header->chanBus[channel].copyId = (short)channel;
				}
			}
			[self synchronizeEffectSets];
			for (NSInteger slot = 0; slot < 10 && slot < (NSInteger)globalEffectParameters.count; slot++) {
				NSArray *parameters = globalEffectParameters[slot];
				uint32_t effectID = (uint32_t)self.music->header->globalEffect[slot];
				FXSets *set = [self effectSetForTrack:-1 slot:slot effectID:effectID];
				if (set == NULL || ![parameters isKindOfClass:NSArray.class]) continue;
				for (NSInteger value = 0; value < PP_BUILTIN_EFFECT_PARAMETER_COUNT && value < (NSInteger)parameters.count; value++) {
					set->values[value] = [parameters[value] floatValue];
				}
			}
			for (NSInteger channel = 0; channel < self.music->header->numChn && channel < (NSInteger)trackEffectParameters.count; channel++) {
				NSArray *slots = trackEffectParameters[channel];
				if (![slots isKindOfClass:NSArray.class]) continue;
				for (NSInteger slot = 0; slot < 4 && slot < (NSInteger)slots.count; slot++) {
					NSArray *parameters = slots[slot];
					uint32_t effectID = (uint32_t)self.music->header->chanEffect[channel][slot];
					FXSets *set = [self effectSetForTrack:channel slot:slot effectID:effectID];
					if (set == NULL || ![parameters isKindOfClass:NSArray.class]) continue;
					for (NSInteger value = 0; value < PP_BUILTIN_EFFECT_PARAMETER_COUNT && value < (NSInteger)parameters.count; value++) {
						set->values[value] = [parameters[value] floatValue];
					}
				}
			}
			self.music->hasChanged = true;
		}
		self.driver->base.VolGlobal = (short)MIN(MAX([settings[@"masterVolume"] integerValue], 0), 128);
		self.driver->globPan = (int)MIN(MAX([settings[@"masterPan"] integerValue], 0), 128);
		self.driver->base.FreqExt = (short)MIN(MAX([settings[@"pitch"] integerValue], 160), 16000);
		self.driver->base.VExt = (short)MIN(MAX([settings[@"speed"] integerValue], 160), 16000);
		self.reverbToggle.state = [settings[@"reverb"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
		self.reverbDelaySlider.integerValue = MIN(MAX([settings[@"reverbDelay"] integerValue], 25), 1000);
		self.reverbStrengthSlider.integerValue = MIN(MAX([settings[@"reverbStrength"] integerValue], 0), 70);
		[self reverbControlChanged:nil];
		[self configureBuiltinEffectsFromMusic];
		[self refreshFromDriver];
	}];
}

@end
