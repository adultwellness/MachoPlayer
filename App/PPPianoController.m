#import "PPPianoController.h"
#import "PPPatternCommandCodec.h"
#import "PPPreferences.h"

#include "MADDriver.h"

static NSAppearance *PPPianoClassicAppearance(void)
{
	return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
}

static NSArray<NSColor *> *PPPianoTrackColors(void)
{
	return PPPreferredTrackColors();
}

static NSColor *PPPianoClassicKeyColor(NSInteger note)
{
	// The 2002 Piano used strong color blocks for each displayed octave rather
	// than the Digital editor's paler four-track colors.
	static NSArray<NSColor *> *colors;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		colors = @[
			[NSColor colorWithCalibratedRed:0.96 green:0.72 blue:0.82 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.28 green:0.79 blue:0.45 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.00 green:0.82 blue:0.80 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.88 green:0.91 blue:0.02 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.31 green:0.76 blue:0.58 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.00 green:0.78 blue:0.77 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.19 green:0.78 blue:0.25 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.91 green:0.76 blue:0.85 alpha:1.0]
		];
	});
	NSInteger octave = note < 0 ? 0 : MIN(MAX(note / 12, 0), (NSInteger)colors.count - 1);
	return colors[(NSUInteger)octave];
}

static NSFont *PPPianoFont(CGFloat size, NSFontWeight weight)
{
	NSFont *font = [NSFont fontWithName:@"Monaco" size:size];
	if (font == nil) font = [NSFont monospacedSystemFontOfSize:size weight:weight];
	if (font == nil) font = [NSFont systemFontOfSize:size weight:weight];
	return font;
}

static void PPPianoStopOwnedPreview(MADDriverRec *driver, NSInteger *previewChannel)
{
	if (previewChannel == NULL) return;
	if (driver != NULL && *previewChannel >= 0 && *previewChannel < MAXTRACK) {
		MADDriverClearChannel(driver, (int)*previewChannel);
	}
	*previewChannel = -1;
}

static void PPPianoReleasePreviewChannel(MADDriverRec *driver)
{
	if (driver == NULL) return;
	NSInteger channel = driver->previewChannel;
	if (channel >= 0 && channel < MAXTRACK) MADDriverClearChannel(driver, (int)channel);
	if (channel >= 0 && channel == driver->MultiChanNo - 1 &&
		driver->previewChannelBaseCount >= 0 && driver->previewChannelBaseCount <= channel) {
		driver->MultiChanNo = driver->previewChannelBaseCount;
	}
	driver->previewChannel = -1;
	driver->previewChannelBaseCount = -1;
}

static NSInteger PPPianoAcquirePreviewChannel(MADDriverRec *driver, MADMusic *music)
{
	if (driver == NULL) return -1;
	NSInteger songTracks = music == NULL || music->header == NULL ? 0
		: MIN(MAX((NSInteger)music->header->numChn, 0), (NSInteger)MAXTRACK);
	NSInteger channel = driver->previewChannel;
	if (channel >= songTracks && channel >= 0 && channel < MAXTRACK) {
		if (driver->MultiChanNo <= channel) driver->MultiChanNo = (int)channel + 1;
		return channel;
	}

	// Append a voice outside the song's allocation pool. Reusing an apparently
	// idle multichannel voice is racy: track 1, which is allocated first each
	// row, can claim it between the UI's scan and clear operations.
	NSInteger renderedVoices = MAX((NSInteger)driver->MultiChanNo, songTracks);
	if (renderedVoices < 0 || renderedVoices >= MAXTRACK) return -1;
	channel = renderedVoices;
	driver->previewChannelBaseCount = (short)driver->MultiChanNo;
	MADDriverClearChannel(driver, (int)channel);
	driver->previewChannel = (short)channel;
	driver->base.Active[channel] = true;
	driver->MultiChanNo = (int)channel + 1;
	return channel;
}

BOOL PPPianoRunPreviewOwnershipSelfTest(void)
{
	MADDriverRec driver = {0};
	MADMusic music = {0};
	MADSpec header = {0};
	header.numChn = 4;
	music.header = &header;
	driver.previewChannel = -1;
	driver.previewChannelBaseCount = -1;
	driver.MultiChanNo = 6;
	driver.base.chan[5].samplePtr = (char *)&music;
	NSInteger previewChannel = PPPianoAcquirePreviewChannel(&driver, &music);
	if (previewChannel != 6 || driver.previewChannel != 6 ||
		driver.previewChannelBaseCount != 6 || driver.MultiChanNo != 7)
		return NO;
	driver.base.chan[previewChannel].samplePtr = (char *)&driver;
	driver.base.chan[2].samplePtr = (char *)&driver;
	PPPianoStopOwnedPreview(&driver, &previewChannel);
	BOOL stoppedWithoutReleasing = previewChannel == -1 && driver.previewChannel == 6 &&
		driver.MultiChanNo == 7 && driver.base.chan[6].samplePtr == NULL &&
		driver.base.chan[2].samplePtr != NULL && driver.base.chan[5].samplePtr != NULL;
	PPPianoReleasePreviewChannel(&driver);
	return stoppedWithoutReleasing && driver.previewChannel == -1 &&
		driver.previewChannelBaseCount == -1 && driver.MultiChanNo == 6;
}

