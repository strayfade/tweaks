#import <substrate.h>
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>
#import "SMScreenCapture.h"
#import "SMCommon.h"

typedef struct __IOMobileFramebuffer *IOMobileFramebufferRef;

static kern_return_t (*gOrigSwapSetLayer)(IOMobileFramebufferRef framebuffer,
                                          int layer,
                                          IOSurfaceRef surface,
                                          CGRect bounds,
                                          CGRect frame,
                                          int flags);
static void (*gIsMainDisplay)(IOMobileFramebufferRef framebuffer, int *isMain);

static kern_return_t smReplSwapSetLayer(IOMobileFramebufferRef framebuffer,
                                        int layer,
                                        IOSurfaceRef surface,
                                        CGRect bounds,
                                        CGRect frame,
                                        int flags) {
    if (surface != NULL) {
        if (gIsMainDisplay) {
            int isMain = 0;
            gIsMainDisplay(framebuffer, &isMain);
            if (!isMain) {
                if (gOrigSwapSetLayer != NULL) {
                    return gOrigSwapSetLayer(framebuffer, layer, surface, bounds, frame, flags);
                }
                return KERN_SUCCESS;
            }
        }

        static NSUInteger gSwapHookCalls = 0;
        if (gSwapHookCalls < 3) {
            gSwapHookCalls++;
            smLog(@"IOMFB SwapSetLayer hook call #%lu (layer %d).", (unsigned long)gSwapHookCalls, layer);
        }
        [[SMScreenCapture sharedCapture] ingestDisplaySurface:surface];
    }

    if (gOrigSwapSetLayer != NULL) {
        return gOrigSwapSetLayer(framebuffer, layer, surface, bounds, frame, flags);
    }
    return KERN_SUCCESS;
}

%ctor {
    @autoreleasepool {
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            NULL,
        };

        void *handle = NULL;
        for (size_t index = 0; paths[index] != NULL; index++) {
            handle = dlopen(paths[index], RTLD_NOW);
            if (handle != NULL) {
                break;
            }
        }

        if (handle == NULL) {
            smLog(@"IOMobileFramebuffer.framework unavailable; display hook not installed.");
            return;
        }

        gIsMainDisplay = (void (*)(IOMobileFramebufferRef, int *))dlsym(handle, "IOMobileFramebufferIsMainDisplay");
        void *swapSetLayer = dlsym(handle, "IOMobileFramebufferSwapSetLayer");
        if (swapSetLayer == NULL) {
            smLog(@"IOMobileFramebufferSwapSetLayer symbol not found.");
            return;
        }

        MSHookFunction(swapSetLayer, (void *)&smReplSwapSetLayer, (void **)&gOrigSwapSetLayer);
        smLog(@"Installed IOMobileFramebufferSwapSetLayer hook (Veency-style capture).");
    }
}
