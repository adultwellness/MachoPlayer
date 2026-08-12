#import "PPPatternCommandCodec.h"
#import "PPPreferences.h"

static NSString *PPTrimmedField(NSString *value)
{
	return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
}

static BOOL PPScanDecimal(NSString *value, NSInteger *result)
{
	if (value.length == 0) return NO;
	NSScanner *scanner = [NSScanner scannerWithString:value];
	scanner.charactersToBeSkipped = nil;
	return [scanner scanInteger:result] && scanner.isAtEnd;
}

static BOOL PPScanHex(NSString *value, NSUInteger length, unsigned int *result)
{
	if (value.length != length) return NO;
	NSScanner *scanner = [NSScanner scannerWithString:value];
	scanner.charactersToBeSkipped = nil;
	return [scanner scanHexInt:result] && scanner.isAtEnd;
}

NSString *PPPatternEffectCharacter(MADEffectID effect)
{
	if (effect <= MADEffectSpeed) return [NSString stringWithFormat:@"%X", (unsigned int)effect];
	switch (effect) {
		case MADEffectNoteOff: return @"G";
		case MADEffectLoop: return @"L";
		case MADEffectNOffset: return @"O";
		default: return @"?";
	}
}

NSArray<NSString *> *PPPatternEffectMenuTitles(void)
{
	static NSArray<NSString *> *titles;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		titles = @[
			@"0-Normal/Arpeggio", @"1-Slide Up", @"2-Slide Down", @"3-Portamento",
			@"4-Vibrato", @"5-Portamento+Vol Slide", @"6-Vibrato+Vol Slide", @"7-Tremolo",
			@"8-Set Panning", @"9-Set Sample Offset", @"A-VolumeSlide", @"B-Position Jump",
			@"C-Set Volume", @"D-Pattern Break", @"E-E Commands", @"F-Set Speed",
			@"G-Note Off (Multi-Channel Tracks)", @"L-Move Loop", @"O-Set Sample Offset in %"
		];
	});
	return titles;
}

NSArray<NSString *> *PPTrackerKeyboardKeys(void)
{
	NSMutableArray<NSString *> *keys = [NSMutableArray array];
	for (NSString *key in PPDefaultPianoKeyMap()) {
		if (key.length > 0) [keys addObject:key];
	}
	return keys.copy;
}

NSDictionary<NSNumber *, NSString *> *PPTrackerKeyboardLabels(NSInteger octaveOffset)
{
	NSArray<NSString *> *mapping = PPPreferredPianoKeyMap();
	NSMutableDictionary<NSNumber *, NSString *> *labels = [NSMutableDictionary dictionaryWithCapacity:mapping.count];
	for (NSInteger baseNote = 0; baseNote < (NSInteger)mapping.count; baseNote++) {
		NSString *key = mapping[(NSUInteger)baseNote];
		NSInteger note = baseNote + octaveOffset * 12;
		if (key.length > 0 && note >= 0 && note < NUMBER_NOTES) labels[@(note)] = key;
	}
	return labels.copy;
}

static NSInteger PPTrackerKeyboardBaseNoteForKeyInMap(NSString *key, NSArray<NSString *> *mapping)
{
	if (key.length != 1) return NSNotFound;
	NSUInteger index = [mapping indexOfObject:key];
	return index == NSNotFound ? NSNotFound : (NSInteger)index;
}

NSInteger PPTrackerKeyboardBaseNoteForKey(NSString *key)
{
	return PPTrackerKeyboardBaseNoteForKeyInMap(key, PPPreferredPianoKeyMap());
}

NSInteger PPTrackerKeyboardNoteForKey(NSString *key, NSInteger octaveOffset)
{
	NSInteger baseNote = PPTrackerKeyboardBaseNoteForKey(key);
	if (baseNote == NSNotFound) return NSNotFound;
	NSInteger note = baseNote + octaveOffset * 12;
	return note >= 0 && note < NUMBER_NOTES ? note : NSNotFound;
}

