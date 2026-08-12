#import "PPEqualizerController.h"

#include "RDriver.h"
#include "RDriverInt.h"
#include <math.h>

static const NSUInteger PPEqualizerBin[PP_EQUALIZER_BAND_COUNT] = {
	0, 16, 32, 64, 128, 256, 512, EQPACKET * 2
};

static double PPEqualizerClamp(double value)
{
	if (!isfinite(value)) return 1.0;
	return MIN(MAX(value, 0.0), 2.0);
}

void PPSetEqualizerBands(MADDriverRec *driver,
	const double *bands, bool enabled)
{
	if (driver == NULL || driver->Filter == NULL || bands == NULL) return;
	bool wasEnabled = driver->base.Equalizer;
	driver->base.Equalizer = false;
	for (NSInteger segment = 0; segment < PP_EQUALIZER_BAND_COUNT - 1; segment++) {
		NSUInteger first = PPEqualizerBin[segment];
		NSUInteger last = PPEqualizerBin[segment + 1];
		double start = PPEqualizerClamp(bands[segment]);
		double end = PPEqualizerClamp(bands[segment + 1]);
		for (NSUInteger bin = first; bin <= last; bin++) {
			double amount = last == first ? 0.0 : (double)(bin - first) / (double)(last - first);
			driver->Filter[bin] = start + (end - start) * amount;
		}
	}
	driver->Filter[EQPACKET * 2 + 1] = driver->Filter[EQPACKET * 2];
	if (wasEnabled != enabled) MADResetOutputEqualizer(driver);
	driver->base.Equalizer = enabled;
}

@interface PPEqualizerFlippedView : NSView
@end

@implementation PPEqualizerFlippedView
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
}
@end

@interface PPEqualizerController ()
{
	double _bands[PP_EQUALIZER_BAND_COUNT];
}
@property(nonatomic) MADDriverRec *driver;
@property(nonatomic, strong) NSButton *enabledButton;
@property(nonatomic, strong) NSMutableArray<NSSlider *> *sliders;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *frequencyFields;
@property(nonatomic, strong) NSMutableArray<NSTextField *> *valueFields;
@end

@implementation PPEqualizerController

- (instancetype)initWithDriver:(MADDriverRec *)driver
{
	NSPanel *window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 354)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
			NSWindowStyleMaskMiniaturizable
		backing:NSBackingStoreBuffered defer:NO];
	self = [super initWithWindow:window];
	if (self == nil) return nil;
	for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) _bands[band] = 1.0;
	window.title = @"Equalizer";
	window.floatingPanel = YES;
	window.becomesKeyOnlyIfNeeded = NO;
	window.level = NSFloatingWindowLevel;
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	window.backgroundColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
	window.contentView = [[PPEqualizerFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 440, 354)];
	[self buildControls];
	[self attachDriver:driver];
	[window center];
	return self;
}

- (NSFont *)classicFont
{
	return [NSFont fontWithName:@"Monaco" size:10] ?:
		[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
}

- (NSImage *)classicImageNamed:(NSString *)name
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	return path == nil ? [[NSImage alloc] initWithSize:NSMakeSize(20, 20)] :
		[[NSImage alloc] initWithContentsOfFile:path];
}

- (NSButton *)squareButtonAtX:(CGFloat)x image:(NSString *)image action:(SEL)action toolTip:(NSString *)toolTip
{
	NSButton *button = [NSButton buttonWithImage:[self classicImageNamed:image] target:self action:action];
	button.frame = NSMakeRect(x, 10, 36, 30);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.toolTip = toolTip;
	[self.window.contentView addSubview:button];
	return button;
}

