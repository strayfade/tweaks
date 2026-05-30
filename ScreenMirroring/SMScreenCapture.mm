#import "SMScreenCapture.h"
#import "SMCommon.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <QuartzCore/QuartzCore.h>

// SpringBoard capture: IOMobileFramebufferSwapSetLayer hook -> untile compositor IOSurface -> scale to VNC.
// CARenderServer APIs remain for optional diagnostics only; they do not work reliably in SpringBoard.

@interface UIImage (ScreenMirroringPrivate)
+ (UIImage *)_UICreateScreenUIImage;
@end

@interface UIScreen (ScreenMirroringPrivate)
- (CGRect)_unjailedReferenceBoundsInPixels;
@end

typedef struct __IOSurface *IOSurfaceRef;
typedef struct __IOSurfaceAccelerator *IOSurfaceAcceleratorRef;
typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;
typedef kern_return_t (*SMIOMFBGetMainDisplayFunc)(IOMobileFramebufferRef *display);
typedef kern_return_t (*SMIOMFBGetLayerDefaultSurfaceFunc)(IOMobileFramebufferRef display, int layer, IOSurfaceRef *buffer);

typedef CFIndex (*SMCARenderServerGetDirtyFrameCountFunc)(void *unknown);
typedef void (*SMCARenderServerRenderDisplayFunc)(int display, CFStringRef framebuffer, IOSurfaceRef surface, int unknown1, int unknown2);
typedef IOSurfaceRef (*SMIOSurfaceCreateFunc)(CFDictionaryRef properties);
typedef int (*SMIOSurfaceLockFunc)(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
typedef int (*SMIOSurfaceUnlockFunc)(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
typedef void *(*SMIOSurfaceGetBaseAddressFunc)(IOSurfaceRef surface);
typedef size_t (*SMIOSurfaceGetBytesPerRowFunc)(IOSurfaceRef surface);
typedef size_t (*SMIOSurfaceGetWidthFunc)(IOSurfaceRef surface);
typedef size_t (*SMIOSurfaceGetHeightFunc)(IOSurfaceRef surface);
typedef size_t (*SMIOSurfaceAlignPropertyFunc)(CFStringRef property, size_t value);
typedef kern_return_t (*SMIOSurfaceAcceleratorCreateFunc)(CFAllocatorRef allocator, CFDictionaryRef options, IOSurfaceAcceleratorRef *accelerator);
typedef kern_return_t (*SMIOSurfaceAcceleratorTransferSurfaceFunc)(IOSurfaceAcceleratorRef accelerator,
                                                                     IOSurfaceRef source,
                                                                     IOSurfaceRef destination,
                                                                     CFArrayRef filters,
                                                                     CFDictionaryRef sourceSync,
                                                                     CFDictionaryRef destinationSync,
                                                                     CFDictionaryRef copySpec);
typedef CFRunLoopSourceRef (*SMIOSurfaceAcceleratorGetRunLoopSourceFunc)(IOSurfaceAcceleratorRef accelerator);
typedef void (*SMIOSurfaceFlushFunc)(IOSurfaceRef surface, uint32_t options);

static const uint32_t kSMIOSurfaceLockReadOnly = 0x00000001;
static const uint32_t kSMPixelFormatBGRA = 0x42475242; // 'BGRA' — matches Veency / VNC wire layout
static const CGBitmapInfo kSMVNCBitmapInfo = (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

static CFIndex gSMDirtyFrameCount = -1;

// Display layer IOSurfaces use 64x16 pixel tiles; linear memcpy produces black/garbage (Veency).
static void smCopy64x16BlockedImage(uint8_t *destination, const uint8_t *source, size_t width, size_t height) {
    if (!destination || !source || width == 0 || height == 0) {
        return;
    }

    const uint8_t *const fromEnd = source + (4 * width * height);
    uint8_t *const toEnd = destination + (4 * width * height);
    uint8_t *toLine = destination;
    const uint8_t *from = source;

    while (from < fromEnd) {
        size_t toXOffset = 0;
        while (toXOffset < (width * 4)) {
            size_t toLineOffset = 0;
            while (toLineOffset < 16) {
                uint8_t *toPtr = toLine + toXOffset + (4 * width * toLineOffset);
                if ((toPtr + (64 * 4)) <= toEnd && (from + (64 * 4)) <= fromEnd) {
                    memcpy(toPtr, from, 64 * 4);
                }
                toLineOffset++;
                from += 64 * 4;
            }
            toXOffset += 64 * 4;
        }
        toLine += 16 * 4 * width;
    }
}

static BOOL smSampleFrameHasVisibleContent(const uint8_t *pixels, size_t width, size_t height, size_t stride) {
    if (!pixels || width == 0 || height == 0) {
        return NO;
    }

    uint64_t sum = 0;
    size_t samples = 0;
    for (size_t y = 0; y < height; y += 48) {
        for (size_t x = 0; x < width; x += 48) {
            const uint8_t *pixel = pixels + (y * stride) + (x * 4);
            sum += (uint64_t)pixel[0] + pixel[1] + pixel[2];
            samples++;
        }
    }
    return samples > 0 && ((sum / samples) > 8);
}

@interface SMScreenFrame ()
@property (nonatomic, assign, readwrite) NSUInteger width;
@property (nonatomic, assign, readwrite) NSUInteger height;
@property (nonatomic, strong, readwrite) NSData *bgraPixels;
@end

@implementation SMScreenFrame
@end

static void smFillOpaqueAlphaChannel(uint8_t *pixels, size_t width, size_t height, size_t stride) {
    if (!pixels || width == 0 || height == 0) {
        return;
    }

    const size_t rowBytes = stride > 0 ? stride : width * 4;
    for (size_t row = 0; row < height; row++) {
        uint8_t *rowPixels = pixels + row * rowBytes;
        for (size_t column = 0; column < width; column++) {
            rowPixels[(column * 4) + 3] = 255;
        }
    }
}

static void smCapFrameDimensions(NSUInteger *width, NSUInteger *height) {
    const size_t maxPixels = 640 * 360;
    if (*width == 0 || *height == 0) {
        return;
    }
    if ((*width * *height) <= maxPixels) {
        return;
    }
    const double shrink = sqrt((double)maxPixels / (double)(*width * *height));
    *width = MAX((NSUInteger)((double)*width * shrink), 1);
    *height = MAX((NSUInteger)((double)*height * shrink), 1);
}

static NSTimeInterval smCaptureMinInterval(void) {
    const double frameRate = smPreferredFrameRate();
    return frameRate > 0.0 ? (1.0 / frameRate) : (1.0 / 30.0);
}

@implementation SMScreenCapture {
    dispatch_queue_t _captureQueue;
    NSTimeInterval _lastCaptureTime;
    NSTimeInterval _lastIomfbIngestTime;
    NSTimeInterval _lastDisplayLayerTime;
    SMScreenFrame *_cachedFrame;
    NSMutableData *_reusedStreamingPixels;
    NSMutableData *_nativePixelScratch;
    NSUInteger _cachedWidth;
    NSUInteger _cachedHeight;
    NSUInteger _reusedStreamingWidth;
    NSUInteger _reusedStreamingHeight;
    NSUInteger _nativeScratchWidth;
    NSUInteger _nativeScratchHeight;
    NSUInteger _nativeWidth;
    NSUInteger _nativeHeight;
    NSUInteger _compositorWidth;
    NSUInteger _compositorHeight;
    NSDictionary *_renderProperties;
    IOSurfaceRef _renderSurface;
    IOSurfaceRef _scratchSurface;
    IOSurfaceRef _displaySurface;
    IOSurfaceRef _lastDisplayLayer;
    CADisplayLink *_displayLink;
    BOOL _streamingActive;
    BOOL _iomfbFrameReady;
    BOOL _iomfbFrameDirty;
    NSMutableData *_untileBuffer;
    BOOL _loggedBlackCARender;
    BOOL _loggedBlackIomfb;
    BOOL _loggedAccelFailure;
    BOOL _loggedIomfbIngestOK;
    BOOL _loggedIomfbPollFail;
    BOOL _loggedWindowCaptureFail;
    os_unfair_lock _surfaceLockGuard;
    SMIOSurfaceFlushFunc _surfaceFlush;
    SMCARenderServerGetDirtyFrameCountFunc _getDirtyFrameCount;
    SMCARenderServerRenderDisplayFunc _renderDisplay;
    SMIOSurfaceCreateFunc _surfaceCreate;
    SMIOSurfaceLockFunc _surfaceLock;
    SMIOSurfaceUnlockFunc _surfaceUnlock;
    SMIOSurfaceGetBaseAddressFunc _surfaceGetBaseAddress;
    SMIOSurfaceGetBytesPerRowFunc _surfaceGetBytesPerRow;
    SMIOSurfaceGetWidthFunc _surfaceGetWidth;
    SMIOSurfaceGetHeightFunc _surfaceGetHeight;
    SMIOSurfaceAlignPropertyFunc _surfaceAlignProperty;
    SMIOSurfaceAcceleratorCreateFunc _acceleratorCreate;
    SMIOSurfaceAcceleratorTransferSurfaceFunc _acceleratorTransfer;
    SMIOSurfaceAcceleratorGetRunLoopSourceFunc _acceleratorRunLoopSource;
    IOSurfaceAcceleratorRef _accelerator;
    BOOL _surfaceCaptureReady;
    BOOL _acceleratorReady;
    BOOL _asyncCaptureInFlight;
    NSUInteger _asyncCaptureWidth;
    NSUInteger _asyncCaptureHeight;
    NSMutableArray<void (^)(SMScreenFrame *)> *_asyncCaptureCompletions;
}

+ (instancetype)sharedCapture {
    static SMScreenCapture *capture = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        capture = [[SMScreenCapture alloc] init];
    });
    return capture;
}

- (void)releaseSurfacesLocked {
    if (_renderSurface) {
        CFRelease(_renderSurface);
        _renderSurface = NULL;
    }
    if (_scratchSurface) {
        CFRelease(_scratchSurface);
        _scratchSurface = NULL;
    }
    if (_displaySurface) {
        CFRelease(_displaySurface);
        _displaySurface = NULL;
    }
    _renderProperties = nil;
    _iomfbFrameReady = NO;
    _compositorWidth = 0;
    _compositorHeight = 0;
}

- (BOOL)ensureCompositorDisplaySurfaceLocked:(size_t)width height:(size_t)height {
    if (width == 0 || height == 0 || !_surfaceCaptureReady) {
        return NO;
    }

    if (_compositorWidth == width && _compositorHeight == height && _displaySurface) {
        return YES;
    }

    if (_displaySurface) {
        CFRelease(_displaySurface);
        _displaySurface = NULL;
    }

    NSDictionary *displayProperties =
        [self surfacePropertiesForWidth:(int)width height:(int)height purpleEDRAM:NO];
    _displaySurface = _surfaceCreate((__bridge CFDictionaryRef)displayProperties);
    if (!_displaySurface) {
        smLog(@"IOSurfaceCreate failed for compositor buffer %zux%zu.", width, height);
        _compositorWidth = 0;
        _compositorHeight = 0;
        return NO;
    }

    _compositorWidth = width;
    _compositorHeight = height;
    _iomfbFrameReady = NO;
    return YES;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t captureAttr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _captureQueue = dispatch_queue_create("com.strayfade.screenmirroring.capture", captureAttr);
        _nativeWidth = 1170;
        _nativeHeight = 2532;
        _getDirtyFrameCount = (SMCARenderServerGetDirtyFrameCountFunc)dlsym(RTLD_DEFAULT, "CARenderServerGetDirtyFrameCount");
        _renderDisplay = (SMCARenderServerRenderDisplayFunc)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");

        void *surfaceHandle = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
        if (surfaceHandle) {
            _surfaceCreate = (SMIOSurfaceCreateFunc)dlsym(surfaceHandle, "IOSurfaceCreate");
            _surfaceLock = (SMIOSurfaceLockFunc)dlsym(surfaceHandle, "IOSurfaceLock");
            _surfaceUnlock = (SMIOSurfaceUnlockFunc)dlsym(surfaceHandle, "IOSurfaceUnlock");
            _surfaceGetBaseAddress = (SMIOSurfaceGetBaseAddressFunc)dlsym(surfaceHandle, "IOSurfaceGetBaseAddress");
            _surfaceGetBytesPerRow = (SMIOSurfaceGetBytesPerRowFunc)dlsym(surfaceHandle, "IOSurfaceGetBytesPerRow");
            _surfaceGetWidth = (SMIOSurfaceGetWidthFunc)dlsym(surfaceHandle, "IOSurfaceGetWidth");
            _surfaceGetHeight = (SMIOSurfaceGetHeightFunc)dlsym(surfaceHandle, "IOSurfaceGetHeight");
            _surfaceAlignProperty = (SMIOSurfaceAlignPropertyFunc)dlsym(surfaceHandle, "IOSurfaceAlignProperty");
            _surfaceFlush = (SMIOSurfaceFlushFunc)dlsym(surfaceHandle, "IOSurfaceFlush");
        }
        _surfaceLockGuard = OS_UNFAIR_LOCK_INIT;

        void *acceleratorHandle =
            dlopen("/System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator", RTLD_LAZY);
        if (acceleratorHandle) {
            _acceleratorCreate = (SMIOSurfaceAcceleratorCreateFunc)dlsym(acceleratorHandle, "IOSurfaceAcceleratorCreate");
            _acceleratorTransfer =
                (SMIOSurfaceAcceleratorTransferSurfaceFunc)dlsym(acceleratorHandle, "IOSurfaceAcceleratorTransferSurface");
            _acceleratorRunLoopSource =
                (SMIOSurfaceAcceleratorGetRunLoopSourceFunc)dlsym(acceleratorHandle, "IOSurfaceAcceleratorGetRunLoopSource");
        }

        _surfaceCaptureReady = (_renderDisplay != NULL && _surfaceCreate != NULL && _surfaceLock != NULL && _surfaceUnlock != NULL &&
                                _surfaceGetBaseAddress != NULL && _surfaceGetBytesPerRow != NULL && _surfaceGetWidth != NULL &&
                                _surfaceGetHeight != NULL);
        if (!_surfaceCaptureReady) {
            smLog(@"IOSurface/CARenderServer capture APIs unavailable.");
        }
        if (!_acceleratorCreate || !_acceleratorTransfer) {
            smLog(@"IOSurfaceAccelerator unavailable; capture quality may be reduced.");
        }
    }
    return self;
}

