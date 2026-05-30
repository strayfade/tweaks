#import "SMVNCServer.h"
#import "SMCommon.h"
#import "SMVNCConnection.h"
#import "SMScreenCapture.h"
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

// iOS 14+ API; not always declared in Theos SDK headers.
@interface NSNetService (SMScreenMirroringPublish)
- (void)publishWithOptions:(NSUInteger)options includingPeerToPeer:(BOOL)includePeerToPeer;
@end

@interface SMVNCServer () <NSNetServiceDelegate>
- (void)clientDisconnectedLocked:(SMVNCConnection *)connection;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *publishedServices;
@property (nonatomic, strong) NSMutableArray<SMVNCConnection *> *connections;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) uint64_t reloadGeneration;
@end

@implementation SMVNCServer

+ (instancetype)sharedServer {
    static SMVNCServer *server = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        server = [[SMVNCServer alloc] init];
    });
    return server;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _queue = dispatch_queue_create("com.strayfade.screenmirroring.server", DISPATCH_QUEUE_SERIAL);
    _connections = [NSMutableArray array];
    _publishedServices = [NSMutableArray array];
    _listenSocket = -1;
    return self;
}

- (void)handleBootstrap {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                      (__bridge const void *)self,
                                      smPreferenceChangedCallback,
                                      CFSTR("com.strayfade.screenmirroring~prefs/preferencesChanged"),
                                      NULL,
                                      CFNotificationSuspensionBehaviorCoalesce);

        dispatch_async(dispatch_get_main_queue(), ^{
            [[SMScreenCapture sharedCapture] prepareOnMainThread];
        });

        dispatch_async(self.queue, ^{
            [self reloadLocked];
        });
    });
}

static void smPreferenceChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SMVNCServer *server = (__bridge SMVNCServer *)observer;
    [server handlePreferenceChange];
}

- (void)handlePreferenceChange {
    dispatch_async(_queue, ^{
        self.reloadGeneration += 1;
        const uint64_t generation = self.reloadGeneration;

        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), self.queue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.reloadGeneration != generation) {
                return;
            }
            [strongSelf reloadLocked];
        });
    });
}

- (void)reloadLocked {
    [self stopLocked];

    if (!smReadEnabled()) {
        return;
    }

    if (smReadPassword().length == 0) {
        smLog(@"Password is empty. Server will not start until a password is set.");
        return;
    }

    if (![self startListenerLocked]) {
        return;
    }

    self.running = YES;
    [self startPublishingLocked];
    smLog(@"VNC server started on port %u.", (unsigned)kSMServerPort);
}

- (void)stopLocked {
    const BOOL wasRunning = self.running || self.listenSocket >= 0;
    self.running = NO;

    for (SMVNCConnection *connection in [self.connections copy]) {
        [connection closeImmediately];
    }
    [self.connections removeAllObjects];

    if (self.acceptSource) {
        dispatch_source_cancel(self.acceptSource);
        self.acceptSource = nil;
    }

    if (self.listenSocket >= 0) {
        shutdown(self.listenSocket, SHUT_RDWR);
        close(self.listenSocket);
        self.listenSocket = -1;
    }

    NSArray<NSNetService *> *publishedServices = [self.publishedServices copy];
    [self.publishedServices removeAllObjects];
    if (publishedServices.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSNetService *service in publishedServices) {
                [service stop];
                service.delegate = nil;
            }
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[SMScreenCapture sharedCapture] setStreamingActive:NO];
        [[SMScreenCapture sharedCapture] resetCaptureThrottle];
    });

    if (wasRunning) {
        smLog(@"VNC server stopped.");
    }
}

- (BOOL)startListenerLocked {
    if (self.listenSocket >= 0) {
        return YES;
    }

    int socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socketFD < 0) {
        return NO;
    }

    int yes = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_REUSEPORT
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));
#endif

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(kSMServerPort);
    address.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        smLog(@"Failed to bind VNC listener on port %u (errno %d: %s).",
              (unsigned)kSMServerPort,
              errno,
              strerror(errno));
        close(socketFD);
        return NO;
    }
    if (listen(socketFD, 8) != 0) {
        smLog(@"Failed to listen on port %u (errno %d: %s).", (unsigned)kSMServerPort, errno, strerror(errno));
        close(socketFD);
        return NO;
    }

    self.listenSocket = socketFD;
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)socketFD, 0, self.queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.acceptSource, ^{
        [weakSelf acceptPendingConnections];
    });
    dispatch_resume(self.acceptSource);
    return YES;
}

