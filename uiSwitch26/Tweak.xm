#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <rootless.h>

static const CGFloat kSwitchTrackWidth = 70.0;
static const CGFloat kSwitchTrackHeight = 31.0;
static const CGFloat kSwitchThumbWidth = 62.0;
static const CGFloat kSwitchThumbHeight = 43.0;

/// High-frequency re-apply while UIKit animates the thumb (see `setOn:animated:`).
static const NSTimeInterval kSwitchSizingPulseInterval = 1.0 / 120.0;
static const NSInteger kSwitchSizingPulseMaxTicks = 90;

static const void *kSwSizingPulseTimerKey = &kSwSizingPulseTimerKey;

static void swApplySwitchVisualSizing(UIView *visualElement);

static void swInvalidateSizingPulseTimer(UISwitch *sw) {
    if (!sw) {
        return;
    }
    NSTimer *existing = objc_getAssociatedObject(sw, kSwSizingPulseTimerKey);
    if (existing) {
        [existing invalidate];
        objc_setAssociatedObject(sw, kSwSizingPulseTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL swIsSwitchVisualElementView(UIView *view) {
    if (!view) {
        return NO;
    }
    NSString *className = NSStringFromClass([view class]);
    return [className isEqualToString:@"UISwitchModernVisualElement"];
}

static UIView *swFindModernVisualElementInSwitch(UISwitch *sw) {
    if (!sw) {
        return nil;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:sw];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (swIsSwitchVisualElementView(v)) {
            return v;
        }
        for (UIView *child in v.subviews) {
            [queue addObject:child];
        }
    }
    return nil;
}

static void swApplySwitchSizingFromUISwitch(UISwitch *sw) {
    UIView *visual = swFindModernVisualElementInSwitch(sw);
    if (visual) {
        swApplySwitchVisualSizing(visual);
    }
}

static void swBeginSizingPulseForSwitch(UISwitch *sw) {
    if (!sw) {
        return;
    }
    swInvalidateSizingPulseTimer(sw);
    __weak UISwitch *weakSw = sw;
    __block NSInteger ticks = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kSwitchSizingPulseInterval repeats:YES block:^(NSTimer *t) {
        UISwitch *s = weakSw;
        if (!s) {
            [t invalidate];
            return;
        }
        swApplySwitchSizingFromUISwitch(s);
        ticks++;
        if (ticks >= kSwitchSizingPulseMaxTicks) {
            [t invalidate];
            objc_setAssociatedObject(s, kSwSizingPulseTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }];
    objc_setAssociatedObject(sw, kSwSizingPulseTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

static void swApplySizeToView(UIView *view, CGSize size, CGPoint origin) {
    if (!view) {
        return;
    }

    CGRect frame = view.frame;
    frame.origin = origin;
    frame.size = size;
    if (!CGRectEqualToRect(view.frame, frame)) {
        view.frame = frame;
    }

    CGRect bounds = view.bounds;
    bounds.origin = CGPointZero;
    bounds.size = size;
    if (!CGRectEqualToRect(view.bounds, bounds)) {
        view.bounds = bounds;
    }
}

static void swApplySizePreservingOrigin(UIView *view, CGSize size) {
    if (!view) {
        return;
    }

    CGRect frame = view.frame;
    frame.size = size;
    if (!CGRectEqualToRect(view.frame, frame)) {
        view.frame = frame;
    }

    CGRect bounds = view.bounds;
    bounds.origin = CGPointZero;
    bounds.size = size;
    if (!CGRectEqualToRect(view.bounds, bounds)) {
        view.bounds = bounds;
    }
}

static void swApplySwitchThumbWidthToImageView(UIImageView *imageView) {
    if (!imageView) {
        return;
    }
    CGSize thumbSize = CGSizeMake(kSwitchThumbWidth, kSwitchThumbHeight);
    swApplySizePreservingOrigin(imageView, thumbSize);
    imageView.clipsToBounds = NO;
}

static void swApplySwitchVisualSizing(UIView *visualElement) {
    static BOOL isApplyingSwitchSizing = NO;
    if (isApplyingSwitchSizing) {
        return;
    }
    isApplyingSwitchSizing = YES;

    if (!visualElement) {
        isApplyingSwitchSizing = NO;
        return;
    }

    NSArray<UIView *> *trackViews = visualElement.subviews;
    if (trackViews.count < 2) {
        isApplyingSwitchSizing = NO;
        return;
    }

    CGSize trackSize = CGSizeMake(kSwitchTrackWidth, kSwitchTrackHeight);
    swApplySizeToView(trackViews[0], trackSize, CGPointZero);
    swApplySizeToView(trackViews[1], trackSize, CGPointZero);

    UIView *onTrackView = trackViews[1];
    NSArray<UIView *> *onTrackSubviews = onTrackView.subviews;
    if (onTrackSubviews.count >= 3) {
        UIView *thumbView = onTrackSubviews[2];
        CGSize thumbSize = CGSizeMake(kSwitchThumbWidth, kSwitchThumbHeight);
        swApplySizePreservingOrigin(thumbView, thumbSize);
        thumbView.clipsToBounds = NO;
    }

    swApplySizeToView(visualElement, trackSize, CGPointZero);
    visualElement.clipsToBounds = NO;
    isApplyingSwitchSizing = NO;
}

static BOOL swIsTrackedSwitchThumbImageView(UIImageView *imageView) {
    if (!imageView) {
        return NO;
    }

    UIView *superview = imageView.superview;
    if (!superview) {
        return NO;
    }

    UIView *candidate = superview.superview;
    while (candidate) {
        if (swIsSwitchVisualElementView(candidate)) {
            return YES;
        }
        candidate = candidate.superview;
    }
    return NO;
}

%hook UISwitch

- (void)dealloc {
    swInvalidateSizingPulseTimer(self);
    %orig;
}

- (void)layoutSubviews {
    %orig;
    swApplySwitchSizingFromUISwitch(self);
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    if (animated) {
        swApplySwitchSizingFromUISwitch(self);
        swBeginSizingPulseForSwitch(self);
    } else {
        swApplySwitchSizingFromUISwitch(self);
    }
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kSwitchTrackWidth, kSwitchTrackHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(kSwitchTrackWidth, kSwitchTrackHeight);
}

%end

%hook UISwitchModernVisualElement

- (void)layoutSubviews {
    %orig;
    swApplySwitchVisualSizing((UIView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    swApplySwitchVisualSizing((UIView *)self);
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    swApplySwitchVisualSizing((UIView *)self);
}

%end

%hook UIImageView

- (void)layoutSubviews {
    %orig;
    UIImageView *imageView = (UIImageView *)self;
    if (!swIsTrackedSwitchThumbImageView(imageView)) {
        return;
    }
    swApplySwitchThumbWidthToImageView(imageView);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    UIImageView *imageView = (UIImageView *)self;
    if (!swIsTrackedSwitchThumbImageView(imageView)) {
        return;
    }
    swApplySwitchThumbWidthToImageView(imageView);
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    UIImageView *imageView = (UIImageView *)self;
    if (!swIsTrackedSwitchThumbImageView(imageView)) {
        return;
    }
    swApplySwitchThumbWidthToImageView(imageView);
}

%end