- (void)dealloc {
    [self releaseSurfacesLocked];
    if (_lastDisplayLayer) {
        CFRelease(_lastDisplayLayer);
        _lastDisplayLayer = NULL;
    }
    if (_accelerator) {
        CFRelease(_accelerator);
        _accelerator = NULL;
    }
}

- (CGRect)nativeBoundsInPixels {
    UIScreen *screen = [UIScreen mainScreen];
    if ([screen respondsToSelector:@selector(_unjailedReferenceBoundsInPixels)]) {
        return [screen _unjailedReferenceBoundsInPixels];
    }

    CGRect bounds = screen.bounds;
    CGFloat scale = screen.nativeScale;
    if (scale < 1.0f) {
        scale = screen.scale;
    }
    return CGRectMake(0, 0, bounds.size.width * scale, bounds.size.height * scale);
}

- (NSMutableDictionary *)surfacePropertiesForWidth:(int)surfaceWidth
                                            height:(int)surfaceHeight
                                       purpleEDRAM:(BOOL)purpleEDRAM {
    const int bytesPerElement = 4;
    int bytesPerRow = surfaceWidth * bytesPerElement;
    if (_surfaceAlignProperty) {
        bytesPerRow = (int)_surfaceAlignProperty(CFSTR("IOSurfaceBytesPerRow"), (size_t)bytesPerRow);
    }

    NSMutableDictionary *properties = [@{
        @"IOSurfaceWidth" : @(surfaceWidth),
        @"IOSurfaceHeight" : @(surfaceHeight),
        @"IOSurfaceBytesPerElement" : @(bytesPerElement),
        @"IOSurfacePixelFormat" : @(kSMPixelFormatBGRA),
        @"IOSurfaceBytesPerRow" : @(bytesPerRow),
        @"IOSurfaceAllocSize" : @(bytesPerRow * surfaceHeight),
    } mutableCopy];

    if (purpleEDRAM) {
        properties[@"IOSurfaceMemoryRegion"] = @"PurpleEDRAM";
        properties[@"IOSurfaceIsGlobal"] = @YES;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (colorSpace) {
        CFPropertyListRef colorSpacePropertyList = CGColorSpaceCopyPropertyList(colorSpace);
        CGColorSpaceRelease(colorSpace);
        if (colorSpacePropertyList) {
            properties[@"IOSurfaceColorSpace"] = (__bridge id)colorSpacePropertyList;
            CFRelease(colorSpacePropertyList);
        }
    }

    return properties;
}

- (BOOL)rebuildSurfacesForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (width == 0 || height == 0 || !_surfaceCaptureReady) {
        return NO;
    }

    const int surfaceWidth = (int)width;
    const int surfaceHeight = (int)height;

    NSDictionary *scratchProperties =
        [self surfacePropertiesForWidth:surfaceWidth height:surfaceHeight purpleEDRAM:NO];
    NSDictionary *destinationProperties =
        [self surfacePropertiesForWidth:surfaceWidth height:surfaceHeight purpleEDRAM:YES];

    [self releaseSurfacesLocked];
    _renderProperties = [destinationProperties copy];

    _scratchSurface = _surfaceCreate((__bridge CFDictionaryRef)scratchProperties);
    _renderSurface = _surfaceCreate((__bridge CFDictionaryRef)destinationProperties);
    if (!_renderSurface || !_scratchSurface) {
        smLog(@"IOSurfaceCreate failed for %dx%d.", surfaceWidth, surfaceHeight);
        [self releaseSurfacesLocked];
        return NO;
    }

    if (![self ensureCompositorDisplaySurfaceLocked:width height:height]) {
        [self releaseSurfacesLocked];
        return NO;
    }

    smLog(@"IOSurfaces created (%dx%d, PurpleEDRAM render buffers).", surfaceWidth, surfaceHeight);
    return YES;
}