- (void)acceptPendingConnections {
    while (self.listenSocket >= 0) {
        struct sockaddr_in clientAddress;
        socklen_t addressLength = sizeof(clientAddress);
        int clientSocket = accept(self.listenSocket, (struct sockaddr *)&clientAddress, &addressLength);
        if (clientSocket < 0) {
            break;
        }

        if (self.connections.count >= kSMMaxConnections) {
            close(clientSocket);
            smLog(@"Rejected connection (max clients reached).");
            continue;
        }

        dispatch_queue_t connectionQueue = dispatch_queue_create("com.strayfade.screenmirroring.client", DISPATCH_QUEUE_SERIAL);
        SMVNCConnection *connection = [[SMVNCConnection alloc] initWithSocketFD:clientSocket server:self queue:connectionQueue];
        [self.connections addObject:connection];
        [connection start];
        smLog(@"Accepted VNC TCP client.");
    }
}

- (void)publishServiceOnMainThreadWithType:(NSString *)type name:(NSString *)name port:(int)port txt:(NSData *)txtData {
    if (!self.running) {
        return;
    }

    NSNetService *service = [[NSNetService alloc] initWithDomain:kSMServiceDomain
                                                            type:type
                                                            name:name
                                                            port:port];
    service.delegate = self;
    [service setTXTRecordData:txtData];
    if ([service respondsToSelector:@selector(publishWithOptions:includingPeerToPeer:)]) {
        [service publishWithOptions:0 includingPeerToPeer:YES];
    } else {
        [service publish];
    }
    [self.publishedServices addObject:service];
    smLog(@"Publishing Bonjour '%@' type %@ port %d.", name, type, port);
}

- (void)startPublishingLocked {
    const int port = (int)kSMServerPort;

    __block NSString *deviceName = @"Screen-Mirroring-iOS";
    dispatch_sync(dispatch_get_main_queue(), ^{
        deviceName = smSanitizedServiceName([UIDevice currentDevice].name);
    });

    NSDictionary *txt = @{
        @"v": [NSString stringWithFormat:@"%u", kSMProtocolVersion],
        @"id": smDeviceIdentifier(),
        @"platform": @"ios",
        @"vendor": @"strayfade",
        @"proto": @"rfb",
    };
    NSData *txtData = [NSNetService dataFromTXTRecordDictionary:txt];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.publishedServices.count > 0 || !self.running) {
            return;
        }

        [self publishServiceOnMainThreadWithType:kSMServiceType name:deviceName port:port txt:txtData];
        [self publishServiceOnMainThreadWithType:kSMRfbServiceType name:deviceName port:port txt:txtData];
    });
}

- (void)clientConnected:(SMVNCConnection *)connection {
    (void)connection;
}

- (void)notifyClientDisconnected:(SMVNCConnection *)connection {
    dispatch_async(self.queue, ^{
        [self clientDisconnectedLocked:connection];
    });
}

- (void)clientDisconnectedLocked:(SMVNCConnection *)connection {
    if (!connection) {
        return;
    }
    [self.connections removeObject:connection];
    if (self.connections.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[SMScreenCapture sharedCapture] setStreamingActive:NO];
            [[SMScreenCapture sharedCapture] resetCaptureThrottle];
            [[SMScreenCapture sharedCapture] cancelPendingCaptures];
        });
    }
}

- (void)netServiceDidPublish:(NSNetService *)sender {
    smLog(@"Bonjour published %@.%@%@ port %ld.", sender.name, sender.type, sender.domain, (long)sender.port);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    smLog(@"Bonjour publish failed for %@.%@%@: %@", sender.name, sender.type, sender.domain, errorDict);
}

@end