NSString *PPPatternStringForCommand(const Cmd *command)
{
	if (command == NULL) return @"               ";
	NSString *note = @"   ";
	if (command->note == 0xFE) {
		note = @"OFF";
	} else if (command->note != 0xFF && command->note < NUMBER_NOTES) {
		static NSArray<NSString *> *notes;
		static dispatch_once_t onceToken;
		dispatch_once(&onceToken, ^{
			notes = @[@"C-", @"C#", @"D-", @"D#", @"E-", @"F-", @"F#", @"G-", @"G#", @"A-", @"A#", @"B-"];
		});
		note = [NSString stringWithFormat:@"%@%u", notes[command->note % 12], command->note / 12];
	}
	NSString *instrument = command->ins == 0 ? @"   " : [NSString stringWithFormat:@"%03u", command->ins];
	NSString *effect = command->cmd == 0 && command->arg == 0 ? @" " : PPPatternEffectCharacter(command->cmd);
	NSString *argument = command->arg == 0 ? @"  " : [NSString stringWithFormat:@"%02X", command->arg];
	NSString *volume = command->vol == 0xFF ? @"  " : [NSString stringWithFormat:@"%02X", command->vol];
	return [NSString stringWithFormat:@"%@ %@ %@ %@ %@", instrument, note, effect, argument, volume];
}

static BOOL PPPatternFields(NSString *input, NSArray<NSString *> **fields)
{
	if (PPTrimmedField(input).length == 0) {
		*fields = @[@"", @"", @"", @"", @""];
		return YES;
	}
	if (input.length >= 15) {
		NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
		BOOL fixed = [spaces characterIsMember:[input characterAtIndex:3]] &&
			[spaces characterIsMember:[input characterAtIndex:7]] &&
			[spaces characterIsMember:[input characterAtIndex:9]] &&
			[spaces characterIsMember:[input characterAtIndex:12]];
		if (fixed) {
			*fields = @[[input substringWithRange:NSMakeRange(0, 3)],
				[input substringWithRange:NSMakeRange(4, 3)], [input substringWithRange:NSMakeRange(8, 1)],
				[input substringWithRange:NSMakeRange(10, 2)], [input substringWithRange:NSMakeRange(13, 2)]];
			return YES;
		}
	}
	NSArray<NSString *> *raw = [input.uppercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:5];
	for (NSString *token in raw) if (token.length > 0) [tokens addObject:token];
	if (tokens.count != 5) return NO;
	*fields = tokens;
	return YES;
}

static BOOL PPPatternParseNote(NSString *field, MADByte *note)
{
	field = PPTrimmedField(field);
	if (field.length == 0 || [field isEqualToString:@"---"] || [field isEqualToString:@"..."]) {
		*note = 0xFF;
		return YES;
	}
	if ([field isEqualToString:@"OFF"]) {
		*note = 0xFE;
		return YES;
	}
	if (field.length != 3) return NO;
	static NSDictionary<NSString *, NSNumber *> *noteValues;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		noteValues = @{@"C-": @0, @"C#": @1, @"D-": @2, @"D#": @3, @"E-": @4, @"F-": @5,
			@"F#": @6, @"G-": @7, @"G#": @8, @"A-": @9, @"A#": @10, @"B-": @11};
	});
	NSNumber *base = noteValues[[field substringToIndex:2]];
	NSInteger octave = -1;
	if (base == nil || !PPScanDecimal([field substringFromIndex:2], &octave)) return NO;
	NSInteger value = octave * 12 + base.integerValue;
	if (octave < 0 || value < 0 || value >= NUMBER_NOTES) return NO;
	*note = (MADByte)value;
	return YES;
}

static BOOL PPPatternParseEffect(NSString *field, MADEffectID *effect)
{
	field = PPTrimmedField(field);
	if (field.length == 0 || [field isEqualToString:@"-"] || [field isEqualToString:@"."]) {
		*effect = MADEffectArpeggio;
		return YES;
	}
	if (field.length != 1) return NO;
	unichar character = [field characterAtIndex:0];
	if (character >= '0' && character <= '9') *effect = (MADEffectID)(character - '0');
	else if (character >= 'A' && character <= 'F') *effect = (MADEffectID)(10 + character - 'A');
	else if (character == 'G') *effect = MADEffectNoteOff;
	else if (character == 'L') *effect = MADEffectLoop;
	else if (character == 'O') *effect = MADEffectNOffset;
	else return NO;
	return YES;
}

