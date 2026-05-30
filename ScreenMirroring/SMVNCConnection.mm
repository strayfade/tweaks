#import "SMVNCConnection.h"
#import "SMCommon.h"
#import "SMInputInjector.h"
#import "SMScreenCapture.h"
#import "SMVNCCrypto.h"
#import "SMVNCServer.h"
#import <arpa/inet.h>
#import <errno.h>
#import <netdb.h>
#import <sys/socket.h>
#import <fcntl.h>
#import <netinet/tcp.h>
#import <os/lock.h>
#import <unistd.h>

static void smClampFramebufferRect(uint16_t *x,
                                   uint16_t *y,
                                   uint16_t *width,
                                   uint16_t *height,
                                   NSUInteger frameWidth,
                                   NSUInteger frameHeight) {
    if (frameWidth == 0 || frameHeight == 0) {
        *width = 0;
        *height = 0;
        return;
    }

    if (*x >= frameWidth) {
        *x = 0;
    }
    if (*y >= frameHeight) {
        *y = 0;
    }

    if (*width == 0) {
        *width = (uint16_t)MIN(frameWidth, (NSUInteger)UINT16_MAX);
    }
    if (*height == 0) {
        *height = (uint16_t)MIN(frameHeight, (NSUInteger)UINT16_MAX);
    }

    const NSUInteger maxWidth = frameWidth - (NSUInteger)*x;
    const NSUInteger maxHeight = frameHeight - (NSUInteger)*y;
    *width = (uint16_t)MIN((NSUInteger)*width, maxWidth);
    *height = (uint16_t)MIN((NSUInteger)*height, maxHeight);
}