- (BOOL)copySurface:(IOSurfaceRef)source
          toSurface:(IOSurfaceRef)destination
            context:(const char *)context
      displaySource:(BOOL)displaySource {
    if (!source || !destination || !_surfaceLock || !_surfaceUnlock || !_surfaceGetBaseAddress || !_surfaceGetWidth ||
        !_surfaceGetHeight || !_surfaceGetBytesPerRow) {
        return NO;
    }

    if (_surfaceFlush) {
        _surfaceFlush(source, 0);
    }

    if (_acceleratorReady && _acceleratorTransfer && !displaySource) {
        const kern_return_t result =
            _acceleratorTransfer(_accelerator, source, destination, NULL, NULL, NULL, NULL);
        if (result == KERN_SUCCESS) {
            return YES;
        }
        if (!_loggedAccelFailure) {
            _loggedAccelFailure = YES;
            smLog(@"%s IOSurfaceAcceleratorTransferSurface failed (%d); using linear copy.",
                  context,
                  result);
        }
    }

    const size_t width = MIN(_surfaceGetWidth(source), _surfaceGetWidth(destination));
    const size_t height = MIN(_surfaceGetHeight(source), _surfaceGetHeight(destination));
    if (width == 0 || height == 0) {
        return NO;
    }

    _surfaceLock(source, kSMIOSurfaceLockReadOnly, NULL);
    _surfaceLock(destination, 0, NULL);
    const uint8_t *sourceBytes = (const uint8_t *)_surfaceGetBaseAddress(source);
    uint8_t *destinationBytes = (uint8_t *)_surfaceGetBaseAddress(destination);
    if (sourceBytes && destinationBytes) {
        if (displaySource) {
            const size_t packedRowBytes = width * 4;
            const size_t packedLength = packedRowBytes * height;
            if (!_untileBuffer || _untileBuffer.length < packedLength) {
                _untileBuffer = [NSMutableData dataWithLength:packedLength];
            }
            uint8_t *packedPixels = (uint8_t *)_untileBuffer.mutableBytes;
            if (packedPixels) {
                smCopy64x16BlockedImage(packedPixels, sourceBytes, width, height);
                const size_t destStride = _surfaceGetBytesPerRow(destination);
                for (size_t row = 0; row < height; row++) {
                    memcpy(destinationBytes + row * destStride, packedPixels + row * packedRowBytes, packedRowBytes);
                }
            }
        } else {
            const size_t sourceStride = _surfaceGetBytesPerRow(source);
            const size_t destStride = _surfaceGetBytesPerRow(destination);
            const size_t copyBytes = width * 4;
            for (size_t row = 0; row < height; row++) {
                memcpy(destinationBytes + row * destStride, sourceBytes + row * sourceStride, copyBytes);
            }
        }
    }
    _surfaceUnlock(destination, 0, NULL);
    _surfaceUnlock(source, kSMIOSurfaceLockReadOnly, NULL);
    return sourceBytes != NULL && destinationBytes != NULL;
}

