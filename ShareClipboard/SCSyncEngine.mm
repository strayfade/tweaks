#import "SCSyncEngine.h"
#import "SCConnection.h"
#import "SCCommon.h"
#import "SCPasteboard.h"
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static void scLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ShareClipboard] %@", message);
}

@interface SCSyncEngine () <NSNetServiceDelegate, NSNetServiceBrowserDelegate, SCConnectionDelegate>
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t clipboardProcessingQueue;
@property (nonatomic, strong) NSNetService *publishedService;
@property (nonatomic, strong) NSNetServiceBrowser *browser;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SCConnection *> *connectionsByPeerID;
@property (nonatomic, strong) NSMutableSet<NSString *> *connectingPeerIDs;
@property (nonatomic, strong) NSMutableSet<NSNetService *> *pendingServices;
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL applyingRemoteUpdate;
@property (nonatomic, copy) NSString *lastSentFingerprint;
@property (nonatomic, copy) NSString *lastAppliedFingerprint;
@property (nonatomic, strong) dispatch_block_t pendingClipboardWork;
@property (nonatomic, strong) dispatch_queue_t pasteboardWatchQueue;
@property (nonatomic, strong) dispatch_source_t pasteboardWatchSource;
@property (nonatomic, assign) NSInteger lastPasteboardChangeCount;
@property (nonatomic, assign) BOOL publishingLocalClipboard;
@property (nonatomic, assign) NSTimeInterval lastLocalClipboardPublishTime;
@end

@implementation SCSyncEngine

+ (instancetype)sharedEngine {
    static SCSyncEngine *engine = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[SCSyncEngine alloc] init];
    });
    return engine;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _queue = dispatch_queue_create("com.strayfade.shareclipboard.sync", DISPATCH_QUEUE_SERIAL);
    _clipboardProcessingQueue = dispatch_queue_create("com.strayfade.shareclipboard.clipboard", DISPATCH_QUEUE_SERIAL);
    _pasteboardWatchQueue = dispatch_queue_create("com.strayfade.shareclipboard.pasteboard-watch", DISPATCH_QUEUE_SERIAL);
    _connectionsByPeerID = [NSMutableDictionary dictionary];
    _connectingPeerIDs = [NSMutableSet set];
    _pendingServices = [NSMutableSet set];
    _listenSocket = -1;
    return self;
}

- (void)startIfNeeded {
    dispatch_async(self.queue, ^{
        if (!scReadEnabled()) {
            [self stopLocked];
            return;
        }
        if (self.running) {
            return;
        }
        if (![self startListenerLocked]) {
            scLog(@"Failed to start TCP listener.");
            return;
        }
        self.running = YES;
        [self startPublishingLocked];
        [self startBrowsingLocked];
        [self registerClipboardObserverLocked];
        [self startPasteboardWatchLocked];
        scLog(@"Sync engine started.");
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        [self stopLocked];
    });
}

- (void)handlePreferenceChange {
    dispatch_async(self.queue, ^{
        if (scReadEnabled()) {
            [self startIfNeededOnQueue];
        } else {
            [self stopLocked];
        }
    });
}

- (void)startIfNeededOnQueue {
    if (!scReadEnabled()) {
        [self stopLocked];
        return;
    }
    if (self.running) {
        return;
    }
    if (![self startListenerLocked]) {
        return;
    }
    self.running = YES;
    [self startPublishingLocked];
    [self startBrowsingLocked];
    [self registerClipboardObserverLocked];
    [self startPasteboardWatchLocked];
}

- (void)stopLocked {
    self.running = NO;

    dispatch_source_t pasteboardWatchSource = self.pasteboardWatchSource;
    self.pasteboardWatchSource = nil;
    if (pasteboardWatchSource) {
        dispatch_source_cancel(pasteboardWatchSource);
    }

    self.acceptSource = nil;
    if (self.listenSocket >= 0) {
        close(self.listenSocket);
        self.listenSocket = -1;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pendingClipboardWork) {
            dispatch_block_cancel(self.pendingClipboardWork);
            self.pendingClipboardWork = nil;
        }

        [self.publishedService stop];
        self.publishedService.delegate = nil;
        self.publishedService = nil;

        [self.browser stop];
        self.browser.delegate = nil;
        self.browser = nil;
    });

    for (SCConnection *connection in self.connectionsByPeerID.allValues) {
        connection.delegate = nil;
        [connection close];
    }
    [self.connectionsByPeerID removeAllObjects];
    [self.connectingPeerIDs removeAllObjects];
    [self.pendingServices removeAllObjects];

    scLog(@"Sync engine stopped.");
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

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = 0;
    address.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return NO;
    }
    if (listen(socketFD, 8) != 0) {
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

        if (self.connectionsByPeerID.count >= kSCMaxConnections) {
            close(clientSocket);
            continue;
        }

        SCConnection *connection = [[SCConnection alloc] initWithSocketFD:clientSocket queue:self.queue];
        if (!connection) {
            continue;
        }
        connection.delegate = self;
        [self trackConnection:connection forPeerID:nil];
        scLog(@"Accepted inbound TCP connection.");
    }
}

