#import "PPInstrumentEditorController.h"

enum {
	PPEnvelopeOn = 1,
	PPEnvelopeSustain = 2,
	PPEnvelopeLoop = 4,
	PPEnvelopeFixedSpeed = 8
};

typedef struct {
	char name[32];
	long loopBeg;
	long loopSize;
	Byte vol;
	unsigned short c2spd;
	Byte loopType;
	char realNote;
} PPSampleMetadata;

@interface PPInstrumentSnapshot : NSObject
@property(nonatomic, strong) NSData *instrumentData;
@property(nonatomic, strong) NSArray<NSData *> *sampleMetadata;
@property(nonatomic) NSInteger selectedSample;
@end

@implementation PPInstrumentSnapshot
@end

@interface PPSmallPianoView : NSView
@property(nonatomic) InstrData *instrument;
@property(nonatomic) NSInteger selectedSample;
@property(nonatomic) NSInteger pressedNote;
@property(nonatomic, copy) void (^noteHandler)(NSInteger note, BOOL assigning);
@property(nonatomic, copy) dispatch_block_t assignmentWillBegin;
@property(nonatomic, copy) dispatch_block_t assignmentDidEnd;
@end

@implementation PPSmallPianoView

- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (self != nil) {
		_pressedNote = -1;
		_selectedSample = -1;
	}
	return self;
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)isBlackNote:(NSInteger)note
{
	switch (note % 12) {
		case 1: case 3: case 6: case 8: case 10: return YES;
		default: return NO;
	}
}

- (NSInteger)whiteIndexForSemitone:(NSInteger)semitone
{
	static const NSInteger indexes[12] = {0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6};
	return indexes[semitone % 12];
}

- (NSRect)rectForNote:(NSInteger)note
{
	CGFloat whiteWidth = NSWidth(self.bounds) / 56.0;
	NSInteger octave = note / 12;
	NSInteger semitone = note % 12;
	NSInteger white = [self whiteIndexForSemitone:semitone];
	if (![self isBlackNote:note]) {
		return NSMakeRect((octave * 7 + white) * whiteWidth, 0, ceil(whiteWidth), NSHeight(self.bounds));
	}
	CGFloat boundary = (octave * 7 + white + 1) * whiteWidth;
	CGFloat blackWidth = MAX(4.0, floor(whiteWidth * 0.58));
	CGFloat blackHeight = floor(NSHeight(self.bounds) * 0.62);
	return NSMakeRect(round(boundary - blackWidth / 2.0), NSHeight(self.bounds) - blackHeight,
		blackWidth, blackHeight);
}

- (NSColor *)assignmentColorForNote:(NSInteger)note black:(BOOL)black
{
	if (note == self.pressedNote) {
		return [NSColor colorWithCalibratedRed:1.0 green:0.88 blue:0.12 alpha:1.0];
	}
	if (self.instrument != NULL && self.selectedSample >= 0 &&
		self.instrument->what[note] == self.selectedSample) {
		return black ? [NSColor colorWithCalibratedRed:0.65 green:0.05 blue:0.05 alpha:1.0]
			: [NSColor colorWithCalibratedRed:1.0 green:0.28 blue:0.24 alpha:1.0];
	}
	return black ? [NSColor colorWithCalibratedWhite:0.08 alpha:1.0] : NSColor.whiteColor;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		if ([self isBlackNote:note]) continue;
		NSRect key = [self rectForNote:note];
		[[self assignmentColorForNote:note black:NO] setFill];
		NSRectFill(key);
		[NSColor.blackColor setStroke];
		NSFrameRectWithWidth(key, 1.0);
	}
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		if (![self isBlackNote:note]) continue;
		NSRect key = [self rectForNote:note];
		[[self assignmentColorForNote:note black:YES] setFill];
		NSRectFill(key);
		[NSColor.blackColor setStroke];
		NSFrameRectWithWidth(key, 1.0);
	}
}

- (NSInteger)noteAtPoint:(NSPoint)point
{
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		if ([self isBlackNote:note] && NSPointInRect(point, [self rectForNote:note])) return note;
	}
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		if (![self isBlackNote:note] && NSPointInRect(point, [self rectForNote:note])) return note;
	}
	return -1;
}

