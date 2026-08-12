#import "PPPatternModeController.h"
#import "PPPatternCommandCodec.h"
#import "PPPreferences.h"

#include "MADDriver.h"
#include "RDriverInt.h"
#include <math.h>
#include <string.h>

static NSPasteboardType const PPPatternPasteboardType = @"com.playerpro.pattern-commands";

typedef struct {
	uint32_t magic;
	uint16_t version;
	uint16_t rows;
	uint16_t channels;
	uint16_t reserved;
} PPPatternClipboardHeader;

typedef NS_ENUM(NSInteger, PPPatternCanvasTool) {
	PPPatternCanvasToolNote,
	PPPatternCanvasToolSelect,
	PPPatternCanvasToolErase,
	PPPatternCanvasToolPlay,
	PPPatternCanvasToolZoom
};

@class PPPatternCanvasView;
@class PPBoxTimelineView;
@class PPBoxGutterView;
@class PPBoxPitchScrollerView;
@class PPWaveTimelineView;
@class PPWaveGutterView;
@class PPClassicalTimelineView;
@class PPClassicalGutterView;

@interface PPPatternClassicButton : NSButton
@end

typedef struct {
	float minimum;
	float maximum;
} PPWaveEnvelopePoint;

static NSInteger const PPWaveEnvelopeColumnsPerRow = 128;

@interface PPPatternModeController () <NSWindowDelegate>
@property(nonatomic) MADMusic *music;
@property(nonatomic) MADDriverRec *driver;
@property(nonatomic) NSInteger patternIndex;
@property(nonatomic) NSInteger selectedInstrument;
@property(nonatomic) NSInteger selectedChannel;
@property(nonatomic) PPPatternEditorMode mode;
@property(nonatomic) PPPatternCanvasTool tool;
@property(nonatomic, strong) PPPatternCanvasView *canvas;
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSPopUpButton *channelPopup;
@property(nonatomic, strong) NSPopUpButton *instrumentPopup;
@property(nonatomic, strong) NSTextField *positionField;
@property(nonatomic, strong) NSSlider *zoomSlider;
@property(nonatomic, strong) PPBoxTimelineView *boxTimeline;
@property(nonatomic, strong) PPBoxGutterView *boxGutter;
@property(nonatomic, strong) PPBoxPitchScrollerView *boxPitchScroller;
@property(nonatomic, strong) NSArray<NSButton *> *boxToolButtons;
@property(nonatomic, strong) NSPopUpButton *boxEffectPopup;
@property(nonatomic, strong) NSTextField *boxArgumentField;
@property(nonatomic, strong) NSTextField *boxVolumeField;
@property(nonatomic) MADEffectID boxDefaultEffect;
@property(nonatomic) MADByte boxDefaultArgument;
@property(nonatomic) MADByte boxDefaultVolume;
@property(nonatomic) CGFloat boxPitchOffset;
@property(nonatomic, strong) NSTextField *overviewZoomField;
@property(nonatomic, strong) NSTextField *overviewSizeField;
@property(nonatomic, strong) NSButton *overviewAuditionButton;
@property(nonatomic, strong) PPWaveTimelineView *waveTimeline;
@property(nonatomic, strong) PPWaveGutterView *waveGutter;
@property(nonatomic, strong) NSPopUpButton *waveSizePopup;
@property(nonatomic, strong) NSArray<NSButton *> *waveToolButtons;
@property(nonatomic, strong, nullable) NSData *waveformEnvelope;
@property(nonatomic) CGFloat waveBandSize;
@property(nonatomic) NSInteger waveformRows;
@property(nonatomic) NSInteger waveformChannels;
@property(nonatomic) BOOL wavePlayWasReading;
@property(nonatomic) BOOL wavePreviousJumpSetting;
@property(nonatomic) BOOL wavePlayGestureActive;
@property(nonatomic, strong) PPClassicalTimelineView *classicalTimeline;
@property(nonatomic, strong) PPClassicalGutterView *classicalGutter;
@property(nonatomic, strong) NSArray<NSButton *> *classicalToolButtons;
@property(nonatomic, strong) NSArray<NSButton *> *classicalLengthButtons;
@property(nonatomic, strong) NSArray<NSButton *> *classicalAccidentalButtons;
@property(nonatomic, strong) NSTextField *classicalInstrumentNameField;
@property(nonatomic) NSInteger classicalNoteLength;
@property(nonatomic) NSInteger classicalAccidental;
@property(nonatomic) BOOL classicalPlayWasReading;
@property(nonatomic) BOOL classicalPreviousJumpSetting;
@property(nonatomic) BOOL classicalPlayGestureActive;
@property(nonatomic) NSInteger classicalPlaybackEndRow;
@property(nonatomic, strong, nullable) NSData *classicalTrackReadingState;
@property(nonatomic, strong) NSTimer *playbackTimer;
@property(nonatomic) BOOL previewActive;
@property(nonatomic) NSInteger previewChannel;
@property(nonatomic) BOOL auditionEdits;
@property(nonatomic) BOOL showsBoxOctaves;
@property(nonatomic) BOOL showsTimeBands;
@property(nonatomic) BOOL showsStaffGuides;
@property(nonatomic, copy) PPPatternModeHandler changeHandler;
@property(nonatomic, copy) PPPatternModeHandler closeHandler;
- (PatData *)pattern;
- (Cmd *)commandAtRow:(NSInteger)row channel:(NSInteger)channel;
- (sData *)sampleForCommand:(Cmd *)command;
- (void)editRow:(NSInteger)row note:(NSInteger)note erase:(BOOL)erase;
- (void)previewRow:(NSInteger)row channel:(NSInteger)channel;
- (void)previewBoxNote:(NSInteger)note channel:(NSInteger)channel;
- (void)previewOverviewRow:(NSInteger)row;
- (void)clearBoxAuditionVoices;
- (void)canvasSelectionChanged;
- (void)copyCanvasSelection:(id)sender;
- (void)cutCanvasSelection:(id)sender;
- (void)pasteCanvasSelection:(id)sender;
- (void)clearCanvasSelection:(id)sender;
- (CGFloat)boxCellWidth;
- (CGFloat)boxPitchHeight;
- (CGFloat)boxTrackHeight;
- (NSString *)boxNoteName:(NSInteger)note;
- (void)boxScrollChanged:(NSNotification *)notification;
- (void)updateBoxPitchScroller;
- (void)cycleBoxZoomBackward:(BOOL)backward focusRow:(NSInteger)row note:(NSInteger)note;
- (void)updateBoxPlayback:(NSTimer *)timer;
- (void)buildBoxWindow;
- (void)buildClassicalWindow;
- (void)buildOverviewWindow;
- (void)buildWaveWindow;
- (void)renderWaveformPreview;
- (BOOL)waveEnvelopeForChannel:(NSInteger)channel row:(NSInteger)row column:(NSInteger)column
	minimum:(CGFloat *)minimum maximum:(CGFloat *)maximum;
- (void)waveScrollChanged:(nullable NSNotification *)notification;
- (void)updateWavePlayback:(NSTimer *)timer;
- (void)setWaveTool:(PPPatternCanvasTool)tool;
- (void)zoomWaveAtRow:(NSInteger)row outward:(BOOL)outward;
- (void)beginWavePlayAtRow:(NSInteger)row;
- (void)endWavePlayGesture;
- (void)handleWaveGutterTrack:(NSInteger)track modifiers:(NSEventModifierFlags)modifiers;
- (CGFloat)classicalCellWidth;
- (CGFloat)classicalTrackHeight;
- (void)classicalScrollChanged:(nullable NSNotification *)notification;
- (void)updateClassicalPlayback:(NSTimer *)timer;
- (void)setBoxTool:(PPPatternCanvasTool)tool;
- (void)editClassicalRow:(NSInteger)row note:(NSInteger)note erase:(BOOL)erase;
- (void)beginClassicalPlayAtRow:(NSInteger)row endingAtRow:(NSInteger)endRow
	limitToSelection:(BOOL)limitToSelection;
- (void)endClassicalPlayGesture;
- (void)handleClassicalGutterTrack:(NSInteger)track modifiers:(NSEventModifierFlags)modifiers;
- (void)updateOverviewInformation;
- (void)updateOverviewPlayback:(NSTimer *)timer;
- (NSImage *)classicImageNamed:(NSString *)name;
@end

@implementation PPPatternClassicButton

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	NSRect bounds = NSInsetRect(self.bounds, 0.5, 0.5);
	BOOL pressed = self.highlighted || self.state == NSControlStateValueOn;
	NSColor *fill = !self.enabled ? [NSColor colorWithCalibratedWhite:0.89 alpha:1.0] :
		(pressed ? [NSColor colorWithCalibratedWhite:0.67 alpha:1.0] :
		 [NSColor colorWithCalibratedWhite:0.86 alpha:1.0]);
	[fill setFill];
	NSRectFill(bounds);
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeRect:bounds];
	[(pressed ? [NSColor colorWithCalibratedWhite:0.43 alpha:1.0] : NSColor.whiteColor) setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(bounds) + 1, NSMinY(bounds) + 1)
		toPoint:NSMakePoint(NSMaxX(bounds) - 1, NSMinY(bounds) + 1)];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(bounds) + 1, NSMinY(bounds) + 1)
		toPoint:NSMakePoint(NSMinX(bounds) + 1, NSMaxY(bounds) - 1)];
	[(pressed ? NSColor.whiteColor : [NSColor colorWithCalibratedWhite:0.42 alpha:1.0]) setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(bounds) + 1, NSMaxY(bounds) - 1)
		toPoint:NSMakePoint(NSMaxX(bounds) - 1, NSMaxY(bounds) - 1)];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMaxX(bounds) - 1, NSMinY(bounds) + 1)
		toPoint:NSMakePoint(NSMaxX(bounds) - 1, NSMaxY(bounds) - 1)];

	NSRect content = NSInsetRect(bounds, 4, 4);
	if (self.image != nil) {
		NSSize imageSize = self.image.size;
		if (imageSize.width > 0 && imageSize.height > 0) {
			CGFloat scale = MIN(NSWidth(content) / imageSize.width,
				NSHeight(content) / imageSize.height);
			NSSize fitted = NSMakeSize(floor(imageSize.width * scale),
				floor(imageSize.height * scale));
			content = NSMakeRect(floor(NSMidX(bounds) - fitted.width / 2.0),
				floor(NSMidY(bounds) - fitted.height / 2.0), fitted.width, fitted.height);
		}
		// The classic cicn artwork carries an opaque white icon canvas. Multiply
		// preserves the colored/black pixels while allowing the button's gray
		// face to show through those legacy white pixels.
		[self.image drawInRect:content fromRect:NSZeroRect operation:NSCompositingOperationMultiply
			fraction:self.enabled ? 1.0 : 0.42 respectFlipped:YES hints:nil];
		return;
	}
	NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.alignment = NSTextAlignmentCenter;
	NSDictionary *attributes = @{
		NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:11],
		NSForegroundColorAttributeName: self.enabled ? NSColor.blackColor :
			[NSColor colorWithCalibratedWhite:0.55 alpha:1.0],
		NSParagraphStyleAttributeName: paragraph
	};
	NSSize titleSize = [self.title sizeWithAttributes:attributes];
	NSRect titleRect = NSMakeRect(NSMinX(bounds) + 2,
		floor(NSMidY(bounds) - titleSize.height / 2.0), NSWidth(bounds) - 4, titleSize.height);
	[self.title drawInRect:titleRect withAttributes:attributes];
}

@end

@interface PPPatternCanvasView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@property(nonatomic) NSInteger selectedRow;
@property(nonatomic) NSInteger selectedChannel;
@property(nonatomic) NSInteger selectedNote;
@property(nonatomic) NSInteger playbackRow;
@property(nonatomic) NSInteger selectionAnchorRow;
@property(nonatomic) NSInteger selectionAnchorNote;
@property(nonatomic) NSInteger selectionEndRow;
@property(nonatomic) NSInteger selectionEndNote;
@property(nonatomic) NSInteger selectionAnchorChannel;
@property(nonatomic) NSInteger selectionEndChannel;
@property(nonatomic) BOOL hasBoxSelection;
@property(nonatomic) BOOL draggingBoxSelection;
@property(nonatomic) BOOL draggingClassicalSelection;
@property(nonatomic) CGFloat zoom;
- (CGFloat)cellWidth;
@end

@interface PPBoxTimelineView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@end

@interface PPBoxGutterView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@end

@interface PPBoxPitchScrollerView : NSView
@property(nonatomic) CGFloat doubleValue;
@property(nonatomic) CGFloat knobProportion;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic) BOOL draggingKnob;
@property(nonatomic) CGFloat dragOffset;
@end

@interface PPWaveTimelineView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@end

@interface PPWaveGutterView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@end

@interface PPClassicalTimelineView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@end

@interface PPClassicalGutterView : NSView
@property(nonatomic, weak) PPPatternModeController *owner;
@end

static NSColor *PPBoxClassicGray(void)
{
	return [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
}

static NSDictionary<NSAttributedStringKey, id> *PPBoxLabelAttributes(void)
{
	static NSDictionary<NSAttributedStringKey, id> *attributes;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
			[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
		attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor};
	});
	return attributes;
}

static NSDictionary<NSAttributedStringKey, id> *PPBoxNoteAttributes(void)
{
	static NSDictionary<NSAttributedStringKey, id> *attributes;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSFont *font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
		attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor};
	});
	return attributes;
}

static NSColor *PPBoxTrackColor(NSInteger track)
{
	static NSArray<NSColor *> *colors;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		colors = @[
			[NSColor colorWithCalibratedRed:1.00 green:0.08 blue:0.08 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.49 green:0.77 blue:0.04 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.10 green:0.88 blue:0.88 alpha:1.0],
			[NSColor colorWithCalibratedRed:1.00 green:0.91 blue:0.04 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.65 green:0.27 blue:0.91 alpha:1.0],
			[NSColor colorWithCalibratedRed:1.00 green:0.48 blue:0.08 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.18 green:0.43 blue:1.00 alpha:1.0],
			[NSColor colorWithCalibratedRed:1.00 green:0.28 blue:0.64 alpha:1.0]
		];
	});
	return colors[MAX(track, 0) % colors.count];
}

static NSInteger PPClassicalDiatonicPosition(NSInteger note)
{
	static const NSInteger semitoneToStep[12] = {0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6};
	note = MIN(MAX(note, 0), NUMBER_NOTES - 1);
	return (note / 12) * 7 + semitoneToStep[note % 12];
}

static BOOL PPClassicalNoteIsAccidental(NSInteger note)
{
	static const BOOL accidental[12] = {NO, YES, NO, YES, NO, NO, YES, NO, YES, NO, YES, NO};
	return note >= 0 && note < NUMBER_NOTES && accidental[note % 12];
}

static NSInteger PPClassicalRhythmChunk(NSInteger remaining, NSInteger row)
{
	// The 2002 renderer did not carry a glyph through a 4/4 measure boundary;
	// it decomposed the duration into familiar dotted and straight values.
	NSInteger available = MIN(MAX(remaining, 1), 16 - (row % 16));
	static const NSInteger lengths[] = {16, 12, 8, 6, 4, 3, 2, 1};
	for (NSUInteger index = 0; index < sizeof(lengths) / sizeof(lengths[0]); index++)
		if (available >= lengths[index]) return lengths[index];
	return 1;
}

@implementation PPBoxPitchScrollerView

- (BOOL)isFlipped { return YES; }

- (NSRect)trackRect
{
	return NSMakeRect(1, 17, MAX(NSWidth(self.bounds) - 2, 1), MAX(NSHeight(self.bounds) - 34, 1));
}

- (NSRect)knobRect
{
	NSRect track = [self trackRect];
	CGFloat height = MAX(floor(NSHeight(track) * MIN(MAX(self.knobProportion, 0.05), 1.0)), 14.0);
	CGFloat travel = MAX(NSHeight(track) - height, 0.0);
	return NSMakeRect(NSMinX(track) + 2, floor(NSMinY(track) + self.doubleValue * travel),
		MAX(NSWidth(track) - 4, 1), height);
}

- (void)drawTriangleInRect:(NSRect)rect pointsDown:(BOOL)down
{
	NSBezierPath *triangle = [NSBezierPath bezierPath];
	CGFloat midX = NSMidX(rect);
	if (down) {
		[triangle moveToPoint:NSMakePoint(midX - 4, NSMidY(rect) - 2)];
		[triangle lineToPoint:NSMakePoint(midX + 4, NSMidY(rect) - 2)];
		[triangle lineToPoint:NSMakePoint(midX, NSMidY(rect) + 3)];
	} else {
		[triangle moveToPoint:NSMakePoint(midX - 4, NSMidY(rect) + 2)];
		[triangle lineToPoint:NSMakePoint(midX + 4, NSMidY(rect) + 2)];
		[triangle lineToPoint:NSMakePoint(midX, NSMidY(rect) - 3)];
	}
	[triangle closePath];
	[NSColor.blackColor setFill];
	[triangle fill];
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.76 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(NSInsetRect(self.bounds, 0.5, 0.5), 1.0);
	NSRect top = NSMakeRect(1, 1, NSWidth(self.bounds) - 2, 16);
	NSRect bottom = NSMakeRect(1, NSHeight(self.bounds) - 17, NSWidth(self.bounds) - 2, 16);
	[[NSColor colorWithCalibratedWhite:0.91 alpha:1.0] setFill];
	NSRectFill(top);
	NSRectFill(bottom);
	[[NSColor colorWithCalibratedWhite:0.58 alpha:1.0] setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(1, 16.5)
		toPoint:NSMakePoint(NSWidth(self.bounds) - 1, 16.5)];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(1, NSHeight(self.bounds) - 17.5)
		toPoint:NSMakePoint(NSWidth(self.bounds) - 1, NSHeight(self.bounds) - 17.5)];
	[self drawTriangleInRect:top pointsDown:NO];
	[self drawTriangleInRect:bottom pointsDown:YES];
	NSRect knob = [self knobRect];
	[[NSColor colorWithCalibratedRed:0.49 green:0.49 blue:0.96 alpha:1.0] setFill];
	NSRectFill(knob);
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(NSInsetRect(knob, 0.5, 0.5), 1.0);
	for (NSInteger line = 0; line < 3; line++) {
		CGFloat y = floor(NSMidY(knob) - 3 + line * 3) + 0.5;
		[[NSColor colorWithCalibratedWhite:0.92 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(knob) + 3, y)
			toPoint:NSMakePoint(NSMaxX(knob) - 3, y)];
	}
}

- (void)sendChange
{
	self.doubleValue = MIN(MAX(self.doubleValue, 0.0), 1.0);
	[self setNeedsDisplay:YES];
	if (self.action != NULL) [NSApp sendAction:self.action to:self.target from:self];
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSRect knob = [self knobRect];
	if (NSPointInRect(point, knob)) {
		self.draggingKnob = YES;
		self.dragOffset = point.y - NSMinY(knob);
		return;
	}
	if (point.y < 17) self.doubleValue -= 0.04;
	else if (point.y > NSHeight(self.bounds) - 17) self.doubleValue += 0.04;
	else self.doubleValue += point.y < NSMinY(knob) ? -self.knobProportion : self.knobProportion;
	[self sendChange];
}

- (void)mouseDragged:(NSEvent *)event
{
	if (!self.draggingKnob) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSRect track = [self trackRect];
	NSRect knob = [self knobRect];
	CGFloat travel = MAX(NSHeight(track) - NSHeight(knob), 1.0);
	self.doubleValue = (point.y - self.dragOffset - NSMinY(track)) / travel;
	[self sendChange];
}

- (void)mouseUp:(NSEvent *)event
{
	(void)event;
	self.draggingKnob = NO;
}

@end

@implementation PPBoxTimelineView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[PPBoxClassicGray() setFill];
	NSRectFill(self.bounds);
	PPPatternModeController *owner = self.owner;
	PatData *pattern = [owner pattern];
	if (owner == nil || pattern == NULL || owner.scrollView == nil) return;
	CGFloat cellWidth = [owner boxCellWidth];
	CGFloat scrollX = NSMinX(owner.scrollView.documentVisibleRect);
	NSInteger firstRow = MAX((NSInteger)floor(scrollX / cellWidth), 0);
	NSInteger finalRow = MIN((NSInteger)ceil((scrollX + NSWidth(self.bounds)) / cellWidth) + 1,
		pattern->header.size);
	NSInteger labelStep = cellWidth >= 11.0 ? 1 : cellWidth >= 7.0 ? 2 : 4;
	NSDictionary *attributes = PPBoxLabelAttributes();
	for (NSInteger row = firstRow; row < finalRow; row++) {
		CGFloat x = floor(row * cellWidth - scrollX);
		NSRect cell = NSMakeRect(x, 0, ceil(cellWidth), NSHeight(self.bounds));
		if (row == owner.canvas.playbackRow) {
			[[NSColor colorWithCalibratedRed:0.92 green:0.03 blue:0.03 alpha:1.0] setFill];
			NSRectFill(cell);
		} else if (row == owner.canvas.selectedRow) {
			[[NSColor colorWithCalibratedWhite:0.72 alpha:1.0] setFill];
			NSRectFill(cell);
		}
		[[NSColor colorWithCalibratedWhite:0.45 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(x + 0.5, 0)
			toPoint:NSMakePoint(x + 0.5, NSHeight(self.bounds))];
		if (row % labelStep == 0) {
			NSString *label = pattern->header.size > 100
				? [NSString stringWithFormat:@"%03ld", (long)row]
				: [NSString stringWithFormat:@"%02ld", (long)row];
			NSSize labelSize = [label sizeWithAttributes:attributes];
			[label drawAtPoint:NSMakePoint(floor(x + (cellWidth - labelSize.width) / 2.0),
				MAX(floor((NSHeight(self.bounds) - labelSize.height) / 2.0), 0))
				withAttributes:attributes];
		}
	}
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(0, NSHeight(self.bounds) - 0.5)
		toPoint:NSMakePoint(NSWidth(self.bounds), NSHeight(self.bounds) - 0.5)];
}

@end

@implementation PPBoxGutterView

- (BOOL)isFlipped { return YES; }

