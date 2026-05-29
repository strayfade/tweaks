#import <Foundation/Foundation.h>

@class SCConnection;

@protocol SCConnectionDelegate <NSObject>
- (void)connection:(SCConnection *)connection didReceiveMessage:(NSDictionary *)message;
- (void)connectionDidClose:(SCConnection *)connection;
@end

@interface SCConnection : NSObject

@property (nonatomic, weak) id<SCConnectionDelegate> delegate;
@property (nonatomic, copy, readonly) NSString *peerIdentifier;
@property (nonatomic, copy, readonly) NSString *peerPlatform;

- (instancetype)initWithSocketFD:(int)socketFD queue:(dispatch_queue_t)queue;
- (instancetype)initWithResolvedService:(NSNetService *)service queue:(dispatch_queue_t)queue;
- (void)close;
- (void)sendMessage:(NSDictionary *)message;

@end