- (void)mouseDown:(NSEvent *)event
{
	BOOL assigning = (event.modifierFlags & NSEventModifierFlagOption) != 0;
	if (assigning && self.assignmentWillBegin != nil) self.assignmentWillBegin();
	NSInteger previousNote = -1;
	NSEvent *current = event;
	for (;;) {
		NSPoint point = [self convertPoint:current.locationInWindow fromView:nil];
		NSInteger note = [self noteAtPoint:point];
		if (note >= 0 && note != previousNote) {
			self.pressedNote = note;
			[self setNeedsDisplay:YES];
			if (self.noteHandler != nil) self.noteHandler(note, assigning);
			previousNote = note;
		}
		if (current.type == NSEventTypeLeftMouseUp) break;
		current = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
	}
	self.pressedNote = -1;
	[self setNeedsDisplay:YES];
	if (assigning && self.assignmentDidEnd != nil) self.assignmentDidEnd();
}

@end

@interface PPInstrumentEditorController () <NSWindowDelegate, NSTextFieldDelegate>
@property(nonatomic) MADMusic *music;
@property(nonatomic) MADDriverRec *driver;
@property(nonatomic) NSInteger instrument;
@property(nonatomic) NSInteger selectedSample;
@property(nonatomic, strong) NSTextField *instrumentNameField;
@property(nonatomic, strong) NSTextField *fadeField;
@property(nonatomic, strong) NSArray<NSButton *> *envelopeButtons;
@property(nonatomic, strong) NSPopUpButton *samplePopup;
@property(nonatomic, strong) NSTextField *sampleNameField;
@property(nonatomic, strong) NSTextField *loopStartField;
@property(nonatomic, strong) NSTextField *loopLengthField;
@property(nonatomic, strong) NSTextField *volumeField;
@property(nonatomic, strong) NSTextField *rateField;
@property(nonatomic, strong) NSTextField *relativeNoteField;
@property(nonatomic, strong) NSPopUpButton *loopTypePopup;
@property(nonatomic, strong) NSTextField *formatField;
@property(nonatomic, strong) NSTextField *noteField;
@property(nonatomic, strong) PPSmallPianoView *piano;
@property(nonatomic, strong, nullable) PPInstrumentSnapshot *mappingSnapshot;
@property(nonatomic) BOOL mappingChanged;
@property(nonatomic, copy) PPInstrumentEditorHandler changeHandler;
@property(nonatomic, copy) PPInstrumentEditorHandler closeHandler;
@end

@implementation PPInstrumentEditorController

- (instancetype)initWithMusic:(MADMusic *)music driver:(MADDriverRec *)driver instrument:(NSInteger)instrument
	sample:(NSInteger)sample changeHandler:(PPInstrumentEditorHandler)changeHandler
	closeHandler:(PPInstrumentEditorHandler)closeHandler
{
	self = [super initWithWindow:nil];
	if (self == nil) return nil;
	_music = music;
	_driver = driver;
	_instrument = instrument;
	_selectedSample = MAX(sample, 0);
	_changeHandler = [changeHandler copy];
	_closeHandler = [closeHandler copy];
	[self buildWindow];
	return self;
}

- (NSFont *)classicFont
{
	return [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
}

- (InstrData *)instrumentData
{
	if (self.music == NULL || self.instrument < 0 || self.instrument >= MAXINSTRU) return NULL;
	return &self.music->fid[self.instrument];
}

- (sData *)selectedSampleData
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL || self.selectedSample < 0 || self.selectedSample >= instrument->numSamples) return NULL;
	return self.music->sample[instrument->firstSample + self.selectedSample];
}

- (NSString *)legacyString:(const char *)bytes length:(size_t)length fallback:(NSString *)fallback
{
	size_t count = strnlen(bytes, length);
	if (count == 0) return fallback;
	return [[NSString alloc] initWithBytes:bytes length:count encoding:NSMacOSRomanStringEncoding] ?: fallback;
}