- (void)mouseDown:(NSEvent *)event
{
	PPPatternModeController *owner = self.owner;
	if (owner == nil || owner.music == NULL) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	CGFloat scrollY = NSMinY(owner.scrollView.documentVisibleRect);
	NSInteger channel = (NSInteger)floor((point.y + scrollY) / [owner boxTrackHeight]);
	if (channel < 0 || channel >= owner.music->header->numChn) return;
	owner.selectedChannel = channel;
	owner.canvas.selectedChannel = channel;
	if (owner.driver != NULL && (event.modifierFlags & NSEventModifierFlagCommand)) {
		owner.driver->base.Active[channel] = !owner.driver->base.Active[channel];
	} else if (owner.driver != NULL && (event.modifierFlags & NSEventModifierFlagOption)) {
		BOOL onlyThisTrack = owner.driver->base.Active[channel];
		for (NSInteger index = 0; index < owner.music->header->numChn; index++) {
			if (index != channel && owner.driver->base.Active[index]) {
				onlyThisTrack = NO;
				break;
			}
		}
		for (NSInteger index = 0; index < owner.music->header->numChn; index++) {
			owner.driver->base.Active[index] = onlyThisTrack || index == channel;
		}
	}
	[owner canvasSelectionChanged];
	[owner.canvas setNeedsDisplay:YES];
	[self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[PPBoxClassicGray() setFill];
	NSRectFill(self.bounds);
	PPPatternModeController *owner = self.owner;
	if (owner == nil || owner.music == NULL || owner.scrollView == nil) return;
	CGFloat laneHeight = [owner boxTrackHeight];
	CGFloat pitchHeight = [owner boxPitchHeight];
	CGFloat scrollY = NSMinY(owner.scrollView.documentVisibleRect);
	NSInteger firstChannel = MAX((NSInteger)floor(scrollY / laneHeight), 0);
	NSInteger lastChannel = MIN((NSInteger)ceil((scrollY + NSHeight(self.bounds)) / laneHeight),
		owner.music->header->numChn);
	NSDictionary *attributes = PPBoxLabelAttributes();
	for (NSInteger channel = firstChannel; channel < lastChannel; channel++) {
		CGFloat y = floor(channel * laneHeight - scrollY);
		NSRect lane = NSMakeRect(0, y, NSWidth(self.bounds), laneHeight);
		BOOL active = owner.driver == NULL || owner.driver->base.Active[channel];
		NSColor *trackColor = active ? PPBoxTrackColor(channel) :
			[NSColor colorWithCalibratedWhite:0.74 alpha:1.0];
		[trackColor setFill];
		NSRectFill(NSMakeRect(0, y, 32, laneHeight));
		[NSColor.blackColor setStroke];
		NSFrameRectWithWidth(NSInsetRect(NSMakeRect(0, y, 32, laneHeight), 0.5, 0.5), 1.0);
		NSString *track = [NSString stringWithFormat:@"%02ld", (long)channel + 1];
		NSSize trackSize = [track sizeWithAttributes:attributes];
		[track drawAtPoint:NSMakePoint(floor((32 - trackSize.width) / 2.0),
			floor(y + (laneHeight - trackSize.height) / 2.0)) withAttributes:attributes];

		[[NSColor colorWithCalibratedWhite:0.96 alpha:1.0] setFill];
		NSRectFill(NSMakeRect(51, y, NSWidth(self.bounds) - 51, laneHeight));
		NSInteger firstPitch = MAX((NSInteger)floor(owner.boxPitchOffset / pitchHeight), 0);
		CGFloat pitchRemainder = owner.boxPitchOffset - firstPitch * pitchHeight;
		for (NSInteger pitch = firstPitch; pitch <= NUMBER_NOTES; pitch++) {
			CGFloat noteY = y + (pitch - firstPitch) * pitchHeight - pitchRemainder;
			if (noteY >= y + laneHeight) break;
			if (noteY + pitchHeight <= y) continue;
			NSInteger note = NUMBER_NOTES - 1 - pitch;
			if (note < 0 || note >= NUMBER_NOTES) continue;
			NSString *label = [owner boxNoteName:note];
			NSSize labelSize = [label sizeWithAttributes:attributes];
			[label drawAtPoint:NSMakePoint(MAX(NSWidth(self.bounds) - labelSize.width - 3, 53),
				floor(noteY + (pitchHeight - labelSize.height) / 2.0)) withAttributes:attributes];
			[[NSColor colorWithCalibratedWhite:0.62 alpha:1.0] setStroke];
			[NSBezierPath strokeLineFromPoint:NSMakePoint(51, floor(noteY + pitchHeight) - 0.5)
				toPoint:NSMakePoint(NSWidth(self.bounds), floor(noteY + pitchHeight) - 0.5)];
		}
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, NSMaxY(lane) - 0.5)
			toPoint:NSMakePoint(NSWidth(self.bounds), NSMaxY(lane) - 0.5)];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(50.5, y)
			toPoint:NSMakePoint(50.5, NSMaxY(lane))];
		if (channel == owner.canvas.selectedChannel) {
			[[NSColor colorWithCalibratedRed:0.15 green:0.26 blue:0.75 alpha:1.0] setStroke];
			NSFrameRectWithWidth(NSInsetRect(lane, 1.5, 1.5), 2.0);
		}
	}
}

@end

@implementation PPWaveTimelineView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	PPPatternModeController *owner = self.owner;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	if (owner == nil || owner.canvas == nil || owner.scrollView == nil) return;
	PatData *pattern = [owner pattern];
	if (pattern == NULL) return;

	CGFloat cellWidth = MAX([owner.canvas cellWidth], 1.0);
	CGFloat offset = owner.scrollView.contentView.bounds.origin.x;
	NSInteger rows = pattern->header.size;
	NSInteger firstRow = MAX((NSInteger)floor(offset / cellWidth), 0);
	NSInteger finalRow = MIN((NSInteger)ceil((offset + NSWidth(self.bounds)) / cellWidth) + 1, rows);
	NSInteger digits = rows > 100 ? 3 : 2;
	NSInteger labelStep = 1;
	while (cellWidth * labelStep < digits * 6.0 + 4.0) labelStep *= 2;
	NSDictionary *attributes = PPBoxLabelAttributes();

	[[NSColor colorWithCalibratedWhite:0.78 alpha:1.0] setStroke];
	for (NSInteger row = firstRow; row <= finalRow; row++) {
		CGFloat x = floor(row * cellWidth - offset) + 0.5;
		[NSBezierPath strokeLineFromPoint:NSMakePoint(x, 0)
			toPoint:NSMakePoint(x, NSHeight(self.bounds))];
	}
	[NSColor.blackColor setStroke];
	for (NSInteger row = firstRow - firstRow % labelStep; row < finalRow; row += labelStep) {
		if (row < 0) continue;
		CGFloat left = row * cellWidth - offset;
		CGFloat right = MIN((row + labelStep) * cellWidth - offset, rows * cellWidth - offset);
		if (right <= 0 || left >= NSWidth(self.bounds)) continue;
		NSString *label = [NSString stringWithFormat:digits == 3 ? @"%03ld" : @"%02ld", (long)row];
		NSSize labelSize = [label sizeWithAttributes:attributes];
		[label drawAtPoint:NSMakePoint(floor((left + right - labelSize.width) / 2.0),
			floor((NSHeight(self.bounds) - labelSize.height) / 2.0)) withAttributes:attributes];
		CGFloat edge = floor(left) + 0.5;
		[NSBezierPath strokeLineFromPoint:NSMakePoint(edge, 0)
			toPoint:NSMakePoint(edge, NSHeight(self.bounds))];
	}
	[NSBezierPath strokeLineFromPoint:NSMakePoint(0, 0.5)
		toPoint:NSMakePoint(NSWidth(self.bounds), 0.5)];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(0, NSHeight(self.bounds) - 0.5)
		toPoint:NSMakePoint(NSWidth(self.bounds), NSHeight(self.bounds) - 0.5)];
}

@end

@implementation PPWaveGutterView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	PPPatternModeController *owner = self.owner;
	[PPBoxClassicGray() setFill];
	NSRectFill(self.bounds);
	if (owner == nil || owner.scrollView == nil || owner.music == NULL) return;

	CGFloat band = MAX(owner.waveBandSize, 1.0);
	CGFloat offset = owner.scrollView.contentView.bounds.origin.y;
	NSInteger channels = MAX((NSInteger)owner.music->header->numChn, 1);
	NSInteger firstChannel = MAX((NSInteger)floor(offset / band), 0);
	NSInteger finalChannel = MIN((NSInteger)ceil((offset + NSHeight(self.bounds)) / band) + 1, channels);
	NSDictionary *attributes = PPBoxLabelAttributes();
	for (NSInteger channel = firstChannel; channel < finalChannel; channel++) {
		CGFloat y = floor(channel * band - offset);
		NSRect lane = NSMakeRect(0, y, NSWidth(self.bounds), ceil(band));
		[PPBoxTrackColor(channel) setFill];
		NSRectFill(lane);
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, NSMaxY(lane) - 0.5)
			toPoint:NSMakePoint(NSWidth(self.bounds), NSMaxY(lane) - 0.5)];
		NSString *label = [NSString stringWithFormat:@"%02ld", (long)channel + 1];
		NSSize labelSize = [label sizeWithAttributes:attributes];
		NSDictionary *labelAttributes = attributes;
		if (owner.driver != NULL && !owner.driver->base.Active[channel]) {
			labelAttributes = @{NSFontAttributeName:attributes[NSFontAttributeName],
				NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:0.45 alpha:1.0]};
		}
		[label drawAtPoint:NSMakePoint(floor((NSWidth(lane) - labelSize.width) / 2.0),
			floor(NSMidY(lane) - labelSize.height / 2.0)) withAttributes:labelAttributes];
	}
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSWidth(self.bounds) - 0.5, 0)
		toPoint:NSMakePoint(NSWidth(self.bounds) - 0.5, NSHeight(self.bounds))];
}

- (void)mouseDown:(NSEvent *)event
{
	PPPatternModeController *owner = self.owner;
	if (owner == nil || owner.scrollView == nil) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	CGFloat offset = owner.scrollView.contentView.bounds.origin.y;
	NSInteger track = (NSInteger)floor((point.y + offset) / MAX(owner.waveBandSize, 1.0));
	[owner handleWaveGutterTrack:track modifiers:event.modifierFlags];
}

@end

@implementation PPClassicalTimelineView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	PPPatternModeController *owner = self.owner;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	if (owner == nil || owner.scrollView == nil || owner.canvas == nil) return;
	PatData *pattern = [owner pattern];
	if (pattern == NULL) return;

	CGFloat cellWidth = MAX([owner classicalCellWidth], 1.0);
	CGFloat offset = owner.scrollView.contentView.bounds.origin.x;
	NSInteger rows = pattern->header.size;
	NSInteger digits = rows > 100 ? 3 : 2;
	NSInteger labelStep = 1;
	while (cellWidth * labelStep < digits * 6.0 + 4.0) labelStep *= 2;
	NSInteger firstRow = MAX((NSInteger)floor(offset / cellWidth), 0);
	NSInteger finalRow = MIN((NSInteger)ceil((offset + NSWidth(self.bounds)) / cellWidth) + 1, rows);
	NSDictionary *attributes = PPBoxLabelAttributes();

	for (NSInteger row = firstRow - firstRow % labelStep; row < finalRow; row += labelStep) {
		if (row < 0) continue;
		CGFloat x = floor(row * cellWidth - offset);
		CGFloat width = MIN(labelStep * cellWidth, rows * cellWidth - row * cellWidth);
		// PlayerPRO 2002 banded the position ruler in four-row groups while
		// leaving the notation area itself white.
		if ((row / 4) % 2 == 0) {
			[[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:0.64 alpha:1.0] setFill];
			NSRectFill(NSMakeRect(x, 1, width, NSHeight(self.bounds) - 2));
		}
		if (row == owner.canvas.playbackRow) {
			[[NSColor colorWithCalibratedRed:0.96 green:0.42 blue:0.45 alpha:1.0] setFill];
			NSRectFill(NSMakeRect(x, 1, width, NSHeight(self.bounds) - 2));
		}
		NSString *label = [NSString stringWithFormat:digits == 3 ? @"%03ld" : @"%02ld", (long)row];
		NSSize size = [label sizeWithAttributes:attributes];
		[label drawAtPoint:NSMakePoint(floor(x + (width - size.width) / 2.0),
			floor((NSHeight(self.bounds) - size.height) / 2.0)) withAttributes:attributes];
		[[NSColor colorWithCalibratedWhite:0.58 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(x + 0.5, 0)
			toPoint:NSMakePoint(x + 0.5, NSHeight(self.bounds))];
	}
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(0, 0.5)
		toPoint:NSMakePoint(NSWidth(self.bounds), 0.5)];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(0, NSHeight(self.bounds) - 0.5)
		toPoint:NSMakePoint(NSWidth(self.bounds), NSHeight(self.bounds) - 0.5)];
}

- (NSInteger)rowForEvent:(NSEvent *)event
{
	PPPatternModeController *owner = self.owner;
	if (owner == nil || owner.scrollView == nil) return -1;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	CGFloat x = point.x + owner.scrollView.contentView.bounds.origin.x;
	PatData *pattern = [owner pattern];
	if (pattern == NULL) return -1;
	return MIN(MAX((NSInteger)floor(x / MAX([owner classicalCellWidth], 1.0)), 0),
		pattern->header.size - 1);
}

- (void)mouseDown:(NSEvent *)event
{
	NSInteger row = [self rowForEvent:event];
	if (row < 0) return;
	self.owner.canvas.selectedRow = row;
	[self.owner canvasSelectionChanged];
	[self.owner beginClassicalPlayAtRow:row endingAtRow:[self.owner pattern]->header.size - 1
		limitToSelection:NO];
}

- (void)mouseDragged:(NSEvent *)event
{
	NSInteger row = [self rowForEvent:event];
	if (row < 0 || row == self.owner.canvas.selectedRow) return;
	self.owner.canvas.selectedRow = row;
	[self.owner beginClassicalPlayAtRow:row endingAtRow:[self.owner pattern]->header.size - 1
		limitToSelection:NO];
	[self.owner canvasSelectionChanged];
}

- (void)mouseUp:(NSEvent *)event
{
	(void)event;
	[self.owner endClassicalPlayGesture];
}

@end

@implementation PPClassicalGutterView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	PPPatternModeController *owner = self.owner;
	[PPBoxClassicGray() setFill];
	NSRectFill(self.bounds);
	if (owner == nil || owner.scrollView == nil || owner.music == NULL) return;
	CGFloat laneHeight = MAX([owner classicalTrackHeight], 1.0);
	CGFloat offset = owner.scrollView.contentView.bounds.origin.y;
	NSInteger channels = MAX((NSInteger)owner.music->header->numChn, 1);
	NSInteger first = MAX((NSInteger)floor(offset / laneHeight), 0);
	NSInteger last = MIN((NSInteger)ceil((offset + NSHeight(self.bounds)) / laneHeight) + 1, channels);
	NSDictionary *labelAttributes = PPBoxLabelAttributes();
	NSFont *musicFont = [NSFont fontWithName:@"Apple Symbols" size:32.0 * owner.canvas.zoom] ?:
		[NSFont systemFontOfSize:32.0 * owner.canvas.zoom];
	NSDictionary *musicAttributes = @{NSFontAttributeName:musicFont, NSForegroundColorAttributeName:NSColor.blackColor};

	for (NSInteger channel = first; channel < last; channel++) {
		CGFloat y = floor(channel * laneHeight - offset);
		NSRect lane = NSMakeRect(0, y, NSWidth(self.bounds), ceil(laneHeight));
		BOOL active = owner.driver == NULL || owner.driver->base.Active[channel];
		[NSColor.whiteColor setFill];
		NSRectFill(lane);
		[PPBoxTrackColor(channel) setFill];
		NSRectFill(NSMakeRect(0, y, 25, NSHeight(lane)));
		NSString *label = [NSString stringWithFormat:@"%02ld", (long)channel + 1];
		NSMutableDictionary *trackAttributes = [labelAttributes mutableCopy];
		if (!active) trackAttributes[NSForegroundColorAttributeName] =
			[NSColor colorWithCalibratedWhite:0.47 alpha:1.0];
		NSSize labelSize = [label sizeWithAttributes:trackAttributes];
		[label drawAtPoint:NSMakePoint(floor((25 - labelSize.width) / 2.0),
			floor(NSMidY(lane) - labelSize.height / 2.0)) withAttributes:trackAttributes];

		NSMutableDictionary *clefAttributes = [musicAttributes mutableCopy];
		if (!active) clefAttributes[NSForegroundColorAttributeName] =
			[NSColor colorWithCalibratedWhite:0.47 alpha:1.0];
		[@"𝄞" drawAtPoint:NSMakePoint(26, y + 7 * owner.canvas.zoom) withAttributes:clefAttributes];
		[@"𝄢" drawAtPoint:NSMakePoint(26, y + 59 * owner.canvas.zoom) withAttributes:clefAttributes];
		NSDictionary *timeAttributes = @{NSFontAttributeName:[NSFont boldSystemFontOfSize:12 * owner.canvas.zoom],
			NSForegroundColorAttributeName:active ? NSColor.blackColor :
				[NSColor colorWithCalibratedWhite:0.47 alpha:1.0]};
		[@"4\n4" drawInRect:NSMakeRect(48, y + 18 * owner.canvas.zoom, 14,
			34 * owner.canvas.zoom) withAttributes:timeAttributes];
		[@"4\n4" drawInRect:NSMakeRect(48, y + 70 * owner.canvas.zoom, 14,
			34 * owner.canvas.zoom) withAttributes:timeAttributes];
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(24.5, y)
			toPoint:NSMakePoint(24.5, NSMaxY(lane))];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, NSMaxY(lane) - 0.5)
			toPoint:NSMakePoint(NSWidth(self.bounds), NSMaxY(lane) - 0.5)];
	}
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSWidth(self.bounds) - 0.5, 0)
		toPoint:NSMakePoint(NSWidth(self.bounds) - 0.5, NSHeight(self.bounds))];
}

- (void)mouseDown:(NSEvent *)event
{
	PPPatternModeController *owner = self.owner;
	if (owner == nil || owner.scrollView == nil) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSInteger track = (NSInteger)floor((point.y + owner.scrollView.contentView.bounds.origin.y) /
		MAX([owner classicalTrackHeight], 1.0));
	[owner handleClassicalGutterTrack:track modifiers:event.modifierFlags];
}

@end

@implementation PPPatternCanvasView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (CGFloat)cellWidth
{
	switch (self.owner.mode) {
		case PPPatternEditorModeClassical: return [self.owner classicalCellWidth];
		case PPPatternEditorModeBox: return [self.owner boxCellWidth];
		case PPPatternEditorModeClassicOverview: return 10.0 * self.zoom;
		case PPPatternEditorModeWave: return 8.0 * self.zoom;
	}
}

- (CGFloat)boxPitchHeight { return [self.owner boxPitchHeight]; }
- (CGFloat)overviewBandHeight { return 48.0 * self.zoom; }
- (CGFloat)waveBandHeight { return MAX(self.owner.waveBandSize, 16.0); }

- (NSSize)requiredSize
{
	PatData *pattern = [self.owner pattern];
	NSInteger rows = pattern == NULL ? 64 : pattern->header.size;
	NSInteger channels = self.owner.music == NULL ? 4 : MAX(self.owner.music->header->numChn, 1);
	CGFloat width = MAX(620.0, rows * self.cellWidth + 1);
	switch (self.owner.mode) {
		case PPPatternEditorModeBox:
			return NSMakeSize(width, channels * [self.owner boxTrackHeight] + 1);
		case PPPatternEditorModeClassical: {
			CGFloat viewportHeight = self.owner.scrollView == nil ? 300.0 :
				NSHeight(self.owner.scrollView.contentView.bounds);
			return NSMakeSize(width, MAX(channels * [self.owner classicalTrackHeight] + 1,
				viewportHeight));
		}
		case PPPatternEditorModeClassicOverview: {
			CGFloat viewportHeight = self.owner.scrollView == nil ? 220.0 : NSHeight(self.owner.scrollView.contentView.bounds);
			return NSMakeSize(width, MAX(viewportHeight, 220.0));
		}
		case PPPatternEditorModeWave: {
			CGFloat viewportHeight = self.owner.scrollView == nil ? 300.0 :
				NSHeight(self.owner.scrollView.contentView.bounds);
			return NSMakeSize(width, MAX(channels * self.waveBandHeight + 1, viewportHeight));
		}
	}
}

- (void)resizeForContent
{
	[self setFrameSize:[self requiredSize]];
	[self setNeedsDisplay:YES];
}

- (NSColor *)colorForInstrument:(NSInteger)instrument
{
	static NSArray<NSColor *> *colors;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		colors = @[
			[NSColor colorWithCalibratedRed:0.16 green:0.42 blue:0.88 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.10 green:0.63 blue:0.24 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.83 green:0.20 blue:0.31 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.79 green:0.48 blue:0.03 alpha:1.0],
			[NSColor colorWithCalibratedRed:0.48 green:0.25 blue:0.78 alpha:1.0]
		];
	});
	return colors[MAX(instrument - 1, 0) % colors.count];
}

- (NSColor *)colorForChannel:(NSInteger)channel
{
	return self.owner.mode == PPPatternEditorModeBox
		? PPBoxTrackColor(channel) : PPPreferredTrackColor(channel);
}

- (void)drawTimeGridWithHeight:(CGFloat)height
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return;
	for (NSInteger row = 0; row <= pattern->header.size; row++) {
		CGFloat x = row * self.cellWidth;
		if (row < pattern->header.size && self.owner.showsTimeBands && (row / 8) % 2 == 0) {
			[[NSColor colorWithCalibratedRed:1.0 green:0.97 blue:0.78 alpha:0.42] setFill];
			NSRectFill(NSMakeRect(x, 0, self.cellWidth, height));
		}
		[(row % 8 == 0 ? [NSColor colorWithCalibratedWhite:0.48 alpha:1.0]
			: [NSColor colorWithCalibratedWhite:0.82 alpha:1.0]) setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(x, 0) toPoint:NSMakePoint(x, height)];
	}
	if (self.selectedRow >= 0) {
		[[NSColor colorWithCalibratedRed:0.25 green:0.53 blue:0.96 alpha:0.18] setFill];
		NSRectFill(NSMakeRect(self.selectedRow * self.cellWidth, 0, self.cellWidth, height));
	}
}

