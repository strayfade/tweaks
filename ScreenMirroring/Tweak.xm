#import "SMVNCServer.h"
#import "SMInputInjector.h"

%ctor {
    @autoreleasepool {
        [[SMInputInjector sharedInjector] prepareOnMainThreadIfNeeded];
        [[SMVNCServer sharedServer] handleBootstrap];
        %init;
    }
}
