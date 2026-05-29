#import "SCPasteboard.h"
#import "SCSyncEngine.h"

%ctor {
    @autoreleasepool {
        @try {
            scInstallPasteboardPrivacyHooks();
            [[SCSyncEngine sharedEngine] startIfNeeded];
            %init;
        } @catch (NSException *exception) {
            NSLog(@"[ShareClipboard] Failed to initialize: %@", exception);
        }
    }
}