- (void)drawBoxMode
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return;
	NSInteger channels = MAX((NSInteger)self.owner.music->header->numChn, 1);
	CGFloat laneHeight = [self.owner boxTrackHeight];
	CGFloat pitchHeight = self.boxPitchHeight;
	CGFloat cellWidth = self.cellWidth;
	NSInteger firstRow = MAX((NSInteger)floor(NSMinX(self.visibleRect) / cellWidth), 0);
	NSInteger finalRow = MIN((NSInteger)ceil(NSMaxX(self.visibleRect) / cellWidth) + 1,
		pattern->header.size);
	NSInteger firstChannel = MAX((NSInteger)floor(NSMinY(self.visibleRect) / laneHeight), 0);
	NSInteger finalChannel = MIN((NSInteger)ceil(NSMaxY(self.visibleRect) / laneHeight) + 1, channels);
	NSInteger firstPitch = MAX((NSInteger)floor(self.owner.boxPitchOffset / pitchHeight), 0);
	CGFloat pitchRemainder = self.owner.boxPitchOffset - firstPitch * pitchHeight;
	NSColor *yellow = [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:0.60 alpha:1.0];
	NSColor *green = [NSColor colorWithCalibratedRed:0.60 green:1.0 blue:0.60 alpha:1.0];
	NSColor *cyan = [NSColor colorWithCalibratedRed:0.40 green:1.0 blue:1.0 alpha:1.0];
	NSColor *grid = [NSColor colorWithCalibratedWhite:0.58 alpha:1.0];
	static const BOOL blackKey[12] = {
		NO, YES, NO, YES, NO, NO, YES, NO, YES, NO, YES, NO
	};

	for (NSInteger channel = firstChannel; channel < finalChannel; channel++) {
		CGFloat laneY = channel * laneHeight;
		[NSColor.whiteColor setFill];
		NSRectFill(NSMakeRect(0, laneY, NSWidth(self.bounds), laneHeight));

		if (self.owner.showsTimeBands) {
			[yellow setFill];
			for (NSInteger row = firstRow; row < finalRow; row++) {
				if ((row / 4) % 2 == 0) {
					NSRectFill(NSMakeRect(row * cellWidth, laneY, ceil(cellWidth), laneHeight));
				}
			}
		}

		if (self.owner.showsBoxOctaves) {
			for (NSInteger pitch = firstPitch; pitch <= NUMBER_NOTES; pitch++) {
				CGFloat noteY = laneY + (pitch - firstPitch) * pitchHeight - pitchRemainder;
				if (noteY >= laneY + laneHeight) break;
				if (noteY + pitchHeight <= laneY) continue;
				NSInteger note = NUMBER_NOTES - 1 - pitch;
				if (note < 0 || note >= NUMBER_NOTES || !blackKey[note % 12]) continue;
				[((note / 12) % 2 == 0 ? green : cyan) setFill];
				NSRectFill(NSMakeRect(0, noteY, NSWidth(self.bounds), pitchHeight));
			}
		}

		[grid setStroke];
		for (NSInteger pitch = firstPitch; pitch <= NUMBER_NOTES; pitch++) {
			CGFloat y = floor(laneY + (pitch - firstPitch) * pitchHeight - pitchRemainder) + 0.5;
			if (y < laneY || y > laneY + laneHeight) continue;
			[NSBezierPath strokeLineFromPoint:NSMakePoint(0, y)
				toPoint:NSMakePoint(NSWidth(self.bounds), y)];
		}
		for (NSInteger row = firstRow; row <= finalRow; row++) {
			CGFloat x = floor(row * cellWidth) + 0.5;
			[NSBezierPath strokeLineFromPoint:NSMakePoint(x, laneY)
				toPoint:NSMakePoint(x, laneY + laneHeight)];
		}
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, laneY + 0.5)
			toPoint:NSMakePoint(NSWidth(self.bounds), laneY + 0.5)];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, laneY + laneHeight - 0.5)
			toPoint:NSMakePoint(NSWidth(self.bounds), laneY + laneHeight - 0.5)];

		for (NSInteger row = firstRow; row < finalRow; row++) {
			Cmd *command = [self.owner commandAtRow:row channel:channel];
			if (command == NULL || command->note == 0xFF || command->note >= NUMBER_NOTES) continue;
			NSInteger pitch = NUMBER_NOTES - 1 - command->note;
			CGFloat y = laneY + pitch * pitchHeight - self.owner.boxPitchOffset;
			if (y + pitchHeight <= laneY || y >= laneY + laneHeight) continue;
			NSRect noteRect = NSIntersectionRect(NSMakeRect(row * cellWidth + 0.5, y + 0.5,
				MAX(cellWidth, 2), MAX(pitchHeight - 1, 2)),
				NSMakeRect(0, laneY + 1, NSWidth(self.bounds), laneHeight - 2));
			BOOL active = self.owner.driver == NULL || self.owner.driver->base.Active[channel];
			[(active ? [self colorForChannel:channel] :
				[NSColor colorWithCalibratedWhite:0.72 alpha:1.0]) setFill];
			NSRectFill(noteRect);
			[NSColor.blackColor setStroke];
			NSFrameRectWithWidth(NSInsetRect(noteRect, 0.5, 0.5), 1.5);
			if (cellWidth > 8.0 && command->ins > 0) {
				NSString *instrument = cellWidth > 22.0
					? [NSString stringWithFormat:@"%03u", command->ins]
					: [NSString stringWithFormat:@"%02u", command->ins % 100];
				NSDictionary *attributes = PPBoxNoteAttributes();
				NSSize size = [instrument sizeWithAttributes:attributes];
				if (size.width <= NSWidth(noteRect) - 1 && size.height <= NSHeight(noteRect) + 2) {
					[instrument drawAtPoint:NSMakePoint(floor(NSMidX(noteRect) - size.width / 2.0),
						floor(NSMidY(noteRect) - size.height / 2.0)) withAttributes:attributes];
				}
			}
		}
	}

	if (self.hasBoxSelection && self.selectedChannel >= 0) {
		NSInteger startRow = MIN(self.selectionAnchorRow, self.selectionEndRow);
		NSInteger endRow = MAX(self.selectionAnchorRow, self.selectionEndRow);
		NSInteger highNote = MAX(self.selectionAnchorNote, self.selectionEndNote);
		NSInteger lowNote = MIN(self.selectionAnchorNote, self.selectionEndNote);
		CGFloat laneY = self.selectedChannel * laneHeight;
		CGFloat top = laneY + (NUMBER_NOTES - 1 - highNote) * pitchHeight -
			self.owner.boxPitchOffset;
		CGFloat bottom = laneY + (NUMBER_NOTES - lowNote) * pitchHeight -
			self.owner.boxPitchOffset;
		NSRect selection = NSIntersectionRect(NSMakeRect(startRow * cellWidth, top,
			(endRow - startRow + 1) * cellWidth, bottom - top),
			NSMakeRect(0, laneY, NSWidth(self.bounds), laneHeight));
		[[NSColor colorWithCalibratedRed:0.95 green:0.12 blue:0.35 alpha:0.30] setFill];
		NSRectFill(selection);
		[[NSColor colorWithCalibratedRed:0.60 green:0.0 blue:0.18 alpha:1.0] setStroke];
		NSBezierPath *outline = [NSBezierPath bezierPathWithRect:NSInsetRect(selection, 0.5, 0.5)];
		outline.lineWidth = 2.0;
		CGFloat dash[] = {5, 2};
		[outline setLineDash:dash count:2 phase:0];
		[outline stroke];
	}
}

- (CGFloat)yForClassicalNote:(NSInteger)note channel:(NSInteger)channel
{
	CGFloat laneHeight = [self.owner classicalTrackHeight];
	CGFloat localY = laneHeight / 2.0 + 3.0 * self.zoom +
		3.5 * self.zoom * (30 - PPClassicalDiatonicPosition(note));
	return channel * laneHeight + localY;
}

- (NSInteger)classicalDurationAtRow:(NSInteger)row channel:(NSInteger)channel
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return 1;
	for (NSInteger next = row + 1; next < pattern->header.size; next++) {
		Cmd *command = [self.owner commandAtRow:next channel:channel];
		if (command != NULL && command->note != 0xFF) return MAX(next - row, 1);
	}
	return MAX(pattern->header.size - row, 1);
}

- (NSInteger)classicalLengthIndexForDuration:(NSInteger)duration
{
	if (duration >= 16) return 0;
	if (duration >= 8) return 1;
	if (duration >= 4) return 2;
	if (duration >= 2) return 3;
	return 4;
}

- (void)drawClassicalNoteAtX:(CGFloat)x y:(CGFloat)y duration:(NSInteger)duration
	instrument:(NSInteger)instrument active:(BOOL)active
{
	CGFloat zoom = self.zoom;
	NSInteger lengthIndex = [self classicalLengthIndexForDuration:duration];
	NSColor *ink = active ? NSColor.blackColor : [NSColor colorWithCalibratedWhite:0.50 alpha:1.0];
	NSArray<NSString *> *names = @[@"16", @"8", @"4", @"2", @"1"];
	NSImage *image = [self.owner classicImageNamed:
		[@"classic-staff-note-" stringByAppendingString:names[lengthIndex]]];
	if (image != nil) {
		// Resources 500-504 are the original upward-stem 12x19 PlayerPRO
		// notation pixels. Keeping every stem above the head leaves the original
		// instrument annotation unobstructed below it.
		CGFloat top = y - 16.0 * zoom;
		NSRect iconRect = NSMakeRect(x - 6.0 * zoom, top, 12.0 * zoom, 19.0 * zoom);
		[image drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
			fraction:active ? 1.0 : 0.45 respectFlipped:YES
			hints:@{NSImageHintInterpolation:@(NSImageInterpolationNone)}];
	} else {
		// Keep a small vector fallback for development builds missing resources.
		NSRect head = NSMakeRect(x - 4 * zoom, y - 2.5 * zoom, 8 * zoom, 5 * zoom);
		NSBezierPath *headPath = [NSBezierPath bezierPathWithOvalInRect:head];
		[ink setStroke]; [ink setFill];
		if (lengthIndex <= 1) [headPath stroke]; else [headPath fill];
	}
	if (duration == 3 || duration == 6 || duration == 12) {
		NSImage *dot = [self.owner classicImageNamed:@"classic-staff-dot"];
		if (dot != nil) {
			[dot drawInRect:NSMakeRect(x + 5 * zoom, y - 9 * zoom, 12 * zoom, 19 * zoom)
				fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
				fraction:active ? 1.0 : 0.45 respectFlipped:YES
				hints:@{NSImageHintInterpolation:@(NSImageInterpolationNone)}];
		}
	}
	if (instrument > 0 && self.cellWidth >= 16.0) {
		NSString *label = [NSString stringWithFormat:@"%ld", (long)instrument];
		NSDictionary *attributes = @{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:9 * zoom
			weight:NSFontWeightMedium], NSForegroundColorAttributeName:ink};
		NSSize size = [label sizeWithAttributes:attributes];
		[label drawAtPoint:NSMakePoint(floor(x - size.width / 2.0), y + 6 * zoom)
			withAttributes:attributes];
	}
}

- (void)drawClassicalRestAtX:(CGFloat)x laneY:(CGFloat)laneY duration:(NSInteger)duration
	active:(BOOL)active
{
	CGFloat zoom = self.zoom;
	NSInteger lengthIndex = [self classicalLengthIndexForDuration:duration];
	NSArray<NSString *> *names = @[@"16", @"8", @"4", @"2", @"1"];
	NSImage *image = [self.owner classicImageNamed:
		[@"classic-staff-rest-" stringByAppendingString:names[lengthIndex]]];
	CGFloat y = laneY + 66 * zoom;
	if (image != nil) {
		[image drawInRect:NSMakeRect(x - 6 * zoom, y, 12 * zoom, 19 * zoom)
			fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
			fraction:active ? 1.0 : 0.45 respectFlipped:YES
				hints:@{NSImageHintInterpolation:@(NSImageInterpolationNone)}];
	}
	if (duration == 3 || duration == 6 || duration == 12) {
		NSImage *dot = [self.owner classicImageNamed:@"classic-staff-dot"];
		[dot drawInRect:NSMakeRect(x + 5 * zoom, y, 12 * zoom, 19 * zoom)
			fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
			fraction:active ? 1.0 : 0.45 respectFlipped:YES
			hints:@{NSImageHintInterpolation:@(NSImageInterpolationNone)}];
	}
}

- (void)drawClassicalMode
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return;
	NSInteger channels = MAX((NSInteger)self.owner.music->header->numChn, 1);
	CGFloat laneHeight = [self.owner classicalTrackHeight];
	CGFloat cellWidth = self.cellWidth;
	CGFloat patternWidth = pattern->header.size * cellWidth;
	NSInteger firstRow = MAX((NSInteger)floor(NSMinX(self.visibleRect) / cellWidth), 0);
	NSInteger finalRow = MIN((NSInteger)ceil(NSMaxX(self.visibleRect) / cellWidth) + 1,
		pattern->header.size);
	NSInteger firstChannel = MAX((NSInteger)floor(NSMinY(self.visibleRect) / laneHeight), 0);
	NSInteger finalChannel = MIN((NSInteger)ceil(NSMaxY(self.visibleRect) / laneHeight) + 1, channels);
	[PPBoxClassicGray() setFill];
	NSRectFill(self.bounds);

	for (NSInteger channel = firstChannel; channel < finalChannel; channel++) {
		CGFloat laneY = channel * laneHeight;
		BOOL active = self.owner.driver == NULL || self.owner.driver->base.Active[channel];
		[NSColor.whiteColor setFill];
		NSRectFill(NSMakeRect(0, laneY, patternWidth, laneHeight));

		if (self.owner.showsStaffGuides) {
			NSColor *staffColor = active ? NSColor.blackColor :
				[NSColor colorWithCalibratedWhite:0.55 alpha:1.0];
			[staffColor setStroke];
			for (NSInteger line = 0; line < 5; line++) {
				CGFloat treble = laneY + (40 + line * 7) * self.zoom;
				CGFloat bass = laneY + (82 + line * 7) * self.zoom;
				[NSBezierPath strokeLineFromPoint:NSMakePoint(0, floor(treble) + 0.5)
					toPoint:NSMakePoint(patternWidth, floor(treble) + 0.5)];
				[NSBezierPath strokeLineFromPoint:NSMakePoint(0, floor(bass) + 0.5)
					toPoint:NSMakePoint(patternWidth, floor(bass) + 0.5)];
			}
		}

		for (NSInteger row = firstRow; row <= finalRow; row++) {
			if (row % 16 != 0) continue;
			CGFloat x = floor(row * cellWidth) + 0.5;
			[NSColor.blackColor setStroke];
			NSBezierPath *line = [NSBezierPath bezierPath];
			[line moveToPoint:NSMakePoint(x, laneY)];
			[line lineToPoint:NSMakePoint(x, laneY + laneHeight)];
			line.lineWidth = 1.5;
			[line stroke];
		}
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, laneY + 0.5)
			toPoint:NSMakePoint(patternWidth, laneY + 0.5)];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, laneY + laneHeight - 0.5)
			toPoint:NSMakePoint(patternWidth, laneY + laneHeight - 0.5)];

		// Reproduce the original rhythmic-rest scan: silence exists before the
		// first note and after an explicit note-off, but not inside a sustained
		// note.  Large gaps are split at measure boundaries into standard values.
		NSInteger scan = 0;
		while (scan < pattern->header.size) {
			NSInteger nextNote = scan;
			while (nextNote < pattern->header.size) {
				Cmd *candidate = [self.owner commandAtRow:nextNote channel:channel];
				if (candidate != NULL && candidate->note != 0xFF && candidate->note != 0xFE) break;
				nextNote++;
			}
			NSInteger restRow = scan;
			NSInteger restLength = nextNote - scan;
			while (restLength > 0) {
				NSInteger chunk = PPClassicalRhythmChunk(restLength, restRow);
				if (restRow + chunk >= firstRow && restRow < finalRow) {
					CGFloat restX = restRow * cellWidth + cellWidth * 0.5;
					[self drawClassicalRestAtX:restX laneY:laneY duration:chunk active:active];
				}
				restRow += chunk;
				restLength -= chunk;
			}
			if (nextNote >= pattern->header.size) break;
			NSInteger noteEnd = nextNote + 1;
			while (noteEnd < pattern->header.size) {
				Cmd *ending = [self.owner commandAtRow:noteEnd channel:channel];
				if (ending != NULL && ending->note != 0xFF) break;
				noteEnd++;
			}
			scan = noteEnd;
		}

		NSInteger previousNote = -1;
		for (NSInteger previousRow = 0; previousRow < firstRow; previousRow++) {
			Cmd *previous = [self.owner commandAtRow:previousRow channel:channel];
			if (previous != NULL && previous->note < NUMBER_NOTES) previousNote = previous->note;
		}
		for (NSInteger row = firstRow; row < finalRow; row++) {
			Cmd *command = [self.owner commandAtRow:row channel:channel];
			if (command == NULL || command->note == 0xFF) continue;
			CGFloat x = row * cellWidth + cellWidth * 0.5;
			if (command->note == 0xFE) {
				continue;
			}
			if (command->note >= NUMBER_NOTES) continue;
			CGFloat y = [self yForClassicalNote:command->note channel:channel];
			NSInteger duration = [self classicalDurationAtRow:row channel:channel];
			if (PPClassicalNoteIsAccidental(command->note)) {
				BOOL useSharp = previousNote < 0 || previousNote <= command->note;
				NSString *name = useSharp ? @"classic-staff-sharp" : @"classic-staff-flat";
				NSImage *accidental = [self.owner classicImageNamed:name];
				CGFloat accidentalY = useSharp ? y :
					[self yForClassicalNote:MIN(command->note + 1, NUMBER_NOTES - 1) channel:channel];
				[accidental drawInRect:NSMakeRect(x - 12 * self.zoom,
					accidentalY - 9 * self.zoom, 8 * self.zoom, 19 * self.zoom)
					fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
					fraction:active ? 1.0 : 0.45 respectFlipped:YES
					hints:@{NSImageHintInterpolation:@(NSImageInterpolationNone)}];
			}
			[self drawClassicalNoteAtX:x y:y duration:duration instrument:command->ins active:active];
			previousNote = command->note;

			CGFloat localY = y - laneY;
			[(active ? NSColor.blackColor :
				[NSColor colorWithCalibratedWhite:0.50 alpha:1.0]) setStroke];
			if (localY < 36 * self.zoom) {
				for (CGFloat ledger = 33 * self.zoom; ledger >= localY - 1; ledger -= 7 * self.zoom)
					[NSBezierPath strokeLineFromPoint:NSMakePoint(x - 6 * self.zoom, laneY + ledger)
						toPoint:NSMakePoint(x + 6 * self.zoom, laneY + ledger)];
			} else if (localY > 114 * self.zoom) {
				for (CGFloat ledger = 117 * self.zoom; ledger <= localY + 1; ledger += 7 * self.zoom)
					[NSBezierPath strokeLineFromPoint:NSMakePoint(x - 6 * self.zoom, laneY + ledger)
						toPoint:NSMakePoint(x + 6 * self.zoom, laneY + ledger)];
			}
		}
	}

	if (self.hasBoxSelection) {
		NSInteger startRow = MIN(self.selectionAnchorRow, self.selectionEndRow);
		NSInteger endRow = MAX(self.selectionAnchorRow, self.selectionEndRow);
		NSInteger startChannel = MIN(self.selectionAnchorChannel, self.selectionEndChannel);
		NSInteger endChannel = MAX(self.selectionAnchorChannel, self.selectionEndChannel);
		NSRect selection = NSMakeRect(startRow * cellWidth, startChannel * laneHeight,
			(endRow - startRow + 1) * cellWidth, (endChannel - startChannel + 1) * laneHeight);
		// The original used a simple translucent lavender cell/range with no
		// modern marquee outline.
		[[NSColor colorWithCalibratedRed:0.65 green:0.64 blue:0.96 alpha:0.42] setFill];
		NSRectFill(selection);
	}

	if (self.playbackRow >= 0 && self.playbackRow < pattern->header.size) {
		[[NSColor colorWithCalibratedRed:0.45 green:0.48 blue:0.98 alpha:0.30] setFill];
		NSRectFill(NSMakeRect(self.playbackRow * cellWidth, 0, cellWidth, channels * laneHeight));
	}
}

- (void)drawClassicOverview
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return;
	NSInteger channels = self.owner.music->header->numChn;
	[NSColor.blackColor setFill];
	NSRectFill(self.bounds);
	NSInteger firstChannel = self.owner.selectedChannel >= 0 ? self.owner.selectedChannel : 0;
	NSInteger lastChannel = self.owner.selectedChannel >= 0 ? self.owner.selectedChannel + 1 : channels;
	for (NSInteger channel = firstChannel; channel < lastChannel; channel++) {
		for (NSInteger row = 0; row < pattern->header.size; row++) {
			Cmd *command = [self.owner commandAtRow:row channel:channel];
			if (command == NULL || command->note == 0xFF || command->note >= NUMBER_NOTES) continue;
			if (self.owner.selectedInstrument >= 0 && command->ins != self.owner.selectedInstrument + 1) continue;
			CGFloat x = row * self.cellWidth + 1.0;
			CGFloat y = 6.0 + (NUMBER_NOTES - 1 - command->note) * MAX(NSHeight(self.bounds) - 12.0, 1.0) /
				(NUMBER_NOTES - 1);
			[[self colorForChannel:channel] setFill];
			NSRectFill(NSMakeRect(x, floor(y), MAX(self.cellWidth - 2.0, 2.0), 2.0));
		}
	}
	NSInteger cursor = self.playbackRow >= 0 ? self.playbackRow : self.selectedRow;
	if (cursor >= 0 && cursor < pattern->header.size) {
		[NSColor.whiteColor setFill];
		NSRectFill(NSMakeRect(cursor * self.cellWidth + 1.0, 0,
			MAX(self.cellWidth - 2.0, 2.0), NSHeight(self.bounds)));
	}
}

- (CGFloat)sampleValue:(sData *)sample atFraction:(CGFloat)fraction
{
	if (sample == NULL || sample->data == NULL || sample->size <= 0) return 0;
	NSInteger channels = sample->stereo ? 2 : 1;
	NSInteger frameBytes = (sample->amp / 8) * channels;
	NSInteger frames = frameBytes > 0 ? sample->size / frameBytes : 0;
	if (frames <= 0) return 0;
	NSInteger frame = MIN(MAX((NSInteger)floor(fraction * (frames - 1)), 0), frames - 1);
	if (sample->amp == 16) return ((int16_t *)sample->data)[frame * channels] / 32768.0;
	return ((int8_t *)sample->data)[frame * channels] / 128.0;
}

- (void)drawWaveMode
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return;
	NSInteger channels = self.owner.music->header->numChn;
	CGFloat band = self.waveBandHeight;
	CGFloat cellWidth = self.cellWidth;
	CGFloat patternWidth = pattern->header.size * cellWidth;
	CGFloat trackHeight = channels * band;
	[PPBoxClassicGray() setFill];
	NSRectFill(self.bounds);

	NSInteger firstRow = MAX((NSInteger)floor(NSMinX(self.visibleRect) / cellWidth), 0);
	NSInteger finalRow = MIN((NSInteger)ceil(NSMaxX(self.visibleRect) / cellWidth) + 1,
		pattern->header.size);
	NSInteger firstChannel = MAX((NSInteger)floor(NSMinY(self.visibleRect) / band), 0);
	NSInteger finalChannel = MIN((NSInteger)ceil(NSMaxY(self.visibleRect) / band) + 1, channels);
	for (NSInteger channel = firstChannel; channel < finalChannel; channel++) {
		CGFloat top = channel * band;
		CGFloat center = top + band / 2;
		[NSColor.whiteColor setFill];
		NSRectFill(NSMakeRect(0, top, patternWidth, band));
		[[NSColor colorWithCalibratedWhite:0.76 alpha:1.0] setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, floor(center) + 0.5)
			toPoint:NSMakePoint(patternWidth, floor(center) + 0.5)];

		for (NSInteger row = firstRow; row < finalRow; row++) {
			CGFloat startX = row * self.cellWidth;
			NSInteger pixels = MAX((NSInteger)floor(self.cellWidth), 1);
			NSBezierPath *wave = [NSBezierPath bezierPath];
			CGFloat previousMid = center;
			BOOL hasPrevious = NO;
			for (NSInteger pixel = 0; pixel < pixels; pixel++) {
				NSInteger sourceStart = pixel * PPWaveEnvelopeColumnsPerRow / pixels;
				NSInteger sourceEnd = MAX((pixel + 1) * PPWaveEnvelopeColumnsPerRow / pixels,
					sourceStart + 1);
				CGFloat minimum = 1.0;
				CGFloat maximum = -1.0;
				for (NSInteger source = sourceStart; source < sourceEnd; source++) {
					CGFloat pointMinimum = 0;
					CGFloat pointMaximum = 0;
					if (![self.owner waveEnvelopeForChannel:channel row:row column:source
						minimum:&pointMinimum maximum:&pointMaximum]) continue;
					minimum = MIN(minimum, pointMinimum);
					maximum = MAX(maximum, pointMaximum);
				}
				if (maximum < minimum) continue;
				CGFloat x = floor(startX + pixel) + 0.5;
				CGFloat topY = center - maximum * band * 0.44;
				CGFloat bottomY = center - minimum * band * 0.44;
				CGFloat middle = (topY + bottomY) / 2.0;
				if (hasPrevious) {
					[wave moveToPoint:NSMakePoint(x - 1.0, previousMid)];
					[wave lineToPoint:NSMakePoint(x, middle)];
				}
				[wave moveToPoint:NSMakePoint(x, topY)];
				[wave lineToPoint:NSMakePoint(x, bottomY)];
				previousMid = middle;
				hasPrevious = YES;
			}
			BOOL active = self.owner.driver == NULL || self.owner.driver->base.Active[channel];
			[(active ? NSColor.blackColor : [NSColor colorWithCalibratedWhite:0.70 alpha:1.0]) setStroke];
			wave.lineWidth = 1.0;
			[wave stroke];
		}
		[NSColor.blackColor setStroke];
		[NSBezierPath strokeLineFromPoint:NSMakePoint(0, floor(top + band) - 0.5)
			toPoint:NSMakePoint(patternWidth, floor(top + band) - 0.5)];
	}

	[[NSColor colorWithCalibratedWhite:0.84 alpha:1.0] setStroke];
	for (NSInteger row = firstRow; row <= finalRow; row++) {
		CGFloat x = floor(row * cellWidth) + 0.5;
		[NSBezierPath strokeLineFromPoint:NSMakePoint(x, 0)
			toPoint:NSMakePoint(x, trackHeight)];
	}
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(floor(patternWidth) - 0.5, 0)
		toPoint:NSMakePoint(floor(patternWidth) - 0.5, trackHeight)];

	NSInteger cursor = self.playbackRow >= 0 ? self.playbackRow : self.selectedRow;
	if (cursor >= 0 && cursor < pattern->header.size) {
		[[NSColor colorWithCalibratedRed:0.43 green:0.48 blue:1.0 alpha:0.27] setFill];
		NSRectFill(NSMakeRect(cursor * cellWidth + 1.0, 0,
			MAX(cellWidth - 2.0, 1.0), trackHeight));
	}
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	switch (self.owner.mode) {
		case PPPatternEditorModeBox: [self drawBoxMode]; break;
		case PPPatternEditorModeClassical: [self drawClassicalMode]; break;
		case PPPatternEditorModeClassicOverview: [self drawClassicOverview]; break;
		case PPPatternEditorModeWave: [self drawWaveMode]; break;
	}
}

