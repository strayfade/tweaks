#import <Foundation/Foundation.h>

@interface SMInputInjector : NSObject
+ (instancetype)sharedInjector;
- (void)prepareOnMainThreadIfNeeded;
- (void)handlePointerEventWithButtonMask:(uint8_t)buttonMask x:(uint16_t)x y:(uint16_t)y frameWidth:(NSUInteger)frameWidth frameHeight:(NSUInteger)frameHeight;
- (void)handleKeyEventWithDown:(BOOL)down keysym:(uint32_t)keysym;
@end