- (void)copyString:(NSString *)string toBuffer:(char *)buffer length:(size_t)length
{
	memset(buffer, 0, length);
	NSData *data = [string dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	if (data.length > 0) memcpy(buffer, data.bytes, MIN(data.length, length - 1));
}

- (NSTextField *)label:(NSString *)title frame:(NSRect)frame inView:(NSView *)view
{
	NSTextField *label = [NSTextField labelWithString:title];
	label.frame = frame;
	label.font = [self classicFont];
	label.lineBreakMode = NSLineBreakByClipping;
	[view addSubview:label];
	return label;
}

- (NSTextField *)editField:(NSRect)frame identifier:(NSString *)identifier inView:(NSView *)view
{
	NSTextField *field = [NSTextField textFieldWithString:@""];
	field.frame = frame;
	field.font = [self classicFont];
	field.identifier = identifier;
	field.delegate = self;
	field.focusRingType = NSFocusRingTypeNone;
	[view addSubview:field];
	return field;
}

- (NSBox *)boxWithTitle:(NSString *)title frame:(NSRect)frame
{
	NSBox *box = [[NSBox alloc] initWithFrame:frame];
	box.title = title;
	box.titleFont = [self classicFont];
	box.boxType = NSBoxPrimary;
	box.borderType = NSLineBorder;
	box.contentViewMargins = NSMakeSize(6, 5);
	[self.window.contentView addSubview:box];
	return box;
}

- (NSButton *)envelopeButton:(NSString *)title tag:(NSInteger)tag frame:(NSRect)frame inView:(NSView *)view
{
	NSButton *button = [NSButton checkboxWithTitle:title target:self action:@selector(envelopeFlagChanged:)];
	button.frame = frame;
	button.font = [self classicFont];
	button.tag = tag;
	button.controlSize = NSControlSizeSmall;
	button.focusRingType = NSFocusRingTypeNone;
	[view addSubview:button];
	return button;
}

- (void)buildWindow
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(210, 210, 455, 352)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = [NSString stringWithFormat:@"Instrument Info - %ld", (long)self.instrument + 1];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.backgroundColor = [NSColor colorWithCalibratedWhite:0.89 alpha:1.0];
	self.window = window;

	NSBox *instrumentBox = [self boxWithTitle:@"Instrument" frame:NSMakeRect(5, 286, 445, 61)];
	NSView *instrumentView = instrumentBox.contentView;
	[self label:@"Name:" frame:NSMakeRect(3, 13, 42, 16) inView:instrumentView];
	self.instrumentNameField = [self editField:NSMakeRect(43, 10, 250, 20) identifier:@"instrument-name" inView:instrumentView];
	[self label:@"Fadeout:" frame:NSMakeRect(302, 13, 55, 16) inView:instrumentView];
	self.fadeField = [self editField:NSMakeRect(356, 10, 72, 20) identifier:@"fadeout" inView:instrumentView];

	NSBox *envelopeBox = [self boxWithTitle:@"Envelopes" frame:NSMakeRect(5, 220, 445, 63)];
	NSView *envelopeView = envelopeBox.contentView;
	[self label:@"Volume:" frame:NSMakeRect(3, 25, 55, 16) inView:envelopeView];
	[self label:@"Panning:" frame:NSMakeRect(3, 3, 55, 16) inView:envelopeView];
	NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
	NSArray<NSString *> *titles = @[@"On", @"Sustain", @"Loop", @"Fixed speed"];
	NSArray<NSNumber *> *bits = @[@(PPEnvelopeOn), @(PPEnvelopeSustain), @(PPEnvelopeLoop), @(PPEnvelopeFixedSpeed)];
	NSArray<NSNumber *> *widths = @[@52, @72, @58, @100];
	CGFloat x = 60;
	for (NSInteger index = 0; index < 4; index++) {
		CGFloat width = widths[index].doubleValue;
		[buttons addObject:[self envelopeButton:titles[index] tag:0x100 | bits[index].integerValue
			frame:NSMakeRect(x, 23, width, 18) inView:envelopeView]];
		[buttons addObject:[self envelopeButton:titles[index] tag:0x200 | bits[index].integerValue
			frame:NSMakeRect(x, 1, width, 18) inView:envelopeView]];
		x += width;
	}
	self.envelopeButtons = buttons;

	NSBox *keyboardBox = [self boxWithTitle:@"Sample assignment" frame:NSMakeRect(5, 142, 445, 75)];
	NSView *keyboardView = keyboardBox.contentView;
	self.piano = [[PPSmallPianoView alloc] initWithFrame:NSMakeRect(3, 15, 430, 42)];
	self.piano.toolTip = @"Click to preview. Option-drag to assign the selected sample, as in PlayerPRO 2002.";
	[keyboardView addSubview:self.piano];
	self.noteField = [self label:@"Click plays • ⌥-drag assigns the selected sample" frame:NSMakeRect(3, -1, 420, 14)
		inView:keyboardView];
	__weak typeof(self) weakSelf = self;
	self.piano.assignmentWillBegin = ^{ [weakSelf beginMapping]; };
	self.piano.noteHandler = ^(NSInteger note, BOOL assigning) { [weakSelf handlePianoNote:note assigning:assigning]; };
	self.piano.assignmentDidEnd = ^{ [weakSelf finishMapping]; };

	NSBox *sampleBox = [self boxWithTitle:@"Sample Info" frame:NSMakeRect(5, 5, 445, 134)];
	NSView *sampleView = sampleBox.contentView;
	self.samplePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(3, 89, 155, 22) pullsDown:NO];
	self.samplePopup.font = [self classicFont];
	self.samplePopup.target = self;
	self.samplePopup.action = @selector(selectSample:);
	[sampleView addSubview:self.samplePopup];
	self.sampleNameField = [self editField:NSMakeRect(164, 90, 264, 20) identifier:@"sample-name" inView:sampleView];

	[self label:@"Loop start:" frame:NSMakeRect(3, 64, 65, 16) inView:sampleView];
	self.loopStartField = [self editField:NSMakeRect(65, 61, 72, 20) identifier:@"sample-metadata" inView:sampleView];
	[self label:@"Length:" frame:NSMakeRect(146, 64, 48, 16) inView:sampleView];
	self.loopLengthField = [self editField:NSMakeRect(192, 61, 72, 20) identifier:@"sample-metadata" inView:sampleView];
	[self label:@"Volume:" frame:NSMakeRect(273, 64, 50, 16) inView:sampleView];
	self.volumeField = [self editField:NSMakeRect(323, 61, 52, 20) identifier:@"sample-metadata" inView:sampleView];

	[self label:@"Rate:" frame:NSMakeRect(3, 38, 40, 16) inView:sampleView];
	self.rateField = [self editField:NSMakeRect(42, 35, 78, 20) identifier:@"sample-metadata" inView:sampleView];
	[self label:@"Rel. note:" frame:NSMakeRect(128, 38, 64, 16) inView:sampleView];
	self.relativeNoteField = [self editField:NSMakeRect(190, 35, 55, 20) identifier:@"sample-metadata" inView:sampleView];
	[self label:@"Loop type:" frame:NSMakeRect(253, 38, 65, 16) inView:sampleView];
	self.loopTypePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(315, 34, 113, 22) pullsDown:NO];
	[self.loopTypePopup addItemsWithTitles:@[@"Classic", @"Ping-Pong"]];
	self.loopTypePopup.font = [self classicFont];
	self.loopTypePopup.target = self;
	self.loopTypePopup.action = @selector(changeLoopType:);
	[sampleView addSubview:self.loopTypePopup];

	[self label:@"Format:" frame:NSMakeRect(3, 12, 48, 16) inView:sampleView];
	self.formatField = [self label:@"—" frame:NSMakeRect(50, 12, 230, 16) inView:sampleView];
	[self label:@"Real note = played note + relative note" frame:NSMakeRect(229, 12, 199, 16) inView:sampleView].alignment = NSTextAlignmentRight;

	[self reloadAllControls];
}