- (void)setStreamingActive:(BOOL)active {
    if ([NSThread isMainThread]) {
        [self setStreamingActiveOnMainThread:active];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setStreamingActiveOnMainThread:active];
    });
}

- (BOOL)refreshDisplaySurfaceFromLastLayerLocked {
    if (!_lastDisplayLayer || !_surfaceGetWidth || !_surfaceGetHeight) {
        return NO;
    }

    const size_t surfaceWidth = _surfaceGetWidth(_lastDisplayLayer);
    const size_t surfaceHeight = _surfaceGetHeight(_lastDisplayLayer);
    if (surfaceWidth == 0 || surfaceHeight == 0) {
        return NO;
    }

    if (![self ensureCompositorDisplaySurfaceLocked:surfaceWidth height:surfaceHeight]) {
        return NO;
    }

    const BOOL transferred =
        [self copySurface:_lastDisplayLayer toSurface:_displaySurface context:"IOMFB" displaySource:YES];
    if (!transferred) {
        return NO;
    }

    _iomfbFrameReady = YES;
    _iomfbFrameDirty = NO;
    _lastIomfbIngestTime = CFAbsoluteTimeGetCurrent();
    return YES;
}

- (void)primeDisplaySurfaceFromLastLayerLocked {
    if (!_lastDisplayLayer || !_streamingActive) {
        return;
    }

    if (![self refreshDisplaySurfaceFromLastLayerLocked]) {
        return;
    }

    if (!_loggedIomfbIngestOK && _surfaceGetBaseAddress && _surfaceGetBytesPerRow) {
        _surfaceLock(_displaySurface, kSMIOSurfaceLockReadOnly, NULL);
        const uint8_t *pixels = (const uint8_t *)_surfaceGetBaseAddress(_displaySurface);
        const size_t width = _surfaceGetWidth(_displaySurface);
        const size_t height = _surfaceGetHeight(_displaySurface);
        const size_t stride = _surfaceGetBytesPerRow(_displaySurface);
        const BOOL visible = smSampleFrameHasVisibleContent(pixels, width, height, stride);
        _surfaceUnlock(_displaySurface, kSMIOSurfaceLockReadOnly, NULL);
        _loggedIomfbIngestOK = YES;
        smLog(@"Primed IOMFB display surface from last compositor layer (%zux%zu, visible=%@).",
              width,
              height,
              visible ? @"yes" : @"no");
    }
}

- (void)setStreamingActiveOnMainThread:(BOOL)active {
    if (_streamingActive == active) {
        return;
    }
    _streamingActive = active;

    if (active) {
        os_unfair_lock_lock(&_surfaceLockGuard);
        _loggedBlackIomfb = NO;
        _iomfbFrameDirty = YES;
        [self primeDisplaySurfaceFromLastLayerLocked];
        os_unfair_lock_unlock(&_surfaceLockGuard);
    } else {
        _iomfbFrameReady = NO;
        _iomfbFrameDirty = NO;
    }
}

- (void)onDisplayLink:(CADisplayLink *)link {
    (void)link;
    if (!_streamingActive || !smReadLiveCapture()) {
        return;
    }

    os_unfair_lock_lock(&_surfaceLockGuard);
    [self renderDisplayToSurface];
    os_unfair_lock_unlock(&_surfaceLockGuard);
}

- (void)ingestDisplaySurface:(IOSurfaceRef)surface {
    if (!surface) {
        return;
    }

    os_unfair_lock_lock(&_surfaceLockGuard);

    if (_lastDisplayLayer) {
        CFRelease(_lastDisplayLayer);
        _lastDisplayLayer = NULL;
    }
    _lastDisplayLayer = (IOSurfaceRef)CFRetain(surface);
    _lastDisplayLayerTime = CFAbsoluteTimeGetCurrent();

    if (_streamingActive) {
        _iomfbFrameDirty = YES;
    }

    if (!_streamingActive) {
        os_unfair_lock_unlock(&_surfaceLockGuard);
        return;
    }

    if (_nativeWidth == 0 || _nativeHeight == 0) {
        os_unfair_lock_unlock(&_surfaceLockGuard);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self prepareOnMainThread];
        });
        return;
    }

    os_unfair_lock_unlock(&_surfaceLockGuard);
}

