#import <Foundation/Foundation.h>

#include "PlayerPROCore.h"

NS_ASSUME_NONNULL_BEGIN

/// Formats a command in PlayerPRO 5.9.6's five-field Digital notation.
FOUNDATION_EXPORT NSString *PPPatternStringForCommand(const Cmd * _Nullable command);

/// Parses fixed-width original notation or five explicit fields. Empty fields
/// may be written as 000, ---, ., 00, and -- respectively.
FOUNDATION_EXPORT BOOL PPPatternParseCommandString(NSString *input, Cmd *command);

/// The single-character identifiers used by the original Digital editor.
FOUNDATION_EXPORT NSString *PPPatternEffectCharacter(MADEffectID effect);
FOUNDATION_EXPORT NSArray<NSString *> *PPPatternEffectMenuTitles(void);

/// PlayerPRO's canonical tracker keyboard and the user's editable note map.
/// Both the Digital and Piano editors use these helpers so their displayed
/// labels and entered notes always stay in lockstep.
FOUNDATION_EXPORT NSArray<NSString *> *PPTrackerKeyboardKeys(void);
FOUNDATION_EXPORT NSDictionary<NSNumber *, NSString *> *PPTrackerKeyboardLabels(NSInteger octaveOffset);
FOUNDATION_EXPORT NSInteger PPTrackerKeyboardBaseNoteForKey(NSString *key);
FOUNDATION_EXPORT NSInteger PPTrackerKeyboardNoteForKey(NSString *key, NSInteger octaveOffset);

/// Exercises blank fields, OFF, hexadecimal effects, and G/L/O round trips.
FOUNDATION_EXPORT BOOL PPPatternRunCommandCodecSelfTest(void);

NS_ASSUME_NONNULL_END
