#import <Foundation/Foundation.h>

typedef struct __IOSurface *IOSurfaceRef;

@interface SMScreenFrame : NSObject
@property (nonatomic, assign, readonly) NSUInteger width;
@property (nonatomic, assign, readonly) NSUInteger height;
@property (nonatomic, strong, readonly) NSData *bgraPixels;
@end

@interface SMScreenCapture : NSObject
+ (instancetype)sharedCapture;
- (void)prepareOnMainThread;
- (void)setStreamingActive:(BOOL)active;
- (void)ingestDisplaySurface:(IOSurfaceRef)surface;
- (void)frameDimensionsForScale:(NSInteger)scale width:(NSUInteger *)width height:(NSUInteger *)height;
- (CGSize)nativeSizeInPixels;
- (void)resetCaptureThrottle;
- (void)cancelPendingCaptures;
- (dispatch_queue_t)captureQueueForVNC;
- (SMScreenFrame *)captureFrameWithTargetWidth:(NSUInteger)targetWidth targetHeight:(NSUInteger)targetHeight;
- (void)captureFrameWithTargetWidth:(NSUInteger)targetWidth
                     targetHeight:(NSUInteger)targetHeight
                       completion:(void (^)(SMScreenFrame *frame))completion;
@end