static int32_t smReadS32BEFrom(const uint8_t *bytes) {
    return (int32_t)(((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3]);
}

static uint16_t smReadPixelFormatU16(const uint8_t *bytes) {
    return (uint16_t)((bytes[0] << 8) | bytes[1]);
}

static uint32_t smPackTrueColorPixel(uint8_t red, uint8_t green, uint8_t blue, const uint8_t *pixelFormat) {
    const uint16_t redMax = smReadPixelFormatU16(pixelFormat + 4);
    const uint16_t greenMax = smReadPixelFormatU16(pixelFormat + 6);
    const uint16_t blueMax = smReadPixelFormatU16(pixelFormat + 8);
    const uint8_t redShift = pixelFormat[10];
    const uint8_t greenShift = pixelFormat[11];
    const uint8_t blueShift = pixelFormat[12];

    const uint32_t redValue = redMax > 0 ? ((uint32_t)red * redMax / 255U) : 0;
    const uint32_t greenValue = greenMax > 0 ? ((uint32_t)green * greenMax / 255U) : 0;
    const uint32_t blueValue = blueMax > 0 ? ((uint32_t)blue * blueMax / 255U) : 0;
    return (redValue << redShift) | (greenValue << greenShift) | (blueValue << blueShift);
}

static void smWritePackedPixel(uint8_t *destination, uint32_t packedPixel, uint8_t bitsPerPixel, BOOL bigEndian) {
    if (bitsPerPixel == 8) {
        destination[0] = (uint8_t)(packedPixel & 0xFF);
        return;
    }

    if (bitsPerPixel == 16) {
        const uint16_t value = (uint16_t)(packedPixel & 0xFFFF);
        if (bigEndian) {
            destination[0] = (uint8_t)((value >> 8) & 0xFF);
            destination[1] = (uint8_t)(value & 0xFF);
        } else {
            destination[0] = (uint8_t)(value & 0xFF);
            destination[1] = (uint8_t)((value >> 8) & 0xFF);
        }
        return;
    }

    if (bigEndian) {
        destination[0] = (uint8_t)((packedPixel >> 24) & 0xFF);
        destination[1] = (uint8_t)((packedPixel >> 16) & 0xFF);
        destination[2] = (uint8_t)((packedPixel >> 8) & 0xFF);
        destination[3] = (uint8_t)(packedPixel & 0xFF);
    } else {
        destination[0] = (uint8_t)(packedPixel & 0xFF);
        destination[1] = (uint8_t)((packedPixel >> 8) & 0xFF);
        destination[2] = (uint8_t)((packedPixel >> 16) & 0xFF);
        destination[3] = (uint8_t)((packedPixel >> 24) & 0xFF);
    }
}

static NSMutableData *smEncodeRectPixelsForClientFormat(const uint8_t *sourceBGRA,
                                                        NSUInteger sourceStride,
                                                        uint16_t rectX,
                                                        uint16_t rectY,
                                                        uint16_t rectWidth,
                                                        uint16_t rectHeight,
                                                        const uint8_t *pixelFormat) {
    if (!sourceBGRA || !pixelFormat || rectWidth == 0 || rectHeight == 0) {
        return nil;
    }

    const uint8_t bitsPerPixel = pixelFormat[0];
    if (bitsPerPixel != 8 && bitsPerPixel != 16 && bitsPerPixel != 32) {
        return nil;
    }
    if (pixelFormat[3] == 0) {
        return nil;
    }

    const BOOL bigEndian = pixelFormat[2] != 0;
    const NSUInteger bytesPerPixel = bitsPerPixel / 8;
    NSMutableData *encoded = [NSMutableData dataWithLength:(NSUInteger)rectWidth * rectHeight * bytesPerPixel];
    uint8_t *destination = (uint8_t *)encoded.mutableBytes;

    for (NSUInteger row = 0; row < rectHeight; row++) {
        const uint8_t *sourceRow = sourceBGRA + ((NSUInteger)rectY + row) * sourceStride + (NSUInteger)rectX * 4;
        uint8_t *destinationRow = destination + row * rectWidth * bytesPerPixel;
        for (NSUInteger column = 0; column < rectWidth; column++) {
            const uint8_t *sourcePixel = sourceRow + column * 4;
            const uint8_t blue = sourcePixel[0];
            const uint8_t green = sourcePixel[1];
            const uint8_t red = sourcePixel[2];
            const uint32_t packed = smPackTrueColorPixel(red, green, blue, pixelFormat);
            smWritePackedPixel(destinationRow + column * bytesPerPixel, packed, bitsPerPixel, bigEndian);
        }
    }

    return encoded;
}

static BOOL smClientFormatIs32BitBGRx(const uint8_t *pixelFormat) {
    return pixelFormat[0] == 32 && pixelFormat[1] >= 24 && pixelFormat[2] == 0 && pixelFormat[3] == 1 &&
           smReadPixelFormatU16(pixelFormat + 4) == 255 && smReadPixelFormatU16(pixelFormat + 6) == 255 &&
           smReadPixelFormatU16(pixelFormat + 8) == 255 && pixelFormat[10] == 16 && pixelFormat[11] == 8 && pixelFormat[12] == 0;
}

static BOOL smClientFormatIsReadyForPixels(const uint8_t *pixelFormat) {
    const uint8_t bitsPerPixel = pixelFormat[0];
    return pixelFormat[3] == 1 && (bitsPerPixel == 8 || bitsPerPixel == 16 || bitsPerPixel == 32);
}

static void smCopyRectTo32BitBGRx(const uint8_t *source,
                                  NSUInteger sourceStride,
                                  uint8_t *destination,
                                  uint16_t rectX,
                                  uint16_t rectY,
                                  uint16_t rectWidth,
                                  uint16_t rectHeight) {
    const NSUInteger destinationStride = (NSUInteger)rectWidth * 4;
    for (NSUInteger row = 0; row < rectHeight; row++) {
        const uint8_t *sourceRow = source + ((NSUInteger)rectY + row) * sourceStride + (NSUInteger)rectX * 4;
        uint8_t *destinationRow = destination + row * destinationStride;
        for (NSUInteger column = 0; column < rectWidth; column++) {
            const uint8_t *pixel = sourceRow + column * 4;
            uint8_t *out = destinationRow + column * 4;
            const uint32_t bgr = (uint32_t)pixel[0] | ((uint32_t)pixel[1] << 8) | ((uint32_t)pixel[2] << 16);
            *(uint32_t *)out = bgr | 0xFF000000U;
        }
    }
}

static const uint32_t kSMEncodingRaw = 0;
static const uint32_t kSMEncodingLastRect = 0xFFFFFF20;

// 32-bit little-endian true colour BGRx (matches bitmap capture).
static const uint8_t kSMServerPixelFormat[16] = {
    32, 24, 0, 1,
    0, 255, 0, 255, 0, 255,
    16, 8, 0,
    0, 0, 0,
};

@interface SMVNCConnection ()
@property (nonatomic, assign) int socketFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) os_unfair_lock writeLock;
@property (nonatomic, assign) BOOL authenticated;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) unsigned int clientMajorVersion;
@property (nonatomic, assign) unsigned int clientMinorVersion;
@property (nonatomic, assign) BOOL usesSecurityTypeList;
@property (nonatomic, assign) NSUInteger frameWidth;
@property (nonatomic, assign) NSUInteger frameHeight;
@property (nonatomic, assign) BOOL wantsUpdates;
@property (nonatomic, assign) BOOL incrementalOnly;
@property (nonatomic, assign) uint16_t updateX;
@property (nonatomic, assign) uint16_t updateY;
@property (nonatomic, assign) uint16_t updateWidth;
@property (nonatomic, assign) uint16_t updateHeight;
@property (nonatomic, strong) dispatch_source_t updateTimer;
@property (nonatomic, assign) BOOL clientWantsLastRect;
@end

