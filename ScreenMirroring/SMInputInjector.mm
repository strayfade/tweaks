#import "SMInputInjector.h"
#import "SMCommon.h"
#import "SMIOKitSPI.h"
#import "SMHIDUsages.h"
#import "SMHardwareKeys.h"
#import "SMKeysymMap.h"
#import "SMScreenCapture.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <unistd.h>

static const CGFloat kSMWheelStepPx = 80.0f;
static const IOHIDFloat kSMDefaultMajorRadius = 5.0f;
static const IOHIDFloat kSMDefaultPathPressure = 0.0f;
static const int kSMMaxTouchCount = 1;
static const int kSMFingerIdentifier = 2;
static const uint64_t kSMIOHIDSenderID = 0x8000000817319371ULL;

typedef enum {
    SMHandEventTouched,
    SMHandEventMoved,
    SMHandEventLifted,
} SMHandEventType;

typedef struct {
    int identifier;
    CGPoint point;
    IOHIDFloat pathMajorRadius;
    IOHIDFloat pathPressure;
    UInt8 pathProximity;
} SMActiveTouchPoint;

typedef void (*SMBKSHIDEventSendToSystemProcessFunc)(IOHIDEventRef event);

@implementation SMInputInjector {
    dispatch_queue_t _hidQueue;
    CGSize _physicalScreenSize;
    SMActiveTouchPoint _activePoints[kSMMaxTouchCount];
    NSUInteger _activePointCount;
    uint8_t _prevButtonMask;
    BOOL _keyboardReady;
    BOOL _touchReady;
    SMBKSHIDEventSendToSystemProcessFunc _bksSendToSystem;
}

+ (instancetype)sharedInjector {
    static SMInputInjector *injector = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        injector = [[SMInputInjector alloc] init];
    });
    return injector;
}

- (void)prepareOnMainThreadIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshPhysicalScreenSize];
    });
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    for (NSUInteger i = 0; i < kSMMaxTouchCount; ++i) {
        _activePoints[i].identifier = kSMFingerIdentifier;
    }

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL_WITH_AUTORELEASE_POOL,
                                                                         QOS_CLASS_USER_INTERACTIVE,
                                                                         0);
    _hidQueue = dispatch_queue_create("com.strayfade.screenmirroring.hid-events", attr);

    void *bksHandle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    if (!bksHandle) {
        const char *roots[] = {"/var/jb", "/cores/binpack", NULL};
        for (size_t index = 0; roots[index] != NULL; index++) {
            char path[512];
            snprintf(path, sizeof(path), "%s/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
                     roots[index]);
            bksHandle = dlopen(path, RTLD_NOW);
            if (bksHandle) {
                break;
            }
        }
    }
    if (bksHandle) {
        _bksSendToSystem = (SMBKSHIDEventSendToSystemProcessFunc)dlsym(bksHandle, "BKSHIDEventSendToSystemProcess");
    }

    if ([NSThread isMainThread]) {
        [self refreshPhysicalScreenSize];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshPhysicalScreenSize];
        });
    }

    _touchReady = YES;
    _keyboardReady = YES;

    smLog(@"Touch injection ready (screen %.0fx%.0f, IOHID+BKS=%s).",
          _physicalScreenSize.width,
          _physicalScreenSize.height,
          _bksSendToSystem ? "yes" : "no");
    smLog(@"Keyboard injection ready via IOHIDEventSystemClient.");

    return self;
}

- (void)refreshPhysicalScreenSize {
    const CGSize native = [[SMScreenCapture sharedCapture] nativeSizeInPixels];
    if (native.width >= 1.0f && native.height >= 1.0f) {
        _physicalScreenSize = native;
    } else if (_physicalScreenSize.width < 1.0f || _physicalScreenSize.height < 1.0f) {
        _physicalScreenSize = CGSizeMake(1.0f, 1.0f);
    }
}

static IOHIDEventSystemClientRef smSharedHIDClient(void) {
    static IOHIDEventSystemClientRef client = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    });
    return client;
}

- (void)dispatchTouchEvent:(IOHIDEventRef)event {
    if (!event || !_touchReady) {
        if (event) {
            CFRelease(event);
        }
        return;
    }

    IOHIDEventSetSenderID(event, kSMIOHIDSenderID);

    IOHIDEventSystemClientRef client = smSharedHIDClient();
    if (client) {
        IOHIDEventSystemClientDispatchEvent(client, event);
    }

    if (_bksSendToSystem) {
        IOHIDEventRef bksEvent = (IOHIDEventRef)CFRetain(event);
        _bksSendToSystem(bksEvent);
        CFRelease(bksEvent);
    }

    CFRelease(event);
}