static NSString *PPPianoNoteName(NSInteger note)
{
	static NSArray<NSString *> *names;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ names = @[@"C", @"C#", @"D", @"D#", @"E", @"F", @"F#", @"G", @"G#", @"A", @"A#", @"B"]; });
	if (note < 0 || note >= NUMBER_NOTES) return @"---";
	NSString *name = names[(NSUInteger)note % 12];
	return name.length == 1 ? [NSString stringWithFormat:@"%@-%ld", name, (long)note / 12]
		: [NSString stringWithFormat:@"%@%ld", name, (long)note / 12];
}

@interface PPPianoKeyboardView : NSView
@property(nonatomic) BOOL compactMode;
@property(nonatomic) NSInteger keyboardOffset;
@property(nonatomic) NSInteger selectedInstrument;
@property(nonatomic) NSInteger selectedTrack;
@property(nonatomic) NSInteger pressedNote;
@property(nonatomic) BOOL macKeyboardEnabled;
@property(nonatomic) BOOL drawsOctaveMarkers;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *playingNotes;
@property(nonatomic, copy) void (^noteHandler)(NSInteger note, BOOL began);
- (NSSize)pianoSize;
@end

@implementation PPPianoKeyboardView {
	NSInteger _mouseNote;
	NSInteger _keyboardNote;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		self.appearance = PPPianoClassicAppearance();
		_pressedNote = -1;
		_mouseNote = -1;
		_keyboardNote = -1;
		_keyboardOffset = 0;
		_macKeyboardEnabled = YES;
		_drawsOctaveMarkers = YES;
		_playingNotes = @{};
	}
	return self;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (NSSize)pianoSize
{
	return self.compactMode ? NSMakeSize(449, 58) : NSMakeSize(17 * NUMBER_NOTES, 29);
}

- (BOOL)isBlackNote:(NSInteger)note
{
	NSInteger pitch = note % 12;
	return pitch == 1 || pitch == 3 || pitch == 6 || pitch == 8 || pitch == 10;
}

- (NSRect)compactRectForNote:(NSInteger)wanted
{
	CGFloat previous = 0;
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		BOOL black = [self isBlackNote:note];
		NSRect rect;
		if (black) {
			rect = NSMakeRect(previous, 30, 5, 28);
			previous += 2;
		} else {
			rect = NSMakeRect(previous, 10, 9, 48);
			previous += [self isBlackNote:note + 1] ? 6 : 8;
		}
		if (note == wanted) return rect;
	}
	return NSZeroRect;
}

- (NSRect)rectForNote:(NSInteger)note
{
	return self.compactMode ? [self compactRectForNote:note] : NSMakeRect(note * 17, 0, 17, 29);
}

- (NSInteger)noteAtPoint:(NSPoint)point
{
	if (!NSPointInRect(point, self.bounds)) return -1;
	if (!self.compactMode) {
		NSInteger note = (NSInteger)floor(point.x / 17.0);
		return note >= 0 && note < NUMBER_NOTES ? note : -1;
	}
	// Accidentals overlap the natural keys in the original small PICT, so they
	// get hit-tested first just as PlayerPRO 2002 did.
	for (NSInteger pass = 0; pass < 2; pass++) {
		for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
			if ((pass == 0) != [self isBlackNote:note]) continue;
			if (NSPointInRect(point, [self compactRectForNote:note])) return note;
		}
	}
	return -1;
}

- (NSDictionary<NSNumber *, NSString *> *)keyboardLabels
{
	// The characters stay on their physical keyboard positions while the note
	// names beneath them transpose with the octave arrows. The same offset is
	// applied by keyDown:, so the displayed name and the note heard agree.
	return PPTrackerKeyboardLabels(0);
}

- (NSInteger)displayedNoteForKeyPosition:(NSInteger)position
{
	if (position < 0 || position >= NUMBER_NOTES) return -1;
	NSInteger note = position + self.keyboardOffset * 12;
	return note >= 0 && note < NUMBER_NOTES ? note : -1;
}

- (NSInteger)keyPositionForDisplayedNote:(NSInteger)note
{
	NSInteger position = note - self.keyboardOffset * 12;
	return position >= 0 && position < NUMBER_NOTES ? position : -1;
}