- (PPInstrumentSnapshot *)captureSnapshot
{
	PPInstrumentSnapshot *snapshot = [[PPInstrumentSnapshot alloc] init];
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL) return snapshot;
	snapshot.instrumentData = [NSData dataWithBytes:instrument length:sizeof(*instrument)];
	NSMutableArray<NSData *> *metadata = [NSMutableArray arrayWithCapacity:instrument->numSamples];
	for (NSInteger index = 0; index < instrument->numSamples; index++) {
		sData *sample = self.music->sample[instrument->firstSample + index];
		PPSampleMetadata value = {0};
		if (sample != NULL) {
			memcpy(value.name, sample->name, sizeof(value.name));
			value.loopBeg = sample->loopBeg;
			value.loopSize = sample->loopSize;
			value.vol = sample->vol;
			value.c2spd = sample->c2spd;
			value.loopType = sample->loopType;
			value.realNote = sample->realNote;
		}
		[metadata addObject:[NSData dataWithBytes:&value length:sizeof(value)]];
	}
	snapshot.sampleMetadata = metadata;
	snapshot.selectedSample = self.selectedSample;
	return snapshot;
}

- (void)registerUndoSnapshot:(PPInstrumentSnapshot *)snapshot actionName:(NSString *)name
{
	[[self.window.undoManager prepareWithInvocationTarget:self] restoreSnapshot:snapshot actionName:name];
	[self.window.undoManager setActionName:name];
}