- (void)startPublishingLocked {
    if (self.publishedService) {
        return;
    }

    struct sockaddr_in address;
    socklen_t addressLength = sizeof(address);
    if (getsockname(self.listenSocket, (struct sockaddr *)&address, &addressLength) != 0) {
        scLog(@"Failed to read listener port (errno %d).", errno);
        return;
    }

    const int port = ntohs(address.sin_port);
    NSString *deviceName = scSanitizedServiceName([UIDevice currentDevice].name);
    NSData *txtData = [self txtRecordData];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.publishedService || !self.running) {
            return;
        }

        NSNetService *service = [[NSNetService alloc] initWithDomain:kSCServiceDomain
                                                                  type:kSCServiceType
                                                                  name:deviceName
                                                                  port:port];
        service.delegate = self;
        [service setTXTRecordData:txtData];
        [service publish];
        self.publishedService = service;
        scLog(@"Publishing mDNS service '%@' on port %d.", deviceName, port);
    });
}

- (NSData *)txtRecordData {
    NSDictionary *txt = @{
        @"v": [NSString stringWithFormat:@"%u", kSCProtocolVersion],
        @"id": scDeviceIdentifier(),
        @"platform": @"ios",
    };
    return [NSNetService dataFromTXTRecordDictionary:txt];
}

- (void)startBrowsingLocked {
    if (self.browser) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.browser || !self.running) {
            return;
        }

        NSNetServiceBrowser *browser = [[NSNetServiceBrowser alloc] init];
        browser.delegate = self;
        [browser searchForServicesOfType:kSCServiceType inDomain:kSCServiceDomain];
        self.browser = browser;
        scLog(@"Started browsing for peers.");
    });
}

static void scPasteboardDarwinChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SCSyncEngine *engine = (__bridge SCSyncEngine *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [engine notePasteboardChanged];
    });
}

- (void)registerClipboardObserverLocked {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastPasteboardChangeCount = scPasteboardChangeCount();
    });

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SCSyncEngine *engine = [SCSyncEngine sharedEngine];
        __weak SCSyncEngine *weakEngine = engine;

        [[NSNotificationCenter defaultCenter] addObserverForName:UIPasteboardChangedNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            SCSyncEngine *strongEngine = weakEngine;
            if (!strongEngine || !strongEngine.running) {
                return;
            }
            [strongEngine notePasteboardChanged];
        }];

        CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
        static const CFStringRef kPasteboardDarwinNames[] = {
            CFSTR("com.apple.system.pasteboard.changed"),
            CFSTR("com.apple.system.pasteboard.notify.changed"),
            CFSTR("com.apple.uikit.pboard.changed"),
            CFSTR("com.apple.pasteboard.changed"),
            CFSTR("PBServerPasteboardChangedNotification"),
        };

        for (size_t index = 0; index < sizeof(kPasteboardDarwinNames) / sizeof(kPasteboardDarwinNames[0]); index++) {
            CFNotificationCenterAddObserver(darwinCenter,
                                            (__bridge const void *)engine,
                                            scPasteboardDarwinChanged,
                                            kPasteboardDarwinNames[index],
                                            NULL,
                                            CFNotificationSuspensionBehaviorCoalesce);
        }

        CFNotificationCenterAddObserver(darwinCenter,
                                        (__bridge const void *)engine,
                                        scPreferenceChangedCallback,
                                        CFSTR("com.strayfade.shareclipboard~prefs/preferencesChanged"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    });
}

- (void)notePasteboardChanged {
    if (self.applyingRemoteUpdate || self.publishingLocalClipboard) {
        return;
    }

    NSInteger changeCount = scPasteboardChangeCount();
    if (changeCount == self.lastPasteboardChangeCount) {
        return;
    }

    scLog(@"Pasteboard changed (count %ld).", (long)changeCount);
    self.lastPasteboardChangeCount = changeCount;
    [self scheduleLocalClipboardSync];
}

