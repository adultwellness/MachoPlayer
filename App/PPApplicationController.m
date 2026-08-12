#import "PPApplicationController.h"
#import "PPEqualizerController.h"
#import "PPInstrumentEditorController.h"
#import "PPMixerController.h"
#import "PPPianoController.h"
#import "PPPatternCommandCodec.h"
#import "PPPatternModeController.h"
#import "PPPreferences.h"
#import "PPSampleEditorController.h"

#import <AudioToolbox/AudioToolbox.h>

#include <limits.h>

#include "PlayerPROCore.h"
#include "MADDriver.h"
#include "MIDI-Hardware-OSX.h"

static NSString *const PPPatternColumnPrefix = @"pattern-";
static NSPasteboardType const PPPatternPasteboardType = @"com.playerpro.pattern-commands";
static NSString *const PPPatternBandRowsDefaultsKey = @"DigitalPatternHighlightedRows";
static NSInteger const PPDefaultPatternBandRows = 4;
static CGFloat const PPInstrumentListCompactWidth = 212.0;
static CGFloat const PPInstrumentListExpandedWidth = 312.0;
// Partition.c used a 94-point compact sequencer and a 200-point expanded
// variant.  The compact form is the narrow Pos/ID window shown in the 2002 UI;
// expanding reveals the pattern-name column without changing the row layout.
static CGFloat const PPPartitionCompactWidth = 94.0;
static CGFloat const PPPartitionExpandedWidth = 200.0;
// Pos, popup and ID end at x=67 in PPPartitionCellView. Terminating the
// compact table at x=70 prevents any name glyph from reaching the scroller.
static CGFloat const PPPartitionCompactColumnWidth = 70.0;
static CGFloat const PPPartitionExpandedColumnWidth = 183.0;
static NSInteger const PPPreferenceRadioTagBase = 10000;

typedef NS_ENUM(NSInteger, PPPreferencesCategory) {
	PPPreferencesCategoryDriver = 0,
	PPPreferencesCategoryPiano,
	PPPreferencesCategoryMIDI,
	PPPreferencesCategoryMusicList,
	PPPreferencesCategoryColor,
	PPPreferencesCategoryMisc,
	PPPreferencesCategoryBoxEditor,
	PPPreferencesCategoryDigitalEditor,
	PPPreferencesCategoryClassicalEditor,
	PPPreferencesCategoryFKeys
};

typedef struct {
	size_t headerBytes;
	size_t lengthBytes;
	unsigned int sampleRate;
	MADByte bits;
	MADBool stereo;
	BOOL signedPCM;
	BOOL littleEndian;
} PPRawSampleSettings;

typedef NS_ENUM(NSInteger, PPToneGeneratorWaveform) {
	PPToneGeneratorSilence = 0,
	PPToneGeneratorTriangle,
	PPToneGeneratorSquare,
	PPToneGeneratorSine
};

typedef struct {
	size_t frames;
	double frequency;
	double amplitudePercent;
	PPToneGeneratorWaveform waveform;
	MADBool stereo;
} PPToneGeneratorSettings;

static double const PPToneGeneratorSampleRate = 22254.54545;

static void *PPCreateToneGeneratorPCM(PPToneGeneratorSettings settings, size_t *byteCountOut)
{
	if (byteCountOut != NULL) *byteCountOut = 0;
	size_t channels = settings.stereo ? 2 : 1;
	if (settings.frames == 0 || settings.frames > INT_MAX / (sizeof(int16_t) * channels) ||
		settings.frequency <= 0.0 || settings.amplitudePercent < 0.0 ||
		settings.amplitudePercent > 100.0) return NULL;
	size_t sampleCount = settings.frames * channels;
	int16_t *output = calloc(sampleCount, sizeof(int16_t));
	if (output == NULL) return NULL;
	double gain = settings.amplitudePercent / 100.0;
	for (size_t frame = 0; frame < settings.frames; frame++) {
		double phase = 2.0 * M_PI * settings.frequency * (double)frame / PPToneGeneratorSampleRate;
		double value = 0.0;
		switch (settings.waveform) {
			case PPToneGeneratorTriangle: value = (2.0 / M_PI) * asin(sin(phase)); break;
			case PPToneGeneratorSquare: value = sin(phase) >= 0.0 ? 1.0 : -1.0; break;
			case PPToneGeneratorSine: value = sin(phase); break;
			case PPToneGeneratorSilence: break;
		}
		int16_t encoded = (int16_t)lrint(MIN(MAX(value * gain, -1.0), 1.0) * 32767.0);
		for (size_t channel = 0; channel < channels; channel++) output[frame * channels + channel] = encoded;
	}
	if (byteCountOut != NULL) *byteCountOut = sampleCount * sizeof(int16_t);
	return output;
}

static void *PPCreateRawPCM(NSData *source, PPRawSampleSettings settings, size_t *byteCountOut)
{
	if (byteCountOut != NULL) *byteCountOut = 0;
	if (source.length == 0 || settings.headerBytes >= source.length ||
		(settings.bits != 8 && settings.bits != 16)) return NULL;
	size_t channels = settings.stereo ? 2 : 1;
	size_t bytesPerFrame = (settings.bits / 8) * channels;
	size_t available = source.length - settings.headerBytes;
	size_t requested = settings.lengthBytes == 0 ? available : MIN(settings.lengthBytes, available);
	size_t byteCount = requested - requested % bytesPerFrame;
	if (byteCount == 0 || byteCount > INT_MAX) return NULL;
	uint8_t *output = malloc(byteCount);
	if (output == NULL) return NULL;
	const uint8_t *input = (const uint8_t *)source.bytes + settings.headerBytes;
	if (settings.bits == 8) {
		for (size_t index = 0; index < byteCount; index++) {
			int value = settings.signedPCM ? (int)(int8_t)input[index] : (int)input[index] - 128;
			((int8_t *)output)[index] = (int8_t)value;
		}
	} else {
		size_t values = byteCount / 2;
		for (size_t index = 0; index < values; index++) {
			const uint8_t *bytes = input + index * 2;
			uint16_t encoded = settings.littleEndian
				? (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8))
				: (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
			int32_t value = settings.signedPCM ? (int16_t)encoded : (int32_t)encoded - 32768;
			((int16_t *)output)[index] = (int16_t)value;
		}
	}
	if (byteCountOut != NULL) *byteCountOut = byteCount;
	return output;
}

static NSError *PPPatternFileError(NSString *description)
{
	return [NSError errorWithDomain:@"com.machoplayer.pattern-file" code:1
		userInfo:@{NSLocalizedDescriptionKey: description}];
}

static void PPSetPatternFileError(NSError **error, NSString *description)
{
	if (error != NULL) *error = PPPatternFileError(description);
}

// Standalone 'PATN' files were raw PatHeader + Cmd blocks written by the
// PowerPC application, so their four 32-bit header fields are big-endian.
// Commands contain only bytes and need no conversion.
static NSData *PPCreatePatternFileData(PatData *pattern, NSInteger channels, NSString *exportName)
{
	if (pattern == NULL || pattern->header.size < 1 || pattern->header.size > MAXPATTERNSIZE ||
		channels < 1 || channels > MAXTRACK) return nil;
	NSUInteger commandBytes = (NSUInteger)channels * (NSUInteger)pattern->header.size * sizeof(Cmd);
	NSMutableData *data = [NSMutableData dataWithLength:sizeof(PatHeader) + commandBytes];
	PatHeader *header = data.mutableBytes;
	*header = pattern->header;
	header->compMode = PatternCompressionNone;
	header->patBytes = (int)commandBytes;
	header->unused2 = 0;
	if (exportName.length > 0) {
		memset(header->name, 0, sizeof(header->name));
		NSData *nameData = [exportName dataUsingEncoding:NSMacOSRomanStringEncoding
			allowLossyConversion:YES];
		memcpy(header->name, nameData.bytes, MIN(nameData.length, sizeof(header->name) - 1));
	}
	memcpy((uint8_t *)data.mutableBytes + sizeof(PatHeader), pattern->Cmds, commandBytes);
	MADBE32(&header->size);
	MADBE32(&header->compMode);
	MADBE32(&header->patBytes);
	MADBE32(&header->unused2);
	return data;
}

static BOOL PPPatternFileHeaderIsUsable(PatHeader header)
{
	return header.size >= 1 && header.size <= MAXPATTERNSIZE &&
		header.compMode == PatternCompressionNone;
}

static PatData *PPCreatePatternFromFileData(NSData *data, NSInteger targetChannels, NSError **error)
{
	if (data.length < sizeof(PatHeader)) {
		PPSetPatternFileError(error, @"This pattern file is too short to contain a PlayerPRO pattern.");
		return NULL;
	}
	if (targetChannels < 1 || targetChannels > MAXTRACK) {
		PPSetPatternFileError(error, @"The current song has an unsupported track count.");
		return NULL;
	}

	PatHeader encoded = {0};
	memcpy(&encoded, data.bytes, sizeof(encoded));
	PatHeader bigEndian = encoded;
	MADBE32(&bigEndian.size);
	MADBE32(&bigEndian.compMode);
	MADBE32(&bigEndian.patBytes);
	MADBE32(&bigEndian.unused2);
	PatHeader littleEndian = encoded;
	MADLE32(&littleEndian.size);
	MADLE32(&littleEndian.compMode);
	MADLE32(&littleEndian.patBytes);
	MADLE32(&littleEndian.unused2);

	// Big-endian is the authentic 2002 format. Accept host/little-endian files
	// as a courtesy to early MachoPlayer builds that may have written raw data.
	PatHeader decoded = {0};
	if (PPPatternFileHeaderIsUsable(bigEndian)) decoded = bigEndian;
	else if (PPPatternFileHeaderIsUsable(littleEndian)) decoded = littleEndian;
	else {
		PPSetPatternFileError(error,
			@"This is not a valid uncompressed PlayerPRO pattern file.");
		return NULL;
	}

	NSUInteger payloadBytes = data.length - sizeof(PatHeader);
	NSUInteger bytesPerTrack = (NSUInteger)decoded.size * sizeof(Cmd);
	if (bytesPerTrack == 0 || payloadBytes == 0 || payloadBytes % bytesPerTrack != 0) {
		PPSetPatternFileError(error, @"The pattern command data is incomplete or damaged.");
		return NULL;
	}
	NSUInteger sourceChannels = payloadBytes / bytesPerTrack;
	if (sourceChannels < 1 || sourceChannels > MAXTRACK) {
		PPSetPatternFileError(error, @"The pattern file has an unsupported track count.");
		return NULL;
	}

	NSUInteger targetCommandBytes = (NSUInteger)targetChannels * bytesPerTrack;
	PatData *pattern = calloc(sizeof(PatHeader) + targetCommandBytes, 1);
	if (pattern == NULL) {
		PPSetPatternFileError(error, @"There is not enough memory to load this pattern.");
		return NULL;
	}
	pattern->header = decoded;
	pattern->header.compMode = PatternCompressionNone;
	pattern->header.patBytes = (int)targetCommandBytes;
	pattern->header.unused2 = 0;
	for (NSInteger channel = 0; channel < targetChannels; channel++) {
		for (NSInteger row = 0; row < decoded.size; row++) {
			MADKillCmd(GetMADCommand((short)row, (short)channel, pattern));
		}
	}
	const Cmd *source = (const Cmd *)((const uint8_t *)data.bytes + sizeof(PatHeader));
	NSUInteger copiedChannels = MIN(sourceChannels, (NSUInteger)targetChannels);
	for (NSUInteger channel = 0; channel < copiedChannels; channel++) {
		memcpy(pattern->Cmds + channel * (NSUInteger)decoded.size,
			source + channel * (NSUInteger)decoded.size, bytesPerTrack);
	}
	return pattern;
}

BOOL PPApplicationRunPatternFileSelfTest(void)
{
	NSUInteger bytes = sizeof(PatHeader) + 2 * 4 * sizeof(Cmd);
	PatData *source = calloc(bytes, 1);
	if (source == NULL) return NO;
	source->header.size = 4;
	source->header.compMode = PatternCompressionMAD1; // Export must normalize this.
	memcpy(source->header.name, "Pattern test", 12);
	for (NSInteger channel = 0; channel < 2; channel++) {
		for (NSInteger row = 0; row < 4; row++) MADKillCmd(GetMADCommand((short)row, (short)channel, source));
	}
	*GetMADCommand(2, 1, source) = (Cmd){3, 48, MADEffectOffset, 0x80, 0x40, 0};
	NSData *encoded = PPCreatePatternFileData(source, 2, nil);
	const uint8_t *raw = encoded.bytes;
	BOOL passed = encoded.length == bytes && raw != NULL &&
		raw[0] == 0 && raw[1] == 0 && raw[2] == 0 && raw[3] == 4;
	NSError *error = nil;
	PatData *decoded = PPCreatePatternFromFileData(encoded, 3, &error);
	Cmd *copied = decoded == NULL ? NULL : GetMADCommand(2, 1, decoded);
	Cmd *blank = decoded == NULL ? NULL : GetMADCommand(2, 2, decoded);
	passed = passed && error == nil && decoded != NULL && decoded->header.size == 4 &&
		decoded->header.compMode == PatternCompressionNone && copied != NULL &&
		copied->ins == 3 && copied->note == 48 && copied->cmd == MADEffectOffset &&
		copied->arg == 0x80 && copied->vol == 0x40 && blank != NULL &&
		blank->ins == 0 && blank->note == 0xFF && blank->vol == 0xFF;
	free(decoded);
	free(source);
	return passed;
}

@interface PPRawImportControlView : NSView
@property(nonatomic, strong) NSTextField *headerField;
@property(nonatomic, strong) NSTextField *lengthField;
@property(nonatomic, strong) NSTextField *rateField;
@property(nonatomic, strong) NSPopUpButton *bitsPopup;
@property(nonatomic, strong) NSPopUpButton *channelsPopup;
@property(nonatomic, strong) NSPopUpButton *encodingPopup;
@property(nonatomic, strong) NSPopUpButton *endianPopup;
@end

BOOL PPApplicationRunSampleWorkflowSelfTest(void)
{
	uint8_t unsignedEight[] = {0, 128, 255};
	PPRawSampleSettings eightSettings = {
		.headerBytes = 0, .lengthBytes = sizeof(unsignedEight), .sampleRate = 22050,
		.bits = 8, .stereo = MADFalse, .signedPCM = NO, .littleEndian = YES
	};
	size_t byteCount = 0;
	int8_t *eight = PPCreateRawPCM([NSData dataWithBytes:unsignedEight length:sizeof(unsignedEight)],
		eightSettings, &byteCount);
	BOOL passed = eight != NULL && byteCount == sizeof(unsignedEight) &&
		eight[0] == INT8_MIN && eight[1] == 0 && eight[2] == INT8_MAX;
	free(eight);

	uint8_t signedLittleSixteen[] = {0x55, 0xaa, 0x00, 0x80, 0x34, 0x12, 0xff};
	PPRawSampleSettings littleSettings = {
		.headerBytes = 2, .lengthBytes = 5, .sampleRate = 44100,
		.bits = 16, .stereo = MADFalse, .signedPCM = YES, .littleEndian = YES
	};
	int16_t *little = PPCreateRawPCM([NSData dataWithBytes:signedLittleSixteen
		length:sizeof(signedLittleSixteen)], littleSettings, &byteCount);
	passed = passed && little != NULL && byteCount == 4 &&
		little[0] == INT16_MIN && little[1] == 0x1234;
	free(little);

	uint8_t unsignedBigSixteen[] = {0x00, 0x00, 0x80, 0x00, 0xff, 0xff, 0x44, 0x44};
	PPRawSampleSettings bigSettings = {
		.headerBytes = 0, .lengthBytes = sizeof(unsignedBigSixteen), .sampleRate = 44100,
		.bits = 16, .stereo = MADTrue, .signedPCM = NO, .littleEndian = NO
	};
	int16_t *big = PPCreateRawPCM([NSData dataWithBytes:unsignedBigSixteen
		length:sizeof(unsignedBigSixteen)], bigSettings, &byteCount);
	passed = passed && big != NULL && byteCount == sizeof(unsignedBigSixteen) &&
		big[0] == INT16_MIN && big[1] == 0 && big[2] == INT16_MAX && big[3] == (int16_t)0xc444;
	free(big);

	PPToneGeneratorSettings silenceSettings = {
		.frames = 32, .frequency = 440.0, .amplitudePercent = 100.0,
		.waveform = PPToneGeneratorSilence, .stereo = MADFalse
	};
	int16_t *silence = PPCreateToneGeneratorPCM(silenceSettings, &byteCount);
	passed = passed && silence != NULL && byteCount == 32 * sizeof(int16_t);
	for (NSInteger frame = 0; passed && frame < 32; frame++) passed = silence[frame] == 0;
	free(silence);

	PPToneGeneratorSettings toneSettings = {
		.frames = 64, .frequency = 440.0, .amplitudePercent = 50.0,
		.waveform = PPToneGeneratorSine, .stereo = MADTrue
	};
	int16_t *tone = PPCreateToneGeneratorPCM(toneSettings, &byteCount);
	BOOL foundTone = NO;
	for (NSInteger frame = 0; tone != NULL && frame < 64; frame++) {
		foundTone |= tone[frame * 2] != 0;
		passed = passed && tone[frame * 2] == tone[frame * 2 + 1];
	}
	passed = passed && tone != NULL && byteCount == 64 * 2 * sizeof(int16_t) && foundTone;
	free(tone);
	return passed;
}

@implementation PPRawImportControlView

- (instancetype)initWithFileSize:(NSUInteger)fileSize
{
	self = [super initWithFrame:NSMakeRect(0, 0, 390, 205)];
	if (self == nil) return nil;
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSArray<NSString *> *labels = @[@"Header:", @"Length:", @"Rate:", @"Bit depth:",
		@"Channels:", @"Encoding:", @"Byte order:"];
	for (NSInteger row = 0; row < (NSInteger)labels.count; row++) {
		CGFloat y = 178 - row * 27;
		NSTextField *label = [NSTextField labelWithString:labels[row]];
		label.frame = NSMakeRect(0, y + 3, 105, 18);
		label.font = font;
		label.textColor = NSColor.blackColor;
		[self addSubview:label];
	}
	self.headerField = [NSTextField textFieldWithString:@"0"];
	self.lengthField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%lu", (unsigned long)fileSize]];
	self.rateField = [NSTextField textFieldWithString:@"22050"];
	NSArray<NSTextField *> *fields = @[self.headerField, self.lengthField, self.rateField];
	NSArray<NSString *> *suffixes = @[@"bytes", @"bytes (0 = to end)", @"Hz"];
	for (NSInteger row = 0; row < 3; row++) {
		NSTextField *field = fields[row];
		field.frame = NSMakeRect(110, 176 - row * 27, 115, 22);
		field.font = font;
		field.alignment = NSTextAlignmentRight;
		field.textColor = NSColor.blackColor;
		field.backgroundColor = NSColor.whiteColor;
		[self addSubview:field];
		NSTextField *suffix = [NSTextField labelWithString:suffixes[row]];
		suffix.frame = NSMakeRect(232, 179 - row * 27, 150, 18);
		suffix.font = font;
		suffix.textColor = NSColor.blackColor;
		[self addSubview:suffix];
	}
	NSArray<NSArray<NSString *> *> *choices = @[
		@[@"8-bit", @"16-bit"], @[@"Mono", @"Stereo"], @[@"Signed PCM", @"Unsigned PCM"],
		@[@"Little-endian", @"Big-endian"]
	];
	NSMutableArray<NSPopUpButton *> *popups = [NSMutableArray arrayWithCapacity:4];
	for (NSInteger row = 0; row < 4; row++) {
		NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 176 - (row + 3) * 27, 180, 23)
			pullsDown:NO];
		[popup addItemsWithTitles:choices[row]];
		popup.font = font;
		[self addSubview:popup];
		[popups addObject:popup];
	}
	self.bitsPopup = popups[0];
	self.channelsPopup = popups[1];
	self.encodingPopup = popups[2];
	self.endianPopup = popups[3];
	[self.bitsPopup selectItemAtIndex:1];
#if __BIG_ENDIAN__
	[self.endianPopup selectItemAtIndex:1];
#else
	[self.endianPopup selectItemAtIndex:0];
#endif
	return self;
}

@end

@interface PPToneGeneratorContentView : NSView
@end

@implementation PPToneGeneratorContentView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];

	NSBezierPath *waveforms = [NSBezierPath bezierPath];
	waveforms.lineWidth = 1.0;
	// Silence.
	[waveforms moveToPoint:NSMakePoint(124, 169.5)];
	[waveforms lineToPoint:NSMakePoint(178, 169.5)];
	// Triangle.
	[waveforms moveToPoint:NSMakePoint(221, 160)];
	[waveforms lineToPoint:NSMakePoint(244, 183)];
	[waveforms lineToPoint:NSMakePoint(269, 157)];
	// Square.
	[waveforms moveToPoint:NSMakePoint(124, 130)];
	[waveforms lineToPoint:NSMakePoint(142, 130)];
	[waveforms lineToPoint:NSMakePoint(142, 149)];
	[waveforms lineToPoint:NSMakePoint(160, 149)];
	[waveforms lineToPoint:NSMakePoint(160, 130)];
	[waveforms lineToPoint:NSMakePoint(178, 130)];
	// Sine wave.
	NSBezierPath *sine = [NSBezierPath bezierPath];
	sine.lineWidth = 1.0;
	for (NSInteger point = 0; point <= 48; point++) {
		CGFloat fraction = point / 48.0;
		NSPoint position = NSMakePoint(221 + fraction * 48.0,
			139.5 + sin(fraction * M_PI * 2.0) * 12.0);
		if (point == 0) [sine moveToPoint:position]; else [sine lineToPoint:position];
	}
	[waveforms stroke];
	[sine stroke];
}
@end

@interface PPToneGeneratorDialogController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSPanel *window;
@property(nonatomic, strong) NSTextField *lengthField;
@property(nonatomic, strong) NSTextField *frequencyField;
@property(nonatomic, strong) NSTextField *amplitudeField;
@property(nonatomic, strong) NSArray<NSButton *> *waveformButtons;
@property(nonatomic, strong) NSArray<NSButton *> *modeButtons;
@property(nonatomic) PPToneGeneratorWaveform selectedWaveform;
@property(nonatomic) MADBool stereo;
@property(nonatomic) PPToneGeneratorSettings acceptedSettings;
@property(nonatomic, copy) void (^previewHandler)(PPToneGeneratorSettings settings);
@end

@implementation PPToneGeneratorDialogController

- (instancetype)initWithPreviewHandler:(void (^)(PPToneGeneratorSettings))previewHandler
{
	self = [super init];
	if (self == nil) return nil;
	_previewHandler = [previewHandler copy];
	_selectedWaveform = PPToneGeneratorSilence;
	_stereo = MADFalse;
	_window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 274, 202)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"Tone Generator";
	_window.releasedWhenClosed = NO;
	_window.floatingPanel = YES;
	_window.hidesOnDeactivate = NO;
	_window.delegate = self;
	_window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	PPToneGeneratorContentView *content = [[PPToneGeneratorContentView alloc]
		initWithFrame:NSMakeRect(0, 0, 274, 202)];
	_window.contentView = content;
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSFont *boldFont = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];

	NSTextField *(^label)(NSString *, NSRect, NSFont *) = ^NSTextField *(NSString *text, NSRect frame, NSFont *labelFont) {
		NSTextField *field = [NSTextField labelWithString:text];
		field.frame = frame;
		field.font = labelFont;
		field.textColor = NSColor.blackColor;
		[content addSubview:field];
		return field;
	};
	label(@"Wave type:", NSMakeRect(16, 163, 88, 18), boldFont);
	label(@"Length:", NSMakeRect(16, 94, 78, 18), boldFont);
	label(@"Frequency:", NSMakeRect(16, 64, 78, 18), boldFont);
	label(@"Amplitude:", NSMakeRect(16, 34, 78, 18), boldFont);
	label(@"%", NSMakeRect(159, 34, 18, 18), boldFont);
	label(@"Mode:", NSMakeRect(16, 4, 65, 18), boldFont);

	_lengthField = [NSTextField textFieldWithString:@"2000"];
	_frequencyField = [NSTextField textFieldWithString:@"440"];
	_amplitudeField = [NSTextField textFieldWithString:@"100"];
	NSArray<NSTextField *> *fields = @[_lengthField, _frequencyField, _amplitudeField];
	NSArray<NSValue *> *fieldFrames = @[[NSValue valueWithRect:NSMakeRect(102, 90, 77, 23)],
		[NSValue valueWithRect:NSMakeRect(102, 60, 77, 23)],
		[NSValue valueWithRect:NSMakeRect(102, 30, 55, 23)]];
	for (NSInteger index = 0; index < (NSInteger)fields.count; index++) {
		NSTextField *field = fields[index];
		field.frame = fieldFrames[index].rectValue;
		field.font = font;
		field.alignment = NSTextAlignmentRight;
		field.textColor = NSColor.blackColor;
		field.backgroundColor = NSColor.whiteColor;
		field.focusRingType = NSFocusRingTypeExterior;
		[content addSubview:field];
	}

	NSMutableArray<NSButton *> *waveButtons = [NSMutableArray arrayWithCapacity:4];
	NSArray<NSValue *> *waveFrames = @[[NSValue valueWithRect:NSMakeRect(105, 161, 18, 18)],
		[NSValue valueWithRect:NSMakeRect(197, 161, 18, 18)],
		[NSValue valueWithRect:NSMakeRect(105, 131, 18, 18)],
		[NSValue valueWithRect:NSMakeRect(197, 131, 18, 18)]];
	for (NSInteger waveform = 0; waveform < 4; waveform++) {
		NSButton *button = [NSButton radioButtonWithTitle:@"" target:self action:@selector(selectWaveform:)];
		button.frame = waveFrames[waveform].rectValue;
		button.tag = waveform;
		button.state = waveform == PPToneGeneratorSilence ? NSControlStateValueOn : NSControlStateValueOff;
		button.toolTip = @[@"Silence", @"Triangle", @"Square", @"Sine wave"][waveform];
		button.accessibilityLabel = button.toolTip;
		[content addSubview:button];
		[waveButtons addObject:button];
	}
	_waveformButtons = waveButtons;

	NSMutableArray<NSButton *> *modes = [NSMutableArray arrayWithCapacity:2];
	for (NSInteger mode = 0; mode < 2; mode++) {
		NSButton *button = [NSButton radioButtonWithTitle:mode == 0 ? @"Mono" : @"Stereo"
			target:self action:@selector(selectMode:)];
		button.frame = NSMakeRect(mode == 0 ? 102 : 171, 1, 68, 22);
		button.font = font;
		button.tag = mode;
		button.state = mode == 0 ? NSControlStateValueOn : NSControlStateValueOff;
		[content addSubview:button];
		[modes addObject:button];
	}
	_modeButtons = modes;

	NSArray<NSString *> *buttonTitles = @[@"Play", @"OK", @"Cancel"];
	SEL actions[] = {@selector(preview:), @selector(accept:), @selector(cancel:)};
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [NSButton buttonWithTitle:buttonTitles[index] target:self action:actions[index]];
		button.frame = NSMakeRect(207, 91 - index * 31, 59, 24);
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.font = boldFont;
		button.focusRingType = NSFocusRingTypeNone;
		if (index == 1) button.keyEquivalent = @"\r";
		if (index == 2) button.keyEquivalent = @"\e";
		[content addSubview:button];
	}
	return self;
}

- (void)selectWaveform:(NSButton *)sender
{
	self.selectedWaveform = (PPToneGeneratorWaveform)sender.tag;
	for (NSButton *button in self.waveformButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)selectMode:(NSButton *)sender
{
	self.stereo = sender.tag == 1 ? MADTrue : MADFalse;
	for (NSButton *button in self.modeButtons)
		button.state = button == sender ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)readSettings:(PPToneGeneratorSettings *)settings
{
	BOOL (^integerValue)(NSTextField *, unsigned long long, unsigned long long, unsigned long long *) =
		^BOOL(NSTextField *field, unsigned long long minimum, unsigned long long maximum,
			unsigned long long *value) {
			NSString *text = [field.stringValue stringByTrimmingCharactersInSet:
				NSCharacterSet.whitespaceAndNewlineCharacterSet];
			NSScanner *scanner = [NSScanner scannerWithString:text];
			unsigned long long parsed = 0;
			if (text.length == 0 || ![scanner scanUnsignedLongLong:&parsed] || !scanner.isAtEnd ||
				parsed < minimum || parsed > maximum) {
				NSBeep();
				[self.window makeFirstResponder:field];
				[field selectText:nil];
				return NO;
			}
			*value = parsed;
			return YES;
		};
	unsigned long long frames = 0, frequency = 0, amplitude = 0;
	if (!integerValue(self.lengthField, 1, 20ULL * 1024ULL * 1024ULL, &frames) ||
		!integerValue(self.frequencyField, 1, 50000, &frequency) ||
		!integerValue(self.amplitudeField, 0, 100, &amplitude)) return NO;
	if (settings != NULL) {
		*settings = (PPToneGeneratorSettings){.frames = (size_t)frames,
			.frequency = (double)frequency, .amplitudePercent = (double)amplitude,
			.waveform = self.selectedWaveform, .stereo = self.stereo};
	}
	return YES;
}

- (void)preview:(id)sender
{
	(void)sender;
	PPToneGeneratorSettings settings = {0};
	if ([self readSettings:&settings] && self.previewHandler != nil) self.previewHandler(settings);
}

- (void)accept:(id)sender
{
	(void)sender;
	PPToneGeneratorSettings settings = {0};
	if (![self readSettings:&settings]) return;
	self.acceptedSettings = settings;
	[NSApp stopModalWithCode:NSModalResponseOK];
}

- (void)cancel:(id)sender
{
	(void)sender;
	[NSApp abortModal];
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
	(void)sender;
	if (NSApp.modalWindow == self.window) [NSApp abortModal];
	return YES;
}

@end

static NSAppearance *PPClassicLightAppearance(void)
{
	static NSAppearance *appearance;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	});
	return appearance;
}

static NSImage *PPOriginalLoopTransportImage(void)
{
	static NSImage *image;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// The upper-left 20 × 20 pixels of PlayerPRO 2002's ICN# 191 loop control.
		static const uint32_t rows[20] = {
			0x00000000, 0x00000000, 0x00000000, 0x00E00000, 0x03E00000,
			0x07060000, 0x06070000, 0x0C0F8000, 0x0C1F0000, 0x0C030000,
			0x0C030000, 0x0F830000, 0x1F030000, 0x0E060000, 0x020E0000,
			0x007C0000, 0x00700000, 0x00000000, 0x00000000, 0x00000000
		};
		image = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:NO drawingHandler:^BOOL(NSRect destination) {
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
	});
	return image;
}

static NSImage *PPOriginalRecordTransportImage(void)
{
	static NSImage *image;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		// PlayerPRO's icl8 130 record lamp: a small red octagon centered in
		// the 20-pixel transport button, retained without template tinting.
		image = [NSImage imageWithSize:NSMakeSize(20, 20) flipped:NO drawingHandler:^BOOL(NSRect destination) {
			CGFloat sx = NSWidth(destination) / 20.0;
			CGFloat sy = NSHeight(destination) / 20.0;
			NSBezierPath *lamp = [NSBezierPath bezierPath];
			[lamp moveToPoint:NSMakePoint(NSMinX(destination) + 7 * sx, NSMinY(destination) + 4 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 13 * sx, NSMinY(destination) + 4 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 16 * sx, NSMinY(destination) + 7 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 16 * sx, NSMinY(destination) + 13 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 13 * sx, NSMinY(destination) + 16 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 7 * sx, NSMinY(destination) + 16 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 4 * sx, NSMinY(destination) + 13 * sy)];
			[lamp lineToPoint:NSMakePoint(NSMinX(destination) + 4 * sx, NSMinY(destination) + 7 * sy)];
			[lamp closePath];
			[[NSColor colorWithCalibratedRed:0.94 green:0.02 blue:0.02 alpha:1.0] setFill];
			[lamp fill];
			return YES;
		}];
		image.template = NO;
	});
	return image;
}

static void PPForceClassicLightAppearanceOnView(NSView *view)
{
	view.appearance = PPClassicLightAppearance();
	if ([view isKindOfClass:NSTextField.class]) {
		NSTextField *field = (NSTextField *)view;
		field.textColor = NSColor.blackColor;
		if (field.isEditable) {
			field.drawsBackground = YES;
			field.backgroundColor = NSColor.whiteColor;
		}
	} else if ([view isKindOfClass:NSTextView.class]) {
		NSTextView *textView = (NSTextView *)view;
		textView.textColor = NSColor.blackColor;
		textView.insertionPointColor = NSColor.blackColor;
		textView.drawsBackground = YES;
		textView.backgroundColor = NSColor.whiteColor;
	} else if ([view isKindOfClass:NSTableView.class]) {
		((NSTableView *)view).backgroundColor = NSColor.whiteColor;
	} else if ([view isKindOfClass:NSClipView.class]) {
		NSClipView *clipView = (NSClipView *)view;
		clipView.drawsBackground = YES;
		clipView.backgroundColor = NSColor.whiteColor;
	}
	for (NSView *subview in view.subviews) {
		PPForceClassicLightAppearanceOnView(subview);
	}
}

static void PPForceClassicLightAppearanceOnWindow(NSWindow *window)
{
	window.appearance = PPClassicLightAppearance();
	window.backgroundColor = [NSColor colorWithCalibratedWhite:0.90 alpha:1.0];
	if (window.contentView != nil) PPForceClassicLightAppearanceOnView(window.contentView);
}

typedef struct {
	uint32_t magic;
	uint16_t version;
	uint16_t rows;
	uint16_t channels;
	uint16_t reserved;
} PPPatternClipboardHeader;

@interface PPPatternSnapshot : NSObject
@property(nonatomic) NSInteger pattern;
@property(nonatomic) NSInteger rows;
@property(nonatomic) NSInteger channels;
@property(nonatomic, strong) NSData *commands;
@end

@implementation PPPatternSnapshot
@end

@interface PPPatternCollectionSnapshot : NSObject
@property(nonatomic, strong) NSData *headerData;
@property(nonatomic, strong) NSArray<NSData *> *patterns;
@property(nonatomic) NSInteger selectedPattern;
@property(nonatomic) NSInteger selectedPartitionPosition;
@end

@implementation PPPatternCollectionSnapshot
@end

@protocol PPPatternTableCommandDelegate <NSObject>
- (BOOL)patternTableHandleKeyDown:(NSEvent *)event;
- (BOOL)patternTableBeginSelection:(NSEvent *)event;
- (void)patternTableOpenCommandInspector:(NSEvent *)event;
- (void)patternTableContinueSelection:(NSEvent *)event;
- (void)patternTableEndSelection:(NSEvent *)event;
- (void)patternTableSelectTrackFromHeader:(NSInteger)channel extend:(BOOL)extend;
- (void)copyPatternSelection:(id)sender;
- (void)cutPatternSelection:(id)sender;
- (void)pastePatternSelection:(id)sender;
- (void)clearPatternSelection:(id)sender;
- (void)selectAllPatternCommands:(id)sender;
@end

@interface PPPatternTableView : NSTableView
@property(nonatomic, weak) id<PPPatternTableCommandDelegate> commandDelegate;
@property(nonatomic) BOOL trackingCommandSelection;
@end

@interface PPPatternHeaderView : NSTableHeaderView
@property(nonatomic, weak) id<PPPatternTableCommandDelegate> commandDelegate;
@end

@implementation PPPatternHeaderView
- (BOOL)isOpaque { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
	center.alignment = NSTextAlignmentCenter;
	for (NSInteger column = 0; column < (NSInteger)self.tableView.tableColumns.count; column++) {
		NSRect frame = [self headerRectOfColumn:column];
		if (!NSIntersectsRect(frame, self.bounds)) continue;
		NSColor *color = column == 0
			? [NSColor colorWithCalibratedWhite:0.86 alpha:1.0]
			: PPPreferredTrackColor(column - 1);
		[color setFill];
		NSRectFill(frame);
		[NSColor.blackColor setStroke];
		NSFrameRectWithWidth(NSInsetRect(frame, 0.5, 0.5), 1.0);
		if (column > 0) {
			NSString *title = [NSString stringWithFormat:@"%ld", (long)column];
			[title drawInRect:NSInsetRect(frame, 1, 0) withAttributes:@{
				NSFontAttributeName: font,
				NSForegroundColorAttributeName: NSColor.blackColor,
				NSParagraphStyleAttributeName: center
			}];
		}
	}
}

- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSInteger column = -1;
	for (NSInteger candidate = 0; candidate < (NSInteger)self.tableView.tableColumns.count; candidate++) {
		if (NSPointInRect(point, [self headerRectOfColumn:candidate])) {
			column = candidate;
			break;
		}
	}
	// Column zero is the row-number gutter. Track columns begin at one.
	if (column <= 0) {
		[super mouseDown:event];
		return;
	}
	[self.commandDelegate patternTableSelectTrackFromHeader:column - 1
		extend:(event.modifierFlags & NSEventModifierFlagShift) != 0];
}
@end

// AppKit leaves a small header/scroller intersection at the upper-right of an
// NSTableView. With a legacy scroller it can expose the final colored track
// header. The original Digital editor used the surrounding dialog gray here.
@interface PPPatternHeaderCornerView : NSView
@end

@implementation PPPatternHeaderCornerView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(self.bounds), NSMinY(self.bounds) + 0.5)
		toPoint:NSMakePoint(NSMaxX(self.bounds), NSMinY(self.bounds) + 0.5)];
}
@end


@implementation PPPatternTableView
- (void)keyDown:(NSEvent *)event
{
	if (![self.commandDelegate patternTableHandleKeyDown:event]) [super keyDown:event];
}
- (void)mouseDown:(NSEvent *)event
{
	self.trackingCommandSelection = [self.commandDelegate patternTableBeginSelection:event];
	if (self.trackingCommandSelection && event.clickCount >= 2) {
		[self.commandDelegate patternTableOpenCommandInspector:event];
		self.trackingCommandSelection = NO;
		return;
	}
	if (!self.trackingCommandSelection) [super mouseDown:event];
}
- (void)mouseDragged:(NSEvent *)event
{
	if (self.trackingCommandSelection) [self.commandDelegate patternTableContinueSelection:event];
	else [super mouseDragged:event];
}
- (void)mouseUp:(NSEvent *)event
{
	if (self.trackingCommandSelection) {
		[self.commandDelegate patternTableEndSelection:event];
		self.trackingCommandSelection = NO;
	} else {
		[super mouseUp:event];
	}
}
- (void)copy:(id)sender { [self.commandDelegate copyPatternSelection:sender]; }
- (void)cut:(id)sender { [self.commandDelegate cutPatternSelection:sender]; }
- (void)paste:(id)sender { [self.commandDelegate pastePatternSelection:sender]; }
- (void)delete:(id)sender { [self.commandDelegate clearPatternSelection:sender]; }
- (void)deleteBackward:(id)sender { [self.commandDelegate clearPatternSelection:sender]; }
- (void)selectAll:(id)sender { [self.commandDelegate selectAllPatternCommands:sender]; }
@end

@interface PPClassicControlStripView : NSView
@end

@implementation PPClassicControlStripView
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSBezierPath *rules = [NSBezierPath bezierPath];
	rules.lineWidth = 1.0;
	// Preserve the exact lower-row frame from the original Editor DITL 139.
	// Its group rules sit at x=100/183/287/392 and the row divider at y=25
	// (18 points from the bottom in this flipped QuickDraw-to-AppKit layout).
	[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), 18.5)];
	[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), 18.5)];
	for (NSNumber *position in @[@100.5, @183.5, @287.5, @392.5]) {
		[rules moveToPoint:NSMakePoint(position.doubleValue, NSMinY(self.bounds))];
		[rules lineToPoint:NSMakePoint(position.doubleValue, 18.5)];
	}
	[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), 0.5)];
	[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), 0.5)];
	[rules stroke];
}
@end

@interface PPClassicToolsTransportView : NSView
@end

@implementation PPClassicToolsTransportView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(NSInsetRect(self.bounds, 0.5, 0.5), 1.0);
}
@end

@interface PPClassicToolsInspectorView : NSView
@end

@implementation PPClassicToolsInspectorView
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSBezierPath *rules = [NSBezierPath bezierPath];
	rules.lineWidth = 1.0;
	[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), NSMaxY(self.bounds) - 0.5)];
	[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), NSMaxY(self.bounds) - 0.5)];
	[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), NSMaxY(self.bounds) - 20.5)];
	[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), NSMaxY(self.bounds) - 20.5)];
	[rules stroke];
	NSFrameRectWithWidth(NSInsetRect(self.bounds, 0.5, 0.5), 1.0);
}
@end

@interface PPClassicToolsHelpView : NSView
@end

@implementation PPClassicToolsHelpView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSBezierPath *border = [NSBezierPath bezierPath];
	border.lineWidth = 1.0;
	[border moveToPoint:NSMakePoint(0.5, NSMinY(self.bounds))];
	[border lineToPoint:NSMakePoint(0.5, NSMaxY(self.bounds))];
	[border moveToPoint:NSMakePoint(NSMinX(self.bounds), 0.5)];
	[border lineToPoint:NSMakePoint(NSMaxX(self.bounds), 0.5)];
	[border stroke];
}
@end

@interface PPHexPickerMenuView : NSView
@property(nonatomic) NSInteger value;
@property(nonatomic) NSInteger pendingHighDigit;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic) NSInteger hoverDigit;
@property(nonatomic) NSInteger hoverColumn;
@end

@implementation PPHexPickerMenuView

static const CGFloat PPHexPickerRowHeight = 13.0;
static const CGFloat PPHexPickerReadoutHeight = 40.0;

- (instancetype)initWithValue:(NSInteger)value target:(id)target action:(SEL)action
{
	self = [super initWithFrame:NSMakeRect(0, 0, 38, PPHexPickerReadoutHeight + 16 * PPHexPickerRowHeight)];
	if (self != nil) {
		_value = MIN(MAX(value, 0), 255);
		_pendingHighDigit = (_value >> 4) & 0x0F;
		_target = target;
		_action = action;
		_hoverDigit = -1;
		_hoverColumn = -1;
	}
	return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
	(void)event;
	return YES;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
	NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:self.bounds
		options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
		owner:self userInfo:nil];
	[self addTrackingArea:area];
}

- (void)setValue:(NSInteger)value
{
	_value = MIN(MAX(value, 0), 255);
	_pendingHighDigit = (_value >> 4) & 0x0F;
	[self setNeedsDisplay:YES];
}

- (void)updateHoverForEvent:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	NSInteger row = (NSInteger)floor((NSHeight(self.bounds) - point.y) / PPHexPickerRowHeight);
	if (row >= 0 && row < 16 && point.y >= PPHexPickerReadoutHeight) {
		self.hoverDigit = row;
		self.hoverColumn = point.x < NSMidX(self.bounds) ? 0 : 1;
		// PlayerPRO's two-column picker latched the first hexadecimal digit as
		// the pointer passed over it. The user could then move directly into the
		// right column and click the second digit to commit the combined byte.
		if (self.hoverColumn == 0) self.pendingHighDigit = row;
	} else {
		self.hoverDigit = -1;
		self.hoverColumn = -1;
	}
	[self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event { [self updateHoverForEvent:event]; }
- (void)mouseMoved:(NSEvent *)event { [self updateHoverForEvent:event]; }
- (void)mouseExited:(NSEvent *)event
{
	(void)event;
	self.hoverDigit = -1;
	self.hoverColumn = -1;
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
	[self updateHoverForEvent:event];
	if (self.hoverDigit < 0 || self.hoverDigit > 15) return;
	NSMenu *menu = self.enclosingMenuItem.menu;
	if (self.hoverColumn == 0) self.value = (self.hoverDigit << 4) | (self.value & 0x0F);
	else self.value = (self.pendingHighDigit << 4) | self.hoverDigit;
	[NSApp sendAction:self.action to:self.target from:self];
	[menu cancelTracking];
}

- (NSInteger)previewValue
{
	NSInteger high = MIN(MAX(self.pendingHighDigit, 0), 15);
	if (self.hoverDigit < 0 || self.hoverDigit > 15)
		return (high << 4) | (self.value & 0x0F);
	return self.hoverColumn == 0 ? (high << 4) | (self.value & 0x0F)
		: (high << 4) | self.hoverDigit;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	NSFont *font = [NSFont fontWithName:@"Monaco" size:10] ?:
		[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
	NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
	center.alignment = NSTextAlignmentCenter;
	for (NSInteger digit = 0; digit < 16; digit++) {
		CGFloat y = NSHeight(self.bounds) - (digit + 1) * PPHexPickerRowHeight;
		for (NSInteger column = 0; column < 2; column++) {
			NSRect cell = NSMakeRect(column * NSWidth(self.bounds) / 2.0, y,
				NSWidth(self.bounds) / 2.0, PPHexPickerRowHeight);
			BOOL hovered = digit == self.hoverDigit && column == self.hoverColumn;
			NSInteger selectedDigit = column == 0 ? self.pendingHighDigit : self.value & 0x0F;
			if (hovered) {
				[[NSColor colorWithCalibratedRed:0.16 green:0.16 blue:0.48 alpha:1.0] setFill];
				NSRectFill(cell);
			}
			NSColor *color = hovered ? NSColor.whiteColor : digit == selectedDigit
				? [NSColor colorWithCalibratedRed:0.9 green:0 blue:0 alpha:1.0] : NSColor.blackColor;
			NSString *text = [NSString stringWithFormat:@"%X", (unsigned int)digit];
			[text drawInRect:NSInsetRect(cell, 0, -1)
				withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color,
					NSParagraphStyleAttributeName: center}];
		}
	}
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMidX(self.bounds), PPHexPickerReadoutHeight)
		toPoint:NSMakePoint(NSMidX(self.bounds), NSMaxY(self.bounds))];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(self.bounds), PPHexPickerReadoutHeight + 0.5)
		toPoint:NSMakePoint(NSMaxX(self.bounds), PPHexPickerReadoutHeight + 0.5)];
	NSInteger value = [self previewValue];
	NSArray<NSString *> *readouts = @[[NSString stringWithFormat:@"%02lX", (long)value],
		[NSString stringWithFormat:@"%ld", (long)value],
		[NSString stringWithFormat:@"%d", (int)(int8_t)value]];
	for (NSInteger row = 0; row < 3; row++) {
		NSRect line = NSMakeRect(0, PPHexPickerReadoutHeight - (row + 1) * 13, NSWidth(self.bounds), 13);
		[readouts[row] drawInRect:NSInsetRect(line, 0, -1)
			withAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.blackColor,
				NSParagraphStyleAttributeName: center}];
	}
}
@end

@interface PPClassicIconButton : NSButton
@property(nonatomic) NSRect classicArtworkSourceRect;
@property(nonatomic) NSSize classicArtworkDisplaySize;
@end

@implementation PPClassicIconButton
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

	if (self.image != nil) {
		NSSize imageSize = self.image.size;
		NSRect source = NSMakeRect(0, 0, imageSize.width, imageSize.height);
		BOOL hasExplicitArtwork = NSWidth(self.classicArtworkSourceRect) > 0.0 &&
			NSHeight(self.classicArtworkSourceRect) > 0.0;
		if (hasExplicitArtwork) {
			source = self.classicArtworkSourceRect;
		} else {
			// Most original cicn exports have a two-pixel white canvas around the
			// actual artwork. Trim that canvas before fitting so the Digital toolbar
			// glyphs retain the same visual weight as the Classic Editor controls.
			CGFloat sourceInset = floor(MIN(imageSize.width, imageSize.height) * 0.10);
			if (sourceInset > 0 && NSWidth(source) > sourceInset * 2 &&
				NSHeight(source) > sourceInset * 2) source = NSInsetRect(source, sourceInset, sourceInset);
		}
		NSSize fitted = self.classicArtworkDisplaySize;
		if (fitted.width <= 0.0 || fitted.height <= 0.0) {
			CGFloat contentInset = MAX(floor(MIN(NSWidth(bounds), NSHeight(bounds)) * 0.10), 2.0);
			NSRect available = NSInsetRect(bounds, contentInset, contentInset);
			CGFloat scale = MIN(NSWidth(available) / NSWidth(source), NSHeight(available) / NSHeight(source));
			fitted = NSMakeSize(floor(NSWidth(source) * scale), floor(NSHeight(source) * scale));
		}
		NSRect destination = NSMakeRect(floor(NSMidX(bounds) - fitted.width / 2.0),
			floor(NSMidY(bounds) - fitted.height / 2.0), fitted.width, fitted.height);
		NSGraphicsContext *context = NSGraphicsContext.currentContext;
		NSImageInterpolation saved = context.imageInterpolation;
		context.imageInterpolation = NSImageInterpolationNone;
		// White was the classic icon canvas, not part of the glyph. Multiplication
		// lets the gray beveled face show through without damaging colored pixels.
		[self.image drawInRect:destination fromRect:source operation:NSCompositingOperationMultiply
			fraction:self.enabled ? 1.0 : 0.42 respectFlipped:YES hints:nil];
		context.imageInterpolation = saved;
		return;
	}

	NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.alignment = NSTextAlignmentCenter;
	NSDictionary *attributes = @{
		NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:10],
		NSForegroundColorAttributeName: self.enabled ? NSColor.blackColor :
			[NSColor colorWithCalibratedWhite:0.55 alpha:1.0],
		NSParagraphStyleAttributeName: paragraph
	};
	NSSize titleSize = [self.title sizeWithAttributes:attributes];
	[self.title drawInRect:NSMakeRect(NSMinX(bounds) + 2,
		floor(NSMidY(bounds) - titleSize.height / 2.0), NSWidth(bounds) - 4, titleSize.height)
		withAttributes:attributes];
}
@end

@interface PPClassicTransportPositionView : NSControl {
	double _classicDoubleValue;
}
@end

@implementation PPClassicTransportPositionView

- (void)setDoubleValue:(double)doubleValue
{
	_classicDoubleValue = MIN(MAX(doubleValue, 0.0), 1.0);
	[self setNeedsDisplay:YES];
}

- (double)doubleValue
{
	return _classicDoubleValue;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
	(void)event;
	return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	NSRect frame = NSInsetRect(self.bounds, 0.5, 0.5);
	[[NSColor colorWithCalibratedWhite:0.76 alpha:1.0] setFill];
	NSRectFill(frame);
	NSRect fill = NSInsetRect(frame, 2.0, 2.0);
	fill.size.width = floor(NSWidth(fill) * self.doubleValue);
	if (NSWidth(fill) > 0.0) {
		[[NSColor colorWithCalibratedRed:0.48 green:0.48 blue:0.82 alpha:1.0] setFill];
		NSRectFill(fill);
	}
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(frame, 1.0);
}

- (void)updateValueWithEvent:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	CGFloat width = MAX(NSWidth(self.bounds) - 4.0, 1.0);
	self.doubleValue = (point.x - 2.0) / width;
	[self sendAction:self.action to:self.target];
}

- (void)mouseDown:(NSEvent *)event
{
	[self updateValueWithEvent:event];
	while (true) {
		NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		if (next.type == NSEventTypeLeftMouseUp) break;
		[self updateValueWithEvent:next];
	}
}

@end

@interface PPClassicRowView : NSTableRowView
@property(nonatomic) BOOL markerBand;
@property(nonatomic) BOOL playbackRow;
@property(nonatomic) CGFloat patternContentWidth;
@property(nonatomic) BOOL drawsStepRule;
@end

@implementation PPClassicRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	NSRect patternBounds = self.bounds;
	if (self.patternContentWidth > 0.0) {
		[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
		NSRectFill(self.bounds);
		patternBounds.size.width = MIN(self.patternContentWidth, NSWidth(self.bounds));
	}
	NSColor *color = self.markerBand
		? [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:0.60 alpha:1.0]
		: NSColor.whiteColor;
	[color setFill];
	NSRectFill(patternBounds);
	if (self.playbackRow) {
		// The 2002 CurRect used the dialog gray with QuickDraw's adMin mode.
		// A neutral darken blend retains that characteristic on yellow bands.
		[[NSColor colorWithCalibratedWhite:0.82 alpha:1.0] setFill];
		NSRectFillUsingOperation(patternBounds, NSCompositingOperationDarken);
	}
	if (self.drawsStepRule) {
		NSBezierPath *stepRule = [NSBezierPath bezierPath];
		stepRule.lineWidth = 1.0;
		CGFloat dash[] = {1.0, 1.0};
		[stepRule setLineDash:dash count:2 phase:0.0];
		[stepRule moveToPoint:NSMakePoint(NSMinX(patternBounds), NSMaxY(patternBounds) - 0.5)];
		[stepRule lineToPoint:NSMakePoint(NSMaxX(patternBounds), NSMaxY(patternBounds) - 0.5)];
		[[NSColor colorWithCalibratedWhite:0.73 alpha:1.0] setStroke];
		[stepRule stroke];
	}
}

- (void)drawSelectionInRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedRed:0.28 green:0.52 blue:0.86 alpha:0.72] setFill];
	NSRect selectionBounds = self.bounds;
	if (self.patternContentWidth > 0.0) selectionBounds.size.width = MIN(self.patternContentWidth, NSWidth(self.bounds));
	NSRectFillUsingOperation(selectionBounds, NSCompositingOperationSourceOver);
}
@end

@interface PPPartitionRowView : NSTableRowView
@property(nonatomic) BOOL activePosition;
@end

@implementation PPPartitionRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
	if (self.activePosition) {
		[NSColor.redColor setFill];
		NSRectFill(NSMakeRect(0, 0, 6, NSHeight(self.bounds)));
	}
}

- (void)drawSelectionInRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedRed:0.77 green:0.75 blue:0.95 alpha:1.0] setFill];
	NSRectFill(NSMakeRect(6, 0, MAX(NSWidth(self.bounds) - 6, 0), NSHeight(self.bounds)));
	if (self.activePosition) {
		[NSColor.redColor setFill];
		NSRectFill(NSMakeRect(0, 0, 6, NSHeight(self.bounds)));
	}
}
@end

@interface PPPartitionHeaderCell : NSTableHeaderCell
@property(nonatomic) BOOL showsName;
@end

@implementation PPPartitionHeaderCell
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
	(void)controlView;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(cellFrame);
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(cellFrame), NSMinY(cellFrame) + 0.5)
		toPoint:NSMakePoint(NSMaxX(cellFrame), NSMinY(cellFrame) + 0.5)];

	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
	center.alignment = NSTextAlignmentCenter;
	NSDictionary *attributes = @{NSFontAttributeName: font,
		NSForegroundColorAttributeName: NSColor.blackColor,
		NSParagraphStyleAttributeName: center};
	CGFloat textY = floor(NSMidY(cellFrame) - font.capHeight / 2.0 - 2.0);
	[@"Pos" drawInRect:NSMakeRect(NSMinX(cellFrame) + 5.0, textY, 31.0, 13.0)
		withAttributes:attributes];
	[@"ID" drawInRect:NSMakeRect(NSMinX(cellFrame) + 47.0, textY, 20.0, 13.0)
		withAttributes:attributes];
	if (self.showsName) {
		NSMutableParagraphStyle *left = [center mutableCopy];
		left.alignment = NSTextAlignmentLeft;
		NSDictionary *nameAttributes = @{NSFontAttributeName: font,
			NSForegroundColorAttributeName: NSColor.blackColor,
			NSParagraphStyleAttributeName: left};
		[@"Name" drawInRect:NSMakeRect(NSMinX(cellFrame) + 73.0, textY,
			MAX(NSWidth(cellFrame) - 75.0, 0.0), 13.0) withAttributes:nameAttributes];
	}
}
@end

// NSTableHeaderView asks AppKit to paint the area beyond the final column.
// At the utility window's enforced minimum width that filler can render the
// first character of the table identifier (the persistent phantom "P"). Draw
// one complete, opaque classic header above the scroll view instead.
@interface PPPartitionHeaderOverlayView : NSView
@property(nonatomic) BOOL showsName;
@end

@implementation PPPartitionHeaderOverlayView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(self.bounds), NSMinY(self.bounds) + 0.5)
		toPoint:NSMakePoint(NSMaxX(self.bounds), NSMinY(self.bounds) + 0.5)];

	NSFont *font = [NSFont fontWithName:@"Monaco" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
	NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
	center.alignment = NSTextAlignmentCenter;
	NSDictionary *attributes = @{NSFontAttributeName: font,
		NSForegroundColorAttributeName: NSColor.blackColor,
		NSParagraphStyleAttributeName: center};
	CGFloat textY = floor(NSMidY(self.bounds) - font.capHeight / 2.0 - 2.0);
	[@"Pos" drawInRect:NSMakeRect(5.0, textY, 31.0, 13.0) withAttributes:attributes];
	[@"ID" drawInRect:NSMakeRect(47.0, textY, 20.0, 13.0) withAttributes:attributes];
	if (self.showsName) {
		NSMutableParagraphStyle *left = [center mutableCopy];
		left.alignment = NSTextAlignmentLeft;
		[@"Name" drawInRect:NSMakeRect(73.0, textY, MAX(NSWidth(self.bounds) - 75.0, 0.0), 13.0)
			withAttributes:@{NSFontAttributeName: font,
				NSForegroundColorAttributeName: NSColor.blackColor,
				NSParagraphStyleAttributeName: left}];
	}
}
@end

@interface PPPartitionPatternPopUpButton : NSPopUpButton
@end

@implementation PPPartitionPatternPopUpButton
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	// PICT 140 was a tiny square containing a down arrow, repeated once per
	// partition row.  Drawing that face while retaining NSPopUpButton tracking
	// gives us the original hit target and the modern menu implementation.
	NSRect face = NSMakeRect(floor(NSMidX(self.bounds) - 5.0),
		floor(NSMidY(self.bounds) - 4.0), 10.0, 8.0);
	[NSColor.whiteColor setFill];
	NSRectFill(face);
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(face, 1.0);
	NSBezierPath *arrow = [NSBezierPath bezierPath];
	// Control views are flipped: the larger y coordinate is visually lower.
	[arrow moveToPoint:NSMakePoint(NSMidX(face) - 2.5, NSMidY(face) - 1.0)];
	[arrow lineToPoint:NSMakePoint(NSMidX(face) + 2.5, NSMidY(face) - 1.0)];
	[arrow lineToPoint:NSMakePoint(NSMidX(face), NSMidY(face) + 2.0)];
	[arrow closePath];
	[NSColor.blackColor setFill];
	[arrow fill];
}
@end

@interface PPPartitionWidthToggleButton : NSButton
@property(nonatomic) BOOL partitionExpanded;
@end

@implementation PPPartitionWidthToggleButton
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	NSRect bounds = NSInsetRect(self.bounds, 3.0, 4.0);
	NSBezierPath *triangle = [NSBezierPath bezierPath];
	if (!self.partitionExpanded) {
		[triangle moveToPoint:NSMakePoint(NSMinX(bounds) + 1.0, NSMinY(bounds) + 1.0)];
		[triangle lineToPoint:NSMakePoint(NSMaxX(bounds) - 1.0, NSMinY(bounds) + 1.0)];
		[triangle lineToPoint:NSMakePoint(NSMidX(bounds), NSMaxY(bounds) - 1.0)];
	} else {
		[triangle moveToPoint:NSMakePoint(NSMinX(bounds) + 1.0, NSMaxY(bounds) - 1.0)];
		[triangle lineToPoint:NSMakePoint(NSMaxX(bounds) - 1.0, NSMaxY(bounds) - 1.0)];
		[triangle lineToPoint:NSMakePoint(NSMidX(bounds), NSMinY(bounds) + 1.0)];
	}
	[triangle closePath];
	[[NSColor colorWithCalibratedRed:0.20 green:0.30 blue:0.82 alpha:1.0] setFill];
	[triangle fill];
	[NSColor.blackColor setStroke];
	[triangle stroke];
}
@end

@interface PPClassicGrowBoxView : NSView
@end

@implementation PPClassicGrowBoxView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	[NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(self.bounds) + 0.5, NSMinY(self.bounds))
		toPoint:NSMakePoint(NSMinX(self.bounds) + 0.5, NSMaxY(self.bounds))];
}
@end

@interface PPClassicListRowView : NSTableRowView
@end

@implementation PPClassicListRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[NSColor.whiteColor setFill];
	NSRectFill(self.bounds);
}

- (void)drawSelectionInRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	// The list windows used a pale lavender selection instead of the
	// system accent color.  Keeping it opaque also leaves black text legible.
	[[NSColor colorWithCalibratedRed:0.77 green:0.75 blue:0.95 alpha:1.0] setFill];
	NSRectFill(self.bounds);
}
@end

@interface PPMusicListTableView : NSTableView
@end

@implementation PPMusicListTableView
- (void)keyDown:(NSEvent *)event
{
	if (event.keyCode == 51 || event.keyCode == 117) {
		[NSApp sendAction:@selector(removeMusicListEntries:) to:nil from:self];
		return;
	}
	if (event.keyCode == 36 || event.keyCode == 76) {
		[NSApp sendAction:@selector(loadSelectedMusicListEntry:) to:nil from:self];
		return;
	}
	[super keyDown:event];
}

- (void)delete:(id)sender
{
	[NSApp sendAction:@selector(removeMusicListEntries:) to:nil from:sender];
}
@end

@interface PPPianoKeyMapTableView : NSTableView <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *keyMap;
@property(nonatomic, copy) void (^keyMapChangedHandler)(NSArray<NSString *> *keyMap);
- (void)replaceKeyMap:(NSArray<NSString *> *)keyMap;
@end

@implementation PPPianoKeyMapTableView

- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (self) {
		self.dataSource = self;
		self.delegate = self;
		self.headerView = nil;
		self.rowHeight = 17;
		self.intercellSpacing = NSMakeSize(0, 0);
		self.backgroundColor = NSColor.whiteColor;
		self.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
		self.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
		NSTableColumn *noteColumn = [[NSTableColumn alloc] initWithIdentifier:@"note"];
		noteColumn.width = 61;
		noteColumn.minWidth = 61;
		noteColumn.maxWidth = 61;
		[self addTableColumn:noteColumn];
		NSTableColumn *keyColumn = [[NSTableColumn alloc] initWithIdentifier:@"key"];
		keyColumn.width = 31;
		keyColumn.minWidth = 31;
		keyColumn.maxWidth = 31;
		[self addTableColumn:keyColumn];
		[self replaceKeyMap:PPDefaultPianoKeyMap()];
	}
	return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)replaceKeyMap:(NSArray<NSString *> *)keyMap
{
	NSArray<NSString *> *source = keyMap.count == NUMBER_NOTES ? keyMap : PPDefaultPianoKeyMap();
	self.keyMap = [source mutableCopy];
	[self reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	(void)tableView;
	return NUMBER_NOTES;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn
	row:(NSInteger)row
{
	NSTextField *field = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
	if (field == nil) {
		field = [NSTextField labelWithString:@""];
		field.identifier = tableColumn.identifier;
		field.font = [NSFont fontWithName:@"Monaco" size:9] ?:
			[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
		field.textColor = NSColor.blackColor;
		field.backgroundColor = NSColor.clearColor;
		field.alignment = [tableColumn.identifier isEqualToString:@"key"]
			? NSTextAlignmentCenter : NSTextAlignmentLeft;
	}
	if ([tableColumn.identifier isEqualToString:@"key"]) {
		field.stringValue = row >= 0 && row < (NSInteger)self.keyMap.count
			? self.keyMap[(NSUInteger)row] : @"";
	} else {
		static NSArray<NSString *> *pitchNames;
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^{
			pitchNames = @[@"C ", @"C#", @"D ", @"D#", @"E ", @"F ",
				@"F#", @"G ", @"G#", @"A ", @"A#", @"B "];
		});
		field.stringValue = [NSString stringWithFormat:@"%@%ld",
			pitchNames[(NSUInteger)row % 12], (long)row / 12];
	}
	return field;
}

- (void)keyDown:(NSEvent *)event
{
	NSInteger row = self.selectedRow;
	if (row < 0 || row >= NUMBER_NOTES ||
		(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
			NSEventModifierFlagOption)) != 0) {
		[super keyDown:event];
		return;
	}
	NSString *characters = event.characters;
	unichar character = characters.length == 1 ? [characters characterAtIndex:0] : 0;
	if (character == NSDeleteCharacter || character == NSBackspaceCharacter) {
		self.keyMap[(NSUInteger)row] = @"";
	} else if (characters.length == 1 && character > 0x20 && character < 0x7F) {
		// The original PianoKey table is a one-to-one map. Moving a key to a
		// new note first clears its old assignment, so duplicate triggers are
		// never possible.
		for (NSInteger note = 0; note < (NSInteger)self.keyMap.count; note++) {
			if ([self.keyMap[(NSUInteger)note] isEqualToString:characters]) {
				self.keyMap[(NSUInteger)note] = @"";
			}
		}
		self.keyMap[(NSUInteger)row] = characters;
	} else {
		[super keyDown:event];
		return;
	}
	[self reloadData];
	[self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	if (self.keyMapChangedHandler != nil) self.keyMapChangedHandler(self.keyMap.copy);
}

@end

@interface PPPartitionCellView : NSTableCellView
@property(nonatomic, strong) NSTextField *positionField;
@property(nonatomic, strong) NSPopUpButton *patternPopup;
@property(nonatomic, strong) NSTextField *patternField;
@property(nonatomic, strong) NSTextField *nameField;
@end

@implementation PPPartitionCellView
- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (self != nil) {
		_positionField = [NSTextField labelWithString:@""];
		_positionField.alignment = NSTextAlignmentRight;
		[self addSubview:_positionField];
		_patternPopup = [[PPPartitionPatternPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
		_patternPopup.controlSize = NSControlSizeMini;
		_patternPopup.bordered = NO;
		_patternPopup.refusesFirstResponder = YES;
		_patternPopup.focusRingType = NSFocusRingTypeNone;
		[self addSubview:_patternPopup];
		_patternField = [NSTextField labelWithString:@""];
		_patternField.alignment = NSTextAlignmentRight;
		[self addSubview:_patternField];
		_nameField = [NSTextField labelWithString:@""];
		_nameField.alignment = NSTextAlignmentLeft;
		_nameField.lineBreakMode = NSLineBreakByClipping;
		[self addSubview:_nameField];
	}
	return self;
}

- (void)layout
{
	[super layout];
	// Leave a full eight-point safety margin before the legacy vertical
	// scroller. NSTextField's internal trailing padding otherwise hides the ID
	// digit at the original 94-point compact width.
	self.positionField.frame = NSMakeRect(5, 0, 29, NSHeight(self.bounds));
	self.patternPopup.frame = NSMakeRect(35, 0, 14, NSHeight(self.bounds));
	self.patternField.frame = NSMakeRect(48, 0, 19, NSHeight(self.bounds));
	self.nameField.frame = NSMakeRect(73, 0, MAX(NSWidth(self.bounds) - 75, 0), NSHeight(self.bounds));
}
@end

@interface PPInstrumentListCellView : NSTableCellView
@property(nonatomic, strong) NSButton *disclosureButton;
@property(nonatomic, strong) NSButton *previewButton;
@end

@implementation PPInstrumentListCellView
- (instancetype)initWithFrame:(NSRect)frameRect
{
	self = [super initWithFrame:frameRect];
	if (self != nil) {
		_disclosureButton = [NSButton buttonWithTitle:@"" target:nil action:nil];
		_disclosureButton.bordered = NO;
		_disclosureButton.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
		_disclosureButton.focusRingType = NSFocusRingTypeNone;
		_disclosureButton.refusesFirstResponder = YES;
		[self addSubview:_disclosureButton];

		_previewButton = [NSButton buttonWithTitle:@"" target:nil action:nil];
		_previewButton.bordered = NO;
		_previewButton.imagePosition = NSImageOnly;
		_previewButton.imageScaling = NSImageScaleProportionallyDown;
		_previewButton.focusRingType = NSFocusRingTypeNone;
		_previewButton.refusesFirstResponder = YES;
		[self addSubview:_previewButton];

		NSTextField *field = [NSTextField textFieldWithString:@""];
		field.bordered = NO;
		field.bezeled = NO;
		field.drawsBackground = NO;
		field.textColor = NSColor.blackColor;
		field.lineBreakMode = NSLineBreakByClipping;
		field.focusRingType = NSFocusRingTypeNone;
		self.textField = field;
		[self addSubview:field];
	}
	return self;
}

- (void)layout
{
	[super layout];
	CGFloat height = NSHeight(self.bounds);
	self.disclosureButton.frame = NSMakeRect(0, 0, 18, height);
	self.previewButton.frame = NSMakeRect(18, 0, 20, height);
	CGFloat textX = self.previewButton.hidden ? 19.0 : 40.0;
	self.textField.frame = NSMakeRect(textX, 0, MAX(NSWidth(self.bounds) - textX - 2.0, 0), height);
}
@end

@interface PPInstrumentDetailView : NSView
@end

@implementation PPInstrumentDetailView
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.86 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	[NSColor.blackColor setStroke];
	NSBezierPath *rules = [NSBezierPath bezierPath];
	rules.lineWidth = 1.0;
	[rules moveToPoint:NSMakePoint(0.5, NSMinY(self.bounds))];
	[rules lineToPoint:NSMakePoint(0.5, NSMaxY(self.bounds))];
	[rules moveToPoint:NSMakePoint(NSMinX(self.bounds), 49.5)];
	[rules lineToPoint:NSMakePoint(NSMaxX(self.bounds), 49.5)];
	[rules stroke];
}
@end

@interface PPInstrumentInspectorToggleButton : NSButton
@property(nonatomic) BOOL inspectorExpanded;
@end

@implementation PPInstrumentInspectorToggleButton
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	NSRect bounds = NSInsetRect(self.bounds, 3.0, 4.0);
	NSBezierPath *triangle = [NSBezierPath bezierPath];
	if (self.inspectorExpanded) {
		[triangle moveToPoint:NSMakePoint(NSMinX(bounds) + 1.0, NSMidY(bounds))];
		[triangle lineToPoint:NSMakePoint(NSMaxX(bounds) - 1.0, NSMinY(bounds) + 1.0)];
		[triangle lineToPoint:NSMakePoint(NSMaxX(bounds) - 1.0, NSMaxY(bounds) - 1.0)];
	} else {
		[triangle moveToPoint:NSMakePoint(NSMaxX(bounds) - 1.0, NSMidY(bounds))];
		[triangle lineToPoint:NSMakePoint(NSMinX(bounds) + 1.0, NSMinY(bounds) + 1.0)];
		[triangle lineToPoint:NSMakePoint(NSMinX(bounds) + 1.0, NSMaxY(bounds) - 1.0)];
	}
	[triangle closePath];
	[[NSColor colorWithCalibratedRed:0.20 green:0.30 blue:0.82 alpha:1.0] setFill];
	[triangle fill];
	[NSColor.blackColor setStroke];
	[triangle stroke];
}
@end

@interface PPClassicHeaderCell : NSTableHeaderCell
@property(nonatomic, strong) NSColor *classicColor;
@end

@implementation PPClassicHeaderCell
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
	[(self.classicColor ?: NSColor.controlBackgroundColor) setFill];
	NSRectFill(cellFrame);
	[NSColor.blackColor setStroke];
	NSFrameRect(cellFrame);
	NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
	style.alignment = NSTextAlignmentCenter;
	NSDictionary *attributes = @{
		NSFontAttributeName: [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
		NSForegroundColorAttributeName: NSColor.blackColor,
		NSParagraphStyleAttributeName: style
	};
	[self.stringValue drawInRect:NSInsetRect(cellFrame, 1, 0) withAttributes:attributes];
	(void)controlView;
}
@end

@interface PPPatternCommandCellView : NSTextField
@property(nonatomic) BOOL drawsPatternGuides;
@property(nonatomic) BOOL drawsRightTrackBorder;
@property(nonatomic) BOOL patternSelected;
@property(nonatomic) BOOL patternCursor;
@property(nonatomic) NSInteger patternField;
@end

@implementation PPPatternCommandCellView
- (void)drawRect:(NSRect)dirtyRect
{
	[super drawRect:dirtyRect];
	if (!self.drawsPatternGuides) return;

	// PlayerPRO 2002 allocated 4/4/2/3/3 character cells and drew its field
	// rules exactly at those boundaries. The command itself begins four pixels
	// inside the track; the separating blank character straddles each rule.
	CGFloat characterWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName:
		self.font ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular]}].width;
	CGFloat boundaries[] = {4.0, 8.0, 10.0, 13.0};
	NSBezierPath *guides = [NSBezierPath bezierPath];
	guides.lineWidth = 1.0;
	CGFloat dash[] = {1.0, 1.0};
	[guides setLineDash:dash count:2 phase:0.0];
	for (NSUInteger index = 0; index < sizeof(boundaries) / sizeof(boundaries[0]); index++) {
		CGFloat x = floor(boundaries[index] * characterWidth) + 0.5;
		[guides moveToPoint:NSMakePoint(x, NSMinY(self.bounds))];
		[guides lineToPoint:NSMakePoint(x, NSMaxY(self.bounds))];
	}
	[[NSColor colorWithCalibratedWhite:(34952.0 / 65535.0) alpha:1.0] setStroke];
	[guides stroke];
	[NSColor.blackColor setStroke];
	NSBezierPath *trackRule = [NSBezierPath bezierPath];
	trackRule.lineWidth = 1.0;
	[trackRule moveToPoint:NSMakePoint(0.5, NSMinY(self.bounds))];
	[trackRule lineToPoint:NSMakePoint(0.5, NSMaxY(self.bounds))];
	if (self.drawsRightTrackBorder) {
		CGFloat right = NSMaxX(self.bounds) - 0.5;
		[trackRule moveToPoint:NSMakePoint(right, NSMinY(self.bounds))];
		[trackRule lineToPoint:NSMakePoint(right, NSMaxY(self.bounds))];
	}
	[trackRule stroke];

	if (self.patternSelected) {
		// QuickDraw's original column selection was a pale lavender. Darken
		// preserves that lavender on white rows and produces the characteristic
		// muted olive where it crosses a yellow four-row band.
		[[NSColor colorWithCalibratedRed:0.77 green:0.77 blue:1.0 alpha:1.0] setFill];
		NSRectFillUsingOperation(self.bounds, NSCompositingOperationDarken);
	}

	// The original Digital editor framed the active subfield in red on top of
	// the blue selection tint. Keep that cursor visible even when the command
	// itself consists entirely of blank fields.
	if (self.patternCursor) {
		static const CGFloat starts[] = {0.0, 4.0, 8.0, 10.0, 13.0};
		static const CGFloat widths[] = {4.0, 4.0, 2.0, 3.0, 3.0};
		NSInteger field = MIN(MAX(self.patternField, 0), 4);
		NSRect cursorRect = NSMakeRect(floor(starts[field] * characterWidth) + 0.5,
			0.5, ceil(widths[field] * characterWidth), MAX(NSHeight(self.bounds) - 1.0, 1.0));
		cursorRect = NSIntersectionRect(cursorRect, NSInsetRect(self.bounds, 0.5, 0.5));
		[NSColor.redColor setStroke];
		NSFrameRectWithWidth(cursorRect, 1.0);
	}
}
@end

@interface PPOscilloscopeView : NSView
@property(nonatomic, copy) NSData *pcmData;
@property(nonatomic) NSInteger sampleBits;
@property(nonatomic) NSInteger channelCount;
@property(nonatomic) NSInteger analysisSize;
@property(nonatomic) BOOL drawsConnectedLines;
@end

@implementation PPOscilloscopeView

- (BOOL)isFlipped { return YES; }

- (CGFloat)normalizedSampleAtFrame:(NSUInteger)frame channel:(NSInteger)channel
{
	NSInteger channels = MAX(self.channelCount, 1);
	NSUInteger index = frame * (NSUInteger)channels + (NSUInteger)MIN(MAX(channel, 0), channels - 1);
	if (self.sampleBits == 8) {
		if (index >= self.pcmData.length) return 0.0;
		return ((const uint8_t *)self.pcmData.bytes)[index] / 127.5 - 1.0;
	}
	NSUInteger offset = index * sizeof(int16_t);
	if (offset + sizeof(int16_t) > self.pcmData.length) return 0.0;
	int16_t sample = 0;
	memcpy(&sample, (const uint8_t *)self.pcmData.bytes + offset, sizeof(sample));
	return (CGFloat)sample / 32768.0;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.78 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	NSInteger channels = MIN(MAX(self.channelCount, 1), 2);
	NSInteger bytesPerSample = self.sampleBits == 8 ? 1 : 2;
	NSInteger sourceChannels = MAX(self.channelCount, 1);
	NSUInteger frames = self.pcmData.length / (NSUInteger)(bytesPerSample * sourceChannels);
	NSUInteger displayedFrames = MIN(frames, (NSUInteger)MAX(self.analysisSize, 8) * 8);
	NSUInteger firstFrame = frames > displayedFrames ? frames - displayedFrames : 0;
	NSColor *guideColor = [NSColor colorWithCalibratedRed:0.0 green:0.62 blue:0.05 alpha:1.0];
	NSColor *waveColor = [NSColor colorWithCalibratedRed:0.0 green:0.86 blue:0.88 alpha:1.0];
	NSDictionary *labelAttributes = @{
		NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
		NSForegroundColorAttributeName: NSColor.blackColor
	};
	NSRect plot = NSMakeRect(0, 0, NSWidth(self.bounds), MAX(NSHeight(self.bounds) - 18, 1));
	NSRect label = NSMakeRect(0, NSMaxY(plot), NSWidth(self.bounds), 18);
	[NSColor.blackColor setFill];
	NSRectFill(plot);
	NSBezierPath *grid = [NSBezierPath bezierPath];
	grid.lineWidth = 1.0;
	CGFloat middle = NSMidY(plot);
	[grid moveToPoint:NSMakePoint(NSMinX(plot), floor(middle) + 0.5)];
	[grid lineToPoint:NSMakePoint(NSMaxX(plot), floor(middle) + 0.5)];
	for (NSInteger division = 0; division <= 4; division++) {
		CGFloat x = floor(NSWidth(plot) * division / 4.0) + 0.5;
		[grid moveToPoint:NSMakePoint(x, NSMinY(plot))];
		[grid lineToPoint:NSMakePoint(x, NSMaxY(plot))];
	}
	[guideColor setStroke];
	[grid stroke];
	for (NSInteger channel = 0; channel < channels; channel++) {
		if (displayedFrames > 1 && NSWidth(plot) > 1) {
			CGFloat amplitude = MAX(NSHeight(plot) / 2.0 - 4.0, 1.0);
			NSBezierPath *wave = [NSBezierPath bezierPath];
			wave.lineWidth = 1.0;
			NSUInteger columns = MAX((NSUInteger)floor(NSWidth(plot)), 2);
			for (NSUInteger x = 0; x < columns; x++) {
				NSUInteger frame = firstFrame + MIN((x * displayedFrames) / columns, displayedFrames - 1);
				CGFloat y = middle - [self normalizedSampleAtFrame:frame channel:channel] * amplitude;
				if (self.drawsConnectedLines) {
					if (x == 0) [wave moveToPoint:NSMakePoint(0, y)];
					else [wave lineToPoint:NSMakePoint((CGFloat)x, y)];
				} else {
					[wave appendBezierPathWithRect:NSMakeRect((CGFloat)x, floor(y), 1.0, 1.0)];
				}
			}
			if (self.drawsConnectedLines) {
				[waveColor setStroke];
				[wave stroke];
			} else {
				[waveColor setFill];
				[wave fill];
			}
		}
	}
	[[NSColor colorWithCalibratedWhite:0.82 alpha:1.0] setFill];
	NSRectFill(label);
	NSString *channelLabel = channels == 2 ? @"Left/Right Channels (2)" : @"Mono Channel (1)";
	NSString *status = [NSString stringWithFormat:@"Audio Output: %@   Buffer Size: %lu bytes",
		channelLabel, (unsigned long)self.pcmData.length];
	[status drawInRect:NSInsetRect(label, 5, 2) withAttributes:labelAttributes];
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(NSInsetRect(self.bounds, 0.5, 0.5), 1.0);
}
@end

@interface PPSpectrumView : NSView
@property(nonatomic, copy) NSData *pcmData;
@property(nonatomic) NSInteger sampleBits;
@property(nonatomic) NSInteger channelCount;
@property(nonatomic) NSInteger analysisSize;
@property(nonatomic) NSUInteger sampleRate;
@property(nonatomic) BOOL logarithmicScale;
@property(nonatomic) CGFloat cursorFraction;
@end

@implementation PPSpectrumView

- (BOOL)isFlipped { return YES; }

- (void)updateCursorWithEvent:(NSEvent *)event
{
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	self.cursorFraction = MIN(MAX(point.x / MAX(NSWidth(self.bounds), 1.0), 0.0), 1.0);
	[self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event { [self updateCursorWithEvent:event]; }
- (void)mouseDragged:(NSEvent *)event { [self updateCursorWithEvent:event]; }

- (double)normalizedSampleAtFrame:(NSUInteger)frame channel:(NSInteger)channel
{
	NSInteger channels = MAX(self.channelCount, 1);
	NSUInteger index = frame * (NSUInteger)channels + (NSUInteger)MIN(MAX(channel, 0), channels - 1);
	if (self.sampleBits == 8) {
		if (index >= self.pcmData.length) return 0.0;
		return ((const uint8_t *)self.pcmData.bytes)[index] / 127.5 - 1.0;
	}
	NSUInteger offset = index * sizeof(int16_t);
	if (offset + sizeof(int16_t) > self.pcmData.length) return 0.0;
	int16_t sample = 0;
	memcpy(&sample, (const uint8_t *)self.pcmData.bytes + offset, sizeof(sample));
	return (double)sample / 32768.0;
}

- (void)transformReal:(double *)real imaginary:(double *)imaginary length:(NSUInteger)length
{
	for (NSUInteger index = 1, reversed = 0; index < length; index++) {
		NSUInteger bit = length >> 1;
		while ((reversed & bit) != 0) { reversed ^= bit; bit >>= 1; }
		reversed ^= bit;
		if (index < reversed) {
			double swap = real[index]; real[index] = real[reversed]; real[reversed] = swap;
			swap = imaginary[index]; imaginary[index] = imaginary[reversed]; imaginary[reversed] = swap;
		}
	}
	for (NSUInteger span = 2; span <= length; span <<= 1) {
		double angle = -2.0 * M_PI / (double)span;
		double stepReal = cos(angle);
		double stepImaginary = sin(angle);
		for (NSUInteger base = 0; base < length; base += span) {
			double weightReal = 1.0;
			double weightImaginary = 0.0;
			for (NSUInteger offset = 0; offset < span / 2; offset++) {
				NSUInteger even = base + offset;
				NSUInteger odd = even + span / 2;
				double oddReal = real[odd] * weightReal - imaginary[odd] * weightImaginary;
				double oddImaginary = real[odd] * weightImaginary + imaginary[odd] * weightReal;
				real[odd] = real[even] - oddReal;
				imaginary[odd] = imaginary[even] - oddImaginary;
				real[even] += oddReal;
				imaginary[even] += oddImaginary;
				double nextReal = weightReal * stepReal - weightImaginary * stepImaginary;
				weightImaginary = weightReal * stepImaginary + weightImaginary * stepReal;
				weightReal = nextReal;
			}
		}
	}
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor colorWithCalibratedWhite:0.78 alpha:1.0] setFill];
	NSRectFill(self.bounds);
	NSInteger channels = MIN(MAX(self.channelCount, 1), 2);
	NSInteger bytesPerSample = self.sampleBits == 8 ? 1 : 2;
	NSInteger sourceChannels = MAX(self.channelCount, 1);
	NSUInteger frames = self.pcmData.length / (NSUInteger)(bytesPerSample * sourceChannels);
	NSUInteger requested = MIN(frames, (NSUInteger)MAX(self.analysisSize, 8) * 8);
	NSUInteger transformLength = 1;
	while ((transformLength << 1) <= requested && transformLength < 4096) transformLength <<= 1;
	if (transformLength < 8) transformLength = 0;
	NSUInteger firstFrame = frames > transformLength ? frames - transformLength : 0;
	NSColor *barColor = [NSColor colorWithCalibratedRed:0.0 green:0.86 blue:0.88 alpha:1.0];
	NSDictionary *labelAttributes = @{
		NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
		NSForegroundColorAttributeName: NSColor.blackColor
	};
	NSRect plot = NSMakeRect(0, 0, NSWidth(self.bounds), MAX(NSHeight(self.bounds) - 18, 1));
	NSRect label = NSMakeRect(0, NSMaxY(plot), NSWidth(self.bounds), 18);
	[NSColor.blackColor setFill];
	NSRectFill(plot);
	double displayedFrequency = 0.0;
	if (transformLength > 0 && NSWidth(plot) > 2) {
		double *real = calloc(transformLength, sizeof(double));
		double *imaginary = calloc(transformLength, sizeof(double));
		NSUInteger limit = transformLength / 2;
		double *magnitudes = calloc(limit, sizeof(double));
		if (real != NULL && imaginary != NULL && magnitudes != NULL) {
			// Combine the channels in the display, not in the time-domain signal:
			// retaining the strongest magnitude prevents opposite-phase stereo
			// material from disappearing from the shared spectrum.
			for (NSInteger channel = 0; channel < channels; channel++) {
				memset(real, 0, transformLength * sizeof(double));
				memset(imaginary, 0, transformLength * sizeof(double));
				for (NSUInteger index = 0; index < transformLength; index++) {
					double window = 0.5 - 0.5 * cos((2.0 * M_PI * index) / (double)(transformLength - 1));
					real[index] = [self normalizedSampleAtFrame:firstFrame + index channel:channel] * window;
				}
				[self transformReal:real imaginary:imaginary length:transformLength];
				for (NSUInteger bin = 1; bin < limit; bin++) {
					magnitudes[bin] = MAX(magnitudes[bin], hypot(real[bin], imaginary[bin]));
				}
			}
			NSUInteger peakBin = 0;
			double peakMagnitude = 0.0;
			for (NSUInteger bin = 1; bin < limit; bin++) {
				double magnitude = magnitudes[bin];
				if (magnitude > peakMagnitude) { peakMagnitude = magnitude; peakBin = bin; }
			}
			NSUInteger bars = MAX((NSUInteger)floor(NSWidth(plot) / 2.0), 1);
			double rate = self.sampleRate > 0 ? self.sampleRate : 44100.0;
			double minimumFrequency = MAX(rate / transformLength, 20.0);
			double maximumFrequency = rate / 2.0;
			[barColor setFill];
			for (NSUInteger bar = 0; bar < bars; bar++) {
				double fraction = bars > 1 ? (double)bar / (double)(bars - 1) : 0.0;
				double frequency = self.logarithmicScale
					? minimumFrequency * pow(maximumFrequency / minimumFrequency, fraction)
					: maximumFrequency * fraction;
				NSUInteger bin = MIN((NSUInteger)llround(frequency * transformLength / rate), limit - 1);
				double magnitude = magnitudes[bin] * 2.0 / transformLength;
				double decibels = 20.0 * log10(MAX(magnitude, 0.000001));
				double level = MIN(MAX((decibels + 72.0) / 72.0, 0.0), 1.0);
				CGFloat height = floor(level * MAX(NSHeight(plot) - 4.0, 1.0));
				NSRectFill(NSMakeRect(bar * 2.0, NSMaxY(plot) - height, 1.0, height));
			}
			displayedFrequency = peakBin * rate / transformLength;
			if (self.cursorFraction >= 0.0) {
				displayedFrequency = self.logarithmicScale
					? minimumFrequency * pow(maximumFrequency / minimumFrequency, self.cursorFraction)
					: maximumFrequency * self.cursorFraction;
				CGFloat cursorX = floor(NSWidth(plot) * self.cursorFraction) + 0.5;
				[[NSColor colorWithCalibratedRed:0.88 green:0.0 blue:0.0 alpha:1.0] setStroke];
				[NSBezierPath strokeLineFromPoint:NSMakePoint(cursorX, NSMinY(plot))
					toPoint:NSMakePoint(cursorX, NSMaxY(plot))];
			}
		}
		free(real);
		free(imaginary);
		free(magnitudes);
	}
	[[NSColor colorWithCalibratedWhite:0.82 alpha:1.0] setFill];
	NSRectFill(label);
	NSString *channelLabel = channels == 2 ? @"Left/Right Channels (2)" : @"Mono Channel (1)";
	NSString *status = [NSString stringWithFormat:@"Audio Output: %@   Frequency: %.2f Hertz",
		channelLabel, displayedFrequency];
	[status drawInRect:NSInsetRect(label, 5, 2) withAttributes:labelAttributes];
	[NSColor.blackColor setStroke];
	NSFrameRectWithWidth(NSInsetRect(self.bounds, 0.5, 0.5), 1.0);
}
@end

@interface PPApplicationController () <PPPatternTableCommandDelegate, NSWindowDelegate, NSMenuDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSPanel *toolsWindow;
@property(nonatomic, strong) NSPanel *musicListWindow;
@property(nonatomic, strong) NSPanel *patternsWindow;
@property(nonatomic, strong) NSPanel *partitionWindow;
@property(nonatomic, strong) NSPanel *instrumentsWindow;
@property(nonatomic, strong) PPPatternTableView *patternTable;
@property(nonatomic, strong) NSTableView *orderTable;
@property(nonatomic, strong) NSTableView *partitionTable;
@property(nonatomic, strong) NSTableView *instrumentTable;
@property(nonatomic, strong) NSScrollView *instrumentScrollView;
@property(nonatomic, strong) NSMutableIndexSet *collapsedInstrumentIndexes;
@property(nonatomic, strong) PPMusicListTableView *musicListTable;
@property(nonatomic, strong) NSTextField *musicListSummaryField;
@property(nonatomic, strong) NSMutableArray<NSURL *> *musicListEntries;
@property(nonatomic, strong) NSURL *musicListURL;
@property(nonatomic) NSInteger musicListActiveIndex;
@property(nonatomic) NSInteger musicListPlaybackMode;
@property(nonatomic, strong) NSPopUpButton *musicListPlaybackPopup;
@property(nonatomic) BOOL musicListHandledEnd;
@property(nonatomic, strong) NSTextField *partitionLengthField;
@property(nonatomic, strong) PPPartitionWidthToggleButton *partitionWidthButton;
@property(nonatomic, strong) PPPartitionHeaderOverlayView *partitionHeaderOverlay;
@property(nonatomic) BOOL partitionInspectorExpanded;
@property(nonatomic, strong) NSTextField *instrumentSummaryField;
@property(nonatomic, strong) PPInstrumentDetailView *instrumentDetailView;
@property(nonatomic, strong) PPInstrumentInspectorToggleButton *instrumentInspectorButton;
@property(nonatomic, strong) NSArray<NSTextField *> *instrumentDetailValues;
@property(nonatomic) BOOL instrumentInspectorExpanded;
@property(nonatomic, strong) NSMutableArray<PPSampleEditorController *> *sampleEditors;
@property(nonatomic, strong) NSMutableArray<PPInstrumentEditorController *> *instrumentEditors;
@property(nonatomic, strong) NSMutableArray<PPPatternModeController *> *patternModeEditors;
@property(nonatomic, strong) NSData *rawPreviewData;
@property(nonatomic, strong) PPMixerController *mixerController;
@property(nonatomic, strong) PPPianoController *pianoController;
@property(nonatomic, strong) PPEqualizerController *equalizerController;
@property(nonatomic, strong) NSPanel *oscilloscopeWindow;
@property(nonatomic, strong) PPOscilloscopeView *oscilloscopeView;
@property(nonatomic, strong) NSPanel *spectrumWindow;
@property(nonatomic, strong) PPSpectrumView *spectrumView;
@property(nonatomic, strong) NSPanel *generalInformationPanel;
@property(nonatomic, strong) NSPanel *preferencesPanel;
@property(nonatomic, strong) NSPopUpButton *preferencesCategoryPopup;
@property(nonatomic, strong) NSView *preferencesPane;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *preferenceDraft;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *preferenceValueFields;
@property(nonatomic, strong) NSPopUpButton *generalTracksPopup;
@property(nonatomic, strong) NSTextField *generalNameField;
@property(nonatomic, strong) NSTextField *generalTempoField;
@property(nonatomic, strong) NSTextField *generalSpeedField;
@property(nonatomic, strong) NSTextView *generalCopyrightTextView;
@property(nonatomic, strong) NSButton *generalShowCopyrightButton;
@property(nonatomic, strong) NSButton *generalMODModeButton;
@property(nonatomic, strong) NSButton *generalLinearTableButton;
@property(nonatomic, strong) NSButton *generalMultiChannelButton;
@property(nonatomic, strong) NSPopUpButton *generalMixChannelsPopup;
@property(nonatomic, strong) NSTextField *titleField;
@property(nonatomic, strong) NSTextField *statusField;
@property(nonatomic, strong) NSTextField *timeField;
@property(nonatomic, strong) NSTextField *durationField;
@property(nonatomic, strong) NSTextField *toolsTitleField;
@property(nonatomic, strong) NSView *toolsTransportView;
@property(nonatomic, strong) PPClassicToolsInspectorView *toolsCommandInspectorView;
@property(nonatomic) BOOL toolsCommandInspectorExpanded;
@property(nonatomic, strong) PPClassicToolsHelpView *toolsEffectHelpView;
@property(nonatomic, strong) NSTextField *toolsEffectHelpTitleField;
@property(nonatomic, strong) NSTextField *toolsEffectHelpBodyField;
@property(nonatomic, strong) NSButton *toolsEffectHelpButton;
@property(nonatomic) BOOL toolsEffectHelpExpanded;
@property(nonatomic, strong) NSTextField *toolsPatternField;
@property(nonatomic, strong) NSTextField *toolsPositionField;
@property(nonatomic, strong) NSTextField *toolsTrackField;
@property(nonatomic, strong) NSTextField *toolsInstrumentField;
@property(nonatomic, strong) NSTextField *toolsNoteField;
@property(nonatomic, strong) NSTextField *toolsEffectField;
@property(nonatomic, strong) NSTextField *toolsArgumentField;
@property(nonatomic, strong) NSTextField *toolsVolumeField;
@property(nonatomic, strong) NSPopUpButton *toolsPatternPopup;
@property(nonatomic, strong) NSPopUpButton *toolsTrackPopup;
@property(nonatomic, strong) NSPopUpButton *toolsInstrumentPopup;
@property(nonatomic, strong) NSPopUpButton *toolsNotePopup;
@property(nonatomic, strong) NSPopUpButton *toolsEffectPopup;
@property(nonatomic, strong) NSPopUpButton *toolsArgumentPopup;
@property(nonatomic, strong) NSPopUpButton *toolsVolumePopup;
@property(nonatomic, strong) PPHexPickerMenuView *toolsArgumentHexPicker;
@property(nonatomic, strong) PPHexPickerMenuView *toolsVolumeHexPicker;
@property(nonatomic, strong) PPHexPickerMenuView *patternArgumentHexPicker;
@property(nonatomic, strong) PPHexPickerMenuView *patternVolumeHexPicker;
@property(nonatomic, strong) PPClassicTransportPositionView *positionSlider;
@property(nonatomic, strong) NSButton *playButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic, strong) NSButton *toolsRecordButton;
@property(nonatomic, strong) NSButton *loopButton;
@property(nonatomic, strong) NSButton *patternRecordButton;
@property(nonatomic, strong) NSButton *patternTraceButton;
@property(nonatomic, strong) NSButton *patternEffectToggle;
@property(nonatomic, strong) NSButton *patternInstrumentToggle;
@property(nonatomic, strong) NSButton *patternVolumeToggle;
@property(nonatomic, strong) NSButton *patternArgumentToggle;
@property(nonatomic, strong) NSPopUpButton *patternEffectPopup;
@property(nonatomic, strong) NSPopUpButton *patternInstrumentPopup;
@property(nonatomic, strong) NSPopUpButton *patternVolumePopup;
@property(nonatomic, strong) NSPopUpButton *patternArgumentPopup;
@property(nonatomic, strong) NSButton *patternFillButton;
@property(nonatomic, strong) NSTextField *patternStepField;
@property(nonatomic, strong) NSStepper *patternStepper;
@property(nonatomic) NSInteger patternStep;
@property(nonatomic) NSInteger patternOctaveOffset;
@property(nonatomic) BOOL patternRecording;
@property(nonatomic) NSInteger patternField;
@property(nonatomic, copy) NSString *patternFieldBuffer;
@property(nonatomic) NSInteger patternFieldBufferRow;
@property(nonatomic) NSInteger patternFieldBufferChannel;
@property(nonatomic) NSInteger patternFieldBufferKind;
@property(nonatomic) NSInteger patternSelectionTop;
@property(nonatomic) NSInteger patternSelectionBottom;
@property(nonatomic) NSInteger patternSelectionLeft;
@property(nonatomic) NSInteger patternSelectionRight;
@property(nonatomic) NSInteger patternSelectionAnchorRow;
@property(nonatomic) NSInteger patternSelectionAnchorChannel;
@property(nonatomic) NSInteger patternCursorRow;
@property(nonatomic) NSInteger patternCursorChannel;
@property(nonatomic) NSInteger patternPlaybackPattern;
@property(nonatomic) NSInteger patternPlaybackRow;
@property(nonatomic) NSInteger patternBandRows;
@property(nonatomic) BOOL patternTraceEnabled;
@property(nonatomic) BOOL suppressPatternSelectionTransportReset;
@property(nonatomic) BOOL suppressPartitionSelectionAction;
@property(nonatomic) NSInteger selectedPartitionPosition;
@property(nonatomic) MADByte defaultPatternInstrument;
@property(nonatomic) MADEffectID defaultPatternEffect;
@property(nonatomic) MADByte defaultPatternArgument;
@property(nonatomic) MADByte defaultPatternVolume;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, strong) id playbackKeyMonitor;
@property(nonatomic, strong) NSURL *documentURL;
@property(nonatomic, strong) NSMenu *openRecentMenu;
@property(nonatomic) BOOL terminationReplyPending;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary<NSString *, NSNumber *> *> *midiHeldNotes;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *midiTrackOwners;
- (void)resetTransportToSelectedPatternPreservingPlayback:(BOOL)preservePlayback;
- (void)arrangeDefaultWorkspace;
- (void)updateToolsTitle;
- (void)updateTransportButtonStates;
- (void)applyMIDIPreferences;
- (void)applyMIDIPreferenceDraftRouting;
- (void)captureVisiblePreferenceValues;
- (void)handleMIDIStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2;
- (void)midiDevicesChanged;
- (void)reconcileMIDIPreferenceDraftEndpoints;
- (IBAction)refreshMIDIDevices:(id)sender;
- (void)handlePianoMIDIOutputNote:(NSInteger)note track:(NSInteger)track
	instrument:(NSInteger)instrument velocity:(NSInteger)velocity began:(BOOL)began;
- (void)recordPianoNote:(NSInteger)note track:(NSInteger)track
	livePlayback:(BOOL)livePlayback velocity:(NSInteger)velocity;
- (void)recordPianoNote:(NSInteger)note track:(NSInteger)track instrument:(NSInteger)instrument
	livePlayback:(BOOL)livePlayback velocity:(NSInteger)velocity;
- (void)recordMIDINoteInDigitalEditor:(NSInteger)note track:(NSInteger)track
	instrument:(NSInteger)instrument velocity:(NSInteger)velocity noteOff:(BOOL)noteOff;
- (BOOL)saveToURL:(NSURL *)url;
- (void)beginSavePanelWithCompletion:(void (^)(BOOL saved))completion;
- (void)finishPendingTermination:(BOOL)shouldTerminate;
@end

static void PPReceiveMIDIEvent(void *context, uint8_t status, uint8_t data1, uint8_t data2)
{
	PPApplicationController *controller = (__bridge PPApplicationController *)context;
	if (controller == nil) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		[controller handleMIDIStatus:status data1:data1 data2:data2];
	});
}

static void PPMIDIDevicesChanged(void *context)
{
	PPApplicationController *controller = (__bridge PPApplicationController *)context;
	if (controller == nil) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		[controller midiDevicesChanged];
	});
}

@implementation PPApplicationController {
	MADLibrary *_library;
	MADDriverRec *_driver;
	MADMusic *_music;
	NSInteger _selectedPattern;
	NSInteger _selectedInstrument;
	NSInteger _selectedSample;
	NSInteger _lastPianoRecordRow[MAXTRACK];
	NSInteger _lastPianoRecordPattern[MAXTRACK];
}

- (BOOL)performConfiguredFunctionKey:(NSInteger)index
{
	NSArray<NSString *> *actions = [NSUserDefaults.standardUserDefaults arrayForKey:PPFKeyActionsDefaultsKey];
	if (index < 0 || index >= (NSInteger)actions.count) return NO;
	NSString *action = actions[index];
	if ([action isEqualToString:@"open"]) [self openDocument:nil];
	else if ([action isEqualToString:@"play"]) [self togglePlayback:nil];
	else if ([action isEqualToString:@"stop"]) [self stopPlayback:nil];
	else if ([action isEqualToString:@"mixer"]) [self showMixer:nil];
	else if ([action isEqualToString:@"instruments"]) [self focusInstruments:nil];
	else if ([action isEqualToString:@"patterns"]) [self showPatterns:nil];
	else if ([action isEqualToString:@"piano"]) [self showPiano:nil];
	else if ([action isEqualToString:@"oscilloscope"]) [self showOscilloscope:nil];
	else if ([action isEqualToString:@"spectrum"]) [self showSpectrum:nil];
	else if ([action isEqualToString:@"music-list"]) [self showMusicList:nil];
	else if ([action isEqualToString:@"overview"]) [self openClassicOverview:nil];
	else if ([action isEqualToString:@"preferences"]) [self showPreferencesWindow:nil];
	else return NO;
	return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	(void)notification;
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	NSApp.appearance = PPClassicLightAppearance();
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowDidBecomeKey:)
		name:NSWindowDidBecomeKeyNotification object:nil];
	self.sampleEditors = [NSMutableArray array];
	self.instrumentEditors = [NSMutableArray array];
	self.patternModeEditors = [NSMutableArray array];
	self.collapsedInstrumentIndexes = [NSMutableIndexSet indexSet];
	self.midiHeldNotes = [NSMutableDictionary dictionary];
	self.midiTrackOwners = [NSMutableDictionary dictionary];
	self.musicListEntries = [NSMutableArray array];
	self.musicListActiveIndex = -1;
	NSMutableDictionary *registeredDefaults = [PPPreferenceDefaultValues() mutableCopy];
	registeredDefaults[PPPatternBandRowsDefaultsKey] = @(PPDefaultPatternBandRows);
	[NSUserDefaults.standardUserDefaults registerDefaults:registeredDefaults];
	MADMIDIInitialize(PPReceiveMIDIEvent, (__bridge void *)self,
		PPMIDIDevicesChanged, (__bridge void *)self);
	[self applyMIDIPreferences];
	self.musicListPlaybackMode = MIN(MAX([NSUserDefaults.standardUserDefaults
		integerForKey:PPMusicListPlaybackModeDefaultsKey], 0), 3);
	self.musicListHandledEnd = NO;
	self.patternStep = MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:PPDigitalStepDefaultsKey], 1), 16);
	self.patternOctaveOffset = MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:PPDigitalOctaveDefaultsKey], -7), 7);
	self.patternRecording = NO;
	self.patternField = 0;
	self.patternFieldBufferRow = -1;
	self.patternFieldBufferChannel = -1;
	self.patternFieldBufferKind = -1;
	self.patternSelectionTop = self.patternSelectionBottom = 0;
	self.patternSelectionLeft = self.patternSelectionRight = 0;
	self.patternSelectionAnchorRow = self.patternSelectionAnchorChannel = 0;
	self.patternCursorRow = self.patternCursorChannel = 0;
	self.patternPlaybackPattern = self.patternPlaybackRow = -1;
	self.selectedPartitionPosition = 0;
	self.patternBandRows = MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:PPPatternBandRowsDefaultsKey], 1), 64);
	self.patternTraceEnabled = [NSUserDefaults.standardUserDefaults boolForKey:PPDigitalTraceDefaultsKey];
	self.defaultPatternInstrument = 1;
	self.defaultPatternEffect = MADEffectArpeggio;
	self.defaultPatternArgument = 0;
	self.defaultPatternVolume = 0;
	for (NSInteger track = 0; track < MAXTRACK; track++) {
		_lastPianoRecordRow[track] = -1;
		_lastPianoRecordPattern[track] = -1;
	}
	if ([NSUserDefaults.standardUserDefaults boolForKey:PPMusicListRememberDefaultsKey]) {
		for (id path in [NSUserDefaults.standardUserDefaults arrayForKey:PPMusicListSavedPathsDefaultsKey]) {
			if ([path isKindOfClass:NSString.class]) {
				[self.musicListEntries addObject:[NSURL fileURLWithPath:path]];
			}
		}
	}
	[self buildMainMenu];
	[self buildClassicWindow];
	[self initializePlayerPRO];
	[self newDocument:nil];
	[self showMixer:nil];
	[self showPiano:nil];
	[self arrangeDefaultWorkspace];
	for (NSWindow *window in NSApp.windows) PPForceClassicLightAppearanceOnWindow(window);
	[self.instrumentsWindow orderFront:nil];
	[self.patternsWindow orderFront:nil];
	[self.toolsWindow orderFront:nil];
	[self.mixerController.window orderFront:nil];
	[self.pianoController.window orderFront:nil];
	[self.window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
	__weak typeof(self) weakSelf = self;
	self.playbackKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
		handler:^NSEvent * _Nullable(NSEvent *event) {
			if (event.isARepeat) return event;
			NSWindow *keyWindow = NSApp.keyWindow;
			if (keyWindow.attachedSheet != nil) return event;
			NSResponder *responder = keyWindow.firstResponder;
			if ([responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).isEditable) return event;
			static const unsigned short functionKeyCodes[] = {122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111};
			for (NSInteger index = 0; index < 12; index++) {
				if (event.keyCode == functionKeyCodes[index]) {
					return [weakSelf performConfiguredFunctionKey:index] ? nil : event;
				}
			}
			NSEventModifierFlags transportModifiers = event.modifierFlags &
				(NSEventModifierFlagCommand | NSEventModifierFlagControl |
				 NSEventModifierFlagOption | NSEventModifierFlagShift);
			if (transportModifiers == 0 &&
				[event.charactersIgnoringModifiers isEqualToString:@"\\"]) {
				// Match the Tools window's push-on/push-off loop button: the
				// unmodified backslash key flips the same control and then uses
				// its normal action so the driver and visible state cannot diverge.
				weakSelf.loopButton.state = weakSelf.loopButton.state == NSControlStateValueOn
					? NSControlStateValueOff : NSControlStateValueOn;
				[weakSelf togglePatternLoop:weakSelf.loopButton];
				return nil;
			}
			if (event.keyCode != 49 ||
				(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0) {
				return event;
			}
			// Space belongs to the sample editor while it is key: there it
			// auditions the open sample/selection.  Consuming it here used to
			// start the song at the Digital editor's selected row instead.
			if ([keyWindow.windowController isKindOfClass:PPSampleEditorController.class]) return event;
			[weakSelf togglePlayback:nil];
			return nil;
		}];

	self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
		target:self selector:@selector(updatePlaybackStatus:) userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	(void)notification;
	[self persistRememberedMusicList];
	[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
	if (self.playbackKeyMonitor != nil) {
		[NSEvent removeMonitor:self.playbackKeyMonitor];
		self.playbackKeyMonitor = nil;
	}
	[self.statusTimer invalidate];
	[self disposeCurrentMusic];
	if (_driver != NULL) {
		MADStopDriver(_driver);
		[self.equalizerController attachDriver:NULL];
		MADDisposeDriver(_driver);
		_driver = NULL;
	}
	if (_library != NULL) {
		MADDisposeLibrary(_library);
		_library = NULL;
	}
	MADMIDIShutdown();
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	(void)sender;
	// Commit an in-progress title, instrument, sample, or command edit before
	// consulting hasChanged. Otherwise quitting while a field still owns the
	// editor can omit its newest text from both the prompt and the saved file.
	[NSApp.keyWindow makeFirstResponder:nil];
	if (_music == NULL || !_music->hasChanged) return NSTerminateNow;
	if (self.terminationReplyPending) return NSTerminateLater;

	self.terminationReplyPending = YES;
	NSString *name = self.documentURL.lastPathComponent;
	if (name.length == 0) name = self.titleField.stringValue;
	if (name.length == 0) name = @"Untitled";
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = [NSString stringWithFormat:@"Do you want to save the changes made to \u201c%@\u201d?", name];
	alert.informativeText = @"Your changes will be lost if you quit without saving them.";
	[alert addButtonWithTitle:@"Save"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert addButtonWithTitle:@"Don\u2019t Save"];
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
		if (response == NSAlertFirstButtonReturn) {
			if (self.documentURL != nil) {
				[self finishPendingTermination:[self saveToURL:self.documentURL]];
			} else {
				[self beginSavePanelWithCompletion:^(BOOL saved) {
					[self finishPendingTermination:saved];
				}];
			}
		} else if (response == NSAlertThirdButtonReturn) {
			[self finishPendingTermination:YES];
		} else {
			[self finishPendingTermination:NO];
		}
	}];
	return NSTerminateLater;
}

- (void)finishPendingTermination:(BOOL)shouldTerminate
{
	if (!self.terminationReplyPending) return;
	self.terminationReplyPending = NO;
	[NSApp replyToApplicationShouldTerminate:shouldTerminate];
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	NSWindow *window = [notification.object isKindOfClass:NSWindow.class] ? notification.object : nil;
	if (window != nil) PPForceClassicLightAppearanceOnWindow(window);
}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window
{
	(void)window;
	return self.window.undoManager;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	(void)sender;
	return YES;
}

- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames
{
	(void)application;
	if (filenames.count > 0) {
		NSMutableArray<NSURL *> *URLs = [NSMutableArray arrayWithCapacity:filenames.count];
		for (NSString *filename in filenames) [URLs addObject:[NSURL fileURLWithPath:filename]];
		if (URLs.count > 1) [self addURLsToMusicList:URLs atIndex:self.musicListEntries.count];
		[self loadDocumentAtURL:URLs.firstObject];
	}
	[NSApp replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

#pragma mark - Construction

- (void)initializePlayerPRO
{
	MADErr error = MADInitLibrary(NULL, &_library);
	if (error != MADNoErr) {
		[self presentErrorCode:error operation:@"initializing PlayerPRO"];
		return;
	}

	MADDriverSettings settings;
	MADGetBestDriver(&settings);
	settings.driverMode = CoreAudioDriver;
	// Music List owns the user-visible Stop/Next/Random/Loop policy.  Leaving
	// the core driver's historical repeat flag enabled keeps Reading set after
	// musicEnd and makes the transport appear to play silence indefinitely.
	settings.repeatMusic = false;
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	settings.outPutRate = (unsigned int)MIN(MAX([defaults integerForKey:PPDriverSampleRateDefaultsKey], 11025), 48000);
	settings.oversampling = (int)MIN(MAX([defaults integerForKey:PPDriverOversamplingDefaultsKey], 1), 4);
	settings.MicroDelaySize = (int)MIN(MAX([defaults integerForKey:PPDriverMicroDelayDefaultsKey], 0), 1000);
	settings.TickRemover = [defaults boolForKey:PPDriverTickRemoverDefaultsKey];
	settings.surround = [defaults boolForKey:PPDriverSurroundDefaultsKey];
	settings.Reverb = [defaults boolForKey:PPDriverReverbEnabledDefaultsKey];
	settings.ReverbSize = (int)MIN(MAX([defaults integerForKey:PPDriverReverbDelayDefaultsKey], 25), 1000);
	settings.ReverbStrength = (int)MIN(MAX([defaults integerForKey:PPDriverReverbStrengthDefaultsKey], 0), 70);
	error = MADCreateDriver(&settings, _library, &_driver);
	if (error == MADNoErr) {
		error = MADStartDriver(_driver);
	}
	if (_driver != NULL) {
		_driver->SendMIDIClockData = [defaults boolForKey:PPMIDIClockDefaultsKey];
	}
	if (error != MADNoErr) {
		[self presentErrorCode:error operation:@"starting Core Audio"];
	}
}

- (void)buildMainMenu
{
	NSMenu *menuBar = [[NSMenu alloc] initWithTitle:@""];
	NSApp.mainMenu = menuBar;

	NSMenuItem *applicationItem = [[NSMenuItem alloc] initWithTitle:@"MachoPlayer" action:nil keyEquivalent:@""];
	[menuBar addItem:applicationItem];
	NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"MachoPlayer"];
	applicationItem.submenu = applicationMenu;
	[applicationMenu addItemWithTitle:@"About MachoPlayer" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
	[applicationMenu addItem:[NSMenuItem separatorItem]];
	[applicationMenu addItemWithTitle:@"Quit MachoPlayer" action:@selector(terminate:) keyEquivalent:@"q"];

	NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
	[menuBar addItem:fileItem];
	NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
	fileItem.submenu = fileMenu;
	[fileMenu addItemWithTitle:@"New…" action:@selector(newDocument:) keyEquivalent:@"n"];
	[fileMenu addItemWithTitle:@"Open…" action:@selector(openDocument:) keyEquivalent:@"o"];
	NSMenuItem *openRecentItem = [[NSMenuItem alloc] initWithTitle:@"Open Recent"
		action:nil keyEquivalent:@""];
	self.openRecentMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];
	self.openRecentMenu.delegate = self;
	openRecentItem.submenu = self.openRecentMenu;
	[fileMenu addItem:openRecentItem];
	[fileMenu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
	NSMenuItem *saveAs = [fileMenu addItemWithTitle:@"Save As…" action:@selector(saveDocumentAs:) keyEquivalent:@"S"];
	saveAs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
	[fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItemWithTitle:@"Export as…" action:@selector(exportDocument:) keyEquivalent:@""];
	[fileMenu addItemWithTitle:@"Reset" action:@selector(rewind:) keyEquivalent:@""];
	[fileMenu addItemWithTitle:@"Music List" action:@selector(showMusicList:) keyEquivalent:@""];
	[fileMenu addItemWithTitle:@"Save Music List…" action:@selector(saveMusicList:) keyEquivalent:@""];
	[fileMenu addItemWithTitle:@"Clear Music List" action:@selector(clearMusicList:) keyEquivalent:@""];
	[fileMenu addItem:[NSMenuItem separatorItem]];
	[fileMenu addItemWithTitle:@"Page SetUp…" action:@selector(runPageLayout:) keyEquivalent:@""];
	[fileMenu addItemWithTitle:@"Preferences…" action:@selector(showPreferencesWindow:) keyEquivalent:@","];

	NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
	[menuBar addItem:editItem];
	NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
	editItem.submenu = editMenu;
	[editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
	NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
	redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
	[editMenu addItem:[NSMenuItem separatorItem]];
	[editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
	[editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
	[editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
	[editMenu addItemWithTitle:@"Clear" action:@selector(delete:) keyEquivalent:@""];
	[editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

	NSMenuItem *instrumentsItem = [[NSMenuItem alloc] initWithTitle:@"Instruments" action:nil keyEquivalent:@""];
	NSMenu *instrumentsMenu = [[NSMenu alloc] initWithTitle:@"Instruments"];
	instrumentsItem.submenu = instrumentsMenu;
	[instrumentsMenu addItemWithTitle:@"Instruments List" action:@selector(focusInstruments:) keyEquivalent:@"l"];
	[instrumentsMenu addItem:[NSMenuItem separatorItem]];
	NSMenuItem *newInstrumentItem = [[NSMenuItem alloc] initWithTitle:@"New…" action:nil keyEquivalent:@""];
	NSMenu *newInstrumentMenu = [[NSMenu alloc] initWithTitle:@"New…"];
	[newInstrumentMenu addItemWithTitle:@"Import a File…" action:@selector(loadSample:) keyEquivalent:@""];
	[newInstrumentMenu addItemWithTitle:@"Silence/Tone Generator" action:@selector(createSilentSample:) keyEquivalent:@""];
	[newInstrumentMenu addItemWithTitle:@"Record (Audio Input)" action:@selector(recordSample:) keyEquivalent:@""];
	NSMenuItem *quickTime = [newInstrumentMenu addItemWithTitle:@"Quicktime Instrument" action:nil keyEquivalent:@""];
	quickTime.enabled = NO;
	[newInstrumentMenu addItemWithTitle:@"RAW Data Import…" action:@selector(importRawSample:) keyEquivalent:@""];
	NSMenuItem *audioCD = [newInstrumentMenu addItemWithTitle:@"Audio CD Import…" action:nil keyEquivalent:@""];
	audioCD.enabled = NO;
	NSMenuItem *selection = [newInstrumentMenu addItemWithTitle:@"Selection in Digital Editor…" action:nil keyEquivalent:@""];
	selection.enabled = NO;
	newInstrumentItem.submenu = newInstrumentMenu;
	[instrumentsMenu addItem:newInstrumentItem];
	[instrumentsMenu addItemWithTitle:@"Duplicate Sample" action:@selector(duplicateSelectedSample:) keyEquivalent:@""];
	[instrumentsMenu addItemWithTitle:@"Duplicate Instrument" action:@selector(duplicateSelectedInstrument:) keyEquivalent:@""];
	[instrumentsMenu addItemWithTitle:@"Export As…" action:@selector(exportSelectedSample:) keyEquivalent:@""];
	[instrumentsMenu addItemWithTitle:@"Delete" action:@selector(deleteSelectedInstrumentOrSample:) keyEquivalent:@""];
	[instrumentsMenu addItem:[NSMenuItem separatorItem]];
	[instrumentsMenu addItemWithTitle:@"Save Instruments List…" action:nil keyEquivalent:@""];

	NSMenuItem *viewsItem = [[NSMenuItem alloc] initWithTitle:@"Views" action:nil keyEquivalent:@""];
	[menuBar addItem:viewsItem];
	NSMenu *viewsMenu = [[NSMenu alloc] initWithTitle:@"Views"];
	viewsItem.submenu = viewsMenu;
	[viewsMenu addItemWithTitle:@"Tools" action:@selector(showTools:) keyEquivalent:@""];
	[viewsMenu addItemWithTitle:@"Oscillo View" action:@selector(showOscilloscope:) keyEquivalent:@""];
	[viewsMenu addItemWithTitle:@"Spectrum View" action:@selector(showSpectrum:) keyEquivalent:@""];
	[viewsMenu addItemWithTitle:@"Mixer" action:@selector(showMixer:) keyEquivalent:@"b"];
	[viewsMenu addItemWithTitle:@"Equalizer" action:@selector(showEqualizer:) keyEquivalent:@""];
	[viewsMenu addItemWithTitle:@"Pattern View" action:@selector(openClassicOverview:) keyEquivalent:@""];
	[viewsMenu addItemWithTitle:@"Partition" action:@selector(showPartition:) keyEquivalent:@""];
	[viewsMenu addItemWithTitle:@"Piano" action:@selector(showPiano:) keyEquivalent:@"p"];

	NSMenuItem *editorItem = [[NSMenuItem alloc] initWithTitle:@"Editor" action:nil keyEquivalent:@""];
	[menuBar addItem:editorItem];
	NSMenu *editorMenu = [[NSMenu alloc] initWithTitle:@"Editor"];
	editorItem.submenu = editorMenu;
	[editorMenu addItemWithTitle:@"Digital Editor" action:@selector(focusPattern:) keyEquivalent:@"d"];
	[editorMenu addItemWithTitle:@"Box Editor" action:@selector(openBoxEditor:) keyEquivalent:@""];
	[editorMenu addItemWithTitle:@"Classical Editor" action:@selector(openClassicalEditor:) keyEquivalent:@""];
	[editorMenu addItemWithTitle:@"Wave Preview" action:@selector(openWaveEditor:) keyEquivalent:@""];
	[editorMenu addItem:[NSMenuItem separatorItem]];
	[editorMenu addItemWithTitle:@"Find…" action:@selector(findCommand:) keyEquivalent:@"f"];
	[editorMenu addItemWithTitle:@"Find Current Note" action:@selector(findCurrentNote:) keyEquivalent:@"g"];
	[editorMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
	[editorMenu addItemWithTitle:@"Convert patterns to 64 rows" action:@selector(convertPatternsTo64Rows:) keyEquivalent:@""];
	[editorMenu addItemWithTitle:@"General Information…" action:@selector(showMusicInformation:) keyEquivalent:@"i"];

	// The original menu order placed instrument operations after the editors.
	[menuBar addItem:instrumentsItem];

	NSMenuItem *patternsItem = [[NSMenuItem alloc] initWithTitle:@"Patterns" action:nil keyEquivalent:@""];
	[menuBar addItem:patternsItem];
	NSMenu *patternsMenu = [[NSMenu alloc] initWithTitle:@"Patterns"];
	patternsItem.submenu = patternsMenu;
	[patternsMenu addItemWithTitle:@"Patterns List" action:@selector(showPatterns:) keyEquivalent:@""];
	[patternsMenu addItemWithTitle:@"Partition" action:@selector(showPartition:) keyEquivalent:@""];
	[patternsMenu addItem:[NSMenuItem separatorItem]];
	[patternsMenu addItemWithTitle:@"New Pattern" action:@selector(newPattern:) keyEquivalent:@""];
	[patternsMenu addItemWithTitle:@"Duplicate Pattern" action:@selector(duplicatePattern:) keyEquivalent:@""];
	[patternsMenu addItemWithTitle:@"Pattern Information…" action:@selector(editPatternInformation:) keyEquivalent:@""];
	[patternsMenu addItemWithTitle:@"Purge Pattern…" action:@selector(purgePattern:) keyEquivalent:@""];
	[patternsMenu addItemWithTitle:@"Delete Pattern…" action:@selector(deletePattern:) keyEquivalent:@""];

	NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
	[menuBar addItem:helpItem];
	NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
	helpItem.submenu = helpMenu;
	[helpMenu addItemWithTitle:@"Show Online Help" action:nil keyEquivalent:@""];
}

- (void)buildClassicWindow
{
	NSRect frame = NSMakeRect(90, 170, 1049, 396);
	self.window = [[NSWindow alloc] initWithContentRect:frame
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
			NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	self.window.title = @"Pattern: 000";
	self.window.minSize = NSMakeSize(540, 260);
	self.window.releasedWhenClosed = NO;
	self.window.backgroundColor = NSColor.whiteColor;

	NSView *content = self.window.contentView;
	content.autoresizesSubviews = YES;

	self.titleField = [NSTextField textFieldWithString:@"Untitled"];
	self.titleField.identifier = @"music-title";
	self.titleField.delegate = self;
	NSView *controlStrip = [[PPClassicControlStripView alloc] initWithFrame:NSMakeRect(0, frame.size.height - 44, frame.size.width, 44)];
	controlStrip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[content addSubview:controlStrip];

	[self addClassicButtonTo:controlStrip x:4 image:@"preferences" title:nil action:@selector(showPreferencesWindow:)];
	[self addClassicButtonTo:controlStrip x:33 image:@"load" title:nil action:@selector(openDocument:)];
	[self addClassicButtonTo:controlStrip x:62 image:@"save" title:nil action:@selector(saveDocument:)];
	[self addClassicButtonTo:controlStrip x:91 image:@"info" title:nil action:@selector(showMusicInformation:)];
	[self addClassicButtonTo:controlStrip x:120 image:@"play" title:nil action:@selector(togglePlayback:)];
	self.patternRecordButton = [self addClassicButtonTo:controlStrip x:149 image:@"record" title:nil action:@selector(togglePatternRecording:)];
	self.patternRecordButton.buttonType = NSButtonTypePushOnPushOff;
	self.patternRecordButton.toolTip = @"Direct tracker keyboard recording";
	NSButton *effectButton = [self addClassicButtonTo:controlStrip x:178 image:@"fx" title:nil action:@selector(showPatternDefaults:)];
	effectButton.toolTip = @"Choose Digital effect, argument, and volume defaults";
	[self addClassicButtonTo:controlStrip x:207 image:@"show" title:nil action:@selector(showPatterns:)];
	self.patternTraceButton = [self addClassicButtonTo:controlStrip x:236 image:@"trace" title:nil action:@selector(togglePatternTrace:)];
	self.patternTraceButton.buttonType = NSButtonTypePushOnPushOff;
	self.patternTraceButton.state = self.patternTraceEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	self.patternTraceButton.toolTip = @"Follow the playing pattern and keep its current row visible";
	[self addClassicButtonTo:controlStrip x:265 image:@"find" title:nil action:@selector(findCommand:)];
	[self addClassicButtonTo:controlStrip x:294 image:@"note-up" title:nil action:@selector(transposeNoteUp:)];
	[self addClassicButtonTo:controlStrip x:323 image:@"note-down" title:nil action:@selector(transposeNoteDown:)];

	NSTextField *stepLabel = [NSTextField labelWithString:@"Step:"];
	stepLabel.frame = NSMakeRect(346, 24, 36, 16);
	stepLabel.font = [self classicFont];
	[controlStrip addSubview:stepLabel];
	self.patternStepField = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld", (long)self.patternStep]];
	self.patternStepField.frame = NSMakeRect(381, 24, 14, 16);
	self.patternStepField.font = [self classicFont];
	[controlStrip addSubview:self.patternStepField];
	self.patternStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(396, 24, 20, 18)];
	self.patternStepper.minValue = 1; self.patternStepper.maxValue = 16; self.patternStepper.integerValue = self.patternStep;
	self.patternStepper.target = self; self.patternStepper.action = @selector(changePatternStep:);
	[controlStrip addSubview:self.patternStepper];
	// The original Digital editor kept the enable checkbox and value selector
	// separate.  Preserve that compact Ins / FX / Arg / Vol order here.
	self.patternInstrumentToggle = [self addClassicToggle:@"Ins:001" frame:NSMakeRect(3, 1, 71, 16) toView:controlStrip selected:YES];
	self.patternInstrumentPopup = [self addClassicPatternPopupAtX:77 title:@"Instrument" toView:controlStrip];
	self.patternEffectToggle = [self addClassicToggle:@"FX:0" frame:NSMakeRect(102, 1, 57, 16) toView:controlStrip selected:NO];
	self.patternEffectPopup = [self addClassicPatternPopupAtX:161 title:@"Effect" toView:controlStrip];
	self.patternArgumentToggle = [self addClassicToggle:@"Arg:00" frame:NSMakeRect(187, 1, 76, 16) toView:controlStrip selected:NO];
	self.patternArgumentPopup = [self addClassicPatternPopupAtX:264 title:@"Argument" toView:controlStrip];
	self.patternVolumeToggle = [self addClassicToggle:@"Vol:00" frame:NSMakeRect(291, 1, 76, 16) toView:controlStrip selected:NO];
	self.patternVolumePopup = [self addClassicPatternPopupAtX:368 title:@"Volume" toView:controlStrip];
	for (NSButton *toggle in @[self.patternEffectToggle, self.patternInstrumentToggle,
		self.patternVolumeToggle, self.patternArgumentToggle]) {
		toggle.toolTip = @"Enabled defaults are applied by Fill and direct Digital entry";
	}
	self.patternFillButton = [[PPClassicIconButton alloc] initWithFrame:NSMakeRect(394, 1, 25, 16)];
	self.patternFillButton.image = [self classicImageNamed:@"fill"];
	// Unlike the other cicn exports, Fill is a 12 x 5 glyph parked in the
	// upper-left corner of a 32 x 32 white canvas. Draw the original pixels at
	// their native visual size instead of shrinking that mostly-empty canvas.
	((PPClassicIconButton *)self.patternFillButton).classicArtworkSourceRect = NSMakeRect(1, 26, 12, 5);
	((PPClassicIconButton *)self.patternFillButton).classicArtworkDisplaySize = NSMakeSize(12, 5);
	self.patternFillButton.target = self;
	self.patternFillButton.action = @selector(fillPatternSelection:);
	self.patternFillButton.frame = NSMakeRect(394, 1, 25, 16);
	self.patternFillButton.bezelStyle = NSBezelStyleSmallSquare;
	self.patternFillButton.imageScaling = NSImageScaleProportionallyDown;
	self.patternFillButton.focusRingType = NSFocusRingTypeNone;
	self.patternFillButton.toolTip = @"Fill selection with the enabled defaults";
	[controlStrip addSubview:self.patternFillButton];
	[self rebuildPatternInstrumentPopup];
	[self rebuildPatternEffectPopup];
	[self rebuildPatternHexPopup:self.patternArgumentPopup title:@"Argument"
		value:self.defaultPatternArgument action:@selector(choosePatternArgument:)];
	[self rebuildPatternHexPopup:self.patternVolumePopup title:@"Volume"
		value:self.defaultPatternVolume action:@selector(choosePatternVolume:)];

	NSScrollView *patternScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - 44)];
	patternScroll.hasHorizontalScroller = YES;
	patternScroll.hasVerticalScroller = YES;
	patternScroll.autohidesScrollers = NO;
	patternScroll.scrollerStyle = NSScrollerStyleLegacy;
	patternScroll.verticalScrollElasticity = NSScrollElasticityNone;
	patternScroll.borderType = NSNoBorder;
	patternScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	self.patternTable = [[PPPatternTableView alloc] initWithFrame:patternScroll.bounds];
	self.patternTable.identifier = @"pattern";
	self.patternTable.dataSource = self;
	self.patternTable.delegate = self;
	self.patternTable.commandDelegate = self;
	self.patternTable.rowHeight = 13;
	self.patternTable.usesAlternatingRowBackgroundColors = NO;
	self.patternTable.backgroundColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
	self.patternTable.gridStyleMask = NSTableViewGridNone;
	self.patternTable.intercellSpacing = NSMakeSize(0, 0);
	self.patternTable.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
	self.patternTable.allowsColumnSelection = YES;
	self.patternTable.allowsMultipleSelection = YES;
	self.patternTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
	PPPatternHeaderView *patternHeader = [[PPPatternHeaderView alloc]
		initWithFrame:NSMakeRect(0, 0, patternScroll.bounds.size.width, 13)];
	patternHeader.commandDelegate = self;
	self.patternTable.headerView = patternHeader;
	patternScroll.documentView = self.patternTable;
	[content addSubview:patternScroll];
	CGFloat patternScrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
		scrollerStyle:NSScrollerStyleLegacy];
	PPPatternHeaderCornerView *patternCorner = [[PPPatternHeaderCornerView alloc] initWithFrame:
		NSMakeRect(NSWidth(content.bounds) - patternScrollerWidth,
			NSMaxY(patternScroll.frame) - NSHeight(patternHeader.frame),
			patternScrollerWidth, NSHeight(patternHeader.frame))];
	patternCorner.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
	[content addSubview:patternCorner];

	self.statusField = [NSTextField labelWithString:@"Ready"];
	[self buildToolsWindow];
	[self buildMusicListWindow];
	[self buildPatternsWindow];
	[self buildPartitionWindow];
	[self buildInstrumentsWindow];
}

- (NSFont *)classicFont
{
	return [NSFont fontWithName:@"Monaco" size:9] ?: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
}

- (NSImage *)classicImageNamed:(NSString *)name
{
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png" inDirectory:@"Classic"];
	return path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:path];
}

- (NSButton *)addClassicButtonTo:(NSView *)view x:(CGFloat)x image:(NSString *)imageName
	title:(NSString *)title action:(SEL)action
{
	NSButton *button = [[PPClassicIconButton alloc] initWithFrame:NSMakeRect(x, 22, 20, 20)];
	button.title = title ?: @"";
	button.target = self;
	button.action = action;
	button.frame = NSMakeRect(x, 22, 20, 20);
	button.bordered = NO;
	button.focusRingType = NSFocusRingTypeNone;
	button.font = [self classicFont];
	if (imageName != nil) {
		button.image = [self classicImageNamed:imageName];
		button.imagePosition = NSImageOnly;
		button.imageScaling = NSImageScaleProportionallyDown;
	}
	[view addSubview:button];
	return button;
}

- (void)configureOriginalListArtwork:(NSString *)imageName forButton:(PPClassicIconButton *)button
{
	button.image = [self classicImageNamed:imageName];
	// These cicn exports retain their original 32 x 32 canvas even though the
	// actual list-toolbar glyphs occupy only a small block in its upper-left.
	// Crop to those source pixels and draw them 1:1, just as QuickDraw did.
	NSDictionary<NSString *, NSValue *> *sourceRects = @{
		@"instrument-load": [NSValue valueWithRect:NSMakeRect(3, 15, 14, 14)],
		@"instrument-save": [NSValue valueWithRect:NSMakeRect(3, 15, 14, 14)],
		@"instrument-delete": [NSValue valueWithRect:NSMakeRect(3, 15, 13, 14)],
		@"instrument-record": [NSValue valueWithRect:NSMakeRect(3, 15, 14, 14)],
		@"instrument-open": [NSValue valueWithRect:NSMakeRect(5, 20, 11, 6)],
		@"instrument-play": [NSValue valueWithRect:NSMakeRect(4, 17, 12, 11)],
		@"info": [NSValue valueWithRect:NSMakeRect(5, 3, 9, 14)]
	};
	NSValue *sourceValue = sourceRects[imageName];
	if (sourceValue != nil) {
		button.classicArtworkSourceRect = sourceValue.rectValue;
		button.classicArtworkDisplaySize = sourceValue.rectValue.size;
	}
	button.imagePosition = NSImageOnly;
	button.imageScaling = NSImageScaleNone;
}

- (PPClassicIconButton *)classicListToolbarButtonAtX:(CGFloat)x y:(CGFloat)y
	image:(NSString *)imageName action:(SEL)action toolTip:(NSString *)toolTip inView:(NSView *)view
{
	PPClassicIconButton *button = [[PPClassicIconButton alloc] initWithFrame:NSMakeRect(x, y, 20, 20)];
	button.target = self;
	button.action = action;
	button.bordered = NO;
	button.focusRingType = NSFocusRingTypeNone;
	button.toolTip = toolTip;
	[self configureOriginalListArtwork:imageName forButton:button];
	[view addSubview:button];
	return button;
}

- (IBAction)showClassicToolbarMenu:(NSButton *)sender
{
	if (sender.menu.numberOfItems == 0) { NSBeep(); return; }
	[sender.menu popUpMenuPositioningItem:nil
		atLocation:NSMakePoint(NSMinX(sender.bounds), NSMinY(sender.bounds)) inView:sender];
}

- (NSButton *)addClassicToggle:(NSString *)title frame:(NSRect)frame toView:(NSView *)view selected:(BOOL)selected
{
	NSButton *button = [NSButton checkboxWithTitle:title target:nil action:nil];
	button.frame = frame;
	button.controlSize = NSControlSizeMini;
	button.font = [self classicFont];
	button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
	[view addSubview:button];
	return button;
}

- (NSPopUpButton *)addClassicPatternPopupAtX:(CGFloat)x title:(NSString *)title toView:(NSView *)view
{
	// DITL 139 used 20 x 13 popup controls at QuickDraw y=28..41.
	// AppKit's origin is at the bottom here, hence y=3.
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x, 3, 20, 13) pullsDown:YES];
	popup.font = [self classicFont];
	popup.controlSize = NSControlSizeMini;
	popup.refusesFirstResponder = YES;
	popup.focusRingType = NSFocusRingTypeNone;
	popup.toolTip = [NSString stringWithFormat:@"Choose the Digital %@ default", title.lowercaseString];
	// A pull-down's first item is its face.  Keep it blank so the compact
	// control shows only the original-style down arrow instead of clipped text.
	[popup addItemWithTitle:@""];
	popup.accessibilityLabel = [NSString stringWithFormat:@"Digital %@ menu", title];
	[view addSubview:popup];
	return popup;
}

- (NSButton *)transportButtonAtX:(CGFloat)x image:(NSString *)name action:(SEL)action inView:(NSView *)view
{
	NSButton *button = [NSButton buttonWithImage:[self transportImageNamed:name] target:self action:action];
	button.frame = NSMakeRect(x, 27, 20, 20);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.imageScaling = NSImageScaleProportionallyDown;
	button.focusRingType = NSFocusRingTypeNone;
	[view addSubview:button];
	return button;
}

- (NSImage *)transportImageNamed:(NSString *)name
{
	if ([name isEqualToString:@"PPLoop"]) return PPOriginalLoopTransportImage();
	if ([name isEqualToString:@"PPRecord"]) return PPOriginalRecordTransportImage();
	NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"pdf" inDirectory:@"Transport"];
	return path == nil ? nil : [[NSImage alloc] initWithContentsOfFile:path];
}

- (NSPanel *)classicPanelWithSize:(NSSize)size title:(NSString *)title
{
	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
		styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskResizable
		backing:NSBackingStoreBuffered defer:NO];
	panel.title = title;
	panel.releasedWhenClosed = NO;
	panel.floatingPanel = YES;
	panel.hidesOnDeactivate = NO;
	return panel;
}

- (void)buildToolsWindow
{
	self.toolsWindow = [self classicPanelWithSize:NSMakeSize(183, 48) title:@"Tools"];
	self.toolsWindow.styleMask &= ~NSWindowStyleMaskResizable;
	self.toolsWindow.backgroundColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
	self.toolsWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	NSView *content = self.toolsWindow.contentView;
	self.toolsTransportView = [[PPClassicToolsTransportView alloc] initWithFrame:NSMakeRect(0, 0, 183, 48)];
	[content addSubview:self.toolsTransportView];
	NSView *view = self.toolsTransportView;
	NSButton *previous = [self transportButtonAtX:1 image:@"PPPrevTrack"
		action:@selector(previousPartition:) inView:view];
	previous.toolTip = @"Previous partition position";
	NSButton *reverse = [self transportButtonAtX:24 image:@"PPReverse"
		action:@selector(scanBackward:) inView:view];
	reverse.toolTip = @"Scan backward";
	reverse.continuous = YES;
	[reverse setPeriodicDelay:0.35 interval:0.08];
	self.toolsRecordButton = [self transportButtonAtX:47 image:@"PPRecord"
		action:@selector(toggleToolsRecording:) inView:view];
	self.toolsRecordButton.buttonType = NSButtonTypePushOnPushOff;
	self.toolsRecordButton.toolTip = @"Arm Piano recording";
	self.loopButton = [self transportButtonAtX:70 image:@"PPLoop" action:@selector(togglePatternLoop:) inView:view];
	self.loopButton.buttonType = NSButtonTypePushOnPushOff;
	self.loopButton.state = NSControlStateValueOff;
	self.loopButton.toolTip = @"Loop the current pattern";
	self.stopButton = [self transportButtonAtX:93 image:@"PPStop" action:@selector(stopPlayback:) inView:view];
	self.stopButton.buttonType = NSButtonTypePushOnPushOff;
	self.stopButton.toolTip = @"Stop playback";
	self.playButton = [self transportButtonAtX:116 image:@"PPPlay" action:@selector(playPlayback:) inView:view];
	self.playButton.buttonType = NSButtonTypePushOnPushOff;
	self.playButton.toolTip = @"Play";
	NSButton *forward = [self transportButtonAtX:139 image:@"PPFastForward"
		action:@selector(scanForward:) inView:view];
	forward.toolTip = @"Scan forward";
	forward.continuous = YES;
	[forward setPeriodicDelay:0.35 interval:0.08];
	NSButton *next = [self transportButtonAtX:162 image:@"PPNextTrack"
		action:@selector(nextPartition:) inView:view];
	next.toolTip = @"Next partition position";

	self.timeField = [NSTextField labelWithString:@"00:00"];
	self.timeField.frame = NSMakeRect(2, 14, 34, 12);
	self.timeField.font = [self classicFont];
	[view addSubview:self.timeField];
	self.durationField = [NSTextField labelWithString:@"00:00"];
	self.durationField.frame = NSMakeRect(147, 14, 34, 12);
	self.durationField.alignment = NSTextAlignmentRight;
	self.durationField.font = [self classicFont];
	[view addSubview:self.durationField];
	self.positionSlider = [[PPClassicTransportPositionView alloc] initWithFrame:NSMakeRect(36, 14, 109, 12)];
	self.positionSlider.focusRingType = NSFocusRingTypeNone;
	self.positionSlider.target = self; self.positionSlider.action = @selector(seek:);
	[view addSubview:self.positionSlider];
	self.toolsTitleField = [NSTextField labelWithString:@"Untitled"];
	self.toolsTitleField.frame = NSMakeRect(2, 0, 179, 13);
	self.toolsTitleField.alignment = NSTextAlignmentCenter;
	self.toolsTitleField.font = [self classicFont];
	self.toolsTitleField.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[view addSubview:self.toolsTitleField];

	self.toolsCommandInspectorView = [[PPClassicToolsInspectorView alloc] initWithFrame:NSMakeRect(0, 0, 183, 121)];
	self.toolsCommandInspectorView.hidden = YES;
	[content addSubview:self.toolsCommandInspectorView positioned:NSWindowBelow relativeTo:self.toolsTransportView];

	NSTextField *(^label)(NSString *, NSRect, NSTextAlignment) = ^NSTextField *(NSString *title, NSRect frame,
		NSTextAlignment alignment) {
		NSTextField *field = [NSTextField labelWithString:title];
		field.frame = frame;
		field.font = [self classicFont];
		field.alignment = alignment;
		[self.toolsCommandInspectorView addSubview:field];
		return field;
	};
	NSTextField *(^editor)(NSString *, NSRect, NSString *) = ^NSTextField *(NSString *value, NSRect frame,
		NSString *identifier) {
		NSTextField *field = [NSTextField textFieldWithString:value];
		field.frame = frame;
		field.font = [self classicFont];
		field.controlSize = NSControlSizeMini;
		field.alignment = NSTextAlignmentRight;
		field.identifier = identifier;
		field.delegate = self;
		field.focusRingType = NSFocusRingTypeNone;
		[self.toolsCommandInspectorView addSubview:field];
		return field;
	};
	NSPopUpButton *(^popup)(NSRect, NSString *) = ^NSPopUpButton *(NSRect frame, NSString *accessibilityLabel) {
		NSPopUpButton *button = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:YES];
		button.font = [self classicFont];
		button.controlSize = NSControlSizeMini;
		button.focusRingType = NSFocusRingTypeNone;
		button.refusesFirstResponder = YES;
		[button addItemWithTitle:@""];
		button.accessibilityLabel = accessibilityLabel;
		[self.toolsCommandInspectorView addSubview:button];
		return button;
	};

	label(@"Pat:", NSMakeRect(2, 102, 22, 16), NSTextAlignmentLeft);
	self.toolsPatternField = editor(@"0", NSMakeRect(23, 102, 22, 17), @"tools-pattern");
	self.toolsPatternPopup = popup(NSMakeRect(44, 101, 21, 19), @"Tools pattern menu");
	label(@"Pos:", NSMakeRect(66, 102, 22, 16), NSTextAlignmentLeft);
	self.toolsPositionField = editor(@"0", NSMakeRect(87, 102, 23, 17), @"tools-position");
	label(@"Track:", NSMakeRect(111, 102, 34, 16), NSTextAlignmentLeft);
	self.toolsTrackField = editor(@"1", NSMakeRect(144, 102, 19, 17), @"tools-track");
	self.toolsTrackPopup = popup(NSMakeRect(162, 101, 21, 19), @"Tools track menu");

	NSArray<NSString *> *fieldNames = @[@"Instrument:", @"Note:", @"Effect:", @"Argument:", @"Volume:"];
	NSArray<NSString *> *identifiers = @[@"tools-command-instrument", @"tools-command-note",
		@"tools-command-effect", @"tools-command-argument", @"tools-command-volume"];
	NSMutableArray<NSTextField *> *fields = [NSMutableArray arrayWithCapacity:5];
	NSMutableArray<NSPopUpButton *> *popups = [NSMutableArray arrayWithCapacity:5];
	for (NSInteger row = 0; row < 5; row++) {
		CGFloat y = 81 - row * 20;
		label(fieldNames[row], NSMakeRect(51, y, 68, 16), NSTextAlignmentRight);
		[fields addObject:editor(row == 0 ? @"000" : row == 1 ? @"000" : row == 2 ? @"0" : @"00",
			NSMakeRect(120, y, 41, 17), identifiers[row])];
		[popups addObject:popup(NSMakeRect(160, y - 1, 23, 19),
			[NSString stringWithFormat:@"Tools %@ menu", fieldNames[row]])];
	}
	self.toolsInstrumentField = fields[0]; self.toolsInstrumentPopup = popups[0];
	self.toolsNoteField = fields[1]; self.toolsNotePopup = popups[1];
	self.toolsEffectField = fields[2]; self.toolsEffectPopup = popups[2];
	self.toolsArgumentField = fields[3]; self.toolsArgumentPopup = popups[3];
	self.toolsVolumeField = fields[4]; self.toolsVolumePopup = popups[4];

	for (NSDictionary *badgeInfo in @[@{@"text": @"A", @"y": @62}]) {
		NSTextField *badge = [NSTextField labelWithString:badgeInfo[@"text"]];
		badge.frame = NSMakeRect(39, [badgeInfo[@"y"] doubleValue], 12, 13);
		badge.font = [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightBold];
		badge.alignment = NSTextAlignmentCenter;
		badge.drawsBackground = YES;
		badge.backgroundColor = [NSColor colorWithCalibratedWhite:0.82 alpha:1.0];
		badge.bordered = YES;
		badge.textColor = NSColor.blackColor;
		[self.toolsCommandInspectorView addSubview:badge];
	}
	self.toolsEffectHelpButton = [NSButton buttonWithTitle:@"?" target:self action:@selector(toggleToolsEffectHelp:)];
	self.toolsEffectHelpButton.frame = NSMakeRect(38, 41, 14, 15);
	self.toolsEffectHelpButton.bezelStyle = NSBezelStyleSmallSquare;
	self.toolsEffectHelpButton.controlSize = NSControlSizeMini;
	self.toolsEffectHelpButton.font = [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightBold];
	self.toolsEffectHelpButton.focusRingType = NSFocusRingTypeNone;
	self.toolsEffectHelpButton.toolTip = @"Show help for the selected effect command";
	[self.toolsCommandInspectorView addSubview:self.toolsEffectHelpButton];

	NSArray<NSString *> *buttonImages = @[@"instrument-play", @"instrument-delete", @"sample-select"];
	NSArray<NSString *> *buttonTips = @[@"Audition this command", @"Delete this command",
		@"Apply modifications to all selected cells"];
	SEL buttonActions[] = {@selector(auditionToolsCommand:), @selector(deleteToolsCommand:),
		@selector(applyToolsCommandToSelection:)};
	for (NSInteger index = 0; index < 3; index++) {
		NSButton *button = [[PPClassicIconButton alloc] initWithFrame:NSMakeRect(9, 78 - index * 29, 24, 24)];
		button.bezelStyle = NSBezelStyleSmallSquare;
		button.image = [self classicImageNamed:buttonImages[index]];
		button.imagePosition = NSImageOnly;
		button.imageScaling = NSImageScaleProportionallyDown;
		button.focusRingType = NSFocusRingTypeNone;
		button.target = self;
		button.action = buttonActions[index];
		button.toolTip = buttonTips[index];
		[self.toolsCommandInspectorView addSubview:button];
	}
	// The original-style command editor grows below the compact transport. Keep
	// a small, persistent disclosure control in its otherwise unused lower-left
	// corner so returning to the transport-only window never requires reopening
	// the Digital editor or finding a menu command.
	PPClassicIconButton *collapseInspector = [[PPClassicIconButton alloc]
		initWithFrame:NSMakeRect(9, 2, 24, 15)];
	collapseInspector.title = @"▴";
	collapseInspector.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	collapseInspector.focusRingType = NSFocusRingTypeNone;
	collapseInspector.target = self;
	collapseInspector.action = @selector(collapseToolsCommandInspector:);
	collapseInspector.toolTip = @"Return Tools to compact transport mode";
	collapseInspector.accessibilityLabel = @"Collapse Tools command editor";
	[self.toolsCommandInspectorView addSubview:collapseInspector];

	self.toolsEffectHelpView = [[PPClassicToolsHelpView alloc] initWithFrame:NSMakeRect(183, 0, 287, 169)];
	self.toolsEffectHelpView.hidden = YES;
	[content addSubview:self.toolsEffectHelpView];
	self.toolsEffectHelpTitleField = [NSTextField labelWithString:@""];
	self.toolsEffectHelpTitleField.frame = NSMakeRect(7, 147, 273, 16);
	self.toolsEffectHelpTitleField.font = [NSFont fontWithName:@"Monaco-Bold" size:9] ?:
		[NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
	self.toolsEffectHelpTitleField.textColor = NSColor.blackColor;
	[self.toolsEffectHelpView addSubview:self.toolsEffectHelpTitleField];
	self.toolsEffectHelpBodyField = [NSTextField wrappingLabelWithString:@""];
	self.toolsEffectHelpBodyField.frame = NSMakeRect(7, 8, 273, 138);
	self.toolsEffectHelpBodyField.font = [NSFont fontWithName:@"Monaco" size:8] ?:
		[NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightRegular];
	self.toolsEffectHelpBodyField.textColor = NSColor.blackColor;
	self.toolsEffectHelpBodyField.maximumNumberOfLines = 0;
	self.toolsEffectHelpBodyField.lineBreakMode = NSLineBreakByWordWrapping;
	[self.toolsEffectHelpView addSubview:self.toolsEffectHelpBodyField];
	[self rebuildToolsCommandInspectorMenus];
	[self updateToolsCommandInspector];
	[self updateTransportButtonStates];
	[self.toolsWindow setFrameTopLeftPoint:NSMakePoint(NSMaxX(self.window.frame) - 183, NSMaxY(self.window.frame) + 58)];
}

- (void)setToolsCommandInspectorExpanded:(BOOL)expanded
{
	if (self.toolsWindow == nil || self.toolsCommandInspectorView == nil) return;
	_toolsCommandInspectorExpanded = expanded;
	if (!expanded) _toolsEffectHelpExpanded = NO;
	CGFloat inspectorHeight = expanded ? 121.0 : 0.0;
	CGFloat contentWidth = expanded && self.toolsEffectHelpExpanded ? 470.0 : 183.0;
	NSRect oldFrame = self.toolsWindow.frame;
	CGFloat top = NSMaxY(oldFrame);
	CGFloat left = NSMinX(oldFrame);
	[self.toolsWindow setContentSize:NSMakeSize(contentWidth, 48 + inspectorHeight)];
	NSRect frame = self.toolsWindow.frame;
	frame.origin.x = left;
	frame.origin.y = top - NSHeight(frame);
	[self.toolsWindow setFrame:frame display:YES animate:NO];
	self.toolsTransportView.frame = NSMakeRect(0, inspectorHeight, 183, 48);
	self.toolsCommandInspectorView.hidden = !expanded;
	self.toolsEffectHelpView.hidden = !(expanded && self.toolsEffectHelpExpanded);
	self.toolsEffectHelpView.frame = NSMakeRect(183, 0, 287, 48 + inspectorHeight);
	self.toolsEffectHelpButton.state = self.toolsEffectHelpExpanded ? NSControlStateValueOn : NSControlStateValueOff;
	if (expanded) {
		[self rebuildToolsCommandInspectorMenus];
		[self updateToolsCommandInspector];
	}
}

- (NSDictionary<NSString *, NSString *> *)toolsHelpForEffect:(MADEffectID)effect
{
	NSString *key = PPPatternEffectCharacter(effect);
	static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *help;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		help = @{
			@"0": @{@"title": @"Normal / Arpeggio", @"body": @"With argument 00, play the note normally. Otherwise x and y are semitone offsets: the player rapidly alternates between the base note, base+x, and base+y."},
			@"1": @{@"title": @"Slide up", @"body": @"Where [1][x][y] raises pitch by x*16+y period units after each tick. Argument 00 continues the previous slide rate."},
			@"2": @{@"title": @"Slide down", @"body": @"Where [2][x][y] lowers pitch by x*16+y period units after each tick. Argument 00 continues the previous slide rate."},
			@"3": @{@"title": @"Slide to note", @"body": @"Where [3][x][y] smoothly changes the current sample period by x*16+y after each tick, never sliding beyond the target period. The note in this channel supplies the destination. Unlike effects [1] and [2], the slide stops at that note. Argument 00 continues the previous slide rate."},
			@"4": @{@"title": @"Vibrato", @"body": @"Where [4][x][y] applies vibrato. x selects the oscillation speed and y selects its depth. A zero nibble reuses that part of the previous vibrato setting."},
			@"5": @{@"title": @"Slide to note + volume slide", @"body": @"Continues the previous slide-to-note while also changing volume. Use x0 to slide volume up by x, or 0y to slide it down by y."},
			@"6": @{@"title": @"Vibrato + volume slide", @"body": @"Continues the previous vibrato while also changing volume. Use x0 to slide volume up by x, or 0y to slide it down by y."},
			@"7": @{@"title": @"Tremolo", @"body": @"Where [7][x][y] varies volume periodically. x controls speed and y controls depth; zero values reuse the previous setting."},
			@"8": @{@"title": @"Set panning", @"body": @"Sets the channel position from left to right. 00 is hard left, 80 is center, and FF is hard right."},
			@"9": @{@"title": @"Set sample offset", @"body": @"Starts playback partway through the sample. The hexadecimal argument selects an offset in 256-byte blocks."},
			@"A": @{@"title": @"Volume slide", @"body": @"Use x0 to raise volume by x after each tick, or 0y to lower volume by y. Argument 00 continues the previous volume slide."},
			@"B": @{@"title": @"Position jump", @"body": @"Continues playback at the specified song-list position after the current row."},
			@"C": @{@"title": @"Set volume", @"body": @"Immediately sets channel volume. Tracker-compatible values normally range from 00 (silent) through 40 (full volume)."},
			@"D": @{@"title": @"Pattern break", @"body": @"Ends the current pattern and begins the next song position at the decimal row encoded by the two argument digits."},
			@"E": @{@"title": @"Extended commands", @"body": @"The high argument nibble chooses an extended command and the low nibble supplies its value. These include fine slides, waveform choices, note cut/delay, retrigger, and pattern delay."},
			@"F": @{@"title": @"Set speed / tempo", @"body": @"Values 01–1F set timing pulses per row. Values 20–FF set tempo in beats per minute. 00 has no timing effect."},
			@"G": @{@"title": @"Note off", @"body": @"Stops the active note on this channel. This command is intended for PlayerPRO multi-channel tracks."},
			@"L": @{@"title": @"Move loop", @"body": @"Moves or controls the current playback loop using the hexadecimal argument, following PlayerPRO’s native loop-command behavior."},
			@"O": @{@"title": @"Set sample offset in percent", @"body": @"Starts sample playback at a proportional position. 00 begins at the start and FF begins near the end of the sample."}
		};
	});
	return help[key] ?: @{@"title": @"Effect command", @"body": @"No help is available for this command."};
}

- (void)refreshToolsEffectHelp
{
	Cmd *command = [self selectedEditorCommand];
	MADEffectID effect = command == NULL ? self.defaultPatternEffect : command->cmd;
	NSDictionary<NSString *, NSString *> *entry = [self toolsHelpForEffect:effect];
	self.toolsEffectHelpTitleField.stringValue = entry[@"title"];
	self.toolsEffectHelpBodyField.stringValue = entry[@"body"];
}

- (IBAction)toggleToolsEffectHelp:(id)sender
{
	(void)sender;
	if (!self.toolsCommandInspectorExpanded) [self setToolsCommandInspectorExpanded:YES];
	_toolsEffectHelpExpanded = !self.toolsEffectHelpExpanded;
	[self refreshToolsEffectHelp];
	[self setToolsCommandInspectorExpanded:YES];
}

- (IBAction)collapseToolsCommandInspector:(id)sender
{
	(void)sender;
	[self setToolsCommandInspectorExpanded:NO];
	[self.window makeFirstResponder:self.patternTable];
	self.statusField.stringValue = @"Tools returned to compact transport mode";
}

- (PPHexPickerMenuView *)installOriginalHexPickerInPopup:(NSPopUpButton *)popup value:(NSInteger)value
	action:(SEL)action accessibilityLabel:(NSString *)accessibilityLabel
{
	if (popup == nil) return nil;
	[popup removeAllItems];
	[popup addItemWithTitle:@""];
	popup.lastItem.tag = -1;
	PPHexPickerMenuView *picker = [[PPHexPickerMenuView alloc] initWithValue:value target:self action:action];
	picker.accessibilityLabel = accessibilityLabel;
	NSMenuItem *pickerItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
	pickerItem.view = picker;
	pickerItem.enabled = YES;
	[popup.menu addItem:pickerItem];
	popup.menu.autoenablesItems = NO;
	return picker;
}

- (void)rebuildToolsCommandInspectorMenus
{
	if (self.toolsPatternPopup == nil) return;
	NSArray<NSPopUpButton *> *plainPopups = @[self.toolsPatternPopup, self.toolsTrackPopup,
		self.toolsInstrumentPopup, self.toolsNotePopup, self.toolsEffectPopup];
	for (NSPopUpButton *popup in plainPopups) {
		[popup removeAllItems];
		[popup addItemWithTitle:@""];
		popup.lastItem.tag = -1;
	}

	NSInteger patternCount = _music == NULL || _music->header == NULL ? 0 : _music->header->numPat;
	for (NSInteger pattern = 0; pattern < patternCount; pattern++) {
		if (_music->partition[pattern] == NULL) continue;
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Pattern %03ld", (long)pattern]
			action:@selector(chooseToolsPattern:) keyEquivalent:@""];
		item.target = self; item.tag = pattern;
		[self.toolsPatternPopup.menu addItem:item];
	}
	NSInteger tracks = _music == NULL || _music->header == NULL ? 0 : _music->header->numChn;
	for (NSInteger track = 0; track < tracks; track++) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Track %ld", (long)track + 1]
			action:@selector(chooseToolsTrack:) keyEquivalent:@""];
		item.target = self; item.tag = track;
		[self.toolsTrackPopup.menu addItem:item];
	}
	for (NSInteger instrument = 0; instrument <= 255; instrument++) {
		NSString *title = @"No Instrument";
		if (instrument > 0) {
			NSString *name = @"-";
			if (_music != NULL) {
				InstrData *data = &_music->fid[instrument - 1];
				name = [self stringFromLegacyBytes:data->name length:sizeof(data->name) fallback:@"-"];
			}
			title = [NSString stringWithFormat:@"%03ld %@", (long)instrument, name];
		}
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
			action:@selector(chooseToolsInstrument:) keyEquivalent:@""];
		item.target = self; item.tag = instrument;
		[self.toolsInstrumentPopup.menu addItem:item];
	}
	NSMenuItem *noNote = [[NSMenuItem alloc] initWithTitle:@"No Note" action:@selector(chooseToolsNote:) keyEquivalent:@""];
	noNote.target = self; noNote.tag = 0xFF;
	[self.toolsNotePopup.menu addItem:noNote];
	NSMenuItem *noteOff = [[NSMenuItem alloc] initWithTitle:@"OFF - Note Off" action:@selector(chooseToolsNote:) keyEquivalent:@""];
	noteOff.target = self; noteOff.tag = 0xFE;
	[self.toolsNotePopup.menu addItem:noteOff];
	[self.toolsNotePopup.menu addItem:NSMenuItem.separatorItem];
	for (NSInteger note = 0; note < NUMBER_NOTES; note++) {
		Cmd command = {0, (MADByte)note, 0, 0, 0xFF, 0};
		NSString *notation = [PPPatternStringForCommand(&command) substringWithRange:NSMakeRange(4, 3)];
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:notation action:@selector(chooseToolsNote:) keyEquivalent:@""];
		item.target = self; item.tag = note;
		[self.toolsNotePopup.menu addItem:item];
	}
	NSArray<NSString *> *effectTitles = PPPatternEffectMenuTitles();
	for (NSInteger effect = 0; effect < (NSInteger)effectTitles.count; effect++) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:effectTitles[effect]
			action:@selector(chooseToolsEffect:) keyEquivalent:@""];
		item.target = self; item.tag = effect;
		[self.toolsEffectPopup.menu addItem:item];
	}
	Cmd *selectedCommand = [self selectedEditorCommand];
	NSInteger argument = selectedCommand == NULL ? 0 : selectedCommand->arg;
	NSInteger volume = selectedCommand == NULL || selectedCommand->vol == 0xFF ? 0 : selectedCommand->vol;
	self.toolsArgumentHexPicker = [self installOriginalHexPickerInPopup:self.toolsArgumentPopup value:argument
		action:@selector(chooseToolsArgument:) accessibilityLabel:@"Pattern argument hexadecimal picker"];
	self.toolsVolumeHexPicker = [self installOriginalHexPickerInPopup:self.toolsVolumePopup value:volume
		action:@selector(chooseToolsVolume:) accessibilityLabel:@"Pattern volume hexadecimal picker"];
}

- (BOOL)setCheckedTag:(NSInteger)tag inMenu:(NSMenu *)menu
{
	BOOL found = NO;
	for (NSMenuItem *item in menu.itemArray) {
		BOOL childFound = item.submenu != nil && [self setCheckedTag:tag inMenu:item.submenu];
		BOOL matches = item.action != nil && item.submenu == nil && item.tag == tag;
		item.state = matches ? NSControlStateValueOn : NSControlStateValueOff;
		found = found || childFound || matches;
	}
	return found;
}

- (NSString *)toolsNoteString:(MADByte)note
{
	if (note == 0xFF) return @"000";
	if (note == 0xFE) return @"OFF";
	if (note >= NUMBER_NOTES) return @"???";
	Cmd command = {0, note, 0, 0, 0xFF, 0};
	return [PPPatternStringForCommand(&command) substringWithRange:NSMakeRange(4, 3)];
}

- (void)updateToolsCommandInspector
{
	if (self.toolsCommandInspectorView == nil) return;
	PatData *pattern = [self selectedPatternData];
	BOOL available = _music != NULL && _music->header != NULL && pattern != NULL && pattern->header.size > 0 &&
		_music->header->numChn > 0;
	for (NSControl *control in @[self.toolsPatternField, self.toolsPositionField, self.toolsTrackField,
		self.toolsInstrumentField, self.toolsNoteField, self.toolsEffectField,
		self.toolsArgumentField, self.toolsVolumeField, self.toolsPatternPopup, self.toolsTrackPopup,
		self.toolsInstrumentPopup, self.toolsNotePopup, self.toolsEffectPopup,
		self.toolsArgumentPopup, self.toolsVolumePopup]) control.enabled = available;
	if (!available) return;
	NSInteger row = MIN(MAX(self.patternCursorRow, 0), pattern->header.size - 1);
	NSInteger channel = MIN(MAX(self.patternCursorChannel, 0), (NSInteger)_music->header->numChn - 1);
	Cmd *command = GetMADCommand((short)row, (short)channel, pattern);
	if (command == NULL) return;
	self.toolsPatternField.stringValue = [NSString stringWithFormat:@"%ld", (long)_selectedPattern];
	self.toolsPositionField.stringValue = [NSString stringWithFormat:@"%ld", (long)row];
	self.toolsTrackField.stringValue = [NSString stringWithFormat:@"%ld", (long)channel + 1];
	self.toolsInstrumentField.stringValue = [NSString stringWithFormat:@"%03u", command->ins];
	self.toolsNoteField.stringValue = [self toolsNoteString:command->note];
	self.toolsEffectField.stringValue = PPPatternEffectCharacter(command->cmd);
	self.toolsArgumentField.stringValue = [NSString stringWithFormat:@"%02X", command->arg];
	self.toolsVolumeField.stringValue = command->vol == 0xFF ? @"00" : [NSString stringWithFormat:@"%02X", command->vol];
	self.toolsArgumentHexPicker.value = command->arg;
	self.toolsVolumeHexPicker.value = command->vol == 0xFF ? 0 : command->vol;
	[self setCheckedTag:_selectedPattern inMenu:self.toolsPatternPopup.menu];
	[self setCheckedTag:channel inMenu:self.toolsTrackPopup.menu];
	[self setCheckedTag:command->ins inMenu:self.toolsInstrumentPopup.menu];
	[self setCheckedTag:command->note inMenu:self.toolsNotePopup.menu];
	[self setCheckedTag:command->cmd inMenu:self.toolsEffectPopup.menu];
	if (self.toolsEffectHelpExpanded) [self refreshToolsEffectHelp];
}

- (void)changeToolsCommandField:(NSInteger)field value:(NSInteger)value actionName:(NSString *)actionName
{
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || pattern->header.size <= 0 || _music == NULL || _music->header == NULL ||
		_music->header->numChn <= 0) { NSBeep(); return; }
	NSInteger row = MIN(MAX(self.patternCursorRow, 0), pattern->header.size - 1);
	NSInteger channel = MIN(MAX(self.patternCursorChannel, 0), (NSInteger)_music->header->numChn - 1);
	Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
	if (command == NULL) return;
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd previous = *command;
	switch (field) {
		case 0: command->ins = (MADByte)MIN(MAX(value, 0), 255); break;
		case 1: command->note = (MADByte)MIN(MAX(value, 0), 255); break;
		case 2: command->cmd = (MADEffectID)MIN(MAX(value, 0), MADEffectNOffset); break;
		case 3: command->arg = (MADByte)MIN(MAX(value, 0), 255); break;
		case 4: command->vol = (MADByte)MIN(MAX(value, 0), 255); break;
		default: return;
	}
	self.patternField = field;
	[self finishDirectPatternChangeFrom:previous command:command snapshot:snapshot row:row channel:channel actionName:actionName];
	[self updateToolsCommandInspector];
}

- (void)rejectToolsCommandInspectorValue:(NSString *)message
{
	NSBeep();
	[self updateToolsCommandInspector];
	self.statusField.stringValue = message;
}

- (BOOL)scanToolsInteger:(NSString *)text value:(NSInteger *)value
{
	NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (trimmed.length == 0) return NO;
	NSScanner *scanner = [NSScanner scannerWithString:trimmed];
	scanner.charactersToBeSkipped = nil;
	NSInteger result = 0;
	if (![scanner scanInteger:&result] || !scanner.isAtEnd) return NO;
	if (value != NULL) *value = result;
	return YES;
}

- (BOOL)scanToolsHex:(NSString *)text value:(NSInteger *)value
{
	NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
	if (trimmed.length == 0 || trimmed.length > 2) return NO;
	NSScanner *scanner = [NSScanner scannerWithString:trimmed];
	scanner.charactersToBeSkipped = nil;
	unsigned int result = 0;
	if (![scanner scanHexInt:&result] || !scanner.isAtEnd || result > 0xFF) return NO;
	if (value != NULL) *value = result;
	return YES;
}

- (void)applyToolsCommandInspectorField:(NSTextField *)field
{
	if (_music == NULL || _music->header == NULL || field == nil) return;
	NSString *identifier = field.identifier ?: @"";
	NSInteger value = 0;
	if ([identifier isEqualToString:@"tools-pattern"]) {
		if (![self scanToolsInteger:field.stringValue value:&value] || value < 0 || value >= _music->header->numPat ||
			_music->partition[value] == NULL) {
			[self rejectToolsCommandInspectorValue:@"Pattern must identify an existing pattern"];
			return;
		}
		if (value != _selectedPattern) {
			NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
			item.tag = value;
			[self chooseToolsPattern:item];
		} else [self updateToolsCommandInspector];
		return;
	}
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL) return;
	if ([identifier isEqualToString:@"tools-position"]) {
		if (![self scanToolsInteger:field.stringValue value:&value] || value < 0 || value >= pattern->header.size) {
			[self rejectToolsCommandInspectorValue:[NSString stringWithFormat:@"Position must be between 0 and %d",
				MAX(pattern->header.size - 1, 0)]];
			return;
		}
		NSInteger channel = MIN(MAX(self.patternCursorChannel, 0), (NSInteger)_music->header->numChn - 1);
		[self selectPatternTop:value bottom:value left:channel right:channel];
		[self updateToolsCommandInspector];
		return;
	}
	if ([identifier isEqualToString:@"tools-track"]) {
		if (![self scanToolsInteger:field.stringValue value:&value] || value < 1 || value > _music->header->numChn) {
			[self rejectToolsCommandInspectorValue:[NSString stringWithFormat:@"Track must be between 1 and %u",
				_music->header->numChn]];
			return;
		}
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
		item.tag = value - 1;
		[self chooseToolsTrack:item];
		return;
	}

	Cmd *command = [self selectedEditorCommand];
	if (command == NULL) return;
	NSString *trimmed = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
	if ([identifier isEqualToString:@"tools-command-instrument"]) {
		NSString *current = [NSString stringWithFormat:@"%03u", command->ins];
		if ([trimmed isEqualToString:current]) return;
		if ([trimmed isEqualToString:@"---"] || [trimmed isEqualToString:@"NO INS"] || trimmed.length == 0) value = 0;
		else if (![self scanToolsInteger:trimmed value:&value] || value < 0 || value > 255) {
			[self rejectToolsCommandInspectorValue:@"Instrument must be No Ins or 000…255"];
			return;
		}
		[self changeToolsCommandField:0 value:value actionName:@"Edit Pattern Instrument"];
		return;
	}
	if ([identifier isEqualToString:@"tools-command-note"]) {
		if ([trimmed isEqualToString:[self toolsNoteString:command->note]]) return;
		if (trimmed.length == 0 || [trimmed isEqualToString:@"000"] || [trimmed isEqualToString:@"---"] ||
			[trimmed isEqualToString:@"NO NOTE"]) value = 0xFF;
		else if ([trimmed isEqualToString:@"OFF"]) value = 0xFE;
		else {
			NSString *notation = [trimmed stringByReplacingOccurrencesOfString:@" " withString:@"-"];
			if (notation.length == 2 && [[NSCharacterSet letterCharacterSet] characterIsMember:[notation characterAtIndex:0]]) {
				notation = [NSString stringWithFormat:@"%@-%@", [notation substringToIndex:1], [notation substringFromIndex:1]];
			}
			Cmd parsed = {0};
			if (!PPPatternParseCommandString([NSString stringWithFormat:@"000 %@ 0 00 --", notation], &parsed)) {
				[self rejectToolsCommandInspectorValue:@"Note must use tracker notation such as C-4, C#4, OFF, or 000"];
				return;
			}
			value = parsed.note;
		}
		[self changeToolsCommandField:1 value:value actionName:@"Edit Pattern Note"];
		return;
	}
	if ([identifier isEqualToString:@"tools-command-effect"]) {
		if ([trimmed isEqualToString:PPPatternEffectCharacter(command->cmd)]) return;
		Cmd parsed = {0};
		if (!PPPatternParseCommandString([NSString stringWithFormat:@"000 --- %@ 00 --", trimmed], &parsed)) {
			[self rejectToolsCommandInspectorValue:@"Effect must be 0–F, G, L, or O"];
			return;
		}
		[self changeToolsCommandField:2 value:parsed.cmd actionName:@"Edit Pattern Effect"];
		return;
	}
	if ([identifier isEqualToString:@"tools-command-argument"]) {
		if ([trimmed isEqualToString:[NSString stringWithFormat:@"%02X", command->arg]]) return;
		if (![self scanToolsHex:trimmed value:&value]) {
			[self rejectToolsCommandInspectorValue:@"Argument must be a hexadecimal value from 00 to FF"];
			return;
		}
		[self changeToolsCommandField:3 value:value actionName:@"Edit Pattern Argument"];
		return;
	}
	if ([identifier isEqualToString:@"tools-command-volume"]) {
		NSString *current = command->vol == 0xFF ? @"00" : [NSString stringWithFormat:@"%02X", command->vol];
		if ([trimmed isEqualToString:current]) return;
		if (trimmed.length == 0 || [trimmed isEqualToString:@"--"] || [trimmed isEqualToString:@"NO VOL"] ||
			[trimmed isEqualToString:@"NO VOLUME"]) value = 0xFF;
		else if (![self scanToolsHex:trimmed value:&value]) {
			[self rejectToolsCommandInspectorValue:@"Volume must be No Volume or a hexadecimal value from 00 to FF"];
			return;
		}
		if (value == 0) value = 0xFF;
		[self changeToolsCommandField:4 value:value actionName:@"Edit Pattern Volume"];
	}
}

- (NSInteger)hexPickerValueFromSender:(id)sender
{
	if ([sender isKindOfClass:PPHexPickerMenuView.class]) return ((PPHexPickerMenuView *)sender).value;
	return [sender respondsToSelector:@selector(tag)] ? [sender tag] : 0;
}

- (IBAction)chooseToolsInstrument:(NSMenuItem *)sender
{
	[self changeToolsCommandField:0 value:sender.tag actionName:@"Edit Pattern Instrument"];
}

- (IBAction)chooseToolsNote:(NSMenuItem *)sender
{
	[self changeToolsCommandField:1 value:sender.tag actionName:@"Edit Pattern Note"];
}

- (IBAction)chooseToolsEffect:(NSMenuItem *)sender
{
	[self changeToolsCommandField:2 value:sender.tag actionName:@"Edit Pattern Effect"];
}

- (IBAction)chooseToolsArgument:(id)sender
{
	[self changeToolsCommandField:3 value:[self hexPickerValueFromSender:sender] actionName:@"Edit Pattern Argument"];
}

- (IBAction)chooseToolsVolume:(id)sender
{
	NSInteger value = [self hexPickerValueFromSender:sender];
	// PlayerPRO's Tools inspector represents an absent volume command as 00.
	// Preserve that workflow even though modern Cmd storage uses 0xFF.
	[self changeToolsCommandField:4 value:value == 0 ? 0xFF : value actionName:@"Edit Pattern Volume"];
}

- (IBAction)chooseToolsPattern:(NSMenuItem *)sender
{
	if (_music == NULL || _music->header == NULL || sender.tag < 0 || sender.tag >= _music->header->numPat ||
		_music->partition[sender.tag] == NULL) { NSBeep(); return; }
	NSInteger row = self.patternCursorRow;
	NSInteger channel = self.patternCursorChannel;
	_selectedPattern = sender.tag;
	self.suppressPatternSelectionTransportReset = YES;
	[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:_selectedPattern] byExtendingSelection:NO];
	[self.orderTable scrollRowToVisible:_selectedPattern];
	self.suppressPatternSelectionTransportReset = NO;
	[self resetTransportToSelectedPatternPreservingPlayback:YES];
	[self.patternTable reloadData];
	PatData *pattern = [self selectedPatternData];
	[self selectPatternTop:MIN(MAX(row, 0), pattern->header.size - 1)
		bottom:MIN(MAX(row, 0), pattern->header.size - 1)
		left:MIN(MAX(channel, 0), (NSInteger)_music->header->numChn - 1)
		right:MIN(MAX(channel, 0), (NSInteger)_music->header->numChn - 1)];
	[self updatePatternWindowTitle];
	[self updateToolsCommandInspector];
}

- (IBAction)chooseToolsTrack:(NSMenuItem *)sender
{
	if (_music == NULL || sender.tag < 0 || sender.tag >= _music->header->numChn) { NSBeep(); return; }
	NSInteger row = MIN(MAX(self.patternCursorRow, 0), [self selectedPatternData]->header.size - 1);
	[self selectPatternTop:row bottom:row left:sender.tag right:sender.tag];
	[self updateToolsCommandInspector];
}

- (IBAction)auditionToolsCommand:(id)sender
{
	(void)sender;
	Cmd *command = [self selectedEditorCommand];
	if (_music == NULL || _driver == NULL || command == NULL) { NSBeep(); return; }
	NSInteger instrumentIndex = command->ins > 0 ? command->ins - 1 : _selectedInstrument;
	NSInteger note = command->note < NUMBER_NOTES ? command->note : 48;
	if (instrumentIndex < 0 || instrumentIndex >= MAXINSTRU) { NSBeep(); return; }
	InstrData *instrument = &_music->fid[instrumentIndex];
	if (instrument->numSamples <= 0) { NSBeep(); return; }
	NSInteger sampleIndex = instrument->what[MIN(MAX(note, 0), NUMBER_NOTES - 1)];
	if (sampleIndex < 0 || sampleIndex >= instrument->numSamples) sampleIndex = 0;
	sData *sample = _music->sample[instrument->firstSample + sampleIndex];
	if (sample == NULL || sample->data == NULL || sample->size <= 2) { NSBeep(); return; }
	if (![self.pianoController auditionNote:note velocity:127 instrument:instrumentIndex
		track:MAX(self.patternCursorChannel, 0)]) {
		NSBeep();
		return;
	}
	self.statusField.stringValue = [NSString stringWithFormat:@"Auditioning pattern %03ld row %03ld track %02ld",
		(long)_selectedPattern, (long)self.patternCursorRow, (long)self.patternCursorChannel + 1];
}

- (IBAction)deleteToolsCommand:(id)sender
{
	(void)sender;
	NSInteger row, channel;
	if (![self singlePatternCellSelectedAtRow:&row channel:&channel]) { NSBeep(); return; }
	Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
	if (command == NULL) return;
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd previous = *command;
	*command = (Cmd){0, 0xFF, MADEffectArpeggio, 0, 0xFF, 0};
	[self finishDirectPatternChangeFrom:previous command:command snapshot:snapshot row:row channel:channel actionName:@"Delete Pattern Command"];
	[self updateToolsCommandInspector];
}

- (IBAction)applyToolsCommandToSelection:(id)sender
{
	(void)sender;
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) { NSBeep(); return; }
	Cmd *sourceCommand = [self selectedEditorCommand];
	PatData *pattern = [self selectedPatternData];
	if (sourceCommand == NULL || pattern == NULL) { NSBeep(); return; }
	Cmd source = *sourceCommand;
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	NSInteger changed = 0;
	for (NSInteger channel = left; channel <= right; channel++) {
		for (NSInteger row = top; row <= bottom; row++) {
			Cmd *destination = GetMADCommand((short)row, (short)channel, pattern);
			if (destination == NULL || memcmp(destination, &source, sizeof(source)) == 0) continue;
			*destination = source;
			changed++;
		}
	}
	if (changed == 0) {
		self.statusField.stringValue = @"Selected cells already contain these modifications";
		return;
	}
	[self registerPatternUndoSnapshot:snapshot actionName:@"Apply Tools Modifications"];
	_music->hasChanged = true;
	[self.patternTable reloadData];
	[self updateToolsCommandInspector];
	self.statusField.stringValue = [NSString stringWithFormat:@"Applied Tools modifications to %ld selected cells",
		(long)changed];
}

- (NSButton *)musicListButtonAtX:(CGFloat)x title:(NSString *)title image:(NSString *)imageName
	action:(SEL)action toolTip:(NSString *)toolTip inView:(NSView *)view
{
	NSButton *button = imageName.length > 0
		? [NSButton buttonWithImage:[self classicImageNamed:imageName] target:self action:action]
		: [NSButton buttonWithTitle:title target:self action:action];
	button.frame = NSMakeRect(x, 8, 20, 20);
	button.bezelStyle = NSBezelStyleSmallSquare;
	button.imageScaling = NSImageScaleProportionallyDown;
	button.focusRingType = NSFocusRingTypeNone;
	button.font = [self classicFont];
	button.toolTip = toolTip;
	[view addSubview:button];
	return button;
}

- (void)buildMusicListWindow
{
	// DLOG 142 opened at 200 points wide and used 20-point list cells.
	self.musicListWindow = [self classicPanelWithSize:NSMakeSize(200, 300) title:@"Untitled Music List"];
	self.musicListWindow.minSize = NSMakeSize(180, 160);
	NSView *view = self.musicListWindow.contentView;
	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 264, 200, 36)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[view addSubview:strip];
	[self musicListButtonAtX:5 title:@"A↕" image:nil action:@selector(sortMusicList:)
		toolTip:@"Alphabetize the Music List" inView:strip];
	[self musicListButtonAtX:33 title:nil image:@"info" action:@selector(showMusicListEntryInformation:)
		toolTip:@"Information about the selected music file" inView:strip];
	[self musicListButtonAtX:61 title:nil image:@"instrument-delete" action:@selector(removeMusicListEntries:)
		toolTip:@"Remove the selected file from the Music List" inView:strip];
	[self musicListButtonAtX:89 title:@"?" image:nil action:@selector(showMusicListHelp:)
		toolTip:@"Music List help" inView:strip];
	[self musicListButtonAtX:117 title:nil image:@"instrument-open" action:@selector(loadSelectedMusicListEntry:)
		toolTip:@"Open the selected music file" inView:strip];
	[self musicListButtonAtX:145 title:nil image:@"instrument-record" action:@selector(addMusicFiles:)
		toolTip:@"Add music files" inView:strip];

	NSPopUpButton *behavior = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(173, 6, 23, 22) pullsDown:YES];
	self.musicListPlaybackPopup = behavior;
	behavior.font = [self classicFont];
	behavior.controlSize = NSControlSizeMini;
	behavior.focusRingType = NSFocusRingTypeNone;
	behavior.toolTip = @"What to do when a music file ends";
	[behavior addItemWithTitle:@""];
	NSArray<NSString *> *behaviorTitles = @[@"Stop Playing", @"Load Next Music", @"Shuffle Music List", @"Loop Current Music"];
	for (NSInteger index = 0; index < (NSInteger)behaviorTitles.count; index++) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:behaviorTitles[index]
			action:@selector(changeMusicListPlaybackMode:) keyEquivalent:@""];
		item.target = self;
		item.tag = index;
		item.state = index == self.musicListPlaybackMode ? NSControlStateValueOn : NSControlStateValueOff;
		[behavior.menu addItem:item];
	}
	[strip addSubview:behavior];

	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 16, 200, 248)];
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = NO;
	scroll.scrollerStyle = NSScrollerStyleLegacy;
	scroll.borderType = NSBezelBorder;
	self.musicListTable = [[PPMusicListTableView alloc] initWithFrame:NSZeroRect];
	self.musicListTable.identifier = @"music-list";
	self.musicListTable.dataSource = self;
	self.musicListTable.delegate = self;
	self.musicListTable.target = self;
	self.musicListTable.doubleAction = @selector(loadSelectedMusicListEntry:);
	self.musicListTable.rowHeight = 20;
	self.musicListTable.intercellSpacing = NSMakeSize(0, 0);
	self.musicListTable.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
	self.musicListTable.gridColor = [NSColor colorWithCalibratedWhite:0.78 alpha:1.0];
	self.musicListTable.allowsMultipleSelection = YES;
	self.musicListTable.headerView = nil;
	self.musicListTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"music-list"];
	column.width = 197;
	column.resizingMask = NSTableColumnAutoresizingMask;
	[self.musicListTable addTableColumn:column];
	[self.musicListTable registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
	scroll.documentView = self.musicListTable;
	[view addSubview:scroll];

	self.musicListSummaryField = [NSTextField labelWithString:@"Number of music files: 0"];
	self.musicListSummaryField.frame = NSMakeRect(6, 1, 188, 14);
	self.musicListSummaryField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	self.musicListSummaryField.font = [self classicFont];
	[view addSubview:self.musicListSummaryField];
	[self.musicListWindow setFrameTopLeftPoint:NSMakePoint(NSMinX(self.window.frame) - 205, NSMaxY(self.window.frame) - 54)];
}

- (NSTableView *)classicListWithIdentifier:(NSString *)identifier title:(NSString *)title width:(CGFloat)width
{
	NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
	table.identifier = identifier; table.dataSource = self; table.delegate = self;
	table.rowHeight = 13; table.intercellSpacing = NSMakeSize(0, 0);
	table.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
	table.gridColor = [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
	column.title = title; column.width = width;
	[table addTableColumn:column];
	return table;
}

- (void)buildPatternsWindow
{
	self.patternsWindow = [self classicPanelWithSize:NSMakeSize(223, 280) title:@"Patterns List"];
	self.patternsWindow.delegate = self;
	NSView *view = self.patternsWindow.contentView;
	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 244, 223, 36)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[view addSubview:strip];
	NSArray<NSString *> *images = @[@"instrument-record", @"instrument-load", @"instrument-save",
		@"instrument-delete", @"info", @"instrument-open"];
	// Pattern.c resources 154, 152, 151, 150, 149 and 159 respectively.
	NSArray<NSString *> *actions = @[@"newPattern:", @"loadPatternFile:", @"savePatternFile:",
		@"deletePattern:", @"editPatternInformation:", @"openPreferredPatternEditor:"];
	NSArray<NSString *> *tips = @[@"New 64-row pattern", @"Load a pattern file", @"Save the selected pattern",
		@"Delete the selected pattern", @"Pattern information", @"Open in the preferred pattern editor"];
	for (NSUInteger i = 0; i < images.count; i++) {
		[self classicListToolbarButtonAtX:11 + i * 30 y:8 image:images[i]
			action:NSSelectorFromString(actions[i]) toolTip:tips[i] inView:strip];
	}
	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 223, 244)];
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
	self.orderTable = [self classicListWithIdentifier:@"order" title:@" ID       Size          Name" width:220];
	self.orderTable.target = self;
	self.orderTable.doubleAction = @selector(openPreferredPatternEditor:);
	scroll.documentView = self.orderTable; [view addSubview:scroll];
	[self.patternsWindow setFrameTopLeftPoint:NSMakePoint(NSMaxX(self.window.frame) - 223, NSMaxY(self.window.frame) - 54)];
}

- (void)buildPartitionWindow
{
	self.partitionInspectorExpanded = NO;
	self.partitionWindow = [self classicPanelWithSize:NSMakeSize(PPPartitionCompactWidth, 440) title:@"Partition"];
	self.partitionWindow.delegate = self;
	self.partitionWindow.contentMinSize = NSMakeSize(PPPartitionCompactWidth, 180);
	self.partitionWindow.contentMaxSize = NSMakeSize(PPPartitionExpandedWidth, CGFLOAT_MAX);
	self.partitionWindow.backgroundColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
	self.partitionWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
	NSView *view = self.partitionWindow.contentView;
	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 413, PPPartitionCompactWidth, 27)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[view addSubview:strip];
	[self classicListToolbarButtonAtX:6 y:3 image:@"partition-remove"
		action:@selector(removePartitionPosition:) toolTip:@"Remove sequence position" inView:strip];
	[self classicListToolbarButtonAtX:29 y:3 image:@"partition-add"
		action:@selector(insertPartitionPosition:) toolTip:@"Insert sequence position" inView:strip];
	[self classicListToolbarButtonAtX:52 y:3 image:@"info"
		action:@selector(editSelectedPartitionPatternInformation:)
		toolTip:@"Information for the selected pattern" inView:strip];
	self.partitionWidthButton = [[PPPartitionWidthToggleButton alloc]
		initWithFrame:NSMakeRect(76, 3, 16, 20)];
	self.partitionWidthButton.bordered = NO;
	self.partitionWidthButton.focusRingType = NSFocusRingTypeNone;
	self.partitionWidthButton.refusesFirstResponder = YES;
	self.partitionWidthButton.target = self;
	self.partitionWidthButton.action = @selector(togglePartitionInspector:);
	self.partitionWidthButton.toolTip = @"Show pattern names";
	[strip addSubview:self.partitionWidthButton];
	NSBox *toolbarRule = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, PPPartitionCompactWidth, 1)];
	toolbarRule.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	toolbarRule.boxType = NSBoxSeparator;
	[strip addSubview:toolbarRule];

	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 16,
		PPPartitionCompactWidth, 397)];
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = NO;
	scroll.scrollerStyle = NSScrollerStyleLegacy;
	scroll.borderType = NSBezelBorder;
	self.partitionTable = [self classicListWithIdentifier:@"partition" title:@"" width:197];
	self.partitionTable.tableColumns.firstObject.minWidth = PPPartitionCompactColumnWidth;
	self.partitionTable.tableColumns.firstObject.maxWidth = PPPartitionExpandedColumnWidth;
	self.partitionTable.tableColumns.firstObject.width = PPPartitionCompactColumnWidth;
	PPPartitionHeaderCell *partitionHeader = [[PPPartitionHeaderCell alloc] initTextCell:@""];
	partitionHeader.showsName = NO;
	self.partitionTable.tableColumns.firstObject.headerCell = partitionHeader;
	self.partitionTable.gridStyleMask = NSTableViewGridNone;
	self.partitionTable.backgroundColor = NSColor.whiteColor;
	self.partitionTable.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
	self.partitionTable.target = self;
	NSMenu *partitionMenu = [[NSMenu alloc] initWithTitle:@"Partition"];
	NSArray<NSDictionary<NSString *, NSString *> *> *menuActions = @[
		@{@"title": @"Insert Position", @"action": NSStringFromSelector(@selector(insertPartitionPosition:))},
		@{@"title": @"Remove Position", @"action": NSStringFromSelector(@selector(removePartitionPosition:))},
		@{@"title": @"-", @"action": @""},
		@{@"title": @"Move Position Up", @"action": NSStringFromSelector(@selector(movePartitionPositionUp:))},
		@{@"title": @"Move Position Down", @"action": NSStringFromSelector(@selector(movePartitionPositionDown:))},
		@{@"title": @"-", @"action": @""},
		@{@"title": @"Pattern Information…", @"action": NSStringFromSelector(@selector(editSelectedPartitionPatternInformation:))}
	];
	for (NSDictionary<NSString *, NSString *> *definition in menuActions) {
		if ([definition[@"title"] isEqualToString:@"-"]) {
			[partitionMenu addItem:NSMenuItem.separatorItem];
			continue;
		}
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:definition[@"title"]
			action:NSSelectorFromString(definition[@"action"]) keyEquivalent:@""];
		item.target = self;
		[partitionMenu addItem:item];
	}
	self.partitionTable.menu = partitionMenu;
	scroll.documentView = self.partitionTable;
	[view addSubview:scroll];
	CGFloat partitionHeaderHeight = NSHeight(self.partitionTable.headerView.frame);
	if (partitionHeaderHeight <= 0.0) partitionHeaderHeight = 17.0;
	self.partitionHeaderOverlay = [[PPPartitionHeaderOverlayView alloc] initWithFrame:
		NSMakeRect(0, NSMaxY(scroll.frame) - partitionHeaderHeight,
			NSWidth(view.bounds), partitionHeaderHeight)];
	self.partitionHeaderOverlay.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	self.partitionHeaderOverlay.showsName = NO;
	[view addSubview:self.partitionHeaderOverlay];

	self.partitionLengthField = [[NSTextField alloc] initWithFrame:
		NSMakeRect(0, 0, PPPartitionCompactWidth - 15.0, 16)];
	self.partitionLengthField.stringValue = @"Length : 1";
	self.partitionLengthField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	self.partitionLengthField.font = [self classicFont];
	self.partitionLengthField.editable = NO;
	self.partitionLengthField.selectable = NO;
	self.partitionLengthField.bezeled = NO;
	self.partitionLengthField.bordered = YES;
	self.partitionLengthField.drawsBackground = YES;
	self.partitionLengthField.backgroundColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
	self.partitionLengthField.textColor = NSColor.blackColor;
	[view addSubview:self.partitionLengthField];
	PPClassicGrowBoxView *growBox = [[PPClassicGrowBoxView alloc] initWithFrame:
		NSMakeRect(PPPartitionCompactWidth - 15.0, 0, 15, 16)];
	growBox.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
	[view addSubview:growBox];
	[self.partitionWindow setFrameTopLeftPoint:NSMakePoint(NSMinX(self.window.frame) - 104, NSMaxY(self.window.frame) - 54)];
}

- (void)buildInstrumentsWindow
{
	// The original window toggled between a 200-point compact list and a
	// 300-point list plus information pane.  The modern titlebar adds twelve
	// content points to the compact recreation, so retain the original 100-point
	// disclosure delta: 212 compact, 312 expanded.
	self.instrumentInspectorExpanded = NO;
	self.instrumentsWindow = [self classicPanelWithSize:
		NSMakeSize(PPInstrumentListCompactWidth, 350) title:@"Instruments List"];
	self.instrumentsWindow.minSize = NSMakeSize(180, 180);
	NSView *view = self.instrumentsWindow.contentView;
	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 314, 212, 36)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[view addSubview:strip];
	NSArray<NSString *> *images = @[@"instrument-load", @"instrument-save", @"instrument-delete",
		@"instrument-record", @"instrument-open", @"instrument-play"];
	NSArray<NSString *> *actions = @[@"loadSample:", @"exportSelectedSample:", @"deleteSelectedInstrumentOrSample:",
		@"", @"openSelectedInstrumentOrSample:", @"previewSelectedSample:"];
	NSArray<NSString *> *tips = @[@"Load or replace sample", @"Save sample", @"Delete instrument or sample",
		@"Create or import an instrument or sample", @"Open selected instrument or sample",
		@"Preview selected sample"];
	for (NSUInteger i = 0; i < images.count; i++) {
		if (i == 3) {
			PPClassicIconButton *newMenu = [self classicListToolbarButtonAtX:9 + i * 30 y:8
				image:images[i] action:@selector(showClassicToolbarMenu:) toolTip:tips[i] inView:strip];
			NSMenu *menu = [[NSMenu alloc] initWithTitle:@"New Instrument or Sample"];
			NSArray<NSDictionary *> *newActions = @[
				@{@"title": @"Import a File…", @"action": NSStringFromSelector(@selector(loadSample:))},
				@{@"title": @"Silence/Tone Generator", @"action": NSStringFromSelector(@selector(createSilentSample:))},
				@{@"title": @"Record (Audio Input)", @"action": NSStringFromSelector(@selector(recordSample:))},
				@{@"title": @"Quicktime Instrument", @"action": @""},
				@{@"title": @"RAW Data Import…", @"action": NSStringFromSelector(@selector(importRawSample:))},
				@{@"title": @"Audio CD Import…", @"action": @""},
				@{@"title": @"Selection in Digital Editor…", @"action": @""}
			];
			for (NSDictionary *definition in newActions) {
				NSString *actionName = definition[@"action"];
				NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:definition[@"title"]
					action:actionName.length > 0 ? NSSelectorFromString(actionName) : nil keyEquivalent:@""];
				item.target = actionName.length > 0 ? self : nil;
				item.enabled = actionName.length > 0;
				[menu addItem:item];
			}
			newMenu.menu = menu;
			newMenu.accessibilityLabel = @"New instrument or sample menu";
			continue;
		}
		[self classicListToolbarButtonAtX:9 + i * 30 y:8 image:images[i]
			action:NSSelectorFromString(actions[i]) toolTip:tips[i] inView:strip];
	}
	self.instrumentInspectorButton = [[PPInstrumentInspectorToggleButton alloc]
		initWithFrame:NSMakeRect(190, 8, 18, 20)];
	self.instrumentInspectorButton.bordered = NO;
	self.instrumentInspectorButton.focusRingType = NSFocusRingTypeNone;
	self.instrumentInspectorButton.refusesFirstResponder = YES;
	self.instrumentInspectorButton.target = self;
	self.instrumentInspectorButton.action = @selector(toggleInstrumentInspector:);
	self.instrumentInspectorButton.toolTip = @"Show instrument and sample information";
	[strip addSubview:self.instrumentInspectorButton];

	self.instrumentScrollView = [[NSScrollView alloc]
		initWithFrame:NSMakeRect(0, 18, PPInstrumentListCompactWidth, 296)];
	NSScrollView *scroll = self.instrumentScrollView;
	scroll.autoresizingMask = NSViewHeightSizable;
	scroll.hasVerticalScroller = YES;
	scroll.autohidesScrollers = NO;
	scroll.scrollerStyle = NSScrollerStyleLegacy;
	scroll.borderType = NSBezelBorder;
	self.instrumentTable = [self classicListWithIdentifier:@"instrument" title:@"" width:195];
	self.instrumentTable.headerView = nil;
	self.instrumentTable.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
	self.instrumentTable.tableColumns.firstObject.resizingMask = NSTableColumnAutoresizingMask;
	self.instrumentTable.gridColor = NSColor.blackColor;
	self.instrumentTable.backgroundColor = NSColor.whiteColor;
	self.instrumentTable.target = self;
	self.instrumentTable.doubleAction = @selector(openSelectedInstrumentOrSample:);
	scroll.documentView = self.instrumentTable; [view addSubview:scroll];

	self.instrumentDetailView = [[PPInstrumentDetailView alloc] initWithFrame:
		NSMakeRect(PPInstrumentListCompactWidth, 18,
			PPInstrumentListExpandedWidth - PPInstrumentListCompactWidth, 296)];
	self.instrumentDetailView.autoresizingMask = NSViewHeightSizable;
	self.instrumentDetailView.hidden = YES;
	[view addSubview:self.instrumentDetailView];
	NSFont *detailFont = [self classicFont];
	NSTextField *(^detailField)(NSString *, NSRect, NSTextAlignment) =
		^NSTextField *(NSString *text, NSRect frame, NSTextAlignment alignment) {
			NSTextField *field = [NSTextField labelWithString:text];
			field.frame = frame;
			field.font = detailFont;
			field.textColor = NSColor.blackColor;
			field.alignment = alignment;
			field.lineBreakMode = NSLineBreakByClipping;
			[self.instrumentDetailView addSubview:field];
			return field;
		};
	NSArray<NSString *> *detailLabels = @[@"Instrument:", @"No samples:", @"Size:", @"Loop:",
		@"Start:", @"Size:", @"Volume:", @"Rate:", @"Real Note:", @"Bits:", @"Mode:"];
	NSArray<NSNumber *> *detailRows = @[@6, @25, @56, @75, @94, @113, @132, @151, @170, @189, @208];
	for (NSInteger index = 0; index < (NSInteger)detailLabels.count; index++) {
		BOOL indented = index == 4 || index == 5;
		detailField(detailLabels[index], NSMakeRect(indented ? 17 : 7,
			detailRows[index].doubleValue, indented ? 45 : 59, 15), NSTextAlignmentLeft);
	}
	NSMutableArray<NSTextField *> *detailValues = [NSMutableArray array];
	for (NSNumber *row in @[@6, @25, @56, @94, @113, @132, @151, @170, @189, @208]) {
		NSTextField *field = detailField(@"-", NSMakeRect(65, row.doubleValue, 33, 15),
			NSTextAlignmentLeft);
		[detailValues addObject:field];
	}
	self.instrumentDetailValues = detailValues;
	self.instrumentSummaryField = [NSTextField labelWithString:@"0 b, #ins: 0, #samples: 0"];
	self.instrumentSummaryField.frame = NSMakeRect(6, 1, 202, 15);
	self.instrumentSummaryField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	self.instrumentSummaryField.font = [self classicFont];
	self.instrumentSummaryField.lineBreakMode = NSLineBreakByClipping;
	[view addSubview:self.instrumentSummaryField];
	[self.instrumentsWindow setFrameTopLeftPoint:NSMakePoint(NSMinX(self.window.frame) + 8, NSMaxY(self.window.frame) - 54)];
}

#pragma mark - Music List

- (void)persistRememberedMusicList
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if (![defaults boolForKey:PPMusicListRememberDefaultsKey]) {
		[defaults removeObjectForKey:PPMusicListSavedPathsDefaultsKey];
		return;
	}
	NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:self.musicListEntries.count];
	for (NSURL *URL in self.musicListEntries) {
		if (URL.isFileURL) [paths addObject:URL.path];
	}
	[defaults setObject:paths forKey:PPMusicListSavedPathsDefaultsKey];
}

- (void)updateMusicListSummary
{
	self.musicListSummaryField.stringValue = [NSString stringWithFormat:@"Number of music files: %ld",
		(long)self.musicListEntries.count];
}

- (NSInteger)musicListIndexForURL:(NSURL *)URL
{
	if (URL == nil) return NSNotFound;
	NSURL *wanted = URL.URLByStandardizingPath;
	for (NSInteger index = 0; index < (NSInteger)self.musicListEntries.count; index++) {
		if ([self.musicListEntries[index].URLByStandardizingPath isEqual:wanted]) return index;
	}
	return NSNotFound;
}

- (void)addURLsToMusicList:(NSArray<NSURL *> *)URLs atIndex:(NSInteger)index
{
	NSMutableArray<NSURL *> *files = [NSMutableArray array];
	for (NSURL *URL in URLs) {
		if (URL.isFileURL && !URL.hasDirectoryPath) [files addObject:URL.URLByStandardizingPath];
	}
	if (files.count == 0) return;
	NSInteger insertion = MIN(MAX(index, 0), (NSInteger)self.musicListEntries.count);
	NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertion, files.count)];
	[self.musicListEntries insertObjects:files atIndexes:indexes];
	[self.musicListTable reloadData];
	[self.musicListTable selectRowIndexes:indexes byExtendingSelection:NO];
	[self.musicListTable scrollRowToVisible:insertion];
	[self updateMusicListSummary];
	self.musicListWindow.title = self.musicListURL == nil ? @"Untitled Music List" : self.musicListURL.lastPathComponent;
	[self persistRememberedMusicList];
}

- (IBAction)showMusicList:(id)sender
{
	(void)sender;
	[self.musicListTable reloadData];
	[self updateMusicListSummary];
	[self.musicListWindow makeKeyAndOrderFront:nil];
	[self.musicListWindow makeFirstResponder:self.musicListTable];
}

- (IBAction)addMusicFiles:(id)sender
{
	(void)sender;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowsMultipleSelection = YES;
	panel.canChooseDirectories = NO;
	panel.message = @"Add tracker music files, or open a saved MachoPlayer Music List";
	[panel beginSheetModalForWindow:self.musicListWindow completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		if (panel.URLs.count == 1 && [panel.URL.pathExtension.lowercaseString isEqualToString:@"mplaylist"]) {
			[self readMusicListAtURL:panel.URL];
		} else {
			[self addURLsToMusicList:panel.URLs atIndex:self.musicListEntries.count];
		}
	}];
}

- (IBAction)sortMusicList:(id)sender
{
	(void)sender;
	NSURL *activeURL = self.musicListActiveIndex >= 0 && self.musicListActiveIndex < (NSInteger)self.musicListEntries.count
		? self.musicListEntries[self.musicListActiveIndex] : self.documentURL;
	[self.musicListEntries sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
		return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
	}];
	self.musicListActiveIndex = [self musicListIndexForURL:activeURL];
	[self.musicListTable reloadData];
	if (self.musicListActiveIndex != NSNotFound) {
		[self.musicListTable selectRowIndexes:[NSIndexSet indexSetWithIndex:self.musicListActiveIndex]
			byExtendingSelection:NO];
	}
	[self persistRememberedMusicList];
}

- (IBAction)showMusicListEntryInformation:(id)sender
{
	(void)sender;
	NSInteger row = self.musicListTable.selectedRow;
	if (row < 0 || row >= (NSInteger)self.musicListEntries.count) { NSBeep(); return; }
	NSURL *URL = self.musicListEntries[row];
	NSDictionary<NSFileAttributeKey, id> *attributes = [NSFileManager.defaultManager
		attributesOfItemAtPath:URL.path error:nil];
	NSNumber *size = attributes[NSFileSize];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = URL.lastPathComponent;
	alert.informativeText = [NSString stringWithFormat:@"%@\n%@",
		URL.URLByDeletingLastPathComponent.path,
		size == nil ? @"File is not currently available" : [NSByteCountFormatter stringFromByteCount:size.longLongValue
			countStyle:NSByteCountFormatterCountStyleFile]];
	[alert beginSheetModalForWindow:self.musicListWindow completionHandler:nil];
}

- (IBAction)showMusicListHelp:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Music List";
	alert.informativeText = @"Add or drag tracker files into this numbered queue. Double-click a row, press Return, or use the triangle button to load it. The arrow menu chooses Stop, Next, Shuffle, or Repeat when playback reaches the end.";
	[alert beginSheetModalForWindow:self.musicListWindow completionHandler:nil];
}

- (IBAction)removeMusicListEntries:(id)sender
{
	(void)sender;
	NSIndexSet *selection = self.musicListTable.selectedRowIndexes;
	if (selection.count == 0) { NSBeep(); return; }
	NSInteger first = selection.firstIndex;
	NSURL *activeURL = self.musicListActiveIndex >= 0 && self.musicListActiveIndex < (NSInteger)self.musicListEntries.count
		? self.musicListEntries[self.musicListActiveIndex] : nil;
	[self.musicListEntries removeObjectsAtIndexes:selection];
	self.musicListActiveIndex = [self musicListIndexForURL:activeURL];
	[self.musicListTable reloadData];
	[self updateMusicListSummary];
	if (self.musicListEntries.count > 0) {
		NSInteger replacement = MIN(first, (NSInteger)self.musicListEntries.count - 1);
		[self.musicListTable selectRowIndexes:[NSIndexSet indexSetWithIndex:replacement] byExtendingSelection:NO];
	}
	[self persistRememberedMusicList];
}

- (IBAction)clearMusicList:(id)sender
{
	(void)sender;
	[self.musicListEntries removeAllObjects];
	self.musicListActiveIndex = -1;
	self.musicListURL = nil;
	self.musicListWindow.title = @"Untitled Music List";
	[self.musicListTable reloadData];
	[self updateMusicListSummary];
	[self persistRememberedMusicList];
}

- (IBAction)saveMusicList:(id)sender
{
	(void)sender;
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = self.musicListURL.lastPathComponent ?: @"Untitled Music List.mplaylist";
	panel.message = @"Save the numbered Music List and its current selection";
	[panel beginSheetModalForWindow:self.musicListWindow completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK) return;
		NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:self.musicListEntries.count];
		for (NSURL *URL in self.musicListEntries) [paths addObject:URL.path];
		NSDictionary *propertyList = @{
			@"format": @"MachoPlayer Music List",
			@"version": @1,
			@"files": paths,
			@"selectedIndex": @(self.musicListTable.selectedRow)
		};
		NSError *error = nil;
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:propertyList
			format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
		if (data == nil || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
			[NSApp presentError:error];
			return;
		}
		self.musicListURL = panel.URL;
		self.musicListWindow.title = panel.URL.lastPathComponent;
		self.statusField.stringValue = [NSString stringWithFormat:@"Saved Music List as %@", panel.URL.lastPathComponent];
	}];
}

- (void)readMusicListAtURL:(NSURL *)URL
{
	NSError *error = nil;
	NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:&error];
	id object = data == nil ? nil : [NSPropertyListSerialization propertyListWithData:data
		options:NSPropertyListImmutable format:nil error:&error];
	if (![object isKindOfClass:NSDictionary.class] || ![object[@"files"] isKindOfClass:NSArray.class]) {
		if (error == nil) error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError
			userInfo:@{NSLocalizedDescriptionKey: @"This is not a MachoPlayer Music List."}];
		[NSApp presentError:error];
		return;
	}
	[self.musicListEntries removeAllObjects];
	for (id path in object[@"files"]) {
		if ([path isKindOfClass:NSString.class]) [self.musicListEntries addObject:[NSURL fileURLWithPath:path]];
	}
	self.musicListURL = URL;
	self.musicListActiveIndex = [self musicListIndexForURL:self.documentURL];
	self.musicListWindow.title = URL.lastPathComponent;
	[self.musicListTable reloadData];
	[self updateMusicListSummary];
	NSInteger selection = [object[@"selectedIndex"] integerValue];
	if (selection >= 0 && selection < (NSInteger)self.musicListEntries.count) {
		[self.musicListTable selectRowIndexes:[NSIndexSet indexSetWithIndex:selection] byExtendingSelection:NO];
		[self.musicListTable scrollRowToVisible:selection];
	}
	[self persistRememberedMusicList];
	if ([NSUserDefaults.standardUserDefaults boolForKey:PPMusicListLoadFirstDefaultsKey] &&
		self.musicListEntries.count > 0) {
		[self.musicListTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
		[self loadSelectedMusicListEntry:nil];
	}
}

- (IBAction)loadSelectedMusicListEntry:(id)sender
{
	(void)sender;
	NSInteger row = self.musicListTable.selectedRow;
	if (row < 0 || row >= (NSInteger)self.musicListEntries.count) { NSBeep(); return; }
	NSURL *URL = self.musicListEntries[row];
	if (![NSFileManager.defaultManager fileExistsAtPath:URL.path]) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.alertStyle = NSAlertStyleWarning;
		alert.messageText = [NSString stringWithFormat:@"%@ could not be found.", URL.lastPathComponent];
		alert.informativeText = @"Remove the missing entry or add the file again from its new location.";
		[alert addButtonWithTitle:@"Remove"];
		[alert addButtonWithTitle:@"Cancel"];
		[alert beginSheetModalForWindow:self.musicListWindow completionHandler:^(NSModalResponse response) {
			if (response == NSAlertFirstButtonReturn) [self removeMusicListEntries:nil];
		}];
		return;
	}
	self.musicListActiveIndex = row;
	[self loadDocumentAtURL:URL];
	[self.musicListTable reloadData];
}

- (IBAction)changeMusicListPlaybackMode:(NSMenuItem *)sender
{
	self.musicListPlaybackMode = MIN(MAX(sender.tag, 0), 3);
	[NSUserDefaults.standardUserDefaults setInteger:self.musicListPlaybackMode
		forKey:PPMusicListPlaybackModeDefaultsKey];
	for (NSMenuItem *item in sender.menu.itemArray) {
		if (item.action == @selector(changeMusicListPlaybackMode:)) {
			item.state = item.tag == self.musicListPlaybackMode ? NSControlStateValueOn : NSControlStateValueOff;
		}
	}
	self.musicListHandledEnd = NO;
}

- (BOOL)advanceMusicListAfterPlaybackEnd
{
	if (self.musicListPlaybackMode == 0 || _music == NULL || _music->header == NULL) return NO;
	if (self.musicListPlaybackMode == 3) {
		if (_music->header->numPointers <= 0) return NO;
		_selectedPattern = _music->header->oPointers[0];
		self.selectedPartitionPosition = 0;
		[self resetTransportToSelectedPatternPreservingPlayback:NO];
		[self playPlayback:nil];
		return YES;
	}
	if (self.musicListEntries.count == 0) return NO;
	NSInteger current = self.musicListActiveIndex;
	if (current < 0 || current >= (NSInteger)self.musicListEntries.count) current = [self musicListIndexForURL:self.documentURL];
	NSInteger next = self.musicListPlaybackMode == 2
		? arc4random_uniform((uint32_t)self.musicListEntries.count)
		: (current + 1) % self.musicListEntries.count;
	if (self.musicListEntries.count > 1 && next == current) next = (next + 1) % self.musicListEntries.count;
	self.musicListActiveIndex = next;
	[self.musicListTable selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
	[self.musicListTable scrollRowToVisible:next];
	[self loadDocumentAtURL:self.musicListEntries[next]];
	[self playPlayback:nil];
	return YES;
}

- (void)arrangeDefaultWorkspace
{
	// Match the reference 1408 x 881-point screen while keeping every window
	// inside the current display's usable area.  Mapping from the full screen
	// makes the menu-bar spacing agree with the reference screenshot; clamping
	// to visibleFrame still accounts for a non-hidden Dock or a secondary screen.
	NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
	if (screen == nil) return;
	NSRect screenFrame = screen.frame;
	NSRect visible = screen.visibleFrame;
	CGFloat scaleX = NSWidth(screenFrame) / 1408.0;
	CGFloat scaleY = NSHeight(screenFrame) / 881.0;

	CGFloat editorWidth = MIN(640.0, MAX(540.0, NSWidth(visible) - 40.0));
	CGFloat editorHeight = MIN(600.0, MAX(260.0, NSHeight(visible) - 100.0));
	[self.window setContentSize:NSMakeSize(editorWidth, editorHeight)];
	[self.instrumentsWindow setContentSize:NSMakeSize(self.instrumentInspectorExpanded
		? PPInstrumentListExpandedWidth : PPInstrumentListCompactWidth, 350)];
	[self.patternsWindow setContentSize:NSMakeSize(223, 280)];
	[self.partitionWindow setContentSize:NSMakeSize(self.partitionInspectorExpanded
		? PPPartitionExpandedWidth : PPPartitionCompactWidth,
		MIN(440.0, NSHeight(visible) - 80.0))];
	CGFloat toolsInspectorHeight = self.toolsCommandInspectorExpanded ? 121.0 : 0.0;
	CGFloat toolsWidth = self.toolsCommandInspectorExpanded && self.toolsEffectHelpExpanded ? 470.0 : 183.0;
	[self.toolsWindow setContentSize:NSMakeSize(toolsWidth, 48 + toolsInspectorHeight)];
	self.toolsTransportView.frame = NSMakeRect(0, toolsInspectorHeight, 183, 48);
	self.toolsCommandInspectorView.hidden = !self.toolsCommandInspectorExpanded;
	self.toolsEffectHelpView.hidden = !(self.toolsCommandInspectorExpanded && self.toolsEffectHelpExpanded);
	[self.mixerController.window setContentSize:NSMakeSize(375, MIN(278.0, NSHeight(visible) - 40.0))];
	CGFloat pianoWidth = MIN(1110.0, MAX(360.0, NSWidth(visible) - 40.0));
	[self.pianoController.window setContentSize:NSMakeSize(pianoWidth, 44)];

	void (^placeAtOrigin)(NSWindow *, CGFloat, CGFloat) = ^(NSWindow *window, CGFloat referenceX, CGFloat referenceY) {
		if (window == nil) return;
		NSRect frame = window.frame;
		frame.origin = NSMakePoint(NSMinX(screenFrame) + referenceX * scaleX,
			NSMinY(screenFrame) + referenceY * scaleY);
		frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)),
			MAX(NSMinX(visible), NSMaxX(visible) - NSWidth(frame)));
		frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)),
			MAX(NSMinY(visible), NSMaxY(visible) - NSHeight(frame)));
		[window setFrame:frame display:NO];
	};
	void (^placeBelowTop)(NSWindow *, CGFloat, CGFloat) = ^(NSWindow *window, CGFloat referenceX, CGFloat topInset) {
		if (window == nil) return;
		NSRect frame = window.frame;
		frame.origin = NSMakePoint(NSMinX(screenFrame) + referenceX * scaleX,
			NSMaxY(screenFrame) - topInset * scaleY - NSHeight(frame));
		frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)),
			MAX(NSMinX(visible), NSMaxX(visible) - NSWidth(frame)));
		frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)),
			MAX(NSMinY(visible), NSMaxY(visible) - NSHeight(frame)));
		[window setFrame:frame display:NO];
	};

	placeBelowTop(self.instrumentsWindow, 10, 48);
	placeBelowTop(self.window, 373, 78);
	placeBelowTop(self.toolsWindow, 1164, 87);
	placeAtOrigin(self.patternsWindow, 28, 196);
	placeAtOrigin(self.partitionWindow, 8, 140);
	placeAtOrigin(self.mixerController.window, 1025, 140);
	placeAtOrigin(self.pianoController.window, 124, 20);
}

#pragma mark - Documents

- (IBAction)newDocument:(id)sender
{
	(void)sender;
	[self disposeCurrentMusic];
	_music = CreateFreeMADK();
	if (_music != NULL) {
		for (NSInteger instrument = 0; instrument < MAXINSTRU; instrument++) {
			_music->fid[instrument].firstSample = (short)(instrument * MAXSAMPLE);
		}
		// MachoPlayer's blank workspace begins mono/centered. Imported and opened
		// songs retain the per-track panning stored in their files.
		for (NSInteger channel = 0; channel < MAXTRACK; channel++) {
			_music->header->chanPan[channel] = MAX_PANNING / 2;
		}
	}
	self.documentURL = nil;
	self.musicListActiveIndex = -1;
	self.musicListHandledEnd = NO;
	_selectedPattern = 0;
	self.selectedPartitionPosition = 0;
	_selectedInstrument = 0;
	_selectedSample = -1;
	[self.collapsedInstrumentIndexes removeAllIndexes];
	self.defaultPatternInstrument = 1;
	[self attachMusicAndReload];
	if (_music != NULL) _music->hasChanged = false;
	self.titleField.stringValue = @"Untitled";
	self.window.representedURL = nil;
	self.window.documentEdited = NO;
	[self updatePatternWindowTitle];
	[self.musicListTable reloadData];
}

- (IBAction)openDocument:(id)sender
{
	(void)sender;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowsMultipleSelection = NO;
	panel.canChooseDirectories = NO;
	panel.message = @"Open a PlayerPRO or tracker music file";
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result == NSModalResponseOK) {
			[self loadDocumentAtURL:panel.URL];
		}
	}];
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
	if (menu != self.openRecentMenu) return;
	[menu removeAllItems];
	NSArray<NSURL *> *recentURLs = NSDocumentController.sharedDocumentController.recentDocumentURLs;
	if (recentURLs.count == 0) {
		NSMenuItem *emptyItem = [[NSMenuItem alloc] initWithTitle:@"No Recent Documents"
			action:nil keyEquivalent:@""];
		emptyItem.enabled = NO;
		[menu addItem:emptyItem];
	} else {
		for (NSURL *url in recentURLs) {
			NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:url.lastPathComponent
				action:@selector(openRecentDocument:) keyEquivalent:@""];
			item.target = self;
			item.representedObject = url;
			item.toolTip = url.path;
			[menu addItem:item];
		}
	}
	[menu addItem:NSMenuItem.separatorItem];
	NSMenuItem *clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear Menu"
		action:@selector(clearOpenRecentMenu:) keyEquivalent:@""];
	clearItem.target = self;
	clearItem.enabled = recentURLs.count > 0;
	[menu addItem:clearItem];
}

- (IBAction)openRecentDocument:(NSMenuItem *)sender
{
	NSURL *url = [sender.representedObject isKindOfClass:NSURL.class] ? sender.representedObject : nil;
	if (url != nil) [self loadDocumentAtURL:url];
}

- (IBAction)clearOpenRecentMenu:(id)sender
{
	[NSDocumentController.sharedDocumentController clearRecentDocuments:sender];
	[self menuNeedsUpdate:self.openRecentMenu];
}

- (void)loadDocumentAtURL:(NSURL *)url
{
	if (_library == NULL || _driver == NULL || url == nil) {
		return;
	}

	char type[5] = {0};
	MADErr error = MADMusicIdentifyCFURL(_library, type, (__bridge CFURLRef)url);
	if (error != MADNoErr) {
		[self presentErrorCode:error operation:@"identifying the music file"];
		return;
	}

	MADMusic *loadedMusic = NULL;
	error = MADLoadMusicCFURLFile(_library, &loadedMusic, type, (__bridge CFURLRef)url);
	if (error != MADNoErr || loadedMusic == NULL) {
		[self presentErrorCode:error operation:@"opening the music file"];
		return;
	}

	[self disposeCurrentMusic];
	_music = loadedMusic;
	self.documentURL = url;
	[NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
	NSInteger musicListIndex = [self musicListIndexForURL:url];
	self.musicListActiveIndex = musicListIndex == NSNotFound ? -1 : musicListIndex;
	self.musicListHandledEnd = NO;
	_selectedPattern = _music->header->oPointers[0];
	self.selectedPartitionPosition = 0;
	_selectedInstrument = 0;
	_selectedSample = -1;
	[self.collapsedInstrumentIndexes removeAllIndexes];
	self.defaultPatternInstrument = 1;
	[self attachMusicAndReload];
	_music->hasChanged = false;
	self.titleField.stringValue = [self stringFromLegacyBytes:_music->header->name length:sizeof(_music->header->name)
		fallback:url.lastPathComponent.stringByDeletingPathExtension];
	self.window.representedURL = url;
	self.window.documentEdited = NO;
	[self updatePatternWindowTitle];
	[self.musicListTable reloadData];
	self.statusField.stringValue = [NSString stringWithFormat:@"%@ • %u patterns • %u tracks • %u instruments",
		type[0] == 0 ? @"MADK" : [NSString stringWithUTF8String:type], _music->header->numPat,
		_music->header->numChn, _music->header->numInstru];
	if (_music->header->showCopyright) {
		NSString *copyright = [self stringFromLegacyBytes:_music->header->infos
			length:sizeof(_music->header->infos) fallback:@""];
		if (copyright.length > 0) {
			NSAlert *alert = [[NSAlert alloc] init];
			alert.messageText = self.titleField.stringValue.length > 0 ? self.titleField.stringValue : @"Music Information";
			alert.informativeText = copyright;
			[alert addButtonWithTitle:@"OK"];
			[alert beginSheetModalForWindow:self.window completionHandler:nil];
		}
	}
	if ([NSUserDefaults.standardUserDefaults boolForKey:PPMusicListAutoPlayDefaultsKey]) {
		[self playPlayback:nil];
	}
}

- (void)attachMusicAndReload
{
	if (_driver != NULL && _music != NULL) {
		MADCleanDriver(_driver);
		MADAttachDriverToMusic(_driver, _music, NULL);
	}
	[self rebuildPatternColumns];
	[self.orderTable reloadData];
	[self.partitionTable reloadData];
	[self updatePartitionLengthDisplay];
	[self.instrumentTable reloadData];
	[self.patternTable reloadData];
	PatData *pattern = [self selectedPatternData];
	if (pattern != NULL && pattern->header.size > 0 && _music->header->numChn > 0) {
		[self selectPatternTop:0 bottom:0 left:0 right:0];
	}
	if (self.instrumentTable.numberOfRows > 0) {
		[self.instrumentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
	}
	[self updateInstrumentDetails];
	[self.mixerController attachMusic:_music driver:_driver];
	[self.pianoController attachMusic:_music driver:_driver selectedInstrument:_selectedInstrument
		selectedTrack:MAX(self.patternCursorChannel, 0)];
	[self.equalizerController attachDriver:_driver];
	self.loopButton.state = _driver != NULL && !_driver->JumpToNextPattern
		? NSControlStateValueOn : NSControlStateValueOff;
	[self updateTransportButtonStates];
	[self updateToolsTitle];
	[self rebuildToolsCommandInspectorMenus];
	[self updateToolsCommandInspector];
	if (self.orderTable.numberOfRows > 0) {
		NSInteger row = MIN(MAX(_selectedPattern, 0), self.orderTable.numberOfRows - 1);
		[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	}
	if (self.partitionTable.numberOfRows > 0) {
		self.suppressPartitionSelectionAction = YES;
		NSInteger position = MIN(MAX(self.selectedPartitionPosition, 0), self.partitionTable.numberOfRows - 1);
		[self.partitionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:position] byExtendingSelection:NO];
		[self.partitionTable scrollRowToVisible:position];
		self.suppressPartitionSelectionAction = NO;
	}
}

- (void)disposeCurrentMusic
{
	[self.mixerController attachMusic:NULL driver:NULL];
	[self.pianoController attachMusic:NULL driver:NULL selectedInstrument:0 selectedTrack:0];
	for (PPSampleEditorController *editor in self.sampleEditors.copy) {
		[editor close];
	}
	[self.sampleEditors removeAllObjects];
	for (PPInstrumentEditorController *editor in self.instrumentEditors.copy) {
		[editor close];
	}
	[self.instrumentEditors removeAllObjects];
	for (PPPatternModeController *editor in self.patternModeEditors.copy) {
		[editor close];
	}
	[self.patternModeEditors removeAllObjects];
	if (_music != NULL) {
		if (_driver != NULL) {
			MADStopMusic(_driver);
			MADCleanDriver(_driver);
		}
		MADDisposeMusic(&_music, _driver);
		_music = NULL;
	}
}

- (BOOL)reconfigureDriverWithSettings:(MADDriverSettings)newSettings operation:(NSString *)operation
{
	if (_driver == NULL || _library == NULL) return NO;
	MADDriverSettings oldSettings = _driver->DriverSettings;
	BOOL wasPlaying = _music != NULL && MADWasReading(_driver);
	long fullTime = 1, currentTime = 0;
	if (_music != NULL) MADGetMusicStatus(_driver, &fullTime, &currentTime);
	short volume = _driver->base.VolGlobal;
	short speed = _driver->base.VExt;
	short pitch = _driver->base.FreqExt;
	int pan = _driver->globPan;
	BOOL loop = !_driver->JumpToNextPattern;
	bool active[MAXTRACK];
	memcpy(active, _driver->base.Active, sizeof(active));

	MADStopMusic(_driver);
	MADStopDriver(_driver);
	[self.equalizerController attachDriver:NULL];
	MADDisposeDriver(_driver);
	_driver = NULL;
	MADErr requestedError = MADCreateDriver(&newSettings, _library, &_driver);
	MADErr error = requestedError;
	if (error == MADNoErr) error = MADStartDriver(_driver);
	if (error != MADNoErr) requestedError = error;
	BOOL usedFallback = error != MADNoErr;
	if (error != MADNoErr) {
		if (_driver != NULL) {
			MADDisposeDriver(_driver);
			_driver = NULL;
		}
		error = MADCreateDriver(&oldSettings, _library, &_driver);
		if (error == MADNoErr) error = MADStartDriver(_driver);
	}
	if (error != MADNoErr || _driver == NULL) {
		[self presentErrorCode:error operation:operation];
		[self.mixerController attachMusic:_music driver:NULL];
		[self.pianoController attachMusic:_music driver:NULL selectedInstrument:_selectedInstrument
			selectedTrack:MAX(self.patternCursorChannel, 0)];
		[self.equalizerController attachDriver:NULL];
		return NO;
	}

	_driver->base.VolGlobal = volume;
	_driver->base.VExt = speed;
	_driver->base.FreqExt = pitch;
	_driver->globPan = pan;
	_driver->JumpToNextPattern = !loop;
	memcpy(_driver->base.Active, active, sizeof(active));
	if (_music != NULL) {
		MADAttachDriverToMusic(_driver, _music, NULL);
		MADSetMusicStatus(_driver, 0, MAX(fullTime, 1), MIN(currentTime, MAX(fullTime, 1)));
		if (wasPlaying) MADPlayMusic(_driver);
	}
	self.loopButton.state = loop ? NSControlStateValueOn : NSControlStateValueOff;
	[self updateTransportButtonStates];
	[self.mixerController attachMusic:_music driver:_driver];
	[self.pianoController attachMusic:_music driver:_driver selectedInstrument:_selectedInstrument
		selectedTrack:MAX(self.patternCursorChannel, 0)];
	[self.equalizerController attachDriver:_driver];
	if (usedFallback) {
		[self presentErrorCode:requestedError operation:operation];
		return NO;
	}
	return YES;
}

- (void)applyMixerReverbEnabled:(BOOL)enabled delay:(NSInteger)delay strength:(NSInteger)strength
{
	if (_driver == NULL || _library == NULL) return;
	delay = MIN(MAX(delay, 25), 1000);
	strength = MIN(MAX(strength, 0), 70);
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	[defaults setBool:enabled forKey:PPDriverReverbEnabledDefaultsKey];
	[defaults setInteger:delay forKey:PPDriverReverbDelayDefaultsKey];
	[defaults setInteger:strength forKey:PPDriverReverbStrengthDefaultsKey];
	MADDriverSettings oldSettings = _driver->DriverSettings;
	if (oldSettings.Reverb == enabled && oldSettings.ReverbSize == delay) {
		_driver->DriverSettings.ReverbStrength = (int)strength;
		self.statusField.stringValue = enabled
			? [NSString stringWithFormat:@"PlayerPRO reverb: %ld ms, %ld%%", (long)delay, (long)strength]
			: @"PlayerPRO reverb off";
		return;
	}
	MADDriverSettings newSettings = oldSettings;
	newSettings.Reverb = enabled;
	newSettings.ReverbSize = (int)delay;
	newSettings.ReverbStrength = (int)strength;
	[self reconfigureDriverWithSettings:newSettings operation:@"reconfiguring PlayerPRO reverb"];
	self.statusField.stringValue = enabled
		? [NSString stringWithFormat:@"PlayerPRO reverb: %ld ms, %ld%%", (long)delay, (long)strength]
		: @"PlayerPRO reverb off";
}

- (IBAction)showMixer:(id)sender
{
	(void)sender;
	if (self.mixerController == nil) {
		self.mixerController = [[PPMixerController alloc] initWithMusic:_music driver:_driver];
		__weak typeof(self) weakSelf = self;
		self.mixerController.reverbHandler = ^(BOOL enabled, NSInteger delay, NSInteger strength) {
			[weakSelf applyMixerReverbEnabled:enabled delay:delay strength:strength];
		};
	}
	[self.mixerController attachMusic:_music driver:_driver];
	[self.mixerController showWindow:nil];
	[self.mixerController.window makeKeyAndOrderFront:nil];
}

- (IBAction)showEqualizer:(id)sender
{
	(void)sender;
	if (self.equalizerController == nil) {
		self.equalizerController = [[PPEqualizerController alloc] initWithDriver:_driver];
	} else {
		[self.equalizerController attachDriver:_driver];
	}
	[self.equalizerController showWindow:nil];
	[self.equalizerController.window makeKeyAndOrderFront:nil];
}

- (IBAction)showPiano:(id)sender
{
	(void)sender;
	if (self.pianoController == nil) {
		__weak typeof(self) weakSelf = self;
		self.pianoController = [[PPPianoController alloc] initWithRecordHandler:
			^(NSInteger note, NSInteger track, BOOL livePlayback) {
				[weakSelf recordPianoNote:note track:track livePlayback:livePlayback velocity:-1];
			} statusHandler:^(NSString *status) {
				weakSelf.statusField.stringValue = status;
			} octaveHandler:^(NSInteger octave) {
				weakSelf.patternOctaveOffset = octave;
				weakSelf.statusField.stringValue = [NSString stringWithFormat:@"Piano/Tracker offset: %@%ld octave(s)",
					octave >= 0 ? @"+" : @"", (long)octave];
			} midiOutputHandler:^(NSInteger note, NSInteger track, NSInteger instrument,
				NSInteger velocity, BOOL began) {
				[weakSelf handlePianoMIDIOutputNote:note track:track instrument:instrument
					velocity:velocity began:began];
			}];
	}
	NSInteger track = MAX(self.patternCursorChannel, 0);
	[self.pianoController setKeyboardOffset:self.patternOctaveOffset];
	[self.pianoController attachMusic:_music driver:_driver selectedInstrument:_selectedInstrument selectedTrack:track];
	[self.pianoController showWindow:nil];
}

- (void)recordPianoNote:(NSInteger)note track:(NSInteger)track livePlayback:(BOOL)livePlayback
{
	[self recordPianoNote:note track:track livePlayback:livePlayback velocity:-1];
}

- (void)recordPianoNote:(NSInteger)note track:(NSInteger)track
	livePlayback:(BOOL)livePlayback velocity:(NSInteger)velocity
{
	[self recordPianoNote:note track:track instrument:_selectedInstrument
		livePlayback:livePlayback velocity:velocity];
}

- (void)recordPianoNote:(NSInteger)note track:(NSInteger)track instrument:(NSInteger)instrument
		livePlayback:(BOOL)livePlayback velocity:(NSInteger)velocity
{
	BOOL noteOff = note == 0xFE;
	if (_music == NULL || _music->header == NULL || _driver == NULL ||
		(!noteOff && (note < 0 || note >= NUMBER_NOTES))) return;
	track = MIN(MAX(track, 0), MAX((NSInteger)_music->header->numChn - 1, 0));
	// Match NPianoRecordProcess from the 2002 application: Piano Record always
	// writes at the driver's transport cursor, never at the Digital selection.
	// PartitionReader points one row beyond the sounding row while playback is
	// active, but is the exact insertion row while playback is paused.
	livePlayback = livePlayback || MADIsPlayingMusic(_driver);
	NSInteger patternIndex = _driver->base.Pat;
	NSInteger row = _driver->base.PartitionReader - (livePlayback ? 1 : 0);
	if (livePlayback && _driver->base.PartitionReader <= 0 &&
		self.patternPlaybackPattern >= 0 && self.patternPlaybackRow >= 0) {
		// Preserve the row which is visibly sounding during the driver's brief
		// end-of-pattern transition, including the previous pattern's last row.
		patternIndex = self.patternPlaybackPattern;
		row = self.patternPlaybackRow;
	}
	if (patternIndex < 0 || patternIndex >= MAXPATTERN || _music->partition[patternIndex] == NULL) return;
	PatData *pattern = _music->partition[patternIndex];
	row = MIN(MAX(row, 0), MAX((NSInteger)pattern->header.size - 1, 0));

	// The 2002 recorder advances a second note on the same track/tick to the
	// next reader position instead of silently replacing the first one.
	if (livePlayback && _lastPianoRecordPattern[track] == patternIndex && _lastPianoRecordRow[track] == row) {
		row++;
		if (row >= pattern->header.size) {
			row = 0;
			if (_driver->JumpToNextPattern && _music->header->numPointers > 0) {
				NSInteger nextPosition = _driver->base.PL + 1;
				if (nextPosition >= _music->header->numPointers) nextPosition = 0;
				patternIndex = _music->header->oPointers[nextPosition];
			}
		}
		if (patternIndex < 0 || patternIndex >= MAXPATTERN || _music->partition[patternIndex] == NULL) return;
		pattern = _music->partition[patternIndex];
		row = MIN(MAX(row, 0), MAX((NSInteger)pattern->header.size - 1, 0));
	}
	_lastPianoRecordPattern[track] = patternIndex;
	_lastPianoRecordRow[track] = row;

	// Block the player from fetching this track's command while its fields are
	// being replaced, as the original recorder did before touching the cell.
	_driver->TrackLineReading[track] = false;
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:patternIndex];
	Cmd *command = GetMADCommand((short)row, (short)track, pattern);
	if (command == NULL) return;
	command->ins = noteOff ? 0 : (MADByte)MIN(MAX(instrument + 1, 1), 255);
	command->note = (MADByte)note;
	command->cmd = noteOff ? MADEffectNoteOff : MADEffectArpeggio;
	command->arg = 0;
	command->vol = !noteOff && velocity >= 0
		? (MADByte)(0x10 + MIN(MAX((velocity * 64 + 63) / 127, 0), 64))
		: 0xFF;
	if (!noteOff && livePlayback && _driver->smallcounter > 0) {
		command->cmd = (MADEffectID)0x0E;
		command->arg = (MADByte)(0xD0 + MIN(_driver->smallcounter, 0x0F));
	}
	[self registerPatternUndoSnapshot:snapshot actionName:@"Record Piano Note"];
	_music->hasChanged = true;
	NSInteger nextRow = pattern->header.size > 0 ? (row + 1) % pattern->header.size : row;
	if (!livePlayback) {
		// Step recording advances the transport reader itself. Merely moving the
		// Digital selection made every subsequent Piano note return to row zero.
		_driver->base.PartitionReader = (short)nextRow;
		if (nextRow == 0 && _driver->JumpToNextPattern && _music->header->numPointers > 0) {
			NSInteger nextPosition = MIN((NSInteger)_driver->base.PL + 1,
				(NSInteger)_music->header->numPointers - 1);
			_driver->base.PL = (short)nextPosition;
			_driver->base.Pat = _music->header->oPointers[nextPosition];
		}
	}

	if (patternIndex == _selectedPattern) {
		[self.patternTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
			columnIndexes:[NSIndexSet indexSetWithIndex:track + 1]];
		if (!livePlayback) {
			[self selectPatternTop:nextRow bottom:nextRow left:track right:track];
		}
	}
	self.statusField.stringValue = [NSString stringWithFormat:@"Piano REC • %@%@ row %03ld track %02ld%@",
		livePlayback ? @"live " : @"step ", noteOff ? @"note-off •" : @"note •",
		(long)row, (long)track + 1,
		!noteOff && livePlayback && _driver->smallcounter > 0 ? @" • fine delay" : @""];
}

- (void)handlePianoMIDIOutputNote:(NSInteger)note track:(NSInteger)track
	instrument:(NSInteger)instrument velocity:(NSInteger)velocity began:(BOOL)began
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if (![defaults boolForKey:PPMIDIOutputEnabledDefaultsKey] ||
		![defaults boolForKey:PPMIDIAuditionOutputDefaultsKey]) return;
	NSInteger midiNote = note + 12;
	if (midiNote < 0 || midiNote > 127) return;
	uint8_t channel = MADMIDIRoutedChannel((int)track, (int)instrument);
	if (began) {
		MADMIDISendProgramIfNeeded(channel, (uint8_t)(instrument & 0x7F));
		MADMIDISendNoteOn(channel, (uint8_t)midiNote,
			(uint8_t)MIN(MAX(velocity, 1), 127));
	} else {
		MADMIDISendNoteOff(channel, (uint8_t)midiNote, 0);
	}
}

- (void)recordMIDINoteInDigitalEditor:(NSInteger)note track:(NSInteger)track
	instrument:(NSInteger)instrument velocity:(NSInteger)velocity noteOff:(BOOL)noteOff
{
	if (!self.patternRecording || _music == NULL || _music->header == NULL) return;
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || pattern->header.size <= 0 || _music->header->numChn <= 0) return;
	NSInteger row = MIN(MAX(self.patternCursorRow, 0), pattern->header.size - 1);
	track = MIN(MAX(track, 0), (NSInteger)_music->header->numChn - 1);
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd *command = GetMADCommand((short)row, (short)track, pattern);
	if (command == NULL) return;
	if (noteOff) {
		command->ins = 0;
		command->note = 0xFE;
		command->cmd = MADEffectNoteOff;
		command->arg = 0;
		command->vol = 0xFF;
	} else {
		command->note = (MADByte)MIN(MAX(note, 0), NUMBER_NOTES - 1);
		if (self.patternInstrumentToggle.state == NSControlStateValueOn) {
			command->ins = (MADByte)MIN(MAX(instrument + 1, 1), 255);
		}
		if (self.patternEffectToggle.state == NSControlStateValueOn) command->cmd = self.defaultPatternEffect;
		if (self.patternArgumentToggle.state == NSControlStateValueOn) command->arg = self.defaultPatternArgument;
		if ([NSUserDefaults.standardUserDefaults boolForKey:PPMIDIVelocityDefaultsKey]) {
			command->vol = (MADByte)(0x10 + MIN(MAX((velocity * 64 + 63) / 127, 0), 64));
		} else if (self.patternVolumeToggle.state == NSControlStateValueOn) {
			command->vol = self.defaultPatternVolume == 0 ? 0xFF : self.defaultPatternVolume;
		}
	}
	[self registerPatternUndoSnapshot:snapshot
		actionName:noteOff ? @"Record MIDI Note Off" : @"Record MIDI Note"];
	_music->hasChanged = true;
	[self.patternTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
		columnIndexes:[NSIndexSet indexSetWithIndex:track + 1]];
	NSInteger nextRow = (row + self.patternStep) % pattern->header.size;
	[self selectPatternTop:nextRow bottom:nextRow left:track right:track];
	self.statusField.stringValue = [NSString stringWithFormat:@"MIDI REC • %@ row %03ld track %02ld",
		noteOff ? @"note-off" : @"note", (long)row, (long)track + 1];
}

- (void)handleMIDIStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	if (![defaults boolForKey:PPMIDIInputEnabledDefaultsKey]) return;
	uint8_t kind = status & 0xF0;
	uint8_t midiChannel = status & 0x0F;
	NSInteger receiveChannel = [defaults integerForKey:PPMIDIInputChannelDefaultsKey];
	if (status < 0xF0 && receiveChannel > 0 && midiChannel + 1 != receiveChannel) return;

	BOOL thru = [defaults boolForKey:PPMIDIThruDefaultsKey] && MADMIDIOutputIsEnabled();
	if (kind != 0x80 && kind != 0x90) {
		if (thru && status < 0xF0) {
			uint8_t message[] = {status, data1, data2};
			size_t length = kind == 0xC0 || kind == 0xD0 ? 2 : 3;
			MADMIDISendBytes(message, length);
		}
		if (kind == 0xB0 && (data1 == 120 || data1 == 123)) {
			for (NSNumber *key in self.midiHeldNotes.allKeys.copy) {
				NSDictionary *held = self.midiHeldNotes[key];
				if (((key.unsignedIntegerValue >> 8) & 0x0F) != midiChannel) continue;
				NSInteger note = [held[@"note"] integerValue];
				NSInteger track = [held[@"track"] integerValue];
				[self.pianoController handleMIDINoteOff:note track:track];
				[self.midiHeldNotes removeObjectForKey:key];
				[self.midiTrackOwners removeObjectForKey:@(track)];
			}
		}
		return;
	}

	BOOL began = kind == 0x90 && data2 > 0;
	NSNumber *key = @(((NSUInteger)midiChannel << 8) | data1);
	if (began) {
		NSInteger trackerNote = (NSInteger)data1 - 12;
		if (trackerNote < 0 || trackerNote >= NUMBER_NOTES || _music == NULL || _music->header == NULL) return;
		BOOL channelMapping = [defaults boolForKey:PPMIDIChannelMappingDefaultsKey];
		NSInteger track = channelMapping
			? MIN((NSInteger)midiChannel, MAX((NSInteger)_music->header->numChn - 1, 0))
			: MIN(MAX(self.patternCursorChannel, 0), MAX((NSInteger)_music->header->numChn - 1, 0));
		NSInteger instrument = channelMapping ? MIN((NSInteger)midiChannel, MAXINSTRU - 1) : _selectedInstrument;
		NSInteger velocity = [defaults boolForKey:PPMIDIVelocityDefaultsKey] ? data2 : 127;
		NSDictionary *previous = self.midiHeldNotes[key];
		if (previous != nil) {
			[self.pianoController handleMIDINoteOff:[previous[@"note"] integerValue]
				track:[previous[@"track"] integerValue]];
		}
		uint8_t outputChannel = MADMIDIRoutedChannel((int)track, (int)instrument);
		self.midiHeldNotes[key] = @{@"note": @(trackerNote), @"track": @(track),
			@"instrument": @(instrument), @"outputChannel": @(outputChannel)};
		self.midiTrackOwners[@(track)] = key;
		BOOL livePlayback = _driver != NULL && MADIsPlayingMusic(_driver);
		[self.pianoController handleMIDINoteOn:trackerNote velocity:velocity
			instrument:instrument track:track];
		if (thru) {
			MADMIDISendProgramIfNeeded(outputChannel, (uint8_t)(instrument & 0x7F));
			MADMIDISendNoteOn(outputChannel, data1, data2);
		}
		if (self.pianoController.isRecordingEnabled) {
			[self recordPianoNote:trackerNote track:track instrument:instrument
				livePlayback:livePlayback velocity:velocity];
		} else {
			[self recordMIDINoteInDigitalEditor:trackerNote track:track
				instrument:instrument velocity:velocity noteOff:NO];
		}
		self.statusField.stringValue = [NSString stringWithFormat:
			@"MIDI IN • note %03u • velocity %03u • channel %02u → instrument %03ld / track %02ld",
			data1, data2, midiChannel + 1, (long)instrument + 1, (long)track + 1];
		return;
	}

	NSDictionary<NSString *, NSNumber *> *held = self.midiHeldNotes[key];
	if (held == nil) return;
	NSInteger trackerNote = held[@"note"].integerValue;
	NSInteger track = held[@"track"].integerValue;
	BOOL ownsTrack = [self.midiTrackOwners[@(track)] isEqual:key];
	[self.pianoController handleMIDINoteOff:trackerNote track:track stopVoice:ownsTrack];
	if (ownsTrack) {
		[self.midiTrackOwners removeObjectForKey:@(track)];
	}
	if (thru) {
		MADMIDISendNoteOff((uint8_t)held[@"outputChannel"].unsignedIntegerValue, data1, data2);
	}
	[self.midiHeldNotes removeObjectForKey:key];
	if (ownsTrack && [defaults boolForKey:PPMIDIRecordNoteOffDefaultsKey]) {
		NSInteger instrument = held[@"instrument"].integerValue;
		if (self.pianoController.isRecordingEnabled) {
			[self recordPianoNote:0xFE track:track instrument:instrument
				livePlayback:_driver != NULL && MADWasReading(_driver) velocity:-1];
		} else {
			[self recordMIDINoteInDigitalEditor:0 track:track
				instrument:instrument velocity:0 noteOff:YES];
		}
	}
}

- (IBAction)saveDocument:(id)sender
{
	(void)sender;
	if (self.documentURL == nil) {
		[self saveDocumentAs:sender];
		return;
	}
	[self saveToURL:self.documentURL];
}

- (IBAction)saveDocumentAs:(id)sender
{
	(void)sender;
	[self beginSavePanelWithCompletion:nil];
}

- (void)beginSavePanelWithCompletion:(void (^)(BOOL saved))completion
{
	if (_music == NULL) { if (completion != nil) completion(NO); return; }
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = self.documentURL.lastPathComponent ?: @"Untitled.madk";
	[panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result == NSModalResponseOK) {
			BOOL saved = [self saveToURL:panel.URL];
			if (completion != nil) completion(saved);
		} else if (completion != nil) {
			completion(NO);
		}
	}];
}

- (BOOL)saveToURL:(NSURL *)url
{
	if (_music == NULL || url == nil) {
		return NO;
	}
	if ([NSUserDefaults.standardUserDefaults boolForKey:PPAddFileExtensionDefaultsKey] &&
		url.pathExtension.length == 0) {
		url = [url URLByAppendingPathExtension:@"madk"];
	}
	BOOL compress = [NSUserDefaults.standardUserDefaults boolForKey:PPAutomaticCompressionDefaultsKey];
	MADErr error = MADMusicSaveCFURL(_music, (__bridge CFURLRef)url, compress);
	if (error == MADNoErr) {
		_music->hasChanged = false;
		self.documentURL = url;
		[NSDocumentController.sharedDocumentController noteNewRecentDocumentURL:url];
		self.window.representedURL = url;
		self.window.documentEdited = NO;
		[self updatePatternWindowTitle];
		self.statusField.stringValue = @"Saved";
		return YES;
	} else {
		[self presentErrorCode:error operation:@"saving the music file"];
		return NO;
	}
}

- (IBAction)exportDocument:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Export is being restored";
	alert.informativeText = @"Playback and native MADK saving are active in this first macOS 26 build. Tracker-format and audio export are the next compatibility milestone.";
	[alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Playback

- (void)updateTransportButtonStates
{
	BOOL playing = _driver != NULL && _music != NULL && MADWasReading(_driver);
	self.playButton.state = playing ? NSControlStateValueOn : NSControlStateValueOff;
	self.stopButton.state = playing ? NSControlStateValueOff : NSControlStateValueOn;
	self.toolsRecordButton.enabled = _driver != NULL && _music != NULL;
}

- (void)updateToolsTitle
{
	NSString *title = self.titleField.stringValue;
	if (title.length == 0) title = self.documentURL.lastPathComponent.stringByDeletingPathExtension;
	if (title.length == 0) title = @"Untitled";
	self.toolsTitleField.stringValue = title;
}

- (void)resetTransportToSelectedPatternPreservingPlayback:(BOOL)preservePlayback
{
	if (_driver == NULL || _music == NULL || _music->header == NULL || [self selectedPatternData] == NULL) return;
	BOOL wasPlaying = preservePlayback && MADWasReading(_driver);
	if (MADWasReading(_driver)) MADStopMusic(_driver);
	MADReset(_driver);
	NSInteger sequencePosition = NSNotFound;
	if (self.selectedPartitionPosition >= 0 && self.selectedPartitionPosition < _music->header->numPointers &&
		_music->header->oPointers[self.selectedPartitionPosition] == _selectedPattern) {
		sequencePosition = self.selectedPartitionPosition;
	} else {
		for (NSInteger index = 0; index < _music->header->numPointers; index++) {
			if (_music->header->oPointers[index] == _selectedPattern) {
				sequencePosition = index;
				break;
			}
		}
	}
	self.selectedPartitionPosition = sequencePosition == NSNotFound ? 0 : sequencePosition;
	if (self.partitionTable != nil && self.selectedPartitionPosition < self.partitionTable.numberOfRows) {
		self.suppressPartitionSelectionAction = YES;
		[self.partitionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:self.selectedPartitionPosition]
			byExtendingSelection:NO];
		[self.partitionTable scrollRowToVisible:self.selectedPartitionPosition];
		self.suppressPartitionSelectionAction = NO;
	}
	_driver->base.PL = sequencePosition == NSNotFound ? 0 : (short)sequencePosition;
	_driver->base.Pat = (short)_selectedPattern;
	_driver->base.PartitionReader = 0;
	_driver->base.musicEnd = false;
	_driver->endPattern = false;
	_driver->OneMoreBeforeEnd = false;
	_driver->base.speed = _music->header->speed;
	_driver->base.finespeed = _music->header->tempo;
	if (wasPlaying) MADPlayMusic(_driver);
}

- (IBAction)togglePlayback:(id)sender
{
	(void)sender;
	if (_driver == NULL || _music == NULL) {
		return;
	}
	if (MADWasReading(_driver)) {
		MADStopMusic(_driver);
		[self updateTransportButtonStates];
		self.statusField.stringValue = @"Playback paused • Space resumes";
	} else {
		[self playPlayback:nil];
	}
}

- (IBAction)playPlayback:(id)sender
{
	(void)sender;
	if (_driver == NULL || _music == NULL) return;
	// MIDI controls are intentionally live. Read the visible pane again here so
	// playback cannot fall back to a stale draft value if AppKit has updated a
	// popup's selection without delivering its action yet.
	if (self.preferencesPanel.isVisible &&
		self.preferencesCategoryPopup.indexOfSelectedItem == PPPreferencesCategoryMIDI) {
		[self captureVisiblePreferenceValues];
		[self applyMIDIPreferenceDraftRouting];
	}
	if (!MADWasReading(_driver)) {
		if (_driver->base.musicEnd) [self resetTransportToSelectedPatternPreservingPlayback:NO];
		MADPlayMusic(_driver);
	}
	[self updateTransportButtonStates];
	self.statusField.stringValue = [NSString stringWithFormat:@"Playing pattern %03ld • Space pauses", (long)_selectedPattern];
}

- (IBAction)stopPlayback:(id)sender
{
	(void)sender;
	if (_driver != NULL && _music != NULL && MADWasReading(_driver)) MADStopMusic(_driver);
	[self updateTransportButtonStates];
	self.statusField.stringValue = @"Playback stopped • Play resumes at this position";
}

- (IBAction)rewind:(id)sender
{
	(void)sender;
	[self resetTransportToSelectedPatternPreservingPlayback:YES];
	self.statusField.stringValue = [NSString stringWithFormat:@"Pattern %03ld rewound", (long)_selectedPattern];
}

- (void)moveTransportToPartitionPosition:(NSInteger)position
{
	if (_driver == NULL || _music == NULL || _music->header == NULL || _music->header->numPointers <= 0) return;
	position = MIN(MAX(position, 0), _music->header->numPointers - 1);
	NSInteger pattern = _music->header->oPointers[position];
	if (pattern < 0 || pattern >= _music->header->numPat || _music->partition[pattern] == NULL) return;
	BOOL wasPlaying = MADWasReading(_driver);
	self.selectedPartitionPosition = position;
	_selectedPattern = pattern;
	self.suppressPartitionSelectionAction = YES;
	[self.partitionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:position] byExtendingSelection:NO];
	[self.partitionTable scrollRowToVisible:position];
	self.suppressPartitionSelectionAction = NO;
	self.suppressPatternSelectionTransportReset = YES;
	[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:pattern] byExtendingSelection:NO];
	[self.orderTable scrollRowToVisible:pattern];
	self.suppressPatternSelectionTransportReset = NO;
	[self resetTransportToSelectedPatternPreservingPlayback:wasPlaying];
	[self.patternTable reloadData];
	PatData *data = [self selectedPatternData];
	if (data != NULL && data->header.size > 0) [self selectPatternTop:0 bottom:0 left:0 right:0];
	[self updatePatternWindowTitle];
	[self updateTransportButtonStates];
	self.statusField.stringValue = [NSString stringWithFormat:@"Partition position %ld → pattern %03ld",
		(long)position + 1, (long)pattern];
}

- (IBAction)previousPartition:(id)sender
{
	(void)sender;
	NSInteger position = self.selectedPartitionPosition;
	if (_driver != NULL && MADWasReading(_driver)) position = _driver->base.PL;
	[self moveTransportToPartitionPosition:MAX(position - 1, 0)];
}

- (IBAction)nextPartition:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL) return;
	NSInteger position = self.selectedPartitionPosition;
	if (_driver != NULL && MADWasReading(_driver)) position = _driver->base.PL;
	[self moveTransportToPartitionPosition:MIN(position + 1, _music->header->numPointers - 1)];
}

- (void)scanTransportByTicks:(long)delta
{
	if (_driver == NULL || _music == NULL) return;
	long fullTime = 1;
	long currentTime = 0;
	if (MADGetMusicStatus(_driver, &fullTime, &currentTime) != MADNoErr) return;
	long target = MIN(MAX(currentTime + delta, 0), MAX(fullTime, 1));
	MADSetMusicStatus(_driver, 0, MAX(fullTime, 1), target);
	self.positionSlider.doubleValue = (double)target / (double)MAX(fullTime, 1);
	self.timeField.stringValue = [self formattedTime:target];
}

- (IBAction)scanBackward:(id)sender
{
	(void)sender;
	[self scanTransportByTicks:-12];
	self.statusField.stringValue = @"Scanning backward";
}

- (IBAction)scanForward:(id)sender
{
	(void)sender;
	[self scanTransportByTicks:12];
	self.statusField.stringValue = @"Scanning forward";
}

- (IBAction)toggleToolsRecording:(NSButton *)sender
{
	BOOL enabled = sender.state == NSControlStateValueOn;
	[self.pianoController setRecordingEnabled:enabled];
	self.statusField.stringValue = enabled
		? @"Piano recording armed • notes write to the selected Digital track"
		: @"Piano recording off • audition only";
}

- (IBAction)togglePatternLoop:(NSButton *)sender
{
	BOOL loop = sender.state == NSControlStateValueOn;
	if (_driver != NULL) _driver->JumpToNextPattern = !loop;
	self.statusField.stringValue = loop ? @"Current-pattern loop on" : @"Current-pattern loop off";
}

- (void)displayPatternFromPlaybackTrace:(NSInteger)patternIndex
{
	if (_music == NULL || _music->header == NULL || patternIndex < 0 || patternIndex >= _music->header->numPat ||
		patternIndex >= MAXPATTERN || _music->partition[patternIndex] == NULL) return;
	_selectedPattern = patternIndex;
	if (_driver != NULL && _driver->base.PL >= 0 && _driver->base.PL < _music->header->numPointers) {
		self.selectedPartitionPosition = _driver->base.PL;
		self.suppressPartitionSelectionAction = YES;
		[self.partitionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:self.selectedPartitionPosition]
			byExtendingSelection:NO];
		[self.partitionTable scrollRowToVisible:self.selectedPartitionPosition];
		self.suppressPartitionSelectionAction = NO;
	}
	self.suppressPatternSelectionTransportReset = YES;
	[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:patternIndex] byExtendingSelection:NO];
	[self.orderTable scrollRowToVisible:patternIndex];
	self.suppressPatternSelectionTransportReset = NO;
	PatData *pattern = [self selectedPatternData];
	NSInteger cursorRow = MIN(MAX(self.patternCursorRow, 0), MAX((NSInteger)pattern->header.size - 1, 0));
	NSInteger cursorChannel = MIN(MAX(self.patternCursorChannel, 0), MAX((NSInteger)_music->header->numChn - 1, 0));
	NSInteger anchorRow = MIN(MAX(self.patternSelectionAnchorRow, 0), MAX((NSInteger)pattern->header.size - 1, 0));
	NSInteger anchorChannel = MIN(MAX(self.patternSelectionAnchorChannel, 0), MAX((NSInteger)_music->header->numChn - 1, 0));
	[self updatePatternSelectionFromAnchorRow:anchorRow channel:anchorChannel
		cursorRow:cursorRow channel:cursorChannel revealCursor:NO];
	[self updatePatternWindowTitle];
}

- (void)reloadDigitalPlaybackRow:(NSInteger)row pattern:(NSInteger)pattern
{
	if (pattern != _selectedPattern || row < 0 || row >= self.patternTable.numberOfRows) return;
	[self.patternTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
		columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.patternTable.tableColumns.count)]];
}

- (void)refreshVisiblePatternRowBackgrounds
{
	if (self.patternTable == nil) return;
	NSRange visibleRows = [self.patternTable rowsInRect:self.patternTable.visibleRect];
	if (visibleRows.location == NSNotFound) return;
	for (NSInteger row = (NSInteger)visibleRows.location; row < (NSInteger)NSMaxRange(visibleRows); row++) {
		PPClassicRowView *rowView = (PPClassicRowView *)[self.patternTable rowViewAtRow:row makeIfNecessary:NO];
		if (![rowView isKindOfClass:PPClassicRowView.class]) continue;
		rowView.markerBand = ((row / self.patternBandRows) % 2) == 0;
		rowView.playbackRow = self.patternPlaybackPattern == _selectedPattern && self.patternPlaybackRow == row;
		rowView.drawsStepRule = [NSUserDefaults.standardUserDefaults boolForKey:PPDigitalRowGuidesDefaultsKey];
		[rowView setNeedsDisplay:YES];
	}
}

- (void)updateDigitalPlaybackPositionForce:(BOOL)force
{
	BOOL reading = _driver != NULL && _music != NULL && MADWasReading(_driver);
	NSInteger oldPattern = self.patternPlaybackPattern;
	NSInteger oldRow = self.patternPlaybackRow;
	if (!reading) {
		if (oldRow >= 0) {
			self.patternPlaybackPattern = self.patternPlaybackRow = -1;
			[self reloadDigitalPlaybackRow:oldRow pattern:oldPattern];
			[self refreshVisiblePatternRowBackgrounds];
		}
		return;
	}
	NSInteger patternIndex = _driver->base.Pat;
	if (patternIndex < 0 || patternIndex >= MAXPATTERN || _music->partition[patternIndex] == NULL) return;
	NSInteger row = MAX((NSInteger)_driver->base.PartitionReader - 1, 0);
	row = MIN(row, MAX((NSInteger)_music->partition[patternIndex]->header.size - 1, 0));
	BOOL changed = patternIndex != oldPattern || row != oldRow;
	if (!changed && !force) return;
	self.patternPlaybackPattern = patternIndex;
	self.patternPlaybackRow = row;
	if (changed) [self reloadDigitalPlaybackRow:oldRow pattern:oldPattern];
	if (self.patternTraceEnabled && patternIndex != _selectedPattern) {
		[self displayPatternFromPlaybackTrace:patternIndex];
	} else if (changed) {
		[self reloadDigitalPlaybackRow:row pattern:patternIndex];
	}
	if (self.patternTraceEnabled) [self.patternTable scrollRowToVisible:row];
	[self refreshVisiblePatternRowBackgrounds];
}

- (IBAction)togglePatternTrace:(NSButton *)sender
{
	self.patternTraceEnabled = sender == nil ? !self.patternTraceEnabled : sender.state == NSControlStateValueOn;
	[NSUserDefaults.standardUserDefaults setBool:self.patternTraceEnabled forKey:PPDigitalTraceDefaultsKey];
	self.patternTraceButton.state = self.patternTraceEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	if (self.patternTraceEnabled) [self updateDigitalPlaybackPositionForce:YES];
	self.statusField.stringValue = self.patternTraceEnabled
		? @"Digital trace on • following the playing pattern and row"
		: @"Digital trace off • playback row remains highlighted in the visible pattern";
}

- (IBAction)seek:(PPClassicTransportPositionView *)sender
{
	if (_driver != NULL && _music != NULL) {
		MADSetMusicStatus(_driver, 0, 1000, (long)llround(sender.doubleValue * 1000.0));
	}
}

- (void)updatePlaybackStatus:(NSTimer *)timer
{
	(void)timer;
	self.window.documentEdited = _music != NULL && _music->hasChanged;
	if (_driver == NULL || _music == NULL) {
		return;
	}
	long fullTime = 1;
	long currentTime = 0;
	if (MADGetMusicStatus(_driver, &fullTime, &currentTime) == MADNoErr) {
		self.positionSlider.doubleValue = fullTime > 0 ? (double)currentTime / (double)fullTime : 0;
		self.timeField.stringValue = [self formattedTime:currentTime];
		self.durationField.stringValue = [self formattedTime:fullTime];
	}
	if (_driver->base.musicEnd) {
		if (!self.musicListHandledEnd) {
			self.musicListHandledEnd = YES;
			BOOL continuedPlayback = self.musicListPlaybackMode != 0 &&
				[self advanceMusicListAfterPlaybackEnd];
			if (!continuedPlayback &&
				[NSUserDefaults.standardUserDefaults boolForKey:PPMusicListReturnToStartDefaultsKey] &&
				_music->header != NULL && _music->header->numPointers > 0) {
				_selectedPattern = _music->header->oPointers[0];
				self.selectedPartitionPosition = 0;
				[self resetTransportToSelectedPatternPreservingPlayback:NO];
				self.statusField.stringValue = @"Playback finished • returned to start";
			} else if (!continuedPlayback) {
				// Stop the public transport as well as the core reader.  This
				// releases the Play state immediately instead of leaving an
				// active Core Audio stream rendering silence after the last row.
				MADStopMusic(_driver);
				self.statusField.stringValue = @"Playback stopped • end of song";
			}
		}
	} else {
		self.musicListHandledEnd = NO;
	}
	[self updateTransportButtonStates];
	self.toolsRecordButton.state = self.pianoController.isRecordingEnabled
		? NSControlStateValueOn : NSControlStateValueOff;
	[self updateDigitalPlaybackPositionForce:NO];
	BOOL oscilloscopeVisible = self.oscilloscopeWindow.isVisible;
	BOOL spectrumVisible = self.spectrumWindow.isVisible;
	if ((oscilloscopeVisible || spectrumVisible) && _driver->base.OscilloWavePtr != NULL) {
		NSUInteger byteCount = MIN((NSUInteger)_driver->base.OscilloWaveSize, (NSUInteger)(1024 * 1024));
		NSInteger sampleBits = _driver->DriverSettings.outPutBits == 8 ? 8 : 16;
		NSInteger channels = _driver->DriverSettings.outPutMode == MonoOutPut ? 1 : 2;
		NSData *audio = [NSData dataWithBytes:_driver->base.OscilloWavePtr length:byteCount];
		if (oscilloscopeVisible) {
			self.oscilloscopeView.sampleBits = sampleBits;
			self.oscilloscopeView.channelCount = channels;
			self.oscilloscopeView.pcmData = audio;
			[self.oscilloscopeView setNeedsDisplay:YES];
		}
		if (spectrumVisible) {
			self.spectrumView.sampleBits = sampleBits;
			self.spectrumView.channelCount = channels;
			self.spectrumView.sampleRate = _driver->DriverSettings.outPutRate;
			self.spectrumView.pcmData = audio;
			[self.spectrumView setNeedsDisplay:YES];
		}
	}
	[self.pianoController updatePlaybackHighlights];
}

#pragma mark - Tables

- (NSInteger)instrumentDisplayCount
{
	if (_music == NULL || _music->header == NULL) return 0;
	// The MADK loader expands numInstru to MAXINSTRU after relocating sparse
	// instrument IDs. That value is storage capacity, not a request to display
	// 255 empty instruments. The 2002 list stopped at the last real instrument.
	NSInteger lastUsed = -1;
	for (NSInteger instrument = 0; instrument < MAXINSTRU; instrument++) {
		InstrData *data = &_music->fid[instrument];
		if (data->name[0] != 0 || data->numSamples > 0) lastUsed = instrument;
	}
	return MAX(lastUsed + 1, 1);
}

- (NSInteger)instrumentListRowCount
{
	NSInteger rows = 0;
	for (NSInteger instrument = 0; instrument < MAXINSTRU; instrument++) {
		rows++;
		if (![self.collapsedInstrumentIndexes containsIndex:(NSUInteger)instrument]) {
			rows += MAX((NSInteger)_music->fid[instrument].numSamples, 0);
		}
	}
	return rows;
}

- (BOOL)decodeInstrumentListRow:(NSInteger)row instrument:(NSInteger *)instrumentOut sample:(NSInteger *)sampleOut
{
	NSInteger cursor = 0;
	for (NSInteger instrument = 0; instrument < MAXINSTRU; instrument++) {
		if (row == cursor) {
			if (instrumentOut != NULL) *instrumentOut = instrument;
			if (sampleOut != NULL) *sampleOut = -1;
			return YES;
		}
		cursor++;
		NSInteger sampleCount = [self.collapsedInstrumentIndexes containsIndex:(NSUInteger)instrument]
			? 0 : MAX((NSInteger)_music->fid[instrument].numSamples, 0);
		if (row >= cursor && row < cursor + sampleCount) {
			if (instrumentOut != NULL) *instrumentOut = instrument;
			if (sampleOut != NULL) *sampleOut = row - cursor;
			return YES;
		}
		cursor += sampleCount;
	}
	return NO;
}

- (void)rebuildPatternColumns
{
	while (self.patternTable.tableColumns.count > 0) {
		[self.patternTable removeTableColumn:self.patternTable.tableColumns.lastObject];
	}
	NSTableColumn *rowColumn = [[NSTableColumn alloc] initWithIdentifier:@"row"];
	PPClassicHeaderCell *rowHeader = [[PPClassicHeaderCell alloc] initTextCell:@""];
	rowHeader.classicColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
	rowColumn.headerCell = rowHeader;
	rowColumn.width = 21;
	rowColumn.minWidth = 21;
	rowColumn.maxWidth = 21;
	[self.patternTable addTableColumn:rowColumn];

	NSUInteger channels = _music == NULL ? 4 : MAX((NSUInteger)_music->header->numChn, 1);
	// The classic editor used StringWidth("000 C-4 F FF FF") + 6. Measuring
	// the same 15-character command in the active Monaco replacement preserves
	// the old compact track density even when font metrics differ slightly.
	CGFloat commandWidth = ceil([@"000 C-4 F FF FF" sizeWithAttributes:@{NSFontAttributeName: [self classicFont]}].width) + 6.0;
	for (NSUInteger channel = 0; channel < channels; channel++) {
		NSString *identifier = [PPPatternColumnPrefix stringByAppendingFormat:@"%lu", (unsigned long)channel];
		NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
		PPClassicHeaderCell *header = [[PPClassicHeaderCell alloc] initTextCell:[NSString stringWithFormat:@"%lu", (unsigned long)channel + 1]];
		header.classicColor = PPPreferredTrackColor((NSInteger)channel);
		column.headerCell = header;
		column.width = commandWidth;
		column.minWidth = commandWidth;
		column.maxWidth = commandWidth;
		[self.patternTable addTableColumn:column];
	}
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	if (tableView == self.musicListTable) return self.musicListEntries.count;
	if (_music == NULL || _music->header == NULL) {
		return 0;
	}
	if (tableView == self.orderTable) {
		return _music->header->numPat;
	}
	if (tableView == self.partitionTable) {
		// numPointers is an 8-bit length, while the original window kept the
		// remaining sequence slots visible as inactive zero-valued placeholders.
		return UINT8_MAX;
	}
	if (tableView == self.instrumentTable) {
		return [self instrumentListRowCount];
	}
	PatData *pattern = [self selectedPatternData];
	return pattern == NULL ? 0 : pattern->header.size;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	if (tableView == self.musicListTable) {
		NSTextField *field = [tableView makeViewWithIdentifier:@"music-list-cell" owner:self];
		if (field == nil) {
			field = [NSTextField labelWithString:@""];
			field.identifier = @"music-list-cell";
			field.font = [self classicFont];
			field.textColor = NSColor.blackColor;
			field.lineBreakMode = NSLineBreakByTruncatingMiddle;
		}
		NSURL *URL = self.musicListEntries[row];
		NSString *current = row == self.musicListActiveIndex ? @"✓" : @" ";
		field.stringValue = [NSString stringWithFormat:@"%@ %03ld  %@", current, (long)row + 1, URL.lastPathComponent];
		field.toolTip = URL.path;
		return field;
	}
	if (tableView == self.partitionTable) {
		PPPartitionCellView *cell = [tableView makeViewWithIdentifier:@"partition-cell" owner:self];
		if (cell == nil) {
			cell = [[PPPartitionCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, tableView.rowHeight)];
			cell.identifier = @"partition-cell";
			cell.positionField.font = [self classicFont];
			cell.patternField.font = [self classicFont];
			cell.nameField.font = [self classicFont];
			cell.patternPopup.font = [self classicFont];
		}
		NSInteger patternID = _music->header->oPointers[row];
		cell.positionField.stringValue = [NSString stringWithFormat:@"%ld:", (long)row + 1];
		cell.patternField.stringValue = [NSString stringWithFormat:@"%ld", (long)patternID];
		// At the 94-point original compact width, the first pixel of the hidden
		// name field otherwise remains visible immediately before the scroller.
		cell.nameField.hidden = !self.partitionInspectorExpanded;
		PatData *selectedPattern = patternID >= 0 && patternID < _music->header->numPat
			? _music->partition[patternID] : NULL;
		cell.nameField.stringValue = !self.partitionInspectorExpanded || selectedPattern == NULL ? @"" :
			[self stringFromLegacyBytes:selectedPattern->header.name
				length:sizeof(selectedPattern->header.name) fallback:@""];
		[cell.patternPopup removeAllItems];
		[cell.patternPopup addItemWithTitle:@""];
		for (NSInteger pattern = 0; pattern < _music->header->numPat; pattern++) {
			PatData *data = _music->partition[pattern];
			NSString *name = data == NULL ? @"" : [self stringFromLegacyBytes:data->header.name
				length:sizeof(data->header.name) fallback:@""];
			NSString *title = name.length == 0 ? [NSString stringWithFormat:@"%03ld", (long)pattern]
				: [NSString stringWithFormat:@"%03ld  %@", (long)pattern, name];
			NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
				action:@selector(choosePartitionPattern:) keyEquivalent:@""];
			item.target = self;
			item.representedObject = @((row << 8) | pattern);
			item.state = pattern == patternID ? NSControlStateValueOn : NSControlStateValueOff;
			[cell.patternPopup.menu addItem:item];
		}
		cell.patternPopup.toolTip = [NSString stringWithFormat:@"Choose the pattern for sequence position %ld", (long)row + 1];
		return cell;
	}

	if (tableView == self.instrumentTable) {
		NSInteger instrument = 0, sample = -1;
		if (![self decodeInstrumentListRow:row instrument:&instrument sample:&sample]) return nil;
		PPInstrumentListCellView *cell = [tableView makeViewWithIdentifier:@"instrument-list-cell" owner:self];
		if (cell == nil) {
			cell = [[PPInstrumentListCellView alloc] initWithFrame:NSMakeRect(0, 0,
				tableColumn.width, tableView.rowHeight)];
			cell.identifier = @"instrument-list-cell";
			cell.textField.font = [self classicFont];
			cell.textField.delegate = self;
			cell.previewButton.image = [self classicImageNamed:@"instrument-play"];
		}
		cell.disclosureButton.hidden = sample >= 0 || _music->fid[instrument].numSamples <= 0;
		cell.previewButton.hidden = sample < 0;
		cell.disclosureButton.title = [self.collapsedInstrumentIndexes containsIndex:(NSUInteger)instrument]
			? @"▸" : @"▾";
		cell.disclosureButton.tag = instrument;
		cell.disclosureButton.target = self;
		cell.disclosureButton.action = @selector(toggleInstrumentDisclosure:);
		cell.disclosureButton.toolTip = @"Expand or collapse this instrument";
		cell.previewButton.tag = (instrument << 8) | (sample + 1);
		cell.previewButton.target = self;
		cell.previewButton.action = @selector(previewInstrumentListSample:);
		cell.previewButton.toolTip = @"Preview this sample";
		cell.textField.identifier = sample < 0 ? @"instrument-cell" : @"sample-cell";
		cell.textField.editable = YES;
		cell.textField.selectable = YES;
		cell.textField.tag = (instrument << 8) | (sample + 1);
		if (sample < 0) {
			NSString *displayName = [self stringFromLegacyBytes:_music->fid[instrument].name
				length:sizeof(_music->fid[instrument].name) fallback:@""];
			cell.textField.stringValue = displayName.length == 0
				? [NSString stringWithFormat:@"%03ld", (long)instrument + 1]
				: [NSString stringWithFormat:@"%03ld  %@", (long)instrument + 1, displayName];
		} else {
			sData *data = _music->sample[_music->fid[instrument].firstSample + sample];
			cell.textField.stringValue = [NSString stringWithFormat:@"%02ld  %@", (long)sample,
				data == NULL ? @"—" : [self stringFromLegacyBytes:data->name
					length:sizeof(data->name) fallback:@"Untitled Sample"]];
		}
		[cell setNeedsLayout:YES];
		return cell;
	}

	PPPatternCommandCellView *field = (PPPatternCommandCellView *)[tableView makeViewWithIdentifier:@"cell" owner:self];
	if (field == nil) {
		field = [PPPatternCommandCellView labelWithString:@""];
		field.identifier = @"cell";
		field.font = [self classicFont];
		field.textColor = NSColor.blackColor;
		field.lineBreakMode = NSLineBreakByClipping;
		field.drawsBackground = NO;
	}
	field.drawsPatternGuides = NO;
	field.drawsRightTrackBorder = NO;
	field.patternSelected = NO;
	field.patternCursor = NO;
	field.patternField = 0;

	if (tableView == self.orderTable) {
		field.identifier = @"order-cell";
		field.editable = NO;
		PatData *pattern = row < MAXPATTERN ? _music->partition[row] : NULL;
		NSString *name = pattern == NULL ? @"" : [self stringFromLegacyBytes:pattern->header.name
			length:sizeof(pattern->header.name) fallback:@""];
		field.stringValue = [NSString stringWithFormat:@"%03ld       %4d          %@", (long)row,
			pattern == NULL ? 0 : pattern->header.size, name];
	} else if ([tableColumn.identifier isEqualToString:@"row"]) {
		field.identifier = @"row-cell";
		field.editable = NO;
		// DrawLeft() in the 2002 editor displayed the pattern's zero-based row.
		field.stringValue = [NSString stringWithFormat:@"%03ld", (long)row];
		field.alignment = NSTextAlignmentLeft;
	} else {
		NSInteger channel = [tableColumn.identifier substringFromIndex:PPPatternColumnPrefix.length].integerValue;
		field.identifier = @"command-cell";
		field.drawsPatternGuides = [NSUserDefaults.standardUserDefaults boolForKey:PPDigitalFieldGuidesDefaultsKey];
		field.drawsRightTrackBorder = channel == (NSInteger)_music->header->numChn - 1;
		field.patternSelected = row >= self.patternSelectionTop && row <= self.patternSelectionBottom &&
			channel >= self.patternSelectionLeft && channel <= self.patternSelectionRight;
		field.patternCursor = row == self.patternCursorRow && channel == self.patternCursorChannel &&
			!(self.patternTraceEnabled && _driver != NULL && MADWasReading(_driver));
		field.patternField = self.patternField;
		field.delegate = self;
		field.editable = NO;
		field.selectable = NO;
		field.alignment = NSTextAlignmentLeft;
		field.tag = (row << 9) | channel;
		Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
		NSString *text = [self stringForCommand:command];
		NSMutableParagraphStyle *commandStyle = [[NSMutableParagraphStyle alloc] init];
		commandStyle.firstLineHeadIndent = 2.0;
		commandStyle.headIndent = 2.0;
		commandStyle.lineBreakMode = NSLineBreakByClipping;
		NSMutableAttributedString *display = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
			NSFontAttributeName: [self classicFont], NSForegroundColorAttributeName: NSColor.blackColor,
			NSParagraphStyleAttributeName: commandStyle
		}];
		field.attributedStringValue = display;
	}
	return field;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
	if (tableView == self.musicListTable || tableView == self.instrumentTable) {
		return [[PPClassicListRowView alloc] initWithFrame:NSZeroRect];
	}
	if (tableView == self.partitionTable) {
		PPPartitionRowView *rowView = [[PPPartitionRowView alloc] initWithFrame:NSZeroRect];
		rowView.activePosition = _music != NULL && _music->header != NULL && row < _music->header->numPointers;
		return rowView;
	}
	PPClassicRowView *rowView = [[PPClassicRowView alloc] initWithFrame:NSZeroRect];
	rowView.drawsStepRule = tableView == self.patternTable &&
		[NSUserDefaults.standardUserDefaults boolForKey:PPDigitalRowGuidesDefaultsKey];
	rowView.markerBand = tableView == self.patternTable &&
		((row / self.patternBandRows) % 2 == 0);
	rowView.playbackRow = tableView == self.patternTable && self.patternPlaybackPattern == _selectedPattern &&
		self.patternPlaybackRow == row;
	if (tableView == self.patternTable && tableView.tableColumns.count > 0) {
		rowView.patternContentWidth = NSMaxX([tableView rectOfColumn:tableView.tableColumns.count - 1]);
	}
	return rowView;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info
	proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation
{
	(void)row;
	if (tableView != self.musicListTable) return NSDragOperationNone;
	NSArray *URLs = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
		options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	if (URLs.count > 0 && dropOperation != NSTableViewDropAbove) {
		[tableView setDropRow:MAX(row, 0) dropOperation:NSTableViewDropAbove];
	}
	return URLs.count > 0 ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info
	row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation
{
	if (tableView != self.musicListTable || dropOperation != NSTableViewDropAbove) return NO;
	NSArray<NSURL *> *URLs = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
		options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
	if (URLs.count == 1 && [URLs.firstObject.pathExtension.lowercaseString isEqualToString:@"mplaylist"]) {
		[self readMusicListAtURL:URLs.firstObject];
		return YES;
	}
	[self addURLsToMusicList:URLs atIndex:row < 0 ? self.musicListEntries.count : row];
	return URLs.count > 0;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	NSTextField *field = notification.object;
	if (_music == NULL || _music->header == NULL) {
		return;
	}
	if ([field.identifier isEqualToString:@"music-title"]) {
		[self copyString:field.stringValue toLegacyBuffer:_music->header->name length:sizeof(_music->header->name)];
		_music->hasChanged = true;
		[self updateToolsTitle];
		return;
	}
	if ([field.identifier hasPrefix:@"tools-"]) {
		[self applyToolsCommandInspectorField:field];
		return;
	}
	if ([field.identifier isEqualToString:@"instrument-cell"]) {
		NSInteger instrument = field.tag >> 8;
		if (instrument >= 0 && instrument < MAXINSTRU) {
			NSRange search = NSMakeRange(MIN((NSUInteger)3, field.stringValue.length),
				field.stringValue.length - MIN((NSUInteger)3, field.stringValue.length));
			NSRange separator = [field.stringValue rangeOfString:@"  " options:0 range:search];
			NSString *name = separator.location == NSNotFound ? @""
				: [field.stringValue substringFromIndex:NSMaxRange(separator)];
			name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			[self copyString:name toLegacyBuffer:_music->fid[instrument].name length:sizeof(_music->fid[instrument].name)];
			if (name.length > 0) _music->header->numInstru = (MADByte)MAX((NSInteger)_music->header->numInstru, instrument + 1);
			_music->hasChanged = true;
			[self.instrumentTable reloadData];
			[self rebuildPatternInstrumentPopup];
			[self updateInstrumentDetails];
		}
		return;
	}
	if ([field.identifier isEqualToString:@"sample-cell"]) {
		NSInteger instrument = field.tag >> 8;
		NSInteger sample = (field.tag & 0xFF) - 1;
		if (instrument >= 0 && instrument < MAXINSTRU && sample >= 0 && sample < _music->fid[instrument].numSamples) {
			sData *data = _music->sample[_music->fid[instrument].firstSample + sample];
			NSUInteger start = MIN((NSUInteger)2, field.stringValue.length);
			NSRange separator = [field.stringValue rangeOfString:@"  " options:0
				range:NSMakeRange(start, field.stringValue.length - start)];
			NSString *name = separator.location == NSNotFound ? @""
				: [field.stringValue substringFromIndex:NSMaxRange(separator)];
			name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			[self copyString:name toLegacyBuffer:data->name length:sizeof(data->name)];
			_music->hasChanged = true;
			[self.instrumentTable reloadData];
			[self updateInstrumentDetails];
		}
		return;
	}
	if (![field.identifier isEqualToString:@"command-cell"]) {
		return;
	}

		NSInteger row = field.tag >> 9;
	NSInteger channel = field.tag & 0x1FF;
	Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	if (command == NULL || ![self parseCommandString:field.stringValue intoCommand:command]) {
		NSBeep();
		field.stringValue = [self stringForCommand:command];
			self.statusField.stringValue = @"Use Digital format: 001 C-4 F 06 40 (effects 0-F, G, L, O; OFF and --- are accepted)";
		return;
	}
	[self registerPatternUndoSnapshot:snapshot actionName:@"Edit Pattern Command"];
	_music->hasChanged = true;
	field.stringValue = [self stringForCommand:command];
	self.statusField.stringValue = @"Pattern changed";
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	if (notification.object == self.partitionTable && self.partitionTable.selectedRow >= 0 &&
		_music != NULL && _music->header != NULL && !self.suppressPartitionSelectionAction) {
		NSInteger position = self.partitionTable.selectedRow;
		self.selectedPartitionPosition = position;
		if (position < _music->header->numPointers) {
			NSInteger pattern = _music->header->oPointers[position];
			if (pattern < _music->header->numPat && _music->partition[pattern] != NULL) {
				_selectedPattern = pattern;
				self.suppressPatternSelectionTransportReset = YES;
				[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:pattern] byExtendingSelection:NO];
				[self.orderTable scrollRowToVisible:pattern];
				self.suppressPatternSelectionTransportReset = NO;
				[self resetTransportToSelectedPatternPreservingPlayback:YES];
				[self.patternTable reloadData];
				PatData *data = [self selectedPatternData];
				if (data != NULL && data->header.size > 0) [self selectPatternTop:0 bottom:0 left:0 right:0];
				[self updatePatternWindowTitle];
				self.statusField.stringValue = [NSString stringWithFormat:@"Partition position %ld → pattern %03ld",
					(long)position + 1, (long)pattern];
			}
		}
	}
	if (notification.object == self.orderTable && self.orderTable.selectedRow >= 0 && _music != NULL) {
		_selectedPattern = self.orderTable.selectedRow;
		if (!self.suppressPatternSelectionTransportReset) {
			[self resetTransportToSelectedPatternPreservingPlayback:YES];
			[self.patternTable reloadData];
			if ([self selectedPatternData] != NULL && [self selectedPatternData]->header.size > 0) {
				[self selectPatternTop:0 bottom:0 left:0 right:0];
			}
		}
		[self updatePatternWindowTitle];
	}
	if (notification.object == self.instrumentTable && self.instrumentTable.selectedRow >= 0 && _music != NULL) {
		NSInteger instrument = 0, sample = -1;
		if ([self decodeInstrumentListRow:self.instrumentTable.selectedRow instrument:&instrument sample:&sample]) {
			_selectedInstrument = instrument;
			_selectedSample = sample;
			self.defaultPatternInstrument = (MADByte)MIN(instrument + 1, 255);
			[self updateInstrumentDetails];
			[self updatePatternInstrumentDisplay];
			[self.pianoController setSelectedInstrument:_selectedInstrument
				selectedTrack:MAX(self.patternCursorChannel, 0)];
		}
	}
	if (notification.object == self.patternTable && _music != NULL) {
		[self.pianoController setSelectedInstrument:_selectedInstrument
			selectedTrack:MAX(self.patternCursorChannel, 0)];
	}
}

- (PatData *)selectedPatternData
{
	if (_music == NULL || _selectedPattern < 0 || _selectedPattern >= MAXPATTERN) {
		return NULL;
	}
	return _music->partition[_selectedPattern];
}

- (void)updatePatternWindowTitle
{
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL) {
		self.window.title = [NSString stringWithFormat:@"Pattern: %03ld", (long)MAX(_selectedPattern, 0)];
		[self updateToolsTitle];
		return;
	}
	NSString *name = [self stringFromLegacyBytes:pattern->header.name length:sizeof(pattern->header.name) fallback:@""];
	self.window.title = [NSString stringWithFormat:@"Pattern: %03ld %@- %d Rows",
		(long)_selectedPattern, name, pattern->header.size];
	[self updateToolsTitle];
}

#pragma mark - Pattern collection

- (void)updatePartitionLengthDisplay
{
	NSInteger length = _music == NULL || _music->header == NULL ? 0 : _music->header->numPointers;
	self.partitionLengthField.stringValue = [NSString stringWithFormat:@"Length : %ld", (long)length];
}

- (IBAction)togglePartitionInspector:(id)sender
{
	(void)sender;
	self.partitionInspectorExpanded = !self.partitionInspectorExpanded;
	self.partitionWidthButton.partitionExpanded = self.partitionInspectorExpanded;
	self.partitionWidthButton.toolTip = self.partitionInspectorExpanded
		? @"Hide pattern names" : @"Show pattern names";
	[self.partitionWidthButton setNeedsDisplay:YES];

	NSPoint topLeft = NSMakePoint(NSMinX(self.partitionWindow.frame), NSMaxY(self.partitionWindow.frame));
	NSSize contentSize = self.partitionWindow.contentView.bounds.size;
	contentSize.width = self.partitionInspectorExpanded
		? PPPartitionExpandedWidth : PPPartitionCompactWidth;
	[self.partitionWindow setContentSize:contentSize];
	[self.partitionWindow setFrameTopLeftPoint:topLeft];
	PPPartitionHeaderCell *header = (PPPartitionHeaderCell *)self.partitionTable.tableColumns.firstObject.headerCell;
	header.showsName = self.partitionInspectorExpanded;
	self.partitionHeaderOverlay.showsName = self.partitionInspectorExpanded;
	[self.partitionHeaderOverlay setNeedsDisplay:YES];
	self.partitionTable.tableColumns.firstObject.width = self.partitionInspectorExpanded
		? PPPartitionExpandedColumnWidth : PPPartitionCompactColumnWidth;
	[self.partitionTable.headerView setNeedsDisplay:YES];
	[self.partitionTable reloadData];
}

- (IBAction)editSelectedPartitionPatternInformation:(id)sender
{
	if (_music == NULL || _music->header == NULL || _music->header->numPat == 0) return;
	BOOL fromContextMenu = [sender isKindOfClass:NSMenuItem.class];
	NSInteger position = fromContextMenu && self.partitionTable.clickedRow >= 0
		? self.partitionTable.clickedRow : self.partitionTable.selectedRow;
	if (position < 0 || position >= UINT8_MAX) { NSBeep(); return; }
	NSInteger pattern = _music->header->oPointers[position];
	if (pattern < 0 || pattern >= _music->header->numPat || _music->partition[pattern] == NULL) {
		NSBeep();
		return;
	}
	_selectedPattern = pattern;
	self.suppressPatternSelectionTransportReset = YES;
	[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:pattern] byExtendingSelection:NO];
	self.suppressPatternSelectionTransportReset = NO;
	[self editPatternInformation:nil];
}

- (void)finishPartitionChangeWithSnapshot:(PPPatternCollectionSnapshot *)snapshot
	actionName:(NSString *)actionName wasPlaying:(BOOL)wasPlaying status:(NSString *)status
{
	if (_music == NULL || _music->header == NULL || _music->header->numPointers == 0) return;
	self.selectedPartitionPosition = MIN(MAX(self.selectedPartitionPosition, 0), _music->header->numPointers - 1);
	NSInteger pattern = _music->header->oPointers[self.selectedPartitionPosition];
	pattern = MIN(MAX(pattern, 0), MAX((NSInteger)_music->header->numPat - 1, 0));
	[self registerPatternCollectionUndoSnapshot:snapshot actionName:actionName];
	[self finishPatternStructureChangeSelecting:pattern wasPlaying:wasPlaying status:status];
}

- (IBAction)choosePartitionPattern:(NSMenuItem *)sender
{
	if (_music == NULL || _music->header == NULL || _music->header->numPat == 0) return;
	NSInteger encoded = [sender.representedObject integerValue];
	NSInteger position = (encoded >> 8) & 0xFF;
	NSInteger pattern = encoded & 0xFF;
	if (position < 0 || position >= UINT8_MAX || pattern < 0 || pattern >= _music->header->numPat) return;
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	if (position >= _music->header->numPointers) {
		for (NSInteger index = _music->header->numPointers; index <= position; index++) {
			_music->header->oPointers[index] = 0;
		}
		_music->header->numPointers = (MADByte)(position + 1);
	}
	_music->header->oPointers[position] = (MADByte)pattern;
	self.selectedPartitionPosition = position;
	[self finishPartitionChangeWithSnapshot:snapshot actionName:@"Change Partition"
		wasPlaying:wasPlaying status:[NSString stringWithFormat:@"Partition position %ld now uses pattern %03ld",
			(long)position + 1, (long)pattern]];
}

- (IBAction)insertPartitionPosition:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL || _music->header->numPointers >= UINT8_MAX) { NSBeep(); return; }
	NSInteger length = _music->header->numPointers;
	if (length == 0) {
		PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
		BOOL wasPlaying = [self stopForPatternStructureChange];
		_music->header->oPointers[0] = 0;
		_music->header->numPointers = 1;
		self.selectedPartitionPosition = 0;
		[self finishPartitionChangeWithSnapshot:snapshot actionName:@"Insert Partition Position"
			wasPlaying:wasPlaying status:@"Inserted partition position 1"];
		return;
	}
	NSInteger source = MIN(MAX(self.partitionTable.selectedRow, 0), length - 1);
	NSInteger insertion = MIN(source + 1, length);
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	for (NSInteger index = length; index > insertion; index--) {
		_music->header->oPointers[index] = _music->header->oPointers[index - 1];
	}
	_music->header->oPointers[insertion] = _music->header->oPointers[source];
	_music->header->numPointers = (MADByte)(length + 1);
	self.selectedPartitionPosition = insertion;
	[self finishPartitionChangeWithSnapshot:snapshot actionName:@"Insert Partition Position"
		wasPlaying:wasPlaying status:[NSString stringWithFormat:@"Inserted partition position %ld", (long)insertion + 1]];
}

- (IBAction)removePartitionPosition:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL || _music->header->numPointers <= 1) { NSBeep(); return; }
	NSInteger position = MIN(MAX(self.partitionTable.selectedRow, 0), _music->header->numPointers - 1);
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	for (NSInteger index = position; index + 1 < _music->header->numPointers; index++) {
		_music->header->oPointers[index] = _music->header->oPointers[index + 1];
	}
	_music->header->numPointers--;
	_music->header->oPointers[_music->header->numPointers] = 0;
	self.selectedPartitionPosition = MIN(position, _music->header->numPointers - 1);
	[self finishPartitionChangeWithSnapshot:snapshot actionName:@"Remove Partition Position"
		wasPlaying:wasPlaying status:[NSString stringWithFormat:@"Removed partition position %ld", (long)position + 1]];
}

- (void)movePartitionPositionBy:(NSInteger)delta
{
	if (_music == NULL || _music->header == NULL) return;
	NSInteger position = self.partitionTable.selectedRow;
	NSInteger destination = position + delta;
	if (position < 0 || position >= _music->header->numPointers || destination < 0 ||
		destination >= _music->header->numPointers) { NSBeep(); return; }
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	MADByte value = _music->header->oPointers[position];
	_music->header->oPointers[position] = _music->header->oPointers[destination];
	_music->header->oPointers[destination] = value;
	self.selectedPartitionPosition = destination;
	[self finishPartitionChangeWithSnapshot:snapshot actionName:@"Move Partition Position"
		wasPlaying:wasPlaying status:[NSString stringWithFormat:@"Moved partition position to %ld", (long)destination + 1]];
}

- (IBAction)movePartitionPositionUp:(id)sender { (void)sender; [self movePartitionPositionBy:-1]; }
- (IBAction)movePartitionPositionDown:(id)sender { (void)sender; [self movePartitionPositionBy:1]; }

- (PPPatternCollectionSnapshot *)capturePatternCollectionSnapshot
{
	PPPatternCollectionSnapshot *snapshot = [[PPPatternCollectionSnapshot alloc] init];
	snapshot.selectedPattern = _selectedPattern;
	snapshot.selectedPartitionPosition = self.selectedPartitionPosition;
	if (_music == NULL || _music->header == NULL) {
		snapshot.headerData = [NSData data];
		snapshot.patterns = @[];
		return snapshot;
	}
	snapshot.headerData = [NSData dataWithBytes:_music->header length:sizeof(*_music->header)];
	NSMutableArray<NSData *> *patterns = [NSMutableArray arrayWithCapacity:_music->header->numPat];
	for (NSInteger index = 0; index < _music->header->numPat; index++) {
		PatData *pattern = _music->partition[index];
		if (pattern == NULL || pattern->header.size <= 0) {
			[patterns addObject:[NSData data]];
			continue;
		}
		NSUInteger size = sizeof(PatHeader) + (NSUInteger)_music->header->numChn *
			(NSUInteger)pattern->header.size * sizeof(Cmd);
		[patterns addObject:[NSData dataWithBytes:pattern length:size]];
	}
	snapshot.patterns = patterns;
	return snapshot;
}

- (void)registerPatternCollectionUndoSnapshot:(PPPatternCollectionSnapshot *)snapshot actionName:(NSString *)name
{
	[[self.window.undoManager prepareWithInvocationTarget:self] restorePatternCollectionSnapshot:snapshot actionName:name];
	[self.window.undoManager setActionName:name];
}

- (BOOL)stopForPatternStructureChange
{
	BOOL wasPlaying = _driver != NULL && MADWasReading(_driver);
	if (_driver != NULL) MADStopMusic(_driver);
	if (_music != NULL) _music->musicUnderModification = true;
	return wasPlaying;
}

- (void)finishPatternStructureChangeSelecting:(NSInteger)pattern wasPlaying:(BOOL)wasPlaying status:(NSString *)status
{
	if (_music == NULL || _music->header == NULL) return;
	_music->musicUnderModification = false;
	_music->hasChanged = true;
	_selectedPattern = MIN(MAX(pattern, 0), MAX((NSInteger)_music->header->numPat - 1, 0));
	if (_driver != NULL) {
		if (_driver->DriverSettings.numChn != _music->header->numChn) {
			MADChangeTracks(_driver, _music->header->numChn);
		}
		MADCleanDriver(_driver);
		MADAttachDriverToMusic(_driver, _music, NULL);
		if (wasPlaying) MADPlayMusic(_driver);
	}
	[self rebuildPatternColumns];
	[self.orderTable reloadData];
	[self.partitionTable reloadData];
	[self updatePartitionLengthDisplay];
	[self.patternTable reloadData];
	[self.mixerController attachMusic:_music driver:_driver];
	[self.pianoController attachMusic:_music driver:_driver selectedInstrument:_selectedInstrument
		selectedTrack:MIN(MAX(self.patternCursorChannel, 0), MAX((NSInteger)_music->header->numChn - 1, 0))];
	if (self.orderTable.numberOfRows > 0) {
		[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:_selectedPattern] byExtendingSelection:NO];
		[self.orderTable scrollRowToVisible:_selectedPattern];
	}
	if (self.partitionTable.numberOfRows > 0) {
		self.selectedPartitionPosition = MIN(MAX(self.selectedPartitionPosition, 0),
			MAX((NSInteger)_music->header->numPointers - 1, 0));
		self.suppressPartitionSelectionAction = YES;
		[self.partitionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:self.selectedPartitionPosition]
			byExtendingSelection:NO];
		[self.partitionTable scrollRowToVisible:self.selectedPartitionPosition];
		self.suppressPartitionSelectionAction = NO;
	}
	PatData *selected = [self selectedPatternData];
	if (selected != NULL && selected->header.size > 0 && _music->header->numChn > 0) {
		[self selectPatternTop:0 bottom:0 left:0 right:0];
	}
	[self updatePatternWindowTitle];
	self.statusField.stringValue = status;
}

- (void)restorePatternCollectionSnapshot:(PPPatternCollectionSnapshot *)snapshot actionName:(NSString *)name
{
	if (_music == NULL || snapshot.headerData.length != sizeof(*_music->header)) return;
	const MADSpec *savedHeader = snapshot.headerData.bytes;
	if (snapshot.patterns.count < savedHeader->numPat) return;
	NSMutableArray<NSValue *> *allocations = [NSMutableArray arrayWithCapacity:savedHeader->numPat];
	for (NSInteger index = 0; index < savedHeader->numPat; index++) {
		NSData *data = snapshot.patterns[index];
		void *allocation = NULL;
		if (data.length > 0) {
			allocation = malloc(data.length);
			if (allocation == NULL) {
				for (NSValue *value in allocations) free(value.pointerValue);
				NSBeep();
				self.statusField.stringValue = @"Not enough memory to restore pattern Undo";
				return;
			}
			memcpy(allocation, data.bytes, data.length);
		}
		[allocations addObject:[NSValue valueWithPointer:allocation]];
	}
	PPPatternCollectionSnapshot *redo = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	for (NSInteger index = 0; index < MAXPATTERN; index++) {
		free(_music->partition[index]);
		_music->partition[index] = NULL;
	}
	memcpy(_music->header, savedHeader, sizeof(*_music->header));
	self.selectedPartitionPosition = snapshot.selectedPartitionPosition;
	for (NSInteger index = 0; index < savedHeader->numPat; index++) {
		_music->partition[index] = allocations[index].pointerValue;
	}
	[self registerPatternCollectionUndoSnapshot:redo actionName:name];
	[self finishPatternStructureChangeSelecting:snapshot.selectedPattern wasPlaying:wasPlaying status:name];
}

- (NSInteger)selectedPatternListIndex
{
	NSInteger pattern = self.orderTable.selectedRow;
	if (pattern < 0) pattern = _selectedPattern;
	if (_music == NULL || _music->header == NULL || pattern < 0 || pattern >= _music->header->numPat) return -1;
	return pattern;
}

- (IBAction)selectPreviousPattern:(id)sender
{
	(void)sender;
	NSInteger pattern = [self selectedPatternListIndex];
	if (pattern <= 0) { NSBeep(); return; }
	[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:pattern - 1] byExtendingSelection:NO];
	[self.orderTable scrollRowToVisible:pattern - 1];
}

- (IBAction)selectNextPattern:(id)sender
{
	(void)sender;
	NSInteger pattern = [self selectedPatternListIndex];
	if (_music == NULL || pattern < 0 || pattern + 1 >= _music->header->numPat) { NSBeep(); return; }
	[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:pattern + 1] byExtendingSelection:NO];
	[self.orderTable scrollRowToVisible:pattern + 1];
}

- (IBAction)newPattern:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL || _music->header->numPat >= MAXPATTERN) { NSBeep(); return; }
	NSUInteger size = sizeof(PatHeader) + (NSUInteger)_music->header->numChn * 64 * sizeof(Cmd);
	PatData *pattern = calloc(size, 1);
	if (pattern == NULL) { NSBeep(); return; }
	pattern->header.size = 64;
	pattern->header.compMode = PatternCompressionNone;
	memcpy(pattern->header.name, "New pattern", 11);
	for (NSInteger channel = 0; channel < _music->header->numChn; channel++) {
		for (NSInteger row = 0; row < 64; row++) MADKillCmd(GetMADCommand((short)row, (short)channel, pattern));
	}
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	NSInteger newIndex = _music->header->numPat;
	_music->partition[newIndex] = pattern;
	_music->header->numPat++;
	[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"New Pattern"];
	[self finishPatternStructureChangeSelecting:newIndex wasPlaying:wasPlaying status:@"Created a new 64-row pattern"];
}

- (IBAction)loadPatternFile:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL || _music->header->numPat >= MAXPATTERN) {
		NSBeep();
		self.statusField.stringValue = @"The song cannot contain another pattern";
		return;
	}
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.title = @"Load Pattern";
	panel.message = @"Choose a standalone PlayerPRO pattern file.";
	panel.prompt = @"Load";
	panel.canChooseDirectories = NO;
	panel.canChooseFiles = YES;
	panel.allowsMultipleSelection = NO;
	// Do not extension-filter: Classic PATN files commonly have no suffix and
	// their Finder type metadata may not survive transfer to a modern disk.
	[panel beginSheetModalForWindow:self.patternsWindow completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK || panel.URL == nil || self->_music == NULL ||
			self->_music->header == NULL) return;
		NSError *readError = nil;
		NSData *data = [NSData dataWithContentsOfURL:panel.URL
			options:NSDataReadingMappedIfSafe error:&readError];
		NSError *patternError = nil;
		PatData *pattern = data == nil ? NULL : PPCreatePatternFromFileData(data,
			self->_music->header->numChn, &patternError);
		NSError *displayError = readError ?: patternError;
		if (pattern == NULL) {
			NSAlert *alert = [NSAlert alertWithError:displayError ?:
				PPPatternFileError(@"The pattern could not be loaded.")];
			[alert beginSheetModalForWindow:self.patternsWindow completionHandler:nil];
			return;
		}
		if (self->_music->header->numPat >= MAXPATTERN) {
			free(pattern);
			NSBeep();
			self.statusField.stringValue = @"The song cannot contain another pattern";
			return;
		}
		PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
		BOOL wasPlaying = [self stopForPatternStructureChange];
		NSInteger newIndex = self->_music->header->numPat;
		self->_music->partition[newIndex] = pattern;
		self->_music->header->numPat++;
		[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"Load Pattern"];
		[self finishPatternStructureChangeSelecting:newIndex wasPlaying:wasPlaying
			status:[NSString stringWithFormat:@"Loaded pattern %@", panel.URL.lastPathComponent]];
	}];
}

- (IBAction)savePatternFile:(id)sender
{
	(void)sender;
	NSInteger patternIndex = [self selectedPatternListIndex];
	if (patternIndex < 0 || _music == NULL || _music->header == NULL) { NSBeep(); return; }
	PatData *pattern = _music->partition[patternIndex];
	if (pattern == NULL) { NSBeep(); return; }
	NSString *patternName = [self stringFromLegacyBytes:pattern->header.name
		length:sizeof(pattern->header.name) fallback:@""];
	if (patternName.length == 0) patternName = [NSString stringWithFormat:@"Pattern %03ld", (long)patternIndex];

	NSSavePanel *panel = [NSSavePanel savePanel];
	panel.title = @"Save Pattern";
	panel.message = @"Save the selected pattern as a standalone PlayerPRO pattern file.";
	panel.prompt = @"Save";
	panel.allowedFileTypes = @[@"patn"];
	panel.allowsOtherFileTypes = YES;
	panel.nameFieldStringValue = [patternName stringByAppendingPathExtension:@"patn"];
	[panel beginSheetModalForWindow:self.patternsWindow completionHandler:^(NSModalResponse result) {
		if (result != NSModalResponseOK || panel.URL == nil || self->_music == NULL ||
			self->_music->header == NULL || patternIndex >= self->_music->header->numPat) return;
		PatData *currentPattern = self->_music->partition[patternIndex];
		if (currentPattern == NULL) return;
		NSString *savedName = panel.URL.URLByDeletingPathExtension.lastPathComponent;
		NSData *data = PPCreatePatternFileData(currentPattern, self->_music->header->numChn, savedName);
		NSError *writeError = nil;
		if (data == nil || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&writeError]) {
			NSAlert *alert = [NSAlert alertWithError:writeError ?:
				PPPatternFileError(@"The pattern could not be saved.")];
			[alert beginSheetModalForWindow:self.patternsWindow completionHandler:nil];
			return;
		}
		// SaveAPatternInt in the 2002 application renamed the pattern to match
		// the file. Preserve that visible behavior, with Undo support.
		PPPatternSnapshot *snapshot = [self capturePatternSnapshot:patternIndex];
		[self copyString:savedName toLegacyBuffer:currentPattern->header.name
			length:sizeof(currentPattern->header.name)];
		[self registerPatternUndoSnapshot:snapshot actionName:@"Rename Saved Pattern"];
		self->_music->hasChanged = true;
		[self.orderTable reloadData];
		[self.partitionTable reloadData];
		[self updatePatternWindowTitle];
		self.statusField.stringValue = [NSString stringWithFormat:@"Saved pattern %@", panel.URL.lastPathComponent];
	}];
}

- (IBAction)duplicatePattern:(id)sender
{
	(void)sender;
	NSInteger sourceIndex = [self selectedPatternListIndex];
	if (sourceIndex < 0 || _music->header->numPat >= MAXPATTERN) { NSBeep(); return; }
	PatData *source = _music->partition[sourceIndex];
	if (source == NULL) return;
	NSUInteger size = sizeof(PatHeader) + (NSUInteger)_music->header->numChn *
		(NSUInteger)source->header.size * sizeof(Cmd);
	PatData *copy = malloc(size);
	if (copy == NULL) { NSBeep(); return; }
	memcpy(copy, source, size);
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	NSInteger newIndex = _music->header->numPat;
	_music->partition[newIndex] = copy;
	_music->header->numPat++;
	[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"Duplicate Pattern"];
	[self finishPatternStructureChangeSelecting:newIndex wasPlaying:wasPlaying status:@"Pattern duplicated"];
}

- (IBAction)deletePattern:(id)sender
{
	(void)sender;
	NSInteger pattern = [self selectedPatternListIndex];
	if (pattern < 0) return;
	if (_music->header->numPat <= 1) {
		NSBeep(); self.statusField.stringValue = @"A music file must contain at least one pattern"; return;
	}
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:@"Delete pattern %03ld?", (long)pattern];
	alert.informativeText = @"Sequence entries that use it will be reset to pattern 000. Later pattern IDs will be renumbered.";
	[alert addButtonWithTitle:@"Delete"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.patternsWindow completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn || self->_music == NULL) return;
		PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
		BOOL wasPlaying = [self stopForPatternStructureChange];
		free(self->_music->partition[pattern]);
		self->_music->header->numPat--;
		for (NSInteger index = pattern; index < self->_music->header->numPat; index++) {
			self->_music->partition[index] = self->_music->partition[index + 1];
		}
		self->_music->partition[self->_music->header->numPat] = NULL;
		for (NSInteger index = 0; index < self->_music->header->numPointers; index++) {
			if (self->_music->header->oPointers[index] > pattern) self->_music->header->oPointers[index]--;
			else if (self->_music->header->oPointers[index] == pattern) self->_music->header->oPointers[index] = 0;
		}
		[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"Delete Pattern"];
		[self finishPatternStructureChangeSelecting:MIN(pattern, self->_music->header->numPat - 1)
			wasPlaying:wasPlaying status:@"Pattern deleted and sequence references updated"];
	}];
}

- (IBAction)purgePattern:(id)sender
{
	(void)sender;
	NSInteger patternIndex = [self selectedPatternListIndex];
	if (patternIndex < 0) return;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat:@"Purge pattern %03ld?", (long)patternIndex];
	alert.informativeText = @"Every note, instrument, effect, argument, and volume command in this pattern will be cleared.";
	[alert addButtonWithTitle:@"Purge"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.patternsWindow completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn || self->_music == NULL) return;
		PPPatternSnapshot *snapshot = [self capturePatternSnapshot:patternIndex];
		PatData *pattern = self->_music->partition[patternIndex];
		for (NSInteger channel = 0; channel < self->_music->header->numChn; channel++) {
			for (NSInteger row = 0; row < pattern->header.size; row++) MADKillCmd(GetMADCommand((short)row, (short)channel, pattern));
		}
		[self registerPatternUndoSnapshot:snapshot actionName:@"Purge Pattern"];
		self->_music->hasChanged = true;
		[self.patternTable reloadData];
		self.statusField.stringValue = @"Pattern purged";
	}];
}

- (NSInteger)initialSpeedForPattern:(PatData *)pattern tempo:(BOOL)tempo
{
	NSInteger channel = tempo ? 1 : 0;
	if (pattern == NULL || _music == NULL || _music->header == NULL ||
		channel >= _music->header->numChn || pattern->header.size <= 0) return -1;
	Cmd *command = GetMADCommand(0, (short)channel, pattern);
	if (command == NULL || command->cmd != MADEffectSpeed) return -1;
	if (tempo) return command->arg >= 32 ? command->arg : -1;
	return command->arg < 32 ? command->arg : -1;
}

- (void)setInitialSpeed:(NSInteger)value tempo:(BOOL)tempo forPattern:(PatData *)pattern
{
	NSInteger channel = tempo ? 1 : 0;
	if (pattern == NULL || _music == NULL || _music->header == NULL ||
		channel >= _music->header->numChn || pattern->header.size <= 0) return;
	Cmd *command = GetMADCommand(0, (short)channel, pattern);
	if (command == NULL) return;
	if (value < 0) {
		if ([self initialSpeedForPattern:pattern tempo:tempo] >= 0) {
			command->cmd = MADEffectArpeggio;
			command->arg = 0;
		}
		return;
	}
	command->cmd = MADEffectSpeed;
	command->arg = (MADByte)value;
}

- (IBAction)editPatternInformation:(id)sender
{
	(void)sender;
	NSInteger patternIndex = [self selectedPatternListIndex];
	if (patternIndex < 0) return;
	PatData *pattern = _music->partition[patternIndex];
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Pattern Info";
	[alert addButtonWithTitle:@"Apply"];
	[alert addButtonWithTitle:@"Cancel"];
	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 218)];
	NSTextField *nameLabel = [NSTextField labelWithString:@"Name:"];
	nameLabel.frame = NSMakeRect(0, 193, 84, 18); [accessory addSubview:nameLabel];
	NSTextField *nameField = [NSTextField textFieldWithString:[self stringFromLegacyBytes:pattern->header.name
		length:sizeof(pattern->header.name) fallback:@""]];
	nameField.frame = NSMakeRect(86, 191, 244, 22); [accessory addSubview:nameField];
	NSTextField *rowsLabel = [NSTextField labelWithString:@"Rows:"];
	rowsLabel.frame = NSMakeRect(0, 163, 84, 18); [accessory addSubview:rowsLabel];
	NSTextField *rowsField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%d", pattern->header.size]];
	rowsField.frame = NSMakeRect(86, 161, 72, 22); [accessory addSubview:rowsField];
	NSTextField *rangeLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"(1…%d)", MAXPATTERNSIZE]];
	rangeLabel.frame = NSMakeRect(166, 163, 100, 18); [accessory addSubview:rangeLabel];

	NSTextField *compressionLabel = [NSTextField labelWithString:@"Compression:"];
	compressionLabel.frame = NSMakeRect(0, 133, 84, 18); [accessory addSubview:compressionLabel];
	NSPopUpButton *compressionPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(86, 131, 110, 24) pullsDown:NO];
	[compressionPopup addItemsWithTitles:@[@"NONE", @"MAD1"]];
	[compressionPopup selectItemAtIndex:pattern->header.compMode == PatternCompressionMAD1 ? 1 : 0];
	[accessory addSubview:compressionPopup];

	NSTextField *markerLabel = [NSTextField labelWithString:@"Highlighted rows:"];
	markerLabel.frame = NSMakeRect(0, 103, 116, 18); [accessory addSubview:markerLabel];
	NSTextField *markerField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%ld", (long)self.patternBandRows]];
	markerField.frame = NSMakeRect(120, 101, 38, 22); [accessory addSubview:markerField];
	NSTextField *markerRange = [NSTextField labelWithString:@"(1…64; default 4)"];
	markerRange.frame = NSMakeRect(166, 103, 132, 18); [accessory addSubview:markerRange];

	NSInteger speed = [self initialSpeedForPattern:pattern tempo:NO];
	NSButton *speedEnabled = [NSButton checkboxWithTitle:@"Speed:" target:nil action:nil];
	speedEnabled.frame = NSMakeRect(0, 68, 84, 22);
	speedEnabled.state = speed > 0 ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:speedEnabled];
	NSTextField *speedField = [NSTextField textFieldWithString:speed > 0 ? [NSString stringWithFormat:@"%ld", (long)speed] : @""];
	speedField.frame = NSMakeRect(86, 68, 72, 22); [accessory addSubview:speedField];
	NSTextField *speedRange = [NSTextField labelWithString:@"(0…31)"];
	speedRange.frame = NSMakeRect(166, 70, 80, 18); [accessory addSubview:speedRange];

	NSInteger tempo = [self initialSpeedForPattern:pattern tempo:YES];
	NSButton *tempoEnabled = [NSButton checkboxWithTitle:@"Tempo:" target:nil action:nil];
	tempoEnabled.frame = NSMakeRect(0, 38, 84, 22);
	tempoEnabled.state = tempo >= 32 ? NSControlStateValueOn : NSControlStateValueOff;
	[accessory addSubview:tempoEnabled];
	NSTextField *tempoField = [NSTextField textFieldWithString:tempo >= 32 ? [NSString stringWithFormat:@"%ld", (long)tempo] : @""];
	tempoField.frame = NSMakeRect(86, 38, 72, 22); [accessory addSubview:tempoField];
	NSTextField *tempoRange = [NSTextField labelWithString:@"(32…255)"];
	tempoRange.frame = NSMakeRect(166, 40, 90, 18); [accessory addSubview:tempoRange];
	if (_music->header->numChn < 2) {
		tempoEnabled.enabled = NO;
		tempoField.enabled = NO;
	}

	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 29, 330, 1)];
	separator.boxType = NSBoxSeparator; [accessory addSubview:separator];
	NSUInteger patternBytes = sizeof(PatHeader) + (NSUInteger)_music->header->numChn *
		(NSUInteger)pattern->header.size * sizeof(Cmd);
	NSTextField *details = [NSTextField labelWithString:[NSString stringWithFormat:@"ID: %ld      Tracks: %d      Size in bytes: %lu",
		(long)patternIndex, _music->header->numChn, (unsigned long)patternBytes]];
	details.frame = NSMakeRect(0, 2, 330, 18); [accessory addSubview:details];
	alert.accessoryView = accessory;
	[alert beginSheetModalForWindow:self.patternsWindow completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn || self->_music == NULL) return;
		BOOL (^parseInteger)(NSTextField *, NSInteger *) = ^BOOL(NSTextField *field, NSInteger *value) {
			NSScanner *scanner = [NSScanner scannerWithString:field.stringValue];
			scanner.charactersToBeSkipped = nil;
			return [scanner scanInteger:value] && scanner.isAtEnd;
		};
		NSInteger rows = 0;
		if (!parseInteger(rowsField, &rows) || rows < 1 || rows > MAXPATTERNSIZE) {
			NSBeep(); self.statusField.stringValue = @"Pattern row count is outside the supported range"; return;
		}
		NSInteger markerRows = 0;
		if (!parseInteger(markerField, &markerRows) || markerRows < 1 || markerRows > 64) {
			NSBeep(); self.statusField.stringValue = @"Highlighted rows must be between 1 and 64"; return;
		}
		NSInteger newSpeed = -1;
		if (speedEnabled.state == NSControlStateValueOn &&
			(!parseInteger(speedField, &newSpeed) || newSpeed < 1 || newSpeed > 31)) {
			NSBeep(); self.statusField.stringValue = @"Pattern speed must be between 1 and 31"; return;
		}
		NSInteger newTempo = -1;
		if (tempoEnabled.state == NSControlStateValueOn &&
			(!parseInteger(tempoField, &newTempo) || newTempo < 32 || newTempo > 255)) {
			NSBeep(); self.statusField.stringValue = @"Pattern tempo must be between 32 and 255"; return;
		}
		PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
		BOOL wasPlaying = [self stopForPatternStructureChange];
		PatData *oldPattern = self->_music->partition[patternIndex];
		if (rows != oldPattern->header.size) {
			NSUInteger size = sizeof(PatHeader) + (NSUInteger)self->_music->header->numChn * (NSUInteger)rows * sizeof(Cmd);
			PatData *resized = calloc(size, 1);
			if (resized == NULL) {
				[self finishPatternStructureChangeSelecting:patternIndex wasPlaying:wasPlaying status:@"Pattern resize failed"];
				NSBeep(); return;
			}
			resized->header = oldPattern->header;
			resized->header.size = (int)rows;
			resized->header.patBytes = 0;
			for (NSInteger channel = 0; channel < self->_music->header->numChn; channel++) {
				for (NSInteger row = 0; row < rows; row++) {
					Cmd *destination = GetMADCommand((short)row, (short)channel, resized);
					if (row < oldPattern->header.size) *destination = *GetMADCommand((short)row, (short)channel, oldPattern);
					else MADKillCmd(destination);
				}
			}
			free(oldPattern);
			self->_music->partition[patternIndex] = resized;
			oldPattern = resized;
		}
		[self copyString:nameField.stringValue toLegacyBuffer:oldPattern->header.name length:sizeof(oldPattern->header.name)];
		oldPattern->header.compMode = compressionPopup.indexOfSelectedItem == 1
			? PatternCompressionMAD1 : PatternCompressionNone;
		oldPattern->header.patBytes = 0;
		[self setInitialSpeed:newSpeed tempo:NO forPattern:oldPattern];
		[self setInitialSpeed:newTempo tempo:YES forPattern:oldPattern];
		self.patternBandRows = markerRows;
		[NSUserDefaults.standardUserDefaults setInteger:markerRows forKey:PPPatternBandRowsDefaultsKey];
		[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"Pattern Information"];
		[self finishPatternStructureChangeSelecting:patternIndex wasPlaying:wasPlaying status:@"Pattern information updated"];
		[self refreshVisiblePatternRowBackgrounds];
	}];
}

- (IBAction)convertPatternsTo64Rows:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL) return;
	NSInteger projectedPatterns = 0;
	NSInteger projectedPointers = _music->header->numPointers;
	for (NSInteger index = 0; index < _music->header->numPat; index++) {
		NSInteger pieces = MAX((_music->partition[index]->header.size + 63) / 64, 1);
		projectedPatterns += pieces;
		for (NSInteger pointer = 0; pointer < _music->header->numPointers; pointer++) {
			if (_music->header->oPointers[pointer] == index) projectedPointers += pieces - 1;
		}
	}
	if (projectedPatterns > MAXPATTERN || projectedPointers > UINT8_MAX) {
		NSBeep(); self.statusField.stringValue = @"64-row conversion would exceed the MADK pattern or sequence limit"; return;
	}
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Convert every pattern to 64 rows?";
	alert.informativeText = @"Long patterns will be split and sequence references expanded. Short patterns receive a pattern-break command at their former end.";
	[alert addButtonWithTitle:@"Convert"];
	[alert addButtonWithTitle:@"Cancel"];
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn || self->_music == NULL) return;
		PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
		BOOL wasPlaying = [self stopForPatternStructureChange];
		ConvertTo64Rows(self->_music);
		[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"Convert Patterns to 64 Rows"];
		[self finishPatternStructureChangeSelecting:MIN(self->_selectedPattern, self->_music->header->numPat - 1)
			wasPlaying:wasPlaying status:@"Converted all patterns to 64-row blocks"];
	}];
}

#pragma mark - Instruments and Samples

- (sData *)selectedSampleData
{
	if (_music == NULL || _selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU ||
		_selectedSample < 0 || _selectedSample >= _music->fid[_selectedInstrument].numSamples) return NULL;
	return _music->sample[_music->fid[_selectedInstrument].firstSample + _selectedSample];
}

- (NSInteger)rowForInstrument:(NSInteger)instrument sample:(NSInteger)sample
{
	NSInteger row = 0;
	for (NSInteger current = 0; current < instrument; current++) {
		row++;
		if (![self.collapsedInstrumentIndexes containsIndex:(NSUInteger)current]) {
			row += _music->fid[current].numSamples;
		}
	}
	return row + (sample < 0 ? 0 : sample + 1);
}

- (void)selectInstrument:(NSInteger)instrument sample:(NSInteger)sample
{
	if (sample >= 0 && [self.collapsedInstrumentIndexes containsIndex:(NSUInteger)instrument]) {
		[self.collapsedInstrumentIndexes removeIndex:(NSUInteger)instrument];
		[self.instrumentTable reloadData];
	}
	_selectedInstrument = instrument;
	_selectedSample = sample;
	self.defaultPatternInstrument = (MADByte)MIN(MAX(instrument + 1, 1), 255);
	NSInteger row = [self rowForInstrument:instrument sample:sample];
	if (row >= 0 && row < self.instrumentTable.numberOfRows) {
		[self.instrumentTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		[self.instrumentTable scrollRowToVisible:row];
	}
	[self updateInstrumentDetails];
	[self updatePatternInstrumentDisplay];
	[self.pianoController setSelectedInstrument:_selectedInstrument
		selectedTrack:MAX(self.patternCursorChannel, 0)];
}

- (void)updatePatternInstrumentDisplay
{
	if (self.patternInstrumentToggle == nil) return;
	self.patternInstrumentToggle.title = [NSString stringWithFormat:@"Ins:%03u", self.defaultPatternInstrument];
	[self rebuildPatternInstrumentPopup];
}

- (void)updateInstrumentSummary
{
	NSInteger instrumentCount = 0;
	NSInteger sampleCount = 0;
	unsigned long long byteCount = 0;
	if (_music != NULL && _music->header != NULL) {
		for (NSInteger instrument = 0; instrument < MAXINSTRU; instrument++) {
			InstrData *info = &_music->fid[instrument];
			if (info->name[0] != 0 || info->numSamples > 0) instrumentCount++;
			NSInteger samples = MAX((NSInteger)info->numSamples, 0);
			sampleCount += samples;
			for (NSInteger sample = 0; sample < samples; sample++) {
				sData *data = _music->sample[info->firstSample + sample];
				if (data != NULL && data->size > 0) byteCount += (unsigned long long)data->size;
			}
		}
	}
	self.instrumentSummaryField.stringValue = [NSString stringWithFormat:@"%llu b, #ins: %ld, #samples: %ld",
		byteCount, (long)instrumentCount, (long)sampleCount];
}

- (IBAction)toggleInstrumentInspector:(id)sender
{
	(void)sender;
	self.instrumentInspectorExpanded = !self.instrumentInspectorExpanded;
	self.instrumentInspectorButton.inspectorExpanded = self.instrumentInspectorExpanded;
	self.instrumentInspectorButton.toolTip = self.instrumentInspectorExpanded
		? @"Hide instrument and sample information" : @"Show instrument and sample information";
	[self.instrumentInspectorButton setNeedsDisplay:YES];

	NSPoint topLeft = NSMakePoint(NSMinX(self.instrumentsWindow.frame), NSMaxY(self.instrumentsWindow.frame));
	NSSize contentSize = self.instrumentsWindow.contentView.bounds.size;
	contentSize.width = self.instrumentInspectorExpanded
		? PPInstrumentListExpandedWidth : PPInstrumentListCompactWidth;
	self.instrumentDetailView.hidden = !self.instrumentInspectorExpanded;
	[self.instrumentsWindow setContentSize:contentSize];
	[self.instrumentsWindow setFrameTopLeftPoint:topLeft];
	[self updateInstrumentDetails];
}

- (void)updateInstrumentDetails
{
	[self updateInstrumentSummary];
	if (self.instrumentDetailValues.count < 10) return;
	if (_music == NULL || _music->header == NULL) {
		for (NSTextField *field in self.instrumentDetailValues) field.stringValue = @"-";
		return;
	}
	NSInteger instrument = MIN(MAX(_selectedInstrument, 0), MAXINSTRU - 1);
	InstrData *info = &_music->fid[instrument];
	self.instrumentDetailValues[0].stringValue = [NSString stringWithFormat:@"%03ld", (long)instrument + 1];
	self.instrumentDetailValues[1].stringValue = [NSString stringWithFormat:@"%d", info->numSamples];
	sData *sample = [self selectedSampleData];
	if (sample == NULL) {
		unsigned long long instrumentBytes = 0;
		for (NSInteger index = 0; index < info->numSamples; index++) {
			sData *data = _music->sample[info->firstSample + index];
			if (data != NULL && data->size > 0) instrumentBytes += (unsigned long long)data->size;
		}
		self.instrumentDetailValues[2].stringValue = [NSString stringWithFormat:@"%llu b", instrumentBytes];
		for (NSInteger index = 3; index < (NSInteger)self.instrumentDetailValues.count; index++)
			self.instrumentDetailValues[index].stringValue = @"-";
		return;
	}
	self.instrumentDetailValues[2].stringValue = [NSString stringWithFormat:@"%d b", sample->size];
	self.instrumentDetailValues[3].stringValue = [NSString stringWithFormat:@"%d b", sample->loopBeg];
	self.instrumentDetailValues[4].stringValue = [NSString stringWithFormat:@"%d b", sample->loopSize];
	self.instrumentDetailValues[5].stringValue = [NSString stringWithFormat:@"%u", sample->vol];
	self.instrumentDetailValues[6].stringValue = [NSString stringWithFormat:@"%u", sample->c2spd];
	self.instrumentDetailValues[7].stringValue = [NSString stringWithFormat:@"%d", sample->realNote];
	self.instrumentDetailValues[8].stringValue = [NSString stringWithFormat:@"%u", sample->amp];
	self.instrumentDetailValues[9].stringValue = sample->stereo ? @"Stereo" : @"Mono";
}

- (void)reloadInstrumentsSelectingInstrument:(NSInteger)instrument sample:(NSInteger)sample
{
	[self.instrumentTable reloadData];
	[self selectInstrument:instrument sample:sample];
}

- (IBAction)toggleInstrumentDisclosure:(id)sender
{
	if (_music == NULL || ![sender respondsToSelector:@selector(tag)]) return;
	NSInteger instrument = [sender tag];
	if (instrument < 0 || instrument >= MAXINSTRU || _music->fid[instrument].numSamples <= 0) return;
	BOOL collapse = ![self.collapsedInstrumentIndexes containsIndex:(NSUInteger)instrument];
	if (collapse) [self.collapsedInstrumentIndexes addIndex:(NSUInteger)instrument];
	else [self.collapsedInstrumentIndexes removeIndex:(NSUInteger)instrument];
	if (collapse && _selectedInstrument == instrument && _selectedSample >= 0) _selectedSample = -1;
	[self.instrumentTable reloadData];
	[self selectInstrument:instrument sample:_selectedInstrument == instrument ? _selectedSample : -1];
	self.statusField.stringValue = [NSString stringWithFormat:@"Instrument %03ld %@",
		(long)instrument + 1, collapse ? @"collapsed" : @"expanded"];
}

- (IBAction)toggleSelectedInstrumentDisclosure:(id)sender
{
	(void)sender;
	if (_music == NULL || _selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU ||
		_music->fid[_selectedInstrument].numSamples <= 0) {
		NSBeep();
		return;
	}
	NSButton *proxy = [NSButton buttonWithTitle:@"" target:nil action:nil];
	proxy.tag = _selectedInstrument;
	[self toggleInstrumentDisclosure:proxy];
}

- (IBAction)previewInstrumentListSample:(id)sender
{
	if (_music == NULL || ![sender respondsToSelector:@selector(tag)]) return;
	NSInteger encoded = [sender tag];
	NSInteger instrument = encoded >> 8;
	NSInteger sample = (encoded & 0xFF) - 1;
	if (instrument < 0 || instrument >= MAXINSTRU || sample < 0 ||
		sample >= _music->fid[instrument].numSamples) {
		NSBeep();
		return;
	}
	[self selectInstrument:instrument sample:sample];
	[self previewSelectedSample:sender];
}

- (IBAction)newInstrument:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL) return;
	NSInteger instrument = _selectedSample < 0 ? MIN(MAX(_selectedInstrument, 0), MAXINSTRU - 1) : [self instrumentDisplayCount];
	if (_music->fid[instrument].name[0] != 0 || _music->fid[instrument].numSamples > 0) {
		instrument = [self instrumentDisplayCount];
	}
	if (instrument >= MAXINSTRU) { NSBeep(); return; }
	_music->fid[instrument].firstSample = (short)(instrument * MAXSAMPLE);
	_music->fid[instrument].no = (MADByte)instrument;
	[self copyString:[NSString stringWithFormat:@"Untitled Instrument %03ld", (long)instrument + 1]
		toLegacyBuffer:_music->fid[instrument].name length:sizeof(_music->fid[instrument].name)];
	_music->header->numInstru = (MADByte)MAX((NSInteger)_music->header->numInstru, instrument + 1);
	_music->hasChanged = true;
	[self reloadInstrumentsSelectingInstrument:instrument sample:-1];
}

- (IBAction)createSilentSample:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL || _selectedInstrument < 0 ||
		_selectedInstrument >= MAXINSTRU) return;
	NSInteger instrument = _selectedInstrument;
	NSInteger replacementIndex = _selectedSample;
	if (replacementIndex < 0 && _music->fid[instrument].numSamples >= MAXSAMPLE) {
		NSBeep();
		return;
	}

	__weak typeof(self) weakSelf = self;
	PPToneGeneratorDialogController *controller = [[PPToneGeneratorDialogController alloc]
		initWithPreviewHandler:^(PPToneGeneratorSettings settings) {
			__strong typeof(weakSelf) self = weakSelf;
			if (self == nil || self->_driver == NULL) { NSBeep(); return; }
			size_t byteCount = 0;
			void *buffer = PPCreateToneGeneratorPCM(settings, &byteCount);
			if (buffer == NULL || byteCount < 4) { free(buffer); NSBeep(); return; }
			[self stopAllSamplePreviews];
			self.rawPreviewData = [NSData dataWithBytesNoCopy:buffer length:byteCount freeWhenDone:YES];
			MADErr error = MADPlaySoundData(self->_driver, self.rawPreviewData.bytes,
				self.rawPreviewData.length, 0, 48, 16, 0, 0,
				(unsigned int)llround(PPToneGeneratorSampleRate), settings.stereo);
			if (error != MADNoErr)
				[self presentErrorCode:error operation:@"previewing the generated sample"];
		}];

	NSRect parentFrame = self.instrumentsWindow.frame;
	NSRect dialogFrame = controller.window.frame;
	dialogFrame.origin.x = NSMidX(parentFrame) - NSWidth(dialogFrame) / 2.0;
	dialogFrame.origin.y = NSMidY(parentFrame) - NSHeight(dialogFrame) / 2.0;
	[controller.window setFrame:dialogFrame display:NO];
	[controller.window makeKeyAndOrderFront:nil];
	[controller.window makeFirstResponder:controller.lengthField];
	[controller.lengthField selectText:nil];
	NSModalResponse response = [NSApp runModalForWindow:controller.window];
	[controller.window orderOut:nil];
	[self stopAllSamplePreviews];
	self.rawPreviewData = nil;
	if (response != NSModalResponseOK) return;

	PPToneGeneratorSettings settings = controller.acceptedSettings;
	size_t byteCount = 0;
	void *buffer = PPCreateToneGeneratorPCM(settings, &byteCount);
	if (buffer == NULL || byteCount < 4) { free(buffer); NSBeep(); return; }
	NSArray<NSString *> *names = @[@"Silence", @"Triangle", @"Square", @"Sine Wave"];
	NSString *name = names[settings.waveform];
	[self installSampleBuffer:buffer byteCount:byteCount bits:16 stereo:settings.stereo
		sampleRate:(unsigned int)llround(PPToneGeneratorSampleRate) name:name instrument:instrument
		replacingSample:replacementIndex statusVerb:@"Generated"];
}

- (IBAction)openSelectedSample:(id)sender
{
	(void)sender;
	if (_music == NULL) return;
	NSInteger sample = _selectedSample;
	if (sample < 0 && _music->fid[_selectedInstrument].numSamples > 0) sample = 0;
	if (sample < 0 || sample >= _music->fid[_selectedInstrument].numSamples) {
		self.statusField.stringValue = @"Load a sample before opening the Samples editor";
		NSBeep();
		return;
	}
	if (_selectedSample != sample) [self selectInstrument:_selectedInstrument sample:sample];
	__weak typeof(self) weakSelf = self;
	__block __weak PPSampleEditorController *weakEditor = nil;
	PPSampleEditorController *editor = [[PPSampleEditorController alloc] initWithMusic:_music driver:_driver
		instrument:_selectedInstrument sample:sample changeHandler:^{
			[weakSelf.instrumentTable reloadData];
			[weakSelf updateInstrumentDetails];
			weakSelf.statusField.stringValue = @"Sample changed (destructive edit)";
		} closeHandler:^{
			if (weakEditor != nil) [weakSelf.sampleEditors removeObject:weakEditor];
		}];
	weakEditor = editor;
	[self.sampleEditors addObject:editor];
	[editor showWindow:nil];
	[editor.window makeKeyAndOrderFront:nil];
}

- (IBAction)openSelectedInstrumentOrSample:(id)sender
{
	if (_selectedSample >= 0) [self openSelectedSample:sender];
	else [self openSelectedInstrumentInfo:sender];
}

- (IBAction)openSelectedInstrumentInfo:(id)sender
{
	(void)sender;
	if (_music == NULL || _selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU) return;
	__weak typeof(self) weakSelf = self;
	__block __weak PPInstrumentEditorController *weakEditor = nil;
	PPInstrumentEditorController *editor = [[PPInstrumentEditorController alloc] initWithMusic:_music driver:_driver
		instrument:_selectedInstrument sample:_selectedSample changeHandler:^{
			[weakSelf.instrumentTable reloadData];
			[weakSelf updateInstrumentDetails];
			weakSelf.statusField.stringValue = @"Instrument information changed";
		} closeHandler:^{
			if (weakEditor != nil) [weakSelf.instrumentEditors removeObject:weakEditor];
		}];
	weakEditor = editor;
	[self.instrumentEditors addObject:editor];
	[editor showWindow:nil];
	[editor.window makeKeyAndOrderFront:nil];
}

- (void)stopAllSamplePreviews
{
	[self.pianoController stopPreview];
	for (PPSampleEditorController *editor in self.sampleEditors) [editor stopPreview];
	for (PPInstrumentEditorController *editor in self.instrumentEditors) [editor stopPreview];
	for (PPPatternModeController *editor in self.patternModeEditors) [editor stopPreview];
	if (_driver != NULL) MADDriverClearChannel(_driver, 0);
}

- (IBAction)previewSelectedSample:(id)sender
{
	(void)sender;
	sData *sample = [self selectedSampleData];
	// The classic toolbar speaker auditioned the first sample when the
	// instrument parent row, rather than one of its child rows, was selected.
	if (sample == NULL && _music != NULL && _selectedInstrument >= 0 && _selectedInstrument < MAXINSTRU &&
		_music->fid[_selectedInstrument].numSamples > 0) {
		sample = _music->sample[_music->fid[_selectedInstrument].firstSample];
	}
	if (_driver == NULL || sample == NULL || sample->data == NULL || sample->size < 4) { NSBeep(); return; }
	[self stopAllSamplePreviews];
	NSInteger note = MIN(MAX(48 + sample->realNote, 0), NUMBER_NOTES - 1);
	MADErr error = MADPlaySoundData(_driver, sample->data, (size_t)sample->size, 0,
		(MADByte)note, sample->amp, sample->loopBeg, sample->loopSize, sample->c2spd, sample->stereo);
	if (error != MADNoErr) [self presentErrorCode:error operation:@"previewing the sample"];
}

- (BOOL)installSampleBuffer:(void *)buffer byteCount:(size_t)byteCount bits:(MADByte)bits
	stereo:(MADBool)stereo sampleRate:(unsigned int)sampleRate name:(NSString *)name
	instrument:(NSInteger)instrument replacingSample:(NSInteger)replacementIndex statusVerb:(NSString *)statusVerb
{
	if (_music == NULL || _music->header == NULL || buffer == NULL || byteCount == 0 || byteCount > INT_MAX ||
		instrument < 0 || instrument >= MAXINSTRU || (bits != 8 && bits != 16) ||
		sampleRate == 0 || sampleRate > USHRT_MAX) {
		free(buffer);
		NSBeep();
		return NO;
	}
	[self stopAllSamplePreviews];
	for (PPSampleEditorController *editor in self.sampleEditors.copy) [editor close];
	for (PPInstrumentEditorController *editor in self.instrumentEditors.copy) [editor close];
	NSInteger sampleIndex = replacementIndex;
	if (instrument >= _music->header->numInstru) _music->header->numInstru = (MADByte)(instrument + 1);
	_music->fid[instrument].firstSample = (short)(instrument * MAXSAMPLE);
	_music->musicUnderModification = true;
	sData *sample = NULL;
	if (sampleIndex >= 0 && sampleIndex < _music->fid[instrument].numSamples) {
		sample = _music->sample[_music->fid[instrument].firstSample + sampleIndex];
	} else if (_music->fid[instrument].numSamples < MAXSAMPLE) {
		sampleIndex = _music->fid[instrument].numSamples;
		sample = MADCreateSample(_music, (short)instrument, (short)sampleIndex);
		if (_music->header->numSamples < UINT8_MAX) _music->header->numSamples++;
	}
	if (sample == NULL) {
		_music->musicUnderModification = false;
		free(buffer);
		NSBeep();
		return NO;
	}
	free(sample->data);
	sample->data = buffer;
	sample->size = (int)byteCount;
	sample->loopBeg = 0;
	sample->loopSize = 0;
	sample->vol = MAX_VOLUME;
	sample->c2spd = (unsigned short)sampleRate;
	sample->loopType = MADLoopTypeClassic;
	sample->amp = bits;
	sample->realNote = 0;
	sample->stereo = stereo;
	NSString *displayName = name.length > 0 ? name : @"Untitled Sample";
	[self copyString:displayName toLegacyBuffer:sample->name length:sizeof(sample->name)];
	if (_music->fid[instrument].name[0] == 0) {
		[self copyString:displayName toLegacyBuffer:_music->fid[instrument].name
			length:sizeof(_music->fid[instrument].name)];
	}
	_music->musicUnderModification = false;
	_music->hasChanged = true;
	[self reloadInstrumentsSelectingInstrument:instrument sample:sampleIndex];
	self.statusField.stringValue = [NSString stringWithFormat:@"%@ %@ — %u-bit %@, %u Hz",
		statusVerb ?: @"Loaded", displayName, sample->amp, sample->stereo ? @"stereo" : @"mono", sample->c2spd];
	return YES;
}

- (IBAction)loadSample:(id)sender
{
	(void)sender;
	if (_music == NULL) return;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowsMultipleSelection = NO;
	panel.canChooseDirectories = NO;
	panel.message = _selectedSample >= 0 ? @"Replace the selected sample with an audio file" : @"Add an audio file to this instrument";
	[panel beginSheetModalForWindow:self.instrumentsWindow completionHandler:^(NSModalResponse response) {
		if (response == NSModalResponseOK) {
			[self importAudioAtURL:panel.URL instrument:self->_selectedInstrument replacingSample:self->_selectedSample];
		}
	}];
}

- (BOOL)rawSettingsFromControls:(PPRawImportControlView *)controls sourceLength:(NSUInteger)sourceLength
	settings:(PPRawSampleSettings *)settings
{
	BOOL (^parse)(NSTextField *, unsigned long long *) = ^BOOL(NSTextField *field, unsigned long long *value) {
		NSString *text = [field.stringValue stringByTrimmingCharactersInSet:
			NSCharacterSet.whitespaceAndNewlineCharacterSet];
		NSScanner *scanner = [NSScanner scannerWithString:text];
		scanner.charactersToBeSkipped = nil;
		unsigned long long parsed = 0;
		if (text.length == 0 || ![scanner scanUnsignedLongLong:&parsed] || !scanner.isAtEnd) {
			NSBeep(); [self.instrumentsWindow makeFirstResponder:field]; return NO;
		}
		*value = parsed;
		return YES;
	};
	unsigned long long header = 0, length = 0, rate = 0;
	if (!parse(controls.headerField, &header) || !parse(controls.lengthField, &length) ||
		!parse(controls.rateField, &rate)) return NO;
	if (header >= sourceLength || length > SIZE_MAX || rate < 1000 || rate > USHRT_MAX) {
		NSBeep();
		return NO;
	}
	if (settings != NULL) {
		*settings = (PPRawSampleSettings){
			.headerBytes = (size_t)header,
			.lengthBytes = (size_t)length,
			.sampleRate = (unsigned int)rate,
			.bits = controls.bitsPopup.indexOfSelectedItem == 0 ? 8 : 16,
			.stereo = controls.channelsPopup.indexOfSelectedItem == 1 ? MADTrue : MADFalse,
			.signedPCM = controls.encodingPopup.indexOfSelectedItem == 0,
			.littleEndian = controls.endianPopup.indexOfSelectedItem == 0
		};
	}
	return YES;
}

- (void)runRawImportAlert:(NSAlert *)alert controls:(PPRawImportControlView *)controls source:(NSData *)source
	URL:(NSURL *)URL instrument:(NSInteger)instrument replacingSample:(NSInteger)replacementIndex
{
	__weak typeof(self) weakSelf = self;
	[alert beginSheetModalForWindow:self.instrumentsWindow completionHandler:^(NSModalResponse response) {
		__strong typeof(weakSelf) self = weakSelf;
		if (self == nil) return;
		if (response != NSAlertFirstButtonReturn && response != NSAlertSecondButtonReturn) {
			[self stopAllSamplePreviews];
			self.rawPreviewData = nil;
			return;
		}
		PPRawSampleSettings settings = {0};
		size_t byteCount = 0;
		void *buffer = NULL;
		if ([self rawSettingsFromControls:controls sourceLength:source.length settings:&settings]) {
			buffer = PPCreateRawPCM(source, settings, &byteCount);
		}
		if (buffer == NULL || byteCount < 4) {
			free(buffer);
			NSBeep();
			dispatch_async(dispatch_get_main_queue(), ^{
				[self runRawImportAlert:alert controls:controls source:source URL:URL
					instrument:instrument replacingSample:replacementIndex];
			});
			return;
		}
		if (response == NSAlertSecondButtonReturn) {
			if (self->_driver == NULL) {
				free(buffer);
				NSBeep();
				return;
			}
			[self stopAllSamplePreviews];
			self.rawPreviewData = [NSData dataWithBytesNoCopy:buffer length:byteCount freeWhenDone:YES];
			MADErr error = MADPlaySoundData(self->_driver, self.rawPreviewData.bytes, self.rawPreviewData.length, 0,
				48, settings.bits, 0, 0, settings.sampleRate, settings.stereo);
			if (error != MADNoErr) [self presentErrorCode:error operation:@"previewing RAW sample data"];
			dispatch_async(dispatch_get_main_queue(), ^{
				[self runRawImportAlert:alert controls:controls source:source URL:URL
					instrument:instrument replacingSample:replacementIndex];
			});
			return;
		}
		[self stopAllSamplePreviews];
		self.rawPreviewData = nil;
		NSString *name = URL.lastPathComponent.stringByDeletingPathExtension;
		[self installSampleBuffer:buffer byteCount:byteCount bits:settings.bits stereo:settings.stereo
			sampleRate:settings.sampleRate name:name instrument:instrument replacingSample:replacementIndex
			statusVerb:@"Imported RAW"];
	}];
}

- (IBAction)importRawSample:(id)sender
{
	(void)sender;
	if (_music == NULL || _selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU) return;
	NSOpenPanel *panel = NSOpenPanel.openPanel;
	panel.allowsMultipleSelection = NO;
	panel.canChooseDirectories = NO;
	panel.message = _selectedSample >= 0 ? @"Replace the selected sample with headerless PCM data"
		: @"Add headerless PCM data to this instrument";
	NSInteger instrument = _selectedInstrument;
	NSInteger replacementIndex = _selectedSample;
	[panel beginSheetModalForWindow:self.instrumentsWindow completionHandler:^(NSModalResponse response) {
		if (response != NSModalResponseOK) return;
		NSError *error = nil;
		NSData *source = [NSData dataWithContentsOfURL:panel.URL options:NSDataReadingMappedIfSafe error:&error];
		if (source.length == 0) {
			NSAlert *failure = [[NSAlert alloc] init];
			failure.alertStyle = NSAlertStyleCritical;
			failure.messageText = @"MachoPlayer could not read this RAW sample.";
			failure.informativeText = error.localizedDescription ?: @"The file is empty.";
			[failure beginSheetModalForWindow:self.instrumentsWindow completionHandler:nil];
			return;
		}
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = @"RAW Data Import";
		alert.informativeText = @"Choose how the headerless PCM bytes should be interpreted.";
		PPRawImportControlView *controls = [[PPRawImportControlView alloc] initWithFileSize:source.length];
		alert.accessoryView = controls;
		[alert addButtonWithTitle:@"Import"];
		[alert addButtonWithTitle:@"Preview"];
		[alert addButtonWithTitle:@"Cancel"];
		[self runRawImportAlert:alert controls:controls source:source URL:panel.URL
			instrument:instrument replacingSample:replacementIndex];
	}];
}

- (void)importAudioAtURL:(NSURL *)url instrument:(NSInteger)instrument replacingSample:(NSInteger)replacementIndex
{
	ExtAudioFileRef audioFile = NULL;
	OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &audioFile);
	AudioStreamBasicDescription source = {0};
	UInt32 propertySize = sizeof(source);
	if (status == noErr) status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &propertySize, &source);
	SInt64 sourceFrames = 0;
	propertySize = sizeof(sourceFrames);
	if (status == noErr) status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propertySize, &sourceFrames);
	UInt32 channels = MIN(MAX(source.mChannelsPerFrame, 1U), 2U);
	double sampleRate = MIN(MAX(source.mSampleRate, 4000.0), 48000.0);
	AudioStreamBasicDescription client = {0};
	client.mSampleRate = sampleRate;
	client.mFormatID = kAudioFormatLinearPCM;
	client.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
	client.mChannelsPerFrame = channels;
	client.mBitsPerChannel = 16;
	client.mFramesPerPacket = 1;
	client.mBytesPerFrame = 2 * channels;
	client.mBytesPerPacket = client.mBytesPerFrame;
	if (status == noErr) status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);

	double ratio = source.mSampleRate > 0 ? sampleRate / source.mSampleRate : 1.0;
	uint64_t estimatedFrames = (uint64_t)ceil(MAX((double)sourceFrames * ratio, 1.0)) + 32;
	if (estimatedFrames > UINT32_MAX || estimatedFrames * client.mBytesPerFrame > INT_MAX) status = memFullErr;
	UInt32 framesToRead = (UInt32)MIN(estimatedFrames, UINT32_MAX);
	size_t allocationSize = (size_t)framesToRead * client.mBytesPerFrame;
	void *buffer = status == noErr ? malloc(allocationSize) : NULL;
	if (status == noErr && buffer == NULL) status = memFullErr;
	AudioBufferList buffers = {0};
	buffers.mNumberBuffers = 1;
	buffers.mBuffers[0].mNumberChannels = channels;
	buffers.mBuffers[0].mDataByteSize = (UInt32)allocationSize;
	buffers.mBuffers[0].mData = buffer;
	if (status == noErr) status = ExtAudioFileRead(audioFile, &framesToRead, &buffers);
	if (audioFile != NULL) ExtAudioFileDispose(audioFile);
	if (status != noErr || framesToRead == 0) {
		free(buffer);
		NSAlert *alert = [[NSAlert alloc] init];
		alert.alertStyle = NSAlertStyleCritical;
		alert.messageText = @"PlayerPRO could not load this sample.";
		alert.informativeText = [NSString stringWithFormat:@"Core Audio error %d", status];
		[alert beginSheetModalForWindow:self.instrumentsWindow completionHandler:nil];
		return;
	}

	[self installSampleBuffer:buffer byteCount:(size_t)framesToRead * client.mBytesPerFrame bits:16
		stereo:channels == 2 ? MADTrue : MADFalse sampleRate:(unsigned int)llround(sampleRate)
		name:url.lastPathComponent.stringByDeletingPathExtension instrument:instrument
		replacingSample:replacementIndex statusVerb:@"Loaded"];
}

- (IBAction)duplicateSelectedSample:(id)sender
{
	(void)sender;
	sData *source = [self selectedSampleData];
	if (_music == NULL || source == NULL || source->data == NULL || source->size <= 0) { NSBeep(); return; }
	NSInteger instrument = _selectedInstrument;
	NSInteger sourceIndex = _selectedSample;
	NSInteger destinationIndex = _music->fid[instrument].numSamples;
	if (destinationIndex >= MAXSAMPLE || _music->header->numSamples >= UINT8_MAX) { NSBeep(); return; }
	char *dataCopy = malloc((size_t)source->size);
	if (dataCopy == NULL) { NSBeep(); return; }
	memcpy(dataCopy, source->data, (size_t)source->size);
	sData metadata = *source;
	[self stopAllSamplePreviews];
	for (PPSampleEditorController *editor in self.sampleEditors.copy) [editor close];
	for (PPInstrumentEditorController *editor in self.instrumentEditors.copy) [editor close];
	_music->musicUnderModification = true;
	sData *duplicate = MADCreateSample(_music, (short)instrument, (short)destinationIndex);
	if (duplicate == NULL) {
		_music->musicUnderModification = false;
		free(dataCopy);
		NSBeep();
		return;
	}
	*duplicate = metadata;
	duplicate->data = dataCopy;
	NSString *originalName = [self stringFromLegacyBytes:source->name length:sizeof(source->name)
		fallback:[NSString stringWithFormat:@"Sample %03ld", (long)_selectedSample + 1]];
	[self copyString:[originalName stringByAppendingString:@" copy"] toLegacyBuffer:duplicate->name length:sizeof(duplicate->name)];
	_music->header->numSamples++;
	_music->musicUnderModification = false;
	_music->hasChanged = true;
	// Appending a duplicate must not silently remap any piano note away from
	// the source sample. The instrument's what[] table is intentionally intact.
	[self reloadInstrumentsSelectingInstrument:instrument sample:destinationIndex];
	self.statusField.stringValue = [NSString stringWithFormat:@"Duplicated sample %03ld as %03ld",
		(long)sourceIndex + 1, (long)destinationIndex + 1];
}

- (IBAction)duplicateSelectedInstrument:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL ||
		_selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU) { NSBeep(); return; }
	NSInteger sourceInstrument = _selectedInstrument;
	InstrData sourceMetadata = _music->fid[sourceInstrument];
	NSInteger sampleCount = MAX((NSInteger)sourceMetadata.numSamples, 0);
	if (sourceMetadata.name[0] == 0 && sampleCount == 0) { NSBeep(); return; }
	if ((NSInteger)_music->header->numSamples + sampleCount > UINT8_MAX) { NSBeep(); return; }
	NSInteger destinationInstrument = NSNotFound;
	for (NSInteger offset = 1; offset < MAXINSTRU; offset++) {
		NSInteger candidate = (sourceInstrument + offset) % MAXINSTRU;
		if (_music->fid[candidate].name[0] == 0 && _music->fid[candidate].numSamples == 0) {
			destinationInstrument = candidate;
			break;
		}
	}
	if (destinationInstrument == NSNotFound) { NSBeep(); return; }

	[self stopAllSamplePreviews];
	for (PPSampleEditorController *editor in self.sampleEditors.copy) [editor close];
	for (PPInstrumentEditorController *editor in self.instrumentEditors.copy) [editor close];
	BOOL previousModificationState = _music->musicUnderModification;
	_music->musicUnderModification = true;
	_music->fid[destinationInstrument] = sourceMetadata;
	_music->fid[destinationInstrument].firstSample = (short)(destinationInstrument * MAXSAMPLE);
	_music->fid[destinationInstrument].no = (MADByte)destinationInstrument;
	_music->fid[destinationInstrument].numSamples = 0;
	BOOL succeeded = YES;
	for (NSInteger index = 0; index < sampleCount; index++) {
		sData *source = _music->sample[sourceMetadata.firstSample + index];
		if (source == NULL || source->size < 0 || (source->size > 0 && source->data == NULL)) {
			succeeded = NO;
			break;
		}
		sData *duplicate = MADCreateSample(_music, (short)destinationInstrument, (short)index);
		if (duplicate == NULL) {
			succeeded = NO;
			break;
		}
		*duplicate = *source;
		duplicate->data = NULL;
		if (source->size > 0) {
			duplicate->data = malloc((size_t)source->size);
			if (duplicate->data == NULL) {
				succeeded = NO;
				break;
			}
			memcpy(duplicate->data, source->data, (size_t)source->size);
		}
	}
	if (!succeeded) {
		MADKillInstrument(_music, (short)destinationInstrument);
		_music->fid[destinationInstrument].firstSample = (short)(destinationInstrument * MAXSAMPLE);
		_music->fid[destinationInstrument].no = (MADByte)destinationInstrument;
		_music->musicUnderModification = previousModificationState;
		NSBeep();
		return;
	}
	NSString *sourceName = [self stringFromLegacyBytes:sourceMetadata.name length:sizeof(sourceMetadata.name)
		fallback:[NSString stringWithFormat:@"Instrument %03ld", (long)sourceInstrument + 1]];
	[self copyString:[sourceName stringByAppendingString:@" copy"]
		toLegacyBuffer:_music->fid[destinationInstrument].name
		length:sizeof(_music->fid[destinationInstrument].name)];
	_music->header->numSamples = (MADByte)((NSInteger)_music->header->numSamples + sampleCount);
	_music->header->numInstru = (MADByte)MAX((NSInteger)_music->header->numInstru, destinationInstrument + 1);
	_music->musicUnderModification = previousModificationState;
	_music->hasChanged = true;
	[self reloadInstrumentsSelectingInstrument:destinationInstrument sample:-1];
	self.statusField.stringValue = [NSString stringWithFormat:@"Duplicated instrument %03ld as %03ld with %ld sample%@",
		(long)sourceInstrument + 1, (long)destinationInstrument + 1, (long)sampleCount,
		sampleCount == 1 ? @"" : @"s"];
}

- (IBAction)deleteSelectedInstrumentOrSample:(id)sender
{
	(void)sender;
	if (_music == NULL) return;
	[self stopAllSamplePreviews];
	for (PPSampleEditorController *editor in self.sampleEditors.copy) [editor close];
	for (PPInstrumentEditorController *editor in self.instrumentEditors.copy) [editor close];
	if (_selectedSample >= 0) {
		if (MADKillSample(_music, (short)_selectedInstrument, (short)_selectedSample) == MADNoErr) {
			if (_music->header->numSamples > 0) _music->header->numSamples--;
			_music->hasChanged = true;
			[self reloadInstrumentsSelectingInstrument:_selectedInstrument sample:-1];
		}
	} else {
		NSInteger removedSamples = _music->fid[_selectedInstrument].numSamples;
		if (MADKillInstrument(_music, (short)_selectedInstrument) == MADNoErr) {
			_music->header->numSamples = (MADByte)MAX((NSInteger)_music->header->numSamples - removedSamples, 0);
			_music->fid[_selectedInstrument].firstSample = (short)(_selectedInstrument * MAXSAMPLE);
			_music->hasChanged = true;
			[self reloadInstrumentsSelectingInstrument:_selectedInstrument sample:-1];
		}
	}
}

- (IBAction)recordSample:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Sample recording";
	alert.informativeText = @"Live recording is not connected yet. Load, preview, and destructive sample editing are active.";
	[alert beginSheetModalForWindow:self.instrumentsWindow completionHandler:nil];
}

- (IBAction)exportSelectedSample:(id)sender
{
	(void)sender;
	sData *sample = [self selectedSampleData];
	if (sample == NULL || sample->data == NULL || sample->size <= 0) { NSBeep(); return; }
	NSString *sampleName = [self stringFromLegacyBytes:sample->name length:sizeof(sample->name) fallback:@"Untitled Sample"];
	NSSavePanel *panel = NSSavePanel.savePanel;
	panel.nameFieldStringValue = [sampleName stringByAppendingPathExtension:@"wav"];
	panel.message = @"Export the selected PlayerPRO sample as linear PCM WAVE audio";
	[panel beginSheetModalForWindow:self.instrumentsWindow completionHandler:^(NSModalResponse response) {
		if (response != NSModalResponseOK) return;
		[self writeSample:sample asWaveAtURL:panel.URL];
	}];
}

- (void)writeSample:(sData *)sample asWaveAtURL:(NSURL *)url
{
	if (sample == NULL || url == nil) return;
	UInt32 channels = sample->stereo ? 2 : 1;
	AudioStreamBasicDescription fileFormat = {0};
	fileFormat.mSampleRate = sample->c2spd;
	fileFormat.mFormatID = kAudioFormatLinearPCM;
	fileFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	fileFormat.mChannelsPerFrame = channels;
	fileFormat.mBitsPerChannel = 16;
	fileFormat.mFramesPerPacket = 1;
	fileFormat.mBytesPerFrame = 2 * channels;
	fileFormat.mBytesPerPacket = fileFormat.mBytesPerFrame;
	ExtAudioFileRef output = NULL;
	OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileWAVEType, &fileFormat, NULL,
		kAudioFileFlags_EraseFile, &output);
	AudioStreamBasicDescription clientFormat = fileFormat;
	clientFormat.mBitsPerChannel = sample->amp;
	clientFormat.mBytesPerFrame = (sample->amp / 8) * channels;
	clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame;
	clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
	if (status == noErr) status = ExtAudioFileSetProperty(output, kExtAudioFileProperty_ClientDataFormat,
		sizeof(clientFormat), &clientFormat);
	AudioBufferList buffers = {0};
	buffers.mNumberBuffers = 1;
	buffers.mBuffers[0].mNumberChannels = channels;
	buffers.mBuffers[0].mDataByteSize = (UInt32)sample->size;
	buffers.mBuffers[0].mData = sample->data;
	UInt32 frameCount = (UInt32)((size_t)sample->size / clientFormat.mBytesPerFrame);
	if (status == noErr) status = ExtAudioFileWrite(output, frameCount, &buffers);
	if (output != NULL) ExtAudioFileDispose(output);
	if (status == noErr) {
		self.statusField.stringValue = [NSString stringWithFormat:@"Saved sample as %@", url.lastPathComponent];
	} else {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.alertStyle = NSAlertStyleCritical;
		alert.messageText = @"PlayerPRO could not export this sample.";
		alert.informativeText = [NSString stringWithFormat:@"Core Audio error %d", status];
		[alert beginSheetModalForWindow:self.instrumentsWindow completionHandler:nil];
	}
}

- (NSString *)stringForCommand:(Cmd *)command
{
	return PPPatternStringForCommand(command);
}

- (BOOL)parseCommandString:(NSString *)input intoCommand:(Cmd *)command
{
	return PPPatternParseCommandString(input, command);
}

- (BOOL)patternHexByteFromString:(NSString *)string value:(MADByte *)value
{
	NSString *candidate = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
	if (candidate.length != 2) return NO;
	unsigned int parsed = 0;
	NSScanner *scanner = [NSScanner scannerWithString:candidate];
	scanner.charactersToBeSkipped = nil;
	if (![scanner scanHexInt:&parsed] || !scanner.isAtEnd || parsed > 0xFF) return NO;
	if (value != NULL) *value = (MADByte)parsed;
	return YES;
}

- (void)updatePatternDefaultsDisplay
{
	self.patternEffectToggle.title = [NSString stringWithFormat:@"FX:%@", PPPatternEffectCharacter(self.defaultPatternEffect)];
	self.patternArgumentToggle.title = [NSString stringWithFormat:@"Arg:%02X", self.defaultPatternArgument];
	self.patternVolumeToggle.title = [NSString stringWithFormat:@"Vol:%02X", self.defaultPatternVolume];
	[self updatePatternInstrumentDisplay];
	[self rebuildPatternEffectPopup];
	[self rebuildPatternHexPopup:self.patternArgumentPopup title:@"Argument"
		value:self.defaultPatternArgument action:@selector(choosePatternArgument:)];
	[self rebuildPatternHexPopup:self.patternVolumePopup title:@"Volume"
		value:self.defaultPatternVolume action:@selector(choosePatternVolume:)];
}

- (void)rebuildPatternInstrumentPopup
{
	if (self.patternInstrumentPopup == nil) return;
	[self.patternInstrumentPopup removeAllItems];
	[self.patternInstrumentPopup addItemWithTitle:@""];
	for (NSInteger value = 0; value <= MAXINSTRU; value++) {
		NSString *title = @"No Ins";
		if (value > 0) {
			NSString *name = @"-";
			if (_music != NULL && _music->header != NULL) {
				InstrData *instrument = &_music->fid[value - 1];
				name = [self stringFromLegacyBytes:instrument->name length:sizeof(instrument->name) fallback:@"-"];
			}
			title = [NSString stringWithFormat:@"%03ld %@", (long)value, name];
		}
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
			action:@selector(choosePatternInstrument:) keyEquivalent:@""];
		item.target = self;
		item.tag = value;
		item.state = value == self.defaultPatternInstrument ? NSControlStateValueOn : NSControlStateValueOff;
		[self.patternInstrumentPopup.menu addItem:item];
	}
	if (self.toolsInstrumentPopup != nil) {
		[self rebuildToolsCommandInspectorMenus];
		[self updateToolsCommandInspector];
	}
}

- (void)rebuildPatternEffectPopup
{
	if (self.patternEffectPopup == nil) return;
	[self.patternEffectPopup removeAllItems];
	[self.patternEffectPopup addItemWithTitle:@""];
	NSArray<NSString *> *titles = PPPatternEffectMenuTitles();
	for (NSInteger effect = 0; effect < (NSInteger)titles.count; effect++) {
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:titles[effect]
			action:@selector(choosePatternEffect:) keyEquivalent:@""];
		item.target = self;
		item.tag = effect;
		item.state = effect == self.defaultPatternEffect ? NSControlStateValueOn : NSControlStateValueOff;
		[self.patternEffectPopup.menu addItem:item];
	}
}

- (void)rebuildPatternHexPopup:(NSPopUpButton *)popup title:(NSString *)title
	value:(MADByte)value action:(SEL)action
{
	if (popup == nil) return;
	PPHexPickerMenuView *picker = [self installOriginalHexPickerInPopup:popup value:value action:action
		accessibilityLabel:[NSString stringWithFormat:@"Digital %@ hexadecimal picker", title.lowercaseString]];
	if (popup == self.patternArgumentPopup) self.patternArgumentHexPicker = picker;
	else if (popup == self.patternVolumePopup) self.patternVolumeHexPicker = picker;
}

- (IBAction)choosePatternInstrument:(NSMenuItem *)sender
{
	self.defaultPatternInstrument = (MADByte)MIN(MAX(sender.tag, 0), 255);
	if (self.defaultPatternInstrument > 0 && self.defaultPatternInstrument <= [self instrumentDisplayCount]) {
		[self selectInstrument:self.defaultPatternInstrument - 1 sample:-1];
	} else {
		[self updatePatternInstrumentDisplay];
	}
	self.statusField.stringValue = self.defaultPatternInstrument == 0
		? @"Digital instrument default: No Ins"
		: [NSString stringWithFormat:@"Digital instrument default: %03u", self.defaultPatternInstrument];
	[self.window makeFirstResponder:self.patternTable];
}

- (IBAction)choosePatternEffect:(NSMenuItem *)sender
{
	self.defaultPatternEffect = (MADEffectID)MIN(MAX(sender.tag, 0), MADEffectNOffset);
	[self updatePatternDefaultsDisplay];
	self.statusField.stringValue = [NSString stringWithFormat:@"Digital effect default: %@",
		PPPatternEffectMenuTitles()[self.defaultPatternEffect]];
	[self.window makeFirstResponder:self.patternTable];
}

- (IBAction)choosePatternArgument:(id)sender
{
	self.defaultPatternArgument = (MADByte)MIN(MAX([self hexPickerValueFromSender:sender], 0), 255);
	[self updatePatternDefaultsDisplay];
	self.statusField.stringValue = [NSString stringWithFormat:@"Digital argument default: %02X", self.defaultPatternArgument];
	[self.window makeFirstResponder:self.patternTable];
}

- (IBAction)choosePatternVolume:(id)sender
{
	self.defaultPatternVolume = (MADByte)MIN(MAX([self hexPickerValueFromSender:sender], 0), 255);
	[self updatePatternDefaultsDisplay];
	self.statusField.stringValue = [NSString stringWithFormat:@"Digital volume default: %02X", self.defaultPatternVolume];
	[self.window makeFirstResponder:self.patternTable];
}

- (IBAction)showPatternDefaults:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Digital command defaults";
	alert.informativeText = @"The checked fields are applied by Fill and direct Digital entry.";
	[alert addButtonWithTitle:@"Apply"];
	[alert addButtonWithTitle:@"Cancel"];

	NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 88)];
	NSButton *useEffect = [NSButton checkboxWithTitle:@"FX:" target:nil action:nil];
	useEffect.frame = NSMakeRect(0, 62, 58, 20);
	useEffect.state = self.patternEffectToggle.state;
	[accessory addSubview:useEffect];
	NSPopUpButton *effectPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, 59, 292, 24) pullsDown:NO];
	[effectPopup addItemsWithTitles:PPPatternEffectMenuTitles()];
	[effectPopup selectItemAtIndex:MIN((NSInteger)self.defaultPatternEffect, 18)];
	[accessory addSubview:effectPopup];

	NSButton *useArgument = [NSButton checkboxWithTitle:@"Arg:" target:nil action:nil];
	useArgument.frame = NSMakeRect(0, 36, 58, 20);
	useArgument.state = self.patternArgumentToggle.state;
	[accessory addSubview:useArgument];
	NSTextField *argumentField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%02X", self.defaultPatternArgument]];
	argumentField.frame = NSMakeRect(62, 35, 56, 22);
	argumentField.font = [self classicFont];
	argumentField.alignment = NSTextAlignmentCenter;
	[accessory addSubview:argumentField];

	NSButton *useVolume = [NSButton checkboxWithTitle:@"Vol:" target:nil action:nil];
	useVolume.frame = NSMakeRect(0, 10, 58, 20);
	useVolume.state = self.patternVolumeToggle.state;
	[accessory addSubview:useVolume];
	NSTextField *volumeField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%02X", self.defaultPatternVolume]];
	volumeField.frame = NSMakeRect(62, 9, 56, 22);
	volumeField.font = [self classicFont];
	volumeField.alignment = NSTextAlignmentCenter;
	[accessory addSubview:volumeField];
	NSTextField *volumeHint = [NSTextField labelWithString:@"00 clears the volume command, matching the original editor"];
	volumeHint.frame = NSMakeRect(126, 11, 228, 18);
	volumeHint.font = [self classicFont];
	[accessory addSubview:volumeHint];
	alert.accessoryView = accessory;

	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn) return;
		MADByte argument = 0, volume = 0;
		if (![self patternHexByteFromString:argumentField.stringValue value:&argument] ||
			![self patternHexByteFromString:volumeField.stringValue value:&volume]) {
			NSBeep();
			self.statusField.stringValue = @"Digital argument and volume defaults must be two hexadecimal digits (00-FF)";
			return;
		}
		self.defaultPatternEffect = (MADEffectID)effectPopup.indexOfSelectedItem;
		self.defaultPatternArgument = argument;
		self.defaultPatternVolume = volume;
		self.patternEffectToggle.state = useEffect.state;
		self.patternArgumentToggle.state = useArgument.state;
		self.patternVolumeToggle.state = useVolume.state;
		[self updatePatternDefaultsDisplay];
		self.statusField.stringValue = @"Digital command defaults updated";
		[self.window makeFirstResponder:self.patternTable];
	}];
}

#pragma mark - Shared pattern editing

- (PPPatternSnapshot *)capturePatternSnapshot:(NSInteger)patternIndex
{
	PPPatternSnapshot *snapshot = [[PPPatternSnapshot alloc] init];
	snapshot.pattern = patternIndex;
	if (_music == NULL || _music->header == NULL || patternIndex < 0 || patternIndex >= MAXPATTERN) return snapshot;
	PatData *pattern = _music->partition[patternIndex];
	if (pattern == NULL) return snapshot;
	snapshot.rows = pattern->header.size;
	snapshot.channels = _music->header->numChn;
	snapshot.commands = [NSData dataWithBytes:pattern->Cmds
		length:(NSUInteger)snapshot.rows * (NSUInteger)snapshot.channels * sizeof(Cmd)];
	return snapshot;
}

- (void)registerPatternUndoSnapshot:(PPPatternSnapshot *)snapshot actionName:(NSString *)name
{
	[[self.window.undoManager prepareWithInvocationTarget:self] restorePatternSnapshot:snapshot actionName:name];
	[self.window.undoManager setActionName:name];
}

- (void)restorePatternSnapshot:(PPPatternSnapshot *)snapshot actionName:(NSString *)name
{
	if (_music == NULL || snapshot.commands.length == 0 || snapshot.pattern < 0 || snapshot.pattern >= MAXPATTERN) return;
	PatData *pattern = _music->partition[snapshot.pattern];
	if (pattern == NULL) return;
	PPPatternSnapshot *redo = [self capturePatternSnapshot:snapshot.pattern];
	NSInteger rows = MIN(snapshot.rows, pattern->header.size);
	NSInteger channels = MIN(snapshot.channels, _music->header->numChn);
	const Cmd *source = snapshot.commands.bytes;
	for (NSInteger channel = 0; channel < channels; channel++) {
		for (NSInteger row = 0; row < rows; row++) {
			Cmd *destination = GetMADCommand((short)row, (short)channel, pattern);
			*destination = source[channel * snapshot.rows + row];
		}
	}
	[self registerPatternUndoSnapshot:redo actionName:name];
	_music->hasChanged = true;
	if (_selectedPattern == snapshot.pattern) [self.patternTable reloadData];
	self.statusField.stringValue = name;
}

- (BOOL)getPatternSelectionTop:(NSInteger *)top bottom:(NSInteger *)bottom left:(NSInteger *)left right:(NSInteger *)right
{
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || _music == NULL || _music->header == NULL) return NO;
	NSInteger topValue = self.patternSelectionTop;
	NSInteger bottomValue = self.patternSelectionBottom;
	NSInteger leftValue = self.patternSelectionLeft;
	NSInteger rightValue = self.patternSelectionRight;
	leftValue = MIN(MAX(leftValue, 0), MAX((NSInteger)_music->header->numChn - 1, 0));
	rightValue = MIN(MAX(rightValue, leftValue), MAX((NSInteger)_music->header->numChn - 1, 0));
	topValue = MIN(MAX(topValue, 0), MAX(pattern->header.size - 1, 0));
	bottomValue = MIN(MAX(bottomValue, topValue), MAX(pattern->header.size - 1, 0));
	if (top != NULL) *top = topValue;
	if (bottom != NULL) *bottom = bottomValue;
	if (left != NULL) *left = leftValue;
	if (right != NULL) *right = rightValue;
	return pattern->header.size > 0 && _music->header->numChn > 0;
}

- (void)updatePatternSelectionFromAnchorRow:(NSInteger)anchorRow channel:(NSInteger)anchorChannel
	cursorRow:(NSInteger)cursorRow channel:(NSInteger)cursorChannel revealCursor:(BOOL)revealCursor
{
	if (_music == NULL || _music->header == NULL) return;
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || pattern->header.size <= 0 || _music->header->numChn <= 0) return;
	anchorRow = MIN(MAX(anchorRow, 0), pattern->header.size - 1);
	cursorRow = MIN(MAX(cursorRow, 0), pattern->header.size - 1);
	anchorChannel = MIN(MAX(anchorChannel, 0), (NSInteger)_music->header->numChn - 1);
	cursorChannel = MIN(MAX(cursorChannel, 0), (NSInteger)_music->header->numChn - 1);
	NSInteger top = MIN(anchorRow, cursorRow);
	NSInteger bottom = MAX(anchorRow, cursorRow);
	NSInteger left = MIN(anchorChannel, cursorChannel);
	NSInteger right = MAX(anchorChannel, cursorChannel);
	self.patternSelectionTop = top;
	self.patternSelectionBottom = bottom;
	self.patternSelectionLeft = left;
	self.patternSelectionRight = right;
	self.patternSelectionAnchorRow = anchorRow;
	self.patternSelectionAnchorChannel = anchorChannel;
	self.patternCursorRow = cursorRow;
	self.patternCursorChannel = cursorChannel;
	[self.patternTable selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(top, bottom - top + 1)]
		byExtendingSelection:NO];
	[self.patternTable selectColumnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(left + 1, right - left + 1)]
		byExtendingSelection:NO];
	if (revealCursor) [self.patternTable scrollRowToVisible:cursorRow];
	[self.patternTable reloadData];
	if (self.toolsCommandInspectorExpanded) [self updateToolsCommandInspector];
}

- (void)selectPatternTop:(NSInteger)top bottom:(NSInteger)bottom left:(NSInteger)left right:(NSInteger)right
{
	// Programmatic selections (paste, Fill, Select All) retain the classic
	// top-left insertion point while mouse and Shift-key selections use the
	// explicit anchor/end method above.
	[self updatePatternSelectionFromAnchorRow:bottom channel:right cursorRow:top channel:left revealCursor:YES];
}

- (void)copyPatternSelection:(id)sender
{
	(void)sender;
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) { NSBeep(); return; }
	NSInteger rows = bottom - top + 1;
	NSInteger channels = right - left + 1;
	PPPatternClipboardHeader header = {0x50434D44, 1, (uint16_t)rows, (uint16_t)channels, 0};
	NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof(header)];
	NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:rows];
	for (NSInteger row = 0; row < rows; row++) {
		NSMutableArray<NSString *> *cells = [NSMutableArray arrayWithCapacity:channels];
		for (NSInteger channel = 0; channel < channels; channel++) {
			Cmd *command = GetMADCommand((short)(top + row), (short)(left + channel), [self selectedPatternData]);
			[data appendBytes:command length:sizeof(*command)];
			[cells addObject:[self stringForCommand:command]];
		}
		[lines addObject:[cells componentsJoinedByString:@"\t"]];
	}
	NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
	[pasteboard clearContents];
	[pasteboard declareTypes:@[PPPatternPasteboardType, NSPasteboardTypeString] owner:nil];
	[pasteboard setData:data forType:PPPatternPasteboardType];
	[pasteboard setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
	self.statusField.stringValue = [NSString stringWithFormat:@"Copied %ld × %ld pattern cells", (long)rows, (long)channels];
}

- (void)clearPatternSelection:(id)sender
{
	(void)sender;
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) { NSBeep(); return; }
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd empty = {0, 0xFF, 0, 0, 0xFF, 0};
	for (NSInteger channel = left; channel <= right; channel++) {
		for (NSInteger row = top; row <= bottom; row++) {
			*GetMADCommand((short)row, (short)channel, [self selectedPatternData]) = empty;
		}
	}
	[self registerPatternUndoSnapshot:snapshot actionName:@"Clear Pattern Selection"];
	_music->hasChanged = true;
	[self.patternTable reloadData];
	self.statusField.stringValue = @"Pattern selection cleared";
}

- (IBAction)fillPatternSelection:(id)sender
{
	(void)sender;
	BOOL useInstrument = self.patternInstrumentToggle.state == NSControlStateValueOn;
	BOOL useEffect = self.patternEffectToggle.state == NSControlStateValueOn;
	BOOL useArgument = self.patternArgumentToggle.state == NSControlStateValueOn;
	BOOL useVolume = self.patternVolumeToggle.state == NSControlStateValueOn;
	if (!useInstrument && !useEffect && !useArgument && !useVolume) {
		NSBeep();
		self.statusField.stringValue = @"Enable at least one Digital default before using Fill";
		return;
	}
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) { NSBeep(); return; }
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	BOOL changed = NO;
	MADByte instrument = self.defaultPatternInstrument;
	MADByte volume = self.defaultPatternVolume == 0 ? 0xFF : self.defaultPatternVolume;
	for (NSInteger channel = left; channel <= right; channel++) {
		for (NSInteger row = top; row <= bottom; row++) {
			Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
			Cmd previous = *command;
			if (useInstrument) command->ins = instrument;
			if (useEffect) command->cmd = self.defaultPatternEffect;
			if (useArgument) command->arg = self.defaultPatternArgument;
			if (useVolume) command->vol = volume;
			if (memcmp(&previous, command, sizeof(Cmd)) != 0) changed = YES;
		}
	}
	if (!changed) {
		self.statusField.stringValue = @"Selection already contains those Digital defaults";
		return;
	}
	[self registerPatternUndoSnapshot:snapshot actionName:@"Fill Pattern Selection"];
	_music->hasChanged = true;
	[self.patternTable reloadData];
	[self selectPatternTop:top bottom:bottom left:left right:right];
	self.statusField.stringValue = [NSString stringWithFormat:@"Filled %ld × %ld cells without changing notes",
		(long)(bottom - top + 1), (long)(right - left + 1)];
}

- (void)cutPatternSelection:(id)sender
{
	[self copyPatternSelection:sender];
	[self clearPatternSelection:sender];
	[self.window.undoManager setActionName:@"Cut Pattern Selection"];
}

- (void)pastePatternSelection:(id)sender
{
	(void)sender;
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) { NSBeep(); return; }
	(void)bottom; (void)right;
	NSData *data = [NSPasteboard.generalPasteboard dataForType:PPPatternPasteboardType];
	if (data.length < sizeof(PPPatternClipboardHeader)) { NSBeep(); return; }
	PPPatternClipboardHeader header;
	[data getBytes:&header length:sizeof(header)];
	NSUInteger required = sizeof(header) + (NSUInteger)header.rows * (NSUInteger)header.channels * sizeof(Cmd);
	if (header.magic != 0x50434D44 || header.version != 1 || header.rows == 0 || header.channels == 0 || data.length < required) {
		NSBeep(); return;
	}
	PatData *pattern = [self selectedPatternData];
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	const Cmd *commands = (const Cmd *)((const uint8_t *)data.bytes + sizeof(header));
	NSInteger pastedRows = 0, pastedChannels = 0;
	for (NSInteger row = 0; row < header.rows && top + row < pattern->header.size; row++) {
		pastedRows = row + 1;
		for (NSInteger channel = 0; channel < header.channels && left + channel < _music->header->numChn; channel++) {
			*GetMADCommand((short)(top + row), (short)(left + channel), pattern) = commands[row * header.channels + channel];
			pastedChannels = MAX(pastedChannels, channel + 1);
		}
	}
	if (pastedRows == 0 || pastedChannels == 0) { NSBeep(); return; }
	[self registerPatternUndoSnapshot:snapshot actionName:@"Paste Pattern Selection"];
	_music->hasChanged = true;
	[self.patternTable reloadData];
	[self selectPatternTop:top bottom:top + pastedRows - 1 left:left right:left + pastedChannels - 1];
	self.statusField.stringValue = @"Pattern commands pasted";
}

- (void)selectAllPatternCommands:(id)sender
{
	(void)sender;
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || _music == NULL || _music->header->numChn == 0) return;
	[self selectPatternTop:0 bottom:pattern->header.size - 1 left:0 right:_music->header->numChn - 1];
}

- (void)movePatternSelectionRows:(NSInteger)rowDelta channels:(NSInteger)channelDelta extend:(BOOL)extend
{
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || pattern->header.size <= 0 || _music == NULL || _music->header->numChn <= 0) return;
	NSInteger cursorRow = MIN(MAX(self.patternCursorRow, 0), pattern->header.size - 1);
	NSInteger cursorChannel = MIN(MAX(self.patternCursorChannel, 0), (NSInteger)_music->header->numChn - 1);
	if (extend) {
		cursorRow = MIN(MAX(cursorRow + rowDelta, 0), pattern->header.size - 1);
		cursorChannel = MIN(MAX(cursorChannel + channelDelta, 0), (NSInteger)_music->header->numChn - 1);
		[self updatePatternSelectionFromAnchorRow:self.patternSelectionAnchorRow
			channel:self.patternSelectionAnchorChannel cursorRow:cursorRow channel:cursorChannel revealCursor:YES];
	} else {
		NSInteger row = (cursorRow + rowDelta) % pattern->header.size;
		if (row < 0) row += pattern->header.size;
		NSInteger channel = (cursorChannel + channelDelta) % _music->header->numChn;
		if (channel < 0) channel += _music->header->numChn;
		[self updatePatternSelectionFromAnchorRow:row channel:channel cursorRow:row channel:channel revealCursor:YES];
	}
}

- (void)previewPatternNote:(NSInteger)note
{
	if (_music == NULL || _driver == NULL || _selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU) return;
	[self.pianoController auditionNote:note velocity:127 instrument:_selectedInstrument
		track:MAX(self.patternCursorChannel, 0)];
}

- (NSNumber *)noteForTrackerKey:(NSString *)key
{
	NSInteger note = PPTrackerKeyboardNoteForKey(key, self.patternOctaveOffset);
	return note == NSNotFound ? nil : @(note);
}

- (NSString *)patternFieldName
{
	static NSArray<NSString *> *names;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ names = @[@"Instrument", @"Note", @"Effect", @"Argument", @"Volume"]; });
	return names[MIN(MAX(self.patternField, 0), 4)];
}

- (void)resetPatternFieldBuffer
{
	self.patternFieldBuffer = @"";
	self.patternFieldBufferRow = -1;
	self.patternFieldBufferChannel = -1;
	self.patternFieldBufferKind = -1;
}

- (NSString *)appendPatternFieldCharacter:(NSString *)character width:(NSInteger)width row:(NSInteger)row channel:(NSInteger)channel
{
	if (self.patternFieldBufferRow != row || self.patternFieldBufferChannel != channel ||
		self.patternFieldBufferKind != self.patternField || self.patternFieldBuffer.length >= width) {
		self.patternFieldBuffer = @"";
	}
	self.patternFieldBufferRow = row;
	self.patternFieldBufferChannel = channel;
	self.patternFieldBufferKind = self.patternField;
	self.patternFieldBuffer = [self.patternFieldBuffer stringByAppendingString:character.uppercaseString];
	return self.patternFieldBuffer;
}

- (BOOL)patternTableLocationForEvent:(NSEvent *)event clampToCommands:(BOOL)clamp
	row:(NSInteger *)rowOut channel:(NSInteger *)channelOut point:(NSPoint *)pointOut
{
	if (_music == NULL || _music->header == NULL || _music->header->numChn <= 0 || self.patternTable.numberOfRows <= 0) return NO;
	NSPoint point = [self.patternTable convertPoint:event.locationInWindow fromView:nil];
	NSInteger row = [self.patternTable rowAtPoint:point];
	NSInteger column = [self.patternTable columnAtPoint:point];
	if (clamp) {
		if (row < 0) row = point.y < 0 ? 0 : self.patternTable.numberOfRows - 1;
		if (column <= 0) {
			NSRect lastCell = [self.patternTable frameOfCellAtColumn:_music->header->numChn row:MIN(MAX(row, 0), self.patternTable.numberOfRows - 1)];
			column = point.x >= NSMaxX(lastCell) ? _music->header->numChn : 1;
		}
		if (column > _music->header->numChn) column = _music->header->numChn;
	}
	if (row < 0 || column <= 0 || column > _music->header->numChn) return NO;
	if (rowOut != NULL) *rowOut = row;
	if (channelOut != NULL) *channelOut = column - 1;
	if (pointOut != NULL) *pointOut = point;
	return YES;
}

- (BOOL)patternTableBeginSelection:(NSEvent *)event
{
	NSInteger row, channel;
	NSPoint point;
	if (![self patternTableLocationForEvent:event clampToCommands:NO row:&row channel:&channel point:&point]) return NO;
	NSRect cell = [self.patternTable frameOfCellAtColumn:channel + 1 row:row];
	CGFloat characterWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName: [self classicFont]}].width;
	NSInteger character = (NSInteger)floor((point.x - NSMinX(cell)) / MAX(characterWidth, 1.0));
	if (character <= 3) self.patternField = 0;
	else if (character <= 7) self.patternField = 1;
	else if (character <= 9) self.patternField = 2;
	else if (character <= 12) self.patternField = 3;
	else self.patternField = 4;
	BOOL extend = (event.modifierFlags & NSEventModifierFlagShift) != 0;
	NSInteger anchorRow = extend ? self.patternSelectionAnchorRow : row;
	NSInteger anchorChannel = extend ? self.patternSelectionAnchorChannel : channel;
	[self updatePatternSelectionFromAnchorRow:anchorRow channel:anchorChannel
		cursorRow:row channel:channel revealCursor:YES];
	[self resetPatternFieldBuffer];
	self.patternRecording = YES;
	self.patternRecordButton.state = NSControlStateValueOn;
	[self.window makeFirstResponder:self.patternTable];
	self.statusField.stringValue = [NSString stringWithFormat:@"Digital editing • %@ field • drag selects commands • Esc turns off",
		[self patternFieldName]];
	return YES;
}

- (void)patternTableOpenCommandInspector:(NSEvent *)event
{
	(void)event;
	[self setToolsCommandInspectorExpanded:YES];
	[self.toolsWindow makeKeyAndOrderFront:nil];
	NSArray<NSTextField *> *fields = @[self.toolsInstrumentField, self.toolsNoteField, self.toolsEffectField,
		self.toolsArgumentField, self.toolsVolumeField];
	NSTextField *field = fields[MIN(MAX(self.patternField, 0), 4)];
	[self.toolsWindow makeFirstResponder:field];
	[field selectText:nil];
	self.statusField.stringValue = [NSString stringWithFormat:@"Tools command editor • pattern %03ld • row %03ld • track %02ld • %@",
		(long)_selectedPattern, (long)self.patternCursorRow, (long)self.patternCursorChannel + 1, [self patternFieldName]];
}

- (void)patternTableContinueSelection:(NSEvent *)event
{
	[self.patternTable autoscroll:event];
	NSInteger row, channel;
	if (![self patternTableLocationForEvent:event clampToCommands:YES row:&row channel:&channel point:NULL]) return;
	[self updatePatternSelectionFromAnchorRow:self.patternSelectionAnchorRow
		channel:self.patternSelectionAnchorChannel cursorRow:row channel:channel revealCursor:NO];
	[self.patternTable displayIfNeeded];
}

- (void)patternTableEndSelection:(NSEvent *)event
{
	[self patternTableContinueSelection:event];
	NSInteger rows = self.patternSelectionBottom - self.patternSelectionTop + 1;
	NSInteger channels = self.patternSelectionRight - self.patternSelectionLeft + 1;
	self.statusField.stringValue = rows == 1 && channels == 1
		? [NSString stringWithFormat:@"Digital editing • %@ field • row %03ld track %02ld",
			[self patternFieldName], (long)self.patternCursorRow + 1, (long)self.patternCursorChannel + 1]
		: [NSString stringWithFormat:@"Selected %ld × %ld Digital commands",
			(long)rows, (long)channels];
}

- (void)patternTableSelectTrackFromHeader:(NSInteger)channel extend:(BOOL)extend
{
	PatData *pattern = [self selectedPatternData];
	if (pattern == NULL || pattern->header.size <= 0 || _music == NULL ||
		_music->header == NULL || _music->header->numChn <= 0) return;
	channel = MIN(MAX(channel, 0), (NSInteger)_music->header->numChn - 1);
	NSInteger left = channel;
	NSInteger right = channel;
	if (extend) {
		left = MIN(self.patternSelectionAnchorChannel, channel);
		right = MAX(self.patternSelectionAnchorChannel, channel);
	}
	[self selectPatternTop:0 bottom:pattern->header.size - 1 left:left right:right];
	[self.window makeFirstResponder:self.patternTable];
	self.statusField.stringValue = left == right
		? [NSString stringWithFormat:@"Selected track %ld", (long)left + 1]
		: [NSString stringWithFormat:@"Selected tracks %ld–%ld", (long)left + 1, (long)right + 1];
}

- (BOOL)singlePatternCellSelectedAtRow:(NSInteger *)row channel:(NSInteger *)channel
{
	if (self.patternSelectionTop != self.patternSelectionBottom ||
		self.patternSelectionLeft != self.patternSelectionRight) return NO;
	if (row != NULL) *row = self.patternCursorRow;
	if (channel != NULL) *channel = self.patternCursorChannel;
	return YES;
}

- (void)finishDirectPatternChangeFrom:(Cmd)previous command:(Cmd *)command snapshot:(PPPatternSnapshot *)snapshot
	row:(NSInteger)row channel:(NSInteger)channel actionName:(NSString *)actionName
{
	if (command == NULL || memcmp(&previous, command, sizeof(Cmd)) == 0) return;
	[self registerPatternUndoSnapshot:snapshot actionName:actionName];
	_music->hasChanged = true;
	[self.patternTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
		columnIndexes:[NSIndexSet indexSetWithIndex:channel + 1]];
	if (self.toolsCommandInspectorExpanded) [self updateToolsCommandInspector];
	self.statusField.stringValue = [NSString stringWithFormat:@"%@ changed", [self patternFieldName]];
}

- (void)clearActivePatternField
{
	NSInteger row, channel;
	if (![self singlePatternCellSelectedAtRow:&row channel:&channel]) { [self clearPatternSelection:nil]; return; }
	Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
	if (command == NULL) return;
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd previous = *command;
	switch (self.patternField) {
		case 0: command->ins = 0; break;
		case 1: command->note = 0xFF; break;
		case 2: command->cmd = MADEffectArpeggio; break;
		case 3: command->arg = 0; break;
		case 4: command->vol = 0xFF; break;
	}
	[self resetPatternFieldBuffer];
	[self finishDirectPatternChangeFrom:previous command:command snapshot:snapshot row:row channel:channel actionName:@"Clear Pattern Field"];
}

- (BOOL)enterPatternFieldCharacter:(NSString *)key
{
	NSInteger row, channel;
	if (![self singlePatternCellSelectedAtRow:&row channel:&channel]) return NO;
	Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
	if (command == NULL || key.length != 1) return NO;
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd previous = *command;
	unichar character = [key.uppercaseString characterAtIndex:0];
	if (self.patternField == 0) {
		if (character < '0' || character > '9') return NO;
		NSString *digits = [self appendPatternFieldCharacter:key width:3 row:row channel:channel];
		NSInteger value = digits.integerValue;
		if (value > 255) { NSBeep(); [self resetPatternFieldBuffer]; return YES; }
		command->ins = (MADByte)value;
	} else if (self.patternField == 2) {
		MADEffectID effect;
		if (character >= '0' && character <= '9') effect = (MADEffectID)(character - '0');
		else if (character >= 'A' && character <= 'F') effect = (MADEffectID)(10 + character - 'A');
		else if (character == 'G') effect = MADEffectNoteOff;
		else if (character == 'L') effect = MADEffectLoop;
		else if (character == 'O') effect = MADEffectNOffset;
		else return NO;
		command->cmd = effect;
		[self resetPatternFieldBuffer];
	} else if (self.patternField == 3 || self.patternField == 4) {
		BOOL hexadecimal = (character >= '0' && character <= '9') || (character >= 'A' && character <= 'F');
		if (!hexadecimal) return NO;
		NSString *digits = [self appendPatternFieldCharacter:key width:2 row:row channel:channel];
		unsigned int value = 0;
		NSScanner *scanner = [NSScanner scannerWithString:digits];
		[scanner scanHexInt:&value];
		if (self.patternField == 3) command->arg = (MADByte)value;
		else command->vol = (MADByte)value;
	} else {
		return NO;
	}
	[self finishDirectPatternChangeFrom:previous command:command snapshot:snapshot row:row channel:channel actionName:@"Edit Pattern Field"];
	return YES;
}

- (BOOL)patternTableHandleKeyDown:(NSEvent *)event
{
	if (_music == NULL || [self selectedPatternData] == NULL) return NO;
	if ((event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0) return NO;
	BOOL extend = (event.modifierFlags & NSEventModifierFlagShift) != 0;
	switch (event.keyCode) {
		case 123: [self resetPatternFieldBuffer]; [self movePatternSelectionRows:0 channels:-1 extend:extend]; return YES;
		case 124: [self resetPatternFieldBuffer]; [self movePatternSelectionRows:0 channels:1 extend:extend]; return YES;
		case 125: [self resetPatternFieldBuffer]; [self movePatternSelectionRows:self.patternStep channels:0 extend:extend]; return YES;
		case 126: [self resetPatternFieldBuffer]; [self movePatternSelectionRows:-self.patternStep channels:0 extend:extend]; return YES;
		case 48:
			self.patternField += extend ? -1 : 1;
			if (self.patternField < 0) self.patternField = 4;
			if (self.patternField > 4) self.patternField = 0;
			[self resetPatternFieldBuffer];
			[self.patternTable reloadData];
			self.statusField.stringValue = [NSString stringWithFormat:@"Digital %@ field • Tab/Shift-Tab changes field",
				[self patternFieldName]];
			return YES;
		case 36: [self resetPatternFieldBuffer]; [self movePatternSelectionRows:self.patternStep channels:0 extend:NO]; return YES;
		case 51: case 117:
			if (self.patternRecording) [self clearActivePatternField]; else [self clearPatternSelection:nil];
			return YES;
		case 53: [self stopAllSamplePreviews]; [self togglePatternRecording:nil]; return YES;
		default: break;
	}
	NSString *key = event.charactersIgnoringModifiers.lowercaseString;
	if ([key isEqualToString:@"["] || [key isEqualToString:@"]"]) {
		self.patternOctaveOffset = MIN(MAX(self.patternOctaveOffset + ([key isEqualToString:@"]"] ? 1 : -1), -7), 7);
		[NSUserDefaults.standardUserDefaults setInteger:self.patternOctaveOffset forKey:PPDigitalOctaveDefaultsKey];
		[self.pianoController setKeyboardOffset:self.patternOctaveOffset];
		self.statusField.stringValue = [NSString stringWithFormat:@"Piano/Tracker offset: %@%ld octave(s)",
			self.patternOctaveOffset >= 0 ? @"+" : @"", (long)self.patternOctaveOffset];
		return YES;
	}
	NSString *typed = event.characters.lowercaseString;
	if ([typed isEqualToString:@"/"] || [typed isEqualToString:@"*"]) {
		[self transposeSelectedNoteBy:[typed isEqualToString:@"*"] ? 1 : -1];
		return YES;
	}
	if (self.patternRecording && [typed isEqualToString:@"."]) {
		[self clearActivePatternField];
		return YES;
	}
	NSNumber *noteNumber = [self noteForTrackerKey:event.characters];
	// The original Mac-keyboard path gives the Tools Piano Record button
	// precedence over Digital step entry, regardless of which editor is front.
	// This is what makes computer-keyboard performance record at transport time.
	if (self.pianoController.isRecordingEnabled && noteNumber != nil &&
		noteNumber.integerValue < NUMBER_NOTES) {
		NSInteger note = noteNumber.integerValue;
		NSInteger track = MIN(MAX(self.patternCursorChannel, 0),
			MAX((NSInteger)_music->header->numChn - 1, 0));
		[self recordPianoNote:note track:track instrument:_selectedInstrument
			livePlayback:_driver != NULL && MADIsPlayingMusic(_driver) velocity:-1];
		[self previewPatternNote:note];
		return YES;
	}
	if (self.patternRecording && self.patternField != 1) {
		return [self enterPatternFieldCharacter:typed];
	}
	BOOL noteOff = self.patternRecording && self.patternField == 1 &&
		[key isEqualToString:@"="];
	if (!noteOff && (noteNumber == nil || noteNumber.integerValue >= NUMBER_NOTES)) return NO;
	NSInteger note = noteOff ? 0xFE : noteNumber.integerValue;
	if (!noteOff) [self previewPatternNote:note];
	if (!self.patternRecording) {
		self.statusField.stringValue = [NSString stringWithFormat:@"Preview note %ld — click a command field or press Esc to edit", (long)note];
		return YES;
	}
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) return YES;
	(void)bottom; (void)right;
	top = MIN(MAX(self.patternCursorRow, 0), [self selectedPatternData]->header.size - 1);
	left = MIN(MAX(self.patternCursorChannel, 0), (NSInteger)_music->header->numChn - 1);
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	Cmd *command = GetMADCommand((short)top, (short)left, [self selectedPatternData]);
	command->note = (MADByte)note;
	if (self.patternInstrumentToggle.state == NSControlStateValueOn) command->ins = self.defaultPatternInstrument;
	if (self.patternEffectToggle.state == NSControlStateValueOn) command->cmd = self.defaultPatternEffect;
	if (self.patternArgumentToggle.state == NSControlStateValueOn) command->arg = self.defaultPatternArgument;
	if (self.patternVolumeToggle.state == NSControlStateValueOn) {
		command->vol = self.defaultPatternVolume == 0 ? 0xFF : self.defaultPatternVolume;
	}
	[self registerPatternUndoSnapshot:snapshot actionName:@"Enter Pattern Note"];
	_music->hasChanged = true;
	[self.patternTable reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:top]
		columnIndexes:[NSIndexSet indexSetWithIndex:left + 1]];
	[self selectPatternTop:(top + self.patternStep) % [self selectedPatternData]->header.size
		bottom:(top + self.patternStep) % [self selectedPatternData]->header.size left:left right:left];
	self.statusField.stringValue = noteOff ? @"Note OFF entered" : @"Pattern note entered";
	return YES;
}

- (IBAction)togglePatternRecording:(NSButton *)sender
{
	if (sender == nil) {
		self.patternRecording = !self.patternRecording;
		self.patternRecordButton.state = self.patternRecording ? NSControlStateValueOn : NSControlStateValueOff;
	} else {
		self.patternRecording = sender.state == NSControlStateValueOn;
	}
	self.statusField.stringValue = self.patternRecording
		? [NSString stringWithFormat:@"Digital editing on • %@ • octave offset %@%ld • step %ld • Esc turns off",
			[self patternFieldName], self.patternOctaveOffset >= 0 ? @"+" : @"", (long)self.patternOctaveOffset,
			(long)self.patternStep]
		: @"Digital editing off • Esc turns on";
	[self.window makeFirstResponder:self.patternTable];
	[self.patternTable reloadData];
}

- (IBAction)changePatternStep:(NSStepper *)sender
{
	self.patternStep = MIN(MAX(sender.integerValue, 1), 16);
	[NSUserDefaults.standardUserDefaults setInteger:self.patternStep forKey:PPDigitalStepDefaultsKey];
	self.patternStepField.integerValue = self.patternStep;
	[self.window makeFirstResponder:self.patternTable];
}

#pragma mark - Helpers

- (IBAction)focusInstruments:(id)sender
{
	(void)sender;
	[self.instrumentsWindow makeKeyAndOrderFront:nil];
	[self.instrumentsWindow makeFirstResponder:self.instrumentTable];
}

- (IBAction)focusPattern:(id)sender
{
	(void)sender;
	[self.window makeKeyAndOrderFront:nil];
	[self.window makeFirstResponder:self.patternTable];
}

- (IBAction)openPreferredPatternEditor:(id)sender
{
	(void)sender;
	NSInteger row = self.orderTable.clickedRow >= 0 ? self.orderTable.clickedRow : self.orderTable.selectedRow;
	if (row >= 0 && row < MAXPATTERN && _music != NULL && _music->partition[row] != NULL) {
		_selectedPattern = row;
		[self.orderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
		[self.patternTable reloadData];
		[self updatePatternWindowTitle];
	}
	NSString *editor = [NSUserDefaults.standardUserDefaults stringForKey:PPPreferredPatternEditorDefaultsKey];
	if ([editor isEqualToString:@"box"]) [self openBoxEditor:nil];
	else if ([editor isEqualToString:@"classical"]) [self openClassicalEditor:nil];
	else if ([editor isEqualToString:@"overview"]) [self openClassicOverview:nil];
	else [self focusPattern:nil];
}

- (void)openPatternMode:(PPPatternEditorMode)mode
{
	if (_music == NULL || [self selectedPatternData] == NULL) return;
	__weak typeof(self) weakSelf = self;
	__block __weak PPPatternModeController *weakEditor = nil;
	PPPatternModeController *editor = [[PPPatternModeController alloc] initWithMusic:_music driver:_driver
		pattern:_selectedPattern instrument:_selectedInstrument mode:mode changeHandler:^{
			[weakSelf.patternTable reloadData];
			[weakSelf.orderTable reloadData];
			weakSelf.statusField.stringValue = @"Pattern changed in alternate editor";
		} closeHandler:^{
			if (weakEditor != nil) [weakSelf.patternModeEditors removeObject:weakEditor];
		}];
	weakEditor = editor;
	[self.patternModeEditors addObject:editor];
	[editor showWindow:nil];
	[editor.window makeKeyAndOrderFront:nil];
}

- (IBAction)openBoxEditor:(id)sender
{
	(void)sender; [self openPatternMode:PPPatternEditorModeBox];
}

- (IBAction)openClassicalEditor:(id)sender
{
	(void)sender; [self openPatternMode:PPPatternEditorModeClassical];
}

- (IBAction)openClassicOverview:(id)sender
{
	(void)sender; [self openPatternMode:PPPatternEditorModeClassicOverview];
}

- (IBAction)openWaveEditor:(id)sender
{
	(void)sender; [self openPatternMode:PPPatternEditorModeWave];
}

- (IBAction)showTools:(id)sender
{
	(void)sender;
	[self.toolsWindow makeKeyAndOrderFront:nil];
}

- (IBAction)showPatterns:(id)sender
{
	(void)sender;
	[self.patternsWindow makeKeyAndOrderFront:nil];
}

- (IBAction)showPartition:(id)sender
{
	(void)sender;
	[self.partitionTable reloadData];
	[self updatePartitionLengthDisplay];
	if (self.partitionTable.numberOfRows > 0) {
		NSInteger position = MIN(MAX(self.selectedPartitionPosition, 0),
			self.partitionTable.numberOfRows - 1);
		self.suppressPartitionSelectionAction = YES;
		[self.partitionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:position]
			byExtendingSelection:NO];
		[self.partitionTable scrollRowToVisible:position];
		self.suppressPartitionSelectionAction = NO;
	}
	[self.partitionWindow makeKeyAndOrderFront:nil];
	[self.partitionWindow makeFirstResponder:self.partitionTable];
}

- (NSView *)analysisControlStripForWindow:(NSWindow *)window spectrum:(BOOL)spectrum
{
	NSRect bounds = window.contentView.bounds;
	NSView *strip = [[NSView alloc] initWithFrame:NSMakeRect(0, NSHeight(bounds) - 30, NSWidth(bounds), 30)];
	strip.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	NSArray<NSDictionary *> *labels = @[
		@{@"text": @"Display:", @"x": @8},
		@{@"text": @"Size:", @"x": @245},
		@{@"text": spectrum ? @"Scale:" : @"Mode:", @"x": @365}
	];
	for (NSDictionary *definition in labels) {
		NSTextField *label = [NSTextField labelWithString:definition[@"text"]];
		label.frame = NSMakeRect([definition[@"x"] doubleValue], 7, 58, 16);
		label.font = [self classicFont];
		[strip addSubview:label];
	}
	NSPopUpButton *display = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(65, 3, 170, 24) pullsDown:NO];
	[display addItemsWithTitles:@[@"Audio Output", @"Driver Tracks", @"Audio Input"]];
	display.font = [self classicFont];
	[display itemAtIndex:1].enabled = NO;
	[display itemAtIndex:2].enabled = NO;
	display.toolTip = @"The live Audio Output source is active; driver-track and audio-input sources remain future parity work.";
	[strip addSubview:display];

	NSPopUpButton *size = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(285, 3, 70, 24) pullsDown:NO];
	[size addItemsWithTitles:@[@"32", @"64", @"128", @"256"]];
	[size selectItemWithTitle:@"128"];
	size.font = [self classicFont];
	size.target = self;
	size.action = @selector(changeAnalysisSize:);
	size.tag = spectrum ? 1 : 0;
	[strip addSubview:size];

	NSPopUpButton *mode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(415, 3, 110, 24) pullsDown:NO];
	mode.font = [self classicFont];
	if (spectrum) {
		[mode addItemsWithTitles:@[@"Log", @"Linear"]];
		mode.target = self;
		mode.action = @selector(changeSpectrumScale:);
	} else {
		[mode addItemWithTitle:@"Stack"];
	}
	[strip addSubview:mode];
	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(strip.bounds), 1)];
	separator.boxType = NSBoxSeparator;
	separator.autoresizingMask = NSViewWidthSizable;
	[strip addSubview:separator];
	return strip;
}

- (IBAction)changeAnalysisSize:(NSPopUpButton *)sender
{
	NSInteger size = MAX(sender.titleOfSelectedItem.integerValue, 8);
	if (sender.tag == 1) {
		self.spectrumView.analysisSize = size;
		[self.spectrumView setNeedsDisplay:YES];
	} else {
		self.oscilloscopeView.analysisSize = size;
		[self.oscilloscopeView setNeedsDisplay:YES];
	}
}

- (IBAction)changeSpectrumScale:(NSPopUpButton *)sender
{
	self.spectrumView.logarithmicScale = sender.indexOfSelectedItem == 0;
	[self.spectrumView setNeedsDisplay:YES];
}

- (IBAction)showOscilloscope:(id)sender
{
	(void)sender;
	if (self.oscilloscopeWindow == nil) {
		self.oscilloscopeWindow = [self classicPanelWithSize:NSMakeSize(640, 280) title:@"Oscilloscope"];
		self.oscilloscopeWindow.minSize = NSMakeSize(480, 180);
		NSRect bounds = self.oscilloscopeWindow.contentView.bounds;
		self.oscilloscopeView = [[PPOscilloscopeView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds) - 30)];
		self.oscilloscopeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		self.oscilloscopeView.sampleBits = 16;
		self.oscilloscopeView.channelCount = 2;
		self.oscilloscopeView.analysisSize = 128;
		self.oscilloscopeView.drawsConnectedLines =
			[NSUserDefaults.standardUserDefaults boolForKey:PPOscilloscopeLinesDefaultsKey];
		[self.oscilloscopeWindow.contentView addSubview:self.oscilloscopeView];
		[self.oscilloscopeWindow.contentView addSubview:[self analysisControlStripForWindow:self.oscilloscopeWindow spectrum:NO]];
		[self.oscilloscopeWindow setFrameTopLeftPoint:NSMakePoint(NSMinX(self.window.frame) + 40, NSMaxY(self.window.frame) - 80)];
	}
	[self.oscilloscopeWindow makeKeyAndOrderFront:nil];
	[self.oscilloscopeView setNeedsDisplay:YES];
}

- (IBAction)showSpectrum:(id)sender
{
	(void)sender;
	if (self.spectrumWindow == nil) {
		self.spectrumWindow = [self classicPanelWithSize:NSMakeSize(640, 280) title:@"Spectrum"];
		self.spectrumWindow.minSize = NSMakeSize(480, 180);
		NSRect bounds = self.spectrumWindow.contentView.bounds;
		self.spectrumView = [[PPSpectrumView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds) - 30)];
		self.spectrumView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		self.spectrumView.sampleBits = 16;
		self.spectrumView.channelCount = 2;
		self.spectrumView.analysisSize = 128;
		self.spectrumView.sampleRate = 44100;
		self.spectrumView.logarithmicScale = YES;
		self.spectrumView.cursorFraction = 0.5;
		[self.spectrumWindow.contentView addSubview:self.spectrumView];
		[self.spectrumWindow.contentView addSubview:[self analysisControlStripForWindow:self.spectrumWindow spectrum:YES]];
		[self.spectrumWindow setFrameTopLeftPoint:NSMakePoint(NSMinX(self.window.frame) + 70, NSMaxY(self.window.frame) - 110)];
	}
	[self.spectrumWindow makeKeyAndOrderFront:nil];
	[self.spectrumView setNeedsDisplay:YES];
}

- (NSTextField *)preferencesLabel:(NSString *)title frame:(NSRect)frame bold:(BOOL)bold inView:(NSView *)view
{
	NSTextField *label = [NSTextField labelWithString:title];
	label.frame = frame;
	label.font = bold ? [NSFont boldSystemFontOfSize:11] : [self classicFont];
	label.textColor = NSColor.blackColor;
	[view addSubview:label];
	return label;
}

- (NSButton *)preferencesCheckbox:(NSString *)title key:(NSString *)key y:(CGFloat)y inView:(NSView *)view
{
	NSButton *button = [NSButton checkboxWithTitle:title target:self action:@selector(preferenceControlChanged:)];
	button.frame = NSMakeRect(30, y, 385, 19);
	button.font = [self classicFont];
	button.controlSize = NSControlSizeSmall;
	button.identifier = key;
	button.state = [self.preferenceDraft[key] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
	[view addSubview:button];
	return button;
}

- (NSButton *)preferencesRadio:(NSString *)title key:(NSString *)key value:(NSInteger)value
	frame:(NSRect)frame inView:(NSView *)view
{
	SEL action = [key isEqualToString:PPPianoKeyUpModeDefaultsKey]
		? @selector(preferencePianoKeyUpModeChanged:)
		: @selector(preferencePianoRecordingModeChanged:);
	NSButton *button = [NSButton radioButtonWithTitle:title target:self action:action];
	button.frame = frame;
	button.font = [self classicFont];
	button.controlSize = NSControlSizeSmall;
	button.identifier = key;
	button.tag = PPPreferenceRadioTagBase + value;
	button.state = [self.preferenceDraft[key] integerValue] == value
		? NSControlStateValueOn : NSControlStateValueOff;
	[view addSubview:button];
	return button;
}

- (IBAction)preferencePianoKeyUpModeChanged:(id)sender
{
	[self preferenceControlChanged:sender];
}

- (IBAction)preferencePianoRecordingModeChanged:(id)sender
{
	[self preferenceControlChanged:sender];
}

- (NSPopUpButton *)preferencesPopupForKey:(NSString *)key titles:(NSArray<NSString *> *)titles
	values:(NSArray *)values frame:(NSRect)frame inView:(NSView *)view
{
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
	popup.font = [self classicFont];
	popup.controlSize = NSControlSizeSmall;
	popup.identifier = key;
	popup.target = self;
	popup.action = @selector(preferenceControlChanged:);
	id selectedValue = self.preferenceDraft[key];
	for (NSUInteger index = 0; index < titles.count; index++) {
		[popup addItemWithTitle:titles[index]];
		id value = index < values.count ? values[index] : titles[index];
		popup.lastItem.representedObject = value;
		if ([value isEqual:selectedValue]) [popup selectItem:popup.lastItem];
	}
	[view addSubview:popup];
	return popup;
}

- (NSSlider *)preferencesSliderForKey:(NSString *)key minimum:(double)minimum maximum:(double)maximum
	valueSuffix:(NSString *)suffix y:(CGFloat)y inView:(NSView *)view
{
	NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(165, y, 180, 20)];
	slider.minValue = minimum;
	slider.maxValue = maximum;
	slider.integerValue = [self.preferenceDraft[key] integerValue];
	slider.continuous = YES;
	slider.identifier = key;
	slider.target = self;
	slider.action = @selector(preferenceControlChanged:);
	[view addSubview:slider];
	NSTextField *value = [self preferencesLabel:@"" frame:NSMakeRect(352, y + 2, 82, 16) bold:NO inView:view];
	value.alignment = NSTextAlignmentRight;
	value.stringValue = [NSString stringWithFormat:@"%ld%@", (long)slider.integerValue, suffix ?: @""];
	self.preferenceValueFields[key] = value;
	return slider;
}

- (void)preferencesSeparatorAtY:(CGFloat)y inView:(NSView *)view
{
	NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(16, y, NSWidth(view.bounds) - 32, 1)];
	separator.boxType = NSBoxSeparator;
	[view addSubview:separator];
}

- (void)midiEndpointTitlesForSources:(BOOL)sources
	titles:(NSArray<NSString *> * __autoreleasing *)titlesOut
	values:(NSArray<NSNumber *> * __autoreleasing *)valuesOut
	selectedValue:(NSNumber *)selectedValue
{
	NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:
		sources ? @"All MIDI Sources" : @"No Destination"];
	NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithObject:
		sources ? @0 : @(MADMIDI_NO_ENDPOINT_ID)];
	size_t count = sources ? MADMIDIGetSourceCount() : MADMIDIGetDestinationCount();
	for (size_t index = 0; index < count; index++) {
		int32_t identifier = 0;
		char endpointName[256] = {0};
		BOOL valid = sources
			? MADMIDIGetSourceInfo(index, &identifier, endpointName, sizeof(endpointName))
			: MADMIDIGetDestinationInfo(index, &identifier, endpointName, sizeof(endpointName));
		if (!valid) continue;
		NSString *name = [NSString stringWithUTF8String:endpointName] ?: @"Unnamed MIDI endpoint";
		[titles addObject:name];
		[values addObject:@(identifier)];
	}
	if (selectedValue != nil && ![values containsObject:selectedValue] &&
		(selectedValue.integerValue != (sources ? 0 : MADMIDI_NO_ENDPOINT_ID))) {
		[titles addObject:[NSString stringWithFormat:@"Unavailable device (%@)", selectedValue]];
		[values addObject:selectedValue];
	}
	if (titlesOut != NULL) *titlesOut = titles;
	if (valuesOut != NULL) *valuesOut = values;
}

- (int32_t)resolvedMIDIEndpointForSources:(BOOL)sources
	selectedID:(int32_t)selectedID
	preferredName:(NSString *)preferredName
	found:(BOOL *)foundOut
	resolvedName:(NSString * __autoreleasing *)resolvedNameOut
{
	int32_t sentinel = sources ? 0 : MADMIDI_NO_ENDPOINT_ID;
	if (!sources && MADMIDIIsApplicationInputEndpoint(selectedID)) {
		if (foundOut != NULL) *foundOut = YES;
		if (resolvedNameOut != NULL) *resolvedNameOut = @"";
		return sentinel;
	}
	if (selectedID == sentinel) {
		if (foundOut != NULL) *foundOut = YES;
		if (resolvedNameOut != NULL) *resolvedNameOut = @"";
		return selectedID;
	}
	BOOL foundByName = NO;
	int32_t nameMatchID = selectedID;
	NSString *nameMatch = nil;
	size_t count = sources ? MADMIDIGetSourceCount() : MADMIDIGetDestinationCount();
	for (size_t index = 0; index < count; index++) {
		int32_t identifier = 0;
		char endpointName[256] = {0};
		BOOL valid = sources
			? MADMIDIGetSourceInfo(index, &identifier, endpointName, sizeof(endpointName))
			: MADMIDIGetDestinationInfo(index, &identifier, endpointName, sizeof(endpointName));
		if (!valid) continue;
		NSString *name = [NSString stringWithUTF8String:endpointName] ?: @"Unnamed MIDI endpoint";
		if (identifier == selectedID) {
			if (foundOut != NULL) *foundOut = YES;
			if (resolvedNameOut != NULL) *resolvedNameOut = name;
			return identifier;
		}
		if (!foundByName && preferredName.length > 0 &&
			[name isEqualToString:preferredName]) {
			foundByName = YES;
			nameMatchID = identifier;
			nameMatch = name;
		}
	}
	// Early MachoPlayer CoreMIDI builds accidentally persisted the popup's
	// one-based row (1, 2, …) instead of kMIDIPropertyUniqueID. Migrate those
	// small, unnamed values to the endpoint currently occupying that row.
	if (!foundByName && preferredName.length == 0 &&
		selectedID > 0 && (size_t)selectedID <= count) {
		size_t legacyIndex = (size_t)selectedID - 1;
		int32_t identifier = 0;
		char endpointName[256] = {0};
		BOOL valid = sources
			? MADMIDIGetSourceInfo(legacyIndex, &identifier, endpointName, sizeof(endpointName))
			: MADMIDIGetDestinationInfo(legacyIndex, &identifier, endpointName, sizeof(endpointName));
		if (valid) {
			if (foundOut != NULL) *foundOut = YES;
			if (resolvedNameOut != NULL) {
				*resolvedNameOut = [NSString stringWithUTF8String:endpointName] ?:
					@"Unnamed MIDI endpoint";
			}
			return identifier;
		}
	}
	if (foundOut != NULL) *foundOut = foundByName;
	if (resolvedNameOut != NULL) *resolvedNameOut = nameMatch ?: preferredName;
	return nameMatchID;
}

- (void)reconcileMIDIPreferenceDraftEndpoints
{
	if (self.preferenceDraft == nil) return;
	for (NSNumber *sourceValue in @[@YES, @NO]) {
		BOOL sources = sourceValue.boolValue;
		NSString *identifierKey = sources ? PPMIDIInputSourceDefaultsKey :
			PPMIDIOutputDestinationDefaultsKey;
		NSString *nameKey = sources ? PPMIDIInputSourceNameDefaultsKey :
			PPMIDIOutputDestinationNameDefaultsKey;
		BOOL found = NO;
		NSString *resolvedName = nil;
		int32_t resolved = [self resolvedMIDIEndpointForSources:sources
			selectedID:(int32_t)[self.preferenceDraft[identifierKey] integerValue]
			preferredName:self.preferenceDraft[nameKey] found:&found resolvedName:&resolvedName];
		if (found) {
			self.preferenceDraft[identifierKey] = @(resolved);
			self.preferenceDraft[nameKey] = resolvedName ?: @"";
		}
	}
}

- (void)applyMIDIPreferenceDraftRouting
{
	if (self.preferenceDraft == nil) return;
	[self reconcileMIDIPreferenceDraftEndpoints];
	MADMIDISetInput((int32_t)[self.preferenceDraft[PPMIDIInputSourceDefaultsKey] integerValue],
		[self.preferenceDraft[PPMIDIInputEnabledDefaultsKey] boolValue]);
	MADMIDISetOutput((int32_t)[self.preferenceDraft[PPMIDIOutputDestinationDefaultsKey] integerValue],
		[self.preferenceDraft[PPMIDIOutputEnabledDefaultsKey] boolValue]);
	MADMIDISetOutputOptions([self.preferenceDraft[PPMIDIPlaybackOutputDefaultsKey] boolValue],
		[self.preferenceDraft[PPMIDIClockDefaultsKey] boolValue],
		[self.preferenceDraft[PPMIDIProgramChangesDefaultsKey] boolValue],
		(MADMIDIChannelRouting)MIN(MAX(
			[self.preferenceDraft[PPMIDIOutputRoutingDefaultsKey] integerValue], 0), 2),
		(uint8_t)MIN(MAX(
			[self.preferenceDraft[PPMIDIOutputChannelDefaultsKey] integerValue], 0), 15));
	if (_driver != NULL) {
		_driver->SendMIDIClockData =
			[self.preferenceDraft[PPMIDIClockDefaultsKey] boolValue];
	}
}

- (void)applyMIDIPreferences
{
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	// Migrate the first CoreMIDI build's -1 no-destination marker without
	// stealing -1 from a real signed CoreMIDI endpoint that already has a name.
	if ([defaults integerForKey:PPMIDIOutputDestinationDefaultsKey] == -1 &&
		[defaults stringForKey:PPMIDIOutputDestinationNameDefaultsKey].length == 0) {
		[defaults setInteger:MADMIDI_NO_ENDPOINT_ID
			forKey:PPMIDIOutputDestinationDefaultsKey];
	}
	BOOL inputFound = NO;
	BOOL outputFound = NO;
	NSString *inputName = nil;
	NSString *outputName = nil;
	int32_t inputID = [self resolvedMIDIEndpointForSources:YES
		selectedID:(int32_t)[defaults integerForKey:PPMIDIInputSourceDefaultsKey]
		preferredName:[defaults stringForKey:PPMIDIInputSourceNameDefaultsKey]
		found:&inputFound resolvedName:&inputName];
	int32_t outputID = [self resolvedMIDIEndpointForSources:NO
		selectedID:(int32_t)[defaults integerForKey:PPMIDIOutputDestinationDefaultsKey]
		preferredName:[defaults stringForKey:PPMIDIOutputDestinationNameDefaultsKey]
		found:&outputFound resolvedName:&outputName];
	if (inputFound) {
		[defaults setInteger:inputID forKey:PPMIDIInputSourceDefaultsKey];
		[defaults setObject:inputName ?: @"" forKey:PPMIDIInputSourceNameDefaultsKey];
	}
	if (outputFound) {
		[defaults setInteger:outputID forKey:PPMIDIOutputDestinationDefaultsKey];
		[defaults setObject:outputName ?: @"" forKey:PPMIDIOutputDestinationNameDefaultsKey];
	}
	MADMIDISetInput(inputID,
		[defaults boolForKey:PPMIDIInputEnabledDefaultsKey]);
	MADMIDISetOutput(outputID,
		[defaults boolForKey:PPMIDIOutputEnabledDefaultsKey]);
	MADMIDISetOutputOptions([defaults boolForKey:PPMIDIPlaybackOutputDefaultsKey],
		[defaults boolForKey:PPMIDIClockDefaultsKey],
		[defaults boolForKey:PPMIDIProgramChangesDefaultsKey],
		(MADMIDIChannelRouting)MIN(MAX([defaults integerForKey:PPMIDIOutputRoutingDefaultsKey], 0), 2),
		(uint8_t)MIN(MAX([defaults integerForKey:PPMIDIOutputChannelDefaultsKey], 0), 15));
	if (_driver != NULL) {
		_driver->SendMIDIClockData = [defaults boolForKey:PPMIDIClockDefaultsKey];
	}
	if (![defaults boolForKey:PPMIDIInputEnabledDefaultsKey]) {
		for (NSDictionary<NSString *, NSNumber *> *held in self.midiHeldNotes.allValues) {
			[self.pianoController handleMIDINoteOff:held[@"note"].integerValue
				track:held[@"track"].integerValue];
		}
		[self.midiHeldNotes removeAllObjects];
		[self.midiTrackOwners removeAllObjects];
	}
}

- (void)midiDevicesChanged
{
	// Preserve the live endpoint reference. Some virtual destinations publish
	// setup notifications during playback even though they remain usable.
	// The explicit refresh button is the only operation that replaces routing.
	if (self.statusField != nil) {
		self.statusField.stringValue =
			@"CoreMIDI device list changed • use MIDI Preferences refresh to rescan";
	}
}

- (IBAction)refreshMIDIDevices:(id)sender
{
	(void)sender;
	if (self.preferencesPanel.isVisible &&
		self.preferencesCategoryPopup.indexOfSelectedItem == PPPreferencesCategoryMIDI) {
		[self captureVisiblePreferenceValues];
	}
	MADMIDIRefreshDevices();
	if (self.preferencesPanel.isVisible &&
		self.preferencesCategoryPopup.indexOfSelectedItem == PPPreferencesCategoryMIDI) {
		[self reconcileMIDIPreferenceDraftEndpoints];
		[self applyMIDIPreferenceDraftRouting];
		[self rebuildPreferencesPane];
	}
	self.statusField.stringValue = @"CoreMIDI sources and destinations refreshed";
}

- (void)rebuildPreferencesPane
{
	for (NSView *subview in self.preferencesPane.subviews.copy) [subview removeFromSuperview];
	[self.preferenceValueFields removeAllObjects];
	NSView *pane = self.preferencesPane;
	NSInteger category = self.preferencesCategoryPopup.indexOfSelectedItem;
	if (category == PPPreferencesCategoryDriver) {
		[self preferencesLabel:@"Driver - Output" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"Driver:" frame:NSMakeRect(30, 263, 120, 18) bold:NO inView:pane];
		[self preferencesLabel:@"Core Audio" frame:NSMakeRect(165, 263, 240, 18) bold:NO inView:pane];
		[self preferencesLabel:@"Output rate:" frame:NSMakeRect(30, 232, 120, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPDriverSampleRateDefaultsKey
			titles:@[@"11.025 kHz", @"22.05 kHz", @"44.1 kHz", @"48 kHz"]
			values:@[@11025, @22050, @44100, @48000] frame:NSMakeRect(160, 226, 150, 25) inView:pane];
		[self preferencesLabel:@"Format:" frame:NSMakeRect(30, 202, 120, 18) bold:NO inView:pane];
		[self preferencesLabel:@"16-bit Stereo" frame:NSMakeRect(165, 202, 180, 18) bold:NO inView:pane];
		[self preferencesLabel:@"Oversampling:" frame:NSMakeRect(30, 172, 120, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPDriverOversamplingDefaultsKey titles:@[@"1 x", @"2 x", @"4 x"]
			values:@[@1, @2, @4] frame:NSMakeRect(160, 166, 100, 25) inView:pane];
		[self preferencesLabel:@"Stereo delay:" frame:NSMakeRect(30, 142, 120, 18) bold:NO inView:pane];
		[self preferencesSliderForKey:PPDriverMicroDelayDefaultsKey minimum:0 maximum:250 valueSuffix:@" ms"
			y:140 inView:pane];
		[self preferencesCheckbox:@"Remove clicks at sample and volume changes"
			key:PPDriverTickRemoverDefaultsKey y:108 inView:pane];
		[self preferencesCheckbox:@"Surround processing" key:PPDriverSurroundDefaultsKey y:84 inView:pane];
		[self preferencesSeparatorAtY:72 inView:pane];
		[self preferencesCheckbox:@"PlayerPRO reverb" key:PPDriverReverbEnabledDefaultsKey y:49 inView:pane];
		[self preferencesLabel:@"Delay:" frame:NSMakeRect(158, 27, 54, 18) bold:NO inView:pane];
		[self preferencesSliderForKey:PPDriverReverbDelayDefaultsKey minimum:25 maximum:1000 valueSuffix:@" ms"
			y:25 inView:pane];
		[self preferencesLabel:@"Strength:" frame:NSMakeRect(30, 5, 120, 18) bold:NO inView:pane];
		NSSlider *strength = [[NSSlider alloc] initWithFrame:NSMakeRect(165, 3, 180, 20)];
		strength.minValue = 0; strength.maxValue = 70;
		strength.integerValue = [self.preferenceDraft[PPDriverReverbStrengthDefaultsKey] integerValue];
		strength.identifier = PPDriverReverbStrengthDefaultsKey;
		strength.target = self; strength.action = @selector(preferenceControlChanged:);
		[pane addSubview:strength];
		NSTextField *strengthValue = [self preferencesLabel:[NSString stringWithFormat:@"%ld%%", (long)strength.integerValue]
			frame:NSMakeRect(352, 5, 82, 16) bold:NO inView:pane];
		strengthValue.alignment = NSTextAlignmentRight;
		self.preferenceValueFields[PPDriverReverbStrengthDefaultsKey] = strengthValue;
	} else if (category == PPPreferencesCategoryPiano) {
		[self preferencesLabel:@"Piano" frame:NSMakeRect(18, 301, 420, 20) bold:YES inView:pane];

		NSScrollView *mappingScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 59, 118, 229)];
		mappingScroll.hasVerticalScroller = YES;
		mappingScroll.autohidesScrollers = NO;
		mappingScroll.borderType = NSBezelBorder;
		mappingScroll.backgroundColor = NSColor.whiteColor;
		PPPianoKeyMapTableView *mappingView = [[PPPianoKeyMapTableView alloc]
			initWithFrame:NSMakeRect(0, 0, 98, NUMBER_NOTES * 17)];
		NSArray<NSString *> *draftMapping = self.preferenceDraft[PPPianoKeyMapDefaultsKey];
		[mappingView replaceKeyMap:draftMapping];
		__weak typeof(self) weakSelf = self;
		mappingView.keyMapChangedHandler = ^(NSArray<NSString *> *keyMap) {
			weakSelf.preferenceDraft[PPPianoKeyMapDefaultsKey] = keyMap;
		};
		mappingView.toolTip = @"Select a note and press a printable key to assign it; Delete clears it";
		mappingScroll.documentView = mappingView;
		[pane addSubview:mappingScroll];
		[mappingView selectRowIndexes:[NSIndexSet indexSetWithIndex:24] byExtendingSelection:NO];
		[mappingView scrollRowToVisible:24];

		NSTextField *mappingHint = [self preferencesLabel:
			@"Select a note, then press a key to change it. Delete clears it."
			frame:NSMakeRect(151, 264, 287, 32) bold:YES inView:pane];
		mappingHint.lineBreakMode = NSLineBreakByWordWrapping;
		NSButton *macKeyboard = [self preferencesCheckbox:@"Use Mac Keyboard"
			key:PPPianoMacKeyboardDefaultsKey y:242 inView:pane];
		macKeyboard.frame = NSMakeRect(151, 242, 270, 19);
		[self preferencesSeparatorAtY:230 inView:pane];

		[self preferencesLabel:@"When key UP:" frame:NSMakeRect(151, 205, 100, 18) bold:NO inView:pane];
		[self preferencesRadio:@"Nothing" key:PPPianoKeyUpModeDefaultsKey value:0
			frame:NSMakeRect(151, 181, 82, 20) inView:pane];
		[self preferencesRadio:@"Key OFF" key:PPPianoKeyUpModeDefaultsKey value:1
			frame:NSMakeRect(241, 181, 86, 20) inView:pane];
		[self preferencesRadio:@"Stop" key:PPPianoKeyUpModeDefaultsKey value:2
			frame:NSMakeRect(335, 181, 76, 20) inView:pane];
		[self preferencesSeparatorAtY:171 inView:pane];

		[self preferencesLabel:@"View:" frame:NSMakeRect(151, 147, 48, 18) bold:NO inView:pane];
		NSButton *small = [self preferencesCheckbox:@"Small Piano"
			key:PPPianoSmallViewDefaultsKey y:145 inView:pane];
		small.frame = NSMakeRect(197, 145, 105, 19);
		NSButton *markers = [self preferencesCheckbox:@"Octave markers"
			key:PPPianoOctaveMarkersDefaultsKey y:145 inView:pane];
		markers.frame = NSMakeRect(302, 145, 125, 19);
		[self preferencesLabel:[NSString stringWithFormat:@"Current octave offset:   %@%ld",
			self.patternOctaveOffset >= 0 ? @"+" : @"", (long)self.patternOctaveOffset]
			frame:NSMakeRect(151, 121, 270, 18) bold:NO inView:pane];
		[self preferencesSeparatorAtY:109 inView:pane];

		[self preferencesLabel:@"Playing & Recording:" frame:NSMakeRect(151, 84, 150, 18) bold:NO inView:pane];
		[self preferencesRadio:@"On following tracks" key:PPPianoRecordingModeDefaultsKey value:3
			frame:NSMakeRect(151, 59, 155, 20) inView:pane];
		[self preferencesRadio:@"On track:" key:PPPianoRecordingModeDefaultsKey value:0
			frame:NSMakeRect(151, 35, 88, 20) inView:pane];
		NSMutableArray<NSString *> *trackTitles = [NSMutableArray array];
		NSMutableArray<NSNumber *> *trackValues = [NSMutableArray array];
		NSInteger trackCount = _music == NULL || _music->header == NULL
			? 32 : MIN(MAX((NSInteger)_music->header->numChn, 1), 32);
		for (NSInteger track = 0; track < trackCount; track++) {
			[trackTitles addObject:[NSString stringWithFormat:@"%ld", (long)track + 1]];
			[trackValues addObject:@(track)];
		}
		[self preferencesPopupForKey:PPPianoRecordingTrackDefaultsKey titles:trackTitles values:trackValues
			frame:NSMakeRect(239, 31, 58, 25) inView:pane];
		[self preferencesRadio:@"On all tracks" key:PPPianoRecordingModeDefaultsKey value:1
			frame:NSMakeRect(306, 59, 120, 20) inView:pane];
		[self preferencesRadio:@"On current track" key:PPPianoRecordingModeDefaultsKey value:2
			frame:NSMakeRect(306, 35, 130, 20) inView:pane];
	} else if (category == PPPreferencesCategoryMIDI) {
		[self preferencesLabel:@"CoreMIDI Routing" frame:NSMakeRect(18, 301, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"Input" frame:NSMakeRect(24, 273, 190, 18) bold:YES inView:pane];
		NSButton *inputEnabled = [self preferencesCheckbox:@"Enable MIDI input"
			key:PPMIDIInputEnabledDefaultsKey y:247 inView:pane];
		inputEnabled.frame = NSMakeRect(24, 247, 195, 19);
		[self preferencesLabel:@"Source:" frame:NSMakeRect(24, 220, 52, 18) bold:NO inView:pane];
		NSArray<NSString *> *sourceTitles = nil;
		NSArray<NSNumber *> *sourceValues = nil;
		[self midiEndpointTitlesForSources:YES titles:&sourceTitles values:&sourceValues
			selectedValue:self.preferenceDraft[PPMIDIInputSourceDefaultsKey]];
		[self preferencesPopupForKey:PPMIDIInputSourceDefaultsKey titles:sourceTitles values:sourceValues
			frame:NSMakeRect(75, 214, 111, 25) inView:pane];
		NSButton *refreshMIDI = [NSButton buttonWithTitle:@"↻" target:self
			action:@selector(refreshMIDIDevices:)];
		refreshMIDI.frame = NSMakeRect(189, 214, 29, 25);
		refreshMIDI.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
		refreshMIDI.toolTip = @"Rescan CoreMIDI sources and destinations";
		[pane addSubview:refreshMIDI];
		[self preferencesLabel:@"Receive:" frame:NSMakeRect(24, 187, 60, 18) bold:NO inView:pane];
		NSMutableArray<NSString *> *channelTitles = [NSMutableArray arrayWithObject:@"Omni"];
		NSMutableArray<NSNumber *> *channelValues = [NSMutableArray arrayWithObject:@0];
		for (NSInteger channel = 1; channel <= 16; channel++) {
			[channelTitles addObject:[NSString stringWithFormat:@"Channel %ld", (long)channel]];
			[channelValues addObject:@(channel)];
		}
		[self preferencesPopupForKey:PPMIDIInputChannelDefaultsKey titles:channelTitles values:channelValues
			frame:NSMakeRect(86, 181, 131, 25) inView:pane];
		NSButton *velocity = [self preferencesCheckbox:@"Velocity controls volume"
			key:PPMIDIVelocityDefaultsKey y:153 inView:pane];
		velocity.frame = NSMakeRect(24, 153, 195, 19);
		NSButton *mapping = [self preferencesCheckbox:@"Channel → instrument/track"
			key:PPMIDIChannelMappingDefaultsKey y:127 inView:pane];
		mapping.frame = NSMakeRect(24, 127, 205, 19);
		[self preferencesLabel:@"Key release:" frame:NSMakeRect(24, 99, 78, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPMIDIRecordNoteOffDefaultsKey
			titles:@[@"Stop audition", @"Record Note OFF"]
			values:@[@NO, @YES] frame:NSMakeRect(100, 93, 117, 25) inView:pane];
		NSTextField *virtualInput = [self preferencesLabel:@"Virtual port: MachoPlayer Input"
			frame:NSMakeRect(24, 53, 200, 34) bold:NO inView:pane];
		virtualInput.lineBreakMode = NSLineBreakByWordWrapping;

		[self preferencesLabel:@"Output" frame:NSMakeRect(239, 273, 199, 18) bold:YES inView:pane];
		NSButton *outputEnabled = [self preferencesCheckbox:@"Enable MIDI output"
			key:PPMIDIOutputEnabledDefaultsKey y:247 inView:pane];
		outputEnabled.frame = NSMakeRect(239, 247, 199, 19);
		[self preferencesLabel:@"Destination:" frame:NSMakeRect(239, 220, 84, 18) bold:NO inView:pane];
		NSArray<NSString *> *destinationTitles = nil;
		NSArray<NSNumber *> *destinationValues = nil;
		[self midiEndpointTitlesForSources:NO titles:&destinationTitles values:&destinationValues
			selectedValue:self.preferenceDraft[PPMIDIOutputDestinationDefaultsKey]];
		[self preferencesPopupForKey:PPMIDIOutputDestinationDefaultsKey
			titles:destinationTitles values:destinationValues
			frame:NSMakeRect(239, 194, 199, 25) inView:pane];
		NSButton *audition = [self preferencesCheckbox:@"Piano/editor audition"
			key:PPMIDIAuditionOutputDefaultsKey y:171 inView:pane];
		audition.frame = NSMakeRect(239, 171, 199, 19);
		NSButton *thru = [self preferencesCheckbox:@"MIDI input thru"
			key:PPMIDIThruDefaultsKey y:149 inView:pane];
		thru.frame = NSMakeRect(239, 149, 199, 19);
		NSButton *playback = [self preferencesCheckbox:@"Song playback"
			key:PPMIDIPlaybackOutputDefaultsKey y:127 inView:pane];
		playback.frame = NSMakeRect(239, 127, 199, 19);
		[self preferencesLabel:@"Route channel:" frame:NSMakeRect(239, 103, 91, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPMIDIOutputRoutingDefaultsKey
			titles:@[@"By tracker track", @"By instrument", @"Fixed channel"]
			values:@[@0, @1, @2] frame:NSMakeRect(326, 97, 112, 25) inView:pane];
		[self preferencesLabel:@"Fixed:" frame:NSMakeRect(239, 74, 48, 18) bold:NO inView:pane];
		NSMutableArray<NSString *> *outputChannels = [NSMutableArray array];
		NSMutableArray<NSNumber *> *outputChannelValues = [NSMutableArray array];
		for (NSInteger channel = 0; channel < 16; channel++) {
			[outputChannels addObject:[NSString stringWithFormat:@"Channel %ld", (long)channel + 1]];
			[outputChannelValues addObject:@(channel)];
		}
		[self preferencesPopupForKey:PPMIDIOutputChannelDefaultsKey
			titles:outputChannels values:outputChannelValues
			frame:NSMakeRect(286, 68, 152, 25) inView:pane];
		NSButton *programs = [self preferencesCheckbox:@"Send program changes"
			key:PPMIDIProgramChangesDefaultsKey y:43 inView:pane];
		programs.frame = NSMakeRect(239, 43, 199, 19);
		NSButton *clock = [self preferencesCheckbox:@"Send MIDI clock/start/stop"
			key:PPMIDIClockDefaultsKey y:19 inView:pane];
		clock.frame = NSMakeRect(239, 19, 199, 19);
	} else if (category == PPPreferencesCategoryMusicList) {
		[self preferencesLabel:@"Music List" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"When a music finishes:" frame:NSMakeRect(30, 260, 180, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPMusicListPlaybackModeDefaultsKey
			titles:@[@"Stop", @"Play next", @"Random", @"Loop current"]
			values:@[@0, @1, @2, @3] frame:NSMakeRect(215, 254, 180, 25) inView:pane];
		[self preferencesCheckbox:@"Remember the Music List for the next launch"
			key:PPMusicListRememberDefaultsKey y:216 inView:pane];
		[self preferencesCheckbox:@"Load the first music when a saved list is opened"
			key:PPMusicListLoadFirstDefaultsKey y:184 inView:pane];
		[self preferencesCheckbox:@"Return to the start when playback finishes"
			key:PPMusicListReturnToStartDefaultsKey y:152 inView:pane];
		[self preferencesCheckbox:@"Automatically play after opening a music"
			key:PPMusicListAutoPlayDefaultsKey y:120 inView:pane];
	} else if (category == PPPreferencesCategoryColor) {
		[self preferencesLabel:@"Color" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"Track colors" frame:NSMakeRect(30, 266, 180, 18) bold:NO inView:pane];
		NSArray<NSColor *> *colors = self.preferenceDraft[PPTrackColorsDefaultsKey];
		for (NSInteger track = 0; track < 8; track++) {
			CGFloat x = track < 4 ? 35 : 235;
			CGFloat y = 224 - (track % 4) * 45;
			[self preferencesLabel:[NSString stringWithFormat:@"Track %ld:", (long)track + 1]
				frame:NSMakeRect(x, y + 5, 78, 18) bold:NO inView:pane];
			NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(x + 82, y, 62, 27)];
			well.tag = track;
			well.color = track < (NSInteger)colors.count ? colors[track] : PPPreferredTrackColor(track);
			well.target = self;
			well.action = @selector(preferenceColorChanged:);
			[pane addSubview:well];
		}
		NSButton *reset = [NSButton buttonWithTitle:@"Original Colors" target:self
			action:@selector(resetPreferenceColors:)];
		reset.frame = NSMakeRect(303, 26, 132, 27);
		reset.font = [self classicFont];
		reset.bezelStyle = NSBezelStyleRounded;
		[pane addSubview:reset];
	} else if (category == PPPreferencesCategoryMisc) {
		[self preferencesLabel:@"Misc" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesCheckbox:@"Compress MAD1 files when saving"
			key:PPAutomaticCompressionDefaultsKey y:252 inView:pane];
		[self preferencesCheckbox:@"Add .madk extension when a file name has none"
			key:PPAddFileExtensionDefaultsKey y:216 inView:pane];
		[self preferencesCheckbox:@"Connect oscilloscope samples with lines"
			key:PPOscilloscopeLinesDefaultsKey y:180 inView:pane];
		[self preferencesLabel:@"Preferred pattern editor:" frame:NSMakeRect(30, 139, 180, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPPreferredPatternEditorDefaultsKey
			titles:@[@"Digital Editor", @"Box Editor", @"Pattern View", @"Classical Editor"]
			values:@[@"digital", @"box", @"overview", @"classical"]
			frame:NSMakeRect(210, 133, 190, 25) inView:pane];
	} else if (category == PPPreferencesCategoryBoxEditor) {
		[self preferencesLabel:@"Box Editor" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"Default zoom:" frame:NSMakeRect(30, 254, 130, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPBoxZoomDefaultsKey titles:@[@"1 x", @"2 x", @"3 x"]
			values:@[@1, @2, @3] frame:NSMakeRect(165, 248, 100, 25) inView:pane];
		[self preferencesCheckbox:@"Draw octave markers" key:PPBoxOctaveMarkersDefaultsKey y:210 inView:pane];
		[self preferencesCheckbox:@"Audition notes while editing" key:PPBoxAuditionDefaultsKey y:176 inView:pane];
		[self preferencesCheckbox:@"Show alternating eight-row time bands" key:PPBoxTimeBandsDefaultsKey y:142 inView:pane];
	} else if (category == PPPreferencesCategoryDigitalEditor) {
		[self preferencesLabel:@"Digital Editor" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"Default step:" frame:NSMakeRect(30, 254, 130, 18) bold:NO inView:pane];
		NSMutableArray *steps = [NSMutableArray array];
		NSMutableArray *stepValues = [NSMutableArray array];
		for (NSInteger value = 1; value <= 16; value++) {
			[steps addObject:[NSString stringWithFormat:@"%ld", (long)value]];
			[stepValues addObject:@(value)];
		}
		[self preferencesPopupForKey:PPDigitalStepDefaultsKey titles:steps values:stepValues
			frame:NSMakeRect(165, 248, 100, 25) inView:pane];
		[self preferencesLabel:@"Default octave:" frame:NSMakeRect(30, 216, 130, 18) bold:NO inView:pane];
		NSMutableArray *octaves = [NSMutableArray array];
		NSMutableArray *octaveValues = [NSMutableArray array];
		for (NSInteger value = -4; value <= 4; value++) {
			[octaves addObject:[NSString stringWithFormat:@"%+ld", (long)value]];
			[octaveValues addObject:@(value)];
		}
		[self preferencesPopupForKey:PPDigitalOctaveDefaultsKey titles:octaves values:octaveValues
			frame:NSMakeRect(165, 210, 100, 25) inView:pane];
		[self preferencesCheckbox:@"Trace the playing row" key:PPDigitalTraceDefaultsKey y:170 inView:pane];
		[self preferencesCheckbox:@"Draw dotted field guides" key:PPDigitalFieldGuidesDefaultsKey y:136 inView:pane];
		[self preferencesCheckbox:@"Draw horizontal row guides" key:PPDigitalRowGuidesDefaultsKey y:102 inView:pane];
	} else if (category == PPPreferencesCategoryClassicalEditor) {
		[self preferencesLabel:@"Classical Editor" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		[self preferencesLabel:@"Default zoom:" frame:NSMakeRect(30, 254, 130, 18) bold:NO inView:pane];
		[self preferencesPopupForKey:PPClassicalZoomDefaultsKey titles:@[@"1 x", @"2 x", @"3 x"]
			values:@[@1, @2, @3] frame:NSMakeRect(165, 248, 100, 25) inView:pane];
		[self preferencesCheckbox:@"Draw staff guides" key:PPClassicalStaffGuidesDefaultsKey y:206 inView:pane];
		[self preferencesCheckbox:@"Audition notes while editing" key:PPClassicalAuditionDefaultsKey y:172 inView:pane];
	} else {
		[self preferencesLabel:@"FKEYs" frame:NSMakeRect(18, 296, 420, 20) bold:YES inView:pane];
		NSArray<NSString *> *actionTitles = @[@"No action", @"Open…", @"Play / Pause", @"Stop",
			@"Mixer", @"Instruments", @"Patterns", @"Piano", @"Oscilloscope", @"Spectrum",
			@"Music List", @"Pattern View", @"Preferences"];
		NSArray<NSString *> *actionValues = @[@"none", @"open", @"play", @"stop", @"mixer",
			@"instruments", @"patterns", @"piano", @"oscilloscope", @"spectrum",
			@"music-list", @"overview", @"preferences"];
		NSArray *actions = self.preferenceDraft[PPFKeyActionsDefaultsKey];
		for (NSInteger index = 0; index < 12; index++) {
			CGFloat x = index < 6 ? 30 : 245;
			CGFloat y = 250 - (index % 6) * 39;
			[self preferencesLabel:[NSString stringWithFormat:@"F%ld:", (long)index + 1]
				frame:NSMakeRect(x, y + 5, 28, 18) bold:NO inView:pane];
			NSString *key = [NSString stringWithFormat:@"fkey-%ld", (long)index];
			self.preferenceDraft[key] = index < (NSInteger)actions.count ? actions[index] : @"none";
			[self preferencesPopupForKey:key titles:actionTitles values:actionValues
				frame:NSMakeRect(x + 30, y, 154, 25) inView:pane];
		}
	}
	PPForceClassicLightAppearanceOnView(pane);
}

- (void)captureVisiblePreferenceValues
{
	if (self.preferenceDraft == nil || self.preferencesPane == nil) return;
	for (NSView *view in self.preferencesPane.subviews) {
		NSString *key = view.identifier;
		if (key.length == 0) continue;
		if ([view isKindOfClass:NSPopUpButton.class]) {
			NSMenuItem *selectedItem = [(NSPopUpButton *)view selectedItem];
			id value = selectedItem.representedObject;
			if (value == nil) continue;
			self.preferenceDraft[key] = value;
			if ([key isEqualToString:PPMIDIInputSourceDefaultsKey]) {
				self.preferenceDraft[PPMIDIInputSourceNameDefaultsKey] =
					[value integerValue] == 0 ? @"" : selectedItem.title;
			} else if ([key isEqualToString:PPMIDIOutputDestinationDefaultsKey]) {
				self.preferenceDraft[PPMIDIOutputDestinationNameDefaultsKey] =
					[value integerValue] == MADMIDI_NO_ENDPOINT_ID ? @"" : selectedItem.title;
			}
		} else if ([view isKindOfClass:NSButton.class]) {
			NSButton *button = (NSButton *)view;
			if (button.tag >= PPPreferenceRadioTagBase) {
				if (button.state == NSControlStateValueOn) {
					self.preferenceDraft[key] = @(button.tag - PPPreferenceRadioTagBase);
				}
			} else {
				self.preferenceDraft[key] = @(button.state == NSControlStateValueOn);
			}
		} else if ([view isKindOfClass:NSSlider.class]) {
			self.preferenceDraft[key] = @([(NSSlider *)view integerValue]);
		}
	}
}

- (IBAction)preferenceCategoryChanged:(id)sender
{
	(void)sender;
	[self captureVisiblePreferenceValues];
	[self rebuildPreferencesPane];
}

- (IBAction)preferenceControlChanged:(id)sender
{
	NSString *key = [sender identifier];
	if (key.length == 0) return;
	if ([sender isKindOfClass:NSButton.class]) {
		NSButton *button = sender;
		if (button.tag >= PPPreferenceRadioTagBase) {
			for (NSView *view in self.preferencesPane.subviews) {
				if ([view isKindOfClass:NSButton.class] &&
					[((NSButton *)view).identifier isEqualToString:key] &&
					((NSButton *)view).tag >= PPPreferenceRadioTagBase) {
					((NSButton *)view).state = view == button
						? NSControlStateValueOn : NSControlStateValueOff;
				}
			}
			self.preferenceDraft[key] = @(button.tag - PPPreferenceRadioTagBase);
		} else {
			self.preferenceDraft[key] = @(button.state == NSControlStateValueOn);
		}
	} else if ([sender isKindOfClass:NSPopUpButton.class]) {
		NSMenuItem *selectedItem = [(NSPopUpButton *)sender selectedItem];
		id value = selectedItem.representedObject;
		if (value != nil) self.preferenceDraft[key] = value;
		if ([key isEqualToString:PPMIDIInputSourceDefaultsKey]) {
			self.preferenceDraft[PPMIDIInputSourceNameDefaultsKey] =
				[value integerValue] == 0 ? @"" : selectedItem.title;
		} else if ([key isEqualToString:PPMIDIOutputDestinationDefaultsKey]) {
			self.preferenceDraft[PPMIDIOutputDestinationNameDefaultsKey] =
				[value integerValue] == MADMIDI_NO_ENDPOINT_ID ? @"" : selectedItem.title;
		}
	} else if ([sender isKindOfClass:NSSlider.class]) {
		NSSlider *slider = sender;
		self.preferenceDraft[key] = @(slider.integerValue);
		NSString *suffix = [key isEqualToString:PPDriverMicroDelayDefaultsKey] ||
			[key isEqualToString:PPDriverReverbDelayDefaultsKey] ? @" ms" :
			([key isEqualToString:PPDriverReverbStrengthDefaultsKey] ? @"%" : @"");
		self.preferenceValueFields[key].stringValue =
			[NSString stringWithFormat:@"%ld%@", (long)slider.integerValue, suffix];
	}
	if ([key hasPrefix:@"MIDI"]) [self applyMIDIPreferenceDraftRouting];
}

- (IBAction)preferenceColorChanged:(NSColorWell *)sender
{
	NSMutableArray<NSColor *> *colors = [self.preferenceDraft[PPTrackColorsDefaultsKey] mutableCopy];
	while (colors.count < 8) [colors addObject:PPPreferredTrackColor(colors.count)];
	colors[(NSUInteger)MIN(MAX(sender.tag, 0), 7)] = sender.color;
	self.preferenceDraft[PPTrackColorsDefaultsKey] = colors;
}

- (IBAction)resetPreferenceColors:(id)sender
{
	(void)sender;
	self.preferenceDraft[PPTrackColorsDefaultsKey] = [PPDefaultTrackColors() mutableCopy];
	[self rebuildPreferencesPane];
}

- (IBAction)cancelPreferences:(id)sender
{
	(void)sender;
	[self.preferencesPanel orderOut:nil];
	self.preferenceDraft = nil;
	[self applyMIDIPreferences];
}

- (IBAction)applyPreferences:(id)sender
{
	(void)sender;
	[self captureVisiblePreferenceValues];
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	for (NSString *key in PPPreferenceDefaultValues()) {
		if ([key isEqualToString:PPTrackColorsDefaultsKey] || [key isEqualToString:PPFKeyActionsDefaultsKey]) continue;
		id value = self.preferenceDraft[key];
		if (value != nil) [defaults setObject:value forKey:key];
	}
	NSMutableArray *functionActions = [NSMutableArray arrayWithCapacity:12];
	for (NSInteger index = 0; index < 12; index++) {
		NSString *key = [NSString stringWithFormat:@"fkey-%ld", (long)index];
		[functionActions addObject:self.preferenceDraft[key] ?: @"none"];
	}
	[defaults setObject:functionActions forKey:PPFKeyActionsDefaultsKey];
	PPStorePreferredTrackColors(self.preferenceDraft[PPTrackColorsDefaultsKey]);
	[self applyMIDIPreferences];

	self.musicListPlaybackMode = MIN(MAX([defaults integerForKey:PPMusicListPlaybackModeDefaultsKey], 0), 3);
	for (NSMenuItem *item in self.musicListPlaybackPopup.menu.itemArray) {
		if (item.action == @selector(changeMusicListPlaybackMode:)) {
			item.state = item.tag == self.musicListPlaybackMode ? NSControlStateValueOn : NSControlStateValueOff;
		}
	}
	[self persistRememberedMusicList];
	self.patternStep = MIN(MAX([defaults integerForKey:PPDigitalStepDefaultsKey], 1), 16);
	self.patternStepper.integerValue = self.patternStep;
	self.patternStepField.integerValue = self.patternStep;
	self.patternOctaveOffset = MIN(MAX([defaults integerForKey:PPDigitalOctaveDefaultsKey], -7), 7);
	[self.pianoController setKeyboardOffset:self.patternOctaveOffset];
	[self.pianoController reloadPreferences];
	self.patternTraceEnabled = [defaults boolForKey:PPDigitalTraceDefaultsKey];
	self.patternTraceButton.state = self.patternTraceEnabled ? NSControlStateValueOn : NSControlStateValueOff;
	self.oscilloscopeView.drawsConnectedLines = [defaults boolForKey:PPOscilloscopeLinesDefaultsKey];
	[self.oscilloscopeView setNeedsDisplay:YES];

	if (_driver != NULL) {
		MADDriverSettings settings = _driver->DriverSettings;
		settings.outPutRate = (unsigned int)[defaults integerForKey:PPDriverSampleRateDefaultsKey];
		settings.oversampling = (int)[defaults integerForKey:PPDriverOversamplingDefaultsKey];
		settings.MicroDelaySize = (int)[defaults integerForKey:PPDriverMicroDelayDefaultsKey];
		settings.TickRemover = [defaults boolForKey:PPDriverTickRemoverDefaultsKey];
		settings.surround = [defaults boolForKey:PPDriverSurroundDefaultsKey];
		settings.Reverb = [defaults boolForKey:PPDriverReverbEnabledDefaultsKey];
		settings.ReverbSize = (int)[defaults integerForKey:PPDriverReverbDelayDefaultsKey];
		settings.ReverbStrength = (int)[defaults integerForKey:PPDriverReverbStrengthDefaultsKey];
		MADDriverSettings current = _driver->DriverSettings;
		BOOL changed = settings.outPutRate != current.outPutRate ||
			settings.oversampling != current.oversampling ||
			settings.MicroDelaySize != current.MicroDelaySize ||
			settings.TickRemover != current.TickRemover ||
			settings.surround != current.surround ||
			settings.Reverb != current.Reverb ||
			settings.ReverbSize != current.ReverbSize ||
			settings.ReverbStrength != current.ReverbStrength;
		if (changed) [self reconfigureDriverWithSettings:settings operation:@"applying audio preferences"];
	}
	[self applyMIDIPreferences];
	[self rebuildPatternColumns];
	[self.patternTable reloadData];
	[self.mixerController.window.contentView setNeedsDisplay:YES];
	[self.pianoController.window.contentView setNeedsDisplay:YES];
	for (PPPatternModeController *editor in self.patternModeEditors) {
		[editor reloadPreferences];
	}
	self.statusField.stringValue = @"Preferences applied";
	[self.preferencesPanel orderOut:nil];
	self.preferenceDraft = nil;
}

- (IBAction)showPreferencesWindow:(id)sender
{
	(void)sender;
	if (self.preferencesPanel == nil) {
		self.preferencesPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 462, 382)
			styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
			backing:NSBackingStoreBuffered defer:NO];
		self.preferencesPanel.title = @"Preferences";
		self.preferencesPanel.releasedWhenClosed = NO;
		self.preferencesPanel.hidesOnDeactivate = NO;
		self.preferencesPanel.backgroundColor = [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
		NSView *content = self.preferencesPanel.contentView;
		[self preferencesLabel:@"Prefs:" frame:NSMakeRect(16, 345, 45, 18) bold:YES inView:content];
		self.preferencesCategoryPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, 339, 210, 27) pullsDown:NO];
		[self.preferencesCategoryPopup addItemsWithTitles:@[@"Driver - Output", @"Piano", @"MIDI",
			@"Music List", @"Color", @"Misc", @"Box Editor", @"Digital Editor",
			@"Classical Editor", @"FKEYs"]];
		self.preferencesCategoryPopup.font = [self classicFont];
		self.preferencesCategoryPopup.target = self;
		self.preferencesCategoryPopup.action = @selector(preferenceCategoryChanged:);
		[content addSubview:self.preferencesCategoryPopup];
		NSButton *okay = [NSButton buttonWithTitle:@"OK" target:self action:@selector(applyPreferences:)];
		okay.frame = NSMakeRect(310, 338, 62, 29);
		okay.keyEquivalent = @"\r";
		okay.font = [self classicFont];
		[content addSubview:okay];
		NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelPreferences:)];
		cancel.frame = NSMakeRect(378, 338, 68, 29);
		cancel.keyEquivalent = @"\e";
		cancel.font = [self classicFont];
		[content addSubview:cancel];
		[self preferencesSeparatorAtY:330 inView:content];
		self.preferencesPane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 462, 329)];
		[content addSubview:self.preferencesPane];
	}
	NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
	self.preferenceDraft = [NSMutableDictionary dictionary];
	for (NSString *key in PPPreferenceDefaultValues()) {
		id value = [defaults objectForKey:key] ?: PPPreferenceDefaultValues()[key];
		if (value != nil) self.preferenceDraft[key] = value;
	}
	self.preferenceDraft[PPTrackColorsDefaultsKey] = [PPPreferredTrackColors() mutableCopy];
	if (_driver != NULL) {
		self.preferenceDraft[PPDriverSampleRateDefaultsKey] = @(_driver->DriverSettings.outPutRate);
		self.preferenceDraft[PPDriverOversamplingDefaultsKey] = @(_driver->DriverSettings.oversampling);
		self.preferenceDraft[PPDriverMicroDelayDefaultsKey] = @(_driver->DriverSettings.MicroDelaySize);
		self.preferenceDraft[PPDriverTickRemoverDefaultsKey] = @(_driver->DriverSettings.TickRemover);
		self.preferenceDraft[PPDriverSurroundDefaultsKey] = @(_driver->DriverSettings.surround);
		self.preferenceDraft[PPDriverReverbEnabledDefaultsKey] = @(_driver->DriverSettings.Reverb);
		self.preferenceDraft[PPDriverReverbDelayDefaultsKey] = @(_driver->DriverSettings.ReverbSize);
		self.preferenceDraft[PPDriverReverbStrengthDefaultsKey] = @(_driver->DriverSettings.ReverbStrength);
	}
	[self reconcileMIDIPreferenceDraftEndpoints];
	self.preferenceValueFields = [NSMutableDictionary dictionary];
	[self rebuildPreferencesPane];
	PPForceClassicLightAppearanceOnWindow(self.preferencesPanel);
	[self.preferencesPanel center];
	[self.preferencesPanel makeKeyAndOrderFront:nil];
}

- (IBAction)showMusicInformation:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL) return;
	if (self.generalInformationPanel.sheetParent != nil || self.generalInformationPanel.visible) {
		[self.generalInformationPanel makeKeyAndOrderFront:nil];
		return;
	}

	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 378, 320)
		styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	panel.title = @"General Information";
	panel.releasedWhenClosed = NO;
	panel.hidesOnDeactivate = NO;
	self.generalInformationPanel = panel;
	NSView *content = panel.contentView;
	NSFont *font = [self classicFont];

	NSTextField *(^addLabel)(NSString *, NSRect) = ^NSTextField *(NSString *title, NSRect frame) {
		NSTextField *label = [NSTextField labelWithString:title];
		label.frame = frame;
		label.font = font;
		label.alignment = NSTextAlignmentRight;
		label.textColor = NSColor.blackColor;
		[content addSubview:label];
		return label;
	};
	NSTextField *(^addField)(NSString *, NSRect) = ^NSTextField *(NSString *value, NSRect frame) {
		NSTextField *field = [NSTextField textFieldWithString:value ?: @""];
		field.frame = frame;
		field.font = font;
		field.textColor = NSColor.blackColor;
		field.backgroundColor = NSColor.whiteColor;
		field.focusRingType = NSFocusRingTypeExterior;
		[content addSubview:field];
		return field;
	};
	NSButton *(^addCheck)(NSString *, CGFloat, BOOL) = ^NSButton *(NSString *title, CGFloat y, BOOL enabled) {
		NSButton *button = [NSButton checkboxWithTitle:title target:nil action:nil];
		button.frame = NSMakeRect(106, y, 210, 19);
		button.font = font;
		button.controlSize = NSControlSizeMini;
		button.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
		[content addSubview:button];
		return button;
	};
	NSTextField *heading = [NSTextField labelWithString:@"General Information"];
	heading.frame = NSMakeRect(0, 298, 378, 17);
	heading.font = [NSFont boldSystemFontOfSize:11];
	heading.alignment = NSTextAlignmentCenter;
	heading.textColor = NSColor.blackColor;
	[content addSubview:heading];

	addLabel(@"Tracks:", NSMakeRect(12, 269, 88, 17));
	self.generalTracksPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(105, 264, 66, 24) pullsDown:NO];
	self.generalTracksPopup.font = font;
	self.generalTracksPopup.controlSize = NSControlSizeSmall;
	for (NSInteger tracks = 2; tracks <= MIN(MAXTRACK, UINT8_MAX - 1); tracks += 2) {
		[self.generalTracksPopup addItemWithTitle:[NSString stringWithFormat:@"%ld", (long)tracks]];
	}
	NSInteger displayedTracks = MIN(MAX((NSInteger)_music->header->numChn, 2), MIN(MAXTRACK, UINT8_MAX - 1));
	displayedTracks -= displayedTracks % 2;
	[self.generalTracksPopup selectItemWithTitle:[NSString stringWithFormat:@"%ld", (long)displayedTracks]];
	[content addSubview:self.generalTracksPopup];

	addLabel(@"Internal Name:", NSMakeRect(12, 241, 88, 17));
	self.generalNameField = addField([self stringFromLegacyBytes:_music->header->name
		length:sizeof(_music->header->name) fallback:@""], NSMakeRect(105, 237, 185, 22));
	self.generalNameField.maximumNumberOfLines = 1;

	addLabel(@"Default tempo:", NSMakeRect(12, 215, 88, 17));
	self.generalTempoField = addField([NSString stringWithFormat:@"%d", _music->header->tempo], NSMakeRect(105, 211, 68, 22));
	NSTextField *bpmLabel = addLabel(@"BPM", NSMakeRect(178, 215, 40, 17));
	bpmLabel.alignment = NSTextAlignmentLeft;

	addLabel(@"Default speed:", NSMakeRect(12, 189, 88, 17));
	self.generalSpeedField = addField([NSString stringWithFormat:@"%d", _music->header->speed], NSMakeRect(105, 185, 68, 22));
	NSTextField *speedLabel = addLabel(@"Timing pulses per line", NSMakeRect(178, 189, 128, 17));
	speedLabel.alignment = NSTextAlignmentLeft;

	addLabel(@"Copyright Text:", NSMakeRect(12, 164, 88, 17));
	NSScrollView *copyrightScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(105, 121, 185, 61)];
	copyrightScroll.borderType = NSBezelBorder;
	copyrightScroll.hasVerticalScroller = YES;
	copyrightScroll.autohidesScrollers = YES;
	NSTextView *copyrightView = [[NSTextView alloc] initWithFrame:copyrightScroll.contentView.bounds];
	copyrightView.font = font;
	copyrightView.textColor = NSColor.blackColor;
	copyrightView.backgroundColor = NSColor.whiteColor;
	copyrightView.insertionPointColor = NSColor.blackColor;
	copyrightView.string = [self stringFromLegacyBytes:_music->header->infos
		length:sizeof(_music->header->infos) fallback:@""];
	copyrightView.minSize = NSMakeSize(0, NSHeight(copyrightScroll.contentView.bounds));
	copyrightView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
	copyrightView.verticallyResizable = YES;
	copyrightView.horizontallyResizable = NO;
	copyrightView.textContainer.widthTracksTextView = YES;
	copyrightScroll.documentView = copyrightView;
	self.generalCopyrightTextView = copyrightView;
	[content addSubview:copyrightScroll];

	self.generalShowCopyrightButton = addCheck(@"Show Copyright when opening", 97, _music->header->showCopyright);
	self.generalMODModeButton = addCheck(@"Old MODs pitch table", 76, _music->header->MODMode);
	self.generalLinearTableButton = addCheck(@"Linear Table", 55, _music->header->XMLinear);
	self.generalMultiChannelButton = addCheck(@"Multi-Channel Tracks", 34, _music->header->MultiChan);
	self.generalMODModeButton.toolTip = @"Use the original MOD pitch limits and period behavior";
	self.generalLinearTableButton.toolTip = @"Use the XM linear frequency table";
	self.generalMultiChannelButton.toolTip = @"Allow multiple voices to be mixed for each pattern track";

	NSTextField *mixLabel = addLabel(@"Max mixing channels:", NSMakeRect(106, 11, 130, 17));
	mixLabel.alignment = NSTextAlignmentLeft;
	self.generalMixChannelsPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(248, 6, 62, 24) pullsDown:NO];
	self.generalMixChannelsPopup.font = font;
	self.generalMixChannelsPopup.controlSize = NSControlSizeSmall;
	for (NSInteger channels = 4; channels <= 98; channels += 2) {
		[self.generalMixChannelsPopup addItemWithTitle:[NSString stringWithFormat:@"%ld", (long)channels]];
	}
	NSInteger mixChannels = _music->header->MultiChanNo;
	if (mixChannels < 4 || mixChannels > 99) mixChannels = 48;
	mixChannels = MIN(MAX(mixChannels - (mixChannels % 2), 4), 98);
	[self.generalMixChannelsPopup selectItemWithTitle:[NSString stringWithFormat:@"%ld", (long)mixChannels]];
	[content addSubview:self.generalMixChannelsPopup];

	NSButton *okButton = [NSButton buttonWithTitle:@"OK" target:self action:@selector(confirmMusicInformation:)];
	okButton.frame = NSMakeRect(302, 252, 64, 28);
	okButton.font = font;
	okButton.bezelStyle = NSBezelStyleRounded;
	okButton.keyEquivalent = @"\r";
	[content addSubview:okButton];
	NSButton *cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelMusicInformation:)];
	cancelButton.frame = NSMakeRect(302, 217, 64, 28);
	cancelButton.font = font;
	cancelButton.bezelStyle = NSBezelStyleRounded;
	cancelButton.keyEquivalent = @"\e";
	[content addSubview:cancelButton];

	PPForceClassicLightAppearanceOnWindow(panel);
	panel.initialFirstResponder = self.generalNameField;
	[self.window beginSheet:panel completionHandler:nil];
}

- (IBAction)cancelMusicInformation:(id)sender
{
	(void)sender;
	if (self.generalInformationPanel.sheetParent != nil) {
		[self.generalInformationPanel.sheetParent endSheet:self.generalInformationPanel returnCode:NSModalResponseCancel];
	} else {
		[self.generalInformationPanel orderOut:nil];
	}
}

- (BOOL)resizePatternsFromTrackCount:(NSInteger)oldCount toTrackCount:(NSInteger)newCount
{
	if (_music == NULL || _music->header == NULL || oldCount == newCount) return YES;
	PatData *replacements[MAXPATTERN] = { NULL };
	for (NSInteger index = 0; index < _music->header->numPat; index++) {
		PatData *source = _music->partition[index];
		if (source == NULL || source->header.size <= 0) continue;
		NSUInteger rows = (NSUInteger)source->header.size;
		if (rows > (NSUInteger)(SIZE_MAX / (NSUInteger)newCount) ||
			rows * (NSUInteger)newCount > (SIZE_MAX - sizeof(PatHeader)) / sizeof(Cmd)) {
			for (NSInteger allocated = 0; allocated < index; allocated++) free(replacements[allocated]);
			return NO;
		}
		NSUInteger byteCount = sizeof(PatHeader) + rows * (NSUInteger)newCount * sizeof(Cmd);
		PatData *replacement = calloc(1, byteCount);
		if (replacement == NULL) {
			for (NSInteger allocated = 0; allocated < index; allocated++) free(replacements[allocated]);
			return NO;
		}
		replacement->header = source->header;
		replacement->header.patBytes = 0;
		for (NSInteger channel = 0; channel < newCount; channel++) {
			for (NSInteger row = 0; row < source->header.size; row++) {
				MADKillCmd(GetMADCommand((short)row, (short)channel, replacement));
			}
		}
		for (NSInteger channel = 0; channel < MIN(oldCount, newCount); channel++) {
			for (NSInteger row = 0; row < source->header.size; row++) {
				*GetMADCommand((short)row, (short)channel, replacement) =
					*GetMADCommand((short)row, (short)channel, source);
			}
		}
		replacements[index] = replacement;
	}
	for (NSInteger index = 0; index < _music->header->numPat; index++) {
		if (_music->partition[index] == NULL || _music->partition[index]->header.size <= 0) continue;
		free(_music->partition[index]);
		_music->partition[index] = replacements[index];
	}
	if (newCount > oldCount) {
		for (NSInteger channel = oldCount; channel < newCount; channel++) {
			_music->header->chanPan[channel] = MAX_PANNING / 2;
			_music->header->chanVol[channel] = MAX_VOLUME;
		}
	}
	return YES;
}

- (IBAction)confirmMusicInformation:(id)sender
{
	(void)sender;
	if (_music == NULL || _music->header == NULL) { [self cancelMusicInformation:nil]; return; }
	BOOL (^parseInteger)(NSTextField *, NSInteger *) = ^BOOL(NSTextField *field, NSInteger *value) {
		NSString *text = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		if (text.length == 0) return NO;
		NSScanner *scanner = [NSScanner scannerWithString:text];
		scanner.charactersToBeSkipped = nil;
		return [scanner scanInteger:value] && scanner.isAtEnd;
	};
	NSInteger tempo = 0;
	if (!parseInteger(self.generalTempoField, &tempo) || tempo < 1 || tempo >= 500) {
		NSBeep(); self.statusField.stringValue = @"Default tempo must be between 1 and 499 BPM";
		[self.generalInformationPanel makeFirstResponder:self.generalTempoField];
		[self.generalTempoField selectText:nil];
		return;
	}
	NSInteger speed = 0;
	if (!parseInteger(self.generalSpeedField, &speed) || speed < 1 || speed >= 15) {
		NSBeep(); self.statusField.stringValue = @"Default speed must be between 1 and 14 timing pulses";
		[self.generalInformationPanel makeFirstResponder:self.generalSpeedField];
		[self.generalSpeedField selectText:nil];
		return;
	}
	NSInteger oldTracks = _music->header->numChn;
	NSInteger newTracks = self.generalTracksPopup.titleOfSelectedItem.integerValue;
	NSInteger mixChannels = self.generalMixChannelsPopup.titleOfSelectedItem.integerValue;
	PPPatternCollectionSnapshot *snapshot = [self capturePatternCollectionSnapshot];
	BOOL wasPlaying = [self stopForPatternStructureChange];
	if (![self resizePatternsFromTrackCount:oldTracks toTrackCount:newTracks]) {
		_music->musicUnderModification = false;
		if (wasPlaying && _driver != NULL) MADPlayMusic(_driver);
		NSBeep(); self.statusField.stringValue = @"Not enough memory to change the track count";
		return;
	}

	_music->header->numChn = (MADByte)newTracks;
	_music->header->tempo = (short)tempo;
	_music->header->speed = (short)speed;
	_music->header->showCopyright = self.generalShowCopyrightButton.state == NSControlStateValueOn;
	_music->header->MODMode = self.generalMODModeButton.state == NSControlStateValueOn;
	_music->header->XMLinear = self.generalLinearTableButton.state == NSControlStateValueOn;
	_music->header->MultiChan = self.generalMultiChannelButton.state == NSControlStateValueOn;
	_music->header->MultiChanNo = (MADByte)mixChannels;
	[self copyString:self.generalNameField.stringValue toLegacyBuffer:_music->header->name
		length:sizeof(_music->header->name)];
	[self copyString:self.generalCopyrightTextView.string toLegacyBuffer:_music->header->infos
		length:sizeof(_music->header->infos)];
	self.titleField.stringValue = self.generalNameField.stringValue;
	[self registerPatternCollectionUndoSnapshot:snapshot actionName:@"General Information"];
	[self finishPatternStructureChangeSelecting:_selectedPattern wasPlaying:wasPlaying
		status:[NSString stringWithFormat:@"General information updated • %ld tracks • %ld BPM / speed %ld",
			(long)newTracks, (long)tempo, (long)speed]];
	[self updateToolsTitle];
	[self cancelMusicInformation:nil];
}

- (Cmd *)selectedEditorCommand
{
	if (_music == NULL || _music->header == NULL) {
		return NULL;
	}
	NSInteger row = self.patternCursorRow;
	NSInteger column = self.patternCursorChannel;
	if (row < 0 || column < 0 || column >= (NSInteger)_music->header->numChn) {
		return NULL;
	}
	return GetMADCommand((short)row, (short)column, [self selectedPatternData]);
}

- (void)transposeSelectedNoteBy:(NSInteger)delta
{
	NSInteger top, bottom, left, right;
	if (![self getPatternSelectionTop:&top bottom:&bottom left:&left right:&right]) { NSBeep(); return; }
	PPPatternSnapshot *snapshot = [self capturePatternSnapshot:_selectedPattern];
	BOOL changed = NO;
	for (NSInteger channel = left; channel <= right; channel++) {
		for (NSInteger row = top; row <= bottom; row++) {
			Cmd *command = GetMADCommand((short)row, (short)channel, [self selectedPatternData]);
			if (command->note == 0xFF || command->note >= NUMBER_NOTES) continue;
			NSInteger note = MIN(MAX((NSInteger)command->note + delta, 0), NUMBER_NOTES - 1);
			if (note != command->note) { command->note = (MADByte)note; changed = YES; }
		}
	}
	if (!changed) { NSBeep(); return; }
	[self registerPatternUndoSnapshot:snapshot actionName:delta > 0 ? @"Transpose Pattern Up" : @"Transpose Pattern Down"];
	_music->hasChanged = true;
	[self.patternTable reloadData];
}

- (IBAction)transposeNoteUp:(id)sender
{
	(void)sender;
	[self transposeSelectedNoteBy:1];
}

- (IBAction)transposeNoteDown:(id)sender
{
	(void)sender;
	[self transposeSelectedNoteBy:-1];
}

- (IBAction)findCommand:(id)sender
{
	(void)sender;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Find";
	alert.informativeText = @"Find tracker text (for example C-4, 001, or F 06):";
	[alert addButtonWithTitle:@"Find"];
	[alert addButtonWithTitle:@"Done"];
	NSTextField *queryField = [NSTextField textFieldWithString:@""];
	queryField.frame = NSMakeRect(0, 0, 260, 22);
	queryField.font = [self classicFont];
	alert.accessoryView = queryField;
	[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
		if (result != NSAlertFirstButtonReturn || queryField.stringValue.length == 0) {
			return;
		}
		NSString *query = queryField.stringValue.uppercaseString;
		PatData *pattern = [self selectedPatternData];
		NSInteger rows = pattern == NULL ? 0 : pattern->header.size;
		NSInteger channels = self->_music == NULL ? 0 : self->_music->header->numChn;
		if (rows <= 0 || channels <= 0) {
			return;
		}
		NSInteger startRow = MAX(self.patternCursorRow, 0);
		NSInteger startChannel = MAX(self.patternCursorChannel, 0);
		for (NSInteger offset = 1; offset <= rows * channels; offset++) {
			NSInteger flat = (startRow * channels + startChannel + offset) % (rows * channels);
			NSInteger row = flat / channels;
			NSInteger channel = flat % channels;
			Cmd *command = GetMADCommand((short)row, (short)channel, pattern);
			if ([[self stringForCommand:command].uppercaseString containsString:query]) {
				[self selectPatternTop:row bottom:row left:channel right:channel];
				self.statusField.stringValue = [NSString stringWithFormat:@"Found %@ at row %03ld, track %02ld",
					query, (long)row + 1, (long)channel + 1];
				return;
			}
		}
		NSBeep();
	}];
}

- (IBAction)findCurrentNote:(id)sender
{
	(void)sender;
	Cmd *current = [self selectedEditorCommand];
	if (current == NULL || current->note == 0xFF || current->note >= NUMBER_NOTES) {
		NSBeep();
		self.statusField.stringValue = @"The active Digital command does not contain a note";
		return;
	}
	MADByte wantedNote = current->note;
	PatData *pattern = [self selectedPatternData];
	NSInteger rows = pattern == NULL ? 0 : pattern->header.size;
	NSInteger channels = _music == NULL ? 0 : _music->header->numChn;
	if (rows <= 0 || channels <= 0) return;
	NSInteger start = MIN(MAX(self.patternCursorRow, 0), rows - 1) * channels +
		MIN(MAX(self.patternCursorChannel, 0), channels - 1);
	for (NSInteger offset = 1; offset < rows * channels; offset++) {
		NSInteger flat = (start + offset) % (rows * channels);
		NSInteger row = flat / channels;
		NSInteger channel = flat % channels;
		Cmd *candidate = GetMADCommand((short)row, (short)channel, pattern);
		if (candidate != NULL && candidate->note == wantedNote) {
			[self selectPatternTop:row bottom:row left:channel right:channel];
			self.statusField.stringValue = [NSString stringWithFormat:@"Found current note at row %03ld, track %02ld",
				(long)row + 1, (long)channel + 1];
			return;
		}
	}
	NSBeep();
	self.statusField.stringValue = @"No other occurrence of the current note in this pattern";
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(showMusicList:)) {
		menuItem.state = self.musicListWindow.isVisible ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (menuItem.action == @selector(focusInstruments:)) {
		menuItem.state = self.instrumentsWindow.isVisible ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (menuItem.action == @selector(saveMusicList:) || menuItem.action == @selector(clearMusicList:)) {
		return self.musicListEntries.count > 0;
	}
	if (menuItem.action == @selector(exportSelectedSample:) || menuItem.action == @selector(openSelectedSample:)) {
		return [self selectedSampleData] != NULL;
	}
	if (menuItem.action == @selector(duplicateSelectedSample:)) {
		if ([self selectedSampleData] == NULL || _music == NULL) return NO;
		NSInteger instrument = _selectedInstrument;
		return instrument >= 0 && instrument < MAXINSTRU &&
			_music->fid[instrument].numSamples < MAXSAMPLE;
	}
	if (menuItem.action == @selector(duplicateSelectedInstrument:)) {
		if (_music == NULL || _music->header == NULL ||
			_selectedInstrument < 0 || _selectedInstrument >= MAXINSTRU) return NO;
		InstrData *source = &_music->fid[_selectedInstrument];
		if ((source->name[0] == 0 && source->numSamples == 0) ||
			(NSInteger)_music->header->numSamples + source->numSamples > UINT8_MAX) return NO;
		for (NSInteger candidate = 0; candidate < MAXINSTRU; candidate++) {
			if (candidate != _selectedInstrument && _music->fid[candidate].name[0] == 0 &&
				_music->fid[candidate].numSamples == 0) return YES;
		}
		return NO;
	}
	if (menuItem.action == @selector(deleteSelectedInstrumentOrSample:) ||
		menuItem.action == @selector(openSelectedInstrumentInfo:) ||
		menuItem.action == @selector(loadSample:) || menuItem.action == @selector(importRawSample:) ||
		menuItem.action == @selector(createSilentSample:)) {
		return _music != NULL;
	}
	if (menuItem.action == @selector(saveDocument:) || menuItem.action == @selector(saveDocumentAs:) ||
		menuItem.action == @selector(exportDocument:)) {
		return _music != NULL;
	}
	return YES;
}

- (NSString *)stringFromLegacyBytes:(const char *)bytes length:(size_t)length fallback:(NSString *)fallback
{
	size_t count = strnlen(bytes, length);
	if (count == 0) {
		return fallback;
	}
	NSString *string = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
	if (string == nil) {
		string = [[NSString alloc] initWithBytes:bytes length:count encoding:NSMacOSRomanStringEncoding];
	}
	return string ?: fallback;
}

- (void)copyString:(NSString *)string toLegacyBuffer:(char *)buffer length:(size_t)length
{
	memset(buffer, 0, length);
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
	if (data.length >= length) {
		data = [data subdataWithRange:NSMakeRange(0, length - 1)];
	}
	memcpy(buffer, data.bytes, data.length);
}

- (NSString *)formattedTime:(long)ticks
{
	long seconds = MAX(ticks / 60, 0);
	return [NSString stringWithFormat:@"%02ld:%02ld", seconds / 60, seconds % 60];
}

- (void)presentErrorCode:(MADErr)error operation:(NSString *)operation
{
	NSAlert *alert = [[NSAlert alloc] init];
	alert.alertStyle = NSAlertStyleCritical;
	alert.messageText = [NSString stringWithFormat:@"PlayerPRO could not finish %@.", operation];
	alert.informativeText = [NSString stringWithFormat:@"PlayerPRO error %d", error];
	if (self.window != nil) {
		[alert beginSheetModalForWindow:self.window completionHandler:nil];
	} else {
		[alert runModal];
	}
}

@end
