#import <Foundation/Foundation.h>
#import <substrate.h>

// Suppress only the legacy "pasted" banner (NoPasteAlerts16). Do not touch "would like to
// copy" alerts here — programmatic button activation can deadlock SpringBoard.

@interface SBUserNotificationAlert : NSObject
- (void)_setActivated:(BOOL)activated;
- (void)_sendResponseAndCleanUp:(BOOL)cleanup;
@end

%hook SBAlertItem

+ (void)activateAlertItem:(id)alertItem {
    Class alertClass = objc_getClass("SBUserNotificationAlert");
    if (alertClass && [alertItem isKindOfClass:alertClass]) {
        NSString *source = @"";
        @try {
            source = MSHookIvar<NSString *>(alertItem, "_alertSource") ?: @"";
        } @catch (__unused NSException *exception) {
        }
        if ([source isEqualToString:@"pasted"]) {
            [alertItem _setActivated:NO];
            if ([alertItem respondsToSelector:@selector(_sendResponseAndCleanUp:)]) {
                [alertItem _sendResponseAndCleanUp:YES];
            }
            return;
        }
    }
    %orig;
}

%end