- (BOOL)prepareAcceleratorOnMainThread {
    if (_acceleratorReady || !_acceleratorCreate || !_acceleratorTransfer) {
        return _acceleratorReady;
    }

    IOSurfaceAcceleratorRef accelerator = NULL;
    if (_acceleratorCreate(kCFAllocatorDefault, NULL, &accelerator) != KERN_SUCCESS || !accelerator) {
        smLog(@"IOSurfaceAcceleratorCreate failed.");
        return NO;
    }

    _accelerator = accelerator;

    if (_acceleratorRunLoopSource) {
        CFRunLoopSourceRef runLoopSource = _acceleratorRunLoopSource(_accelerator);
        if (runLoopSource) {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode);
        }
    }

    _acceleratorReady = YES;
    smLog(@"IOSurfaceAccelerator ready (TrollVNC-style capture path).");
    return YES;
}

- (void)prepareOnMainThread {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self prepareOnMainThread];
        });
        return;
    }

    const CGRect bounds = [self nativeBoundsInPixels];
    _nativeWidth = MAX((NSUInteger)round(bounds.size.width), 1);
    _nativeHeight = MAX((NSUInteger)round(bounds.size.height), 1);
    [self rebuildSurfacesForWidth:_nativeWidth height:_nativeHeight];
    [self prepareAcceleratorOnMainThread];
    smLog(@"Cached display size %lux%lu.", (unsigned long)_nativeWidth, (unsigned long)_nativeHeight);
}

- (CGSize)nativeSizeInPixels {
    if (_nativeWidth == 0 || _nativeHeight == 0) {
        if (![NSThread isMainThread]) {
            __block CGSize size = CGSizeZero;
            dispatch_sync(dispatch_get_main_queue(), ^{
                size = [[SMScreenCapture sharedCapture] nativeSizeInPixels];
            });
            return size;
        }
        const CGRect bounds = [self nativeBoundsInPixels];
        _nativeWidth = MAX((NSUInteger)round(bounds.size.width), 1);
        _nativeHeight = MAX((NSUInteger)round(bounds.size.height), 1);
    }
    return CGSizeMake((CGFloat)_nativeWidth, (CGFloat)_nativeHeight);
}

- (void)frameDimensionsForScale:(NSInteger)scale width:(NSUInteger *)width height:(NSUInteger *)height {
    NSInteger divisor = scale < 1 ? 1 : scale;
    NSUInteger w = MAX(_nativeWidth / (NSUInteger)divisor, 1);
    NSUInteger h = MAX(_nativeHeight / (NSUInteger)divisor, 1);
    smCapFrameDimensions(&w, &h);
    if (width) {
        *width = w;
    }
    if (height) {
        *height = h;
    }
}

- (SMScreenFrame *)placeholderFrameWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (width == 0 || height == 0) {
        return nil;
    }

    NSMutableData *pixelData = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *pixels = (uint8_t *)pixelData.mutableBytes;
    for (NSUInteger y = 0; y < height; y++) {
        for (NSUInteger x = 0; x < width; x++) {
            uint8_t *pixel = pixels + ((y * width + x) * 4);
            pixel[0] = 40;
            pixel[1] = (uint8_t)((x * 255) / MAX(width, (NSUInteger)1));
            pixel[2] = (uint8_t)((y * 255) / MAX(height, (NSUInteger)1));
            pixel[3] = 255;
        }
    }

    SMScreenFrame *frame = [SMScreenFrame new];
    frame.width = width;
    frame.height = height;
    frame.bgraPixels = pixelData;
    return frame;
}

- (SMScreenFrame *)scaledFrameFromReferencePixels:(const uint8_t *)sourcePixels
                                     sourceWidth:(size_t)sourceWidth
                                    sourceHeight:(size_t)sourceHeight
                                     sourceStride:(size_t)sourceStride
                                      targetWidth:(size_t)targetWidth
                                     targetHeight:(size_t)targetHeight {
    if (!sourcePixels || sourceWidth == 0 || sourceHeight == 0 || targetWidth == 0 || targetHeight == 0) {
        return nil;
    }

    const CGRect refBounds = [self nativeBoundsInPixels];
    size_t refWidth = (size_t)MAX(lround(refBounds.size.width), 1);
    size_t refHeight = (size_t)MAX(lround(refBounds.size.height), 1);
    size_t cropWidth = MIN(refWidth, sourceWidth);
    size_t cropHeight = MIN(refHeight, sourceHeight);

    NSData *croppedData = nil;
    const uint8_t *pixels = sourcePixels;
    size_t stride = sourceStride > 0 ? sourceStride : (sourceWidth * 4);

    if (cropWidth < sourceWidth || cropHeight < sourceHeight) {
        NSMutableData *buffer = [NSMutableData dataWithLength:cropWidth * cropHeight * 4];
        uint8_t *destination = (uint8_t *)buffer.mutableBytes;
        for (size_t row = 0; row < cropHeight; row++) {
            memcpy(destination + row * cropWidth * 4, sourcePixels + row * stride, cropWidth * 4);
        }
        croppedData = buffer;
        pixels = (const uint8_t *)croppedData.bytes;
        stride = cropWidth * 4;
        sourceWidth = cropWidth;
        sourceHeight = cropHeight;
    }

    return [self scaledFrameFromBGRA:pixels
                         sourceWidth:sourceWidth
                        sourceHeight:sourceHeight
                         sourceStride:stride
                          targetWidth:targetWidth
                         targetHeight:targetHeight];
}

- (SMScreenFrame *)scaledFrameFromBGRA:(const uint8_t *)sourcePixels
                           sourceWidth:(size_t)sourceWidth
                          sourceHeight:(size_t)sourceHeight
                           sourceStride:(size_t)sourceStride
                            targetWidth:(size_t)targetWidth
                           targetHeight:(size_t)targetHeight {
    if (!sourcePixels || sourceWidth == 0 || sourceHeight == 0 || targetWidth == 0 || targetHeight == 0) {
        return nil;
    }

    const size_t destinationStride = targetWidth * 4;
    const size_t requiredLength = targetWidth * targetHeight * 4;
    if (!_reusedStreamingPixels || _reusedStreamingWidth != targetWidth || _reusedStreamingHeight != targetHeight) {
        _reusedStreamingPixels = [NSMutableData dataWithLength:requiredLength];
        _reusedStreamingWidth = targetWidth;
        _reusedStreamingHeight = targetHeight;
    } else if (_reusedStreamingPixels.length < requiredLength) {
        [_reusedStreamingPixels setLength:requiredLength];
    }

    uint8_t *destination = (uint8_t *)_reusedStreamingPixels.mutableBytes;
    if (!destination) {
        return nil;
    }

    const size_t effectiveSourceStride = sourceStride > 0 ? sourceStride : sourceWidth * 4;

    if (sourceWidth == targetWidth && sourceHeight == targetHeight) {
        for (size_t row = 0; row < targetHeight; row++) {
            memcpy(destination + row * destinationStride,
                   sourcePixels + row * effectiveSourceStride,
                   targetWidth * 4);
        }
    } else {
        for (size_t y = 0; y < targetHeight; y++) {
            const size_t sourceY = (y * sourceHeight) / targetHeight;
            const uint8_t *sourceRow = sourcePixels + (sourceY * effectiveSourceStride);
            uint8_t *destinationRow = destination + (y * destinationStride);
            for (size_t x = 0; x < targetWidth; x++) {
                const size_t sourceX = (x * sourceWidth) / targetWidth;
                const uint8_t *pixel = sourceRow + (sourceX * 4);
                uint8_t *out = destinationRow + (x * 4);
                out[0] = pixel[0];
                out[1] = pixel[1];
                out[2] = pixel[2];
                out[3] = 255;
            }
        }
    }

    if (sourceWidth == targetWidth && sourceHeight == targetHeight) {
        smFillOpaqueAlphaChannel(destination, targetWidth, targetHeight, destinationStride);
    }

    SMScreenFrame *frame = [SMScreenFrame new];
    frame.width = targetWidth;
    frame.height = targetHeight;
    frame.bgraPixels = [_reusedStreamingPixels copy];
    return frame;
}

