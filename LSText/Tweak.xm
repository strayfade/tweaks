#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kLSTextPrefsID = @"com.strayfade.lstext~prefs";
static CGFloat const kLSTextYOffsetMin = -260.0f;
static CGFloat const kLSTextYOffsetMax = -80.0f;

static BOOL lstextReadBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kLSTextPrefsID);
    if (!value) {
        return fallback;
    }
    BOOL result = fallback;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numeric = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numeric)) {
            result = numeric != 0;
        }
    }
    CFRelease(value);
    return result;
}

static float lstextReadFloat(NSString *key, float fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kLSTextPrefsID);
    if (!value) {
        return fallback;
    }
    float result = fallback;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberFloatType, &result);
    }
    CFRelease(value);
    return result;
}

static NSString *lstextReadString(NSString *key, NSString *fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kLSTextPrefsID);
    if (!value) {
        return fallback;
    }
    NSString *result = fallback;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *candidate = [(__bridge NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (candidate.length > 0) {
            result = candidate;
        }
    }
    CFRelease(value);
    return result;
}

@interface LSTextCoordinator : NSObject
@property (nonatomic, strong) UIView *container;
- (void)installInController:(UIViewController *)controller;
- (void)teardown;
@end

@implementation LSTextCoordinator
- (void)installInController:(UIViewController *)controller {
    if (!controller || self.container.superview) {
        return;
    }

    UIView *host = controller.view;
    if (!host) {
        return;
    }

    NSString *textLine = lstextReadString(@"TextLine", @"Welcome");
    if (textLine.length == 0) {
        textLine = @"Welcome";
    }
    float rawOpacity = lstextReadFloat(@"TextOpacity", 95.0f);
    if (rawOpacity <= 1.0f) {
        rawOpacity *= 100.0f;
    }
    float opacityPercent = MIN(MAX(rawOpacity, 0.0f), 100.0f);
    float opacity = opacityPercent / 100.0f;

    float rawVerticalOffset = lstextReadFloat(@"VerticalOffset", 69.0f);
    float verticalPercent = rawVerticalOffset;
    if (rawVerticalOffset < 0.0f || rawVerticalOffset > 100.0f) {
        verticalPercent = ((rawVerticalOffset - kLSTextYOffsetMin) / (kLSTextYOffsetMax - kLSTextYOffsetMin)) * 100.0f;
    }
    verticalPercent = MIN(MAX(verticalPercent, 0.0f), 100.0f);
    float verticalOffset = kLSTextYOffsetMin + ((kLSTextYOffsetMax - kLSTextYOffsetMin) * (verticalPercent / 100.0f));
    float horizontalPadding = MAX(10.0f, lstextReadFloat(@"HorizontalPadding", 18.0f));

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.alpha = opacity;

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 12.0;
    label.layer.masksToBounds = YES;
    label.text = [NSString stringWithFormat:@"  %@  ", textLine];

    [container addSubview:label];
    [host addSubview:container];

    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [container.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:verticalOffset],
        [container.leadingAnchor constraintGreaterThanOrEqualToAnchor:host.leadingAnchor constant:10.0],
        [container.trailingAnchor constraintLessThanOrEqualToAnchor:host.trailingAnchor constant:-10.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:horizontalPadding * 0.2],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-(horizontalPadding * 0.2)],
        [label.heightAnchor constraintEqualToConstant:42.0],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:120.0],
        [label.widthAnchor constraintLessThanOrEqualToConstant:340.0]
    ]];

    self.container = container;
}

- (void)teardown {
    [self.container removeFromSuperview];
    self.container = nil;
}
@end

static const void *kLSTextCoordinatorKey = &kLSTextCoordinatorKey;

static void lstextInstall(UIViewController *controller) {
    if (!lstextReadBool(@"Enabled", YES)) {
        LSTextCoordinator *existing = objc_getAssociatedObject(controller, kLSTextCoordinatorKey);
        [existing teardown];
        objc_setAssociatedObject(controller, kLSTextCoordinatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    LSTextCoordinator *coordinator = objc_getAssociatedObject(controller, kLSTextCoordinatorKey);
    if (!coordinator) {
        coordinator = [LSTextCoordinator new];
        objc_setAssociatedObject(controller, kLSTextCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [coordinator installInController:controller];
}

static void lstextRemove(UIViewController *controller) {
    LSTextCoordinator *coordinator = objc_getAssociatedObject(controller, kLSTextCoordinatorKey);
    [coordinator teardown];
}

%hook CSCoverSheetViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    lstextInstall((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    lstextInstall((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    lstextRemove((UIViewController *)self);
    %orig;
}
%end

%hook SBDashBoardViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    lstextInstall((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    lstextInstall((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    lstextRemove((UIViewController *)self);
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        %init;
    }
}