- (NSInteger)rowAtPoint:(NSPoint)point
{
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return -1;
	return MIN(MAX((NSInteger)floor(point.x / self.cellWidth), 0), pattern->header.size - 1);
}

- (NSInteger)channelAtPoint:(NSPoint)point
{
	if (self.owner.mode == PPPatternEditorModeClassicOverview) return MAX(self.owner.selectedChannel, 0);
	if (self.owner.mode == PPPatternEditorModeWave) return (NSInteger)floor(point.y / self.waveBandHeight);
	if (self.owner.mode == PPPatternEditorModeBox) return (NSInteger)floor(point.y / [self.owner boxTrackHeight]);
	if (self.owner.mode == PPPatternEditorModeClassical)
		return (NSInteger)floor(point.y / [self.owner classicalTrackHeight]);
	return self.owner.selectedChannel;
}

- (NSInteger)noteAtPoint:(NSPoint)point
{
	if (self.owner.mode == PPPatternEditorModeBox) {
		NSInteger channel = [self channelAtPoint:point];
		CGFloat laneY = channel * [self.owner boxTrackHeight];
		NSInteger pitch = (NSInteger)floor((point.y - laneY + self.owner.boxPitchOffset) /
			self.boxPitchHeight);
		return MIN(MAX(NUMBER_NOTES - 1 - pitch, 0), NUMBER_NOTES - 1);
	}
	if (self.owner.mode == PPPatternEditorModeClassical) {
		NSInteger channel = [self channelAtPoint:point];
		CGFloat bestDistance = CGFLOAT_MAX;
		NSInteger bestNote = 0;
		for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
			if (PPClassicalNoteIsAccidental(note)) continue;
			CGFloat distance = fabs(point.y - [self yForClassicalNote:note channel:channel]);
			if (distance < bestDistance) {
				bestDistance = distance;
				bestNote = note;
			}
		}
		return bestNote;
	}
	return -1;
}

- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSInteger row = [self rowAtPoint:point];
	NSInteger channel = [self channelAtPoint:point];
	PatData *pattern = [self.owner pattern];
	if (row < 0 || channel < 0 || channel >= self.owner.music->header->numChn) return;
	self.selectedRow = row;
	self.selectedChannel = channel;
	self.owner.selectedChannel = channel;
	[self.owner canvasSelectionChanged];
	if (self.owner.mode == PPPatternEditorModeWave) {
		switch (self.owner.tool) {
			case PPPatternCanvasToolZoom:
				[self.owner zoomWaveAtRow:row
					outward:(event.modifierFlags & NSEventModifierFlagOption) != 0];
				break;
			case PPPatternCanvasToolNote:
				if (self.owner.driver != NULL) {
					self.owner.driver->base.Pat = (short)self.owner.patternIndex;
					self.owner.driver->base.PartitionReader = (short)row;
				}
				break;
			default:
				[self.owner beginWavePlayAtRow:row];
				break;
		}
		[self.owner.waveTimeline setNeedsDisplay:YES];
		[self setNeedsDisplay:YES];
		return;
	}
	if (self.owner.mode == PPPatternEditorModeClassicOverview) {
		if (self.owner.overviewAuditionButton.state == NSControlStateValueOn) [self.owner previewOverviewRow:row];
		[self setNeedsDisplay:YES];
		return;
	}
	BOOL editable = self.owner.mode == PPPatternEditorModeBox || self.owner.mode == PPPatternEditorModeClassical;
	BOOL erase = (event.modifierFlags & NSEventModifierFlagOption) != 0;
	NSInteger note = editable ? [self noteAtPoint:point] : -1;
	if (self.owner.mode == PPPatternEditorModeBox) {
		self.selectedNote = note;
		switch (self.owner.tool) {
			case PPPatternCanvasToolNote:
				self.hasBoxSelection = YES;
				self.selectionAnchorRow = self.selectionEndRow = row;
				self.selectionAnchorNote = self.selectionEndNote = note;
				[self.owner editRow:row note:note erase:erase];
				break;
			case PPPatternCanvasToolSelect:
				self.hasBoxSelection = YES;
				self.draggingBoxSelection = YES;
				self.selectionAnchorRow = self.selectionEndRow = row;
				self.selectionAnchorNote = self.selectionEndNote = note;
				break;
			case PPPatternCanvasToolErase:
				self.hasBoxSelection = YES;
				self.selectionAnchorRow = self.selectionEndRow = row;
				self.selectionAnchorNote = self.selectionEndNote = note;
				[self.owner editRow:row note:note erase:YES];
				break;
			case PPPatternCanvasToolPlay:
				[self.owner previewBoxNote:note channel:channel];
				break;
			case PPPatternCanvasToolZoom:
				[self.owner cycleBoxZoomBackward:erase focusRow:row note:note];
				break;
		}
		[self.owner.boxGutter setNeedsDisplay:YES];
		[self.owner.boxTimeline setNeedsDisplay:YES];
	} else if (self.owner.mode == PPPatternEditorModeClassical) {
		self.selectedNote = note;
		switch (self.owner.tool) {
			case PPPatternCanvasToolNote:
				self.hasBoxSelection = YES;
				self.selectionAnchorRow = self.selectionEndRow = row;
				self.selectionAnchorChannel = self.selectionEndChannel = channel;
				[self.owner editClassicalRow:row note:note erase:erase];
				break;
			case PPPatternCanvasToolSelect:
				if ((event.modifierFlags & NSEventModifierFlagShift) != 0 && self.hasBoxSelection) {
					self.selectionEndRow = row;
					self.selectionEndChannel = channel;
				} else {
					self.hasBoxSelection = YES;
					self.selectionAnchorRow = self.selectionEndRow = row;
					self.selectionAnchorChannel = self.selectionEndChannel = channel;
				}
				self.draggingClassicalSelection = YES;
				break;
			case PPPatternCanvasToolPlay: {
				NSInteger endRow = pattern->header.size - 1;
				if (self.hasBoxSelection && row >= MIN(self.selectionAnchorRow, self.selectionEndRow) &&
					row <= MAX(self.selectionAnchorRow, self.selectionEndRow))
					endRow = MAX(self.selectionAnchorRow, self.selectionEndRow);
				[self.owner beginClassicalPlayAtRow:row endingAtRow:endRow limitToSelection:YES];
				break;
			}
			case PPPatternCanvasToolErase:
				[self.owner editClassicalRow:row note:note erase:YES];
				break;
			default: break;
		}
		[self.owner.classicalTimeline setNeedsDisplay:YES];
		[self.owner.classicalGutter setNeedsDisplay:YES];
	} else if (editable && self.owner.tool == PPPatternCanvasToolNote) {
		[self.owner editRow:row note:note erase:erase];
	} else {
		[self.owner previewRow:row channel:channel];
	}
	[self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event
{
	if (self.owner.mode == PPPatternEditorModeBox &&
		self.owner.tool == PPPatternCanvasToolPlay) {
		NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
		NSInteger row = [self rowAtPoint:point];
		NSInteger channel = [self channelAtPoint:point];
		if (row < 0 || channel < 0 || channel >= self.owner.music->header->numChn) return;
		NSInteger note = [self noteAtPoint:point];
		if (note != self.selectedNote || channel != self.selectedChannel) {
			self.selectedRow = row;
			self.selectedNote = note;
			self.selectedChannel = channel;
			self.owner.selectedChannel = channel;
			[self.owner previewBoxNote:note channel:channel];
			[self.owner canvasSelectionChanged];
			[self.owner.boxGutter setNeedsDisplay:YES];
			[self.owner.boxTimeline setNeedsDisplay:YES];
			[self setNeedsDisplay:YES];
		}
		return;
	}
	if (self.owner.mode == PPPatternEditorModeClassical && self.draggingClassicalSelection) {
		NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
		NSInteger row = [self rowAtPoint:point];
		NSInteger channel = MIN(MAX([self channelAtPoint:point], 0),
			MAX((NSInteger)self.owner.music->header->numChn - 1, 0));
		self.selectionEndRow = row;
		self.selectionEndChannel = channel;
		self.selectedRow = row;
		self.selectedChannel = channel;
		self.owner.selectedChannel = channel;
		[self.owner canvasSelectionChanged];
		[self setNeedsDisplay:YES];
		return;
	}
	if (self.owner.mode != PPPatternEditorModeBox || !self.draggingBoxSelection) {
		[super mouseDragged:event];
		return;
	}
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	self.selectionEndRow = [self rowAtPoint:point];
	NSInteger note = [self noteAtPoint:NSMakePoint(point.x,
		self.selectedChannel * [self.owner boxTrackHeight] +
		fmod(MAX(point.y, 0), [self.owner boxTrackHeight]))];
	self.selectionEndNote = note;
	self.selectedRow = self.selectionEndRow;
	self.selectedNote = note;
	[self.owner canvasSelectionChanged];
	[self.owner.boxTimeline setNeedsDisplay:YES];
	[self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event
{
	(void)event;
	self.draggingBoxSelection = NO;
	self.draggingClassicalSelection = NO;
	if (self.owner.mode == PPPatternEditorModeWave) {
		[self.owner endWavePlayGesture];
		return;
	}
	if (self.owner.mode == PPPatternEditorModeBox &&
		(self.owner.tool == PPPatternCanvasToolNote ||
		 self.owner.tool == PPPatternCanvasToolPlay)) {
		if (self.owner.driver != NULL && self.owner.previewActive)
			MADKeyOFF(self.owner.driver, -1);
		[self.owner stopPreview];
	}
	if (self.owner.mode == PPPatternEditorModeClassical) {
		[self.owner endClassicalPlayGesture];
		if (self.owner.driver != NULL && self.owner.previewActive)
			MADKeyOFF(self.owner.driver, -1);
		[self.owner stopPreview];
	}
}

- (void)rightMouseDown:(NSEvent *)event
{
	if (self.owner.mode != PPPatternEditorModeBox && self.owner.mode != PPPatternEditorModeClassical) return;
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSInteger row = [self rowAtPoint:point];
	NSInteger channel = [self channelAtPoint:point];
	if (channel < 0 || channel >= self.owner.music->header->numChn) return;
	self.selectedRow = row;
	self.selectedChannel = channel;
	self.owner.selectedChannel = channel;
	NSInteger note = [self noteAtPoint:point];
	self.selectedNote = note;
	self.hasBoxSelection = YES;
	self.selectionAnchorRow = self.selectionEndRow = row;
	self.selectionAnchorNote = self.selectionEndNote = note;
	self.selectionAnchorChannel = self.selectionEndChannel = channel;
	if (self.owner.mode == PPPatternEditorModeClassical)
		[self.owner editClassicalRow:row note:note erase:YES];
	else
		[self.owner editRow:row note:note erase:YES];
	[self.owner canvasSelectionChanged];
	[self.owner.boxGutter setNeedsDisplay:YES];
	[self.owner.boxTimeline setNeedsDisplay:YES];
	[self.owner.classicalGutter setNeedsDisplay:YES];
	[self.owner.classicalTimeline setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event
{
	if ((event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0) {
		[super keyDown:event]; return;
	}
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL) return;
	if (self.owner.mode == PPPatternEditorModeWave && event.keyCode == 48) {
		PPPatternCanvasTool next = self.owner.tool == PPPatternCanvasToolPlay
			? PPPatternCanvasToolNote : self.owner.tool == PPPatternCanvasToolNote
			? PPPatternCanvasToolZoom : PPPatternCanvasToolPlay;
		[self.owner setWaveTool:next];
		return;
	}
	if (self.owner.mode == PPPatternEditorModeClassical && event.keyCode == 48) {
		PPPatternCanvasTool next = self.owner.tool == PPPatternCanvasToolNote
			? PPPatternCanvasToolSelect : PPPatternCanvasToolNote;
		[self.owner setBoxTool:next];
		return;
	}
	if (event.keyCode == 123 || event.keyCode == 124) {
		self.selectedRow += event.keyCode == 123 ? -1 : 1;
		if (self.selectedRow < 0) self.selectedRow = pattern->header.size - 1;
		if (self.selectedRow >= pattern->header.size) self.selectedRow = 0;
		if (self.owner.mode == PPPatternEditorModeBox) {
			self.hasBoxSelection = YES;
			self.selectionAnchorRow = self.selectionEndRow = self.selectedRow;
			self.selectionAnchorNote = self.selectionEndNote = self.selectedNote;
			[self.owner.boxTimeline setNeedsDisplay:YES];
			CGFloat x = self.selectedRow * [self.owner boxCellWidth];
			NSRect visible = self.owner.scrollView.documentVisibleRect;
			if (x < NSMinX(visible) || x + [self.owner boxCellWidth] > NSMaxX(visible)) {
				CGFloat target = MAX(x - NSWidth(visible) / 2.0, 0.0);
				[self.owner.scrollView.contentView scrollToPoint:NSMakePoint(target, visible.origin.y)];
				[self.owner.scrollView reflectScrolledClipView:self.owner.scrollView.contentView];
			}
		} else if (self.owner.mode == PPPatternEditorModeClassical) {
			self.hasBoxSelection = YES;
			self.selectionAnchorRow = self.selectionEndRow = self.selectedRow;
			self.selectionAnchorChannel = self.selectionEndChannel = self.selectedChannel;
			[self.owner.classicalTimeline setNeedsDisplay:YES];
			CGFloat x = self.selectedRow * [self.owner classicalCellWidth];
			NSRect visible = self.owner.scrollView.documentVisibleRect;
			if (x < NSMinX(visible) || x + [self.owner classicalCellWidth] > NSMaxX(visible)) {
				CGFloat target = MAX(x - NSWidth(visible) / 2.0, 0.0);
				[self.owner.scrollView.contentView scrollToPoint:NSMakePoint(target, visible.origin.y)];
				[self.owner.scrollView reflectScrolledClipView:self.owner.scrollView.contentView];
			}
		}
		[self.owner canvasSelectionChanged]; [self setNeedsDisplay:YES]; return;
	}
	if (self.owner.mode == PPPatternEditorModeClassical &&
		(event.keyCode == 125 || event.keyCode == 126)) {
		NSInteger channels = MAX((NSInteger)self.owner.music->header->numChn, 1);
		self.selectedChannel += event.keyCode == 126 ? -1 : 1;
		self.selectedChannel = MIN(MAX(self.selectedChannel, 0), channels - 1);
		self.owner.selectedChannel = self.selectedChannel;
		self.hasBoxSelection = YES;
		self.selectionAnchorRow = self.selectionEndRow = self.selectedRow;
		self.selectionAnchorChannel = self.selectionEndChannel = self.selectedChannel;
		CGFloat y = self.selectedChannel * [self.owner classicalTrackHeight];
		NSRect visible = self.owner.scrollView.documentVisibleRect;
		if (y < NSMinY(visible) || y + [self.owner classicalTrackHeight] > NSMaxY(visible)) {
			CGFloat target = MAX(y - (NSHeight(visible) - [self.owner classicalTrackHeight]) / 2.0, 0.0);
			[self.owner.scrollView.contentView scrollToPoint:NSMakePoint(visible.origin.x, target)];
			[self.owner.scrollView reflectScrolledClipView:self.owner.scrollView.contentView];
		}
		[self.owner canvasSelectionChanged];
		[self.owner.classicalGutter setNeedsDisplay:YES];
		[self setNeedsDisplay:YES];
		return;
	}
	if (self.owner.mode == PPPatternEditorModeBox && (event.keyCode == 125 || event.keyCode == 126)) {
		self.selectedNote += event.keyCode == 126 ? 1 : -1;
		self.selectedNote = MIN(MAX(self.selectedNote, 0), NUMBER_NOTES - 1);
		self.hasBoxSelection = YES;
		self.selectionAnchorRow = self.selectionEndRow = self.selectedRow;
		self.selectionAnchorNote = self.selectionEndNote = self.selectedNote;
		CGFloat noteTop = (NUMBER_NOTES - 1 - self.selectedNote) * [self.owner boxPitchHeight];
		if (noteTop < self.owner.boxPitchOffset) self.owner.boxPitchOffset = noteTop;
		else if (noteTop + [self.owner boxPitchHeight] >
			self.owner.boxPitchOffset + [self.owner boxTrackHeight]) {
			self.owner.boxPitchOffset = noteTop + [self.owner boxPitchHeight] -
				[self.owner boxTrackHeight];
		}
		[self.owner updateBoxPitchScroller];
		[self.owner canvasSelectionChanged];
		[self setNeedsDisplay:YES];
		return;
	}
	if (event.keyCode == 51 || event.keyCode == 117) { [self.owner clearCanvasSelection:nil]; return; }
	if ([event.characters isEqualToString:@" "]) {
		if (self.owner.mode == PPPatternEditorModeClassicOverview) [self.owner previewOverviewRow:self.selectedRow];
		else [self.owner previewRow:self.selectedRow channel:self.owner.selectedChannel];
		return;
	}
	[super keyDown:event];
}

- (void)copy:(id)sender { [self.owner copyCanvasSelection:sender]; }
- (void)cut:(id)sender { [self.owner cutCanvasSelection:sender]; }
- (void)paste:(id)sender { [self.owner pasteCanvasSelection:sender]; }
- (void)delete:(id)sender { [self.owner clearCanvasSelection:sender]; }
- (void)deleteBackward:(id)sender { [self.owner clearCanvasSelection:sender]; }
- (void)selectAll:(id)sender
{
	(void)sender;
	PatData *pattern = [self.owner pattern];
	if (pattern == NULL || (self.owner.mode != PPPatternEditorModeBox &&
		self.owner.mode != PPPatternEditorModeClassical)) { NSBeep(); return; }
	self.hasBoxSelection = YES;
	self.selectionAnchorRow = 0;
	self.selectionEndRow = pattern->header.size - 1;
	if (self.owner.mode == PPPatternEditorModeBox) {
		self.selectionAnchorNote = 0;
		self.selectionEndNote = NUMBER_NOTES - 1;
	} else {
		self.selectionAnchorChannel = 0;
		self.selectionEndChannel = MAX((NSInteger)self.owner.music->header->numChn - 1, 0);
	}
	[self setNeedsDisplay:YES];
	[self.owner canvasSelectionChanged];
}

@end

@implementation PPPatternModeController

- (instancetype)initWithMusic:(MADMusic *)music driver:(MADDriverRec *)driver pattern:(NSInteger)pattern
	instrument:(NSInteger)instrument mode:(PPPatternEditorMode)mode changeHandler:(PPPatternModeHandler)changeHandler
	closeHandler:(PPPatternModeHandler)closeHandler
{
	self = [super initWithWindow:nil];
	if (self == nil) return nil;
	_music = music;
	_driver = driver;
	_patternIndex = pattern;
	_selectedInstrument = mode == PPPatternEditorModeClassicOverview ? -1 : MIN(MAX(instrument, 0), MAXINSTRU - 1);
	_selectedChannel = mode == PPPatternEditorModeClassicOverview ? -1 : 0;
	_mode = mode;
	_waveBandSize = 32.0;
	_tool = (mode == PPPatternEditorModeBox || mode == PPPatternEditorModeClassical)
		? PPPatternCanvasToolNote : PPPatternCanvasToolPlay;
	_previewChannel = -1;
	_changeHandler = [changeHandler copy];
	_closeHandler = [closeHandler copy];
	[self buildWindow];
	[self reloadPreferences];
	return self;
}

- (NSFont *)classicFont
{
	return [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
}

- (NSImage *)classicImageNamed:(NSString *)name
{
	static NSMutableDictionary<NSString *, NSImage *> *images;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ images = [NSMutableDictionary dictionary]; });
	NSImage *cached = images[name];
	if (cached != nil) return cached;
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	NSImage *image = path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:path];
	if (image != nil) images[name] = image;
	return image;
}

- (CGFloat)boxCellWidth
{
	static const CGFloat widths[] = {14.0, 20.0, 30.0};
	NSInteger index = MIN(MAX((NSInteger)llround(self.canvas.zoom), 1), 3) - 1;
	return widths[index];
}

- (CGFloat)boxPitchHeight
{
	static const CGFloat heights[] = {10.0, 20.0, 30.0};
	NSInteger index = MIN(MAX((NSInteger)llround(self.canvas.zoom), 1), 3) - 1;
	return heights[index];
}

- (CGFloat)boxTrackHeight
{
	return 128.0;
}

- (NSString *)boxNoteName:(NSInteger)note
{
	static NSArray<NSString *> *names;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		names = @[@"C ", @"C#", @"D ", @"D#", @"E ", @"F ", @"F#", @"G ", @"G#", @"A ", @"A#", @"B "];
	});
	if (note < 0 || note >= NUMBER_NOTES) return @"";
	return [NSString stringWithFormat:@"%@%ld", names[note % 12], (long)note / 12];
}

- (void)boxScrollChanged:(NSNotification *)notification
{
	(void)notification;
	[self.boxTimeline setNeedsDisplay:YES];
	[self.boxGutter setNeedsDisplay:YES];
}

- (void)updateBoxPitchScroller
{
	if (self.mode != PPPatternEditorModeBox || self.boxPitchScroller == nil) return;
	CGFloat total = NUMBER_NOTES * [self boxPitchHeight];
	CGFloat visible = [self boxTrackHeight];
	CGFloat maximum = MAX(total - visible, 0.0);
	self.boxPitchOffset = MIN(MAX(self.boxPitchOffset, 0.0), maximum);
	self.boxPitchScroller.doubleValue = maximum > 0 ? self.boxPitchOffset / maximum : 0;
	self.boxPitchScroller.knobProportion = MIN(visible / MAX(total, 1.0), 1.0);
	[self.boxPitchScroller setNeedsDisplay:YES];
	[self.canvas setNeedsDisplay:YES];
	[self.boxGutter setNeedsDisplay:YES];
}

- (IBAction)changeBoxPitch:(PPBoxPitchScrollerView *)sender
{
	CGFloat maximum = MAX(NUMBER_NOTES * [self boxPitchHeight] - [self boxTrackHeight], 0.0);
	self.boxPitchOffset = sender.doubleValue * maximum;
	[self updateBoxPitchScroller];
}

- (void)cycleBoxZoomBackward:(BOOL)backward focusRow:(NSInteger)row note:(NSInteger)note
{
	if (self.mode != PPPatternEditorModeBox) return;
	NSInteger zoom = MIN(MAX((NSInteger)llround(self.canvas.zoom), 1), 3);
	zoom = backward ? (zoom == 1 ? 3 : zoom - 1) : (zoom == 3 ? 1 : zoom + 1);
	self.canvas.zoom = zoom;
	[NSUserDefaults.standardUserDefaults setInteger:zoom forKey:PPBoxZoomDefaultsKey];
	[self.canvas resizeForContent];
	self.boxPitchOffset = (NUMBER_NOTES - 1 - MIN(MAX(note, 0), NUMBER_NOTES - 1)) *
		[self boxPitchHeight] - [self boxTrackHeight] / 2.0;
	[self updateBoxPitchScroller];
	CGFloat rowX = row * [self boxCellWidth];
	NSRect visible = self.scrollView.documentVisibleRect;
	CGFloat targetX = MAX(rowX - NSWidth(visible) / 2.0, 0.0);
	[self.scrollView.contentView scrollToPoint:NSMakePoint(targetX, visible.origin.y)];
	[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
	[self boxScrollChanged:nil];
}

- (NSString *)modeTitle
{
	switch (self.mode) {
		case PPPatternEditorModeBox: return @"Box Editor";
		case PPPatternEditorModeClassical: return @"Classical Editor";
		case PPPatternEditorModeClassicOverview: return @"Pattern";
		case PPPatternEditorModeWave: return @"Wave";
	}
}

- (void)buildWindow
{
	if (self.mode == PPPatternEditorModeBox) {
		[self buildBoxWindow];
		return;
	}
	if (self.mode == PPPatternEditorModeClassical) {
		[self buildClassicalWindow];
		return;
	}
	if (self.mode == PPPatternEditorModeClassicOverview) {
		[self buildOverviewWindow];
		return;
	}
	if (self.mode == PPPatternEditorModeWave) {
		[self buildWaveWindow];
		return;
	}
	NSSize size = self.mode == PPPatternEditorModeClassical ? NSMakeSize(720, 310)
		: NSMakeSize(720, 430);
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(160, 150, size.width, size.height)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = [NSString stringWithFormat:@"%@ — Pattern %03ld", [self modeTitle], (long)self.patternIndex];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.minSize = NSMakeSize(440, 230);
	self.window = window;

	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, size.height - 38, size.width, 38)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	strip.wantsLayer = YES;
	strip.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.87 alpha:1.0].CGColor;
	[window.contentView addSubview:strip];
	CGFloat x = 5;
	if (self.mode == PPPatternEditorModeBox || self.mode == PPPatternEditorModeClassical) {
		NSButton *note = [NSButton buttonWithTitle:@"♪" target:self action:@selector(selectNoteTool:)];
		note.frame = NSMakeRect(x, 15, 27, 20); note.bezelStyle = NSBezelStyleSmallSquare;
		note.toolTip = @"Place notes; Option-click or right-click erases"; [strip addSubview:note]; x += 30;
	}
	NSButton *play = [NSButton buttonWithTitle:@"▶" target:self action:@selector(selectPlayTool:)];
	play.frame = NSMakeRect(x, 15, 27, 20); play.bezelStyle = NSBezelStyleSmallSquare;
	play.toolTip = @"Preview pattern notes"; [strip addSubview:play]; x += 38;

	NSTextField *channelLabel = [NSTextField labelWithString:@"Track:"];
	channelLabel.frame = NSMakeRect(x, 19, 42, 14); channelLabel.font = [self classicFont]; [strip addSubview:channelLabel]; x += 40;
	self.channelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, 13, 70, 22) pullsDown:NO];
	self.channelPopup.font = [self classicFont]; self.channelPopup.target = self; self.channelPopup.action = @selector(selectChannel:);
	NSInteger channels = self.music == NULL ? 0 : self.music->header->numChn;
	for (NSInteger channel = 0; channel < channels; channel++) [self.channelPopup addItemWithTitle:[NSString stringWithFormat:@"%03ld", (long)channel + 1]];
	[strip addSubview:self.channelPopup]; x += 78;

	NSTextField *instrumentLabel = [NSTextField labelWithString:@"Ins:"];
	instrumentLabel.frame = NSMakeRect(x, 19, 30, 14); instrumentLabel.font = [self classicFont]; [strip addSubview:instrumentLabel]; x += 27;
	self.instrumentPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, 13, 126, 22) pullsDown:NO];
	self.instrumentPopup.font = [self classicFont]; self.instrumentPopup.target = self;
	self.instrumentPopup.action = @selector(selectInstrument:);
	NSInteger instruments = self.music == NULL ? 0 : MAX((NSInteger)self.music->header->numInstru, 1);
	for (NSInteger instrument = 0; instrument < instruments; instrument++) {
		[self.instrumentPopup addItemWithTitle:[NSString stringWithFormat:@"%03ld", (long)instrument + 1]];
	}
	[self.instrumentPopup selectItemAtIndex:MIN(self.selectedInstrument, MAX(instruments - 1, 0))];
	[strip addSubview:self.instrumentPopup]; x += 135;

	NSTextField *zoomLabel = [NSTextField labelWithString:@"Zoom:"];
	zoomLabel.frame = NSMakeRect(x, 19, 40, 14); zoomLabel.font = [self classicFont]; [strip addSubview:zoomLabel]; x += 39;
	self.zoomSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(x, 14, 100, 18)];
	self.zoomSlider.minValue = 1; self.zoomSlider.maxValue = 3; self.zoomSlider.numberOfTickMarks = 3;
	self.zoomSlider.allowsTickMarkValuesOnly = YES; self.zoomSlider.doubleValue = 1;
	self.zoomSlider.target = self; self.zoomSlider.action = @selector(changeZoom:); [strip addSubview:self.zoomSlider];

	self.positionField = [NSTextField labelWithString:@"Position: 000"];
	self.positionField.frame = NSMakeRect(5, 1, size.width - 10, 13); self.positionField.font = [self classicFont];
	[strip addSubview:self.positionField];
	if (self.mode == PPPatternEditorModeWave) {
		self.channelPopup.enabled = NO;
		self.instrumentPopup.enabled = NO;
	}

	self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height - 38)];
	self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.scrollView.hasHorizontalScroller = YES; self.scrollView.hasVerticalScroller = YES;
	self.scrollView.borderType = NSBezelBorder;
	self.canvas = [[PPPatternCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 620, 300)];
	self.canvas.owner = self; self.canvas.selectedRow = 0; self.canvas.zoom = 1;
	[self.canvas resizeForContent];
	self.scrollView.documentView = self.canvas;
	[window.contentView addSubview:self.scrollView];
}