- (void)drawLargePiano
{
	NSDictionary<NSNumber *, NSString *> *labels = [self keyboardLabels];
	NSFont *font = PPPianoFont(8, NSFontWeightRegular);
	for (NSInteger position = 0; position < NUMBER_NOTES; position++) {
		NSInteger note = [self displayedNoteForKeyPosition:position];
		NSRect keyRect = [self rectForNote:position];
		BOOL black = [self isBlackNote:note >= 0 ? note : position];
		NSColor *keyColor = black ? [NSColor colorWithCalibratedWhite:0.12 alpha:1.0]
			: (note >= 0 && self.drawsOctaveMarkers ? PPPianoClassicKeyColor(note)
				: NSColor.whiteColor);
		[keyColor setFill];
		NSRectFill(keyRect);
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(keyRect) + 0.5, 0)
			toPoint:NSMakePoint(NSMinX(keyRect) + 0.5, 29)];
		NSColor *textColor = black ? NSColor.whiteColor : NSColor.blackColor;
		NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:textColor};
		[PPPianoNoteName(note) drawAtPoint:NSMakePoint(NSMinX(keyRect) + 1, 18) withAttributes:attributes];
		NSString *label = labels[@(position)];
		if (label.length > 0) [label drawAtPoint:NSMakePoint(NSMidX(keyRect) - 2.5, 4) withAttributes:attributes];
	}
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(NSMakeRect(0.5, 0.5, NSWidth(self.bounds) - 1, NSHeight(self.bounds) - 1), 1);
}

- (void)drawCompactPiano
{
	NSDictionary<NSNumber *, NSString *> *labels = [self keyboardLabels];
	NSFont *font = PPPianoFont(8, NSFontWeightRegular);
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		if ([self isBlackNote:note]) continue;
		NSRect rect = [self compactRectForNote:note];
		[NSColor.whiteColor setFill]; NSRectFill(rect);
		[NSColor.blackColor setStroke]; NSFrameRectWithWidth(rect, 1);
		NSString *label = labels[@(note)];
		if (label.length > 0) [label drawAtPoint:NSMakePoint(NSMinX(rect) + 1, 12)
			withAttributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor}];
	}
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		if (![self isBlackNote:note]) continue;
		NSRect rect = [self compactRectForNote:note];
		[[NSColor colorWithCalibratedWhite:0.20 alpha:1.0] setFill]; NSRectFill(rect);
		[NSColor.blackColor setStroke]; NSFrameRectWithWidth(rect, 1);
		NSString *label = labels[@(note)];
		if (label.length > 0) [label drawAtPoint:NSMakePoint(NSMinX(rect), NSMinY(rect) + 7)
			withAttributes:@{NSFontAttributeName:PPPianoFont(7, NSFontWeightRegular),
				NSForegroundColorAttributeName:NSColor.whiteColor}];
	}
	for (NSInteger octave = 0; self.drawsOctaveMarkers && octave < 8; octave++) {
		NSRect strip = NSMakeRect(octave * 56, 0, 56, 10);
		[PPPianoTrackColors()[(NSUInteger)octave % PPPianoTrackColors().count] setFill]; NSRectFill(strip);
		[NSColor.blackColor setStroke]; NSFrameRectWithWidth(strip, 1);
		[[NSString stringWithFormat:@"%ld", (long)octave + self.keyboardOffset] drawInRect:strip withAttributes:@{
			NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor,
			NSParagraphStyleAttributeName:({ NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init]; style.alignment = NSTextAlignmentCenter; style; })
		}];
	}
}

- (void)drawHighlightForNote:(NSInteger)note colorIndex:(NSInteger)colorIndex pressed:(BOOL)pressed
{
	if (note < 0 || note >= NUMBER_NOTES) return;
	NSInteger position = [self keyPositionForDisplayedNote:note];
	if (position < 0) return;
	NSRect rect = NSInsetRect([self rectForNote:position], 1, 1);
	(void)colorIndex;
	(void)pressed;
	[[NSColor colorWithCalibratedRed:1.0 green:0.0 blue:0.0 alpha:1.0] setFill];
	NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver);
	[NSColor.blackColor setStroke]; NSFrameRectWithWidth(rect, 1);
	if (!self.compactMode) {
		NSString *instrument = [NSString stringWithFormat:@"%02ld", (long)MIN(MAX(self.selectedInstrument + 1, 1), 99)];
		NSMutableDictionary<NSAttributedStringKey, id> *attributes = [NSMutableDictionary dictionary];
		NSFont *font = PPPianoFont(8, NSFontWeightBold);
		NSColor *textColor = NSColor.blackColor;
		if (font != nil) attributes[NSFontAttributeName] = font;
		if (textColor != nil) attributes[NSForegroundColorAttributeName] = textColor;
		[instrument drawAtPoint:NSMakePoint(NSMinX(rect) + 2, 4) withAttributes:attributes];
	}
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	self.compactMode ? [self drawCompactPiano] : [self drawLargePiano];
	[self.playingNotes enumerateKeysAndObjectsUsingBlock:^(NSNumber *note, NSNumber *track, BOOL *stop) {
		(void)stop; [self drawHighlightForNote:note.integerValue colorIndex:track.integerValue pressed:NO];
	}];
	if (self.pressedNote >= 0) [self drawHighlightForNote:self.pressedNote colorIndex:self.selectedTrack pressed:YES];
}