- (void)startPasteboardWatchLocked {
    if (self.pasteboardWatchSource) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pasteboardWatchSource || !self.running) {
            return;
        }

        self.lastPasteboardChangeCount = scPasteboardChangeCount();
        self.pasteboardWatchSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.pasteboardWatchQueue);
        dispatch_source_set_timer(self.pasteboardWatchSource,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                                (uint64_t)(2.5 * NSEC_PER_SEC),
                                (uint64_t)(0.5 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.pasteboardWatchSource, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.running) {
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf notePasteboardChanged];
            });
        });
        dispatch_resume(self.pasteboardWatchSource);
        scLog(@"Pasteboard watch started.");
    });
}

static void scPreferenceChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SCSyncEngine *engine = (__bridge SCSyncEngine *)observer;
    [engine handlePreferenceChange];
}

- (void)scheduleLocalClipboardSync {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scheduleLocalClipboardSync];
        });
        return;
    }

    if (!self.running || !scReadEnabled()) {
        return;
    }
    if (self.pendingClipboardWork) {
        dispatch_block_cancel(self.pendingClipboardWork);
        self.pendingClipboardWork = nil;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_block_t work = dispatch_block_create((dispatch_block_flags_t)0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf publishLocalClipboardOnMain];
    });
    self.pendingClipboardWork = work;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), work);
}

- (void)publishLocalClipboardOnMain {
    self.pendingClipboardWork = nil;
    if (!self.running || self.applyingRemoteUpdate || self.publishingLocalClipboard) {
        return;
    }

    self.publishingLocalClipboard = YES;
    scLog(@"Reading local clipboard for sync.");

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.clipboardProcessingQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running || strongSelf.applyingRemoteUpdate) {
            dispatch_async(strongSelf.queue, ^{
                __strong typeof(weakSelf) engine = weakSelf;
                if (engine) {
                    engine.publishingLocalClipboard = NO;
                }
            });
            return;
        }

        NSData *textData = scPasteboardReadTextData();
        NSData *imageData = textData.length > 0 ? nil : scPasteboardReadImagePNGData();

        dispatch_async(strongSelf.queue, ^{
            strongSelf.publishingLocalClipboard = NO;

            if (!strongSelf.running || strongSelf.applyingRemoteUpdate) {
                return;
            }
            if (textData.length == 0 && imageData.length == 0) {
                scLog(@"Local clipboard has no readable text or image.");
                return;
            }

            NSDictionary *message = [strongSelf messageFromClipboardData:textData imagePNGData:imageData];
            if (!message) {
                scLog(@"Failed to build clipboard message.");
                return;
            }

            NSString *fingerprint = message[@"fingerprint"];
            if (fingerprint.length > 0 && [fingerprint isEqualToString:strongSelf.lastAppliedFingerprint]) {
                scLog(@"Skipping local sync; matches last applied remote content.");
                return;
            }
            if (fingerprint.length > 0 && [fingerprint isEqualToString:strongSelf.lastSentFingerprint]) {
                scLog(@"Skipping local sync; already sent this content.");
                return;
            }

            NSMutableDictionary *payload = [message mutableCopy];
            [payload removeObjectForKey:@"fingerprint"];
            strongSelf.lastSentFingerprint = fingerprint;
            strongSelf.lastLocalClipboardPublishTime = [NSDate date].timeIntervalSince1970;
            scLog(@"Sending clipboard update to %lu peer(s).", (unsigned long)strongSelf.connectionsByPeerID.count);
            [strongSelf broadcastMessageLocked:payload];
        });
    });
}

- (NSDictionary *)messageFromClipboardData:(NSData *)textData imagePNGData:(NSData *)imageData {
    if (imageData.length > 0 && imageData.length <= kSCMaxPayloadSize) {
        NSString *encoded = [imageData base64EncodedStringWithOptions:0];
        NSString *fingerprint = scContentFingerprint(@"image", imageData);
        return @{
            @"v": @(kSCProtocolVersion),
            @"id": [[NSUUID UUID] UUIDString],
            @"ts": @((int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0)),
            @"type": @"image",
            @"mime": @"image/png",
            @"data": encoded ?: @"",
            @"fingerprint": fingerprint,
        };
    }

    if (textData.length == 0 || textData.length > kSCMaxPayloadSize) {
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        return nil;
    }

    NSString *fingerprint = scContentFingerprint(@"text", textData);
    return @{
        @"v": @(kSCProtocolVersion),
        @"id": [[NSUUID UUID] UUIDString],
        @"ts": @((int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0)),
        @"type": @"text",
        @"mime": @"text/plain; charset=utf-8",
        @"data": text,
        @"fingerprint": fingerprint,
    };
}