- (NSButton *)boxToolbarButtonWithFrame:(NSRect)frame image:(NSString *)imageName
	title:(NSString *)title action:(SEL)action toolTip:(NSString *)toolTip
{
	NSImage *image = imageName.length > 0 ? [self classicImageNamed:imageName] : nil;
	PPPatternClassicButton *button = [[PPPatternClassicButton alloc] initWithFrame:frame];
	button.target = self;
	button.action = action;
	button.title = image == nil ? title : @"";
	button.image = image;
	button.frame = frame;
	button.bordered = NO;
	button.imagePosition = image != nil ? NSImageOnly : NSNoImage;
	button.imageScaling = NSImageScaleProportionallyDown;
	button.focusRingType = NSFocusRingTypeNone;
	button.font = [self classicFont];
	button.toolTip = toolTip;
	return button;
}

- (void)buildClassicalWindow
{
	// At 1x the reference window exposes 48 twenty-point pattern columns and
	// four 126-point grand staves.  These dimensions reproduce that workspace
	// on a modern display while retaining ordinary AppKit resizing.
	NSSize size = NSMakeSize(1024, 590);
	const CGFloat toolbarHeight = 54.0;
	const CGFloat timelineHeight = 16.0;
	const CGFloat gutterWidth = 60.0;
	CGFloat bodyHeight = size.height - toolbarHeight - timelineHeight;
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(125, 135, size.width, size.height)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
			NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = [NSString stringWithFormat:@"Pattern: %03ld", (long)self.patternIndex];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.minSize = NSMakeSize(620, 330);
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	window.backgroundColor = PPBoxClassicGray();
	self.window = window;

	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, size.height - toolbarHeight,
		size.width, toolbarHeight)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	strip.wantsLayer = YES;
	strip.layer.backgroundColor = PPBoxClassicGray().CGColor;
	[window.contentView addSubview:strip];
	CGFloat x = 7.0;
	const CGFloat buttonY = 11.0;

	NSButton *note = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"" title:@"♪" action:@selector(selectClassicalTool:) toolTip:@"Place rhythmic notes"];
	note.tag = PPPatternCanvasToolNote;
	note.buttonType = NSButtonTypePushOnPushOff;
	note.font = [NSFont systemFontOfSize:19 weight:NSFontWeightRegular];
	[strip addSubview:note]; x += 37;
	NSButton *select = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"sample-select" title:@"+" action:@selector(selectClassicalTool:)
		toolTip:@"Select a rectangular range of rows and tracks"];
	select.tag = PPPatternCanvasToolSelect;
	select.buttonType = NSButtonTypePushOnPushOff;
	[strip addSubview:select]; x += 37;
	self.classicalToolButtons = @[note, select];

	NSButton *play = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"instrument-play" title:@"▶" action:@selector(playClassicalSelection:)
		toolTip:@"Play the selected rows; click the ruler to play while held"];
	[strip addSubview:play]; x += 37;
	NSButton *load = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"load" title:@"L" action:@selector(pasteCanvasSelection:)
		toolTip:@"Paste the saved command selection at the active cell"];
	[strip addSubview:load]; x += 37;
	NSButton *save = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"save" title:@"S" action:@selector(copyCanvasSelection:)
		toolTip:@"Save the selected commands to the pattern clipboard"];
	[strip addSubview:save]; x += 37;
	NSButton *info = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"info" title:@"?" action:@selector(showClassicalInfo:) toolTip:@"Classical Editor help"];
	[strip addSubview:info]; x += 37;
	NSButton *preferences = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"preferences" title:@"P" action:@selector(showClassicalPreferences:)
		toolTip:@"Classical Editor preferences"];
	[strip addSubview:preferences]; x += 37;
	NSButton *effects = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
		image:@"fx" title:@"FX" action:@selector(showClassicalSelectionEffects:)
		toolTip:@"Apply an operation to the selected pattern commands"];
	[strip addSubview:effects]; x += 40;

	NSMutableArray<NSButton *> *lengthButtons = [NSMutableArray array];
	NSArray<NSNumber *> *lengths = @[@16, @8, @4, @2, @1, @0];
	NSArray<NSString *> *lengthTitles = @[@"", @"", @"", @"", @"", @"Key\nOFF"];
	NSArray<NSString *> *lengthImages = @[@"classic-staff-note-16", @"classic-staff-note-8",
		@"classic-staff-note-4", @"classic-staff-note-2", @"classic-staff-note-1", @""];
	NSArray<NSString *> *lengthNames = @[@"16", @"8", @"4", @"2", @"1", @"OFF"];
	for (NSInteger index = 0; index < (NSInteger)lengths.count; index++) {
		CGFloat buttonWidth = index == 5 ? 40 : 31;
		NSButton *button = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, buttonWidth, 32)
			image:lengthImages[index] title:lengthTitles[index] action:@selector(selectClassicalLength:)
			toolTip:index == 5 ? @"Insert note off" :
				[NSString stringWithFormat:@"Set note duration to %@ pattern rows", lengthNames[index]]];
		button.tag = lengths[index].integerValue;
		button.buttonType = NSButtonTypePushOnPushOff;
		button.font = index == 5 ? [NSFont monospacedSystemFontOfSize:7 weight:NSFontWeightRegular]
			: [NSFont systemFontOfSize:17 weight:NSFontWeightRegular];
		[lengthButtons addObject:button];
		[strip addSubview:button];
		x += buttonWidth + 3;
	}
	self.classicalLengthButtons = lengthButtons.copy;

	NSMutableArray<NSButton *> *accidentalButtons = [NSMutableArray array];
	NSArray<NSNumber *> *accidentals = @[@0, @(-1), @1];
	NSArray<NSString *> *accidentalTitles = @[@"♮", @"♭", @"♯"];
	for (NSInteger index = 0; index < (NSInteger)accidentals.count; index++) {
		NSButton *button = [self boxToolbarButtonWithFrame:NSMakeRect(x, buttonY, 32, 32)
			image:@"" title:accidentalTitles[index] action:@selector(selectClassicalAccidental:)
			toolTip:@[@"Natural note", @"Flatten note one semitone", @"Sharpen note one semitone"][index]];
		button.tag = accidentals[index].integerValue;
		button.buttonType = NSButtonTypePushOnPushOff;
		button.font = [NSFont systemFontOfSize:18 weight:NSFontWeightRegular];
		[accidentalButtons addObject:button];
		[strip addSubview:button]; x += 35;
	}
	self.classicalAccidentalButtons = accidentalButtons.copy;

	NSTextField *instrumentLabel = [NSTextField labelWithString:@"Ins:"];
	instrumentLabel.frame = NSMakeRect(x + 2, 20, 30, 17);
	instrumentLabel.font = [self classicFont];
	[strip addSubview:instrumentLabel]; x += 29;
	self.instrumentPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, 15, 58, 24) pullsDown:NO];
	self.instrumentPopup.font = [self classicFont];
	self.instrumentPopup.target = self;
	self.instrumentPopup.action = @selector(selectInstrument:);
	NSInteger instrumentCount = MAX(MAX((NSInteger)self.music->header->numInstru,
		self.selectedInstrument + 1), 16);
	for (NSInteger instrument = 0; instrument < instrumentCount; instrument++)
		[self.instrumentPopup addItemWithTitle:[NSString stringWithFormat:@"%ld", (long)instrument + 1]];
	[self.instrumentPopup selectItemAtIndex:MIN(MAX(self.selectedInstrument, 0), instrumentCount - 1)];
	[strip addSubview:self.instrumentPopup]; x += 61;
	self.classicalInstrumentNameField = [NSTextField labelWithString:@""];
	self.classicalInstrumentNameField.frame = NSMakeRect(x, 20, MAX(size.width - x - 7, 70), 17);
	self.classicalInstrumentNameField.autoresizingMask = NSViewWidthSizable;
	self.classicalInstrumentNameField.font = [self classicFont];
	self.classicalInstrumentNameField.lineBreakMode = NSLineBreakByTruncatingTail;
	[strip addSubview:self.classicalInstrumentNameField];

	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, 1)];
	separator.boxType = NSBoxSeparator;
	separator.autoresizingMask = NSViewWidthSizable;
	[strip addSubview:separator];

	self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(gutterWidth, 0,
		size.width - gutterWidth, bodyHeight)];
	self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.scrollView.hasHorizontalScroller = YES;
	self.scrollView.hasVerticalScroller = YES;
	self.scrollView.autohidesScrollers = NO;
	self.scrollView.scrollerStyle = NSScrollerStyleLegacy;
	self.scrollView.borderType = NSBezelBorder;
	self.scrollView.backgroundColor = PPBoxClassicGray();
	self.canvas = [[PPPatternCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 900, bodyHeight)];
	self.canvas.owner = self;
	self.canvas.selectedRow = 0;
	self.canvas.selectedChannel = 0;
	self.canvas.selectedNote = 84;
	self.canvas.playbackRow = -1;
	self.canvas.zoom = 1.0;
	self.canvas.hasBoxSelection = YES;
	self.canvas.selectionAnchorRow = self.canvas.selectionEndRow = 0;
	self.canvas.selectionAnchorChannel = self.canvas.selectionEndChannel = 0;
	self.scrollView.documentView = self.canvas;
	[window.contentView addSubview:self.scrollView];

	self.classicalTimeline = [[PPClassicalTimelineView alloc] initWithFrame:NSMakeRect(gutterWidth,
		bodyHeight, size.width - gutterWidth, timelineHeight)];
	self.classicalTimeline.owner = self;
	self.classicalTimeline.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[window.contentView addSubview:self.classicalTimeline];
	self.classicalGutter = [[PPClassicalGutterView alloc] initWithFrame:NSMakeRect(0, 0,
		gutterWidth, bodyHeight)];
	self.classicalGutter.owner = self;
	self.classicalGutter.autoresizingMask = NSViewHeightSizable;
	[window.contentView addSubview:self.classicalGutter];
	NSView *corner = [[NSView alloc] initWithFrame:NSMakeRect(0, bodyHeight, gutterWidth, timelineHeight)];
	corner.autoresizingMask = NSViewMinYMargin;
	corner.wantsLayer = YES;
	corner.layer.backgroundColor = NSColor.whiteColor.CGColor;
	corner.layer.borderColor = NSColor.blackColor.CGColor;
	corner.layer.borderWidth = 1.0;
	self.positionField = [NSTextField labelWithString:@"C 7"];
	self.positionField.frame = corner.bounds;
	self.positionField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.positionField.font = [self classicFont];
	self.positionField.alignment = NSTextAlignmentCenter;
	[corner addSubview:self.positionField];
	[window.contentView addSubview:corner];

	self.classicalNoteLength = 16;
	self.classicalAccidental = 0;
	[self setBoxTool:PPPatternCanvasToolNote];
	for (NSButton *button in self.classicalLengthButtons)
		button.state = button.tag == self.classicalNoteLength ? NSControlStateValueOn : NSControlStateValueOff;
	for (NSButton *button in self.classicalAccidentalButtons)
		button.state = button.tag == self.classicalAccidental ? NSControlStateValueOn : NSControlStateValueOff;
	[self selectInstrument:self.instrumentPopup];
	self.scrollView.contentView.postsBoundsChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(classicalScrollChanged:)
		name:NSViewBoundsDidChangeNotification object:self.scrollView.contentView];
	[self.canvas resizeForContent];
	self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self
		selector:@selector(updateClassicalPlayback:) userInfo:nil repeats:YES];
}

- (void)buildBoxWindow
{
	NSSize size = NSMakeSize(980, 600);
	const CGFloat toolbarHeight = 56.0;
	const CGFloat timelineHeight = 20.0;
	const CGFloat gutterWidth = 75.0;
	CGFloat bodyHeight = size.height - toolbarHeight - timelineHeight;
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(145, 120, size.width, size.height)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
			NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = [NSString stringWithFormat:@"Pattern: %ld", (long)self.patternIndex];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.minSize = NSMakeSize(560, 310);
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	window.backgroundColor = PPBoxClassicGray();
	self.window = window;

	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, size.height - toolbarHeight,
		size.width, toolbarHeight)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	strip.wantsLayer = YES;
	strip.layer.backgroundColor = PPBoxClassicGray().CGColor;
	[window.contentView addSubview:strip];

	CGFloat x = 7.0;
	NSButton *noteButton = [self boxToolbarButtonWithFrame:NSMakeRect(x, 18, 34, 32)
		image:@"" title:@"♪" action:@selector(selectBoxTool:) toolTip:@"Place notes"];
	noteButton.tag = PPPatternCanvasToolNote;
	x += 41;

	self.instrumentPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, 26, 61, 24) pullsDown:NO];
	self.instrumentPopup.font = [self classicFont];
	self.instrumentPopup.target = self;
	self.instrumentPopup.action = @selector(selectInstrument:);
	NSInteger instrumentCount = MAX(MAX((NSInteger)self.music->header->numInstru,
		self.selectedInstrument + 1), 16);
	for (NSInteger instrument = 0; instrument < instrumentCount; instrument++) {
		[self.instrumentPopup addItemWithTitle:[NSString stringWithFormat:@"%03ld", (long)instrument + 1]];
	}
	[self.instrumentPopup selectItemAtIndex:MIN(self.selectedInstrument, instrumentCount - 1)];
	[strip addSubview:self.instrumentPopup];
	x += 61;

	self.boxEffectPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, 26, 45, 24) pullsDown:NO];
	self.boxEffectPopup.font = [self classicFont];
	self.boxEffectPopup.target = self;
	self.boxEffectPopup.action = @selector(boxEffectChanged:);
	for (NSInteger effect = 0; effect < (NSInteger)PPPatternEffectMenuTitles().count; effect++) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:PPPatternEffectCharacter((MADEffectID)effect)
			action:nil keyEquivalent:@""];
		item.toolTip = PPPatternEffectMenuTitles()[effect];
		[self.boxEffectPopup.menu addItem:item];
	}
	[strip addSubview:self.boxEffectPopup];
	x += 44;

	self.boxArgumentField = [[NSTextField alloc] initWithFrame:NSMakeRect(x, 27, 39, 22)];
	self.boxArgumentField.font = [self classicFont];
	self.boxArgumentField.alignment = NSTextAlignmentCenter;
	self.boxArgumentField.stringValue = @"00";
	self.boxArgumentField.placeholderString = @"Arg";
	self.boxArgumentField.target = self;
	self.boxArgumentField.action = @selector(boxCommandFieldChanged:);
	self.boxArgumentField.toolTip = @"Default effect argument (hexadecimal)";
	[strip addSubview:self.boxArgumentField];
	x += 39;

	self.boxVolumeField = [[NSTextField alloc] initWithFrame:NSMakeRect(x, 27, 39, 22)];
	self.boxVolumeField.font = [self classicFont];
	self.boxVolumeField.alignment = NSTextAlignmentCenter;
	self.boxVolumeField.stringValue = @"--";
	self.boxVolumeField.placeholderString = @"Vol";
	self.boxVolumeField.target = self;
	self.boxVolumeField.action = @selector(boxCommandFieldChanged:);
	self.boxVolumeField.toolTip = @"Default volume (00–40 hex, or --)";
	[strip addSubview:self.boxVolumeField];
	x += 48;

	NSMutableArray<NSButton *> *toolButtons = [NSMutableArray arrayWithObject:noteButton];
	NSArray<NSDictionary<NSString *, id> *> *tools = @[
		@{@"tag": @(PPPatternCanvasToolSelect), @"image": @"", @"title": @"＋",
			@"tip": @"Select a rectangular range"},
		@{@"tag": @(PPPatternCanvasToolErase), @"image": @"instrument-delete", @"title": @"⌫",
			@"tip": @"Erase notes"},
		@{@"tag": @(PPPatternCanvasToolPlay), @"image": @"instrument-play", @"title": @"▶",
			@"tip": @"Audition notes"},
		@{@"tag": @(PPPatternCanvasToolZoom), @"image": @"sample-zoom", @"title": @"⌕",
			@"tip": @"Cycle grid zoom; Option-click zooms out"}
	];
	for (NSDictionary<NSString *, id> *description in tools) {
		NSButton *button = [self boxToolbarButtonWithFrame:NSMakeRect(x, 18, 34, 32)
			image:description[@"image"] title:description[@"title"]
			action:@selector(selectBoxTool:) toolTip:description[@"tip"]];
		button.tag = [description[@"tag"] integerValue];
		[toolButtons addObject:button];
		[strip addSubview:button];
		x += 41;
	}
	for (NSButton *button in toolButtons) button.buttonType = NSButtonTypePushOnPushOff;
	self.boxToolButtons = toolButtons.copy;
	noteButton.state = NSControlStateValueOn;
	[strip addSubview:noteButton];

	NSButton *preferences = [self boxToolbarButtonWithFrame:NSMakeRect(x + 7, 18, 34, 32)
		image:@"preferences" title:@"P" action:@selector(showBoxPreferences:)
		toolTip:@"Box Editor display preferences"];
	[strip addSubview:preferences];
	NSButton *help = [self boxToolbarButtonWithFrame:NSMakeRect(x + 48, 18, 34, 32)
		image:@"" title:@"?" action:@selector(showBoxHelp:) toolTip:@"Box Editor help"];
	[strip addSubview:help];

	self.positionField = [NSTextField labelWithString:@"C 4 • Row 000 • Track 01"];
	self.positionField.frame = NSMakeRect(7, 2, size.width - 14, 15);
	self.positionField.autoresizingMask = NSViewWidthSizable;
	self.positionField.font = [self classicFont];
	self.positionField.textColor = NSColor.blackColor;
	self.positionField.hidden = YES;
	[strip addSubview:self.positionField];

	self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(gutterWidth, 0,
		size.width - gutterWidth, bodyHeight)];
	self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.scrollView.hasHorizontalScroller = YES;
	self.scrollView.hasVerticalScroller = YES;
	self.scrollView.autohidesScrollers = NO;
	self.scrollView.scrollerStyle = NSScrollerStyleLegacy;
	self.scrollView.borderType = NSBezelBorder;
	self.scrollView.backgroundColor = NSColor.whiteColor;
	self.canvas = [[PPPatternCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 900, 520)];
	self.canvas.owner = self;
	self.canvas.selectedRow = 0;
	self.canvas.selectedChannel = 0;
	self.canvas.selectedNote = NUMBER_NOTES - 1;
	self.canvas.playbackRow = -1;
	self.canvas.zoom = 1;
	self.canvas.hasBoxSelection = NO;
	self.canvas.selectionAnchorRow = self.canvas.selectionEndRow = 0;
	self.canvas.selectionAnchorNote = self.canvas.selectionEndNote = NUMBER_NOTES - 1;
	self.scrollView.documentView = self.canvas;
	[window.contentView addSubview:self.scrollView];

	self.boxTimeline = [[PPBoxTimelineView alloc] initWithFrame:NSMakeRect(gutterWidth,
		bodyHeight, size.width - gutterWidth, timelineHeight)];
	self.boxTimeline.owner = self;
	self.boxTimeline.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[window.contentView addSubview:self.boxTimeline];

	self.boxGutter = [[PPBoxGutterView alloc] initWithFrame:NSMakeRect(0, 0,
		gutterWidth, bodyHeight)];
	self.boxGutter.owner = self;
	self.boxGutter.autoresizingMask = NSViewHeightSizable;
	[window.contentView addSubview:self.boxGutter];

	self.boxPitchScroller = [[PPBoxPitchScrollerView alloc] initWithFrame:NSMakeRect(32,
		MAX(bodyHeight - 128, 0), 19, MIN(128, bodyHeight))];
	self.boxPitchScroller.autoresizingMask = NSViewMinYMargin;
	self.boxPitchScroller.target = self;
	self.boxPitchScroller.action = @selector(changeBoxPitch:);
	[window.contentView addSubview:self.boxPitchScroller];

	self.boxDefaultEffect = MADEffectArpeggio;
	self.boxDefaultArgument = 0;
	self.boxDefaultVolume = 0xFF;
	self.scrollView.contentView.postsBoundsChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(boxScrollChanged:)
		name:NSViewBoundsDidChangeNotification object:self.scrollView.contentView];
	[self.canvas resizeForContent];

	NSInteger highestNote = -1;
	PatData *pattern = [self pattern];
	if (pattern != NULL) {
		for (NSInteger channel = 0; channel < self.music->header->numChn; channel++) {
			for (NSInteger row = 0; row < pattern->header.size; row++) {
				Cmd *command = [self commandAtRow:row channel:channel];
				if (command != NULL && command->note < NUMBER_NOTES)
					highestNote = MAX(highestNote, command->note);
			}
		}
	}
	if (highestNote >= 0) {
		self.canvas.selectedNote = highestNote;
		self.canvas.selectionAnchorNote = self.canvas.selectionEndNote = highestNote;
		NSInteger topNote = MIN(highestNote + 3, NUMBER_NOTES - 1);
		self.boxPitchOffset = (NUMBER_NOTES - 1 - topNote) * [self boxPitchHeight];
	}
	[self updateBoxPitchScroller];
	self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
		selector:@selector(updateBoxPlayback:) userInfo:nil repeats:YES];
}