@implementation SMVNCConnection {
    uint8_t _clientPixelFormat[16];
    BOOL _receivedClientPixelFormat;
    BOOL _teardownStarted;
    BOOL _pushInFlight;
    os_unfair_lock _sessionLock;
    dispatch_queue_t _sendQueue;
    dispatch_queue_t _captureQueue;
}

- (instancetype)initWithSocketFD:(int)socketFD server:(SMVNCServer *)server queue:(dispatch_queue_t)queue {
    self = [super init];
    if (!self) {
        if (socketFD >= 0) {
            close(socketFD);
        }
        return nil;
    }

    _socketFD = socketFD;
    _server = server;
    _queue = queue;
    dispatch_queue_attr_t sendAttr =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    _sendQueue = dispatch_queue_create("com.strayfade.screenmirroring.client.send", sendAttr);
    _captureQueue = [[SMScreenCapture sharedCapture] captureQueueForVNC];
    _writeLock = OS_UNFAIR_LOCK_INIT;
    _sessionLock = OS_UNFAIR_LOCK_INIT;
    _incrementalOnly = NO;
    _updateWidth = 0;
    _updateHeight = 0;
    _usesSecurityTypeList = YES;
    _clientWantsLastRect = NO;
    _receivedClientPixelFormat = NO;
    memcpy(_clientPixelFormat, kSMServerPixelFormat, sizeof(_clientPixelFormat));

    int yes = 1;
    setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    int sendBufferSize = 512 * 1024;
    setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, sizeof(sendBufferSize));

    return self;
}

- (void)shutdownSocketFromAnyThread {
    os_unfair_lock_lock(&_writeLock);
    const int socketToClose = _socketFD;
    _socketFD = -1;
    os_unfair_lock_unlock(&_writeLock);

    if (socketToClose >= 0) {
        shutdown(socketToClose, SHUT_RDWR);
        close(socketToClose);
    }
}

- (void)dealloc {
    [self shutdownSocketFromAnyThread];

    os_unfair_lock_lock(&_sessionLock);
    _running = NO;
    _teardownStarted = YES;
    os_unfair_lock_unlock(&_sessionLock);

    if (_updateTimer) {
        dispatch_source_cancel(_updateTimer);
        _updateTimer = nil;
    }
}

- (void)start {
    dispatch_async(_queue, ^{
        [self runSession];
    });
}