- (BOOL)renderDisplayToSurface {
    if (!_renderDisplay || !_renderSurface || !_scratchSurface) {
        return NO;
    }

    if (_getDirtyFrameCount) {
        const CFIndex dirtyCount = _getDirtyFrameCount(NULL);
        if (dirtyCount == gSMDirtyFrameCount) {
            return NO;
        }
        gSMDirtyFrameCount = dirtyCount;
    }

    _renderDisplay(0, CFSTR("LCD"), _scratchSurface, 0, 0);

    if (![self copySurface:_scratchSurface toSurface:_renderSurface context:"CARender" displaySource:NO]) {
        return NO;
    }

    return YES;
}

- (SMScreenFrame *)captureFrameFromIOSurface:(IOSurfaceRef)surface
                                 targetWidth:(size_t)targetWidth
                                targetHeight:(size_t)targetHeight
                                displayTiled:(BOOL)displayTiled {
    if (!surface || !_surfaceLock || !_surfaceUnlock || !_surfaceGetBaseAddress || !_surfaceGetWidth || !_surfaceGetHeight) {
        return nil;
    }

    const size_t width = _surfaceGetWidth(surface);
    const size_t height = _surfaceGetHeight(surface);
    if (width == 0 || height == 0) {
        return nil;
    }

    const size_t nativeLength = width * height * 4;
    if (!_nativePixelScratch || _nativeScratchWidth != width || _nativeScratchHeight != height) {
        _nativePixelScratch = [NSMutableData dataWithLength:nativeLength];
        _nativeScratchWidth = width;
        _nativeScratchHeight = height;
    } else if (_nativePixelScratch.length < nativeLength) {
        [_nativePixelScratch setLength:nativeLength];
    }
    NSMutableData *nativePixels = _nativePixelScratch;
    if (nativePixels.length == 0) {
        return nil;
    }

    if (_surfaceFlush) {
        _surfaceFlush(surface, 0);
    }

    _surfaceLock(surface, kSMIOSurfaceLockReadOnly, NULL);
    const uint8_t *sourceBytes = (const uint8_t *)_surfaceGetBaseAddress(surface);
    uint8_t *destinationBytes = (uint8_t *)nativePixels.mutableBytes;
    if (sourceBytes && destinationBytes) {
        if (displayTiled) {
            smCopy64x16BlockedImage(destinationBytes, sourceBytes, width, height);
        } else {
            const size_t stride = _surfaceGetBytesPerRow(surface);
            const size_t copyBytes = width * 4;
            for (size_t row = 0; row < height; row++) {
                memcpy(destinationBytes + row * copyBytes, sourceBytes + row * stride, copyBytes);
            }
        }
    }
    _surfaceUnlock(surface, kSMIOSurfaceLockReadOnly, NULL);

    if (!sourceBytes) {
        return nil;
    }

    const size_t stride = width * 4;
    if (!_streamingActive && !smSampleFrameHasVisibleContent(destinationBytes, width, height, stride)) {
        if (!_loggedBlackIomfb) {
            _loggedBlackIomfb = YES;
            smLog(@"IOSurface sample looks empty after %s copy.", displayTiled ? "tiled" : "linear");
        }
        return nil;
    }

    return [self scaledFrameFromReferencePixels:destinationBytes
                                    sourceWidth:width
                                   sourceHeight:height
                                    sourceStride:stride
                                     targetWidth:targetWidth
                                    targetHeight:targetHeight];
}

- (SMScreenFrame *)captureViaIOMFBPollWithTargetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    static dispatch_once_t onceToken;
    static SMIOMFBGetMainDisplayFunc getMainDisplay = NULL;
    static SMIOMFBGetLayerDefaultSurfaceFunc getLayerSurface = NULL;
    dispatch_once(&onceToken, ^{
        void *handle =
            dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY);
        if (handle) {
            getMainDisplay = (SMIOMFBGetMainDisplayFunc)dlsym(handle, "IOMobileFramebufferGetMainDisplay");
            getLayerSurface = (SMIOMFBGetLayerDefaultSurfaceFunc)dlsym(handle, "IOMobileFramebufferGetLayerDefaultSurface");
        }
    });

    if (!getMainDisplay || !getLayerSurface) {
        if (!_loggedIomfbPollFail) {
            _loggedIomfbPollFail = YES;
            smLog(@"IOMFB poll APIs unavailable.");
        }
        return nil;
    }

    IOMobileFramebufferRef framebuffer = NULL;
    if (getMainDisplay(&framebuffer) != KERN_SUCCESS || framebuffer == NULL) {
        if (!_loggedIomfbPollFail) {
            _loggedIomfbPollFail = YES;
            smLog(@"IOMobileFramebufferGetMainDisplay failed.");
        }
        return nil;
    }

    IOSurfaceRef layerSurface = NULL;
    if (getLayerSurface(framebuffer, 0, &layerSurface) != KERN_SUCCESS || layerSurface == NULL) {
        if (!_loggedIomfbPollFail) {
            _loggedIomfbPollFail = YES;
            smLog(@"IOMobileFramebufferGetLayerDefaultSurface failed.");
        }
        return nil;
    }

    return [self captureFrameFromIOSurface:layerSurface
                               targetWidth:targetWidth
                              targetHeight:targetHeight
                              displayTiled:YES];
}