- (void)beginNote:(NSInteger)note source:(NSInteger *)source
{
	if (note < 0 || note >= NUMBER_NOTES || *source == note) return;
	if (*source >= 0 && self.noteHandler != nil) self.noteHandler(*source, NO);
	*source = note;
	self.pressedNote = note;
	[self setNeedsDisplay:YES];
	if (self.noteHandler != nil) self.noteHandler(note, YES);
}

- (void)endNoteSource:(NSInteger *)source
{
	if (*source >= 0 && self.noteHandler != nil) self.noteHandler(*source, NO);
	*source = -1;
	self.pressedNote = _mouseNote >= 0 ? _mouseNote : _keyboardNote;
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	NSInteger position = [self noteAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	[self beginNote:[self displayedNoteForKeyPosition:position] source:&_mouseNote];
}

- (void)mouseDragged:(NSEvent *)event
{
	NSInteger note = [self noteAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
	note = [self displayedNoteForKeyPosition:note];
	if (note >= 0) [self beginNote:note source:&_mouseNote];
}

- (void)mouseUp:(NSEvent *)event
{
	(void)event; [self endNoteSource:&_mouseNote];
}

- (void)keyDown:(NSEvent *)event
{
	if (!self.macKeyboardEnabled) { [super keyDown:event]; return; }
	if (event.isARepeat) return;
	NSInteger note = PPTrackerKeyboardNoteForKey(event.characters, self.keyboardOffset);
	if (note == NSNotFound) { [super keyDown:event]; return; }
	[self beginNote:note source:&_keyboardNote];
}

- (void)keyUp:(NSEvent *)event
{
	if (!self.macKeyboardEnabled) { [super keyUp:event]; return; }
	NSInteger note = PPTrackerKeyboardNoteForKey(event.characters, self.keyboardOffset);
	if (note == NSNotFound) { [super keyUp:event]; return; }
	if (_keyboardNote == note) [self endNoteSource:&_keyboardNote];
}
@end

@interface PPPianoController () <NSWindowDelegate>
@property(nonatomic) MADMusic *music;
@property(nonatomic) MADDriverRec *driver;
@property(nonatomic) NSInteger selectedInstrument;
@property(nonatomic) NSInteger selectedTrack;
@property(nonatomic, strong) PPPianoKeyboardView *pianoView;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSButton *recordButton;
@property(nonatomic, strong) NSSegmentedControl *modeControl;
@property(nonatomic, strong) NSTextField *noteField;
@property(nonatomic) NSInteger octaveOffset;
@property(nonatomic, copy) PPPianoRecordHandler recordHandler;
@property(nonatomic, copy) PPPianoStatusHandler statusHandler;
@property(nonatomic, copy) PPPianoOctaveHandler octaveHandler;
@property(nonatomic, copy) PPPianoMIDIOutputHandler midiOutputHandler;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *midiInputNotes;
@property(nonatomic) NSInteger localPreviewChannel;
@property(nonatomic) NSInteger localPreviewNote;
@property(nonatomic) NSInteger localPreviewSourceTrack;
@property(nonatomic) NSInteger activePianoTrack;
@property(nonatomic) NSInteger lastRoutedTrack;
- (NSInteger)routedTrackForNewNote;
- (BOOL)playNote:(NSInteger)note velocity:(NSInteger)velocity
	instrument:(NSInteger)instrumentIndex track:(NSInteger)track;
@end

@implementation PPPianoController

- (instancetype)initWithRecordHandler:(PPPianoRecordHandler)recordHandler
	statusHandler:(PPPianoStatusHandler)statusHandler
	octaveHandler:(PPPianoOctaveHandler)octaveHandler
	midiOutputHandler:(PPPianoMIDIOutputHandler)midiOutputHandler
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1110, 44)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	self = [super initWithWindow:window];
	if (self) {
		_recordHandler = [recordHandler copy];
		_statusHandler = [statusHandler copy];
		_octaveHandler = [octaveHandler copy];
		_midiOutputHandler = [midiOutputHandler copy];
		_midiInputNotes = [NSMutableDictionary dictionary];
		_selectedInstrument = 0;
		_selectedTrack = 0;
		_octaveOffset = 0;
		_localPreviewChannel = -1;
		_localPreviewNote = -1;
		_localPreviewSourceTrack = -1;
		_activePianoTrack = -1;
		_lastRoutedTrack = -1;
		window.delegate = self;
		window.appearance = PPPianoClassicAppearance();
		window.backgroundColor = [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
		window.title = @"Piano +0 Octave(s)";
		[self buildWindow];
		[self reloadPreferences];
	}
	return self;
}

- (NSFont *)classicFont
{
	return [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
}

- (void)buildWindow
{
	NSView *content = self.window.contentView;
	content.appearance = PPPianoClassicAppearance();

	self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(26, 0, NSWidth(content.bounds) - 26, 44)];
	self.scrollView.hasHorizontalScroller = YES;
	self.scrollView.hasVerticalScroller = NO;
	self.scrollView.autohidesScrollers = NO;
	self.scrollView.borderType = NSNoBorder;
	self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.scrollView.backgroundColor = NSColor.whiteColor;
	self.pianoView = [[PPPianoKeyboardView alloc] initWithFrame:NSMakeRect(0, 0, 17 * NUMBER_NOTES, 29)];
	__weak typeof(self) weakSelf = self;
	self.pianoView.noteHandler = ^(NSInteger note, BOOL began) { [weakSelf handleNote:note began:began]; };
	self.scrollView.documentView = self.pianoView;
	[content addSubview:self.scrollView];
	[self.scrollView.contentView scrollToPoint:NSMakePoint(24 * 17, 0)];
	[self.scrollView reflectScrolledClipView:self.scrollView.contentView];

	NSButton *preferences = [NSButton buttonWithImage:[self originalImageNamed:@"preferences"] target:self action:@selector(togglePianoMode:)];
	preferences.frame = NSMakeRect(2, 22, 22, 22);
	preferences.bezelStyle = NSBezelStyleSmallSquare;
	preferences.toolTip = @"Toggle the original large and small Piano views";
	[content addSubview:preferences];
	NSButton *right = [NSButton buttonWithTitle:@"▶" target:self action:@selector(octaveUp:)];
	right.frame = NSMakeRect(2, 11, 22, 11); right.font = PPPianoFont(7, NSFontWeightRegular);
	right.bezelStyle = NSBezelStyleSmallSquare; right.toolTip = @"Raise the Piano keyboard one octave"; [content addSubview:right];
	NSButton *left = [NSButton buttonWithTitle:@"◀" target:self action:@selector(octaveDown:)];
	left.frame = NSMakeRect(2, 0, 22, 11); left.font = PPPianoFont(7, NSFontWeightRegular);
	left.bezelStyle = NSBezelStyleSmallSquare; left.toolTip = @"Lower the Piano keyboard one octave"; [content addSubview:left];

	// Recording remains controlled by the original Tools record button. Keep
	// these state objects for the existing controller API without adding the
	// later, non-2002 control strip to the Piano window.
	self.recordButton = [NSButton checkboxWithTitle:@"Piano Record" target:self action:@selector(toggleRecord:)];
	self.recordButton.font = [self classicFont];
	self.modeControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(138, 2, 112, 22)];
	self.modeControl.segmentCount = 2;
	[self.modeControl setLabel:@"Large" forSegment:0]; [self.modeControl setLabel:@"Small" forSegment:1];
	self.modeControl.selectedSegment = 0;
	self.modeControl.target = self; self.modeControl.action = @selector(changePianoMode:);
	self.noteField = [NSTextField labelWithString:@"Click or use the characters shown on the keys to play"];
	self.noteField.font = [self classicFont]; self.noteField.textColor = NSColor.blackColor;
	[self applyPianoMode:NO];
}