- (void)close {
    [self closeImmediately];
}

- (void)closeImmediately {
    // Shut down the socket from any thread so a blocked recv on _queue can return.
    [self shutdownSocketFromAnyThread];
    dispatch_async(_queue, ^{
        [self teardownLocked];
    });
}

- (void)teardownLocked {
    if (_teardownStarted) {
        return;
    }
    _teardownStarted = YES;

    os_unfair_lock_lock(&_sessionLock);
    _running = NO;
    _wantsUpdates = NO;
    os_unfair_lock_unlock(&_sessionLock);

    [self stopUpdateTimerLocked];

    _authenticated = NO;

    [self shutdownSocketFromAnyThread];

    if (_sendQueue) {
        dispatch_sync(_sendQueue, ^{});
    }

    SMVNCServer *server = _server;
    if (server) {
        [server notifyClientDisconnected:self];
    }
}

- (BOOL)readExact:(void *)buffer length:(size_t)length {
    uint8_t *cursor = (uint8_t *)buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t readBytes = recv(_socketFD, cursor, remaining, 0);
        if (readBytes <= 0) {
            return NO;
        }
        cursor += readBytes;
        remaining -= (size_t)readBytes;
    }
    return YES;
}

- (BOOL)writeExact:(const void *)buffer length:(size_t)length {
    os_unfair_lock_lock(&_writeLock);
    const int socketFD = _socketFD;
    if (socketFD < 0) {
        os_unfair_lock_unlock(&_writeLock);
        return NO;
    }

    const uint8_t *cursor = (const uint8_t *)buffer;
    size_t remaining = length;
    BOOL success = YES;
    while (remaining > 0) {
        ssize_t wroteBytes = send(socketFD, cursor, remaining, 0);
        if (wroteBytes <= 0) {
            success = NO;
            break;
        }
        cursor += wroteBytes;
        remaining -= (size_t)wroteBytes;
    }
    os_unfair_lock_unlock(&_writeLock);
    return success;
}

- (BOOL)writeU8:(uint8_t)value {
    return [self writeExact:&value length:1];
}

- (BOOL)writeU16BE:(uint16_t)value {
    uint8_t bytes[2] = {(uint8_t)((value >> 8) & 0xFF), (uint8_t)(value & 0xFF)};
    return [self writeExact:bytes length:2];
}

- (BOOL)writeU32BE:(uint32_t)value {
    uint8_t bytes[4] = {
        (uint8_t)((value >> 24) & 0xFF),
        (uint8_t)((value >> 16) & 0xFF),
        (uint8_t)((value >> 8) & 0xFF),
        (uint8_t)(value & 0xFF),
    };
    return [self writeExact:bytes length:4];
}

- (uint16_t)readU16BEFrom:(const uint8_t *)bytes {
    return (uint16_t)((bytes[0] << 8) | bytes[1]);
}