- (SMScreenFrame *)captureViaLastDisplayLayerWithTargetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    if (!_lastDisplayLayer || _lastDisplayLayerTime <= 0.0) {
        return nil;
    }
    if ((CFAbsoluteTimeGetCurrent() - _lastDisplayLayerTime) > 2.0) {
        return nil;
    }
    return [self captureFrameFromIOSurface:_lastDisplayLayer
                               targetWidth:targetWidth
                              targetHeight:targetHeight
                              displayTiled:YES];
}

- (SMScreenFrame *)captureViaDisplaySurfaceWithTargetWidth:(size_t)targetWidth
                                              targetHeight:(size_t)targetHeight
                                                     label:(const char *)label {
    (void)label;
    if (!_displaySurface && !_lastDisplayLayer) {
        return nil;
    }

    if ((CFAbsoluteTimeGetCurrent() - _lastDisplayLayerTime) > 2.0) {
        return nil;
    }

    if (_iomfbFrameDirty || !_iomfbFrameReady) {
        if (![self refreshDisplaySurfaceFromLastLayerLocked]) {
            return nil;
        }
    }

    return [self captureFrameFromIOSurface:_displaySurface
                               targetWidth:targetWidth
                              targetHeight:targetHeight
                              displayTiled:NO];
}

- (SMScreenFrame *)captureViaKeyWindowWithTargetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    UIWindow *window = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) {
            break;
        }
    }
    if (!window) {
        window = [UIApplication sharedApplication].keyWindow;
    }
    if (!window) {
        if (!_loggedWindowCaptureFail) {
            _loggedWindowCaptureFail = YES;
            smLog(@"Key window capture failed: no window.");
        }
        return nil;
    }

    const CGSize boundsSize = window.bounds.size;
    if (boundsSize.width <= 0 || boundsSize.height <= 0) {
        return nil;
    }

    CGFloat scale = window.screen.nativeScale;
    if (scale < 1.0f) {
        scale = window.screen.scale;
    }
    if (scale < 1.0f) {
        scale = 1.0f;
    }

    const size_t pixelWidth = MAX((size_t)(boundsSize.width * scale), 1);
    const size_t pixelHeight = MAX((size_t)(boundsSize.height * scale), 1);
    NSMutableData *pixelData = [NSMutableData dataWithLength:pixelWidth * pixelHeight * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixelData.mutableBytes,
                                                pixelWidth,
                                                pixelHeight,
                                                8,
                                                pixelWidth * 4,
                                                colorSpace,
                                                kSMVNCBitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return nil;
    }

    CGContextScaleCTM(context, scale, scale);
    [window.layer renderInContext:context];
    CGContextRelease(context);

    return [self scaledFrameFromBGRA:(const uint8_t *)pixelData.bytes
                        sourceWidth:pixelWidth
                       sourceHeight:pixelHeight
                        sourceStride:pixelWidth * 4
                         targetWidth:targetWidth
                        targetHeight:targetHeight];
}

- (SMScreenFrame *)captureViaCARenderServerWithTargetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    if (!_surfaceCaptureReady || targetWidth == 0 || targetHeight == 0) {
        return nil;
    }

    if (_nativeWidth == 0 || _nativeHeight == 0 || !_renderSurface) {
        smLog(@"Capture surfaces not prepared.");
        return nil;
    }

    const BOOL rendered = [self renderDisplayToSurface];

    SMScreenFrame *frame = nil;
    _surfaceLock(_renderSurface, kSMIOSurfaceLockReadOnly, NULL);
    const void *baseAddress = _surfaceGetBaseAddress(_renderSurface);
    const size_t stride = _surfaceGetBytesPerRow(_renderSurface);
    const size_t width = _surfaceGetWidth(_renderSurface);
    const size_t height = _surfaceGetHeight(_renderSurface);
    if (baseAddress && width > 0 && height > 0) {
        if (smSampleFrameHasVisibleContent((const uint8_t *)baseAddress, width, height, stride)) {
            frame = [self scaledFrameFromBGRA:(const uint8_t *)baseAddress
                                    sourceWidth:width
                                   sourceHeight:height
                                    sourceStride:stride
                                     targetWidth:targetWidth
                                    targetHeight:targetHeight];
        } else if (!_loggedBlackCARender) {
            _loggedBlackCARender = YES;
            smLog(@"CARenderServer buffer has no visible pixels (black in SpringBoard).");
        }
    }
    _surfaceUnlock(_renderSurface, kSMIOSurfaceLockReadOnly, NULL);

    if (!frame && !rendered) {
        return nil;
    }
    if (!frame) {
        smLog(@"CARenderServer frame scaling failed.");
    }
    return frame;
}

- (SMScreenFrame *)captureViaUIImageWithTargetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    static dispatch_once_t onceToken;
    static UIImage *(*createScreenImageMethod)(id, SEL) = NULL;
    static UIImage *(*createScreenImageFunction)(void) = NULL;
    static BOOL loggedMissingAPI = NO;
    dispatch_once(&onceToken, ^{
        Class uiImageClass = objc_getClass("UIImage");
        if (uiImageClass && [uiImageClass respondsToSelector:@selector(_UICreateScreenUIImage)]) {
            createScreenImageMethod =
                (UIImage * (*)(id, SEL))[uiImageClass methodForSelector:@selector(_UICreateScreenUIImage)];
        }
        createScreenImageFunction = (UIImage * (*)(void))dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    });

    if (!createScreenImageMethod && !createScreenImageFunction) {
        if (!loggedMissingAPI) {
            loggedMissingAPI = YES;
            smLog(@"_UICreateScreenUIImage unavailable.");
        }
        return nil;
    }

    __block SMScreenFrame *frame = nil;
    void (^captureBlock)(void) = ^{
        UIImage *screenImage = nil;
        if (createScreenImageMethod) {
            screenImage = createScreenImageMethod(objc_getClass("UIImage"), @selector(_UICreateScreenUIImage));
        } else if (createScreenImageFunction) {
            screenImage = createScreenImageFunction();
        }
        CGImageRef sourceImage = screenImage.CGImage;
        if (!sourceImage) {
            return;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        NSMutableData *pixelData = [NSMutableData dataWithLength:targetWidth * targetHeight * 4];
        CGContextRef context = CGBitmapContextCreate(pixelData.mutableBytes,
                                                     targetWidth,
                                                     targetHeight,
                                                     8,
                                                     targetWidth * 4,
                                                     colorSpace,
                                                     kSMVNCBitmapInfo);
        CGColorSpaceRelease(colorSpace);
        if (!context) {
            return;
        }

        CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
        CGContextDrawImage(context, CGRectMake(0, 0, targetWidth, targetHeight), sourceImage);
        CGContextRelease(context);

        frame = [SMScreenFrame new];
        frame.width = targetWidth;
        frame.height = targetHeight;
        frame.bgraPixels = pixelData;
    };

    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), captureBlock);
    }
    return frame;
}