- (void)dispatchHIDEvent:(IOHIDEventRef)event {
    if (!event || !_keyboardReady) {
        if (event) {
            CFRelease(event);
        }
        return;
    }

    IOHIDEventSetSenderID(event, kSMIOHIDSenderID);
    IOHIDEventSystemClientRef client = smSharedHIDClient();
    if (client) {
        IOHIDEventSystemClientDispatchEvent(client, event);
    }

    if (_bksSendToSystem) {
        IOHIDEventRef bksEvent = (IOHIDEventRef)CFRetain(event);
        _bksSendToSystem(bksEvent);
        CFRelease(bksEvent);
    }

    CFRelease(event);
}

- (void)dispatchKeyboardEvent:(IOHIDEventRef)event {
    [self dispatchHIDEvent:event];
}

- (CGPoint)vncPointToDevicePointWithX:(uint16_t)vx
                                    y:(uint16_t)vy
                            vncWidth:(NSUInteger)vncWidth
                           vncHeight:(NSUInteger)vncHeight {
    [self refreshPhysicalScreenSize];

    if (vncWidth == 0 || vncHeight == 0) {
        return CGPointZero;
    }

    const double srcWidth = (double)_physicalScreenSize.width;
    const double srcHeight = (double)_physicalScreenSize.height;

    double dx = ((double)vx * srcWidth) / (double)vncWidth;
    double dy = ((double)vy * srcHeight) / (double)vncHeight;

    if (dx < 0.0) {
        dx = 0.0;
    }
    if (dy < 0.0) {
        dy = 0.0;
    }
    if (dx > srcWidth - 1.0) {
        dx = srcWidth - 1.0;
    }
    if (dy > srcHeight - 1.0) {
        dy = srcHeight - 1.0;
    }

    return CGPointMake((CGFloat)dx, (CGFloat)dy);
}

- (IOHIDEventRef)createDigitizerEventForHandEventType:(SMHandEventType)eventType {
    const BOOL isTouching = (eventType == SMHandEventTouched || eventType == SMHandEventMoved);

    IOHIDDigitizerEventMask eventMask = kIOHIDDigitizerEventTouch;
    if (eventType == SMHandEventMoved) {
        eventMask &= ~kIOHIDDigitizerEventTouch;
        eventMask |= kIOHIDDigitizerEventPosition;
        eventMask |= kIOHIDDigitizerEventAttribute;
    } else if (eventType == SMHandEventTouched || eventType == SMHandEventLifted) {
        eventMask |= kIOHIDDigitizerEventIdentity;
    }

    const uint64_t machTime = mach_absolute_time();
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                          machTime,
                                                          kIOHIDDigitizerTransducerTypeHand,
                                                          0,
                                                          0,
                                                          eventMask,
                                                          0,
                                                          0,
                                                          0,
                                                          0,
                                                          0,
                                                          0,
                                                          0,
                                                          isTouching,
                                                          kIOHIDEventOptionNone);
    if (!parent) {
        return NULL;
    }

    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldIsBuiltIn, 1);
    IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    for (NSUInteger i = 0; i < _activePointCount; ++i) {
        SMActiveTouchPoint *pointInfo = &_activePoints[i];
        if (eventType == SMHandEventTouched) {
            if (!pointInfo->pathMajorRadius) {
                pointInfo->pathMajorRadius = kSMDefaultMajorRadius;
            }
            if (!pointInfo->pathPressure) {
                pointInfo->pathPressure = kSMDefaultPathPressure;
            }
            if (!pointInfo->pathProximity) {
                pointInfo->pathProximity = kGSEventPathInfoInTouch | kGSEventPathInfoInRange;
            }
        } else if (eventType == SMHandEventLifted) {
            pointInfo->pathMajorRadius = 0;
            pointInfo->pathPressure = 0;
            pointInfo->pathProximity = 0;
        }

        CGPoint point = pointInfo->point;
        point = CGPointMake(point.x / _physicalScreenSize.width, point.y / _physicalScreenSize.height);

        IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                                   machTime,
                                                                   (uint32_t)pointInfo->identifier,
                                                                   (uint32_t)pointInfo->identifier,
                                                                   eventMask,
                                                                   (IOHIDFloat)point.x,
                                                                   (IOHIDFloat)point.y,
                                                                   0.0f,
                                                                   pointInfo->pathPressure,
                                                                   90.0f,
                                                                   (pointInfo->pathProximity & kGSEventPathInfoInRange) != 0,
                                                                   (pointInfo->pathProximity & kGSEventPathInfoInTouch) != 0,
                                                                   kIOHIDEventOptionNone);
        if (!child) {
            CFRelease(parent);
            return NULL;
        }

        IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMinorRadius, pointInfo->pathMajorRadius);
        IOHIDEventSetFloatValue(child, kIOHIDEventFieldDigitizerMajorRadius, pointInfo->pathMajorRadius);

        IOHIDEventAppendEvent(parent, child, 0);
        CFRelease(child);
    }

    return parent;
}