- (uint32_t)readU32BEFrom:(const uint8_t *)bytes {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

- (BOOL)negotiateProtocolVersion {
    if (![self writeExact:"RFB 003.008\n" length:12]) {
        return NO;
    }

    char clientVersion[12] = {0};
    if (![self readExact:clientVersion length:12]) {
        return NO;
    }

    unsigned int major = 3;
    unsigned int minor = 8;
    sscanf(clientVersion, "RFB %u.%u", &major, &minor);
    self.clientMajorVersion = major;
    self.clientMinorVersion = minor;
    self.usesSecurityTypeList = (major > 3) || (major == 3 && minor >= 8);
    smLog(@"Client protocol: %.12s (uses security list: %@)", clientVersion, self.usesSecurityTypeList ? @"yes" : @"no");
    return YES;
}

- (BOOL)performSecurityHandshake {
    if (self.usesSecurityTypeList) {
        uint8_t securityTypes[] = {1, 2};
        if (![self writeExact:securityTypes length:2]) {
            return NO;
        }

        uint8_t selectedType = 0;
        if (![self readExact:&selectedType length:1] || selectedType != 2) {
            smLog(@"Client did not select VNC authentication (type %u).", selectedType);
            return NO;
        }
    } else {
        uint32_t securityType = htonl(2);
        if (![self writeExact:&securityType length:4]) {
            return NO;
        }
    }

    uint8_t challenge[16];
    int randomFD = open("/dev/urandom", O_RDONLY);
    if (randomFD >= 0) {
        read(randomFD, challenge, sizeof(challenge));
        close(randomFD);
    } else {
        arc4random_buf(challenge, sizeof(challenge));
    }

    if (![self writeExact:challenge length:16]) {
        return NO;
    }

    uint8_t response[16];
    if (![self readExact:response length:16]) {
        return NO;
    }

    uint8_t expected[16];
    NSString *password = smReadPassword();
    smVNCEncryptChallenge(expected, challenge, password.UTF8String);

    if (memcmp(response, expected, 16) != 0) {
        uint32_t failed = htonl(1);
        uint32_t reasonLength = htonl(13);
        [self writeExact:&failed length:4];
        [self writeExact:&reasonLength length:4];
        [self writeExact:"Bad password" length:13];
        smLog(@"Authentication failed.");
        return NO;
    }

    uint32_t success = htonl(0);
    if (![self writeExact:&success length:4]) {
        return NO;
    }

    uint8_t sharedFlag = 0;
    if (![self readExact:&sharedFlag length:1]) {
        return NO;
    }

    return YES;
}

- (BOOL)sendServerInit {
    [[SMScreenCapture sharedCapture] frameDimensionsForScale:smEffectiveFrameScale()
                                                       width:&_frameWidth
                                                      height:&_frameHeight];
    if (_frameWidth == 0 || _frameHeight == 0) {
        smLog(@"ServerInit failed: invalid framebuffer dimensions.");
        return NO;
    }

    if (![self writeU16BE:(uint16_t)_frameWidth] || ![self writeU16BE:(uint16_t)_frameHeight]) {
        return NO;
    }
    if (![self writeExact:kSMServerPixelFormat length:16]) {
        return NO;
    }

    NSString *name = [NSString stringWithFormat:@"Screen Mirroring (%lux%lu)",
                      (unsigned long)_frameWidth,
                      (unsigned long)_frameHeight];
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (![self writeU32BE:(uint32_t)nameData.length] || ![self writeExact:nameData.bytes length:nameData.length]) {
        return NO;
    }

    return YES;
}

- (void)startPushLoopOnSendQueue {
    if (_updateTimer) {
        return;
    }

    const double frameRate = smPreferredFrameRate();
    const int64_t frameIntervalNs = (int64_t)(NSEC_PER_SEC / frameRate);

    _updateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _sendQueue);
    dispatch_source_set_timer(_updateTimer,
                              dispatch_time(DISPATCH_TIME_NOW, frameIntervalNs),
                              frameIntervalNs,
                              0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_updateTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf pushFramebufferUpdateOnSendQueue];
    });
    dispatch_resume(_updateTimer);
    [self pushFramebufferUpdateOnSendQueue];
}

- (void)armFullFramebufferRequest {
    _incrementalOnly = NO;
    _updateX = 0;
    _updateY = 0;
    _updateWidth = 0;
    _updateHeight = 0;
    _wantsUpdates = YES;
}

- (void)stopUpdateTimerLocked {
    dispatch_source_t timer = _updateTimer;
    if (!timer) {
        return;
    }
    _updateTimer = nil;
    dispatch_source_set_cancel_handler(timer, ^{});
    dispatch_source_cancel(timer);
}