BOOL PPPatternParseCommandString(NSString *input, Cmd *command)
{
	if (command == NULL) return NO;
	NSArray<NSString *> *fields;
	if (!PPPatternFields(input, &fields)) return NO;

	NSString *instrumentField = PPTrimmedField(fields[0]);
	NSInteger instrument = 0;
	if (instrumentField.length != 0 && ![instrumentField isEqualToString:@"---"] && ![instrumentField isEqualToString:@"..."]) {
		if (instrumentField.length != 3 || !PPScanDecimal(instrumentField, &instrument) || instrument < 0 || instrument > 255) return NO;
	}
	MADByte note;
	if (!PPPatternParseNote(fields[1], &note)) return NO;
	MADEffectID effect;
	if (!PPPatternParseEffect(fields[2], &effect)) return NO;

	NSString *argumentField = PPTrimmedField(fields[3]);
	unsigned int argument = 0;
	if (argumentField.length != 0 && ![argumentField isEqualToString:@"--"] && ![argumentField isEqualToString:@".."]) {
		if (!PPScanHex(argumentField, 2, &argument)) return NO;
	}
	NSString *volumeField = PPTrimmedField(fields[4]);
	unsigned int volume = 0xFF;
	if (volumeField.length != 0 && ![volumeField isEqualToString:@"--"] && ![volumeField isEqualToString:@".."]) {
		if (!PPScanHex(volumeField, 2, &volume)) return NO;
	}

	*command = (Cmd){(MADByte)instrument, note, effect, (MADByte)argument, (MADByte)volume, 0};
	return YES;
}

BOOL PPPatternRunCommandCodecSelfTest(void)
{
	const Cmd commands[] = {
		{0, 0xFF, MADEffectArpeggio, 0, 0xFF, 0},
		{1, 48, MADEffectSpeed, 0x06, 0x40, 0},
		{2, 0xFE, MADEffectNoteOff, 0, 0xFF, 0},
		{3, 52, MADEffectLoop, 0x03, 0x20, 0},
		{4, 55, MADEffectNOffset, 0x12, 0x30, 0}
	};
	for (NSUInteger index = 0; index < sizeof(commands) / sizeof(commands[0]); index++) {
		NSString *text = PPPatternStringForCommand(&commands[index]);
		Cmd parsed = {0};
		if (!PPPatternParseCommandString(text, &parsed) || memcmp(&commands[index], &parsed, sizeof(Cmd)) != 0) return NO;
	}
	Cmd explicit = {0};
	return PPPatternParseCommandString(@"005 OFF O 7F --", &explicit) && explicit.ins == 5 &&
		explicit.note == 0xFE && explicit.cmd == MADEffectNOffset && explicit.arg == 0x7F && explicit.vol == 0xFF &&
		PPPatternEffectMenuTitles().count == 19 &&
		[PPPatternEffectMenuTitles()[0] isEqualToString:@"0-Normal/Arpeggio"] &&
		[PPPatternEffectMenuTitles()[18] isEqualToString:@"O-Set Sample Offset in %"] &&
		PPTrackerKeyboardKeys().count == 62 && PPDefaultPianoKeyMap().count == NUMBER_NOTES &&
		PPTrackerKeyboardBaseNoteForKeyInMap(@"1", PPDefaultPianoKeyMap()) == 24 &&
		PPTrackerKeyboardBaseNoteForKeyInMap(@"q", PPDefaultPianoKeyMap()) == 34 &&
		PPTrackerKeyboardBaseNoteForKeyInMap(@"g", PPDefaultPianoKeyMap()) == 48 &&
		PPTrackerKeyboardBaseNoteForKeyInMap(@"Q", PPDefaultPianoKeyMap()) == 60 &&
		PPTrackerKeyboardBaseNoteForKeyInMap(@"M", PPDefaultPianoKeyMap()) == 85 &&
		PPTrackerKeyboardBaseNoteForKeyInMap(@"?", PPDefaultPianoKeyMap()) == NSNotFound;
}
