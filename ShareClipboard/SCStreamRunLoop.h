#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

void scStreamRunLoopPerform(dispatch_block_t block);
void scStreamRunLoopPerformSync(dispatch_block_t block);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