- (void)runSession {
    _running = YES;

    if (![self negotiateProtocolVersion]) {
        smLog(@"VNC handshake failed during protocol negotiation.");
        [self teardownLocked];
        return;
    }

    if (![self performSecurityHandshake]) {
        smLog(@"VNC handshake failed during security exchange.");
        [self teardownLocked];
        return;
    }

    if (![self sendServerInit]) {
        smLog(@"VNC handshake failed during ServerInit.");
        [self teardownLocked];
        return;
    }

    _authenticated = YES;
    dispatch_sync(dispatch_get_main_queue(), ^{
        [[SMScreenCapture sharedCapture] setStreamingActive:YES];
    });
    [[SMScreenCapture sharedCapture] resetCaptureThrottle];
    [_server clientConnected:self];
    smLog(@"Client authenticated (%lux%lu).", (unsigned long)_frameWidth, (unsigned long)_frameHeight);

    dispatch_async(_sendQueue, ^{
        [self startPushLoopOnSendQueue];
    });

    while (_running) {
        uint8_t messageType = 0;
        if (![self readExact:&messageType length:1]) {
            break;
        }

        if (![self handleClientMessage:messageType]) {
            break;
        }
    }

    smLog(@"Client disconnected.");
    [self teardownLocked];
}

- (BOOL)handleClientMessage:(uint8_t)messageType {
    switch (messageType) {
        case 0: {
            uint8_t padding[3];
            uint8_t pixelFormat[16];
            if (![self readExact:padding length:3] || ![self readExact:pixelFormat length:16]) {
                return NO;
            }
            memcpy(_clientPixelFormat, pixelFormat, sizeof(_clientPixelFormat));
            _receivedClientPixelFormat = YES;
            smLog(@"Client SetPixelFormat: %ubpp depth %u %s-endian true-colour %u (max %u/%u/%u shifts %u/%u/%u).",
                  pixelFormat[0],
                  pixelFormat[1],
                  pixelFormat[2] ? "big" : "little",
                  pixelFormat[3],
                  smReadPixelFormatU16(pixelFormat + 4),
                  smReadPixelFormatU16(pixelFormat + 6),
                  smReadPixelFormatU16(pixelFormat + 8),
                  pixelFormat[10],
                  pixelFormat[11],
                  pixelFormat[12]);
            [self armFullFramebufferRequest];
            [[SMScreenCapture sharedCapture] resetCaptureThrottle];
            if (!smClientFormatIsReadyForPixels(_clientPixelFormat)) {
                smLog(@"Client pixel format not ready for screen data.");
                dispatch_async(_sendQueue, ^{
                    [self sendEmptyFramebufferUpdate];
                });
            }
            return YES;
        }
        case 2: {
            uint8_t padding[1];
            uint8_t countBytes[2];
            if (![self readExact:padding length:1] || ![self readExact:countBytes length:2]) {
                return NO;
            }
            uint16_t count = [self readU16BEFrom:countBytes];
            if (count > 256) {
                count = 256;
            }
            size_t payloadLength = (size_t)count * 4;
            NSMutableData *encodingData = [NSMutableData dataWithLength:payloadLength];
            if (![self readExact:encodingData.mutableBytes length:payloadLength]) {
                return NO;
            }

            _clientWantsLastRect = NO;
            const uint8_t *encodings = (const uint8_t *)encodingData.bytes;
            for (uint16_t index = 0; index < count; index++) {
                const int32_t encoding = smReadS32BEFrom(encodings + ((size_t)index * 4));
                if ((uint32_t)encoding == kSMEncodingLastRect) {
                    _clientWantsLastRect = YES;
                }
            }
            return YES;
        }
        case 3: {
            uint8_t request[9];
            if (![self readExact:request length:9]) {
                return NO;
            }
            _incrementalOnly = request[0] != 0;
            _updateX = [self readU16BEFrom:request + 1];
            _updateY = [self readU16BEFrom:request + 3];
            _updateWidth = [self readU16BEFrom:request + 5];
            _updateHeight = [self readU16BEFrom:request + 7];
            _wantsUpdates = YES;
            return YES;
        }
        case 4: {
            uint8_t payload[7];
            if (![self readExact:payload length:7]) {
                return NO;
            }
            const BOOL down = payload[0] != 0;
            const uint32_t keysym = [self readU32BEFrom:payload + 3];
            [[SMInputInjector sharedInjector] handleKeyEventWithDown:down keysym:keysym];
            return YES;
        }
        case 5: {
            uint8_t payload[5];
            if (![self readExact:payload length:5]) {
                return NO;
            }
            const uint8_t buttonMask = payload[0];
            const uint16_t x = [self readU16BEFrom:payload + 1];
            const uint16_t y = [self readU16BEFrom:payload + 3];
            [[SMInputInjector sharedInjector] handlePointerEventWithButtonMask:buttonMask
                                                                             x:x
                                                                             y:y
                                                                    frameWidth:_frameWidth
                                                                   frameHeight:_frameHeight];
            return YES;
        }
        case 6: {
            uint8_t padding[3];
            uint8_t lengthBytes[4];
            if (![self readExact:padding length:3] || ![self readExact:lengthBytes length:4]) {
                return NO;
            }
            uint32_t length = [self readU32BEFrom:lengthBytes];
            if (length > 0) {
                NSMutableData *skip = [NSMutableData dataWithLength:length];
                if (![self readExact:skip.mutableBytes length:length]) {
                    return NO;
                }
            }
            return YES;
        }
        default:
            smLog(@"Unknown client message type %u.", messageType);
            return NO;
    }
}