- (void)restoreSnapshot:(PPInstrumentSnapshot *)snapshot actionName:(NSString *)name
{
	PPInstrumentSnapshot *redo = [self captureSnapshot];
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL || snapshot.instrumentData.length != sizeof(*instrument)) return;
	memcpy(instrument, snapshot.instrumentData.bytes, sizeof(*instrument));
	NSInteger count = MIN((NSInteger)snapshot.sampleMetadata.count, instrument->numSamples);
	for (NSInteger index = 0; index < count; index++) {
		sData *sample = self.music->sample[instrument->firstSample + index];
		NSData *data = snapshot.sampleMetadata[index];
		if (sample == NULL || data.length != sizeof(PPSampleMetadata)) continue;
		PPSampleMetadata value;
		[data getBytes:&value length:sizeof(value)];
		memcpy(sample->name, value.name, sizeof(value.name));
		sample->loopBeg = value.loopBeg;
		sample->loopSize = value.loopSize;
		sample->vol = value.vol;
		sample->c2spd = value.c2spd;
		sample->loopType = value.loopType;
		sample->realNote = value.realNote;
	}
	self.selectedSample = MIN(MAX(snapshot.selectedSample, 0), MAX(instrument->numSamples - 1, 0));
	[self registerUndoSnapshot:redo actionName:name];
	[self markChanged];
	[self reloadAllControls];
}

- (void)markChanged
{
	if (self.music != NULL) self.music->hasChanged = true;
	if (self.changeHandler != nil) self.changeHandler();
}

- (void)reloadEnvelopeControls
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL) return;
	for (NSButton *button in self.envelopeButtons) {
		BOOL panning = (button.tag & 0x200) != 0;
		NSInteger bit = button.tag & 0xFF;
		Byte flags = panning ? instrument->pannType : instrument->volType;
		button.state = bit == PPEnvelopeFixedSpeed ? ((flags & bit) == 0) : ((flags & bit) != 0);
	}
}

- (void)reloadSamplePopup
{
	InstrData *instrument = [self instrumentData];
	[self.samplePopup removeAllItems];
	if (instrument == NULL || instrument->numSamples <= 0) {
		[self.samplePopup addItemWithTitle:@"No samples"];
		self.samplePopup.enabled = NO;
		self.selectedSample = 0;
		return;
	}
	self.samplePopup.enabled = YES;
	self.selectedSample = MIN(MAX(self.selectedSample, 0), instrument->numSamples - 1);
	for (NSInteger index = 0; index < instrument->numSamples; index++) {
		sData *sample = self.music->sample[instrument->firstSample + index];
		NSString *name = sample == NULL ? @"Untitled Sample" : [self legacyString:sample->name
			length:sizeof(sample->name) fallback:@"Untitled Sample"];
		[self.samplePopup addItemWithTitle:[NSString stringWithFormat:@"%03ld  %@", (long)index + 1, name]];
	}
	[self.samplePopup selectItemAtIndex:self.selectedSample];
}

- (void)reloadSampleFields
{
	sData *sample = [self selectedSampleData];
	NSArray<NSControl *> *controls = @[self.sampleNameField, self.loopStartField, self.loopLengthField,
		self.volumeField, self.rateField, self.relativeNoteField, self.loopTypePopup];
	for (NSControl *control in controls) control.enabled = sample != NULL;
	if (sample == NULL) {
		self.sampleNameField.stringValue = @"";
		self.loopStartField.stringValue = @"";
		self.loopLengthField.stringValue = @"";
		self.volumeField.stringValue = @"";
		self.rateField.stringValue = @"";
		self.relativeNoteField.stringValue = @"";
		self.formatField.stringValue = @"No samples in this instrument";
		return;
	}
	self.sampleNameField.stringValue = [self legacyString:sample->name length:sizeof(sample->name) fallback:@"Untitled Sample"];
	self.loopStartField.integerValue = sample->loopBeg;
	self.loopLengthField.integerValue = sample->loopSize;
	self.volumeField.integerValue = sample->vol;
	self.rateField.integerValue = sample->c2spd;
	self.relativeNoteField.integerValue = sample->realNote;
	[self.loopTypePopup selectItemAtIndex:MIN(sample->loopType, 1)];
	self.formatField.stringValue = [NSString stringWithFormat:@"%u-bit %@ • %d bytes", sample->amp,
		sample->stereo ? @"Stereo" : @"Mono", sample->size];
}