- (void)buildWaveWindow
{
	NSSize size = NSMakeSize(720, 430);
	const CGFloat toolbarHeight = 50.0;
	const CGFloat timelineHeight = 24.0;
	const CGFloat gutterWidth = 36.0;
	CGFloat bodyHeight = size.height - toolbarHeight - timelineHeight;
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(175, 145, size.width, size.height)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
			NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = [NSString stringWithFormat:@"Pattern: %03ld", (long)self.patternIndex];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.minSize = NSMakeSize(470, 250);
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	window.backgroundColor = PPBoxClassicGray();
	self.window = window;

	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, size.height - toolbarHeight,
		size.width, toolbarHeight)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	strip.wantsLayer = YES;
	strip.layer.backgroundColor = PPBoxClassicGray().CGColor;
	[window.contentView addSubview:strip];

	NSArray<NSDictionary<NSString *, id> *> *descriptions = @[
		@{@"tag":@(PPPatternCanvasToolPlay), @"image":@"play", @"title":@"▶",
			@"tip":@"Play the pattern from a clicked row"},
		@{@"tag":@(PPPatternCanvasToolNote), @"image":@"", @"title":@"♪",
			@"tip":@"Select a track command"},
		@{@"tag":@(PPPatternCanvasToolZoom), @"image":@"sample-zoom", @"title":@"⌕",
			@"tip":@"Zoom horizontally; Option-click zooms out"}
	];
	NSMutableArray<NSButton *> *toolButtons = [NSMutableArray array];
	for (NSInteger index = 0; index < (NSInteger)descriptions.count; index++) {
		NSDictionary<NSString *, id> *description = descriptions[index];
		NSString *imageName = description[@"image"];
		NSImage *image = imageName.length > 0 ? [self classicImageNamed:imageName] : nil;
		NSButton *button = image != nil
			? [NSButton buttonWithImage:image target:self action:@selector(selectWaveTool:)]
			: [NSButton buttonWithTitle:description[@"title"] target:self action:@selector(selectWaveTool:)];
		button.frame = NSMakeRect(8 + index * 40, 9, 34, 32);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.buttonType = NSButtonTypePushOnPushOff;
		button.tag = [description[@"tag"] integerValue];
		button.imagePosition = image != nil ? NSImageOnly : NSNoImage;
		button.imageScaling = NSImageScaleProportionallyDown;
		button.focusRingType = NSFocusRingTypeNone;
		button.font = [NSFont systemFontOfSize:18 weight:NSFontWeightRegular];
		button.toolTip = description[@"tip"];
		[strip addSubview:button];
		[toolButtons addObject:button];
	}
	self.waveToolButtons = toolButtons.copy;
	[self setWaveTool:PPPatternCanvasToolPlay];

	NSTextField *sizeLabel = [NSTextField labelWithString:@"Size:"];
	sizeLabel.frame = NSMakeRect(154, 18, 38, 16);
	sizeLabel.font = [self classicFont];
	[strip addSubview:sizeLabel];
	self.waveSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(190, 11, 82, 25) pullsDown:NO];
	self.waveSizePopup.font = [self classicFont];
	[self.waveSizePopup addItemsWithTitles:@[@"16", @"32", @"64", @"128", @"256"]];
	[self.waveSizePopup selectItemWithTitle:@"32"];
	self.waveSizePopup.target = self;
	self.waveSizePopup.action = @selector(changeWaveBandSize:);
	self.waveSizePopup.toolTip = @"Track waveform height";
	[strip addSubview:self.waveSizePopup];
	NSBox *toolbarSeparator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, 1)];
	toolbarSeparator.boxType = NSBoxSeparator;
	toolbarSeparator.autoresizingMask = NSViewWidthSizable;
	[strip addSubview:toolbarSeparator];

	self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(gutterWidth, 0,
		size.width - gutterWidth, bodyHeight)];
	self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.scrollView.hasHorizontalScroller = YES;
	self.scrollView.hasVerticalScroller = YES;
	self.scrollView.autohidesScrollers = NO;
	self.scrollView.scrollerStyle = NSScrollerStyleLegacy;
	self.scrollView.borderType = NSBezelBorder;
	self.scrollView.backgroundColor = PPBoxClassicGray();
	self.canvas = [[PPPatternCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 620, bodyHeight)];
	self.canvas.owner = self;
	self.canvas.selectedRow = self.driver != NULL && self.driver->base.Pat == self.patternIndex
		? self.driver->base.PartitionReader : 0;
	self.canvas.selectedChannel = 0;
	self.canvas.playbackRow = -1;
	self.canvas.zoom = 1.0;
	self.scrollView.documentView = self.canvas;
	[window.contentView addSubview:self.scrollView];

	self.waveTimeline = [[PPWaveTimelineView alloc] initWithFrame:NSMakeRect(gutterWidth,
		bodyHeight, size.width - gutterWidth, timelineHeight)];
	self.waveTimeline.owner = self;
	self.waveTimeline.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[window.contentView addSubview:self.waveTimeline];
	self.waveGutter = [[PPWaveGutterView alloc] initWithFrame:NSMakeRect(0, 0,
		gutterWidth, bodyHeight)];
	self.waveGutter.owner = self;
	self.waveGutter.autoresizingMask = NSViewHeightSizable;
	[window.contentView addSubview:self.waveGutter];
	NSView *corner = [[NSView alloc] initWithFrame:NSMakeRect(0, bodyHeight, gutterWidth, timelineHeight)];
	corner.autoresizingMask = NSViewMinYMargin;
	corner.wantsLayer = YES;
	corner.layer.backgroundColor = NSColor.whiteColor.CGColor;
	corner.layer.borderColor = NSColor.blackColor.CGColor;
	corner.layer.borderWidth = 1.0;
	[window.contentView addSubview:corner];

	self.scrollView.contentView.postsBoundsChangedNotifications = YES;
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(waveScrollChanged:)
		name:NSViewBoundsDidChangeNotification object:self.scrollView.contentView];
	[self.canvas resizeForContent];
	[self renderWaveformPreview];
	[self.canvas setNeedsDisplay:YES];
	self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self
		selector:@selector(updateWavePlayback:) userInfo:nil repeats:YES];
}

- (void)buildOverviewWindow
{
	NSSize size = NSMakeSize(680, 330);
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(210, 180, size.width, size.height)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	window.title = [NSString stringWithFormat:@"Pattern:%03ld", (long)self.patternIndex];
	window.releasedWhenClosed = NO;
	window.delegate = self;
	window.minSize = NSMakeSize(440, 230);
	window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	self.window = window;

	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, size.height - 55, size.width, 55)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	strip.wantsLayer = YES;
	strip.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.87 alpha:1.0].CGColor;
	[window.contentView addSubview:strip];
	NSArray<NSString *> *buttonImages = @[@"info", @"play", @"sample-zoom"];
	NSArray<NSString *> *buttonActions = @[@"showOverviewHelp:", @"toggleOverviewAudition:", @"cycleOverviewZoom:"];
	NSArray<NSString *> *buttonTips = @[@"Pattern View help", @"Toggle note audition", @"Cycle Pattern View zoom"];
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [NSButton buttonWithImage:[self classicImageNamed:buttonImages[index]] target:self
			action:NSSelectorFromString(buttonActions[index])];
		button.frame = NSMakeRect(7 + index * 38, 12, 32, 32);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.imagePosition = NSImageOnly;
		button.imageScaling = NSImageScaleProportionallyDown;
		button.focusRingType = NSFocusRingTypeNone;
		button.toolTip = buttonTips[index];
		[strip addSubview:button];
		if (index == 1) {
			button.buttonType = NSButtonTypePushOnPushOff;
			button.state = NSControlStateValueOn;
			self.overviewAuditionButton = button;
		}
	}

	self.overviewZoomField = [NSTextField labelWithString:@"Zoom:  1 x (0–64)"];
	self.overviewZoomField.frame = NSMakeRect(114, 31, 180, 16);
	self.overviewZoomField.font = [self classicFont];
	[strip addSubview:self.overviewZoomField];
	self.overviewSizeField = [NSTextField labelWithString:@"Size:  64 x 4"];
	self.overviewSizeField.frame = NSMakeRect(114, 9, 180, 16);
	self.overviewSizeField.font = [self classicFont];
	[strip addSubview:self.overviewSizeField];

	NSTextField *trackLabel = [NSTextField labelWithString:@"Track:"];
	trackLabel.frame = NSMakeRect(330, 31, 48, 16); trackLabel.font = [self classicFont]; [strip addSubview:trackLabel];
	self.channelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(375, 25, 290, 24) pullsDown:NO];
	self.channelPopup.bordered = NO; self.channelPopup.font = [self classicFont];
	self.channelPopup.target = self; self.channelPopup.action = @selector(selectChannel:);
	[self.channelPopup addItemWithTitle:@"All Channels"];
	NSInteger channels = self.music == NULL ? 0 : self.music->header->numChn;
	for (NSInteger channel = 0; channel < channels; channel++) {
		[self.channelPopup addItemWithTitle:[NSString stringWithFormat:@"Track %03ld", (long)channel + 1]];
	}
	[strip addSubview:self.channelPopup];

	NSTextField *instrumentLabel = [NSTextField labelWithString:@"Instrument:"];
	instrumentLabel.frame = NSMakeRect(330, 9, 76, 16); instrumentLabel.font = [self classicFont]; [strip addSubview:instrumentLabel];
	self.instrumentPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(403, 3, 262, 24) pullsDown:NO];
	self.instrumentPopup.bordered = NO; self.instrumentPopup.font = [self classicFont];
	self.instrumentPopup.target = self; self.instrumentPopup.action = @selector(selectInstrument:);
	[self.instrumentPopup addItemWithTitle:@"All instruments"];
	NSInteger instruments = self.music == NULL ? 0 : MAX((NSInteger)self.music->header->numInstru, 1);
	for (NSInteger instrument = 0; instrument < instruments; instrument++) {
		[self.instrumentPopup addItemWithTitle:[NSString stringWithFormat:@"Instrument %03ld", (long)instrument + 1]];
	}
	[strip addSubview:self.instrumentPopup];
	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, size.width, 1)];
	separator.boxType = NSBoxSeparator; separator.autoresizingMask = NSViewWidthSizable; [strip addSubview:separator];

	self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height - 55)];
	self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.scrollView.hasHorizontalScroller = YES;
	self.scrollView.hasVerticalScroller = YES;
	self.scrollView.autohidesScrollers = NO;
	self.scrollView.scrollerStyle = NSScrollerStyleLegacy;
	self.scrollView.borderType = NSBezelBorder;
	self.scrollView.backgroundColor = NSColor.blackColor;
	self.canvas = [[PPPatternCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 640, 220)];
	self.canvas.owner = self; self.canvas.selectedRow = 0; self.canvas.playbackRow = -1; self.canvas.zoom = 1;
	[self.canvas resizeForContent];
	self.scrollView.documentView = self.canvas;
	[window.contentView addSubview:self.scrollView];
	[self updateOverviewInformation];
	self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self
		selector:@selector(updateOverviewPlayback:) userInfo:nil repeats:YES];
}

- (PatData *)pattern
{
	if (self.music == NULL || self.patternIndex < 0 || self.patternIndex >= MAXPATTERN) return NULL;
	return self.music->partition[self.patternIndex];
}

- (Cmd *)commandAtRow:(NSInteger)row channel:(NSInteger)channel
{
	PatData *pattern = [self pattern];
	if (pattern == NULL || row < 0 || row >= pattern->header.size || channel < 0 || channel >= self.music->header->numChn) return NULL;
	return GetMADCommand((short)row, (short)channel, pattern);
}

- (sData *)sampleForCommand:(Cmd *)command
{
	if (command == NULL || command->note == 0xFF || command->note >= NUMBER_NOTES || command->ins == 0) return NULL;
	NSInteger instrumentIndex = command->ins - 1;
	if (instrumentIndex < 0 || instrumentIndex >= MAXINSTRU) return NULL;
	InstrData *instrument = &self.music->fid[instrumentIndex];
	if (instrument->numSamples <= 0) return NULL;
	NSInteger sampleIndex = instrument->what[command->note];
	if (sampleIndex < 0 || sampleIndex >= instrument->numSamples) sampleIndex = 0;
	return self.music->sample[instrument->firstSample + sampleIndex];
}

- (void)renderWaveformPreview
{
	PatData *pattern = [self pattern];
	NSInteger rows = pattern == NULL ? 0 : pattern->header.size;
	NSInteger channels = self.music == NULL ? 0 : self.music->header->numChn;
	self.waveformEnvelope = nil;
	self.waveformRows = rows;
	self.waveformChannels = channels;
	if (pattern == NULL || rows <= 0 || channels <= 0 || self.driver == NULL ||
		self.driver->base.lib == NULL || self.music->musicUnderModification) return;

	NSUInteger pointCount = (NSUInteger)rows * (NSUInteger)channels *
		(NSUInteger)PPWaveEnvelopeColumnsPerRow;
	if (pointCount == 0 || pointCount > NSUIntegerMax / sizeof(PPWaveEnvelopePoint)) return;
	NSMutableData *envelope = [NSMutableData dataWithLength:pointCount * sizeof(PPWaveEnvelopePoint)];
	PPWaveEnvelopePoint *points = envelope.mutableBytes;
	for (NSUInteger point = 0; point < pointCount; point++) {
		points[point].minimum = 1.0f;
		points[point].maximum = -1.0f;
	}

	MADDriverSettings settings;
	MADGetBestDriver(&settings);
	NSInteger renderChannels = MAX(channels, 2);
	if (renderChannels % 2 != 0) renderChannels++;
	settings.numChn = (short)MIN(renderChannels, MAXTRACK);
	settings.outPutBits = 8;
	settings.outPutRate = 11025;
	settings.outPutMode = PolyPhonic;
	settings.driverMode = NoHardwareDriver;
	settings.repeatMusic = false;
	settings.surround = false;
	settings.MicroDelaySize = 0;
	settings.Reverb = false;
	settings.ReverbSize = 100;
	settings.ReverbStrength = 0;
	settings.oversampling = 1;
	settings.TickRemover = false;

	MADDriverRec *renderDriver = NULL;
	MADErr error = MADCreateDriver(&settings, self.driver->base.lib, &renderDriver);
	if (error == MADNoErr) error = MADStartDriver(renderDriver);
	if (error == MADNoErr) error = MADAttachDriverToMusic(renderDriver, self.music, NULL);
	if (error != MADNoErr || renderDriver == NULL) {
		if (renderDriver != NULL) MADDisposeDriver(renderDriver);
		return;
	}

	NSInteger order = 0;
	for (NSInteger position = 0; position < self.music->header->numPointers; position++) {
		if (self.music->header->oPointers[position] == self.patternIndex) {
			order = position;
			break;
		}
	}
	renderDriver->base.PL = (short)order;
	renderDriver->base.Pat = (short)self.patternIndex;
	renderDriver->base.PartitionReader = 0;
	renderDriver->base.speed = MAX((short)self.music->header->speed, (short)1);
	renderDriver->base.finespeed = MAX((short)self.music->header->tempo, (short)1);
	renderDriver->JumpToNextPattern = false;
	renderDriver->endPattern = false;
	renderDriver->base.musicEnd = false;
	renderDriver->smallcounter = 128;
	renderDriver->BufCounter = 0;
	renderDriver->BytesToGenerate = 0;
	MADPurgeTrack(renderDriver);
	MADPlayMusic(renderDriver);

	const NSInteger maximumChunkFrames = 64;
	char *buffer = calloc((size_t)maximumChunkFrames * (size_t)settings.numChn, 1);
	BOOL renderedAny = NO;
	if (buffer != NULL) {
		for (NSInteger row = 0; row < rows && !renderDriver->endPattern; row++) {
			NSInteger rowFrames = 1;
			NSInteger frameOffset = 0;
			BOOL firstChunk = YES;
			while (frameOffset < rowFrames) {
				NSInteger chunkFrames = firstChunk ? 1 : MIN(maximumChunkFrames, rowFrames - frameOffset);
				renderDriver->ASCBUFFER = (int)chunkFrames;
				renderDriver->ASCBUFFERReal = (int)chunkFrames;
				memset(buffer, 0, (size_t)chunkFrames * (size_t)settings.numChn);
				BOOL continued = MADDirectSave(buffer, &settings, renderDriver);
				if (firstChunk) {
					int64_t tickFrames = renderDriver->VSYNC;
					tickFrames /= MAX(renderDriver->base.finespeed, 1);
					tickFrames *= 8000;
					tickFrames /= MAX(renderDriver->base.VExt, 1);
					rowFrames = (NSInteger)MAX(tickFrames * MAX(renderDriver->base.speed, 1), 1);
					rowFrames = MIN(rowFrames, (NSInteger)settings.outPutRate * 10);
					firstChunk = NO;
				}
				for (NSInteger frame = 0; frame < chunkFrames; frame++) {
					NSInteger column = MIN((frameOffset + frame) * PPWaveEnvelopeColumnsPerRow /
						MAX(rowFrames, 1), PPWaveEnvelopeColumnsPerRow - 1);
					for (NSInteger channel = 0; channel < channels; channel++) {
						int8_t encoded = ((int8_t *)buffer)[frame * settings.numChn + channel];
						float value = MAX(MIN((float)encoded / 128.0f, 1.0f), -1.0f);
						NSUInteger index = ((NSUInteger)channel * (NSUInteger)rows + (NSUInteger)row) *
							(NSUInteger)PPWaveEnvelopeColumnsPerRow + (NSUInteger)column;
						points[index].minimum = MIN(points[index].minimum, value);
						points[index].maximum = MAX(points[index].maximum, value);
					}
				}
				frameOffset += chunkFrames;
				renderedAny = YES;
				if (!continued) break;
			}
		}
		free(buffer);
	}
	MADStopDriver(renderDriver);
	MADDisposeDriver(renderDriver);
	if (renderedAny) self.waveformEnvelope = envelope.copy;
}

- (BOOL)waveEnvelopeForChannel:(NSInteger)channel row:(NSInteger)row column:(NSInteger)column
	minimum:(CGFloat *)minimum maximum:(CGFloat *)maximum
{
	if (self.waveformEnvelope == nil || channel < 0 || channel >= self.waveformChannels ||
		row < 0 || row >= self.waveformRows || column < 0 ||
		column >= PPWaveEnvelopeColumnsPerRow) return NO;
	NSUInteger index = ((NSUInteger)channel * (NSUInteger)self.waveformRows + (NSUInteger)row) *
		(NSUInteger)PPWaveEnvelopeColumnsPerRow + (NSUInteger)column;
	if ((index + 1) * sizeof(PPWaveEnvelopePoint) > self.waveformEnvelope.length) return NO;
	const PPWaveEnvelopePoint *points = self.waveformEnvelope.bytes;
	PPWaveEnvelopePoint point = points[index];
	if (point.maximum < point.minimum) {
		point.minimum = 0;
		point.maximum = 0;
	}
	if (minimum != NULL) *minimum = point.minimum;
	if (maximum != NULL) *maximum = point.maximum;
	return YES;
}

- (NSData *)captureCommands
{
	PatData *pattern = [self pattern];
	if (pattern == NULL) return NSData.data;
	return [NSData dataWithBytes:pattern->Cmds
		length:(NSUInteger)pattern->header.size * (NSUInteger)self.music->header->numChn * sizeof(Cmd)];
}

- (void)registerUndoData:(NSData *)data actionName:(NSString *)name
{
	[[self.window.undoManager prepareWithInvocationTarget:self] restoreCommands:data actionName:name];
	[self.window.undoManager setActionName:name];
}

- (void)restoreCommands:(NSData *)data actionName:(NSString *)name
{
	PatData *pattern = [self pattern];
	NSUInteger size = pattern == NULL ? 0 : (NSUInteger)pattern->header.size * self.music->header->numChn * sizeof(Cmd);
	if (pattern == NULL || data.length != size) return;
	NSData *redo = [self captureCommands];
	memcpy(pattern->Cmds, data.bytes, size);
	[self registerUndoData:redo actionName:name];
	self.music->hasChanged = true;
	[self.canvas setNeedsDisplay:YES];
	if (self.changeHandler != nil) self.changeHandler();
}

- (void)editRow:(NSInteger)row note:(NSInteger)note erase:(BOOL)erase
{
	Cmd *command = [self commandAtRow:row channel:self.selectedChannel];
	if (command == NULL) return;
	NSData *undo = [self captureCommands];
	if (erase) {
		*command = (Cmd){0, 0xFF, 0, 0, 0xFF, 0};
	} else {
		command->note = (MADByte)MIN(MAX(note, 0), NUMBER_NOTES - 1);
		command->ins = (MADByte)MIN(self.selectedInstrument + 1, 255);
		if (self.mode == PPPatternEditorModeBox) {
			command->cmd = self.boxDefaultEffect;
			command->arg = self.boxDefaultArgument;
			command->vol = self.boxDefaultVolume;
		}
	}
	[self registerUndoData:undo actionName:erase ? @"Erase Pattern Note" : @"Place Pattern Note"];
	self.music->hasChanged = true;
	if (self.changeHandler != nil) self.changeHandler();
	[self.canvas setNeedsDisplay:YES];
	if (!erase && self.auditionEdits) [self previewRow:row channel:self.selectedChannel];
}