- (void)buildControls
{
	NSView *content = self.window.contentView;
	self.enabledButton = [NSButton buttonWithTitle:@"ON" target:self action:@selector(toggleEqualizer:)];
	self.enabledButton.frame = NSMakeRect(12, 10, 42, 30);
	self.enabledButton.buttonType = NSButtonTypePushOnPushOff;
	self.enabledButton.bezelStyle = NSBezelStyleSmallSquare;
	self.enabledButton.font = [self classicFont];
	self.enabledButton.toolTip = @"Enable or bypass the output equalizer";
	[content addSubview:self.enabledButton];
	[self squareButtonAtX:64 image:@"save" action:@selector(saveEqualizer:) toolTip:@"Save equalizer settings"];
	[self squareButtonAtX:106 image:@"load" action:@selector(loadEqualizer:) toolTip:@"Load equalizer settings"];

	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(10, 48, 420, 1)];
	separator.boxType = NSBoxSeparator;
	[content addSubview:separator];
	self.sliders = [NSMutableArray arrayWithCapacity:PP_EQUALIZER_BAND_COUNT];
	self.frequencyFields = [NSMutableArray arrayWithCapacity:PP_EQUALIZER_BAND_COUNT];
	self.valueFields = [NSMutableArray arrayWithCapacity:PP_EQUALIZER_BAND_COUNT];
	for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) {
		CGFloat y = 58 + band * 36;
		NSTextField *frequency = [NSTextField labelWithString:@""];
		frequency.frame = NSMakeRect(12, y + 3, 88, 18);
		frequency.font = [self classicFont];
		frequency.textColor = NSColor.blackColor;
		[content addSubview:frequency];
		[self.frequencyFields addObject:frequency];

		NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(102, y, 250, 22)];
		slider.minValue = 0.0;
		slider.maxValue = 2.0;
		slider.doubleValue = 1.0;
		slider.continuous = YES;
		slider.tag = band;
		slider.target = self;
		slider.action = @selector(equalizerSliderChanged:);
		[content addSubview:slider];
		[self.sliders addObject:slider];

		NSTextField *value = [NSTextField labelWithString:@"100 %"];
		value.frame = NSMakeRect(360, y + 3, 68, 18);
		value.font = [self classicFont];
		value.textColor = NSColor.blackColor;
		value.alignment = NSTextAlignmentRight;
		[content addSubview:value];
		[self.valueFields addObject:value];
	}
}

- (NSString *)frequencyLabelForBand:(NSInteger)band
{
	double sampleRate = self.driver == NULL || self.driver->DriverSettings.outPutRate == 0
		? 44100.0 : self.driver->DriverSettings.outPutRate;
	double frequency = (sampleRate * 0.5) * (double)PPEqualizerBin[band] / (double)(EQPACKET * 2);
	if (frequency >= 1000.0) return [NSString stringWithFormat:@"%.1f kHz", frequency / 1000.0];
	return [NSString stringWithFormat:@"%.1f Hz", floor(frequency)];
}

- (void)refreshControls
{
	BOOL available = self.driver != NULL && self.driver->Filter != NULL;
	self.enabledButton.enabled = available;
	for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) {
		self.sliders[band].enabled = available;
		self.sliders[band].doubleValue = _bands[band];
		self.frequencyFields[band].stringValue = [self frequencyLabelForBand:band];
		self.valueFields[band].stringValue = [NSString stringWithFormat:@"%.0f %%", _bands[band] * 100.0];
	}
}

- (void)applyBands
{
	PPSetEqualizerBands(self.driver, _bands, self.enabledButton.state == NSControlStateValueOn);
}

- (void)attachDriver:(MADDriverRec *)driver
{
	BOOL enabled = self.enabledButton.state == NSControlStateValueOn;
	self.driver = driver;
	[self refreshControls];
	PPSetEqualizerBands(driver, _bands, enabled);
}

- (IBAction)toggleEqualizer:(NSButton *)sender
{
	(void)sender;
	[self applyBands];
}

- (IBAction)equalizerSliderChanged:(NSSlider *)sender
{
	if (sender.tag < 0 || sender.tag >= PP_EQUALIZER_BAND_COUNT) return;
	_bands[sender.tag] = PPEqualizerClamp(sender.doubleValue);
	self.valueFields[sender.tag].stringValue = [NSString stringWithFormat:@"%.0f %%", _bands[sender.tag] * 100.0];
	[self applyBands];
}

- (IBAction)saveEqualizer:(id)sender
{
	(void)sender;
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = @"Equalizer Settings.ppeq";
	panel.allowedFileTypes = @[@"ppeq"];
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		NSMutableArray *bands = [NSMutableArray arrayWithCapacity:PP_EQUALIZER_BAND_COUNT];
		for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) [bands addObject:@(self->_bands[band])];
		NSDictionary *settings = @{@"version": @1, @"enabled": @(self.enabledButton.state == NSControlStateValueOn), @"bands": bands};
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:settings
			format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
		[data writeToURL:panel.URL atomically:YES];
	}];
}

- (IBAction)loadEqualizer:(id)sender
{
	(void)sender;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowedFileTypes = @[@"ppeq"];
	panel.allowsMultipleSelection = NO;
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		NSData *data = [NSData dataWithContentsOfURL:panel.URL];
		NSDictionary *settings = data == nil ? nil : [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
		NSArray *bands = [settings isKindOfClass:NSDictionary.class] ? settings[@"bands"] : nil;
		if (![bands isKindOfClass:NSArray.class] || bands.count < PP_EQUALIZER_BAND_COUNT) { NSBeep(); return; }
		for (NSInteger band = 0; band < PP_EQUALIZER_BAND_COUNT; band++) self->_bands[band] = PPEqualizerClamp([bands[band] doubleValue]);
		self.enabledButton.state = [settings[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
		[self refreshControls];
		[self applyBands];
	}];
}

@end
