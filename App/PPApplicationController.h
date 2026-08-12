#import <Cocoa/Cocoa.h>

@interface PPApplicationController : NSObject <NSApplicationDelegate,
	NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation>
@end

/// Exercises headerless PCM conversion used by the restored RAW sample importer.
FOUNDATION_EXPORT BOOL PPApplicationRunSampleWorkflowSelfTest(void);

/// Exercises original-compatible standalone PATN pattern serialization.
FOUNDATION_EXPORT BOOL PPApplicationRunPatternFileSelfTest(void);