- (void)previewRow:(NSInteger)row channel:(NSInteger)channel
{
	Cmd *command = [self commandAtRow:row channel:channel];
	sData *sample = [self sampleForCommand:command];
	if (sample == NULL || sample->data == NULL || sample->size <= 2 || self.driver == NULL) { NSBeep(); return; }
	if (self.mode == PPPatternEditorModeBox) [self clearBoxAuditionVoices];
	else [self stopPreview];
	NSInteger availableChannels = MAX((NSInteger)self.driver->DriverSettings.numChn, 1);
	NSInteger previewChannel = self.mode == PPPatternEditorModeBox
		? MIN(MAX(channel, 0), availableChannels - 1) : 0;
	NSInteger note = MIN(MAX((NSInteger)command->note + sample->realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(self.driver, sample->data, (size_t)sample->size, (int)previewChannel,
		(MADByte)note, sample->amp, sample->loopBeg, sample->loopSize, sample->c2spd, sample->stereo);
	if (error == MADNoErr) {
		self.previewActive = YES;
		self.previewChannel = previewChannel;
	} else {
		NSBeep();
	}
}

- (void)previewBoxNote:(NSInteger)note channel:(NSInteger)channel
{
	if (self.music == NULL || self.driver == NULL || self.selectedInstrument < 0 ||
		self.selectedInstrument >= MAXINSTRU || note < 0 || note >= NUMBER_NOTES) {
		NSBeep();
		return;
	}
	InstrData *instrument = &self.music->fid[self.selectedInstrument];
	if (instrument->numSamples <= 0) { NSBeep(); return; }
	NSInteger sampleIndex = instrument->what[note];
	if (sampleIndex < 0 || sampleIndex >= instrument->numSamples) sampleIndex = 0;
	sData *sample = self.music->sample[instrument->firstSample + sampleIndex];
	if (sample == NULL || sample->data == NULL || sample->size <= 2) { NSBeep(); return; }
	[self clearBoxAuditionVoices];
	NSInteger availableChannels = MAX((NSInteger)self.driver->DriverSettings.numChn, 1);
	NSInteger previewChannel = MIN(MAX(channel, 0), availableChannels - 1);
	NSInteger playbackNote = MIN(MAX(note + sample->realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(self.driver, sample->data, (size_t)sample->size,
		(int)previewChannel, (MADByte)playbackNote, sample->amp, sample->loopBeg,
		sample->loopSize, sample->c2spd, sample->stereo);
	if (error == MADNoErr) {
		self.previewActive = YES;
		self.previewChannel = previewChannel;
	} else {
		NSBeep();
	}
}

- (void)clearBoxAuditionVoices
{
	if (self.driver == NULL) return;
	[self stopPreview];
	if (MADWasReading(self.driver)) return;
	NSInteger channels = MIN(MAX((NSInteger)self.driver->DriverSettings.numChn, 0), MAXTRACK);
	for (NSInteger channel = 0; channel < channels; channel++) {
		MADDriverClearChannel(self.driver, (int)channel);
	}
}

- (void)previewOverviewRow:(NSInteger)row
{
	PatData *pattern = [self pattern];
	if (pattern == NULL) return;
	NSInteger firstChannel = self.selectedChannel >= 0 ? self.selectedChannel : 0;
	NSInteger lastChannel = self.selectedChannel >= 0 ? self.selectedChannel + 1 : self.music->header->numChn;
	for (NSInteger channel = firstChannel; channel < lastChannel; channel++) {
		Cmd *command = [self commandAtRow:row channel:channel];
		if (command == NULL || command->note == 0xFF || command->note >= NUMBER_NOTES) continue;
		if (self.selectedInstrument >= 0 && command->ins != self.selectedInstrument + 1) continue;
		[self previewRow:row channel:channel];
		return;
	}
	NSBeep();
}

- (void)canvasSelectionChanged
{
	if (self.mode == PPPatternEditorModeClassicOverview) {
		[self updateOverviewInformation];
		return;
	}
	if (self.mode == PPPatternEditorModeBox) {
		self.positionField.stringValue = [NSString stringWithFormat:@"%@ • Row %03ld • Track %02ld",
			[self boxNoteName:self.canvas.selectedNote], (long)self.canvas.selectedRow,
			(long)self.selectedChannel + 1];
		[self.boxTimeline setNeedsDisplay:YES];
		[self.boxGutter setNeedsDisplay:YES];
		return;
	}
	if (self.mode == PPPatternEditorModeClassical) {
		NSString *noteName = self.classicalNoteLength == 0 ? @"OFF" :
			[self boxNoteName:self.canvas.selectedNote];
		self.positionField.stringValue = @"C 7";
		self.positionField.toolTip = [NSString stringWithFormat:
			@"%@ • Row %03ld • Track %02ld • Length %@",
			noteName, (long)self.canvas.selectedRow, (long)self.selectedChannel + 1,
			self.classicalNoteLength == 0 ? @"OFF" :
				[NSString stringWithFormat:@"%ld", (long)self.classicalNoteLength]];
		if (self.channelPopup != nil && self.selectedChannel < self.channelPopup.numberOfItems)
			[self.channelPopup selectItemAtIndex:self.selectedChannel];
		[self.classicalTimeline setNeedsDisplay:YES];
		[self.classicalGutter setNeedsDisplay:YES];
		return;
	}
	self.positionField.stringValue = [NSString stringWithFormat:@"Position: %03ld • Track: %03ld",
		(long)self.canvas.selectedRow, (long)self.selectedChannel + 1];
}

- (void)setBoxTool:(PPPatternCanvasTool)tool
{
	self.tool = tool;
	NSArray<NSButton *> *buttons = self.mode == PPPatternEditorModeClassical
		? self.classicalToolButtons : self.boxToolButtons;
	for (NSButton *button in buttons) {
		button.state = button.tag == tool ? NSControlStateValueOn : NSControlStateValueOff;
	}
}

- (void)setWaveTool:(PPPatternCanvasTool)tool
{
	if (tool != PPPatternCanvasToolPlay && tool != PPPatternCanvasToolNote &&
		tool != PPPatternCanvasToolZoom) return;
	self.tool = tool;
	for (NSButton *button in self.waveToolButtons) {
		button.state = button.tag == tool ? NSControlStateValueOn : NSControlStateValueOff;
	}
}

- (IBAction)selectWaveTool:(NSButton *)sender
{
	PPPatternCanvasTool tool = (PPPatternCanvasTool)sender.tag;
	[self setWaveTool:tool];
	if (tool == PPPatternCanvasToolZoom && NSApp.currentEvent.clickCount > 1) {
		self.canvas.zoom = 1.0;
		[self.canvas resizeForContent];
		[self.scrollView.contentView scrollToPoint:NSZeroPoint];
		[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
		[self waveScrollChanged:nil];
	}
	[self.window makeFirstResponder:self.canvas];
}

- (IBAction)changeWaveBandSize:(NSPopUpButton *)sender
{
	CGFloat newSize = sender.selectedItem.title.integerValue;
	if (newSize != 16 && newSize != 32 && newSize != 64 && newSize != 128 && newSize != 256) return;
	NSRect visible = self.scrollView.documentVisibleRect;
	CGFloat centerTrack = (NSMidY(visible) / MAX(self.waveBandSize, 1.0));
	self.waveBandSize = newSize;
	[self.canvas resizeForContent];
	CGFloat targetY = MAX(centerTrack * newSize - NSHeight(visible) / 2.0, 0.0);
	[self.scrollView.contentView scrollToPoint:NSMakePoint(visible.origin.x, targetY)];
	[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
	[self waveScrollChanged:nil];
}

- (void)waveScrollChanged:(NSNotification *)notification
{
	(void)notification;
	[self.waveTimeline setNeedsDisplay:YES];
	[self.waveGutter setNeedsDisplay:YES];
}

- (void)zoomWaveAtRow:(NSInteger)row outward:(BOOL)outward
{
	if (self.mode != PPPatternEditorModeWave) return;
	CGFloat oldWidth = [self.canvas cellWidth];
	CGFloat newWidth = outward ? oldWidth / 2.0 : oldWidth * 2.0;
	newWidth = MIN(MAX(newWidth, 4.0), 128.0);
	if (fabs(newWidth - oldWidth) < 0.01) { NSBeep(); return; }
	NSRect visible = self.scrollView.documentVisibleRect;
	CGFloat relative = row * oldWidth - NSMinX(visible);
	self.canvas.zoom = newWidth / 8.0;
	[self.canvas resizeForContent];
	CGFloat target = MAX(row * newWidth - relative, 0.0);
	[self.scrollView.contentView scrollToPoint:NSMakePoint(target, visible.origin.y)];
	[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
	[self waveScrollChanged:nil];
}

- (void)beginWavePlayAtRow:(NSInteger)row
{
	PatData *pattern = [self pattern];
	if (self.driver == NULL || pattern == NULL || row < 0 || row >= pattern->header.size) return;
	if (!self.wavePlayGestureActive) {
		self.wavePlayWasReading = MADWasReading(self.driver);
		self.wavePreviousJumpSetting = self.driver->JumpToNextPattern;
		self.wavePlayGestureActive = YES;
	}
	NSInteger order = self.driver->base.PL;
	for (NSInteger position = 0; position < self.music->header->numPointers; position++) {
		if (self.music->header->oPointers[position] == self.patternIndex) {
			order = position;
			break;
		}
	}
	self.driver->JumpToNextPattern = false;
	self.driver->base.PL = (short)order;
	self.driver->base.Pat = (short)self.patternIndex;
	self.driver->base.PartitionReader = (short)row;
	if (!self.wavePlayWasReading) {
		MADPurgeTrack(self.driver);
		MADPlayMusic(self.driver);
	}
	self.canvas.playbackRow = row;
	[self.canvas setNeedsDisplay:YES];
}

- (void)endWavePlayGesture
{
	if (!self.wavePlayGestureActive) return;
	if (self.driver != NULL) {
		self.driver->JumpToNextPattern = self.wavePreviousJumpSetting;
		if (!self.wavePlayWasReading) MADStopMusic(self.driver);
	}
	self.wavePlayGestureActive = NO;
}

- (void)handleWaveGutterTrack:(NSInteger)track modifiers:(NSEventModifierFlags)modifiers
{
	NSInteger channels = self.music == NULL ? 0 : self.music->header->numChn;
	if (track < 0 || track >= channels) return;
	self.selectedChannel = track;
	self.canvas.selectedChannel = track;
	if (self.driver != NULL && (modifiers & NSEventModifierFlagCommand) != 0) {
		self.driver->base.Active[track] = !self.driver->base.Active[track];
	} else if (self.driver != NULL && (modifiers & NSEventModifierFlagOption) != 0) {
		NSInteger active = 0;
		for (NSInteger channel = 0; channel < channels; channel++) {
			if (self.driver->base.Active[channel]) active++;
		}
		if (active <= 1 && self.driver->base.Active[track]) {
			for (NSInteger channel = 0; channel < channels; channel++)
				self.driver->base.Active[channel] = true;
		} else {
			for (NSInteger channel = 0; channel < channels; channel++)
				self.driver->base.Active[channel] = false;
			self.driver->base.Active[track] = true;
		}
	}
	[self.waveGutter setNeedsDisplay:YES];
	[self.canvas setNeedsDisplay:YES];
}

- (CGFloat)classicalCellWidth
{
	return 20.0 * MAX(self.canvas.zoom, 1.0);
}

- (CGFloat)classicalTrackHeight
{
	return 126.0 * MAX(self.canvas.zoom, 1.0);
}

- (void)classicalScrollChanged:(NSNotification *)notification
{
	(void)notification;
	[self.classicalTimeline setNeedsDisplay:YES];
	[self.classicalGutter setNeedsDisplay:YES];
}

- (void)editClassicalRow:(NSInteger)row note:(NSInteger)note erase:(BOOL)erase
{
	Cmd *command = [self commandAtRow:row channel:self.selectedChannel];
	PatData *pattern = [self pattern];
	if (command == NULL || pattern == NULL) return;
	NSData *undo = [self captureCommands];
	if (erase) {
		*command = (Cmd){0, 0xFF, 0, 0, 0xFF, 0};
	} else if (self.classicalNoteLength == 0) {
		command->ins = 0;
		command->note = 0xFE;
	} else {
		NSInteger adjustedNote = MIN(MAX(note + self.classicalAccidental, 0), NUMBER_NOTES - 1);
		command->note = (MADByte)adjustedNote;
		command->ins = (MADByte)MIN(self.selectedInstrument + 1, 255);
		NSInteger end = MIN(row + self.classicalNoteLength, pattern->header.size);
		for (NSInteger clearRow = row + 1; clearRow < end; clearRow++) {
			Cmd *continuation = [self commandAtRow:clearRow channel:self.selectedChannel];
			if (continuation == NULL) continue;
			continuation->note = 0xFF;
			continuation->ins = 0;
		}
		if (end < pattern->header.size) {
			Cmd *noteOff = [self commandAtRow:end channel:self.selectedChannel];
			if (noteOff != NULL && noteOff->note == 0xFF) {
				noteOff->note = 0xFE;
				noteOff->ins = 0;
			}
		}
		self.canvas.selectedNote = adjustedNote;
	}
	[self registerUndoData:undo actionName:erase ? @"Erase Classical Note" :
		(self.classicalNoteLength == 0 ? @"Insert Note Off" : @"Place Classical Note")];
	self.music->hasChanged = true;
	[self.canvas setNeedsDisplay:YES];
	[self.classicalTimeline setNeedsDisplay:YES];
	if (self.changeHandler != nil) self.changeHandler();
	if (!erase && self.classicalNoteLength > 0 && self.auditionEdits)
		[self previewBoxNote:self.canvas.selectedNote channel:self.selectedChannel];
}

- (void)beginClassicalPlayAtRow:(NSInteger)row endingAtRow:(NSInteger)endRow
	limitToSelection:(BOOL)limitToSelection
{
	PatData *pattern = [self pattern];
	if (self.driver == NULL || pattern == NULL || row < 0 || row >= pattern->header.size) return;
	if (!self.classicalPlayGestureActive) {
		self.classicalPlayWasReading = MADWasReading(self.driver);
		self.classicalPreviousJumpSetting = self.driver->JumpToNextPattern;
		self.classicalTrackReadingState = [NSData dataWithBytes:self.driver->TrackReading
			length:sizeof(self.driver->TrackReading)];
		self.classicalPlayGestureActive = YES;
	}
	if (limitToSelection && self.canvas.hasBoxSelection) {
		NSInteger firstTrack = MIN(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
		NSInteger lastTrack = MAX(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
		const bool *saved = self.classicalTrackReadingState.bytes;
		for (NSInteger track = 0; track < MAXTRACK; track++) {
			BOOL wasEnabled = saved != NULL ? saved[track] : YES;
			self.driver->TrackReading[track] = wasEnabled && track >= firstTrack && track <= lastTrack;
		}
	}
	NSInteger order = self.driver->base.PL;
	for (NSInteger position = 0; position < self.music->header->numPointers; position++) {
		if (self.music->header->oPointers[position] == self.patternIndex) {
			order = position;
			break;
		}
	}
	self.classicalPlaybackEndRow = MIN(MAX(endRow, row), pattern->header.size - 1);
	self.driver->JumpToNextPattern = false;
	self.driver->base.PL = (short)order;
	self.driver->base.Pat = (short)self.patternIndex;
	self.driver->base.PartitionReader = (short)row;
	if (!self.classicalPlayWasReading) {
		MADPurgeTrack(self.driver);
		MADPlayMusic(self.driver);
	}
	self.canvas.playbackRow = row;
	[self.canvas setNeedsDisplay:YES];
	[self.classicalTimeline setNeedsDisplay:YES];
}

- (void)endClassicalPlayGesture
{
	if (!self.classicalPlayGestureActive) return;
	if (self.driver != NULL) {
		self.driver->JumpToNextPattern = self.classicalPreviousJumpSetting;
		if (self.classicalTrackReadingState.length == sizeof(self.driver->TrackReading))
			memcpy(self.driver->TrackReading, self.classicalTrackReadingState.bytes,
				sizeof(self.driver->TrackReading));
		if (!self.classicalPlayWasReading) MADStopMusic(self.driver);
	}
	self.classicalTrackReadingState = nil;
	self.classicalPlayGestureActive = NO;
	if (self.driver == NULL || !MADWasReading(self.driver)) self.canvas.playbackRow = -1;
	[self.canvas setNeedsDisplay:YES];
	[self.classicalTimeline setNeedsDisplay:YES];
}

- (void)updateClassicalPlayback:(NSTimer *)timer
{
	(void)timer;
	PatData *pattern = [self pattern];
	if (self.driver == NULL || pattern == NULL) return;
	BOOL reading = MADWasReading(self.driver);
	NSInteger rawRow = self.driver->base.PartitionReader;
	NSInteger row = reading && self.driver->base.Pat == self.patternIndex
		? MIN(MAX(rawRow, 0), pattern->header.size - 1) : -1;
	if (self.classicalPlayGestureActive &&
		(!reading || self.driver->base.Pat != self.patternIndex || rawRow > self.classicalPlaybackEndRow)) {
		[self endClassicalPlayGesture];
		row = -1;
	}
	if (self.canvas.playbackRow == row) return;
	self.canvas.playbackRow = row;
	[self.canvas setNeedsDisplay:YES];
	[self.classicalTimeline setNeedsDisplay:YES];
	if (row < 0) return;
	CGFloat x = row * [self classicalCellWidth];
	NSRect visible = self.scrollView.documentVisibleRect;
	if (x < NSMinX(visible) || x + [self classicalCellWidth] > NSMaxX(visible)) {
		CGFloat target = MAX(x - NSWidth(visible) / 2.0, 0.0);
		[self.scrollView.contentView scrollToPoint:NSMakePoint(target, visible.origin.y)];
		[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
		[self classicalScrollChanged:nil];
	}
}

- (void)handleClassicalGutterTrack:(NSInteger)track modifiers:(NSEventModifierFlags)modifiers
{
	NSInteger channels = self.music == NULL ? 0 : self.music->header->numChn;
	if (track < 0 || track >= channels) return;
	self.selectedChannel = track;
	self.canvas.selectedChannel = track;
	self.canvas.hasBoxSelection = YES;
	self.canvas.selectionAnchorRow = self.canvas.selectionEndRow = self.canvas.selectedRow;
	self.canvas.selectionAnchorChannel = self.canvas.selectionEndChannel = track;
	if (self.driver != NULL && (modifiers & NSEventModifierFlagCommand) != 0) {
		self.driver->base.Active[track] = !self.driver->base.Active[track];
	} else if (self.driver != NULL && (modifiers & NSEventModifierFlagOption) != 0) {
		NSInteger active = 0;
		for (NSInteger channel = 0; channel < channels; channel++)
			if (self.driver->base.Active[channel]) active++;
		if (active <= 1 && self.driver->base.Active[track]) {
			for (NSInteger channel = 0; channel < channels; channel++)
				self.driver->base.Active[channel] = true;
		} else {
			for (NSInteger channel = 0; channel < channels; channel++)
				self.driver->base.Active[channel] = false;
			self.driver->base.Active[track] = true;
		}
	}
	[self canvasSelectionChanged];
	[self.classicalGutter setNeedsDisplay:YES];
	[self.canvas setNeedsDisplay:YES];
}

- (IBAction)selectClassicalTool:(NSButton *)sender
{
	[self setBoxTool:(PPPatternCanvasTool)sender.tag];
	[self.window makeFirstResponder:self.canvas];
}

- (IBAction)selectClassicalLength:(NSButton *)sender
{
	self.classicalNoteLength = sender.tag;
	for (NSButton *button in self.classicalLengthButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
	[self canvasSelectionChanged];
	[self.window makeFirstResponder:self.canvas];
}

- (IBAction)selectClassicalAccidental:(NSButton *)sender
{
	self.classicalAccidental = sender.tag;
	for (NSButton *button in self.classicalAccidentalButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
	[self.window makeFirstResponder:self.canvas];
}

- (IBAction)playClassicalSelection:(id)sender
{
	(void)sender;
	if (self.classicalPlayGestureActive) {
		[self endClassicalPlayGesture];
		return;
	}
	PatData *pattern = [self pattern];
	if (pattern == NULL) return;
	NSInteger start = self.canvas.hasBoxSelection
		? MIN(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow) : self.canvas.selectedRow;
	NSInteger end = self.canvas.hasBoxSelection
		? MAX(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow) : pattern->header.size - 1;
	[self beginClassicalPlayAtRow:start endingAtRow:end limitToSelection:YES];
}

- (IBAction)showClassicalSelectionEffects:(NSButton *)sender
{
	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Selection Effects"];
	NSArray<NSArray *> *operations = @[
		@[@"Transpose Notes Up One Octave", @12],
		@[@"Transpose Notes Up One Semitone", @1],
		@[@"Transpose Notes Down One Semitone", @(-1)],
		@[@"Transpose Notes Down One Octave", @(-12)]
	];
	for (NSArray *operation in operations) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:operation[0]
			action:@selector(applyClassicalSelectionEffect:) keyEquivalent:@""];
		item.target = self;
		item.tag = [operation[1] integerValue];
		[menu addItem:item];
	}
	[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 2)
		inView:sender];
}

- (IBAction)applyClassicalSelectionEffect:(NSMenuItem *)sender
{
	PatData *pattern = [self pattern];
	if (pattern == NULL || !self.canvas.hasBoxSelection) { NSBeep(); return; }
	NSInteger firstRow = MIN(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
	NSInteger lastRow = MAX(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
	NSInteger firstTrack = MIN(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
	NSInteger lastTrack = MAX(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
	NSData *undo = [self captureCommands];
	BOOL changed = NO;
	for (NSInteger track = firstTrack; track <= lastTrack; track++) {
		for (NSInteger row = firstRow; row <= lastRow; row++) {
			Cmd *command = [self commandAtRow:row channel:track];
			if (command == NULL || command->note >= NUMBER_NOTES) continue;
			NSInteger note = MIN(MAX((NSInteger)command->note + sender.tag, 0), NUMBER_NOTES - 1);
			if (note == command->note) continue;
			command->note = (MADByte)note;
			changed = YES;
		}
	}
	if (!changed) { NSBeep(); return; }
	[self registerUndoData:undo actionName:@"Transpose Classical Selection"];
	self.music->hasChanged = true;
	[self.canvas setNeedsDisplay:YES];
	if (self.changeHandler != nil) self.changeHandler();
}

- (IBAction)showClassicalPreferences:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Classical Editor";
	alert.informativeText = @"Staff display and note-entry options";
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 285, 82)];
	NSButton *guides = [NSButton checkboxWithTitle:@"Draw grand-staff guides" target:nil action:nil];
	guides.frame = NSMakeRect(0, 56, 275, 20);
	guides.state = self.showsStaffGuides ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:guides];
	NSButton *audition = [NSButton checkboxWithTitle:@"Audition notes while placing them" target:nil action:nil];
	audition.frame = NSMakeRect(0, 31, 275, 20);
	audition.state = self.auditionEdits ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:audition];
	NSTextField *zoomLabel = [NSTextField labelWithString:@"Scale:"];
	zoomLabel.frame = NSMakeRect(0, 4, 46, 18); zoomLabel.font = [self classicFont];
	[accessory addSubview:zoomLabel];
	NSPopUpButton *zoom = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(45, 0, 95, 24) pullsDown:NO];
	[zoom addItemsWithTitles:@[@"1 x", @"2 x", @"3 x"]];
	[zoom selectItemAtIndex:MIN(MAX((NSInteger)llround(self.canvas.zoom), 1), 3) - 1];
	[accessory addSubview:zoom];
	alert.accessoryView = accessory;
	__weak typeof(self) weakSelf = self;
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn) return;
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) return;
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		[defaults setBool:guides.state == NSControlStateValueOn forKey:PPClassicalStaffGuidesDefaultsKey];
		[defaults setBool:audition.state == NSControlStateValueOn forKey:PPClassicalAuditionDefaultsKey];
		[defaults setInteger:zoom.indexOfSelectedItem + 1 forKey:PPClassicalZoomDefaultsKey];
		[strongSelf reloadPreferences];
	}];
}

- (IBAction)showClassicalInfo:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Classical Editor";
	alert.informativeText = @"Each grand staff represents one tracker track. Choose a rhythmic length and accidental, then click a staff to enter a note. Use the selection tool to drag across rows and tracks. Tab switches between note and selection modes. Command-click a track number to mute it; Option-click solos or restores tracks. Click and hold the ruler to play from that row.";
	[alert addButtonWithTitle:@"OK"];
	[alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (IBAction)selectBoxTool:(NSButton *)sender
{
	[self setBoxTool:(PPPatternCanvasTool)sender.tag];
}

- (IBAction)selectNoteTool:(id)sender
{
	(void)sender;
	[self setBoxTool:PPPatternCanvasToolNote];
}

- (IBAction)selectPlayTool:(id)sender
{
	(void)sender;
	[self setBoxTool:PPPatternCanvasToolPlay];
}

- (IBAction)boxEffectChanged:(NSPopUpButton *)sender
{
	self.boxDefaultEffect = (MADEffectID)MIN(MAX(sender.indexOfSelectedItem, 0), MADEffectNOffset);
}

- (IBAction)boxCommandFieldChanged:(id)sender
{
	(void)sender;
	NSString *argument = [self.boxArgumentField.stringValue
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
	unsigned int value = 0;
	NSScanner *scanner = [NSScanner scannerWithString:argument];
	if (argument.length != 2 || ![scanner scanHexInt:&value] || !scanner.isAtEnd || value > 0xFF) {
		NSBeep();
		self.boxArgumentField.stringValue = [NSString stringWithFormat:@"%02X", self.boxDefaultArgument];
	} else {
		self.boxDefaultArgument = (MADByte)value;
		self.boxArgumentField.stringValue = [NSString stringWithFormat:@"%02X", self.boxDefaultArgument];
	}

	NSString *volume = [self.boxVolumeField.stringValue
		stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
	if ([volume isEqualToString:@"--"] || volume.length == 0) {
		self.boxDefaultVolume = 0xFF;
		self.boxVolumeField.stringValue = @"--";
		return;
	}
	value = 0;
	scanner = [NSScanner scannerWithString:volume];
	if (volume.length != 2 || ![scanner scanHexInt:&value] || !scanner.isAtEnd || value > 0x40) {
		NSBeep();
		self.boxVolumeField.stringValue = self.boxDefaultVolume == 0xFF ? @"--" :
			[NSString stringWithFormat:@"%02X", self.boxDefaultVolume];
	} else {
		self.boxDefaultVolume = (MADByte)value;
		self.boxVolumeField.stringValue = [NSString stringWithFormat:@"%02X", self.boxDefaultVolume];
	}
}

- (IBAction)showBoxPreferences:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Box Editor";
	alert.informativeText = @"Display and note-entry options";
	[alert addButtonWithTitle:@"OK"];
	[alert addButtonWithTitle:@"Cancel"];
	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 275, 105)];
	NSButton *octaves = [NSButton checkboxWithTitle:@"Color alternating octave rows" target:nil action:nil];
	octaves.frame = NSMakeRect(0, 75, 260, 20);
	octaves.state = self.showsBoxOctaves ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:octaves];
	NSButton *bands = [NSButton checkboxWithTitle:@"Show alternating four-row time bands" target:nil action:nil];
	bands.frame = NSMakeRect(0, 49, 270, 20);
	bands.state = self.showsTimeBands ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:bands];
	NSButton *audition = [NSButton checkboxWithTitle:@"Audition notes while placing them" target:nil action:nil];
	audition.frame = NSMakeRect(0, 23, 270, 20);
	audition.state = self.auditionEdits ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:audition];
	NSTextField *zoomLabel = [NSTextField labelWithString:@"Grid size:"];
	zoomLabel.frame = NSMakeRect(0, 0, 62, 18);
	zoomLabel.font = [self classicFont];
	[accessory addSubview:zoomLabel];
	NSPopUpButton *zoom = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, -4, 100, 24) pullsDown:NO];
	[zoom addItemsWithTitles:@[@"Small", @"Medium", @"Large"]];
	[zoom selectItemAtIndex:MIN(MAX((NSInteger)llround(self.canvas.zoom), 1), 3) - 1];
	[accessory addSubview:zoom];
	alert.accessoryView = accessory;
	__weak typeof(self) weakSelf = self;
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn) return;
		typeof(self) strongSelf = weakSelf;
		if (strongSelf == nil) return;
		NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
		[defaults setBool:octaves.state == NSControlStateValueOn forKey:PPBoxOctaveMarkersDefaultsKey];
		[defaults setBool:bands.state == NSControlStateValueOn forKey:PPBoxTimeBandsDefaultsKey];
		[defaults setBool:audition.state == NSControlStateValueOn forKey:PPBoxAuditionDefaultsKey];
		[defaults setInteger:zoom.indexOfSelectedItem + 1 forKey:PPBoxZoomDefaultsKey];
		[strongSelf reloadPreferences];
	}];
}

