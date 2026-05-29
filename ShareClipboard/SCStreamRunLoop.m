#import "SCStreamRunLoop.h"

static NSThread *scStreamThread = nil;
static NSRunLoop *scStreamRunLoop = nil;

@interface SCStreamRunLoopHost : NSObject
- (void)run;
- (void)performBlock:(dispatch_block_t)block;
@end

@implementation SCStreamRunLoopHost

- (void)run {
    scStreamRunLoop = [NSRunLoop currentRunLoop];
    NSPort *keepAlivePort = [NSMachPort port];
    [scStreamRunLoop addPort:keepAlivePort forMode:NSDefaultRunLoopMode];

    while (YES) {
        @autoreleasepool {
            [scStreamRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }
}

- (void)performBlock:(dispatch_block_t)block {
    if (!block) {
        return;
    }
    block();
}

@end

static void scEnsureStreamThread(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SCStreamRunLoopHost *host = [[SCStreamRunLoopHost alloc] init];
        scStreamThread = [[NSThread alloc] initWithTarget:host selector:@selector(run) object:nil];
        scStreamThread.name = @"ShareClipboardStreams";
        [scStreamThread start];

        while (!scStreamRunLoop) {
            [NSThread sleepForTimeInterval:0.01];
        }
    });
}

void scStreamRunLoopPerform(dispatch_block_t block) {
    if (!block) {
        return;
    }

    scEnsureStreamThread();
    SCStreamRunLoopHost *host = [[SCStreamRunLoopHost alloc] init];
    [host performSelector:@selector(performBlock:)
                 onThread:scStreamThread
               withObject:[block copy]
            waitUntilDone:NO];
}

void scStreamRunLoopPerformSync(dispatch_block_t block) {
    if (!block) {
        return;
    }

    scEnsureStreamThread();
    SCStreamRunLoopHost *host = [[SCStreamRunLoopHost alloc] init];
    [host performSelector:@selector(performBlock:)
                 onThread:scStreamThread
               withObject:[block copy]
            waitUntilDone:YES];
}