- (NSImage *)originalImageNamed:(NSString *)name
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	return path == nil ? [[NSImage alloc] initWithSize:NSMakeSize(16, 16)] : [[NSImage alloc] initWithContentsOfFile:path];
}

- (void)attachMusic:(MADMusic *)music driver:(MADDriverRec *)driver
	selectedInstrument:(NSInteger)instrument selectedTrack:(NSInteger)track
{
	MADDriverRec *previousDriver = self.driver;
	MADMusic *previousMusic = self.music;
	[self stopPreview];
	if (previousDriver != NULL && (previousDriver != driver || previousMusic != music)) {
		PPPianoReleasePreviewChannel(previousDriver);
	}
	[self.midiInputNotes removeAllObjects];
	self.music = music; self.driver = driver;
	[self setSelectedInstrument:instrument selectedTrack:track];
	self.recordButton.enabled = music != NULL && driver != NULL;
	if (music == NULL) self.recordButton.state = NSControlStateValueOff;
	[self updatePlaybackHighlights];
}

- (void)setSelectedInstrument:(NSInteger)instrument selectedTrack:(NSInteger)track
{
	NSInteger tracks = self.music == NULL || self.music->header == NULL ? 1 : MAX(self.music->header->numChn, 1);
	NSInteger newInstrument = MIN(MAX(instrument, 0), MAXINSTRU - 1);
	NSInteger newTrack = MIN(MAX(track, 0), tracks - 1);
	if (newInstrument != self.selectedInstrument || newTrack != self.selectedTrack) {
		[self stopPreview];
	}
	self.selectedInstrument = newInstrument;
	self.selectedTrack = newTrack;
	self.pianoView.selectedInstrument = self.selectedInstrument;
	self.pianoView.selectedTrack = self.selectedTrack;
	[self.pianoView setNeedsDisplay:YES];
}