- (IBAction)showBoxHelp:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Box Editor";
	alert.informativeText = @"Each colored lane is one track and each column is one pattern row. Use the note, selection, eraser, preview, and magnifier tools above the grid. Drag with the selection tool to copy, cut, or clear a note range. Command-click a track number to mute it; Option-click solos or restores tracks.";
	[alert addButtonWithTitle:@"OK"];
	[alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (IBAction)selectChannel:(NSPopUpButton *)sender
{
	if (self.mode == PPPatternEditorModeClassicOverview) {
		self.selectedChannel = sender.indexOfSelectedItem - 1;
		[self.canvas setNeedsDisplay:YES];
		return;
	}
	self.selectedChannel = MIN(MAX(sender.indexOfSelectedItem, 0), MAX((NSInteger)self.music->header->numChn - 1, 0));
	[self.canvas setNeedsDisplay:YES]; [self canvasSelectionChanged];
}

- (IBAction)selectInstrument:(NSPopUpButton *)sender
{
	if (self.mode == PPPatternEditorModeClassicOverview) {
		self.selectedInstrument = sender.indexOfSelectedItem - 1;
		[self.canvas setNeedsDisplay:YES];
		return;
	}
	self.selectedInstrument = MIN(MAX(sender.indexOfSelectedItem, 0), MAXINSTRU - 1);
	if (self.mode == PPPatternEditorModeClassical && self.classicalInstrumentNameField != nil &&
		self.music != NULL) {
		const char *bytes = self.music->fid[self.selectedInstrument].name;
		size_t length = strnlen(bytes, sizeof(self.music->fid[self.selectedInstrument].name));
		NSString *name = [[NSString alloc] initWithBytes:bytes length:length
			encoding:NSMacOSRomanStringEncoding] ?: @"";
		self.classicalInstrumentNameField.stringValue = name;
	}
}

- (IBAction)changeZoom:(NSSlider *)sender
{
	self.canvas.zoom = sender.doubleValue;
	[self.canvas resizeForContent];
}

- (void)reloadPreferences
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	self.showsBoxOctaves = [defaults boolForKey:PPBoxOctaveMarkersDefaultsKey];
	self.showsTimeBands = [defaults boolForKey:PPBoxTimeBandsDefaultsKey];
	self.showsStaffGuides = [defaults boolForKey:PPClassicalStaffGuidesDefaultsKey];
	self.auditionEdits = self.mode == PPPatternEditorModeClassical
		? [defaults boolForKey:PPClassicalAuditionDefaultsKey]
		: [defaults boolForKey:PPBoxAuditionDefaultsKey];
	if (self.mode == PPPatternEditorModeBox || self.mode == PPPatternEditorModeClassical) {
		NSString *zoomKey = self.mode == PPPatternEditorModeClassical
			? PPClassicalZoomDefaultsKey : PPBoxZoomDefaultsKey;
		CGFloat zoom = MIN(MAX([defaults integerForKey:zoomKey], 1), 3);
		CGFloat oldPitchHeight = self.mode == PPPatternEditorModeBox ? [self boxPitchHeight] : 1.0;
		CGFloat centerPitch = (self.boxPitchOffset + [self boxTrackHeight] / 2.0) /
			MAX(oldPitchHeight, 1.0);
		self.zoomSlider.doubleValue = zoom;
		self.canvas.zoom = zoom;
		[self.canvas resizeForContent];
		if (self.mode == PPPatternEditorModeBox) {
			self.boxPitchOffset = centerPitch * [self boxPitchHeight] - [self boxTrackHeight] / 2.0;
			[self updateBoxPitchScroller];
			[self.boxTimeline setNeedsDisplay:YES];
			[self.boxGutter setNeedsDisplay:YES];
		} else {
			[self.classicalTimeline setNeedsDisplay:YES];
			[self.classicalGutter setNeedsDisplay:YES];
			[self classicalScrollChanged:nil];
		}
	} else {
		[self.canvas setNeedsDisplay:YES];
	}
}

- (void)updateBoxPlayback:(NSTimer *)timer
{
	(void)timer;
	NSInteger playbackRow = -1;
	if (self.driver != NULL && MADWasReading(self.driver) && self.driver->base.Pat == self.patternIndex) {
		PatData *pattern = [self pattern];
		if (pattern != NULL) {
			playbackRow = MIN(MAX((NSInteger)self.driver->base.PartitionReader - 1, 0),
				pattern->header.size - 1);
		}
	}
	if (self.canvas.playbackRow == playbackRow) return;
	self.canvas.playbackRow = playbackRow;
	[self.boxTimeline setNeedsDisplay:YES];
	if (playbackRow < 0) return;
	CGFloat x = playbackRow * [self boxCellWidth];
	NSRect visible = self.scrollView.documentVisibleRect;
	if (x < NSMinX(visible) || x + [self boxCellWidth] > NSMaxX(visible)) {
		CGFloat target = MAX(x - NSWidth(visible) / 2.0, 0.0);
		[self.scrollView.contentView scrollToPoint:NSMakePoint(target, visible.origin.y)];
		[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
	}
}

- (void)updateOverviewInformation
{
	PatData *pattern = [self pattern];
	NSInteger rows = pattern == NULL ? 0 : pattern->header.size;
	NSInteger channels = self.music == NULL ? 0 : self.music->header->numChn;
	CGFloat cellWidth = MAX([self.canvas cellWidth], 1.0);
	NSInteger firstRow = MAX((NSInteger)floor(self.scrollView.contentView.bounds.origin.x / cellWidth), 0);
	NSInteger visibleRows = MAX((NSInteger)ceil(NSWidth(self.scrollView.contentView.bounds) / cellWidth), 1);
	NSInteger lastRow = MIN(firstRow + visibleRows, rows);
	self.overviewZoomField.stringValue = [NSString stringWithFormat:@"Zoom:  %.0f x (%ld–%ld)",
		self.canvas.zoom, (long)firstRow, (long)lastRow];
	self.overviewSizeField.stringValue = [NSString stringWithFormat:@"Size:  %ld x %ld", (long)rows, (long)channels];
}

- (IBAction)cycleOverviewZoom:(id)sender
{
	(void)sender;
	CGFloat zoom = self.canvas.zoom;
	self.canvas.zoom = zoom < 1.5 ? 2.0 : zoom < 3.0 ? 4.0 : zoom < 6.0 ? 8.0 : 1.0;
	[self.canvas resizeForContent];
	[self updateOverviewInformation];
}

- (IBAction)toggleOverviewAudition:(NSButton *)sender
{
	sender.state = sender.state == NSControlStateValueOn ? NSControlStateValueOn : NSControlStateValueOff;
}

- (IBAction)showOverviewHelp:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Pattern View";
	alert.informativeText = @"Colored marks show notes by track across the selected pattern. Choose a track or instrument to filter the display, click a row to inspect or audition it, and use the magnifier to cycle zoom.";
	[alert addButtonWithTitle:@"OK"];
	[alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)updateOverviewPlayback:(NSTimer *)timer
{
	(void)timer;
	NSInteger playbackRow = -1;
	if (self.driver != NULL && MADWasReading(self.driver) && self.driver->base.Pat == self.patternIndex) {
		PatData *pattern = [self pattern];
		if (pattern != NULL) playbackRow = MIN(MAX((NSInteger)self.driver->base.PartitionReader - 1, 0), pattern->header.size - 1);
	}
	if (self.canvas.playbackRow == playbackRow) return;
	self.canvas.playbackRow = playbackRow;
	[self.canvas setNeedsDisplay:YES];
	if (playbackRow >= 0) {
		CGFloat x = playbackRow * [self.canvas cellWidth];
		NSRect visible = self.scrollView.documentVisibleRect;
		if (x < NSMinX(visible) || x + [self.canvas cellWidth] > NSMaxX(visible)) {
			CGFloat target = MAX(x - NSWidth(visible) / 2.0, 0.0);
			[self.scrollView.contentView scrollToPoint:NSMakePoint(target, self.scrollView.contentView.bounds.origin.y)];
			[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
			[self updateOverviewInformation];
		}
	}
}

- (void)updateWavePlayback:(NSTimer *)timer
{
	(void)timer;
	if (self.driver == NULL || self.music == NULL) return;
	NSInteger driverPattern = self.driver->base.Pat;
	if (MADWasReading(self.driver) && driverPattern >= 0 && driverPattern < MAXPATTERN &&
		self.music->partition[driverPattern] != NULL && driverPattern != self.patternIndex) {
		self.patternIndex = driverPattern;
		self.window.title = [NSString stringWithFormat:@"Pattern: %03ld", (long)self.patternIndex];
		self.canvas.selectedRow = 0;
		self.canvas.playbackRow = -1;
		[self renderWaveformPreview];
		[self.canvas resizeForContent];
		[self waveScrollChanged:nil];
	}

	PatData *pattern = [self pattern];
	NSInteger row = -1;
	if (pattern != NULL && self.driver->base.Pat == self.patternIndex) {
		row = MIN(MAX((NSInteger)self.driver->base.PartitionReader, 0), pattern->header.size - 1);
	}
	if (self.canvas.playbackRow != row) {
		self.canvas.playbackRow = row;
		[self.canvas setNeedsDisplay:YES];
	}
	if (row < 0 || !MADWasReading(self.driver)) return;
	CGFloat x = row * [self.canvas cellWidth];
	NSRect visible = self.scrollView.documentVisibleRect;
	if (x < NSMinX(visible) || x + [self.canvas cellWidth] > NSMaxX(visible)) {
		CGFloat target = MAX(x - NSWidth(visible) / 2.0, 0.0);
		[self.scrollView.contentView scrollToPoint:NSMakePoint(target, visible.origin.y)];
		[self.scrollView reflectScrolledClipView:self.scrollView.contentView];
		[self waveScrollChanged:nil];
	}
}

- (void)copyCanvasSelection:(id)sender
{
	(void)sender;
	NSInteger startRow = self.canvas.selectedRow;
	NSInteger endRow = self.canvas.selectedRow;
	NSInteger startChannel = self.selectedChannel;
	NSInteger endChannel = self.selectedChannel;
	NSInteger lowNote = 0;
	NSInteger highNote = NUMBER_NOTES - 1;
	if (self.mode == PPPatternEditorModeBox && self.canvas.hasBoxSelection) {
		startRow = MIN(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		endRow = MAX(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		lowNote = MIN(self.canvas.selectionAnchorNote, self.canvas.selectionEndNote);
		highNote = MAX(self.canvas.selectionAnchorNote, self.canvas.selectionEndNote);
	} else if (self.mode == PPPatternEditorModeClassical && self.canvas.hasBoxSelection) {
		startRow = MIN(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		endRow = MAX(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		startChannel = MIN(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
		endChannel = MAX(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
	}
	Cmd *first = [self commandAtRow:startRow channel:startChannel];
	if (first == NULL) { NSBeep(); return; }
	PPPatternClipboardHeader header = {0x50434D44, 1,
		(uint16_t)(endRow - startRow + 1), (uint16_t)(endChannel - startChannel + 1), 0};
	NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
	for (NSInteger row = startRow; row <= endRow; row++) {
		for (NSInteger channel = startChannel; channel <= endChannel; channel++) {
			Cmd *command = [self commandAtRow:row channel:channel];
			Cmd copy = command == NULL ? (Cmd){0, 0xFF, 0, 0, 0xFF, 0} : *command;
			if (self.mode == PPPatternEditorModeBox &&
				(copy.note >= NUMBER_NOTES || copy.note < lowNote || copy.note > highNote))
				copy = (Cmd){0, 0xFF, 0, 0, 0xFF, 0};
			[data appendBytes:&copy length:sizeof(copy)];
		}
	}
	NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
	[pasteboard clearContents]; [pasteboard declareTypes:@[PPPatternPasteboardType] owner:nil];
	[pasteboard setData:data forType:PPPatternPasteboardType];
}

- (void)cutCanvasSelection:(id)sender
{
	[self copyCanvasSelection:sender];
	[self clearCanvasSelection:sender];
	[self.window.undoManager setActionName:@"Cut Pattern Note"];
}

- (void)pasteCanvasSelection:(id)sender
{
	(void)sender;
	if (self.mode == PPPatternEditorModeClassicOverview || self.mode == PPPatternEditorModeWave) { NSBeep(); return; }
	NSData *data = [NSPasteboard.generalPasteboard dataForType:PPPatternPasteboardType];
	if (data.length < sizeof(PPPatternClipboardHeader) + sizeof(Cmd)) { NSBeep(); return; }
	PPPatternClipboardHeader header; [data getBytes:&header length:sizeof(header)];
	if (header.magic != 0x50434D44 || header.version != 1) { NSBeep(); return; }
	NSUInteger commandCount = (NSUInteger)header.rows * MAX((NSUInteger)header.channels, 1);
	if (header.rows == 0 || data.length < sizeof(header) + commandCount * sizeof(Cmd)) {
		NSBeep();
		return;
	}
	NSData *undo = [self captureCommands];
	const Cmd *source = (const Cmd *)((const uint8_t *)data.bytes + sizeof(header));
	PatData *pattern = [self pattern];
	NSInteger pastedRows = MIN((NSInteger)header.rows, pattern->header.size - self.canvas.selectedRow);
	NSInteger pastedChannels = MIN((NSInteger)MAX(header.channels, 1),
		(NSInteger)self.music->header->numChn - self.selectedChannel);
	for (NSInteger row = 0; row < pastedRows; row++) {
		for (NSInteger channel = 0; channel < pastedChannels; channel++) {
			Cmd *destination = [self commandAtRow:self.canvas.selectedRow + row
				channel:self.selectedChannel + channel];
			if (destination != NULL)
				*destination = source[row * MAX(header.channels, 1) + channel];
		}
	}
	if (pastedRows <= 0 || pastedChannels <= 0) return;
	[self registerUndoData:undo actionName:pastedRows == 1 ? @"Paste Pattern Note" : @"Paste Pattern Notes"];
	if (self.mode == PPPatternEditorModeBox) {
		self.canvas.hasBoxSelection = YES;
		self.canvas.selectionAnchorRow = self.canvas.selectedRow;
		self.canvas.selectionEndRow = self.canvas.selectedRow + pastedRows - 1;
		NSInteger note = source[0].note < NUMBER_NOTES ? source[0].note : self.canvas.selectedNote;
		self.canvas.selectionAnchorNote = self.canvas.selectionEndNote = note;
	} else if (self.mode == PPPatternEditorModeClassical) {
		self.canvas.hasBoxSelection = YES;
		self.canvas.selectionAnchorRow = self.canvas.selectedRow;
		self.canvas.selectionEndRow = self.canvas.selectedRow + pastedRows - 1;
		self.canvas.selectionAnchorChannel = self.selectedChannel;
		self.canvas.selectionEndChannel = self.selectedChannel + pastedChannels - 1;
	}
	self.music->hasChanged = true; [self.canvas setNeedsDisplay:YES];
	if (self.changeHandler != nil) self.changeHandler();
}

- (void)clearCanvasSelection:(id)sender
{
	(void)sender;
	if (self.mode == PPPatternEditorModeClassicOverview || self.mode == PPPatternEditorModeWave) { NSBeep(); return; }
	if (self.mode == PPPatternEditorModeBox && self.canvas.hasBoxSelection) {
		NSInteger startRow = MIN(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		NSInteger endRow = MAX(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		NSInteger lowNote = MIN(self.canvas.selectionAnchorNote, self.canvas.selectionEndNote);
		NSInteger highNote = MAX(self.canvas.selectionAnchorNote, self.canvas.selectionEndNote);
		NSData *undo = [self captureCommands];
		BOOL changed = NO;
		for (NSInteger row = startRow; row <= endRow; row++) {
			Cmd *command = [self commandAtRow:row channel:self.selectedChannel];
			if (command == NULL || command->note >= NUMBER_NOTES ||
				command->note < lowNote || command->note > highNote) continue;
			*command = (Cmd){0, 0xFF, 0, 0, 0xFF, 0};
			changed = YES;
		}
		if (!changed) { NSBeep(); return; }
		[self registerUndoData:undo actionName:@"Clear Box Selection"];
		self.music->hasChanged = true;
		[self.canvas setNeedsDisplay:YES];
		if (self.changeHandler != nil) self.changeHandler();
		return;
	}
	if (self.mode == PPPatternEditorModeClassical && self.canvas.hasBoxSelection) {
		NSInteger startRow = MIN(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		NSInteger endRow = MAX(self.canvas.selectionAnchorRow, self.canvas.selectionEndRow);
		NSInteger startChannel = MIN(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
		NSInteger endChannel = MAX(self.canvas.selectionAnchorChannel, self.canvas.selectionEndChannel);
		NSData *undo = [self captureCommands];
		BOOL changed = NO;
		for (NSInteger row = startRow; row <= endRow; row++) {
			for (NSInteger channel = startChannel; channel <= endChannel; channel++) {
				Cmd *command = [self commandAtRow:row channel:channel];
				if (command == NULL) continue;
				if (command->ins == 0 && command->note == 0xFF && command->cmd == 0 &&
					command->arg == 0 && command->vol == 0xFF) continue;
				*command = (Cmd){0, 0xFF, 0, 0, 0xFF, 0};
				changed = YES;
			}
		}
		if (!changed) { NSBeep(); return; }
		[self registerUndoData:undo actionName:@"Clear Classical Selection"];
		self.music->hasChanged = true;
		[self.canvas setNeedsDisplay:YES];
		if (self.changeHandler != nil) self.changeHandler();
		return;
	}
	[self editRow:self.canvas.selectedRow note:0 erase:YES];
}

- (void)stopPreview
{
	if (self.mode == PPPatternEditorModeWave) [self endWavePlayGesture];
	if (self.mode == PPPatternEditorModeClassical) [self endClassicalPlayGesture];
	if (self.driver != NULL && self.previewActive && self.previewChannel >= 0 &&
		self.previewChannel < MAXTRACK) {
		MADDriverClearChannel(self.driver, (int)self.previewChannel);
	}
	self.previewActive = NO;
	self.previewChannel = -1;
}

- (void)windowWillClose:(NSNotification *)notification
{
	(void)notification;
	[self.playbackTimer invalidate];
	self.playbackTimer = nil;
	[self endWavePlayGesture];
	[self endClassicalPlayGesture];
	if (self.mode == PPPatternEditorModeBox && self.scrollView != nil) {
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification
			object:self.scrollView.contentView];
	}
	if (self.mode == PPPatternEditorModeWave && self.scrollView != nil) {
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification
			object:self.scrollView.contentView];
	}
	if (self.mode == PPPatternEditorModeClassical && self.scrollView != nil) {
		[NSNotificationCenter.defaultCenter removeObserver:self name:NSViewBoundsDidChangeNotification
			object:self.scrollView.contentView];
	}
	[self stopPreview];
	if (self.closeHandler != nil) self.closeHandler();
}

- (void)windowDidResize:(NSNotification *)notification
{
	(void)notification;
	if (self.mode == PPPatternEditorModeWave && self.canvas != nil) {
		[self.canvas resizeForContent];
		[self waveScrollChanged:nil];
	} else if (self.mode == PPPatternEditorModeClassicOverview && self.canvas != nil) {
		[self.canvas resizeForContent];
		[self updateOverviewInformation];
	} else if (self.mode == PPPatternEditorModeClassical && self.canvas != nil) {
		[self.canvas resizeForContent];
		[self classicalScrollChanged:nil];
	}
}

@end