- (BOOL)sendEmptyFramebufferUpdate {
    if (![self writeU8:0]) {
        return NO;
    }
    uint8_t padding[1] = {0};
    return [self writeExact:padding length:1] && [self writeU16BE:0];
}

- (void)pushFramebufferUpdateOnSendQueue {
    if (_pushInFlight) {
        return;
    }
    _pushInFlight = YES;

    @try {
        os_unfair_lock_lock(&_sessionLock);
        if (_teardownStarted || !_running || !_authenticated || !_wantsUpdates || !_receivedClientPixelFormat) {
            os_unfair_lock_unlock(&_sessionLock);
            return;
        }

        if (!smClientFormatIsReadyForPixels(_clientPixelFormat)) {
            os_unfair_lock_unlock(&_sessionLock);
            return;
        }

        const NSUInteger serverWidth = _frameWidth;
        const NSUInteger serverHeight = _frameHeight;
        if (serverWidth == 0 || serverHeight == 0) {
            os_unfair_lock_unlock(&_sessionLock);
            return;
        }
        os_unfair_lock_unlock(&_sessionLock);

        __block SMScreenFrame *frame = nil;
        dispatch_sync(_captureQueue, ^{
            frame = [[SMScreenCapture sharedCapture] captureFrameWithTargetWidth:serverWidth
                                                                  targetHeight:serverHeight];
        });

        [self sendFramebufferUpdateWithFrame:frame];
    } @finally {
        _pushInFlight = NO;
    }
}