- (SMScreenFrame *)captureForStreamingWithTargetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    os_unfair_lock_lock(&_surfaceLockGuard);

    SMScreenFrame *frame = [self captureViaDisplaySurfaceWithTargetWidth:targetWidth targetHeight:targetHeight label:"IOMFB"];
    os_unfair_lock_unlock(&_surfaceLockGuard);
    if (frame) {
        return frame;
    }

    if ([NSThread isMainThread]) {
        return [self captureViaUIImageWithTargetWidth:targetWidth targetHeight:targetHeight];
    }

    __block SMScreenFrame *fallbackFrame = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        fallbackFrame = [self captureViaUIImageWithTargetWidth:targetWidth targetHeight:targetHeight];
    });
    return fallbackFrame;
}

- (void)resetCaptureThrottle {
    dispatch_async(_captureQueue, ^{
        self->_lastCaptureTime = 0;
        self->_cachedFrame = nil;
        self->_reusedStreamingPixels = nil;
        self->_nativePixelScratch = nil;
        self->_cachedWidth = 0;
        self->_cachedHeight = 0;
        self->_reusedStreamingWidth = 0;
        self->_reusedStreamingHeight = 0;
        self->_nativeScratchWidth = 0;
        self->_nativeScratchHeight = 0;
        self->_loggedBlackCARender = NO;
        self->_loggedBlackIomfb = NO;
        self->_loggedAccelFailure = NO;
        self->_loggedIomfbIngestOK = NO;
        self->_loggedIomfbPollFail = NO;
        self->_loggedWindowCaptureFail = NO;
        gSMDirtyFrameCount = -1;
    });
}

- (dispatch_queue_t)captureQueueForVNC {
    return _captureQueue;
}

- (void)cancelPendingCaptures {
    dispatch_async(_captureQueue, ^{
        self->_asyncCaptureInFlight = NO;
        self->_asyncCaptureWidth = 0;
        self->_asyncCaptureHeight = 0;
        self->_asyncCaptureCompletions = nil;
    });
}

- (SMScreenFrame *)captureFrameWithTargetWidth:(NSUInteger)targetWidth targetHeight:(NSUInteger)targetHeight {
    const size_t outWidth = targetWidth > 0 ? (size_t)targetWidth : 1;
    const size_t outHeight = targetHeight > 0 ? (size_t)targetHeight : 1;

    const NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (_cachedFrame && _cachedWidth == outWidth && _cachedHeight == outHeight) {
        os_unfair_lock_lock(&_surfaceLockGuard);
        const BOOL frameDirty = _iomfbFrameDirty;
        os_unfair_lock_unlock(&_surfaceLockGuard);
        if (!frameDirty) {
            _lastCaptureTime = now;
            return _cachedFrame;
        }
        if (!_streamingActive && (now - _lastCaptureTime) < smCaptureMinInterval()) {
            return _cachedFrame;
        }
    }

    if (!smReadLiveCapture()) {
        _lastCaptureTime = now;
        return [self placeholderFrameWithWidth:outWidth height:outHeight];
    }

    SMScreenFrame *frame = nil;
    @try {
        frame = [self captureForStreamingWithTargetWidth:outWidth targetHeight:outHeight];
    } @catch (NSException *exception) {
        smLog(@"Screen capture exception: %@", exception);
    }

    if (frame) {
        _lastCaptureTime = now;
        _cachedFrame = frame;
        _cachedWidth = outWidth;
        _cachedHeight = outHeight;
        return frame;
    }

    smLog(@"Capture failed; using placeholder.");
    _lastCaptureTime = now;
    return [self placeholderFrameWithWidth:outWidth height:outHeight];
}

- (void)captureFrameWithTargetWidth:(NSUInteger)targetWidth
                     targetHeight:(NSUInteger)targetHeight
                       completion:(void (^)(SMScreenFrame *frame))completion {
    if (!completion) {
        return;
    }

    const NSUInteger outWidth = targetWidth > 0 ? targetWidth : 1;
    const NSUInteger outHeight = targetHeight > 0 ? targetHeight : 1;
    void (^completionCopy)(SMScreenFrame *) = [completion copy];

    dispatch_async(_captureQueue, ^{
        const NSTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (self->_cachedFrame && self->_cachedWidth == outWidth && self->_cachedHeight == outHeight) {
            os_unfair_lock_lock(&self->_surfaceLockGuard);
            const BOOL frameDirty = self->_iomfbFrameDirty;
            os_unfair_lock_unlock(&self->_surfaceLockGuard);
            if (!frameDirty) {
                self->_lastCaptureTime = now;
                completionCopy(self->_cachedFrame);
                return;
            }
            if (!self->_streamingActive && (now - self->_lastCaptureTime) < smCaptureMinInterval()) {
                completionCopy(self->_cachedFrame);
                return;
            }
        }

        if (self->_asyncCaptureInFlight && self->_asyncCaptureWidth == outWidth &&
            self->_asyncCaptureHeight == outHeight) {
            if (!self->_asyncCaptureCompletions) {
                self->_asyncCaptureCompletions = [NSMutableArray array];
            }
            [self->_asyncCaptureCompletions addObject:completionCopy];
            return;
        }

        self->_asyncCaptureInFlight = YES;
        self->_asyncCaptureWidth = outWidth;
        self->_asyncCaptureHeight = outHeight;
        self->_asyncCaptureCompletions = [NSMutableArray arrayWithObject:completionCopy];

        SMScreenFrame *frame = [self captureFrameWithTargetWidth:outWidth targetHeight:outHeight];

        NSArray<void (^)(SMScreenFrame *)> *completions = [self->_asyncCaptureCompletions copy];
        self->_asyncCaptureCompletions = nil;
        self->_asyncCaptureInFlight = NO;
        self->_asyncCaptureWidth = 0;
        self->_asyncCaptureHeight = 0;

        for (void (^handler)(SMScreenFrame *) in completions) {
            handler(frame);
        }
    });
}

@end