- (void)setKeyboardOffset:(NSInteger)octaveOffset
{
	octaveOffset = MIN(MAX(octaveOffset, -7), 7);
	self.octaveOffset = octaveOffset;
	self.pianoView.keyboardOffset = octaveOffset;
	self.window.title = [NSString stringWithFormat:@"Piano %@%ld Octave(s)", self.octaveOffset >= 0 ? @"+" : @"",
		(long)self.octaveOffset];
	[self.pianoView setNeedsDisplay:YES];
}

- (BOOL)isRecordingEnabled { return self.recordButton.state == NSControlStateValueOn; }

- (void)setRecordingEnabled:(BOOL)enabled
{
	self.recordButton.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
	self.noteField.stringValue = enabled
		? @"Piano recording armed • notes write to the selected track"
		: @"Piano recording off • audition only";
}

- (void)reloadPreferences
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	self.pianoView.macKeyboardEnabled = [defaults boolForKey:PPPianoMacKeyboardDefaultsKey];
	self.pianoView.drawsOctaveMarkers = [defaults boolForKey:PPPianoOctaveMarkersDefaultsKey];
	BOOL compact = [defaults boolForKey:PPPianoSmallViewDefaultsKey];
	self.modeControl.selectedSegment = compact ? 1 : 0;
	[self applyPianoMode:compact];
	[self.pianoView setNeedsDisplay:YES];
}

- (void)showWindow:(id)sender
{
	[super showWindow:sender];
	[self.window makeKeyAndOrderFront:nil];
	[self.window makeFirstResponder:self.pianoView];
}

- (void)handleNote:(NSInteger)note began:(BOOL)began
{
	if (!began) {
		NSInteger keyUpMode = MIN(MAX([NSUserDefaults.standardUserDefaults
			integerForKey:PPPianoKeyUpModeDefaultsKey], 0), 2);
		BOOL livePlayback = self.driver != NULL && MADIsPlayingMusic(self.driver);
		if (keyUpMode != 0) [self stopPreview];
		if (keyUpMode == 1 && self.isRecordingEnabled && self.recordHandler != nil &&
			self.activePianoTrack >= 0) {
			self.recordHandler(0xFE, self.activePianoTrack, livePlayback);
		}
		if (self.midiOutputHandler != nil) {
			self.midiOutputHandler(note,
				self.activePianoTrack >= 0 ? self.activePianoTrack : self.selectedTrack,
				self.selectedInstrument, 0, NO);
		}
		self.activePianoTrack = -1;
		return;
	}
	// Capture transport state before touching the reserved audition voice. Live
	// recording must follow the row that was sounding when the key went down;
	// preview setup is deliberately independent from that decision.
	BOOL livePlayback = self.driver != NULL && MADIsPlayingMusic(self.driver);
	NSInteger track = [self routedTrackForNewNote];
	self.activePianoTrack = track;
	self.noteField.stringValue = [NSString stringWithFormat:@"%@ • instrument %03ld • track %02ld%@",
		PPPianoNoteName(note), (long)self.selectedInstrument + 1, (long)track + 1,
		self.isRecordingEnabled ? @" • REC" : @""];
	if (self.isRecordingEnabled && self.recordHandler != nil) {
		self.recordHandler(note, track, livePlayback);
	}
	[self playNote:note velocity:127 instrument:self.selectedInstrument track:track];
	if (self.midiOutputHandler != nil) {
		self.midiOutputHandler(note, track, self.selectedInstrument, 127, YES);
	}
}