- (void)sendHandEventType:(SMHandEventType)eventType {
    IOHIDEventRef event = [self createDigitizerEventForHandEventType:eventType];
    if (event) {
        [self dispatchTouchEvent:event];
    }
}

- (void)touchDownAtDevicePoint:(CGPoint)devicePoint {
    _activePointCount = 1;
    _activePoints[0].point = devicePoint;
    _activePoints[0].pathMajorRadius = 0;
    _activePoints[0].pathPressure = 0;
    _activePoints[0].pathProximity = 0;
    [self sendHandEventType:SMHandEventTouched];
}

- (void)updateTouchAtDevicePoint:(CGPoint)devicePoint {
    _activePoints[0].point = devicePoint;
    [self sendHandEventType:SMHandEventMoved];
}

- (void)liftUpAtDevicePoint:(CGPoint)devicePoint {
    _activePoints[0].point = devicePoint;
    [self sendHandEventType:SMHandEventLifted];
    _activePointCount = 0;
}

- (void)performScrollFromDevicePoint:(CGPoint)start deltaY:(CGFloat)deltaY {
    CGFloat endY = start.y + deltaY;
    if (endY < 0.0f) {
        endY = 0.0f;
    }
    if (endY > _physicalScreenSize.height - 1.0f) {
        endY = _physicalScreenSize.height - 1.0f;
    }

    const CGPoint endPoint = CGPointMake(start.x, endY);
    [self touchDownAtDevicePoint:start];
    usleep(16000);
    [self updateTouchAtDevicePoint:endPoint];
    usleep(16000);
    [self liftUpAtDevicePoint:endPoint];
}

- (void)handlePointerEventLockedWithButtonMask:(uint8_t)buttonMask
                                             x:(uint16_t)x
                                             y:(uint16_t)y
                                    devicePoint:(CGPoint)devicePoint
                                     frameWidth:(NSUInteger)frameWidth
                                    frameHeight:(NSUInteger)frameHeight {
    const BOOL leftNow = (buttonMask & 0x1) != 0;
    const BOOL leftPrev = (_prevButtonMask & 0x1) != 0;
    const BOOL wheelUpNow = (buttonMask & 0x8) != 0;
    const BOOL wheelDnNow = (buttonMask & 0x10) != 0;
    const BOOL wheelUpPrev = (_prevButtonMask & 0x8) != 0;
    const BOOL wheelDnPrev = (_prevButtonMask & 0x10) != 0;

    if (leftNow && !leftPrev) {
        [self touchDownAtDevicePoint:devicePoint];
    } else if (!leftNow && leftPrev) {
        [self liftUpAtDevicePoint:devicePoint];
    } else if (leftNow) {
        [self updateTouchAtDevicePoint:devicePoint];
    }

    if (wheelUpNow && !wheelUpPrev) {
        [self performScrollFromDevicePoint:devicePoint deltaY:-kSMWheelStepPx];
    } else if (wheelDnNow && !wheelDnPrev) {
        [self performScrollFromDevicePoint:devicePoint deltaY:kSMWheelStepPx];
    }

    _prevButtonMask = buttonMask;
}

- (void)handlePointerEventWithButtonMask:(uint8_t)buttonMask
                                       x:(uint16_t)x
                                       y:(uint16_t)y
                              frameWidth:(NSUInteger)frameWidth
                             frameHeight:(NSUInteger)frameHeight {
    if (!_touchReady || frameWidth == 0 || frameHeight == 0) {
        return;
    }

    const CGPoint devicePoint = [self vncPointToDevicePointWithX:x
                                                               y:y
                                                       vncWidth:frameWidth
                                                      vncHeight:frameHeight];

    dispatch_sync(_hidQueue, ^{
        [self handlePointerEventLockedWithButtonMask:buttonMask
                                                   x:x
                                                   y:y
                                           devicePoint:devicePoint
                                            frameWidth:frameWidth
                                           frameHeight:frameHeight];
    });
}