- (void)reloadAllControls
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL) return;
	self.instrumentNameField.stringValue = [self legacyString:instrument->name length:sizeof(instrument->name)
		fallback:@"Untitled Instrument"];
	self.fadeField.integerValue = instrument->volFade;
	[self reloadEnvelopeControls];
	[self reloadSamplePopup];
	[self reloadSampleFields];
	self.piano.instrument = instrument;
	self.piano.selectedSample = instrument->numSamples > 0 ? self.selectedSample : -1;
	[self.piano setNeedsDisplay:YES];
}

- (BOOL)integerFromField:(NSTextField *)field minimum:(NSInteger)minimum maximum:(NSInteger)maximum value:(NSInteger *)value
{
	NSString *string = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSScanner *scanner = [NSScanner scannerWithString:string];
	NSInteger parsed = 0;
	if (string.length == 0 || ![scanner scanInteger:&parsed] || !scanner.isAtEnd || parsed < minimum || parsed > maximum) return NO;
	if (value != NULL) *value = parsed;
	return YES;
}

- (IBAction)commitTextField:(NSTextField *)sender
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL) return;
	PPInstrumentSnapshot *snapshot = [self captureSnapshot];
	if ([sender.identifier isEqualToString:@"instrument-name"]) {
		[self copyString:sender.stringValue toBuffer:instrument->name length:sizeof(instrument->name)];
		[self registerUndoSnapshot:snapshot actionName:@"Instrument Name"];
		[self markChanged];
		return;
	}
	if ([sender.identifier isEqualToString:@"fadeout"]) {
		NSInteger fade = 0;
		if (![self integerFromField:sender minimum:0 maximum:32767 value:&fade]) { NSBeep(); [self reloadAllControls]; return; }
		instrument->volFade = (unsigned short)fade;
		[self registerUndoSnapshot:snapshot actionName:@"Instrument Fadeout"];
		[self markChanged];
		return;
	}
	sData *sample = [self selectedSampleData];
	if (sample == NULL) return;
	if ([sender.identifier isEqualToString:@"sample-name"]) {
		[self copyString:sender.stringValue toBuffer:sample->name length:sizeof(sample->name)];
		[self registerUndoSnapshot:snapshot actionName:@"Sample Name"];
		[self markChanged];
		[self reloadSamplePopup];
		return;
	}
	NSInteger loopStart = 0, loopLength = 0, volume = 0, rate = 0, relativeNote = 0;
	BOOL valid = [self integerFromField:self.loopStartField minimum:0 maximum:sample->size value:&loopStart] &&
		[self integerFromField:self.loopLengthField minimum:0 maximum:sample->size value:&loopLength] &&
		[self integerFromField:self.volumeField minimum:0 maximum:64 value:&volume] &&
		[self integerFromField:self.rateField minimum:1 maximum:49999 value:&rate] &&
		[self integerFromField:self.relativeNoteField minimum:-95 maximum:95 value:&relativeNote] &&
		loopStart + loopLength <= sample->size;
	if (!valid) { NSBeep(); [self reloadSampleFields]; return; }
	sample->loopBeg = loopStart;
	sample->loopSize = loopLength;
	sample->vol = (Byte)volume;
	sample->c2spd = (unsigned short)rate;
	sample->realNote = (char)relativeNote;
	[self registerUndoSnapshot:snapshot actionName:@"Sample Information"];
	[self markChanged];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	if ([notification.object isKindOfClass:NSTextField.class]) {
		[self commitTextField:notification.object];
	}
}