- (NSInteger)routedTrackForNewNote
{
	NSInteger tracks = self.music == NULL || self.music->header == NULL
		? 1 : MIN(MAX((NSInteger)self.music->header->numChn, 1), (NSInteger)MAXTRACK);
	NSInteger mode = MIN(MAX([NSUserDefaults.standardUserDefaults
		integerForKey:PPPianoRecordingModeDefaultsKey], 0), 3);
	if (mode == 0) {
		return MIN(MAX([NSUserDefaults.standardUserDefaults
			integerForKey:PPPianoRecordingTrackDefaultsKey], 0), tracks - 1);
	}
	if (mode == 2) return MIN(MAX(self.selectedTrack, 0), tracks - 1);

	// The original's "all" and "following" modes assign successive played
	// notes to successive tracks. With no custom following-track set yet, both
	// traverse the available song tracks; the dedicated preference remains so
	// selected-track routing can be added without changing the stored format.
	NSInteger start = self.lastRoutedTrack;
	for (NSInteger attempt = 0; attempt < tracks; attempt++) {
		NSInteger candidate = (start + 1 + attempt + tracks) % tracks;
		if (self.music == NULL || self.music->header == NULL ||
			self.music->header->chanVol[candidate] > 0) {
			self.lastRoutedTrack = candidate;
			return candidate;
		}
	}
	self.lastRoutedTrack = (start + 1 + tracks) % tracks;
	return self.lastRoutedTrack;
}

- (void)playNote:(NSInteger)note
{
	[self playNote:note velocity:127 instrument:self.selectedInstrument track:self.selectedTrack];
}

- (BOOL)auditionNote:(NSInteger)note velocity:(NSInteger)velocity
	instrument:(NSInteger)instrument track:(NSInteger)track
{
	return [self playNote:note velocity:velocity instrument:instrument track:track];
}

