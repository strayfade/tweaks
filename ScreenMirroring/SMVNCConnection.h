#import <Foundation/Foundation.h>

@class SMVNCServer;

@interface SMVNCConnection : NSObject
@property (nonatomic, weak) SMVNCServer *server;
@property (nonatomic, assign, readonly) int socketFD;
@property (nonatomic, assign, readonly) BOOL authenticated;

- (instancetype)initWithSocketFD:(int)socketFD server:(SMVNCServer *)server queue:(dispatch_queue_t)queue;
- (void)start;
- (void)close;
- (void)closeImmediately;
@end