- (BOOL)sendFramebufferUpdateWithFrame:(SMScreenFrame *)frame {
    if (_teardownStarted) {
        return NO;
    }

    os_unfair_lock_lock(&_sessionLock);
    const BOOL shouldSend = !_teardownStarted && _running && _authenticated && _wantsUpdates;
    const NSUInteger serverWidth = _frameWidth;
    const NSUInteger serverHeight = _frameHeight;
    os_unfair_lock_unlock(&_sessionLock);

    if (!shouldSend) {
        return NO;
    }
    if (serverWidth == 0 || serverHeight == 0) {
        return NO;
    }

    if (!frame || frame.width == 0 || frame.height == 0) {
        smLog(@"Framebuffer update skipped: capture unavailable.");
        _wantsUpdates = YES;
        return [self sendEmptyFramebufferUpdate];
    }

    if (frame.width != serverWidth || frame.height != serverHeight) {
        smLog(@"Framebuffer size mismatch (got %lux%lu, expected %lux%lu).",
              (unsigned long)frame.width,
              (unsigned long)frame.height,
              (unsigned long)serverWidth,
              (unsigned long)serverHeight);
        _wantsUpdates = YES;
        return [self sendEmptyFramebufferUpdate];
    }

    const NSUInteger expectedBytes = serverWidth * serverHeight * 4;
    if (frame.bgraPixels.length < expectedBytes) {
        smLog(@"Framebuffer pixel buffer too small (%lu < %lu).",
              (unsigned long)frame.bgraPixels.length,
              (unsigned long)expectedBytes);
        _wantsUpdates = YES;
        return [self sendEmptyFramebufferUpdate];
    }

    uint16_t rectX = _updateX;
    uint16_t rectY = _updateY;
    uint16_t rectWidth = _updateWidth;
    uint16_t rectHeight = _updateHeight;
    smClampFramebufferRect(&rectX, &rectY, &rectWidth, &rectHeight, serverWidth, serverHeight);
    if (rectWidth == 0 || rectHeight == 0) {
        smLog(@"Framebuffer update skipped: empty rectangle.");
        return [self sendEmptyFramebufferUpdate];
    }

    const NSUInteger sourceStride = serverWidth * 4;
    const BOOL fullFrameRect = rectX == 0 && rectY == 0 && rectWidth == serverWidth && rectHeight == serverHeight;
    NSMutableData *rawPixels = nil;
    const uint8_t *wirePixels = NULL;
    NSUInteger wireLength = 0;

    if (smClientFormatIs32BitBGRx(_clientPixelFormat)) {
        if (fullFrameRect && frame.bgraPixels.length >= expectedBytes) {
            wirePixels = (const uint8_t *)frame.bgraPixels.bytes;
            wireLength = expectedBytes;
        } else {
            rawPixels = [NSMutableData dataWithLength:(NSUInteger)rectWidth * rectHeight * 4];
            smCopyRectTo32BitBGRx((const uint8_t *)frame.bgraPixels.bytes,
                                  sourceStride,
                                  (uint8_t *)rawPixels.mutableBytes,
                                  rectX,
                                  rectY,
                                  rectWidth,
                                  rectHeight);
            wirePixels = (const uint8_t *)rawPixels.bytes;
            wireLength = rawPixels.length;
        }
    } else {
        rawPixels = smEncodeRectPixelsForClientFormat((const uint8_t *)frame.bgraPixels.bytes,
                                                      sourceStride,
                                                      rectX,
                                                      rectY,
                                                      rectWidth,
                                                      rectHeight,
                                                      _clientPixelFormat);
        if (rawPixels) {
            wirePixels = (const uint8_t *)rawPixels.bytes;
            wireLength = rawPixels.length;
        }
    }

    if (!wirePixels || wireLength == 0) {
        _wantsUpdates = YES;
        return [self sendEmptyFramebufferUpdate];
    }

    const NSUInteger expectedWireBytes = (NSUInteger)rectWidth * rectHeight * (_clientPixelFormat[0] / 8);
    if (wireLength != expectedWireBytes) {
        _wantsUpdates = YES;
        return [self sendEmptyFramebufferUpdate];
    }

    const uint16_t rectangleCount = _clientWantsLastRect ? 2 : 1;
    if (![self writeU8:0]) {
        return NO;
    }
    uint8_t padding[1] = {0};
    if (![self writeExact:padding length:1] || ![self writeU16BE:rectangleCount]) {
        return NO;
    }

    if (![self writeU16BE:rectX] || ![self writeU16BE:rectY] || ![self writeU16BE:rectWidth] || ![self writeU16BE:rectHeight] ||
        ![self writeU32BE:kSMEncodingRaw]) {
        return NO;
    }

    if (![self writeExact:wirePixels length:wireLength]) {
        smLog(@"Framebuffer write failed (errno %d).", errno);
        dispatch_async(_queue, ^{
            [self teardownLocked];
        });
        return NO;
    }

    if (_clientWantsLastRect) {
        if (![self writeU16BE:0] || ![self writeU16BE:0] || ![self writeU16BE:0] || ![self writeU16BE:0] ||
            ![self writeU32BE:kSMEncodingLastRect]) {
            return NO;
        }
    }

    _wantsUpdates = YES;
    return YES;
}

@end
