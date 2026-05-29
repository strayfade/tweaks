#import "SCConnection.h"
#import "SCCommon.h"
#import "SCStreamRunLoop.h"
#import <CommonCrypto/CommonDigest.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static uint32_t scReadUInt32BE(const uint8_t *bytes) {
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | (uint32_t)bytes[3];
}

static NSData *scWriteUInt32BE(uint32_t value) {
    uint8_t bytes[4];
    bytes[0] = (value >> 24) & 0xFF;
    bytes[1] = (value >> 16) & 0xFF;
    bytes[2] = (value >> 8) & 0xFF;
    bytes[3] = value & 0xFF;
    return [NSData dataWithBytes:bytes length:4];
}

@interface SCConnection () <NSStreamDelegate>
@property (nonatomic, assign) int socketFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSInputStream *inputStream;
@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, strong) NSMutableArray<NSData *> *pendingWrites;
@property (nonatomic, assign) BOOL writing;
@property (nonatomic, copy) NSString *peerIdentifier;
@property (nonatomic, copy) NSString *peerPlatform;
@end

@implementation SCConnection

- (instancetype)initWithSocketFD:(int)socketFD queue:(dispatch_queue_t)queue {
    self = [super init];
    if (!self) {
        if (socketFD >= 0) {
            close(socketFD);
        }
        return nil;
    }

    _socketFD = socketFD;
    _queue = queue;
    _readBuffer = [NSMutableData data];
    _pendingWrites = [NSMutableArray array];
    _peerIdentifier = @"";
    _peerPlatform = @"unknown";

    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketFD, &readStream, &writeStream);
    if (!readStream || !writeStream) {
        [self close];
        return nil;
    }

    _inputStream = (__bridge_transfer NSInputStream *)readStream;
    _outputStream = (__bridge_transfer NSOutputStream *)writeStream;
    _inputStream.delegate = self;
    _outputStream.delegate = self;
    scStreamRunLoopPerformSync(^{
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [_inputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
        [_outputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
        [_inputStream open];
        [_outputStream open];
    });

    return self;
}

- (instancetype)initWithResolvedService:(NSNetService *)service queue:(dispatch_queue_t)queue {
    NSInputStream *inputStream = nil;
    NSOutputStream *outputStream = nil;
    if (![service getInputStream:&inputStream outputStream:&outputStream] || !inputStream || !outputStream) {
        return nil;
    }

    self = [super init];
    if (!self) {
        return nil;
    }

    _socketFD = -1;
    _queue = queue;
    _readBuffer = [NSMutableData data];
    _pendingWrites = [NSMutableArray array];
    _peerIdentifier = @"";
    _peerPlatform = @"unknown";
    _inputStream = inputStream;
    _outputStream = outputStream;
    _inputStream.delegate = self;
    _outputStream.delegate = self;
    scStreamRunLoopPerformSync(^{
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [_inputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
        [_outputStream scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
        [_inputStream open];
        [_outputStream open];
    });

    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    NSInputStream *inputStream = _inputStream;
    NSOutputStream *outputStream = _outputStream;
    int socketFD = _socketFD;
    _inputStream = nil;
    _outputStream = nil;
    _socketFD = -1;

    scStreamRunLoopPerformSync(^{
        if (inputStream) {
            [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            [inputStream close];
        }
        if (outputStream) {
            [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            [outputStream close];
        }
    });

    if (socketFD >= 0) {
        close(socketFD);
    }
}

- (void)sendMessage:(NSDictionary *)message {
    if (!message) {
        return;
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!jsonData || error || jsonData.length > kSCMaxPayloadSize) {
        return;
    }

    NSMutableData *frame = [NSMutableData dataWithData:scWriteUInt32BE((uint32_t)jsonData.length)];
    [frame appendData:jsonData];

    scStreamRunLoopPerform(^{
        if (!self.outputStream || self.outputStream.streamStatus == NSStreamStatusClosed) {
            return;
        }
        [self.pendingWrites addObject:frame];
        [self flushPendingWrites];
    });
}

- (void)flushPendingWrites {
    if (self.writing || self.pendingWrites.count == 0 || !self.outputStream) {
        return;
    }

    while (self.pendingWrites.count > 0) {
        NSData *frame = self.pendingWrites.firstObject;
        const uint8_t *bytes = (const uint8_t *)frame.bytes;
        NSInteger remaining = (NSInteger)frame.length;
        NSInteger offset = 0;

        while (remaining > 0) {
            NSInteger written = [self.outputStream write:bytes + offset maxLength:(NSUInteger)remaining];
            if (written < 0) {
                [self handleStreamClosed];
                return;
            }
            if (written == 0) {
                self.writing = YES;
                return;
            }
            offset += written;
            remaining -= written;
        }

        [self.pendingWrites removeObjectAtIndex:0];
    }
}

- (void)processReadBuffer {
    while (self.readBuffer.length >= 4) {
        const uint8_t *bytes = (const uint8_t *)self.readBuffer.bytes;
        uint32_t payloadLength = scReadUInt32BE(bytes);
        if (payloadLength == 0 || payloadLength > kSCMaxPayloadSize) {
            [self handleStreamClosed];
            return;
        }

        NSUInteger frameLength = 4 + payloadLength;
        if (self.readBuffer.length < frameLength) {
            return;
        }

        NSData *payload = [self.readBuffer subdataWithRange:NSMakeRange(4, payloadLength)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, frameLength) withBytes:NULL length:0];

        id jsonObject = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if (![jsonObject isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSDictionary *message = (NSDictionary *)jsonObject;
        NSString *type = [message[@"type"] isKindOfClass:[NSString class]] ? message[@"type"] : @"";
        if ([type isEqualToString:@"hello"]) {
            NSString *peerID = [message[@"deviceId"] isKindOfClass:[NSString class]] ? message[@"deviceId"] : @"";
            NSString *platform = [message[@"platform"] isKindOfClass:[NSString class]] ? message[@"platform"] : @"unknown";
            self.peerIdentifier = peerID;
            self.peerPlatform = platform;
            continue;
        }

        id<SCConnectionDelegate> delegate = self.delegate;
        dispatch_queue_t queue = self.queue;
        if (delegate && queue) {
            dispatch_async(queue, ^{
                [delegate connection:self didReceiveMessage:message];
            });
        }
    }
}

- (void)handleStreamClosed {
    [self close];
    id<SCConnectionDelegate> delegate = self.delegate;
    dispatch_queue_t queue = self.queue;
    if (delegate && queue) {
        dispatch_async(queue, ^{
            [delegate connectionDidClose:self];
        });
    }
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventOpenCompleted:
            if (aStream == self.outputStream) {
                [self sendMessage:@{
                    @"v": @(kSCProtocolVersion),
                    @"type": @"hello",
                    @"deviceId": scDeviceIdentifier(),
                    @"platform": @"ios",
                }];
            }
            break;
        case NSStreamEventHasBytesAvailable: {
            if (aStream != self.inputStream) {
                break;
            }
            uint8_t buffer[8192];
            while (self.inputStream.hasBytesAvailable) {
                NSInteger read = [self.inputStream read:buffer maxLength:sizeof(buffer)];
                if (read < 0) {
                    [self handleStreamClosed];
                    return;
                }
                if (read == 0) {
                    break;
                }
                [self.readBuffer appendBytes:buffer length:(NSUInteger)read];
            }
            [self processReadBuffer];
            break;
        }
        case NSStreamEventHasSpaceAvailable:
            self.writing = NO;
            [self flushPendingWrites];
            break;
        case NSStreamEventErrorOccurred:
        case NSStreamEventEndEncountered:
            [self handleStreamClosed];
            break;
        default:
            break;
    }
}

@end