- (void)broadcastMessageLocked:(NSDictionary *)message {
    if (self.connectionsByPeerID.count == 0) {
        scLog(@"No peers connected; clipboard update not sent.");
        return;
    }
    for (SCConnection *connection in self.connectionsByPeerID.allValues) {
        [connection sendMessage:message];
    }
}

- (void)trackConnection:(SCConnection *)connection forPeerID:(NSString *)peerID {
    if (!connection) {
        return;
    }

    if (peerID.length > 0) {
        SCConnection *existing = self.connectionsByPeerID[peerID];
        if (existing && existing != connection) {
            existing.delegate = nil;
            [existing close];
        }
        self.connectionsByPeerID[peerID] = connection;
        [self.connectingPeerIDs removeObject:peerID];
        return;
    }

    NSString *temporaryKey = [NSString stringWithFormat:@"pending-%p", connection];
    self.connectionsByPeerID[temporaryKey] = connection;
}

- (void)connection:(SCConnection *)connection didReceiveMessage:(NSDictionary *)message {
    dispatch_async(self.queue, ^{
        [self handleIncomingMessageLocked:message fromConnection:connection];
    });
}

- (void)handleIncomingMessageLocked:(NSDictionary *)message fromConnection:(SCConnection *)connection {
    if (!self.running || !scReadEnabled()) {
        return;
    }

    NSNumber *version = [message[@"v"] isKindOfClass:[NSNumber class]] ? message[@"v"] : nil;
    if (!version || version.unsignedIntValue != kSCProtocolVersion) {
        return;
    }

    NSString *type = [message[@"type"] isKindOfClass:[NSString class]] ? message[@"type"] : @"";
    if ([type isEqualToString:@"hello"]) {
        NSString *peerID = [message[@"deviceId"] isKindOfClass:[NSString class]] ? message[@"deviceId"] : @"";
        if (peerID.length == 0 || [peerID isEqualToString:scDeviceIdentifier()]) {
            connection.delegate = nil;
            [connection close];
            return;
        }
        [self trackConnection:connection forPeerID:peerID];
        return;
    }

    if (![type isEqualToString:@"text"] && ![type isEqualToString:@"image"]) {
        return;
    }

    NSString *data = [message[@"data"] isKindOfClass:[NSString class]] ? message[@"data"] : @"";
    if (data.length == 0) {
        return;
    }

    NSString *fingerprint = @"";
    if ([type isEqualToString:@"text"]) {
        NSData *textData = [data dataUsingEncoding:NSUTF8StringEncoding];
        if (!textData) {
            return;
        }
        fingerprint = scContentFingerprint(@"text", textData);
        if ([fingerprint isEqualToString:self.lastAppliedFingerprint]) {
            return;
        }
        [self applyRemoteTextLocked:data fingerprint:fingerprint];
        return;
    }

    NSData *imageData = [[NSData alloc] initWithBase64EncodedString:data options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imageData || imageData.length == 0 || imageData.length > kSCMaxPayloadSize) {
        return;
    }
    fingerprint = scContentFingerprint(@"image", imageData);
    if ([fingerprint isEqualToString:self.lastAppliedFingerprint]) {
        return;
    }
    UIImage *image = [UIImage imageWithData:imageData];
    if (!image) {
        return;
    }
    [self applyRemoteImageLocked:image fingerprint:fingerprint];
}

- (void)applyRemoteOnMainWithBlock:(dispatch_block_t)update fingerprint:(NSString *)fingerprint {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.applyingRemoteUpdate = YES;
        update();
        self.lastAppliedFingerprint = fingerprint;
        self.lastPasteboardChangeCount = scPasteboardChangeCount();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.applyingRemoteUpdate = NO;
        });
    });
}

- (void)applyRemoteTextLocked:(NSString *)text fingerprint:(NSString *)fingerprint {
    [self applyRemoteOnMainWithBlock:^{
        scPasteboardApplyText(text);
    } fingerprint:fingerprint];
}

- (void)applyRemoteImageLocked:(UIImage *)image fingerprint:(NSString *)fingerprint {
    [self applyRemoteOnMainWithBlock:^{
        scPasteboardApplyImage(image);
    } fingerprint:fingerprint];
}