- (IBAction)envelopeFlagChanged:(NSButton *)sender
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL) return;
	PPInstrumentSnapshot *snapshot = [self captureSnapshot];
	BOOL panning = (sender.tag & 0x200) != 0;
	NSInteger bit = sender.tag & 0xFF;
	Byte *flags = panning ? &instrument->pannType : &instrument->volType;
	if (bit == PPEnvelopeFixedSpeed) {
		if (sender.state == NSControlStateValueOn) *flags &= ~bit;
		else *flags |= bit;
	} else if (sender.state == NSControlStateValueOn) {
		*flags |= bit;
	} else {
		*flags &= ~bit;
	}
	[self registerUndoSnapshot:snapshot actionName:panning ? @"Panning Envelope" : @"Volume Envelope"];
	[self markChanged];
	[self reloadEnvelopeControls];
}

- (IBAction)selectSample:(NSPopUpButton *)sender
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL || instrument->numSamples <= 0) return;
	self.selectedSample = MIN(MAX(sender.indexOfSelectedItem, 0), instrument->numSamples - 1);
	[self reloadSampleFields];
	self.piano.selectedSample = self.selectedSample;
	[self.piano setNeedsDisplay:YES];
}

- (IBAction)changeLoopType:(NSPopUpButton *)sender
{
	sData *sample = [self selectedSampleData];
	if (sample == NULL) return;
	PPInstrumentSnapshot *snapshot = [self captureSnapshot];
	sample->loopType = (Byte)MIN(MAX(sender.indexOfSelectedItem, 0), 1);
	[self registerUndoSnapshot:snapshot actionName:@"Sample Loop Type"];
	[self markChanged];
}

- (NSString *)nameForNote:(NSInteger)note
{
	static NSArray<NSString *> *names;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ names = @[@"C-", @"C#", @"D-", @"D#", @"E-", @"F-", @"F#", @"G-", @"G#", @"A-", @"A#", @"B-"]; });
	return [NSString stringWithFormat:@"%@%ld", names[note % 12], (long)(note / 12)];
}

- (void)beginMapping
{
	self.mappingSnapshot = [self captureSnapshot];
	self.mappingChanged = NO;
}

- (void)handlePianoNote:(NSInteger)note assigning:(BOOL)assigning
{
	InstrData *instrument = [self instrumentData];
	if (instrument == NULL || instrument->numSamples <= 0 || note < 0 || note >= NUMBER_NOTES) return;
	if (assigning) {
		if (instrument->what[note] != self.selectedSample) {
			instrument->what[note] = (Byte)self.selectedSample;
			self.mappingChanged = YES;
			self.music->hasChanged = true;
			[self.piano setNeedsDisplay:YES];
		}
		self.noteField.stringValue = [NSString stringWithFormat:@"%@ → sample %03ld", [self nameForNote:note],
			(long)self.selectedSample + 1];
		return;
	}
	NSInteger sampleIndex = instrument->what[note];
	if (sampleIndex < 0 || sampleIndex >= instrument->numSamples) sampleIndex = 0;
	sData *sample = self.music->sample[instrument->firstSample + sampleIndex];
	self.noteField.stringValue = [NSString stringWithFormat:@"%@ • sample %03ld", [self nameForNote:note], (long)sampleIndex + 1];
	if (sample == NULL || sample->data == NULL || sample->size <= 2 || self.driver == NULL) { NSBeep(); return; }
	[self stopPreview];
	NSInteger playbackNote = MIN(MAX(note + sample->realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(self.driver, sample->data, (size_t)sample->size, 0, (MADByte)playbackNote,
		sample->amp, sample->loopBeg, sample->loopSize, sample->c2spd, sample->stereo);
	if (error != MADNoErr) NSBeep();
}

- (void)finishMapping
{
	[self stopPreview];
	if (self.mappingChanged && self.mappingSnapshot != nil) {
		[self registerUndoSnapshot:self.mappingSnapshot actionName:@"Sample Assignment"];
		[self markChanged];
	}
	self.mappingSnapshot = nil;
	self.mappingChanged = NO;
	self.noteField.stringValue = @"Click plays • ⌥-drag assigns the selected sample";
}

- (void)stopPreview
{
	if (self.driver != NULL) MADDriverClearChannel(self.driver, 0);
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	(void)notification;
	[self reloadAllControls];
}

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	[self stopPreview];
	if (self.closeHandler != nil) self.closeHandler();
}

@end