- (void)performHomeScreenAction {
    [self pulseConsumerUsage:kHIDUsage_Csmr_Menu];
}

- (void)performAppSwitcherAction {
    __block BOOL usedSpringBoardAPI = NO;
    if ([NSThread isMainThread]) {
        usedSpringBoardAPI = [self toggleAppSwitcherViaSpringBoardIfAvailable];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            usedSpringBoardAPI = [self toggleAppSwitcherViaSpringBoardIfAvailable];
        });
    }

    if (!usedSpringBoardAPI) {
        [self pulseConsumerUsage:kHIDUsage_Csmr_Menu];
        usleep(80000);
        [self pulseConsumerUsage:kHIDUsage_Csmr_Menu];
    }
}

- (BOOL)toggleAppSwitcherViaSpringBoardIfAvailable {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if (!controllerClass) {
        return NO;
    }

    id controller = ((id (*)(Class, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance));
    if (!controller) {
        return NO;
    }

    SEL toggleSelector = NSSelectorFromString(@"_toggleSwitcher");
    if ([controller respondsToSelector:toggleSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, toggleSelector);
        return YES;
    }

    SEL activateSelector = NSSelectorFromString(@"activateSwitcher");
    if ([controller respondsToSelector:activateSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, activateSelector);
        return YES;
    }

    SEL activateFromSideSelector = NSSelectorFromString(@"_activateAppSwitcherFromSide:");
    if ([controller respondsToSelector:activateFromSideSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, activateFromSideSelector, (NSInteger)2);
        return YES;
    }

    return NO;
}

- (void)pulseConsumerUsage:(uint32_t)usage {
    IOHIDEventRef downEvent = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                            mach_absolute_time(),
                                                            kHIDPage_Consumer,
                                                            usage,
                                                            true,
                                                            kIOHIDEventOptionNone);
    if (downEvent) {
        [self dispatchHIDEvent:downEvent];
    }

    usleep(16000);

    IOHIDEventRef upEvent = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                          mach_absolute_time(),
                                                          kHIDPage_Consumer,
                                                          usage,
                                                          false,
                                                          kIOHIDEventOptionNone);
    if (upEvent) {
        [self dispatchHIDEvent:upEvent];
    }
}

- (void)performHardwareButtonAction:(SMHardwareButtonAction)action {
    uint32_t usage = 0;
    switch (action) {
        case SMHardwareButtonActionVolumeUp:
            usage = kHIDUsage_Csmr_VolumeIncrement;
            break;
        case SMHardwareButtonActionVolumeDown:
            usage = kHIDUsage_Csmr_VolumeDecrement;
            break;
        case SMHardwareButtonActionSideButton:
            usage = kHIDUsage_Csmr_Power;
            break;
        case SMHardwareButtonActionHome:
            [self performHomeScreenAction];
            return;
        case SMHardwareButtonActionAppSwitcher:
            [self performAppSwitcherAction];
            return;
        case SMHardwareButtonActionNone:
            return;
    }

    [self pulseConsumerUsage:usage];
}

- (void)handleKeyEventWithDown:(BOOL)down keysym:(uint32_t)keysym {
    if (!_keyboardReady) {
        return;
    }

    const SMHardwareButtonAction hardwareAction = smHardwareButtonActionForKeysym(keysym);
    if (hardwareAction != SMHardwareButtonActionNone) {
        if (!down) {
            return;
        }
        dispatch_async(_hidQueue, ^{
            [self performHardwareButtonAction:hardwareAction];
        });
        return;
    }

    const uint32_t usage = smHIDUsageForKeysym(keysym);
    if (usage == 0) {
        return;
    }

    IOHIDEventRef event = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                      mach_absolute_time(),
                                                      kSMHIDPage_KeyboardOrKeypad,
                                                      (uint32_t)usage,
                                                      down,
                                                      kIOHIDEventOptionNone);
    if (!event) {
        return;
    }

    dispatch_async(_hidQueue, ^{
        [self dispatchKeyboardEvent:event];
    });
}

@end