- (void)connectionDidClose:(SCConnection *)connection {
    dispatch_async(self.queue, ^{
        NSString *keyToRemove = nil;
        for (NSString *key in self.connectionsByPeerID) {
            if (self.connectionsByPeerID[key] == connection) {
                keyToRemove = key;
                break;
            }
        }
        if (keyToRemove) {
            [self.connectionsByPeerID removeObjectForKey:keyToRemove];
        }
        if (connection.peerIdentifier.length > 0) {
            [self.connectingPeerIDs removeObject:connection.peerIdentifier];
        }
    });
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidPublish:(NSNetService *)sender {
    scLog(@"Published mDNS service on port %ld.", (long)sender.port);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    scLog(@"Failed to publish mDNS service: %@", errorDict);
}

#pragma mark - NSNetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
    scLog(@"Discovered service: %@", service.name);
    dispatch_async(self.queue, ^{
        if (!self.running) {
            return;
        }

        NSString *serviceKey = service.name ?: @"";
        if (serviceKey.length == 0) {
            return;
        }

        NSString *ownName = scSanitizedServiceName([UIDevice currentDevice].name);
        if ([serviceKey isEqualToString:ownName]) {
            scLog(@"Ignoring own service: %@", serviceKey);
            return;
        }

        if ([self.connectingPeerIDs containsObject:serviceKey]) {
            return;
        }

        [self.connectingPeerIDs addObject:serviceKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            service.delegate = self;
            [self.pendingServices addObject:service];
            [service resolveWithTimeout:5.0];
            scLog(@"Resolving service: %@", service.name);
        });
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing {
    dispatch_async(self.queue, ^{
        NSString *peerID = [self peerIDFromService:service];
        if (peerID.length == 0) {
            return;
        }
        SCConnection *connection = self.connectionsByPeerID[peerID];
        if (connection) {
            connection.delegate = nil;
            [connection close];
            [self.connectionsByPeerID removeObjectForKey:peerID];
        }
        [self.connectingPeerIDs removeObject:peerID];
        [self.pendingServices removeObject:service];
    });
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    dispatch_async(self.queue, ^{
        if (!self.running) {
            return;
        }

        NSString *serviceKey = sender.name ?: @"";
        [self.pendingServices removeObject:sender];

        NSString *peerID = [self peerIDFromService:sender];
        if (peerID.length == 0) {
            scLog(@"Resolved %@ but TXT record has no peer id.", sender.name);
            [self.connectingPeerIDs removeObject:serviceKey];
            return;
        }
        if ([peerID isEqualToString:scDeviceIdentifier()]) {
            [self.connectingPeerIDs removeObject:serviceKey];
            return;
        }
        if (self.connectionsByPeerID[peerID]) {
            [self.connectingPeerIDs removeObject:serviceKey];
            return;
        }
        if (self.connectionsByPeerID.count >= kSCMaxConnections) {
            [self.connectingPeerIDs removeObject:serviceKey];
            return;
        }

        NSString *localID = scDeviceIdentifier();
        if ([localID compare:peerID] != NSOrderedAscending) {
            scLog(@"Peer %@ will connect to us (we are not the initiator).", peerID);
            [self.connectingPeerIDs removeObject:serviceKey];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            SCConnection *connection = [[SCConnection alloc] initWithResolvedService:sender queue:self.queue];
            if (!connection) {
                scLog(@"Failed to open connection to %@.", sender.name);
                dispatch_async(self.queue, ^{
                    [self.connectingPeerIDs removeObject:serviceKey];
                });
                return;
            }

            connection.delegate = self;
            dispatch_async(self.queue, ^{
                [self.connectingPeerIDs removeObject:serviceKey];
                [self trackConnection:connection forPeerID:peerID];
                scLog(@"Connected to peer %@.", peerID);
            });
        });
    });
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    scLog(@"Failed to resolve %@: %@", sender.name, errorDict);
    dispatch_async(self.queue, ^{
        [self.connectingPeerIDs removeObject:sender.name ?: @""];
        [self.pendingServices removeObject:sender];
    });
}

- (NSString *)peerIDFromService:(NSNetService *)service {
    NSData *txtData = service.TXTRecordData;
    if (txtData.length == 0) {
        return @"";
    }
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:txtData];
    NSData *idData = txt[@"id"];
    if (![idData isKindOfClass:[NSData class]]) {
        return @"";
    }
    return [[NSString alloc] initWithData:idData encoding:NSUTF8StringEncoding] ?: @"";
}

@end