- (BOOL)playNote:(NSInteger)note velocity:(NSInteger)velocity
	instrument:(NSInteger)instrumentIndex track:(NSInteger)track
{
	[self stopPreview];
	if (self.music == NULL || self.driver == NULL || instrumentIndex < 0 || instrumentIndex >= MAXINSTRU) {
		NSBeep(); return NO;
	}
	InstrData *instrument = &self.music->fid[instrumentIndex];
	if (instrument->numSamples <= 0) { NSBeep(); return NO; }
	NSInteger sampleIndex = instrument->what[MIN(MAX(note, 0), NUMBER_NOTES - 1)];
	if (sampleIndex < 0 || sampleIndex >= instrument->numSamples) sampleIndex = 0;
	sData *sample = self.music->sample[instrument->firstSample + sampleIndex];
	if (sample == NULL || sample->data == NULL || sample->size <= 2) { NSBeep(); return NO; }
	track = MIN(MAX(track, 0), MAXTRACK - 1);
	NSInteger previewChannel = PPPianoAcquirePreviewChannel(self.driver, self.music);
	if (previewChannel < 0) { NSBeep(); return NO; }
	MADDriverClearChannel(self.driver, (int)previewChannel);
	// Give the audition voice a private mixer identity. Its source track is
	// retained separately for MIDI ownership, but must not alias track 1's
	// volume, mute, pan or effect-routing state.
	self.driver->base.chan[previewChannel].TrackID = MAXTRACK - 1;
	NSInteger playbackNote = MIN(MAX(note + sample->realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(self.driver, sample->data, (size_t)sample->size, (int)previewChannel,
		(MADByte)playbackNote, sample->amp, sample->loopBeg, sample->loopSize, sample->c2spd, sample->stereo);
	if (error != MADNoErr) {
		NSBeep();
		return NO;
	} else {
		self.driver->base.chan[previewChannel].TrackID = MAXTRACK - 1;
		self.driver->base.chan[previewChannel].vol =
			(int)MIN(MAX((velocity * 64 + 63) / 127, 1), 64);
		self.localPreviewChannel = previewChannel;
		self.localPreviewNote = note;
		self.localPreviewSourceTrack = track;
	}
	return YES;
}

- (void)stopPreview
{
	NSInteger previewChannel = self.localPreviewChannel;
	PPPianoStopOwnedPreview(self.driver, &previewChannel);
	self.localPreviewChannel = previewChannel;
	self.localPreviewNote = -1;
	self.localPreviewSourceTrack = -1;
}

- (void)updatePlaybackHighlights
{
	if (!self.isWindowLoaded) return;
	NSMutableDictionary<NSNumber *, NSNumber *> *notes = [NSMutableDictionary dictionary];
	[self.midiInputNotes enumerateKeysAndObjectsUsingBlock:
		^(NSNumber *key, NSNumber *track, BOOL *stop) {
			(void)stop;
			notes[@(key.integerValue & 0xFF)] = track;
		}];
	if (self.driver != NULL && MADWasReading(self.driver)) {
		NSInteger tracks = self.music == NULL || self.music->header == NULL ? 0 : MIN(self.music->header->numChn, MAXTRACK);
		for (NSInteger track = 0; track < tracks; track++) {
			MADChannel *channel = &self.driver->base.chan[track];
			if (!self.driver->base.Active[track] || channel->note < 0 || channel->note >= NUMBER_NOTES || !channel->KeyOn) continue;
			notes[@(channel->note)] = @(channel->TrackID >= 0 ? channel->TrackID : track);
		}
	}
	if (![notes isEqualToDictionary:self.pianoView.playingNotes]) {
		self.pianoView.playingNotes = notes;
		[self.pianoView setNeedsDisplay:YES];
	}
}

- (void)handleMIDINoteOn:(NSInteger)note velocity:(NSInteger)velocity
	instrument:(NSInteger)instrument track:(NSInteger)track
{
	if (note < 0 || note >= NUMBER_NOTES) return;
	track = MIN(MAX(track, 0), MAXTRACK - 1);
	self.midiInputNotes[@((track << 8) | note)] = @(track);
	self.noteField.stringValue = [NSString stringWithFormat:
		@"MIDI %@ • velocity %03ld • instrument %03ld • track %02ld%@",
		PPPianoNoteName(note), (long)velocity, (long)instrument + 1, (long)track + 1,
		self.isRecordingEnabled ? @" • REC" : @""];
	[self playNote:note velocity:velocity instrument:instrument track:track];
	[self updatePlaybackHighlights];
}

- (void)handleMIDINoteOff:(NSInteger)note track:(NSInteger)track
{
	[self handleMIDINoteOff:note track:track stopVoice:YES];
}

- (void)handleMIDINoteOff:(NSInteger)note track:(NSInteger)track stopVoice:(BOOL)stopVoice
{
	NSNumber *key = @((track << 8) | note);
	[self.midiInputNotes removeObjectForKey:key];
	BOOL ownsPreview = self.localPreviewNote == note && self.localPreviewSourceTrack == track;
	if (stopVoice && ownsPreview) [self stopPreview];
	[self updatePlaybackHighlights];
}

- (IBAction)toggleRecord:(NSButton *)sender
{
	NSString *message = sender.state == NSControlStateValueOn
		? @"Piano recording armed • notes write to the selected track"
		: @"Piano recording off • audition only";
	self.noteField.stringValue = message;
	if (self.statusHandler != nil) self.statusHandler(message);
	[self.window makeFirstResponder:self.pianoView];
}

- (IBAction)togglePianoMode:(id)sender
{
	(void)sender;
	self.modeControl.selectedSegment = self.modeControl.selectedSegment == 0 ? 1 : 0;
	[self changePianoMode:self.modeControl];
}

- (IBAction)changePianoMode:(NSSegmentedControl *)sender
{
	[self applyPianoMode:sender.selectedSegment == 1];
	[self.window makeFirstResponder:self.pianoView];
}

- (void)applyPianoMode:(BOOL)compact
{
	self.pianoView.compactMode = compact;
	NSSize pianoSize = [self.pianoView pianoSize];
	self.pianoView.frame = NSMakeRect(0, 0, pianoSize.width, pianoSize.height);
	CGFloat contentHeight = compact ? 73 : 44;
	NSRect frame = self.window.frame;
	CGFloat top = NSMaxY(frame);
	NSRect contentRect = [self.window contentRectForFrameRect:frame];
	contentRect.size.height = contentHeight;
	NSRect newFrame = [self.window frameRectForContentRect:contentRect];
	newFrame.origin.y = top - NSHeight(newFrame);
	[self.window setFrame:newFrame display:YES animate:self.window.isVisible];
	self.scrollView.frame = NSMakeRect(26, 0, NSWidth(self.window.contentView.bounds) - 26, compact ? 73 : 44);
	NSRect minimumFrame = [self.window frameRectForContentRect:NSMakeRect(0, 0, 360, contentHeight)];
	self.window.minSize = minimumFrame.size;
	if (!compact) {
		[self.scrollView.contentView scrollToPoint:NSMakePoint(24 * 17, 0)];
		[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
	}
	[self.pianoView setNeedsDisplay:YES];
}

- (IBAction)octaveDown:(id)sender { (void)sender; [self shiftOctave:-1]; }
- (IBAction)octaveUp:(id)sender { (void)sender; [self shiftOctave:1]; }

- (void)shiftOctave:(NSInteger)amount
{
	NSInteger octaveOffset = MIN(MAX(self.pianoView.keyboardOffset + amount, -7), 7);
	[self setKeyboardOffset:octaveOffset];
	if (self.octaveHandler != nil) self.octaveHandler(octaveOffset);
	[self.window makeFirstResponder:self.pianoView];
}

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	[self.midiInputNotes removeAllObjects];
	[self stopPreview];
}
@end
