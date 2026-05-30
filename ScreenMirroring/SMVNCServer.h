#import <Foundation/Foundation.h>

@class SMVNCConnection;

@interface SMVNCServer : NSObject
+ (instancetype)sharedServer;
- (void)handleBootstrap;
- (void)handlePreferenceChange;
- (void)clientConnected:(SMVNCConnection *)connection;
- (void)notifyClientDisconnected:(SMVNCConnection *)connection;
@end
