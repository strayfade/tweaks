#import <Foundation/Foundation.h>

@interface SCSyncEngine : NSObject

+ (instancetype)sharedEngine;
- (void)startIfNeeded;
- (void)stop;
- (void)handlePreferenceChange;

@end
