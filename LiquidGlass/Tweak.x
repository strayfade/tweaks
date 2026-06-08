/*
 * Tweak.x  –  LiquidGlass
 * Dock + Folder icons: SBFloatingDockView (iPad), SBDockView (iPhone),
 * SBFolderIconImageView (home screen folder icon)
 */

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

extern void LGApplyToDockView(UIView *view);
extern void LGApplyToFolderIcon(UIView *view);
extern void LGRemoveFolderIconGlass(UIView *view);
extern void LGApplyToFolderBackground(UIView *view);
extern void LGHideFolderGlass(UIView *view);
extern void LGApplyToNotificationCell(UIView *view);
extern void LGApplyToWidget(UIView *view);
extern void LGApplyToMediaPlayer(UIView *view);
extern void LGStripMediaPlayerControls(UIView *view);
extern void LGSetupSwitchOverlay(UISwitch *sw);
extern void LGSyncSwitchOverlay(UISwitch *sw);
extern void LGTeardownSwitchOverlay(UISwitch *sw);
extern void LGSetupSliderOverlay(UISlider *s);
extern void LGSyncSliderOverlay(UISlider *s);
extern void LGTeardownSliderOverlay(UISlider *s);
extern void LGApplyToSearchBar(UIView *view);
extern void LGApplyToSpotlightSearch(UIView *view);
extern void LGApplyToLockQuickAction(UIView *view);
extern void LGApplyToDimmingKnockoutBackdrop(UIView *view);
extern void LGApplyAlertPresentation(UIView *root);
extern void LGLayoutAlertActionGroup(UIView *group);
extern void LGApplyAlertDialogHeightBoost(UIView *root);
extern void LGStyleAlertControllerActionView(UIView *action);
extern void LGStyleAlertActionRepresentationView(UIView *representation);
extern void LGApplyAlertActionSequenceSpacing(UIView *container);
extern void LGStyleAlertActionSequenceButtons(UIView *container);
extern CGFloat LGEnforceAlertActionStackSpacing(UIView *stack, CGFloat spacing);
extern void LGHideAlertVibrantSeparator(UIView *view);
extern void LGApplyToBanner(UIView *view);
extern void LGApplyToContextMenu(UIView *view);
extern void LGRemoveContextMenuGlass(UIView *view);
extern void LGApplyToSearchPill(UIView *view);
extern void LGApplyToControlCenterModule(UIView *view);
extern void LGApplyToControlCenterBackground(UIView *view);
extern void LGApplyGlassToSettingsNavButtonBackground(UIView *background);
extern void LGRemoveGlassFromSettingsNavButtonBackground(UIView *background);
extern void LGHideControlCenterGlass(UIView *view);
extern void LGTriggerBurstCapture(void);
extern void LGSuspendCaptures(double duration);

static BOOL lgPref(NSString *key);
static BOOL lgMasterEnabled(void);

// Helper: walk up to `depth` superviews and return YES if any matches `cls`.
static BOOL isInsideClass(UIView *view, NSString *cls, int depth) {
    UIView *p = view;
    for (int i = 0; i < depth && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:cls]) return YES;
    }
    return NO;
}

// Associated-object keys for per-view caching — avoids repeated ancestor walks.
// Each key stores an NSNumber (BOOL) indicating the last result of the check.
// The cache is invalidated when the view moves to a new window/superview.
static void *kLGContextMenuCacheKey = &kLGContextMenuCacheKey;
static void *kLGQuickActionCacheKey = &kLGQuickActionCacheKey;
static void *kLGQuickActionLiveRefreshKey = &kLGQuickActionLiveRefreshKey;

static void *kCC26ModuleSelectionOverlayKey = &kCC26ModuleSelectionOverlayKey;

static void LGLiveRefreshTick(UIView *view, void *key) {
    if (!view || !view.window) {
        if (view) objc_setAssociatedObject(view, key, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    LGApplyToLockQuickAction(view);
    UIView *chevron = [view viewWithTag:0x4C4751]; // kLGPageBackChevronTag
    if (chevron) [view bringSubviewToFront:chevron];
    LGTriggerBurstCapture();
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strongView = weakView;
        if (!strongView) return;
        LGLiveRefreshTick(strongView, key);
    });
}

static void LGStartLiveRefreshLoop(UIView *view, void *key) {
    if (!view) return;
    NSNumber *active = objc_getAssociatedObject(view, key);
    if (active.boolValue) return;
    objc_setAssociatedObject(view, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGLiveRefreshTick(view, key);
}

// Keep Apple's original module selected visuals intact by preserving the selection subviews.

@interface MTMaterialLayer : CALayer
@property (nonatomic, copy, readwrite) NSString *recipeName;
@property (atomic, assign, readonly) CGRect visibleRect;
@end

@interface CALayer ()
@property (atomic, assign, readwrite) id unsafeUnretainedDelegate;
@end

CGFloat calculatedRadius(CGRect visibleRect, CGFloat radius) {
    CGFloat width = visibleRect.size.width;
    CGFloat height = visibleRect.size.height;

    if (CGSizeEqualToSize(visibleRect.size, [UIScreen mainScreen].bounds.size) || width <= 60 || height <= 60) {
        return radius;
    }

    if (height >= 300 && height <= 400 && width >= 100 && width <= 200) {
        return radius;
    }

    if ((fabs(width - height) < 1.0 || width >= 250) && height <= 76) {
        return floor(MIN(width, height) / 2.0);
    }

    return 25;
}

static CGFloat cc26GetModuleRadius(UIView *moduleView) {
    CGFloat width = moduleView.bounds.size.width;
    CGFloat height = moduleView.bounds.size.height;
    if ((width < 100 && height < 100) && fabs(width - height) < 0.01) {
        return width / 2.0;
    } else if (width > height || height > width) {
        return fminf(width, height) / 2.0;
    } else if ((width > 100 && height > 100) && fabs(width - height) < 0.01) {
        return width / 4.0;
    } else if (width > 100 && height > 100) {
        return width / 4.0;
    }
    return 0;
}

static BOOL cc26ModuleExpanded(UIView *moduleView) {
    @try {
        id expanded = [moduleView valueForKey:@"_expanded"];
        if ([expanded respondsToSelector:@selector(boolValue)]) {
            return [expanded boolValue];
        }
    } @catch (NSException *e) {
    }
    return NO;
}

%hook MTMaterialLayer
- (CGFloat)cornerRadius {
    CGFloat radius = %orig;
    NSArray <NSString *> *titles = @[@"modules", @"moduleFill.highlight.generatedRecipe"];

    if ([titles containsObject:self.recipeName]) {
        radius = calculatedRadius(self.visibleRect, radius);
    }

    return radius;
}
%end

%hook CALayer
- (CGFloat)cornerRadius {
    CGFloat radius = %orig;
    // Cache the class lookup — NSClassFromString is surprisingly slow on the hot-path.
    static Class ccuiButtonModuleViewClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ccuiButtonModuleViewClass = NSClassFromString(@"CCUIButtonModuleView"); });
    if (ccuiButtonModuleViewClass &&
        [self.superlayer.unsafeUnretainedDelegate isKindOfClass:ccuiButtonModuleViewClass]) {
        radius = calculatedRadius(self.visibleRect, radius);
    }

    return radius;
}
%end

// CC hooks disabled because they were causing Control Center crashes.
// @interface CCUIButtonModuleView : UIView
// @end
//
// %group ControlCenter
// %hook CCUIButtonModuleView
// - (void)didMoveToWindow {
//     %orig;
//     UIView *v = (UIView *)self;
//     if (v.window) LGApplyToControlCenterModule(v);
// }
// - (void)layoutSubviews {
//     %orig;
//     UIView *v = (UIView *)self;
//     if (v.window) LGApplyToControlCenterModule(v);
// }
// %end
// %end

// Walk the responder chain from 'view' to find the nearest SBHWidgetStackViewController.
static UIViewController *LGNearestWidgetStackVC(UIView *view) {
    UIResponder *r = view;
    while (r) {
        if ([NSStringFromClass([r class]) isEqualToString:@"SBHWidgetStackViewController"]
            && [r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// Returns YES when v is the MTMaterial blur background of a homescreen widget.
// Matches liquidass: parent must be EXACTLY UIView class + have SBHWidgetStackViewController
// in the responder chain + be the VC's view or its direct child.
static BOOL LGIsWidgetMaterialView(UIView *v) {
    UIView *parent = v.superview;
    if (!parent) return NO;
    // Parent must be exactly UIView, not a named subclass
    if (![NSStringFromClass([parent class]) isEqualToString:@"UIView"]) return NO;
    UIViewController *vc = LGNearestWidgetStackVC(parent);
    if (!vc) return NO;
    return vc.view == parent || parent.superview == vc.view;
}

// Per-MTMaterialView widget-classification cache (avoids repeated responder-chain walks)
static void *kLGWidgetClassified = &kLGWidgetClassified; // @YES / @NO

%group FloatingDock
%hook SBFloatingDockView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToDockView(v);
}
%end
%end

%group Dock
%hook SBDockView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToDockView(v);
}
%end
%end

// Lock screen media player — CSAdjunctItemView is the outer rounded card that wraps the
// Now Playing widget. MPUSystemMediaControlsView is its inner controls container.
// We apply glass to CSAdjunctItemView (the whole card) and strip material from
// MPUSystemMediaControlsView so nothing bleeds through.
//
// Guard: on iOS 26 Apple reused CSAdjunctItemView for lockscreen widgets beyond just the
// media player (e.g. the clock/date capsule). Only apply glass if MPUSystemMediaControlsView
// exists as a descendant — confirming this is actually a Now Playing card.
static BOOL LG_hasMPUControls(UIView *root, int depth) {
    if (depth > 6) return NO;
    static Class mpuCls;
    if (!mpuCls) mpuCls = NSClassFromString(@"MPUSystemMediaControlsView");
    if (mpuCls && [root isKindOfClass:mpuCls]) return YES;
    for (UIView *sub in root.subviews)
        if (LG_hasMPUControls(sub, depth + 1)) return YES;
    return NO;
}

%group MediaPlayer
%hook CSAdjunctItemView
- (void)setBackgroundColor:(UIColor *)color {
    // Force clear — intercepting at ObjC level prevents any code from re-applying background.
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
    ((UIView *)self).layer.borderWidth = 0;
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window && LG_hasMPUControls(v, 0)) LGApplyToMediaPlayer(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window && LG_hasMPUControls(v, 0)) LGApplyToMediaPlayer(v);
}
%end
%end

%group MediaPlayerControls
%hook MPUSystemMediaControlsView
// Strip-only — no glass. The outer CSAdjunctItemView owns the single glass layer.
// Adding glass here too creates a visible inner glass card on top of the outer one.
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGStripMediaPlayerControls(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGStripMediaPlayerControls(v);
}
%end
%end

// ── Lock screen wallpaper dim when unread notifications are present ─────────
static const NSUInteger kLGNotificationWallpaperDimTag = 0x4C474E44; // "LGND"
static const CGFloat kLGNotificationWallpaperDimOpacity = 0.38;
static const NSTimeInterval kLGNotificationWallpaperDimFade = 0.32;
static void *kLGNotificationDimLastVisibleKey = &kLGNotificationDimLastVisibleKey;

static BOOL LGNotificationWallpaperDimEnabled(void) {
    return lgMasterEnabled() && lgPref(@"notificationEnabled");
}

static BOOL LGLockScreenWindowClassName(NSString *cls) {
    return cls.length > 0 &&
           ([cls containsString:@"CoverSheet"] || [cls containsString:@"LockScreen"]);
}

static UIWindow *LGLockScreenKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive)
                continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (LGLockScreenWindowClassName(NSStringFromClass([window class])))
                    return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in app.windows) {
        if (LGLockScreenWindowClassName(NSStringFromClass([window class])))
            return window;
    }
#pragma clang diagnostic pop
    return nil;
}

static UIWindow *LGWallpaperWindow(void) {
    static Class wallpaperWindowCls, wallpaperSecureWindowCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wallpaperWindowCls = NSClassFromString(@"_SBWallpaperWindow");
        wallpaperSecureWindowCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    });

    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    UIWindow *secureFallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (wallpaperWindowCls && [window isKindOfClass:wallpaperWindowCls])
                    return window;
                if (wallpaperSecureWindowCls && [window isKindOfClass:wallpaperSecureWindowCls])
                    secureFallback = window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in app.windows) {
        if (wallpaperWindowCls && [window isKindOfClass:wallpaperWindowCls])
            return window;
        if (wallpaperSecureWindowCls && [window isKindOfClass:wallpaperSecureWindowCls])
            secureFallback = window;
    }
#pragma clang diagnostic pop
    return secureFallback;
}

static UIView *LGFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = LGFindSubviewOfClass(sub, cls);
        if (found) return found;
    }
    return nil;
}

static UIView *LGFindWallpaperAnchorInWindow(UIWindow *window) {
    if (!window) return nil;

    static Class staticWallpaperCls, replicaCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        staticWallpaperCls = NSClassFromString(@"SBFStaticWallpaperImageView");
        replicaCls = NSClassFromString(@"PBUISnapshotReplicaView");
    });

    if (staticWallpaperCls) {
        UIView *staticWallpaper = LGFindSubviewOfClass(window, staticWallpaperCls);
        if (staticWallpaper) return staticWallpaper;
    }
    if (replicaCls) {
        UIView *replica = LGFindSubviewOfClass(window, replicaCls);
        if (replica) return replica;
    }

    UIView *best = nil;
    CGFloat bestArea = 0;
    CGFloat screenArea = CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        NSString *cls = NSStringFromClass([view class]);
        if ([cls rangeOfString:@"Wallpaper"].location != NSNotFound &&
            [cls rangeOfString:@"Tint"].location == NSNotFound) {
            CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
            if (area > bestArea) {
                bestArea = area;
                best = view;
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    if (best && bestArea >= screenArea * 0.35) return best;
    return nil;
}

static BOOL LGIsNestedNotificationListCell(UIView *cell) {
    static Class cellCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cellCls = NSClassFromString(@"NCNotificationListCell");
    });
    if (!cellCls || ![cell isKindOfClass:cellCls]) return NO;
    for (UIView *parent = cell.superview; parent; parent = parent.superview) {
        if (parent != cell && [parent isKindOfClass:cellCls]) return YES;
    }
    return NO;
}

static BOOL LGNotificationListCellCountsForDim(UIView *cell) {
    if (!cell || LGIsNestedNotificationListCell(cell)) return NO;
    if (!cell.window) return NO;
    if (!LGLockScreenWindowClassName(NSStringFromClass([cell.window class]))) return NO;
    if (cell.hidden || cell.alpha <= 0.02) return NO;

    CGRect bounds = cell.bounds;
    if (bounds.size.width < 60.0 || bounds.size.height < 18.0) return NO;

    return YES;
}

static NSUInteger LGCountLockScreenNotificationsForDim(UIView *root) {
    if (!root) return 0;

    static Class cellCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cellCls = NSClassFromString(@"NCNotificationListCell");
    });
    if (!cellCls) return 0;

    NSUInteger count = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:cellCls] && LGNotificationListCellCountsForDim(view))
            count++;
        [stack addObjectsFromArray:view.subviews];
    }
    return count;
}

static BOOL LGViewIsNotificationListContainer(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass([view class]);
    return [cls isEqualToString:@"NCNotificationListScrollView"] ||
           [cls isEqualToString:@"NCNotificationListView"];
}

static UIView *LGFindNotificationListContainerInView(UIView *root) {
    if (!root) return nil;
    if (LGViewIsNotificationListContainer(root)) return root;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (LGViewIsNotificationListContainer(view)) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

static UIView *LGFindCSCoverSheetViewInHierarchy(UIView *root) {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) isEqualToString:@"CSCoverSheetView"]) return root;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([NSStringFromClass([view class]) isEqualToString:@"CSCoverSheetView"]) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

static UIView *LGCoverSheetWallpaperAnchorView(UIView *coverSheet) {
    if (!coverSheet) return nil;

    static SEL wallpaperEffectSel, tintingSel, backgroundSel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wallpaperEffectSel = NSSelectorFromString(@"wallpaperEffectView");
        tintingSel = NSSelectorFromString(@"tintingView");
        backgroundSel = NSSelectorFromString(@"backgroundView");
    });

    if (wallpaperEffectSel && [coverSheet respondsToSelector:wallpaperEffectSel]) {
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(coverSheet, wallpaperEffectSel);
        if (v) return v;
    }
    if (tintingSel && [coverSheet respondsToSelector:tintingSel]) {
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(coverSheet, tintingSel);
        if (v) return v;
    }
    if (backgroundSel && [coverSheet respondsToSelector:backgroundSel]) {
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(coverSheet, backgroundSel);
        if (v) return v;
    }
    return nil;
}

static UIView *LGCoverSheetSubviewForSelector(UIView *coverSheet, SEL sel) {
    if (!coverSheet || !sel || ![coverSheet respondsToSelector:sel]) return nil;
    UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(coverSheet, sel);
    return [v isKindOfClass:[UIView class]] ? v : nil;
}

static UIView *LGFindNotificationStructuredListRootView(UIView *root) {
    static Class vcCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        vcCls = NSClassFromString(@"NCNotificationStructuredListViewController");
    });
    if (!vcCls || !root) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        id responder = view.nextResponder;
        if ([responder isKindOfClass:vcCls]) {
            UIViewController *vc = (UIViewController *)responder;
            return vc.view ?: view;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

/// Lowest direct CSCoverSheetView child that contains the notification list — dim goes below this.
static UIView *LGCoverSheetZOrderCeilingForDim(UIView *coverSheet) {
    if (!coverSheet) return nil;

    UIView *structuredRoot = LGFindNotificationStructuredListRootView(coverSheet);
    if (structuredRoot) {
        for (UIView *v = structuredRoot; v && v != coverSheet; v = v.superview) {
            if (v.superview == coverSheet) return v;
        }
    }

    static SEL higherSlideableSel, slideableSel, mainPageSel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        higherSlideableSel = NSSelectorFromString(@"higherSlideableContentView");
        slideableSel = NSSelectorFromString(@"slideableContentView");
        mainPageSel = NSSelectorFromString(@"mainPageView");
    });

    UIView *higher = LGCoverSheetSubviewForSelector(coverSheet, higherSlideableSel);
    if (higher) return higher;
    UIView *slideable = LGCoverSheetSubviewForSelector(coverSheet, slideableSel);
    if (slideable) return slideable;
    return LGCoverSheetSubviewForSelector(coverSheet, mainPageSel);
}

static void LGInstallCoverSheetNotificationWallpaperDim(UIView *coverSheet, UIView *dim) {
    if (!coverSheet || !dim) return;

    UIView *ceiling = LGCoverSheetZOrderCeilingForDim(coverSheet);

    if (ceiling && ceiling.superview == coverSheet) {
        // Full-screen dim below NCNotificationStructuredListViewController / slideable content.
        [coverSheet insertSubview:dim belowSubview:ceiling];
    } else {
        if (dim.superview != coverSheet) [dim removeFromSuperview];
        UIView *anchor = LGCoverSheetWallpaperAnchorView(coverSheet);
        if (anchor && anchor.superview == coverSheet)
            [coverSheet insertSubview:dim aboveSubview:anchor];
        else
            [coverSheet insertSubview:dim atIndex:0];
    }

    dim.frame = coverSheet.bounds;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

static UIView *LGGetOrCreateNotificationWallpaperDimView(UIView *host) {
    if (!host) return nil;
    UIView *dim = [host viewWithTag:kLGNotificationWallpaperDimTag];
    if (dim) return dim;

    dim = [[UIView alloc] initWithFrame:host.bounds];
    dim.tag = kLGNotificationWallpaperDimTag;
    dim.userInteractionEnabled = NO;
    dim.backgroundColor = [UIColor blackColor];
    dim.alpha = 0.0;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.accessibilityElementsHidden = YES;
    return dim;
}

static void LGInstallNotificationWallpaperDimView(UIView *host, UIView *dim, UIView *anchor) {
    if (!host || !dim) return;
    if (dim.superview != host) {
        [dim removeFromSuperview];
        if (anchor && anchor.superview == host)
            [host insertSubview:dim aboveSubview:anchor];
        else
            [host insertSubview:dim atIndex:0];
    }
    dim.frame = host.bounds;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

static void LGSetNotificationWallpaperDimVisible(BOOL visible, UIView *dim) {
    if (!dim) return;
    NSNumber *last = objc_getAssociatedObject(dim, kLGNotificationDimLastVisibleKey);
    if (last && last.boolValue == visible) return;
    objc_setAssociatedObject(dim, kLGNotificationDimLastVisibleKey, @(visible), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat targetAlpha = visible ? kLGNotificationWallpaperDimOpacity : 0.0;
    if (fabs(dim.alpha - targetAlpha) < 0.01) {
        dim.alpha = targetAlpha;
        return;
    }

    [UIView animateWithDuration:kLGNotificationWallpaperDimFade
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        dim.alpha = targetAlpha;
    } completion:nil];
}

static void LGFadeOutNotificationDimsInHierarchy(UIView *root) {
    if (!root) return;
    UIView *dim = [root viewWithTag:kLGNotificationWallpaperDimTag];
    if (dim) LGSetNotificationWallpaperDimVisible(NO, dim);
    for (UIView *sub in root.subviews)
        LGFadeOutNotificationDimsInHierarchy(sub);
}

static void LGRefreshLockScreenNotificationWallpaperDim(UIView *listHint) {
    UIWindow *lockWindow = listHint.window;
    if (!lockWindow) lockWindow = LGLockScreenKeyWindow();

    if (!LGNotificationWallpaperDimEnabled()) {
        if (lockWindow) LGFadeOutNotificationDimsInHierarchy(lockWindow);
        UIWindow *wallpaperWindow = LGWallpaperWindow();
        if (wallpaperWindow && wallpaperWindow != lockWindow)
            LGFadeOutNotificationDimsInHierarchy(wallpaperWindow);
        return;
    }

    if (!lockWindow) return;

    UIView *listRoot = (listHint && LGViewIsNotificationListContainer(listHint))
        ? listHint
        : LGFindNotificationListContainerInView(lockWindow);
    NSUInteger notificationCount = LGCountLockScreenNotificationsForDim(listRoot ?: lockWindow);
    if (notificationCount == 0 && listRoot != lockWindow)
        notificationCount = LGCountLockScreenNotificationsForDim(lockWindow);
    BOOL shouldDim = notificationCount > 0;

    UIView *coverSheet = LGFindCSCoverSheetViewInHierarchy(lockWindow);
    if (coverSheet) {
        UIView *dim = LGGetOrCreateNotificationWallpaperDimView(coverSheet);
        LGInstallCoverSheetNotificationWallpaperDim(coverSheet, dim);
        LGSetNotificationWallpaperDimVisible(shouldDim, dim);
    }

    UIWindow *wallpaperWindow = LGWallpaperWindow();
    if (!coverSheet && wallpaperWindow && wallpaperWindow != lockWindow) {
        UIView *anchor = LGFindWallpaperAnchorInWindow(wallpaperWindow);
        UIView *host = anchor.superview ?: wallpaperWindow;
        UIView *dim = LGGetOrCreateNotificationWallpaperDimView(host);
        LGInstallNotificationWallpaperDimView(host, dim, anchor);
        LGSetNotificationWallpaperDimVisible(shouldDim, dim);
    } else if (!coverSheet) {
        UIView *anchor = LGFindWallpaperAnchorInWindow(lockWindow);
        UIView *host = anchor.superview ?: lockWindow;
        UIView *dim = LGGetOrCreateNotificationWallpaperDimView(host);
        LGInstallNotificationWallpaperDimView(host, dim, anchor);
        LGSetNotificationWallpaperDimVisible(shouldDim, dim);
    }
}

static void *kLGNotificationDimRefreshScheduledKey = &kLGNotificationDimRefreshScheduledKey;

static void LGScheduleLockScreenNotificationWallpaperDimRefresh(UIView *listHint) {
    if (!LGNotificationWallpaperDimEnabled()) {
        LGRefreshLockScreenNotificationWallpaperDim(listHint);
        return;
    }

    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    if (objc_getAssociatedObject(app, kLGNotificationDimRefreshScheduledKey)) return;
    objc_setAssociatedObject(app, kLGNotificationDimRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakHint = listHint;
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(app, kLGNotificationDimRefreshScheduledKey, nil, OBJC_ASSOCIATION_ASSIGN);
        LGRefreshLockScreenNotificationWallpaperDim(weakHint);
    });
}

%group LockScreenNotificationDim
%hook CSCoverSheetView
- (void)layoutSubviews {
    %orig;
    LGScheduleLockScreenNotificationWallpaperDimRefresh(nil);
}
%end

%hook CSCoverSheetViewController
- (void)viewDidLayoutSubviews {
    %orig;
    LGScheduleLockScreenNotificationWallpaperDimRefresh(nil);
}
%end

%hook SBDashBoardViewController
- (void)viewDidLayoutSubviews {
    %orig;
    LGScheduleLockScreenNotificationWallpaperDimRefresh(nil);
}
%end

%hook NCNotificationListView
- (void)layoutSubviews {
    %orig;
    LGScheduleLockScreenNotificationWallpaperDimRefresh((UIView *)self);
}
%end

%hook NCNotificationStructuredListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    LGScheduleLockScreenNotificationWallpaperDimRefresh(((UIViewController *)self).view);
}
%end
%end

// ── Lock screen seamless notification text (NCNotificationSeamlessContentView) ─
static BOOL LGSeamlessNotificationTextEnabled(void) {
    return lgMasterEnabled() && lgPref(@"notificationEnabled");
}

static BOOL LGIsInsideNCNotificationSeamlessContentView(UIView *view) {
    if (!view) return NO;
    static Class seamlessCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seamlessCls = NSClassFromString(@"NCNotificationSeamlessContentView");
    });
    if (!seamlessCls) return NO;
    for (UIView *parent = view; parent; parent = parent.superview) {
        if ([parent isKindOfClass:seamlessCls]) return YES;
    }
    return NO;
}

static Class LGBSUIRelativeDateLabelClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"BSUIRelativeDateLabel");
    });
    return cls;
}

static BOOL LGIsBSUIRelativeDateLabel(UIView *view) {
    Class cls = LGBSUIRelativeDateLabelClass();
    return cls && view && [view isKindOfClass:cls];
}

static BOOL LGIsLockScreenNotificationTextView(UIView *view) {
    if (!view || !view.window) return NO;
    if (!LGLockScreenWindowClassName(NSStringFromClass([view.window class]))) return NO;
    for (UIView *parent = view; parent; parent = parent.superview) {
        NSString *cls = NSStringFromClass([parent class]);
        if ([cls hasPrefix:@"NCNotification"]) return YES;
    }
    return NO;
}

static BOOL LGShouldStyleSeamlessNotificationTextView(UIView *view) {
    if (LGIsInsideNCNotificationSeamlessContentView(view)) return YES;
    if (LGIsBSUIRelativeDateLabel(view) && LGIsLockScreenNotificationTextView(view)) return YES;
    return NO;
}

static BOOL LGViewLooksLikeNotificationTextElement(UIView *view) {
    if (!view) return NO;
    if (LGIsBSUIRelativeDateLabel(view)) return YES;
    if ([view isKindOfClass:[UILabel class]]) return YES;
    if ([view isKindOfClass:[UITextView class]]) return YES;
    if (![view respondsToSelector:@selector(setTextColor:)]) return NO;
    NSString *cls = NSStringFromClass([view class]);
    if ([cls containsString:@"Label"] || [cls containsString:@"Text"] ||
        [cls containsString:@"Title"] || [cls containsString:@"Subtitle"] ||
        [cls containsString:@"Body"] || [cls containsString:@"Caption"] ||
        [cls containsString:@"Summary"] || [cls containsString:@"Header"])
        return YES;
    return NO;
}

static void LGApplyWhiteTextToLabel(UILabel *label) {
    if (!label) return;
    label.textColor = [UIColor whiteColor];
    if (label.attributedText.length) {
        NSMutableAttributedString *styled = [label.attributedText mutableCopy];
        [styled addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor]
                       range:NSMakeRange(0, styled.length)];
        label.attributedText = [styled copy];
    }
}

static void LGApplyWhiteTextToBSUIRelativeDateLabel(UIView *view) {
    if (!LGIsBSUIRelativeDateLabel(view)) return;
    if ([view isKindOfClass:[UILabel class]]) {
        LGApplyWhiteTextToLabel((UILabel *)view);
        return;
    }
    if ([view respondsToSelector:@selector(setTextColor:)]) {
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(view, @selector(setTextColor:), [UIColor whiteColor]);
    }
}

static void LGApplySeamlessNotificationTextStylesInView(UIView *root) {
    if (!root || !LGSeamlessNotificationTextEnabled()) return;
    if (!LGIsInsideNCNotificationSeamlessContentView(root) &&
        ![NSStringFromClass([root class]) isEqualToString:@"NCNotificationSeamlessContentView"])
        return;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (!LGShouldStyleSeamlessNotificationTextView(view)) {
            [stack addObjectsFromArray:view.subviews];
            continue;
        }

        if (LGIsBSUIRelativeDateLabel(view)) {
            LGApplyWhiteTextToBSUIRelativeDateLabel(view);
        } else if ([view isKindOfClass:[UILabel class]]) {
            LGApplyWhiteTextToLabel((UILabel *)view);
        } else if ([view isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)view;
            textView.textColor = [UIColor whiteColor];
            if (textView.attributedText.length) {
                NSMutableAttributedString *styled = [textView.attributedText mutableCopy];
                [styled addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor]
                               range:NSMakeRange(0, styled.length)];
                textView.attributedText = [styled copy];
            }
        } else if (LGViewLooksLikeNotificationTextElement(view) &&
                   [view respondsToSelector:@selector(setTextColor:)]) {
            ((void (*)(id, SEL, UIColor *))objc_msgSend)(view, @selector(setTextColor:), [UIColor whiteColor]);
        }

        [stack addObjectsFromArray:view.subviews];
    }
}

%group NotificationSeamlessText
%hook NCNotificationSeamlessContentView
- (void)layoutSubviews {
    %orig;
    LGApplySeamlessNotificationTextStylesInView((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window)
        LGApplySeamlessNotificationTextStylesInView((UIView *)self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    if (LGSeamlessNotificationTextEnabled() && LGShouldStyleSeamlessNotificationTextView(self)) {
        %orig([UIColor whiteColor]);
        return;
    }
    %orig;
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (LGSeamlessNotificationTextEnabled() && LGShouldStyleSeamlessNotificationTextView(self) && text.length) {
        NSMutableAttributedString *styled = [text mutableCopy];
        [styled addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor]
                       range:NSMakeRange(0, styled.length)];
        %orig([styled copy]);
        return;
    }
    %orig;
}
%end

%hook BSUIRelativeDateLabel
- (void)layoutSubviews {
    %orig;
    if (LGSeamlessNotificationTextEnabled())
        LGApplyWhiteTextToBSUIRelativeDateLabel((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (LGSeamlessNotificationTextEnabled() && ((UIView *)self).window)
        LGApplyWhiteTextToBSUIRelativeDateLabel((UIView *)self);
}
- (void)setTextColor:(UIColor *)color {
    if (LGSeamlessNotificationTextEnabled() && LGIsLockScreenNotificationTextView((UIView *)self)) {
        %orig([UIColor whiteColor]);
        return;
    }
    %orig;
}
%end
%end

// Home screen banner notifications — NCNotificationShortLookView is the rounded pill that
// slides down from the top of the screen. Glass uses no white/dark material tint.
%group Banner
%hook NCNotificationShortLookView
- (void)setBackgroundColor:(UIColor *)color {
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
    ((UIView *)self).layer.borderWidth = 0;
    ((UIView *)self).layer.borderColor = [UIColor clearColor].CGColor;
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToBanner(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToBanner(v);
}
%end
%end

// Lock screen notification cells — NCNotificationListCell is the rounded pill per-notification.
// didMoveToWindow: initial setup when cell enters screen.
// layoutSubviews: O(1) frame sync for cells that already have glass; for cells without glass,
// checks the transform — only cells with identity transform (top of stack or expanded) get
// glass created. Peeking stack cards have a scale/translate transform and are skipped until
// the user expands the stack, at which point their transform becomes identity during the
// animation and glass is created lazily.
%group Notification
%hook NCNotificationListCell
- (void)setBackgroundColor:(UIColor *)color {
    // Always force clear — UIKit constantly re-applies the tinted pill colour via direct
    // property set; intercepting here prevents ANY code from setting a background.
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
    ((UIView *)self).layer.borderWidth = 0;
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToNotificationCell(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToNotificationCell(v);
    LGScheduleLockScreenNotificationWallpaperDimRefresh(v);
}
%end
%end

// NC container: fires once when the whole NC panel enters/leaves the window,
// NOT once per cell — prevents per-cell suspension that freezes glass during scrolling.
%group NCContainer
%hook NCNotificationListScrollView
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (newWindow) {
        // NC sliding in: suspend so new glass cells capture at settled position.
        LGSuspendCaptures(0.45);
    } else {
        // NC dismissing: brief suspend so homescreen glass doesn't capture mid-dismiss.
        LGSuspendCaptures(0.35);
    }
    LGScheduleLockScreenNotificationWallpaperDimRefresh((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGScheduleLockScreenNotificationWallpaperDimRefresh((UIView *)self);
}
%end
%end

// UISlider → LiquidGlassSlider overlay
%group Slider
%hook UISlider
- (void)didMoveToSuperview {
    %orig;
    if (((UIView *)self).superview) LGSetupSliderOverlay((UISlider *)self);
}
- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (!newSuperview) LGTeardownSliderOverlay((UISlider *)self);
    %orig;
}
- (void)layoutSubviews {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
- (void)setValue:(float)value animated:(BOOL)animated {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
// Re-hide native layers on every touch phase — UISlider rebuilds its sublayers
// during tracking, causing the original thumb/track to peek through between layout passes.
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL r = %orig;
    LGSyncSliderOverlay((UISlider *)self);
    return r;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL r = %orig;
    LGSyncSliderOverlay((UISlider *)self);
    return r;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    LGSyncSliderOverlay((UISlider *)self);
}
%end
%end

// UISwitch → LiquidGlassSwitch overlay
%group Switch
%hook UISwitch
- (void)didMoveToSuperview {
    %orig;
    if (((UIView *)self).superview) LGSetupSwitchOverlay((UISwitch *)self);
}
- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (!newSuperview) LGTeardownSwitchOverlay((UISwitch *)self);
    %orig;
}
- (void)layoutSubviews {
    %orig;
    LGSyncSwitchOverlay((UISwitch *)self);
}
- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    LGSyncSwitchOverlay((UISwitch *)self);
}
%end
%end

// Home screen folder icon — SBFolderIconImageView is the 60×60 rounded-rect
// that renders the mini-app grid. Hook layoutSubviews to apply glass each layout pass.
// Size guard: actual folder icon cards are ≥ 44 pt. The tiny app-preview thumbnails
// rendered inside the folder grid are smaller — skip those entirely.
%group FolderIcon
%hook SBFolderIconImageView
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    if (v.bounds.size.width < 44) return;  // skip mini thumbnails inside folder grid
    UIView *p = v.superview;
    while (p) {
        if ([NSStringFromClass([p class]) containsString:@"Library"]) return;
        p = p.superview;
    }
    LGApplyToFolderIcon(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    if (v.bounds.size.width < 44) return;  // skip mini thumbnails inside folder grid
    UIView *p = v.superview;
    while (p) {
        if ([NSStringFromClass([p class]) containsString:@"Library"]) return;
        p = p.superview;
    }
    LGApplyToFolderIcon(v);
}
%end
%end

static void LGKillBackdropsInLayer(CALayer *layer) {
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    for (CALayer *sub in layer.sublayers) {
        if (backdropClass && [sub isKindOfClass:backdropClass]) {
            [sub setValue:@NO forKey:@"enabled"];
            sub.opacity = 0;
        }
        LGKillBackdropsInLayer(sub);
    }
}

// Open folder background — SBFolderBackgroundView holds the blur pill.
// Glass fades in after the open animation; alpha resets to 0 before close.
%group FolderBG
%hook SBFolderBackgroundView
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (newWindow) {
        // Suspend captures on all existing-texture glass views for 0.5 s (folder open
        // animation duration). Prevents dock/icon glass from sampling the mid-open frame.
        // captureSchedulerFired() auto-bursts when the window expires to repaint cleanly.
        LGSuspendCaptures(0.5);
        // Folder opening — always hide glass + kill backdrop BEFORE any frame is rendered.
        // This fires before the open animation starts, so the compositor never sees the glass.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (UIView *sub in v.subviews) {
            sub.hidden = YES;
            LGKillBackdropsInLayer(sub.layer);
        }
        [CATransaction commit];
        // LGApplyToFolderBackground will schedule the reveal via deferFolderGlass.
    } else {
        // Folder closing — hide glass and suspend captures so dock/icon glass don't
        // sample the close animation. Auto-burst resumes them cleanly after 0.35 s.
        LGSuspendCaptures(0.35);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (UIView *sub in v.subviews) {
            sub.hidden = YES;
            LGKillBackdropsInLayer(sub.layer);
        }
        [CATransaction commit];
    }
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    // Always re-setup: ensures reveal is scheduled even on view reuse.
    if (v.window) LGApplyToFolderBackground(v);
}
%end
%end

// Kill _UIBackdropView the instant it enters SBFolderBackgroundView or CSAdjunctItemView.
// Only checks 4 levels — these views are always close ancestors.
%group FolderBackdropKiller
%hook _UIBackdropView
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    UIView *p = newSuperview;
    for (int i = 0; i < 4 && p; i++, p = p.superview) {
        NSString *cls = NSStringFromClass([p class]);
        if ([cls isEqualToString:@"SBFolderBackgroundView"] ||
            [cls isEqualToString:@"CSAdjunctItemView"]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ((UIView *)self).alpha = 0;
            ((UIView *)self).hidden = YES;
            [((UIView *)self).layer setValue:@NO forKey:@"enabled"];
            [CATransaction commit];
            return;
        }
    }
}
- (void)didMoveToSuperview {
    %orig;
    if (!((UIView *)self).superview) return;
    UIView *p = ((UIView *)self).superview;
    for (int i = 0; i < 4 && p; i++, p = p.superview) {
        NSString *cls = NSStringFromClass([p class]);
        if ([cls isEqualToString:@"SBFolderBackgroundView"] ||
            [cls isEqualToString:@"CSAdjunctItemView"]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ((UIView *)self).alpha = 0;
            ((UIView *)self).hidden = YES;
            [((UIView *)self).layer setValue:@NO forKey:@"enabled"];
            [CATransaction commit];
            return;
        }
    }
}
%end
%end

// App Library search bar — SBHSearchTextField is the rounded search field at the top.
%group SearchBar
%hook SBHSearchTextField
- (void)setBackgroundColor:(UIColor *)color {
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSearchBar(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) {
        // App Library search bar appeared — redundant suspension (LiquidGlassAL.x already
        // suspends on pod didMoveToWindow), but kept as belt-and-suspenders for devices
        // where the search bar appears before any pod.
        LGSuspendCaptures(0.45);
        LGApplyToSearchBar(v);
    } else {
        // Search bar leaving window = App Library is closing. Suspend to prevent
        // homescreen glass views from burst-capturing during the slide-out animation.
        LGSuspendCaptures(0.35);
    }
}
%end
%end

// Home screen Spotlight search pill — SBSearchBarTextField is the search input on the home screen.
%group SpotlightSearch
%hook SBSearchBarTextField
- (void)setBackgroundColor:(UIColor *)color {
    %orig([UIColor clearColor]);
    ((UIView *)self).layer.backgroundColor = [UIColor clearColor].CGColor;
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSpotlightSearch(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToSpotlightSearch(v);
}
%end
%end

// Kill MTMaterialView when inside the App Library search bar hierarchy.
// Depth 4: MTMaterialView is always close to SBHSearchTextField or SBSearchBarTextField.
%group SearchBarMaterial
%hook MTMaterialView
// Called every layout pass — fire on the superview if size + window match the quick action circle.
- (void)layoutSubviews {
    %orig;
    UIView *v  = (UIView *)self;
    UIView *sv = v.superview;
    if (!sv || !v.window) return;

    // Homescreen widget glass: replace the MTMaterial blur with LiquidGlass.
    // Cache ONLY confirmed-YES results so we skip the expensive responder-chain walk
    // on subsequent layout passes for known widget views.  Never cache NO — the widget
    // hierarchy may not be fully connected on the first layout pass (e.g. VC not yet in
    // the responder chain), so uncategorised views must be re-checked each pass until
    // they are either confirmed as widgets or leave the window.
    {
        NSNumber *cached = objc_getAssociatedObject(v, kLGWidgetClassified);
        if (cached) {
            // Already confirmed as a widget MTMaterialView — keep it hidden.
            // Guard all property writes: only write when the view is not yet hidden.
            // This avoids redundant UIKit/CALayer work on every layout pass.
            if (!v.hidden) {
                v.hidden = YES; v.alpha = 0; v.layer.opacity = 0;
                // Disable the CABackdropLayer so it stops sampling the backdrop every
                // frame in the GPU compositor — this is the main widget-glass perf fix.
                LGKillBackdropsInLayer(v.layer);
            }
            LGApplyToWidget(sv);
            return;
        }
        if (LGIsWidgetMaterialView(v)) {
            objc_setAssociatedObject(v, kLGWidgetClassified, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            v.hidden = YES; v.alpha = 0; v.layer.opacity = 0;
            // Disable the CABackdropLayer on first classification.
            LGKillBackdropsInLayer(v.layer);
            LGApplyToWidget(sv);
            return;
        }
        // Not a widget (yet) — do NOT cache; retry on next layout pass.
    }

    // Suppress in App Library / search bar ancestors (class-name route, depth 4).
    if (isInsideClass(sv, @"SBHSearchTextField", 4) ||
        isInsideClass(sv, @"SBSearchBarTextField", 4)) {
        v.hidden = YES; v.alpha = 0; v.layer.opacity = 0;
        return;
    }

    // Search + page-dots pill: MTMaterialView inside SBFolderScrollAccessoryView.
    // The MTMaterialView IS the blurred background; hide it and apply glass to its
    // ancestor container (SBFolderScrollAccessoryView) so there's only one rendered shape.
    {
        UIView *pillHost = nil;
        UIView *p = sv;
        for (int i = 0; i < 8 && p; i++, p = p.superview) {
            if ([NSStringFromClass([p class]) containsString:@"SBFolderScrollAccessoryView"]) {
                pillHost = p;
                break;
            }
        }
        if (pillHost) {
            // Fully hide the MTMaterialView (its CABackdropLayer renders black when
            // disabled, not transparent). Glass is injected as a sibling at the same frame.
            v.hidden = YES;
            v.alpha = 0;
            v.layer.opacity = 0;
            LGApplyToSearchPill(v);
            return;
        }
    }

    // Replace the full-screen App Library background blur.
    // Must confirm we're inside the App Library container — size alone is too broad
    // and would also match the home screen wallpaper blur.
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    if (v.bounds.size.width > screenW * 0.7 && v.bounds.size.height > 400) {
        NSString *winCls = NSStringFromClass([v.window class]);
        BOOL isLockScreen = [winCls containsString:@"CoverSheet"] ||
                            [winCls containsString:@"LockScreen"];
        if (!isLockScreen) {
            // Walk ancestors to confirm this is inside the App Library
            BOOL inAppLibrary = NO;
            UIView *p = v.superview;
            for (int i = 0; i < 20 && p; i++, p = p.superview) {
                NSString *cn = NSStringFromClass([p class]);
                if ([cn containsString:@"AppLibrary"] ||
                    [cn containsString:@"SBLibraryController"] ||
                    [cn containsString:@"ILAppLibrary"] ||
                    [cn containsString:@"LibraryViewController"]) {
                    inAppLibrary = YES;
                    break;
                }
            }
            if (!inAppLibrary) goto skip_app_library;
            v.hidden = YES; v.alpha = 0; v.layer.opacity = 0;
            // Inject a replacement thin-blur view into the superview (once, via tag guard).
            UIView *sv = v.superview;
            if (sv && ![sv viewWithTag:0x4C4742]) {
                UIBlurEffect *thin = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
                UIVisualEffectView *rep = [[UIVisualEffectView alloc] initWithEffect:thin];
                rep.frame = sv.bounds;
                rep.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                rep.tag = 0x4C4742;
                rep.userInteractionEnabled = NO;
                [sv insertSubview:rep atIndex:0];
            }
            return;
        }
    }
    skip_app_library:;

    // Lock screen quick action detection: MTMaterialView is the circle background (≈50×50 pt),
    // lives on a CoverSheet/LockScreen window.
    NSString *winCls = NSStringFromClass([v.window class]);
    BOOL isLockScreen = [winCls containsString:@"CoverSheet"] || [winCls containsString:@"LockScreen"];
    if (!isLockScreen) return;
    CGSize s = v.bounds.size;
    if (s.width < 30 || s.width > 90) return;          // not a quick-action circle
    if (fabs(s.width - s.height) > 15) return;         // must be roughly square

    // Exclude notification swipe-action buttons (PLPlatterActionButton, etc.)
    UIView *p = sv;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"NCNotification"] ||
            [cn containsString:@"PLPlatter"] ||
            [cn containsString:@"ActionButton"] ||
            [cn containsString:@"SwipeAction"] ||
            [cn containsString:@"NotificationList"]) return;
    }

    // Hide the material circle and glass the parent button container.
    v.hidden = YES;
    v.alpha  = 0;
    v.layer.opacity = 0;
    LGApplyToLockQuickAction(sv);
}
// Also hide eagerly when added to a search-bar ancestor.
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    if (isInsideClass(newSuperview, @"SBHSearchTextField", 4) ||
        isInsideClass(newSuperview, @"SBSearchBarTextField", 4)) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha  = 0;
        ((UIView *)self).layer.opacity = 0;
    }
}
- (void)didMoveToSuperview {
    %orig;
    UIView *sup = ((UIView *)self).superview;
    if (!sup) return;
    if (isInsideClass(sup, @"SBHSearchTextField", 4) ||
        isInsideClass(sup, @"SBSearchBarTextField", 4)) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).alpha  = 0;
        ((UIView *)self).layer.opacity = 0;
    }
}
%end
%end

// Context menu glass — long-pressing any app icon shows a _UIContextMenuListView.
// Each item (and the overall background) has a UIVisualEffectView for its blur.
// We nil the system blur and inject LiquidGlassEffectView(.clear) in its place,
// matching the same glass style as folder icons and the search bar.

// Aggressively hide all separator-like views inside a context menu list.
// No background-colour guard — any thin view or separator-named view is killed.
static void LGNukeContextMenuSeparators(UIView *root) {
    for (UIView *sub in root.subviews) {
        NSString *cn = NSStringFromClass([sub class]);
        // Any class whose name contains "Separator"
        if ([cn containsString:@"Separator"]) {
            sub.hidden = YES; sub.alpha = 0;
            sub.backgroundColor = [UIColor clearColor];
            LGNukeContextMenuSeparators(sub);
            continue;
        }
        // Exact UICollectionReusableView — iOS uses these as spacing/gap cells
        if ([cn isEqualToString:@"UICollectionReusableView"]) {
            sub.hidden = YES; sub.alpha = 0;
            sub.backgroundColor = [UIColor clearColor];
            LGNukeContextMenuSeparators(sub);
            continue;
        }
        // Any thin horizontal (<=2 pt tall) or vertical (<=2 pt wide) line view
        CGSize s = sub.bounds.size;
        BOOL thinH = s.height > 0 && s.height <= 2.0 && s.width >= 20.0;
        BOOL thinV = s.width  > 0 && s.width  <= 2.0 && s.height >= 20.0;
        if (thinH || thinV) {
            sub.hidden = YES; sub.alpha = 0;
            LGNukeContextMenuSeparators(sub);
            continue;
        }
        LGNukeContextMenuSeparators(sub);
    }
}

%group ContextMenu
%hook UIVisualEffectView
- (void)didMoveToWindow {
    %orig;
    // Invalidate cache on window change so the next layoutSubviews re-evaluates.
    objc_setAssociatedObject(self, kLGContextMenuCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *v = (UIView *)self;
    if (!v.window) {
        LGRemoveContextMenuGlass(v);
        return;
    }
    BOOL inContainer = NO, inList = NO;
    UIView *p = v;
    for (int i = 0; i < 12 && p; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"_UIContextMenuContainerView"]) inContainer = YES;
        if ([cn containsString:@"_UIContextMenuListView"])      inList      = YES;
    }
    if (!inContainer) {
        // Cache negative result to skip the walk on subsequent layoutSubviews.
        objc_setAssociatedObject(self, kLGContextMenuCacheKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!inList) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).layer.opacity = 0;
        return;
    }
    LGApplyToContextMenu(v);
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    // Fast path: use cached result when available.
    NSNumber *cached = objc_getAssociatedObject(self, kLGContextMenuCacheKey);
    if (cached != nil && !cached.boolValue) return;  // previously confirmed not in context menu
    BOOL inContainer = NO, inList = NO;
    UIView *p = v;
    for (int i = 0; i < 12 && p; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"_UIContextMenuContainerView"]) inContainer = YES;
        if ([cn containsString:@"_UIContextMenuListView"])      inList      = YES;
    }
    if (!inContainer) {
        // Cache: this view is not inside a context menu, skip future walks.
        objc_setAssociatedObject(self, kLGContextMenuCacheKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!inList) {
        ((UIView *)self).hidden = YES;
        ((UIView *)self).layer.opacity = 0;
        return;
    }
    LGApplyToContextMenu(v);
}
%end

// Hook _UIContextMenuListView directly — runs every layout pass, nukes all separators.
%hook _UIContextMenuListView
- (void)layoutSubviews {
    %orig;
    LGNukeContextMenuSeparators((UIView *)self);
}
%end

// Belt-and-suspenders: hook the named separator class so it always hides itself.
%hook _UIContextMenuReusableSeparatorView
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    v.hidden = YES; v.alpha = 0;
    v.backgroundColor = [UIColor clearColor];
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    v.hidden = YES; v.alpha = 0;
}
%end

// UICollectionReusableView exact class — gap/spacing cells used by the list.
// Use a static key for associated objects so the ancestor walk runs at most once
// per view (cache is invalidated on window change via didMoveToWindow).
static void *kLGReusableViewCacheKey = &kLGReusableViewCacheKey;
%hook UICollectionReusableView
- (void)didMoveToWindow {
    %orig;
    // Invalidate cache on window change so layout re-evaluates context.
    objc_setAssociatedObject(self, kLGReusableViewCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *v = (UIView *)self;
    if (!v.window) return;
    if (![NSStringFromClass([v class]) isEqualToString:@"UICollectionReusableView"]) return;
    UIView *p = v.superview;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) containsString:@"_UIContextMenuListView"]) {
            v.hidden = YES; v.alpha = 0;
            v.backgroundColor = [UIColor clearColor];
            return;
        }
    }
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;
    if (![NSStringFromClass([v class]) isEqualToString:@"UICollectionReusableView"]) return;
    // Fast path: already confirmed not inside a context menu — skip the walk.
    NSNumber *cached = objc_getAssociatedObject(self, kLGReusableViewCacheKey);
    if (cached != nil && !cached.boolValue) return;
    UIView *p = v.superview;
    BOOL found = NO;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) containsString:@"_UIContextMenuListView"]) {
            v.hidden = YES; v.alpha = 0;
            v.backgroundColor = [UIColor clearColor];
            found = YES;
            break;
        }
    }
    if (!found) {
        // Cache negative: not inside a context menu list.
        objc_setAssociatedObject(self, kLGReusableViewCacheKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
%end
%end

// UIVisualEffectView — used as the circular blur background for lock screen quick actions
// on some iOS versions. Hide it and glass the parent when size + window match.
%group QuickActionVisualEffect
%hook UIVisualEffectView
- (void)didMoveToWindow {
    %orig;
    // Invalidate cache on window change.
    objc_setAssociatedObject(self, kLGQuickActionCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)layoutSubviews {
    %orig;
    UIView *v  = (UIView *)self;
    UIView *sv = v.superview;
    if (!sv || !v.window) return;
    // Fast path: already confirmed this is not a quick-action circle — skip.
    NSNumber *cached = objc_getAssociatedObject(self, kLGQuickActionCacheKey);
    if (cached != nil && !cached.boolValue) return;
    NSString *winCls = NSStringFromClass([v.window class]);
    BOOL isLockScreen = [winCls containsString:@"CoverSheet"] || [winCls containsString:@"LockScreen"];
    if (!isLockScreen) {
        // Not on lock screen — will never be a quick action. Cache and skip.
        objc_setAssociatedObject(self, kLGQuickActionCacheKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGSize s = v.bounds.size;
    if (s.width < 30 || s.width > 90) return;
    if (fabs(s.width - s.height) > 15) return;
    // Exclude notification swipe-action buttons — their internal UIVisualEffectView
    // is the same size on the same window, but lives inside NCNotification*,
    // PLPlatterActionButton, UISwipeAction* ancestors.
    UIView *p = sv;
    for (int i = 0; i < 8 && p; i++, p = p.superview) {
        NSString *cn = NSStringFromClass([p class]);
        if ([cn containsString:@"NCNotification"] ||
            [cn containsString:@"PLPlatter"] ||
            [cn containsString:@"ActionButton"] ||
            [cn containsString:@"SwipeAction"] ||
            [cn containsString:@"NotificationList"]) return;
    }
    v.hidden = YES;
    v.alpha  = 0;
    v.layer.opacity = 0;
    LGApplyToLockQuickAction(sv);
    LGStartLiveRefreshLoop(sv, kLGQuickActionLiveRefreshKey);
}
%end
%end

// Lock screen quick action buttons — flashlight + camera circular pills.
// Three possible class names depending on iOS version:
//   SBUICallToActionButton  (iOS 14–15)
//   CSCallToActionButton    (iOS 16–17 CoverSheet)
//   SBFunctionButtonView    (iOS 18+)
%group QuickActionSBUI
%hook SBUICallToActionButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) {
        LGApplyToLockQuickAction(v);
        LGStartLiveRefreshLoop(v, kLGQuickActionLiveRefreshKey);
    }
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) {
        LGApplyToLockQuickAction(v);
        LGStartLiveRefreshLoop(v, kLGQuickActionLiveRefreshKey);
    }
}
%end
%end

%group QuickActionCS
%hook CSCallToActionButton
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) {
        LGApplyToLockQuickAction(v);
        LGStartLiveRefreshLoop(v, kLGQuickActionLiveRefreshKey);
    }
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) {
        LGApplyToLockQuickAction(v);
        LGStartLiveRefreshLoop(v, kLGQuickActionLiveRefreshKey);
    }
}
%end
%end

// Dimming knockout — alert/sheet dimmer and lock-screen quick-action blur (UIKit private).
%group DimmingKnockoutBackdrop
%hook _UIDimmingKnockoutBackdropView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window && v.bounds.size.width > 0) LGApplyToDimmingKnockoutBackdrop(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToDimmingKnockoutBackdrop(v);
}
- (void)didMoveToSuperview {
    %orig;
    UIView *v = (UIView *)self;
    if (v.superview && v.window) LGApplyToDimmingKnockoutBackdrop(v);
}
%end
%end

// RepresentationsSequence → SeparatableSequence → UIStackView (alert button spacing)
%group AlertActionSequence
%hook _UIInterfaceActionRepresentationsSequenceView
- (void)layoutSubviews {
    LGApplyAlertActionSequenceSpacing((UIView *)self);
    %orig;
    LGStyleAlertActionSequenceButtons((UIView *)self);
}
%end

%hook _UIInterfaceActionSeparatableSequenceView
- (void)layoutSubviews {
    LGApplyAlertActionSequenceSpacing((UIView *)self);
    %orig;
    LGStyleAlertActionSequenceButtons((UIView *)self);
}
%end

%hook UIStackView
- (void)setSpacing:(CGFloat)spacing {
    %orig(LGEnforceAlertActionStackSpacing((UIView *)self, spacing));
}
%end
%end

static void lg_initAlertActionSequenceHooks(void) {
    static BOOL initialized = NO;
    if (initialized) return;
    Class cRep = NSClassFromString(@"_UIInterfaceActionRepresentationsSequenceView");
    Class cSep = NSClassFromString(@"_UIInterfaceActionSeparatableSequenceView");
    if (!cRep && !cSep) return;
    initialized = YES;
    %init(AlertActionSequence,
           _UIInterfaceActionRepresentationsSequenceView = cRep,
           _UIInterfaceActionSeparatableSequenceView = cSep,
           UIStackView = [UIStackView class]);
}

// Alert / action-sheet presentation — ensure knockout dimmers are found and replaced.
%group AlertControllerPresentation
static void lg_applyAlertDimmingKnockout(UIView *v) {
    if (!v.window) return;
    LGApplyAlertPresentation(v);
}

%hook _UIAlertControllerActionView
- (void)layoutSubviews {
    %orig;
    LGStyleAlertControllerActionView((UIView *)self);
}
- (void)_updateLabelAttributes {
    %orig;
    LGStyleAlertControllerActionView((UIView *)self);
}
- (void)_recomputeColors {
    %orig;
    LGStyleAlertControllerActionView((UIView *)self);
}
%end

%hook _UIInterfaceActionCustomViewRepresentationView
- (void)layoutSubviews {
    %orig;
    LGStyleAlertActionRepresentationView((UIView *)self);
}
%end

%hook UIInterfaceActionGroupView
- (void)layoutSubviews {
    %orig;
    LGLayoutAlertActionGroup((UIView *)self);
}
%end

%hook _UIInterfaceActionVibrantSeparatorView
- (void)layoutSubviews {
    %orig;
    LGHideAlertVibrantSeparator((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    LGHideAlertVibrantSeparator((UIView *)self);
}
%end

%hook _UIAlertControllerPhoneTVMacView
- (void)layoutSubviews {
    %orig;
    lg_applyAlertDimmingKnockout((UIView *)self);
    LGApplyAlertDialogHeightBoost((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    lg_applyAlertDimmingKnockout((UIView *)self);
}
%end

%hook _UIAlertControllerView
- (void)layoutSubviews {
    %orig;
    lg_applyAlertDimmingKnockout((UIView *)self);
    LGApplyAlertDialogHeightBoost((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    lg_applyAlertDimmingKnockout((UIView *)self);
}
%end

%end

%group QuickActionFunctionButton
%hook SBFunctionButtonView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    // Guard: only on lock screen window, and only small circular buttons (≤ 90 pt)
    NSString *winCls = NSStringFromClass([v.window class]);
    if (![winCls containsString:@"CoverSheet"] && ![winCls containsString:@"LockScreen"]) return;
    CGSize s = v.bounds.size;
    if (s.width > 0 && s.width <= 90 && fabs(s.width - s.height) < 20)
        LGApplyToLockQuickAction(v);
}
- (void)didMoveToWindow {
    %orig;
    UIView *v = (UIView *)self;
    NSString *winCls = NSStringFromClass([v.window class]);
    if (![winCls containsString:@"CoverSheet"] && ![winCls containsString:@"LockScreen"]) return;
    CGSize s = v.bounds.size;
    if (s.width > 0 && s.width <= 90 && fabs(s.width - s.height) < 20)
        LGApplyToLockQuickAction(v);
}
%end
%end
%group SearchBarBackground
%hook _UITextFieldRoundedRectBackgroundViewNeue
- (void)willMoveToSuperview:(UIView *)newSuperview {
    %orig;
    if (!newSuperview) return;
    // Walk up to check if we're inside SBHSearchTextField
    UIView *p = newSuperview;
    for (int i = 0; i < 5 && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:@"SBHSearchTextField"]) {
            ((UIView *)self).hidden = YES;
            ((UIView *)self).alpha = 0;
            ((UIView *)self).layer.opacity = 0;
            return;
        }
    }
}
- (void)didMoveToSuperview {
    %orig;
    UIView *p = ((UIView *)self).superview;
    for (int i = 0; i < 5 && p; i++, p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:@"SBHSearchTextField"]) {
            ((UIView *)self).hidden = YES;
            ((UIView *)self).alpha = 0;
            ((UIView *)self).layer.opacity = 0;
            return;
        }
    }
}
%end
%end

// Control Center module glass integration.
// Hook both the module background and module instance views for safe glass rendering.
%group ControlCenter
%hook CCUIModuleBackgroundView
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (newWindow) {
        // CC opening: suspend for the entire CC session (up to 60 s).
        // Dock/homescreen glass must NOT sample CC content as their background.
        // When CC closes, willMoveToWindow:nil calls LGSuspendCaptures(0.45) which
        // overwrites this with a short window — ending the long suspension at close time.
        // New CC-module glass views are exempt (backgroundTexture == nil → first-capture
        // logic fires immediately regardless of suspension).
        LGSuspendCaptures(60.0);
    } else {
        // CC closing/dismissing: freeze for 0.45 s (dismiss animation duration) so glass
        // views don't sample the CC-sliding-off-screen state as their background.
        // captureSchedulerFired() auto-bursts after the window expires.
        LGSuspendCaptures(0.45);
    }
}
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToControlCenterModule(v);
}
%end

%hook CCUIModuleInstanceView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (v.window) LGApplyToControlCenterModule(v);
}
%end

%hook CCUIContentModuleContentContainerView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.window) return;

    BOOL opened = cc26ModuleExpanded(v);
    CGFloat radius = opened ? 65.0 : cc26GetModuleRadius(v);
    v.layer.cornerRadius = radius;
    v.layer.masksToBounds = YES;
    if ([v.layer respondsToSelector:@selector(setCornerCurve:)]) {
        v.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (v.window) LGApplyToControlCenterModule(v);
}
%end
%end

// ── Widget host VC suppression ───────────────────────────────────────────────
// CHUISWidgetHostViewController and CHUISAvocadoHostViewController call
// _updateBackgroundMaterialAndColor whenever the widget is laid out, which
// re-adds the MTMaterial blur and undoes our glass injection.  Block them.
%group WidgetSuppress
@interface CHUISWidgetHostViewController : UIViewController
@end
%hook CHUISWidgetHostViewController
- (void)_updateBackgroundMaterialAndColor       { }
- (void)_updatePersistedSnapshotContent         { }
- (void)_updatePersistedSnapshotContentIfNecessary { }
- (id)_snapshotImageFromURL:(id)url             { return nil; }
%end

@interface CHUISAvocadoHostViewController : UIViewController
@end
%hook CHUISAvocadoHostViewController
- (void)_updateBackgroundMaterialAndColor { }
- (id)screenshotManager                   { return nil; }
%end
%end

// ── iOS 26-style page back button (replaces iOS 16 _UIButtonBarButton chrome) ─
static const NSUInteger kLGPageBackCircleTag  = 0x4C4750;
static const NSUInteger kLGPageBackChevronTag = 0x4C4751;
static const NSUInteger kLGNavActionPillTag   = 0x4C4753;
static void *kLGPageBackStyledKey = &kLGPageBackStyledKey;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("com.strayfade.liquidglass/prefschanged");

static BOOL lgPref(NSString *key);
static BOOL lgMasterEnabled(void);
static void LGEnsureNavBarChromeAboveBlur(UINavigationBar *bar, UIView *pageBackButton);

/// UI tweaks only run in SpringBoard or the Settings app (matches LiquidGlass.plist filter).
static BOOL LGIsLiquidGlassHostProcess(void) {
    static dispatch_once_t once;
    static BOOL isHost;
    dispatch_once(&once, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        isHost = [bundleID isEqualToString:@"com.apple.springboard"]
              || [bundleID isEqualToString:@"com.apple.Preferences"];
    });
    return isHost;
}

static BOOL LGPageBackNavFeatureEnabled(void) {
    return LGIsLiquidGlassHostProcess()
        && lgMasterEnabled()
        && lgPref(@"pageBackButtonEnabled");
}

static BOOL LGIsSettingsHostApplication(void) {
    static dispatch_once_t once;
    static BOOL isSettings;
    dispatch_once(&once, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        isSettings = [bundleID isEqualToString:@"com.apple.Preferences"];
    });
    return isSettings;
}

static BOOL LGSettingsBackButtonFeatureEnabled(void) {
    return LGIsSettingsHostApplication()
        && lgMasterEnabled()
        && lgPref(@"pageBackButtonEnabled");
}

static BOOL LGSettings26FeatureEnabled(void) {
    return lgMasterEnabled() && lgPref(@"settings26Enabled");
}

static BOOL LGSettings26SectionLabelsFeatureEnabled(void) {
    return lgMasterEnabled() && lgPref(@"sectionLabelsEnabled");
}

static BOOL LGPageLabelsFeatureEnabled(void) {
    return LGIsSettingsHostApplication()
        && lgMasterEnabled()
        && lgPref(@"pageLabelsEnabled");
}

static UIViewController *lgSettingsViewControllerForResponder(UIResponder *responder) {
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]])
            return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static UIViewController *lgSettingsViewControllerForView(UIView *view) {
    if (!view) return nil;
    UIViewController *vc = lgSettingsViewControllerForResponder(view);
    if (vc) return vc;
    for (UIView *current = view; current; current = current.superview) {
        if (![current isKindOfClass:[UINavigationBar class]]) continue;
        UIResponder *responder = current;
        while (responder) {
            if ([responder isKindOfClass:[UINavigationController class]]) {
                UINavigationController *nav = (UINavigationController *)responder;
                return nav.visibleViewController ?: nav.topViewController;
            }
            responder = responder.nextResponder;
        }
        break;
    }
    return nil;
}

static BOOL lgSettingsIsWiFiSettingsController(id controller) {
    if (!controller) return NO;
    NSString *className = NSStringFromClass(object_getClass(controller));
    return [className isEqualToString:@"WFAirportViewController"]
        || [className isEqualToString:@"APNetworksController"];
}

static BOOL lgSettingsShouldModifyController(id controller) {
    return controller != nil && !lgSettingsIsWiFiSettingsController(controller);
}

static BOOL lgSettingsShouldModifyView(UIView *view) {
    if (!view) return YES;
    UIViewController *vc = lgSettingsViewControllerForView(view);
    for (; vc; vc = vc.parentViewController) {
        if (lgSettingsIsWiFiSettingsController(vc)) return NO;
    }
    return YES;
}

static void LGRestoreNavBarContentViewClips(UIView *content) {
    if (!content) return;
    [content setClipsToBounds:YES];
}

static void LGApplyNavBarContentViewClips(UIView *content) {
    if (!content) return;
    if (!LGPageBackNavFeatureEnabled()) {
        LGRestoreNavBarContentViewClips(content);
        return;
    }
    [content setClipsToBounds:NO];
}

static const NSUInteger kLGNavBarBlurContainerTag    = 0x4C4760;
static const NSUInteger kLGNavBarFeatherBlurTag    = 0x4C4770;
static const NSUInteger kLGNavBarTintGradientTag     = 0x4C4771;
static const CGFloat    kLGNavBarEffectHeightScale   = (1.5 / 3.0);
static const CGFloat    kLGNavBarEffectMinHeight     = 56.0;
static const CGFloat    kLGNavBarEffectExtraHeight   = 50.0;
static const int kLGNavBarFeatherBlurRecipeDefault = 2;
static void *kLGNavBarBlurReplacementKey = &kLGNavBarBlurReplacementKey;
static void *kLGNavBarFeatherBlurViewKey   = &kLGNavBarFeatherBlurViewKey;
static void *kLGNavBarTintGradientLayerKey = &kLGNavBarTintGradientLayerKey;

static Class sLGFeatherBlurClass = Nil;
static BOOL sLGTriedLoadFeatherFramework = NO;

@interface SBFFeatherBlurView : UIView
- (instancetype)initWithRecipe:(int)recipe;
@end
@interface SBHFeatherBlurView : UIView
- (instancetype)initWithRecipe:(int)recipe;
@end

static BOOL LGIsBarBackgroundInNavigationBar(UIView *bg) {
    if (!bg || ![NSStringFromClass([bg class]) isEqualToString:@"_UIBarBackground"])
        return NO;
    UIView *bar = bg.superview;
    return bar && [bar isKindOfClass:[UINavigationBar class]];
}

static void LGEnsureFeatherBlurFrameworkLoaded(void) {
    if (sLGTriedLoadFeatherFramework) return;
    sLGTriedLoadFeatherFramework = YES;

    static const char *frameworkPaths[] = {
        "/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation",
        "/System/Library/PrivateFrameworks/SpringBoardHome.framework/SpringBoardHome",
        NULL
    };
    for (int i = 0; frameworkPaths[i]; i++)
        dlopen(frameworkPaths[i], RTLD_NOW | RTLD_GLOBAL);

    sLGFeatherBlurClass = NSClassFromString(@"SBFFeatherBlurView");
    if (!sLGFeatherBlurClass) sLGFeatherBlurClass = NSClassFromString(@"SBHFeatherBlurView");
}

static BOOL LGIsFeatherBlurViewClass(Class cls) {
    if (!cls) return NO;
    return cls == sLGFeatherBlurClass
        || [NSStringFromClass(cls) isEqualToString:@"SBFFeatherBlurView"]
        || [NSStringFromClass(cls) isEqualToString:@"SBHFeatherBlurView"];
}

static UIView *LGFindFeatherBlurViewInTree(UIView *root) {
    if (!root) return nil;
    if (LGIsFeatherBlurViewClass([root class])) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = LGFindFeatherBlurViewInTree(sub);
        if (found) return found;
    }
    return nil;
}

static int LGFeatherBlurRecipeFromView(UIView *feather) {
    if (!feather) return kLGNavBarFeatherBlurRecipeDefault;
    NSArray<NSString *> *keys = @[@"recipe", @"_recipe", @"blurRecipe", @"_blurRecipe"];
    for (NSString *key in keys) {
        @try {
            id val = [feather valueForKey:key];
            if ([val isKindOfClass:[NSNumber class]]) return [val intValue];
        } @catch (__unused NSException *e) {
        }
    }
    return kLGNavBarFeatherBlurRecipeDefault;
}

static void LGHideNonFeatherBarBackgroundChrome(UIView *barBackground, UIView *feather) {
    for (UIView *sub in barBackground.subviews) {
        if (sub == feather) continue;
        sub.hidden = YES;
        sub.alpha = 0;
        sub.layer.opacity = 0;
    }
}

static void LGRestoreBarBackgroundChrome(UIView *barBackground) {
    if (!barBackground) return;
    barBackground.alpha = 1;
    barBackground.opaque = YES;
    barBackground.layer.opacity = 1;
    barBackground.userInteractionEnabled = YES;
    for (UIView *sub in barBackground.subviews) {
        sub.hidden = NO;
        sub.alpha = 1;
        sub.layer.opacity = 1;
    }
}

static UIView *LGCreateFeatherBlurView(int recipe) {
    LGEnsureFeatherBlurFrameworkLoaded();
    if (!sLGFeatherBlurClass) return nil;

    if ([sLGFeatherBlurClass instancesRespondToSelector:@selector(initWithRecipe:)]) {
        return [(SBFFeatherBlurView *)[sLGFeatherBlurClass alloc] initWithRecipe:recipe];
    }
    return [[sLGFeatherBlurClass alloc] init];
}

static BOOL LGNavBarIsDark(UINavigationBar *bar) {
    UITraitCollection *traits = bar.traitCollection ?: UIScreen.mainScreen.traitCollection;
    UITraitCollection *screen = UIScreen.mainScreen.traitCollection;
    if (@available(iOS 12.0, *)) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            || screen.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static CGRect LGNavBarCompressedEffectFrame(UIView *barBackground) {
    CGRect full = barBackground.frame;
    if (CGRectIsEmpty(full)) full = barBackground.bounds;
    CGFloat effectH = MAX(kLGNavBarEffectMinHeight, full.size.height * kLGNavBarEffectHeightScale)
                    + kLGNavBarEffectExtraHeight;
    return CGRectMake(CGRectGetMinX(full), CGRectGetMinY(full), CGRectGetWidth(full), effectH);
}

static void LGSyncNavBarTintGradient(UIView *replacement, UINavigationBar *bar) {
    if (!replacement || CGRectIsEmpty(replacement.bounds)) return;

    UIView *tintView = [replacement viewWithTag:kLGNavBarTintGradientTag];
    if (!tintView) {
        tintView = [[UIView alloc] initWithFrame:replacement.bounds];
        tintView.tag = kLGNavBarTintGradientTag;
        tintView.userInteractionEnabled = NO;
        tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tintView.backgroundColor = [UIColor clearColor];
        CAGradientLayer *gradient = [CAGradientLayer layer];
        objc_setAssociatedObject(tintView, kLGNavBarTintGradientLayerKey, gradient,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tintView.layer addSublayer:gradient];
        [replacement addSubview:tintView];
    }

    tintView.frame = replacement.bounds;
    CAGradientLayer *gradient = objc_getAssociatedObject(tintView, kLGNavBarTintGradientLayerKey);
    if (!gradient) return;

    BOOL isDark = LGNavBarIsDark(bar);
    UIColor *solid = isDark ? [UIColor blackColor] : [UIColor whiteColor];
    gradient.frame = tintView.bounds;
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint   = CGPointMake(0.5, 1.0);
    gradient.colors = @[
        (id)solid.CGColor,
        (id)[solid colorWithAlphaComponent:0.0].CGColor,
    ];
    gradient.locations = @[@0.0, @1.0];
    [replacement bringSubviewToFront:tintView];
}

static void LGSyncFeatherBlurFrame(UIView *feather, UIView *replacement) {
    if (!feather || !replacement) return;
    feather.frame = replacement.bounds;
    feather.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    feather.hidden = NO;
    feather.alpha = 1;
    feather.layer.opacity = 1;
    feather.userInteractionEnabled = NO;
    [replacement sendSubviewToBack:feather];
}

static void LGInstallFeatherBlurInReplacement(UIView *barBackground, UIView *replacement) {
    CGRect bounds = replacement.bounds;
    if (CGRectIsEmpty(bounds) || bounds.size.height < 2) return;

    UIView *feather = objc_getAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey);
    if (feather && feather.superview != replacement) {
        [feather removeFromSuperview];
        objc_setAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey, nil, OBJC_ASSOCIATION_ASSIGN);
        feather = nil;
    }

    if (!feather) {
        feather = LGFindFeatherBlurViewInTree(barBackground);
        if (feather) {
            int recipe = LGFeatherBlurRecipeFromView(feather);
            [feather removeFromSuperview];
            objc_setAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey, feather,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            (void)recipe;
        }
    }

    if (!feather) {
        feather = (UIView *)[replacement viewWithTag:kLGNavBarFeatherBlurTag];
    }

    if (!feather) {
        int recipe = LGFeatherBlurRecipeFromView(LGFindFeatherBlurViewInTree(barBackground));
        feather = LGCreateFeatherBlurView(recipe);
        if (!feather) return;
        feather.tag = kLGNavBarFeatherBlurTag;
        [replacement addSubview:feather];
        objc_setAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey, feather,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (feather.superview != replacement) {
        feather.tag = kLGNavBarFeatherBlurTag;
        [replacement addSubview:feather];
    }

    LGSyncFeatherBlurFrame(feather, replacement);
    LGHideNonFeatherBarBackgroundChrome(barBackground, feather);
}

static void LGRebuildNavBarGradientBlur(UIView *replacement, UIView *barBackground, UINavigationBar *bar) {
    LGInstallFeatherBlurInReplacement(barBackground, replacement);
    LGSyncNavBarTintGradient(replacement, bar);
}

static void LGPrepareNavigationBarForGradientBlur(UINavigationBar *bar) {
    if (!bar) return;
    bar.translucent = YES;
    bar.backgroundColor = [UIColor clearColor];
    [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsCompact];
    if (@available(iOS 13.0, *)) {
        [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsCompactPrompt];
        [bar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefaultPrompt];
        UINavigationBarAppearance *appearance = [bar.standardAppearance copy];
        if (!appearance) appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithTransparentBackground];
        appearance.backgroundEffect = nil;
        appearance.backgroundColor = [UIColor clearColor];
        appearance.shadowColor = [UIColor clearColor];
        bar.standardAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        bar.compactAppearance = appearance;
        if (@available(iOS 15.0, *))
            bar.compactScrollEdgeAppearance = appearance;
    }
    bar.shadowImage = [UIImage new];
}

static UINavigationBarAppearance *LGDefaultNavigationBarAppearance(void) {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];
    return appearance;
}

static void LGRestoreNavigationBarFromGradientBlur(UINavigationBar *bar) {
    if (!bar) return;
    bar.backgroundColor = nil;
    bar.shadowImage = nil;
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsCompact];
    if (@available(iOS 13.0, *)) {
        [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsCompactPrompt];
        [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefaultPrompt];
        UINavigationBarAppearance *appearance = LGDefaultNavigationBarAppearance();
        bar.standardAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        bar.compactAppearance = appearance;
        if (@available(iOS 15.0, *))
            bar.compactScrollEdgeAppearance = appearance;
    }
}

static void LGRestoreNavBarChromeZOrder(UINavigationBar *bar) {
    if (!bar) return;
    for (UIView *sub in bar.subviews)
        sub.layer.zPosition = 0;
}

static void LGTeardownNavBarBackgroundReplacement(UIView *barBackground) {
    UINavigationBar *bar = nil;
    if ([barBackground.superview isKindOfClass:[UINavigationBar class]])
        bar = (UINavigationBar *)barBackground.superview;

    UIView *feather = objc_getAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey);
    if (feather && feather.superview != barBackground) {
        [feather removeFromSuperview];
        [barBackground insertSubview:feather atIndex:0];
        feather.frame = barBackground.bounds;
        feather.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        feather.hidden = NO;
        feather.alpha = 1;
        feather.layer.opacity = 1;
    }
    objc_setAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey, nil, OBJC_ASSOCIATION_ASSIGN);

    UIView *replacement = objc_getAssociatedObject(barBackground, kLGNavBarBlurReplacementKey);
    if (replacement) {
        [replacement removeFromSuperview];
        objc_setAssociatedObject(barBackground, kLGNavBarBlurReplacementKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    if (bar) {
        for (UIView *sub in [bar.subviews copy]) {
            if (sub.tag == kLGNavBarBlurContainerTag)
                [sub removeFromSuperview];
        }
        LGRestoreNavigationBarFromGradientBlur(bar);
        LGRestoreNavBarChromeZOrder(bar);
    }

    LGRestoreBarBackgroundChrome(barBackground);
}

static void LGSyncNavBarBlurReplacement(UIView *barBackground, UINavigationBar *bar) {
    UIView *replacement = objc_getAssociatedObject(barBackground, kLGNavBarBlurReplacementKey);
    if (!replacement) return;

    LGPrepareNavigationBarForGradientBlur(bar);

    replacement.frame = LGNavBarCompressedEffectFrame(barBackground);
    replacement.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    replacement.hidden = barBackground.hidden;
    replacement.backgroundColor = [UIColor clearColor];
    replacement.opaque = NO;
    replacement.clipsToBounds = YES;

    LGRebuildNavBarGradientBlur(replacement, barBackground, bar);
    LGEnsureNavBarChromeAboveBlur(bar, nil);
}

static void LGInstallNavBarBackgroundReplacement(UIView *barBackground, UINavigationBar *bar) {
    UIView *replacement = objc_getAssociatedObject(barBackground, kLGNavBarBlurReplacementKey);
    if (!replacement) {
        replacement = [[UIView alloc] initWithFrame:barBackground.frame];
        replacement.tag = kLGNavBarBlurContainerTag;
        replacement.userInteractionEnabled = NO;
        replacement.autoresizingMask = barBackground.autoresizingMask;
        replacement.clipsToBounds = NO;
        replacement.backgroundColor = [UIColor clearColor];
        replacement.opaque = NO;
        if (@available(iOS 13.0, *))
            replacement.layer.cornerCurve = barBackground.layer.cornerCurve;

        [bar insertSubview:replacement belowSubview:barBackground];
        objc_setAssociatedObject(barBackground, kLGNavBarBlurReplacementKey, replacement,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGSyncNavBarBlurReplacement(barBackground, bar);
}

static void LGApplyNavBarBackgroundReplacement(UIView *barBackground) {
    if (!LGIsBarBackgroundInNavigationBar(barBackground)) return;

    if (!LGPageBackNavFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement(barBackground);
        return;
    }
    if (!barBackground.window) return;

    UINavigationBar *bar = (UINavigationBar *)barBackground.superview;
    LGInstallNavBarBackgroundReplacement(barBackground, bar);

    UIView *feather = objc_getAssociatedObject(barBackground, kLGNavBarFeatherBlurViewKey);
    if (feather && feather.superview != barBackground) {
        barBackground.alpha = 0;
        barBackground.opaque = NO;
        barBackground.layer.opacity = 0;
        barBackground.userInteractionEnabled = NO;
    } else {
        LGHideNonFeatherBarBackgroundChrome(barBackground, feather);
    }
}

static UINavigationBar *LGNavigationBarForView(UIView *view) {
    for (UIView *p = view; p; p = p.superview) {
        if ([p isKindOfClass:[UINavigationBar class]]) return (UINavigationBar *)p;
    }
    return nil;
}

static UIView *LGNavBarBlurReplacementInBar(UINavigationBar *bar) {
    if (!bar) return nil;
    for (UIView *sub in bar.subviews) {
        if (sub.tag == kLGNavBarBlurContainerTag) return sub;
    }
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"]) {
            UIView *replacement = objc_getAssociatedObject(sub, kLGNavBarBlurReplacementKey);
            if (replacement) return replacement;
        }
    }
    return nil;
}

static void LGEnsureNavBarChromeAboveBlur(UINavigationBar *bar, UIView *pageBackButton) {
    if (!bar) return;
    if (!LGPageBackNavFeatureEnabled()) {
        LGRestoreNavBarChromeZOrder(bar);
        return;
    }

    UIView *blur = LGNavBarBlurReplacementInBar(bar);
    if (blur) {
        blur.layer.zPosition = -500.0;
        if (blur.superview == bar) [bar sendSubviewToBack:blur];
    }

    for (UIView *sub in bar.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls isEqualToString:@"_UINavigationBarContentView"] ||
            [cls isEqualToString:@"_UINavigationBarTitleControl"]) {
            sub.layer.zPosition = 100.0;
            [bar bringSubviewToFront:sub];
        }
    }

    if (pageBackButton) {
        pageBackButton.layer.zPosition = 200.0;
        if (pageBackButton.superview)
            [pageBackButton.superview bringSubviewToFront:pageBackButton];
        UIView *p = pageBackButton;
        for (int i = 0; i < 4 && p; i++, p = p.superview) {
            p.clipsToBounds = NO;
            p.layer.masksToBounds = NO;
            if ([p isKindOfClass:[UINavigationBar class]]) break;
        }
    }
}

static void LGClearNavButtonBackgroundShadow(UIView *background) {
    if (!background) return;
    background.layer.shadowOpacity = 0;
    background.layer.shadowPath = nil;
    background.layer.shadowOffset = CGSizeZero;
    background.layer.shadowRadius = 0;
}

static void LGApplyPageBackCircleShadow(UIView *circle, BOOL isDark) {
    if (!circle) return;
    circle.layer.masksToBounds = NO;
    circle.layer.shadowColor = [UIColor blackColor].CGColor;
    circle.layer.shadowOpacity = isDark ? 0.28f : 0.12f;
    circle.layer.shadowRadius = 3.5f;
    circle.layer.shadowOffset = CGSizeMake(0.0f, 1.5f);
    if (@available(iOS 13.0, *))
        circle.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:circle.bounds
                                                             cornerRadius:circle.layer.cornerRadius].CGPath;
}

static void LGClearPageBackCircleShadow(UIView *btn) {
    UIView *circle = [btn viewWithTag:kLGPageBackCircleTag];
    if (circle) LGClearNavButtonBackgroundShadow(circle);
    UIView *pill = [btn viewWithTag:kLGNavActionPillTag];
    if (pill) LGClearNavButtonBackgroundShadow(pill);
}

static UIView *LGFindNavigationBarContentView(UIView *view) {
    for (UIView *p = view.superview; p; p = p.superview) {
        if ([NSStringFromClass([p class]) isEqualToString:@"_UINavigationBarContentView"])
            return p;
    }
    return nil;
}

static BOOL LGHasBackButtonMaskView(UIView *root) {
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBackButtonMaskView"])
            return YES;
        if (LGHasBackButtonMaskView(sub))
            return YES;
    }
    return NO;
}

static BOOL LGLooksLikePageBackBarButton(UIView *btn) {
    if (!btn || ![NSStringFromClass([btn class]) isEqualToString:@"_UIButtonBarButton"]) return NO;
    if (!LGFindNavigationBarContentView(btn)) return NO;
    return LGHasBackButtonMaskView(btn);
}

static BOOL LGIsPageBackBarButton(UIView *btn) {
    if (!btn || !btn.window) return NO;
    return LGLooksLikePageBackBarButton(btn);
}

static BOOL LGShouldTeardownPageBackButton(UIView *btn) {
    return btn && (LGLooksLikePageBackBarButton(btn) || objc_getAssociatedObject(btn, kLGPageBackStyledKey));
}

static BOOL LGPageBackIsDark(UIView *btn) {
    UITraitCollection *traits = btn.traitCollection ?: UIScreen.mainScreen.traitCollection;
    UITraitCollection *screen = UIScreen.mainScreen.traitCollection;
    if (@available(iOS 12.0, *)) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            || screen.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static UIColor *LGSettingsNavButtonFillColor(BOOL isDark) {
    if (isDark) return [UIColor colorWithWhite:0.15 alpha:1.0];
    return [UIColor whiteColor];
}

static UIColor *LGSettingsNavActionTextColor(BOOL isDark) {
    return isDark ? [UIColor whiteColor] : [UIColor blackColor];
}

static void LGHidePageBackNativeChrome(UIView *btn) {
    for (UIView *sub in btn.subviews) {
        if (sub.tag == kLGPageBackCircleTag || sub.tag == kLGPageBackChevronTag) continue;
        sub.hidden = YES;
        sub.alpha = 0;
    }
    btn.backgroundColor = [UIColor clearColor];
    btn.layer.backgroundColor = [UIColor clearColor].CGColor;
    if ([btn respondsToSelector:@selector(imageView)]) {
        UIImageView *iv = [btn performSelector:@selector(imageView)];
        if ([iv isKindOfClass:[UIImageView class]]) {
            iv.hidden = YES;
            iv.alpha = 0;
        }
    }
}

static void LGRestorePageBackNativeChrome(UIView *btn) {
    if (!btn) return;
    for (UIView *sub in btn.subviews) {
        if (sub.tag == kLGPageBackCircleTag || sub.tag == kLGPageBackChevronTag) continue;
        sub.hidden = NO;
        sub.alpha = 1;
        sub.layer.opacity = 1;
    }
    btn.backgroundColor = nil;
    btn.layer.backgroundColor = nil;
    btn.clipsToBounds = YES;
    btn.layer.masksToBounds = YES;
    if ([btn respondsToSelector:@selector(imageView)]) {
        UIImageView *iv = [btn performSelector:@selector(imageView)];
        if ([iv isKindOfClass:[UIImageView class]]) {
            iv.hidden = NO;
            iv.alpha = 1;
        }
    }
    btn.clipsToBounds = NO;
    btn.layer.masksToBounds = NO;
    [btn setNeedsLayout];
    [btn layoutIfNeeded];
}

static const CGFloat kLGNavButtonBackgroundFillAlpha = 0.95;

static void LGApplySettingsNavButtonChromeToBackground(UIView *background, BOOL isDark, CGFloat cornerRadius) {
    if (!background || cornerRadius <= 0.0) return;
    background.backgroundColor = [LGSettingsNavButtonFillColor(isDark) colorWithAlphaComponent:kLGNavButtonBackgroundFillAlpha];
    background.layer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *))
        background.layer.cornerCurve = kCACornerCurveContinuous;
    LGApplyGlassToSettingsNavButtonBackground(background);
    LGApplyPageBackCircleShadow(background, isDark);
}

static void LGRemoveSettingsNavButtonChromeFromBackground(UIView *background) {
    if (!background) return;
    LGClearNavButtonBackgroundShadow(background);
    LGRemoveGlassFromSettingsNavButtonBackground(background);
}

static void LGTeardownPageBackButtonStyle(UIView *btn) {
    if (!btn) return;
    UIView *circle = [btn viewWithTag:kLGPageBackCircleTag];
    if (circle) LGRemoveSettingsNavButtonChromeFromBackground(circle);
    for (UIView *sub in [btn.subviews copy]) {
        if (sub.tag == kLGPageBackCircleTag || sub.tag == kLGPageBackChevronTag)
            [sub removeFromSuperview];
    }
    LGClearPageBackCircleShadow(btn);
    btn.layer.zPosition = 0;
    LGRestorePageBackNativeChrome(btn);
    objc_setAssociatedObject(btn, kLGPageBackStyledKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static UIImage *LGPageBackChevronSymbolImage(void) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightLight];
        UIImage *symbol = [UIImage systemImageNamed:@"chevron.backward" withConfiguration:cfg];
        if (!symbol) symbol = [UIImage systemImageNamed:@"chevron.left" withConfiguration:cfg];
        if (symbol) return symbol;
    }
    return [UIImage systemImageNamed:@"chevron.backward"];
}

static BOOL LGNavActionLabelHasText(UILabel *label) {
    if (!label) return NO;
    if (label.text.length > 0) return YES;
    if (label.attributedText.length > 0) return YES;
    return NO;
}

static BOOL LGIsSettingsNavActionLabel(UILabel *label) {
    if (!label) return NO;
    if (!LGSettingsBackButtonFeatureEnabled()) return NO;
    for (UIView *v = label.superview; v; v = v.superview) {
        if ([NSStringFromClass([v class]) isEqualToString:@"_UIButtonBarButton"]) {
            if (LGLooksLikePageBackBarButton(v)) return NO;
            return LGFindNavigationBarContentView(v) != nil;
        }
    }
    return NO;
}

static void LGStyleSettingsNavActionLabel(UILabel *label) {
    if (!label || !LGIsSettingsNavActionLabel(label)) return;

    UIColor *textColor = LGSettingsNavActionTextColor(LGPageBackIsDark(label));

    if (label.attributedText.length) {
        NSMutableAttributedString *styled = [label.attributedText mutableCopy];
        [styled addAttribute:NSForegroundColorAttributeName value:textColor
                       range:NSMakeRange(0, styled.length)];
        if (![label.attributedText isEqualToAttributedString:styled])
            label.attributedText = [styled copy];
        return;
    }

    label.textColor = textColor;
}

static void LGApplyStyledNavActionLabelsInView(UIView *root) {
    if (!root) return;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UILabel class]])
            LGStyleSettingsNavActionLabel((UILabel *)sub);
        LGApplyStyledNavActionLabelsInView(sub);
    }
}

static CGRect LGPageBackChevronFrameForImageSize(CGSize imgSize, CGFloat circleSize) {
    if (imgSize.width < 1) imgSize = CGSizeMake(10, 14);
    CGFloat chevW = MIN(imgSize.width + 4, circleSize - 8);
    CGFloat chevH = MIN(imgSize.height + 6, circleSize - 8);
    return CGRectMake(
        floor((circleSize - chevW) * 0.5) - 1.0,
        floor((circleSize - chevH) * 0.5),
        chevW, chevH);
}

static void LGApplyPageBackButtonStyle(UIView *btn) {
    if (!LGPageBackNavFeatureEnabled()) {
        if (LGShouldTeardownPageBackButton(btn))
            LGTeardownPageBackButtonStyle(btn);
        return;
    }
    if (!lgSettingsShouldModifyView(btn)) {
        if (LGShouldTeardownPageBackButton(btn))
            LGTeardownPageBackButtonStyle(btn);
        return;
    }
    if (!LGIsPageBackBarButton(btn)) return;

    LGHidePageBackNativeChrome(btn);

    BOOL isDark = LGPageBackIsDark(btn);
    UIColor *chevronColor = isDark ? [UIColor whiteColor] : [UIColor blackColor];

    static const CGFloat kCircleSize = 40.0;
    CGRect circleFrame = CGRectMake(
        floor((CGRectGetWidth(btn.bounds) - kCircleSize) * 0.5),
        floor((CGRectGetHeight(btn.bounds) - kCircleSize) * 0.5),
        kCircleSize, kCircleSize);

    UIView *circle = [btn viewWithTag:kLGPageBackCircleTag];
    if (!circle) {
        circle = [[UIView alloc] initWithFrame:circleFrame];
        circle.tag = kLGPageBackCircleTag;
        circle.userInteractionEnabled = NO;
        circle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                 UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin |
                                 UIViewAutoresizingFlexibleBottomMargin;
        if (@available(iOS 13.0, *)) circle.layer.cornerCurve = kCACornerCurveContinuous;
        [btn addSubview:circle];
        objc_setAssociatedObject(btn, kLGPageBackStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    circle.frame = circleFrame;
    LGApplySettingsNavButtonChromeToBackground(circle, isDark, kCircleSize * 0.5);

    btn.clipsToBounds = NO;
    btn.layer.masksToBounds = NO;

    UIImageView *chevron = (UIImageView *)[circle viewWithTag:kLGPageBackChevronTag];
    if (!chevron) {
        chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
        chevron.tag = kLGPageBackChevronTag;
        chevron.userInteractionEnabled = NO;
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [circle addSubview:chevron];
    }

    UIImage *symbol = LGPageBackChevronSymbolImage();
    chevron.image = [symbol imageWithTintColor:chevronColor renderingMode:UIImageRenderingModeAlwaysTemplate];
    chevron.tintColor = chevronColor;

    chevron.frame = LGPageBackChevronFrameForImageSize(chevron.image.size, kCircleSize);

    [circle bringSubviewToFront:chevron];
    [btn bringSubviewToFront:circle];

    UINavigationBar *bar = LGNavigationBarForView(btn);
    LGEnsureNavBarChromeAboveBlur(bar, btn);
}

static void LGApplySettingsBackButtonStyleVisualOnly(UIView *btn) {
    if (!LGSettingsBackButtonFeatureEnabled()) {
        if (LGShouldTeardownPageBackButton(btn))
            LGTeardownPageBackButtonStyle(btn);
        return;
    }
    if (!lgSettingsShouldModifyView(btn)) {
        if (LGShouldTeardownPageBackButton(btn))
            LGTeardownPageBackButtonStyle(btn);
        return;
    }
    if (!LGIsPageBackBarButton(btn)) return;

    LGHidePageBackNativeChrome(btn);

    BOOL isDark = LGPageBackIsDark(btn);
    UIColor *chevronColor = isDark ? [UIColor whiteColor] : [UIColor blackColor];

    static const CGFloat kCircleSize = 40.0;
    CGRect circleFrame = CGRectMake(
        floor((CGRectGetWidth(btn.bounds) - kCircleSize) * 0.5),
        floor((CGRectGetHeight(btn.bounds) - kCircleSize) * 0.5),
        kCircleSize, kCircleSize);

    UIView *circle = [btn viewWithTag:kLGPageBackCircleTag];
    if (!circle) {
        circle = [[UIView alloc] initWithFrame:circleFrame];
        circle.tag = kLGPageBackCircleTag;
        circle.userInteractionEnabled = NO;
        circle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                 UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin |
                                 UIViewAutoresizingFlexibleBottomMargin;
        if (@available(iOS 13.0, *)) circle.layer.cornerCurve = kCACornerCurveContinuous;
        [btn addSubview:circle];
        objc_setAssociatedObject(btn, kLGPageBackStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    circle.frame = circleFrame;
    LGApplySettingsNavButtonChromeToBackground(circle, isDark, kCircleSize * 0.5);

    btn.clipsToBounds = NO;
    btn.layer.masksToBounds = NO;

    UIImageView *chevron = (UIImageView *)[circle viewWithTag:kLGPageBackChevronTag];
    if (!chevron) {
        chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
        chevron.tag = kLGPageBackChevronTag;
        chevron.userInteractionEnabled = NO;
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        [circle addSubview:chevron];
    }

    UIImage *symbol = LGPageBackChevronSymbolImage();
    chevron.image = [symbol imageWithTintColor:chevronColor renderingMode:UIImageRenderingModeAlwaysTemplate];
    chevron.tintColor = chevronColor;

    chevron.frame = LGPageBackChevronFrameForImageSize(chevron.image.size, kCircleSize);

    [circle bringSubviewToFront:chevron];
    [btn bringSubviewToFront:circle];
}

static UILabel *LGFindNavActionLabelInView(UIView *root) {
    if (!root) return nil;
    UILabel *fallback = nil;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)sub;
            if (!LGNavActionLabelHasText(label)) continue;
            NSString *cls = NSStringFromClass([label class]);
            if ([cls isEqualToString:@"UIButtonLabel"] || [cls rangeOfString:@"ButtonLabel"].location != NSNotFound)
                return label;
            if (!fallback) fallback = label;
        }
        UILabel *found = LGFindNavActionLabelInView(sub);
        if (found) {
            NSString *cls = NSStringFromClass([found class]);
            if ([cls isEqualToString:@"UIButtonLabel"] || [cls rangeOfString:@"ButtonLabel"].location != NSNotFound)
                return found;
            if (!fallback) fallback = found;
        }
    }
    return fallback;
}

static void LGRemoveSettingsActionButtonBackground(UIView *btn) {
    UIView *pill = [btn viewWithTag:kLGNavActionPillTag];
    if (pill) {
        LGRemoveSettingsNavButtonChromeFromBackground(pill);
        [pill removeFromSuperview];
    }
}

static void LGApplySettingsActionButtonBackground(UIView *btn) {
    if (!btn) return;
    if (!LGSettingsBackButtonFeatureEnabled()) {
        LGRemoveSettingsActionButtonBackground(btn);
        return;
    }
    if (!lgSettingsShouldModifyView(btn)) {
        LGRemoveSettingsActionButtonBackground(btn);
        return;
    }
    if (LGIsPageBackBarButton(btn)) {
        LGRemoveSettingsActionButtonBackground(btn);
        return;
    }
    if (!LGFindNavigationBarContentView(btn)) {
        LGRemoveSettingsActionButtonBackground(btn);
        return;
    }

    LGApplyStyledNavActionLabelsInView(btn);

    UILabel *label = LGFindNavActionLabelInView(btn);
    if (!label || label.hidden || label.alpha <= 0.01 || !LGNavActionLabelHasText(label)) {
        LGRemoveSettingsActionButtonBackground(btn);
        return;
    }
    LGStyleSettingsNavActionLabel(label);

    CGRect labelRect = [label.superview convertRect:label.frame toView:btn];
    if (CGRectIsEmpty(labelRect) || CGRectGetWidth(labelRect) < 2.0 || CGRectGetHeight(labelRect) < 2.0) {
        LGRemoveSettingsActionButtonBackground(btn);
        return;
    }

    static const CGFloat kPillHeight = 40.0;
    static const CGFloat kHPadding = 12.0;
    CGFloat pillWidth = MAX(kPillHeight, ceil(CGRectGetWidth(labelRect) + kHPadding * 2.0));
    CGFloat cx = CGRectGetMidX(labelRect);
    CGFloat cy = CGRectGetMidY(labelRect);
    CGRect pillFrame = CGRectMake(floor(cx - pillWidth * 0.5),
                                  floor(cy - kPillHeight * 0.5),
                                  pillWidth,
                                  kPillHeight);

    UIView *pill = [btn viewWithTag:kLGNavActionPillTag];
    if (!pill) {
        pill = [[UIView alloc] initWithFrame:pillFrame];
        pill.tag = kLGNavActionPillTag;
        pill.userInteractionEnabled = NO;
        if (@available(iOS 13.0, *)) pill.layer.cornerCurve = kCACornerCurveContinuous;
        [btn addSubview:pill];
    }
    BOOL isDark = LGPageBackIsDark(btn);
    pill.frame = pillFrame;
    LGApplySettingsNavButtonChromeToBackground(pill, isDark, 20.0);

    [btn sendSubviewToBack:pill];
    for (UIView *sub in btn.subviews) {
        if (sub != pill) [btn bringSubviewToFront:sub];
    }
    LGApplyStyledNavActionLabelsInView(btn);
}

static void LGEnforceSettingsBackButtonContainerWidth(UIView *btn) {
    if (!lgSettingsShouldModifyView(btn)) return;
    if (!btn) return;
    if (!LGSettingsBackButtonFeatureEnabled()) return;
    if (!LGLooksLikePageBackBarButton(btn)) return;

    static const CGFloat kBackContainerWidth = 40.0;

    CGRect frame = btn.frame;
    if (fabs(frame.size.width - kBackContainerWidth) > 0.5) {
        frame.size.width = kBackContainerWidth;
        btn.frame = frame;
    }

    CGRect bounds = btn.bounds;
    if (fabs(bounds.size.width - kBackContainerWidth) > 0.5) {
        bounds.size.width = kBackContainerWidth;
        btn.bounds = bounds;
    }
}

static CGRect LGSettingsPinnedButtonFrame(UIView *btn, CGRect frame) {
    if (!btn || !btn.window || !btn.superview) return frame;
    if (!LGSettingsBackButtonFeatureEnabled()) return frame;
    if (!LGFindNavigationBarContentView(btn)) return frame;

    UIWindow *window = btn.window;
    CGRect windowFrame = [btn.superview convertRect:frame toView:window];
    if (CGRectIsEmpty(windowFrame)) return frame;

    CGFloat windowWidth = CGRectGetWidth(window.bounds);
    CGFloat desiredMinX = 16.0;
    CGFloat desiredMaxX = windowWidth - 16.0 - CGRectGetWidth(windowFrame);
    BOOL isLeftSide = CGRectGetMidX(windowFrame) <= (windowWidth * 0.5);
    windowFrame.origin.x = isLeftSide ? desiredMinX : desiredMaxX;

    CGRect pinned = [btn.superview convertRect:windowFrame fromView:window];
    frame.origin.x = pinned.origin.x;
    return frame;
}

static void LGEnforceSettingsBackButtonLeftPin(UIView *btn) {
    if (!btn || !btn.window || !btn.superview) return;
    if (!lgSettingsShouldModifyView(btn)) return;
    if (!LGSettingsBackButtonFeatureEnabled()) return;
    if (!LGLooksLikePageBackBarButton(btn)) return;

    UIWindow *window = btn.window;
    CGRect windowFrame = [btn.superview convertRect:btn.frame toView:window];
    if (CGRectIsEmpty(windowFrame)) return;

    windowFrame.origin.x = 16.0;
    CGRect pinned = [btn.superview convertRect:windowFrame fromView:window];
    CGRect frame = btn.frame;
    frame.origin.x = pinned.origin.x;
    if (fabs(frame.origin.x - btn.frame.origin.x) > 0.5) btn.frame = frame;
}

@interface _UIButtonBarButton : UIControl
@end
@interface _UINavigationBarContentView : UIView
@end
@interface _UIBarBackground : UIView
@end

static void LGRefreshPageBackNavChromeInView(UIView *view) {
    if (!view) return;
    BOOL enabled = LGPageBackNavFeatureEnabled();
    NSString *cls = NSStringFromClass([view class]);
    if ([cls isEqualToString:@"_UIButtonBarButton"]) {
        if (enabled)
            LGApplyPageBackButtonStyle(view);
        else if (LGShouldTeardownPageBackButton(view))
            LGTeardownPageBackButtonStyle(view);
    } else if ([cls isEqualToString:@"_UINavigationBarContentView"]) {
        if (enabled)
            LGApplyNavBarContentViewClips(view);
        else
            LGRestoreNavBarContentViewClips(view);
    } else if ([cls isEqualToString:@"_UIBarBackground"] && LGIsBarBackgroundInNavigationBar(view)) {
        if (enabled)
            LGApplyNavBarBackgroundReplacement(view);
        else
            LGTeardownNavBarBackgroundReplacement(view);
    } else if ([view isKindOfClass:[UINavigationBar class]]) {
        UINavigationBar *bar = (UINavigationBar *)view;
        for (UIView *sub in bar.subviews) {
            if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"]) {
                if (enabled)
                    LGApplyNavBarBackgroundReplacement(sub);
                else
                    LGTeardownNavBarBackgroundReplacement(sub);
            }
        }
        if (!enabled) {
            LGRestoreNavigationBarFromGradientBlur(bar);
            LGRestoreNavBarChromeZOrder(bar);
        }
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    }
    for (UIView *sub in view.subviews)
        LGRefreshPageBackNavChromeInView(sub);
}

static void LGRefreshPageBackNavChromeInKeyWindows(void) {
    if (!LGIsLiquidGlassHostProcess()) return;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window) continue;
            LGRefreshPageBackNavChromeInView(window);
        }
    }
}

static void LGPageBackPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGRefreshPageBackNavChromeInKeyWindows();
    });
}

static void LGRegisterPageBackPrefsObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            LGPageBackPrefsChanged,
            kLGPrefsChangedNotification,
            NULL,
            CFNotificationSuspensionBehaviorCoalesce);
    });
}

%group PageBackButton
%hook _UIButtonBarButton
- (void)layoutSubviews {
    %orig;
    if (!LGPageBackNavFeatureEnabled()) {
        if (LGShouldTeardownPageBackButton((UIView *)self))
            LGTeardownPageBackButtonStyle((UIView *)self);
        return;
    }
    LGApplyPageBackButtonStyle((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (!LGPageBackNavFeatureEnabled()) {
        if (LGShouldTeardownPageBackButton((UIView *)self))
            LGTeardownPageBackButtonStyle((UIView *)self);
        return;
    }
    LGApplyPageBackButtonStyle((UIView *)self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    UIView *btn = (UIView *)self;
    if (!LGPageBackNavFeatureEnabled()) {
        if (LGShouldTeardownPageBackButton(btn))
            LGTeardownPageBackButtonStyle(btn);
        return;
    }
    if (@available(iOS 13.0, *)) {
        if (!previousTraitCollection ||
            [btn.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            LGApplyPageBackButtonStyle(btn);
        }
    } else {
        LGApplyPageBackButtonStyle(btn);
    }
}
%end

%hook _UINavigationBarContentView
- (void)layoutSubviews {
    %orig;
    UIView *content = (UIView *)self;
    if (!LGPageBackNavFeatureEnabled()) {
        LGRestoreNavBarContentViewClips(content);
        return;
    }
    LGApplyNavBarContentViewClips(content);
    UINavigationBar *bar = LGNavigationBarForView(content);
    LGEnsureNavBarChromeAboveBlur(bar, nil);
}
- (void)didMoveToWindow {
    %orig;
    if (!LGPageBackNavFeatureEnabled())
        LGRestoreNavBarContentViewClips((UIView *)self);
    else
        LGApplyNavBarContentViewClips((UIView *)self);
}
- (void)setClipsToBounds:(BOOL)clipsToBounds {
    if (LGPageBackNavFeatureEnabled())
        %orig(NO);
    else
        %orig(clipsToBounds);
}
%end

%hook _UIBarBackground
- (void)layoutSubviews {
    %orig;
    if (!LGIsBarBackgroundInNavigationBar((UIView *)self)) return;
    if (!LGPageBackNavFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement((UIView *)self);
        return;
    }
    LGApplyNavBarBackgroundReplacement((UIView *)self);
}
- (void)didMoveToSuperview {
    %orig;
    if (!LGIsBarBackgroundInNavigationBar((UIView *)self)) return;
    if (!LGPageBackNavFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement((UIView *)self);
        return;
    }
    LGApplyNavBarBackgroundReplacement((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    if (!LGIsBarBackgroundInNavigationBar((UIView *)self)) return;
    if (!LGPageBackNavFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement((UIView *)self);
        return;
    }
    LGApplyNavBarBackgroundReplacement((UIView *)self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    UIView *bg = (UIView *)self;
    if (!LGIsBarBackgroundInNavigationBar(bg)) return;
    if (!LGPageBackNavFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    UIView *replacement = objc_getAssociatedObject(bg, kLGNavBarBlurReplacementKey);
    if (replacement && replacement.superview)
        LGSyncNavBarTintGradient(replacement, (UINavigationBar *)bg.superview);
    LGApplyNavBarBackgroundReplacement(bg);
}
- (void)setAlpha:(CGFloat)alpha {
    if (LGPageBackNavFeatureEnabled() && LGIsBarBackgroundInNavigationBar((UIView *)self))
        %orig(0);
    else
        %orig(alpha);
}
- (void)setFrame:(CGRect)frame {
    %orig;
    UIView *bg = (UIView *)self;
    if (LGPageBackNavFeatureEnabled() && LGIsBarBackgroundInNavigationBar(bg))
        LGSyncNavBarBlurReplacement(bg, (UINavigationBar *)bg.superview);
}
%end

%hook UINavigationBar
- (void)layoutSubviews {
    %orig;
    UIView *bar = (UIView *)self;
    if (!LGPageBackNavFeatureEnabled()) {
        for (UIView *sub in bar.subviews) {
            if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"])
                LGTeardownNavBarBackgroundReplacement(sub);
        }
        return;
    }
    LGPrepareNavigationBarForGradientBlur((UINavigationBar *)self);
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"])
            LGApplyNavBarBackgroundReplacement(sub);
    }
}
- (void)setBackgroundImage:(UIImage *)image forBarMetrics:(UIBarMetrics)barMetrics {
    if (LGPageBackNavFeatureEnabled())
        %orig([UIImage new], barMetrics);
    else
        %orig(image, barMetrics);
}
%end
%end

%group SettingsBackButtonOnly
%hook _UIButtonBarButton
- (void)layoutSubviews {
    %orig;
    LGEnforceSettingsBackButtonContainerWidth((UIView *)self);
    CGRect f = ((UIView *)self).frame;
    CGRect pinned = LGSettingsPinnedButtonFrame((UIView *)self, f);
    if (fabs(pinned.origin.x - f.origin.x) > 0.5) ((UIView *)self).frame = pinned;
    LGEnforceSettingsBackButtonLeftPin((UIView *)self);
    dispatch_async(dispatch_get_main_queue(), ^{
        LGEnforceSettingsBackButtonLeftPin((UIView *)self);
    });
    LGApplySettingsBackButtonStyleVisualOnly((UIView *)self);
    LGApplySettingsActionButtonBackground((UIView *)self);
    __weak UIView *weakBtn = (UIView *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *btn = weakBtn;
        if (!btn) return;
        LGApplyStyledNavActionLabelsInView(btn);
        LGApplySettingsActionButtonBackground(btn);
    });
}
- (void)didMoveToWindow {
    %orig;
    LGEnforceSettingsBackButtonContainerWidth((UIView *)self);
    CGRect f = ((UIView *)self).frame;
    CGRect pinned = LGSettingsPinnedButtonFrame((UIView *)self, f);
    if (fabs(pinned.origin.x - f.origin.x) > 0.5) ((UIView *)self).frame = pinned;
    LGEnforceSettingsBackButtonLeftPin((UIView *)self);
    LGApplySettingsBackButtonStyleVisualOnly((UIView *)self);
    LGApplySettingsActionButtonBackground((UIView *)self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    UIView *btn = (UIView *)self;
    LGEnforceSettingsBackButtonContainerWidth(btn);
    if (@available(iOS 13.0, *)) {
        if (!previousTraitCollection ||
            [btn.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            LGApplySettingsBackButtonStyleVisualOnly(btn);
            LGApplySettingsActionButtonBackground(btn);
        }
    } else {
        LGApplySettingsBackButtonStyleVisualOnly(btn);
        LGApplySettingsActionButtonBackground(btn);
    }
}
- (void)setFrame:(CGRect)frame {
    if (LGSettingsBackButtonFeatureEnabled() && LGLooksLikePageBackBarButton((UIView *)self))
        frame.size.width = 40.0;
    frame = LGSettingsPinnedButtonFrame((UIView *)self, frame);
    %orig(frame);
    LGEnforceSettingsBackButtonLeftPin((UIView *)self);
}
- (void)setBounds:(CGRect)bounds {
    if (LGSettingsBackButtonFeatureEnabled() && LGLooksLikePageBackBarButton((UIView *)self))
        bounds.size.width = 40.0;
    %orig(bounds);
    LGEnforceSettingsBackButtonLeftPin((UIView *)self);
}
- (void)setCenter:(CGPoint)center {
    %orig(center);
    LGEnforceSettingsBackButtonLeftPin((UIView *)self);
}
%end

%hook _UINavigationBarContentView
- (void)layoutSubviews {
    %orig;
    UIView *content = (UIView *)self;
    if (!lgSettingsShouldModifyView(content)) {
        LGRestoreNavBarContentViewClips(content);
        return;
    }
    if (!LGSettingsBackButtonFeatureEnabled()) {
        LGRestoreNavBarContentViewClips(content);
        return;
    }
    LGApplyNavBarContentViewClips(content);
    UINavigationBar *bar = LGNavigationBarForView(content);
    LGEnsureNavBarChromeAboveBlur(bar, nil);
}
- (void)didMoveToWindow {
    %orig;
    UIView *content = (UIView *)self;
    if (!lgSettingsShouldModifyView(content))
        LGRestoreNavBarContentViewClips(content);
    else if (!LGSettingsBackButtonFeatureEnabled())
        LGRestoreNavBarContentViewClips(content);
    else
        LGApplyNavBarContentViewClips(content);
}
- (void)setClipsToBounds:(BOOL)clipsToBounds {
    if (LGSettingsBackButtonFeatureEnabled() && lgSettingsShouldModifyView((UIView *)self))
        %orig(NO);
    else
        %orig(clipsToBounds);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    if (LGIsSettingsNavActionLabel(self)) {
        %orig(LGSettingsNavActionTextColor(LGPageBackIsDark(self)));
        return;
    }
    %orig;
}
- (void)setAttributedText:(NSAttributedString *)text {
    if (LGIsSettingsNavActionLabel(self) && text.length) {
        UIColor *textColor = LGSettingsNavActionTextColor(LGPageBackIsDark(self));
        NSMutableAttributedString *styled = [text mutableCopy];
        [styled addAttribute:NSForegroundColorAttributeName value:textColor
                       range:NSMakeRange(0, styled.length)];
        %orig([styled copy]);
        return;
    }
    %orig;
}
- (void)setText:(NSString *)text {
    %orig;
    if (LGIsSettingsNavActionLabel(self) && text.length)
        LGStyleSettingsNavActionLabel(self);
}
%end

%hook _UIBarBackground
- (void)layoutSubviews {
    %orig;
    UIView *bg = (UIView *)self;
    if (!LGIsBarBackgroundInNavigationBar(bg)) return;
    if (!lgSettingsShouldModifyView(bg)) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    if (!LGSettingsBackButtonFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    LGApplyNavBarBackgroundReplacement(bg);
}
- (void)didMoveToWindow {
    %orig;
    UIView *bg = (UIView *)self;
    if (!LGIsBarBackgroundInNavigationBar(bg)) return;
    if (!lgSettingsShouldModifyView(bg)) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    if (!LGSettingsBackButtonFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    LGApplyNavBarBackgroundReplacement(bg);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    UIView *bg = (UIView *)self;
    if (!LGIsBarBackgroundInNavigationBar(bg)) return;
    if (!lgSettingsShouldModifyView(bg)) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    if (!LGSettingsBackButtonFeatureEnabled()) {
        LGTeardownNavBarBackgroundReplacement(bg);
        return;
    }
    UIView *replacement = objc_getAssociatedObject(bg, kLGNavBarBlurReplacementKey);
    if (replacement && replacement.superview)
        LGSyncNavBarTintGradient(replacement, (UINavigationBar *)bg.superview);
    LGApplyNavBarBackgroundReplacement(bg);
}
- (void)setAlpha:(CGFloat)alpha {
    UIView *bg = (UIView *)self;
    if (LGSettingsBackButtonFeatureEnabled() && LGIsBarBackgroundInNavigationBar(bg) && lgSettingsShouldModifyView(bg))
        %orig(0);
    else
        %orig(alpha);
}
%end

%hook UINavigationBar
- (void)layoutSubviews {
    %orig;
    UIView *bar = (UIView *)self;
    if (!lgSettingsShouldModifyView(bar)) {
        for (UIView *sub in bar.subviews) {
            if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"])
                LGTeardownNavBarBackgroundReplacement(sub);
        }
        return;
    }
    if (!LGSettingsBackButtonFeatureEnabled()) {
        for (UIView *sub in bar.subviews) {
            if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"])
                LGTeardownNavBarBackgroundReplacement(sub);
        }
        return;
    }
    LGPrepareNavigationBarForGradientBlur((UINavigationBar *)self);
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass([sub class]) isEqualToString:@"_UIBarBackground"])
            LGApplyNavBarBackgroundReplacement(sub);
    }
}
%end
%end

// ── Settings app cell styling (iOS 26+ rounded rows) ─────────────────────────
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)property forKey:(NSString *)key;
+ (instancetype)preferenceSpecifierNamed:(NSString *)identifier target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(NSInteger)cellType edit:(Class)edit;
@property (nonatomic) Class detailControllerClass;
@end

@interface PSListController : NSObject
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (NSIndexPath *)indexPathForSpecifier:(PSSpecifier *)specifier;
- (NSBundle *)bundle;
- (NSString *)title;
- (UITableView *)table;
- (void)reloadSpecifiers;
- (void)pushController:(id)controller;
- (void)showController:(id)controller;
- (void)pushDetailController:(id)controller;
- (void)didSelectSpecifier:(PSSpecifier *)specifier;
- (NSArray *)specifiers;
- (id)specifierIDPendingPush;
@property (nonatomic, readonly) UINavigationController *navigationController;
@end

static const CGFloat kLGSettings26CornerRadius = 25.0;
static const CGFloat kLGSettings26TargetCellHeight = 50.0;
static const void *kLGSettings26OriginalCornerRadiusKey = &kLGSettings26OriginalCornerRadiusKey;
static const void *kLGSettings26HeaderFooterLabelBoldKey = &kLGSettings26HeaderFooterLabelBoldKey;

static CGFloat lgSettings26ResolvedCellHeight(CGFloat originalHeight) {
    return MAX(originalHeight, kLGSettings26TargetCellHeight);
}

static BOOL lgSettings26IsAppleAccountCellClass(Class cellClass) {
    if (!cellClass) return NO;
    Class appleAccountClass = NSClassFromString(@"PSUIAppleAccountCell");
    if (appleAccountClass && [cellClass isSubclassOfClass:appleAccountClass]) return YES;
    return [NSStringFromClass(cellClass) isEqualToString:@"PSUIAppleAccountCell"];
}

static BOOL lgSettings26ShouldPreserveCellHeight(Class cellClass) {
    if (lgSettings26IsAppleAccountCellClass(cellClass)) return YES;
    if (!cellClass) return NO;
    NSString *className = NSStringFromClass(cellClass);
    return [className isEqualToString:@"PSCapacityBarCell"]
        || [className isEqualToString:@"PSGPreBuddyCell"]
        || [className isEqualToString:@"PSGCurrentTimeCell"];
}

static BOOL lgSettings26IsPSListController(id controller) {
    if (!controller) return NO;
    Class listClass = NSClassFromString(@"PSListController");
    return listClass && [controller isKindOfClass:listClass];
}

static BOOL lgPageLabelsControllerSupportsPageHeader(id controller) {
    return lgSettingsShouldModifyController(controller) && lgSettings26IsPSListController(controller);
}

static BOOL lgSettings26IsThirdPartyPreferenceBundle(NSBundle *bundle) {
    if (!bundle) return NO;

    NSString *bundleID = bundle.bundleIdentifier;
    if (bundleID.length && [bundleID hasPrefix:@"com.apple."])
        return NO;

    NSString *bundlePath = bundle.bundlePath ?: @"";
    if ([bundlePath containsString:@"/System/Library/PreferenceBundles/"] ||
        [bundlePath containsString:@"/System/Applications/Settings.app/"] ||
        [bundlePath containsString:@"/Applications/Preferences.app/"] ||
        [bundlePath containsString:@"/System/Library/PrivateFrameworks/"] ||
        [bundlePath containsString:@"/System/Library/Frameworks/"] ||
        [bundlePath hasPrefix:@"/System/"] ||
        [bundlePath containsString:@"/var/jb/System/"]) {
        return NO;
    }

    // Jailbreak/tweak bundles live here; Apple panes use com.apple.* IDs above.
    if ([bundlePath containsString:@"PreferenceBundles"])
        return YES;

    return NO;
}

static BOOL lgSettings26IsAppleSettingsBundle(NSBundle *bundle) {
    return !lgSettings26IsThirdPartyPreferenceBundle(bundle);
}

static NSBundle *lgSettings26BundleForController(id controller) {
    if (!controller) return nil;
    if ([controller respondsToSelector:@selector(bundle)]) {
        NSBundle *controllerBundle = [controller bundle];
        if (controllerBundle) return controllerBundle;
    }
    @try {
        id bundleValue = [controller valueForKey:@"bundle"];
        if ([bundleValue isKindOfClass:[NSBundle class]]) return (NSBundle *)bundleValue;
    } @catch (__unused NSException *e) {}
    NSBundle *classBundle = [NSBundle bundleForClass:object_getClass(controller)];
    if (classBundle) return classBundle;
    return nil;
}

static BOOL lgSettings26BundleContainsAppleIdentifier(NSBundle *bundle) {
    if (!bundle) return NO;
    NSString *bundleID = bundle.bundleIdentifier;
    if (bundleID.length && [bundleID containsString:@"com.apple."])
        return YES;
    NSString *bundlePath = bundle.bundlePath ?: @"";
    return [bundlePath containsString:@"com.apple."];
}

static BOOL lgSettings26ShouldAffectController(id controller) {
    if (!controller) return YES;
    return lgSettings26IsAppleSettingsBundle(lgSettings26BundleForController(controller));
}

static BOOL lgSettings26ShouldAffectCellLayout(id controller) {
    if (!lgSettingsShouldModifyController(controller)) return NO;
    if (!lgSettings26IsPSListController(controller)) return NO;
    NSBundle *bundle = lgSettings26BundleForController(controller);
    if (lgSettings26BundleContainsAppleIdentifier(bundle)) return YES;
    return lgSettings26ShouldAffectController(controller);
}

static UITableView *lgSettings26OwningTableViewForView(UIView *view) {
    UIView *current = view.superview;
    while (current) {
        if ([current isKindOfClass:[UITableView class]]) return (UITableView *)current;
        current = current.superview;
    }
    return nil;
}

static BOOL lgSettings26ShouldAffectCell(UIView *cellView) {
    if (!cellView) return NO;
    UITableView *tableView = lgSettings26OwningTableViewForView(cellView);
    if (tableView) {
        id delegate = tableView.delegate;
        if ([delegate isKindOfClass:[UIViewController class]] && lgSettings26ShouldAffectCellLayout(delegate))
            return YES;
    }
    UIResponder *responder = cellView;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]] && lgSettings26ShouldAffectCellLayout((id)responder))
            return YES;
        responder = responder.nextResponder;
    }
    return NO;
}

static void lgSettings26ApplyScaledCornerRadius(CALayer *layer, BOOL forceWhenZero) {
    if (!layer) return;
    NSNumber *storedRadius = objc_getAssociatedObject(layer, kLGSettings26OriginalCornerRadiusKey);
    if (!storedRadius) {
        CGFloat originalRadius = layer.cornerRadius;
        if (originalRadius <= 0.0 && !forceWhenZero) return;
        storedRadius = @(originalRadius);
        objc_setAssociatedObject(layer, kLGSettings26OriginalCornerRadiusKey, storedRadius, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    layer.cornerRadius = kLGSettings26CornerRadius;
}

static void lgSettings26ApplyTableCellCornerRadius(UIView *rootView) {
    if (!rootView) return;
    BOOL forceRadius = lgSettings26IsAppleAccountCellClass(object_getClass((id)rootView));
    UITableViewCell *tableCell = [rootView isKindOfClass:[UITableViewCell class]] ? (UITableViewCell *)rootView : nil;
    UIView *contentView = tableCell.contentView;
    lgSettings26ApplyScaledCornerRadius(rootView.layer, forceRadius);
    lgSettings26ApplyScaledCornerRadius(contentView.layer, forceRadius);
    if (tableCell) {
        lgSettings26ApplyScaledCornerRadius(tableCell.backgroundView.layer, forceRadius);
        lgSettings26ApplyScaledCornerRadius(tableCell.selectedBackgroundView.layer, forceRadius);
    }
}

static void lgSettings26ApplyTableCellLayout(UIView *rootView) {
    if (!LGSettings26FeatureEnabled() || !lgSettings26ShouldAffectCell(rootView)) return;
    // Corner radius only — row height is handled by setFrame/setBounds/heightForRowAtIndexPath.
    // Mutating cell bounds during layoutSubviews corrupts UITableView layout and can crash.
    lgSettings26ApplyTableCellCornerRadius(rootView);
}

// ── Settings page label (table header; specifiers / data source untouched) ───
static NSString *const kLGPageLabelsMarkerID = @"LiquidGlassPageLabel";
static const CGFloat kLGPageLabelsMinHeight = 44.0;
static const CGFloat kLGPageLabelsHeaderTopGap = 16.0;
static const CGFloat kLGPageLabelsHeaderBottomGap = 20.0;
static const CGFloat kLGPageLabelsHorizontalInset = 16.0;
static const NSUInteger kLGPageLabelsCardViewTag = 0x4C474201;
static const NSUInteger kLGPageLabelsIconViewTag = 0x4C474202;
static const NSUInteger kLGPageLabelsTitleViewTag = 0x4C474203;
static const NSUInteger kLGPageLabelsSubtitleViewTag = 0x4C474204;
static const void *kLGPageLabelsHeaderViewKey = &kLGPageLabelsHeaderViewKey;
static const void *kLGPageLabelsLayoutInProgressKey = &kLGPageLabelsLayoutInProgressKey;
static const void *kLGPageLabelsIconKey = &kLGPageLabelsIconKey;
static const void *kLGPageLabelsLastSelectedIndexPathKey = &kLGPageLabelsLastSelectedIndexPathKey;
static const void *kLGPageLabelsLastCapturedIconKey = &kLGPageLabelsLastCapturedIconKey;
static const void *kLGPageLabelsDisplayedIconCacheKey = &kLGPageLabelsDisplayedIconCacheKey;
static const void *kLGPageLabelsLastCapturedSpecifierKey = &kLGPageLabelsLastCapturedSpecifierKey;
static const CGFloat kLGPageLabelsIconSize = 58.0;
static const CGFloat kLGPageLabelsCellHorizontalInset = 16.0;
static const CGFloat kLGPageLabelsCellVerticalInset = 16.0;
static const CGFloat kLGPageLabelsSubtitleTextAlpha = 0.6;
static const CGFloat kLGPageLabelsIconLabelGap = 8.0;
static const CGFloat kLGPageLabelsTitleSubtitleGap = 6.0;
static const CGFloat kLGPageLabelsTitleFontSize = 17.0;
static const CGFloat kLGPageLabelsSubtitleFontSize = 14.0;

// Page label descriptions - add entries here; `title` must match the Settings navigation title exactly.
static NSArray<NSDictionary *> *LGPageLabelDescriptionEntries(void) {
    static NSArray<NSDictionary *> *entries = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = @[
            @{@"title": @"Bluetooth",
              @"description": @"Connect to accessories you can use for activities such as streaming music, making phone calls, and gaming."},
             @{@"title": @"Cellular",
              @"description": @"Find out how much data you're using, set data restrictions, and manage carrier settings such as eSIM and Wi-Fi calling."},
            @{@"title": @"Personal Hotspot",
              @"description": @"Personal Hotspot allows you to share a mobile data connection from your iPhone to other nearby devices."},
            @{@"title": @"Screen Time",
              @"description": @"Get insights about your screen time and set limits as needed. Adults can also set parental controls for a child's device."},
            @{@"title": @"General",
              @"description": @"Manage your overall setup and preferences for iPhone, such as software updates, device language, CarPlay, AirDrop, and more."},
            @{@"title": @"Control Center",
              @"description": @"Swipe down from the top-right edge to open Control Center. Here, you can add or remove controls."},
            @{@"title": @"Accessibility",
              @"description": @"Personalize iPhone in ways that work best for you with accessibility features for vision, mobility, hearing, speech, and cognition."},
            @{@"title": @"Siri & Search",
              @"description": @"A personal intelligence system integrated deeply into your iPhone, apps, and Siri."},
            @{@"title": @"Face ID & Passcode",
              @"description": @"Manage apps using Face ID and other iPhone access settings, set up alternative appearances, and change your passcode."},
            @{@"title": @"Privacy & Security",
              @"description": @"Control which apps can access your data, location, camera, and microphone, and manage safety protections."},
            @{@"title": @"System Apps",
              @"description": @"Customize settings for apps included with your iPhone."},
            @{@"title": @"App Store Apps",
              @"description": @"Customize settings for third-party apps downloaded from the App Store."},
        ];
    });
    return entries;
}

static NSString *lgPageLabelsDescriptionForPageTitle(NSString *pageTitle) {
    if (!pageTitle.length) return nil;
    for (NSDictionary *entry in LGPageLabelDescriptionEntries()) {
        id title = entry[@"title"];
        id description = entry[@"description"];
        if (![title isKindOfClass:[NSString class]] || ![description isKindOfClass:[NSString class]]) continue;
        if ([(NSString *)title isEqualToString:pageTitle]) return (NSString *)description;
    }
    return nil;
}

static NSString *lgPageLabelsPageTitleForController(id controller);
static BOOL lgPageLabelsIsActiveForController(id controller);

static NSString *lgPageLabelsDescriptionForController(id controller) {
    return lgPageLabelsDescriptionForPageTitle(lgPageLabelsPageTitleForController(controller));
}

static BOOL lgPageLabelsShouldShowPageHeader(id controller) {
    if (!lgPageLabelsIsActiveForController(controller)) return NO;
    return lgPageLabelsDescriptionForController(controller).length > 0;
}

static UIImage *gLGPageLabelsPendingIcon = nil;
static UIImage *gLGPageLabelsLastNavigationIcon = nil;
static NSMutableDictionary *gLGPageLabelsIconsByTitle = nil;

static void lgPageLabelsConfigureCard(UIView *card, id controller);
static void lgPageLabelsLayoutCardSubviews(UIView *card, id controller);
static UITableView *lgPageLabelsTableViewForController(id controller);
static id lgPageLabelsHeaderHostController(id controller);
static void lgPageLabelsStoreIconForController(id controller, UIImage *icon);
static BOOL lgPageLabelsIsActiveForController(id controller);
static UIImage *lgPageLabelsIconForController(id controller);
static void lgPageLabelsInstallTableHeader(id controller);
static void lgPageLabelsRemoveTableHeader(id controller);
static void lgPageLabelsClearWiFiPaneCustomizations(id controller);
static void lgPageLabelsSetPendingIcon(UIImage *icon);
static void lgPageLabelsCaptureIconFromCell(UITableViewCell *cell, id sourceController, PSSpecifier *specifier);
static void lgPageLabelsCaptureNavigationFromSource(id source, UITableView *tableView, NSIndexPath *indexPath,
    PSSpecifier *specifier);
static UIImage *lgPageLabelsExtractIconAggressive(UITableViewCell *cell, PSSpecifier *specifier, id controller,
    NSIndexPath *indexPath);
static void lgPageLabelsCacheIconForController(id controller, NSIndexPath *indexPath, PSSpecifier *specifier,
    UIImage *icon);
static UIImage *lgPageLabelsRasterizeLeadingIconFromContentView(UIView *contentView);
static UIImage *lgPageLabelsExtractIconFromSpecifier(PSSpecifier *specifier, id controller);
static id lgPageLabelsListControllerForTableView(UITableView *tableView);
static void lgPageLabelsLayoutHeaderContainer(UIView *container, UITableView *tableView, id controller);
static void lgPageLabelsResolveIconAfterPushFromSource(id source, id destination);
static void lgPageLabelsHandleNavigationFromSourceToDestination(id source, id destination);
static UIImage *lgPageLabelsCaptureIconFromViewController(id source);
static BOOL lgPageLabelsShouldCaptureIcons(void);
static BOOL lgPageLabelsIsPageLabelSpecifier(PSSpecifier *specifier);
static void lgPageLabelsRememberCapturedIcon(id sourceController, PSSpecifier *specifier, UIImage *icon);
static id lgPageLabelsSend0(id target, SEL selector);
static id lgPageLabelsSend1(id target, SEL selector, id arg1);
static UIImage *lgPageLabelsCaptureFromPendingPushSpec(id source);
static PSSpecifier *lgPageLabelsSpecifierWithID(id controller, id specID);
static UIImage *lgPageLabelsExtractIconFromCellSnapshot(UITableViewCell *cell);
static NSString *lgPageLabelsPageTitleForController(id controller);
static BOOL lgPageLabelsDestinationAcceptsIcon(id destination);

static CGFloat lgPageLabelsCellHeight(void) {
    return LGSettings26FeatureEnabled()
        ? lgSettings26ResolvedCellHeight(kLGPageLabelsMinHeight)
        : kLGPageLabelsMinHeight;
}

static UIImage *lgPageLabelsCopyImage(UIImage *image) {
    if (!image) return nil;
    CGImageRef cgImage = image.CGImage;
    if (cgImage)
        return [UIImage imageWithCGImage:cgImage scale:image.scale orientation:image.imageOrientation];
    UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
    [image drawAtPoint:CGPointZero];
    UIImage *copy = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return copy;
}

/// Deep-copies the leading icon from the cell content view before Settings recycles/unloads it.
static UIImage *lgPageLabelsRasterizeView(UIView *view) {
    if (!view || view.bounds.size.width < 1.0 || view.bounds.size.height < 1.0) return nil;
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, NO, 0.0);
    BOOL drew = [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    if (!drew)
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return lgPageLabelsCopyImage(snapshot);
}

static BOOL lgPageLabelsImageHasVisiblePixels(UIImage *image) {
    if (!image) return NO;
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return NO;
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width < 2 || height < 2) return NO;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return NO;
    uint8_t pixel[4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) {
        CGColorSpaceRelease(colorSpace);
        return NO;
    }

    CGContextDrawImage(ctx, CGRectMake(0, 0, 1, 1), cgImage);
    CGContextRelease(ctx);
    if (pixel[3] > 8) {
        CGColorSpaceRelease(colorSpace);
        return YES;
    }

    CGContextRef ctx2 = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (ctx2) {
        CGContextDrawImage(ctx2, CGRectMake(0, 0, 1, 1), cgImage);
        CGContextRelease(ctx2);
        if (pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8) return YES;
    }
    return NO;
}

static NSString *lgPageLabelsCacheKeyForIndexPath(NSIndexPath *indexPath) {
    if (!indexPath) return nil;
    return [NSString stringWithFormat:@"%ld-%ld", (long)indexPath.section, (long)indexPath.row];
}

static NSString *lgPageLabelsCacheKeyForSpecifier(PSSpecifier *specifier) {
    if (!specifier) return nil;
    id specID = [specifier propertyForKey:@"id"];
    if ([specID isKindOfClass:[NSString class]] && [(NSString *)specID length])
        return [NSString stringWithFormat:@"id:%@", specID];
    id label = [specifier propertyForKey:@"label"];
    if ([label isKindOfClass:[NSString class]] && [(NSString *)label length])
        return [NSString stringWithFormat:@"label:%@", label];
    return [NSString stringWithFormat:@"ptr:%p", specifier];
}

static NSMutableDictionary *lgPageLabelsIconCacheForController(id controller) {
    if (!controller) return nil;
    NSMutableDictionary *cache = objc_getAssociatedObject(controller, kLGPageLabelsDisplayedIconCacheKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(controller, kLGPageLabelsDisplayedIconCacheKey, cache,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cache;
}

static void lgPageLabelsCacheIconForController(id controller, NSIndexPath *indexPath, PSSpecifier *specifier,
    UIImage *icon) {
    if (!controller || !icon) return;
    UIImage *copy = lgPageLabelsCopyImage(icon);
    if (!copy) return;
    NSMutableDictionary *cache = lgPageLabelsIconCacheForController(controller);
    NSString *pathKey = lgPageLabelsCacheKeyForIndexPath(indexPath);
    if (pathKey) cache[pathKey] = copy;
    NSString *specKey = lgPageLabelsCacheKeyForSpecifier(specifier);
    if (specKey) cache[specKey] = copy;
}

static UIImage *lgPageLabelsCachedIconForController(id controller, NSIndexPath *indexPath, PSSpecifier *specifier) {
    NSMutableDictionary *cache = lgPageLabelsIconCacheForController(controller);
    if (!cache) return nil;
    if (indexPath) {
        id icon = cache[lgPageLabelsCacheKeyForIndexPath(indexPath)];
        if ([icon isKindOfClass:[UIImage class]]) return (UIImage *)icon;
    }
    if (specifier) {
        id icon = cache[lgPageLabelsCacheKeyForSpecifier(specifier)];
        if ([icon isKindOfClass:[UIImage class]]) return (UIImage *)icon;
    }
    return nil;
}

static id lgPageLabelsListControllerForTableView(UITableView *tableView) {
    if (!tableView) return nil;
    Class listClass = NSClassFromString(@"PSListController");
    id delegate = tableView.delegate;
    if (listClass && delegate && [delegate isKindOfClass:listClass])
        return delegate;

    UIResponder *responder = tableView;
    while (responder) {
        if (listClass && [responder isKindOfClass:listClass])
            return responder;
        responder = responder.nextResponder;
    }
    return delegate;
}

static void lgPageLabelsRememberIconForTitle(NSString *title, UIImage *icon) {
    if (!title.length || !icon) return;
    if (!gLGPageLabelsIconsByTitle)
        gLGPageLabelsIconsByTitle = [NSMutableDictionary dictionary];
    gLGPageLabelsIconsByTitle[title] = lgPageLabelsCopyImage(icon);
}

static UIImage *lgPageLabelsIconForTitle(NSString *title) {
    if (!title.length || !gLGPageLabelsIconsByTitle) return nil;
    id icon = gLGPageLabelsIconsByTitle[title];
    if ([icon isKindOfClass:[UIImage class]]) return (UIImage *)icon;
    for (NSString *key in gLGPageLabelsIconsByTitle) {
        if ([key caseInsensitiveCompare:title] == NSOrderedSame) {
            icon = gLGPageLabelsIconsByTitle[key];
            if ([icon isKindOfClass:[UIImage class]]) return (UIImage *)icon;
        }
    }
    return nil;
}

static PSSpecifier *lgPageLabelsSpecifierWithID(id controller, id specID) {
    if (!controller || !specID || ![controller respondsToSelector:@selector(specifiers)]) return nil;
    NSArray *specifiers = [(PSListController *)controller specifiers];
    if (!specifiers.count) return nil;
    Class specClass = objc_getClass("PSSpecifier");
    for (id spec in specifiers) {
        if (!specClass || ![spec isKindOfClass:specClass]) continue;
        id candidateID = [(id)spec propertyForKey:@"id"];
        if (candidateID && [candidateID isEqual:specID])
            return (PSSpecifier *)spec;
    }
    return nil;
}

static UIImage *lgPageLabelsCaptureFromPendingPushSpec(id source) {
    if (!source) return nil;
    id pendingID = lgPageLabelsSend0(source, @selector(specifierIDPendingPush));
    if (!pendingID) return nil;

    PSSpecifier *specifier = lgPageLabelsSpecifierWithID(source, pendingID);
    UITableViewCell *cell = lgPageLabelsSend1(source, NSSelectorFromString(@"cachedCellForSpecifierID:"), pendingID);
    if (![cell isKindOfClass:[UITableViewCell class]])
        cell = lgPageLabelsSend1(source, @selector(cachedCellForSpecifier:), specifier);

    NSIndexPath *indexPath = nil;
    if (specifier && [source respondsToSelector:@selector(indexPathForSpecifier:)])
        indexPath = [(PSListController *)source indexPathForSpecifier:specifier];

    return lgPageLabelsExtractIconAggressive(cell, specifier, source, indexPath);
}

static id lgPageLabelsSend0(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static id lgPageLabelsSend1(id target, SEL selector, id arg1) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, selector, arg1);
}

static UIImage *lgPageLabelsImageFromLayerContents(id contents) {
    if (!contents) return nil;
    if ([contents isKindOfClass:[UIImage class]])
        return lgPageLabelsCopyImage((UIImage *)contents);
    if ([contents isKindOfClass:[NSURL class]]) {
        UIImage *fileImage = [UIImage imageWithContentsOfFile:[(NSURL *)contents path]];
        return fileImage ? lgPageLabelsCopyImage(fileImage) : nil;
    }
    @try {
        CFTypeRef cfContents = (__bridge CFTypeRef)contents;
        if (cfContents && CFGetTypeID(cfContents) == CGImageGetTypeID())
            return [UIImage imageWithCGImage:(CGImageRef)cfContents];
    } @catch (__unused NSException *e) {}
    return nil;
}

static UIImage *lgPageLabelsExtractIconFromViewTree(UIView *root, BOOL preferLeading) {
    if (!root) return nil;
    UIImageView *bestImageView = nil;
    UIView *bestLayerView = nil;
    CGFloat bestMinX = CGFLOAT_MAX;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([view isKindOfClass:[UIImageView class]]) {
            UIImageView *candidate = (UIImageView *)view;
            UIImage *image = candidate.image;
            CGRect frameInRoot = [root convertRect:candidate.bounds fromView:candidate];
            CGFloat minX = CGRectGetMinX(frameInRoot);
            if (image && image.size.width > 0.0 && image.size.height > 0.0) {
                if (!preferLeading || minX < bestMinX) {
                    bestMinX = minX;
                    bestImageView = candidate;
                }
            } else if (candidate.layer.contents) {
                if (!preferLeading || minX < bestMinX) {
                    bestMinX = minX;
                    bestLayerView = candidate;
                }
            } else if (candidate.bounds.size.width >= 18.0 && candidate.bounds.size.height >= 18.0
                && (!preferLeading || minX < 80.0)) {
                UIImage *snapshot = lgPageLabelsRasterizeView(candidate);
                if (snapshot) return snapshot;
            }
        } else if (view.layer.contents && view.bounds.size.width >= 18.0 && view.bounds.size.height >= 18.0) {
            CGRect frameInRoot = [root convertRect:view.bounds fromView:view];
            CGFloat minX = CGRectGetMinX(frameInRoot);
            if (!preferLeading || minX < bestMinX) {
                bestMinX = minX;
                bestLayerView = view;
            }
        }

        for (UIView *sub in view.subviews)
            [queue addObject:sub];
    }

    if (bestImageView && bestImageView.image)
        return lgPageLabelsCopyImage(bestImageView.image);
    if (bestLayerView) {
        UIImage *layerImage = lgPageLabelsImageFromLayerContents(bestLayerView.layer.contents);
        if (layerImage) return layerImage;
        return lgPageLabelsRasterizeView(bestLayerView);
    }
    return nil;
}

static UIImage *lgPageLabelsExtractIconViaPSTableCellAPI(UITableViewCell *cell) {
    if (!cell) return nil;
    Class psCellClass = NSClassFromString(@"PSTableCell");
    if (!psCellClass || ![cell isKindOfClass:psCellClass]) return nil;

    id iconValue = lgPageLabelsSend0((id)cell, @selector(getIcon));
    if ([iconValue isKindOfClass:[UIImage class]] && ((UIImage *)iconValue).size.width > 0.0)
        return lgPageLabelsCopyImage((UIImage *)iconValue);

    iconValue = [(id)cell valueForKey:@"icon"];
    if ([iconValue isKindOfClass:[UIImage class]] && ((UIImage *)iconValue).size.width > 0.0)
        return lgPageLabelsCopyImage((UIImage *)iconValue);

    if ([(id)cell respondsToSelector:@selector(forceSynchronousIconLoadOnNextIconLoad)])
        ((void (*)(id, SEL))objc_msgSend)((id)cell, @selector(forceSynchronousIconLoadOnNextIconLoad));

    iconValue = lgPageLabelsSend0((id)cell, @selector(getLazyIcon));
    if ([iconValue isKindOfClass:[UIImage class]] && ((UIImage *)iconValue).size.width > 0.0)
        return lgPageLabelsCopyImage((UIImage *)iconValue);

    iconValue = lgPageLabelsSend0((id)cell, NSSelectorFromString(@"getLazyIcon"));
    if ([iconValue isKindOfClass:[UIImage class]] && ((UIImage *)iconValue).size.width > 0.0)
        return lgPageLabelsCopyImage((UIImage *)iconValue);

    id iconView = lgPageLabelsSend0((id)cell, @selector(iconImageView));
    if ([iconView isKindOfClass:[UIImageView class]]) {
        UIImage *viewImage = ((UIImageView *)iconView).image;
        if (viewImage && viewImage.size.width > 0.0)
            return lgPageLabelsCopyImage(viewImage);
        UIImage *layerImage = lgPageLabelsImageFromLayerContents(((UIImageView *)iconView).layer.contents);
        if (layerImage) return layerImage;
        return lgPageLabelsRasterizeView((UIView *)iconView);
    }

    for (NSString *key in @[@"iconImageView", @"_iconImageView", @"iconView", @"_iconView", @"_iconContainerView"]) {
        @try {
            id viewValue = [(id)cell valueForKey:key];
            if ([viewValue isKindOfClass:[UIView class]]) {
                UIImage *treeIcon = lgPageLabelsExtractIconFromViewTree((UIView *)viewValue, NO);
                if (treeIcon) return treeIcon;
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static UIImage *lgPageLabelsExtractIconViaListController(id controller, PSSpecifier *specifier, UITableViewCell *cell) {
    if (!controller || !specifier) return nil;

    id cachedCell = lgPageLabelsSend1(controller, @selector(cachedCellForSpecifier:), specifier);
    if ([cachedCell isKindOfClass:[UITableViewCell class]]) {
        UIImage *cachedIcon = lgPageLabelsExtractIconViaPSTableCellAPI((UITableViewCell *)cachedCell);
        if (cachedIcon) return cachedIcon;
        cachedIcon = lgPageLabelsExtractIconFromViewTree(((UITableViewCell *)cachedCell).contentView, YES);
        if (cachedIcon) return cachedIcon;
    }

    id specID = [specifier propertyForKey:@"id"];
    if ([specID isKindOfClass:[NSString class]]) {
        cachedCell = lgPageLabelsSend1(controller, NSSelectorFromString(@"cachedCellForSpecifierID:"), specID);
        if ([cachedCell isKindOfClass:[UITableViewCell class]]) {
            UIImage *cachedIcon = lgPageLabelsExtractIconViaPSTableCellAPI((UITableViewCell *)cachedCell);
            if (cachedIcon) return cachedIcon;
        }
    }

    for (NSString *selName in @[
        @"iconForSpecifier:", @"_iconForSpecifier:", @"imageForSpecifier:", @"_imageForSpecifier:",
        @"loadIconForSpecifier:", @"_loadIconForSpecifier:"
    ]) {
        SEL sel = NSSelectorFromString(selName);
        id result = lgPageLabelsSend1(controller, sel, specifier);
        if ([result isKindOfClass:[UIImage class]] && ((UIImage *)result).size.width > 0.0)
            return lgPageLabelsCopyImage((UIImage *)result);
    }

    if ([controller respondsToSelector:@selector(setForceSynchronousIconLoadForCreatedCells:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setForceSynchronousIconLoadForCreatedCells:), YES);
        if (cell && [cell respondsToSelector:@selector(refreshCellContentsWithSpecifier:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)((id)cell, @selector(refreshCellContentsWithSpecifier:), specifier);
            UIImage *refreshed = lgPageLabelsExtractIconViaPSTableCellAPI(cell);
            if (refreshed) return refreshed;
        }
    }
    return nil;
}

static UIImage *lgPageLabelsExtractLazyAppIcon(PSSpecifier *specifier) {
    if (!specifier) return nil;
    NSString *appID = nil;
    for (NSString *key in @[@"appIDForLazyIcon", @"bundleID", @"applicationIdentifier", @"appID"]) {
        id value = [specifier propertyForKey:key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
            appID = (NSString *)value;
            break;
        }
    }
    if (!appID.length) return nil;

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass && [workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        id workspace = lgPageLabelsSend0(workspaceClass, @selector(defaultWorkspace));
        if (workspace && [workspace respondsToSelector:@selector(iconForApplication:)]) {
            id icon = lgPageLabelsSend1(workspace, @selector(iconForApplication:), appID);
            if ([icon isKindOfClass:[UIImage class]] && ((UIImage *)icon).size.width > 0.0)
                return lgPageLabelsCopyImage((UIImage *)icon);
        }
    }
    return nil;
}

static UIImage *lgPageLabelsRasterizeCellLeadingStrip(UITableViewCell *cell) {
    UIView *contentView = cell.contentView;
    if (!contentView || contentView.bounds.size.width < 40.0) return nil;
    CGFloat stripWidth = MIN(70.0, CGRectGetWidth(contentView.bounds) * 0.35);
    CGFloat side = MIN(kLGPageLabelsIconSize, CGRectGetHeight(contentView.bounds));
    if (side < 18.0) return nil;
    CGFloat y = (CGRectGetHeight(contentView.bounds) - side) * 0.5;
    CGRect cropRect = CGRectMake(0, y, stripWidth, side);
    UIGraphicsBeginImageContextWithOptions(cropRect.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    CGContextTranslateCTM(ctx, -cropRect.origin.x, -cropRect.origin.y);
    [contentView.layer renderInContext:ctx];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (lgPageLabelsImageHasVisiblePixels(snapshot))
        return lgPageLabelsCopyImage(snapshot);
    return snapshot ? lgPageLabelsCopyImage(snapshot) : lgPageLabelsRasterizeLeadingIconFromContentView(contentView);
}

static UIImage *lgPageLabelsExtractIconAggressive(UITableViewCell *cell, PSSpecifier *specifier, id controller,
    NSIndexPath *indexPath) {
    UIImage *icon = lgPageLabelsCachedIconForController(controller, indexPath, specifier);
    if (icon) return lgPageLabelsCopyImage(icon);

    icon = lgPageLabelsExtractIconViaPSTableCellAPI(cell);
    if (icon) return icon;

    if (cell) {
        icon = lgPageLabelsExtractIconFromViewTree(cell.contentView, YES);
        if (icon) return icon;
        icon = lgPageLabelsRasterizeCellLeadingStrip(cell);
        if (icon) return icon;
        icon = lgPageLabelsRasterizeView(cell.contentView);
        if (icon && lgPageLabelsImageHasVisiblePixels(icon)) return icon;
    }

    icon = lgPageLabelsExtractIconViaListController(controller, specifier, cell);
    if (icon) return icon;

    icon = lgPageLabelsExtractIconFromSpecifier(specifier, controller);
    if (icon) return icon;

    icon = lgPageLabelsExtractLazyAppIcon(specifier);
    if (icon) return icon;

    if (cell) {
        icon = lgPageLabelsExtractIconFromViewTree((UIView *)cell, YES);
        if (icon) return icon;
        icon = lgPageLabelsExtractIconFromCellSnapshot(cell);
        if (icon) return icon;
    }
    return nil;
}

static UIImage *lgPageLabelsCropRectFromImage(UIImage *image, CGRect rect) {
    if (!image || !image.CGImage) return nil;
    CGFloat scale = image.scale > 0.0 ? image.scale : 1.0;
    CGRect scaled = CGRectMake(rect.origin.x * scale, rect.origin.y * scale,
        rect.size.width * scale, rect.size.height * scale);
    CGImageRef cropped = CGImageCreateWithImageInRect(image.CGImage, scaled);
    if (!cropped) return nil;
    UIImage *result = [UIImage imageWithCGImage:cropped scale:scale orientation:image.imageOrientation];
    CGImageRelease(cropped);
    return lgPageLabelsCopyImage(result);
}

static UIImage *lgPageLabelsExtractIconFromCellSnapshot(UITableViewCell *cell) {
    if (!cell || cell.bounds.size.width < 20.0 || cell.bounds.size.height < 20.0) return nil;
    UIImage *full = lgPageLabelsRasterizeView(cell);
    if (!full) return nil;

    CGFloat h = CGRectGetHeight(cell.bounds);
    CGFloat w = CGRectGetWidth(cell.bounds);
    CGFloat side = MIN(kLGPageLabelsIconSize, h - 4.0);
    if (side < 18.0) return nil;
    CGFloat y = (h - side) * 0.5;
    NSArray<NSNumber *> *xStarts = @[@16, @15, @59, @20, @11, @((w - side) * 0.5)];

    for (NSNumber *xValue in xStarts) {
        CGFloat x = xValue.floatValue;
        if (x + side > w) continue;
        UIImage *crop = lgPageLabelsCropRectFromImage(full, CGRectMake(x, y, side, side));
        if (lgPageLabelsImageHasVisiblePixels(crop)) return crop;
    }
    return lgPageLabelsCropRectFromImage(full, CGRectMake(16, y, side, side));
}

static UITableView *lgPageLabelsFindTableViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *found = lgPageLabelsFindTableViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static UITableViewCell *lgPageLabelsFindSelectedCellInTableView(UITableView *tableView) {
    if (!tableView) return nil;
    NSIndexPath *indexPath = [tableView indexPathForSelectedRow];
    if (indexPath) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if (cell) return cell;
    }
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell.selected || cell.highlighted) return cell;
    }
    return nil;
}

static NSString *lgPageLabelsTitleTextForCell(UITableViewCell *cell) {
    if (!cell) return nil;
    id titleLabel = nil;
    if ([cell respondsToSelector:@selector(titleLabel)])
        titleLabel = [cell performSelector:@selector(titleLabel)];
    if ([titleLabel isKindOfClass:[UILabel class]] && [(UILabel *)titleLabel text].length)
        return [(UILabel *)titleLabel text];
    if (cell.textLabel.text.length) return cell.textLabel.text;
    return nil;
}

static void lgPageLabelsStoreCapturedIconOnSource(id source, PSSpecifier *specifier, UIImage *icon) {
    if (!icon) return;
    UIImage *copy = lgPageLabelsCopyImage(icon);
    if (!copy) return;
    if (source)
        objc_setAssociatedObject(source, kLGPageLabelsLastCapturedIconKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gLGPageLabelsLastNavigationIcon = copy;
    lgPageLabelsSetPendingIcon(copy);
    if (specifier) {
        id label = [specifier propertyForKey:@"label"];
        if ([label isKindOfClass:[NSString class]])
            lgPageLabelsRememberIconForTitle((NSString *)label, copy);
    }
}

static BOOL lgPageLabelsShouldCaptureIcons(void) {
    return LGPageLabelsFeatureEnabled();
}

static UIImage *lgPageLabelsCaptureIconFromViewController(id source) {
    if (!source || !lgPageLabelsShouldCaptureIcons()) return nil;

    id cached = objc_getAssociatedObject(source, kLGPageLabelsLastCapturedIconKey);
    if ([cached isKindOfClass:[UIImage class]]) return lgPageLabelsCopyImage((UIImage *)cached);

    UITableView *tableView = lgPageLabelsTableViewForController(source);
    if (!tableView && [source respondsToSelector:@selector(view)])
        tableView = lgPageLabelsFindTableViewInView([(id)source view]);

    id listController = tableView ? lgPageLabelsListControllerForTableView(tableView) : nil;
    if (!listController) listController = source;

    NSIndexPath *indexPath = nil;
    if (tableView) {
        indexPath = [tableView indexPathForSelectedRow];
        if (!indexPath) {
            id stored = objc_getAssociatedObject(listController, kLGPageLabelsLastSelectedIndexPathKey);
            if ([stored isKindOfClass:[NSIndexPath class]]) indexPath = (NSIndexPath *)stored;
        }
    }

    UITableViewCell *cell = lgPageLabelsFindSelectedCellInTableView(tableView);
    if (!cell && indexPath && tableView)
        cell = [tableView cellForRowAtIndexPath:indexPath];

    PSSpecifier *specifier = nil;
    Class listClass = NSClassFromString(@"PSListController");
    if (listClass && [listController isKindOfClass:listClass] && indexPath
        && [listController respondsToSelector:@selector(specifierAtIndexPath:)]) {
        specifier = [(PSListController *)listController specifierAtIndexPath:indexPath];
    }
    if (!specifier) {
        id storedSpec = objc_getAssociatedObject(listController, kLGPageLabelsLastCapturedSpecifierKey);
        Class specClass = objc_getClass("PSSpecifier");
        if (specClass && [storedSpec isKindOfClass:specClass])
            specifier = (PSSpecifier *)storedSpec;
    }

    UIImage *icon = lgPageLabelsExtractIconAggressive(cell, specifier, listController, indexPath);
    if (!icon && cell)
        icon = lgPageLabelsExtractIconFromCellSnapshot(cell);

    if (icon) {
        lgPageLabelsRememberCapturedIcon(listController, specifier, icon);
        lgPageLabelsStoreCapturedIconOnSource(source, specifier, icon);
        if (listController != source)
            lgPageLabelsStoreCapturedIconOnSource(listController, specifier, icon);
        NSString *rowTitle = lgPageLabelsTitleTextForCell(cell);
        if (rowTitle.length)
            lgPageLabelsRememberIconForTitle(rowTitle, icon);
    }
    return icon;
}

static void lgPageLabelsHandleNavigationFromSourceToDestination(id source, id destination) {
    if (!lgPageLabelsShouldCaptureIcons() || !destination) return;
    if (lgSettingsIsWiFiSettingsController(destination)) {
        if (source)
            lgPageLabelsClearWiFiPaneCustomizations(source);
        lgPageLabelsClearWiFiPaneCustomizations(destination);
        return;
    }

    if (lgPageLabelsControllerSupportsPageHeader(destination)) {
        lgPageLabelsCaptureIconFromViewController(source);
        lgPageLabelsResolveIconAfterPushFromSource(source, destination);

        if (!lgPageLabelsIconForController(destination)) {
            NSString *destTitle = lgPageLabelsPageTitleForController(destination);
            UIImage *titleIcon = lgPageLabelsIconForTitle(destTitle);
            if (titleIcon)
                lgPageLabelsStoreIconForController(destination, titleIcon);
        }
        return;
    }

    if (lgPageLabelsControllerSupportsPageHeader(source))
        lgPageLabelsCaptureIconFromViewController(source);
}

static UIImage *lgPageLabelsImageNamed(NSString *name, NSBundle *bundle) {
    if (!name.length) return nil;
    if (bundle) {
        UIImage *bundled = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
        if (bundled) return lgPageLabelsCopyImage(bundled);
        NSString *path = [bundle pathForResource:name ofType:@"png"];
        if (!path) path = [bundle pathForResource:name ofType:@"pdf"];
        if (path) {
            UIImage *fileImage = [UIImage imageWithContentsOfFile:path];
            if (fileImage) return lgPageLabelsCopyImage(fileImage);
        }
    }
    UIImage *named = [UIImage imageNamed:name];
    return named ? lgPageLabelsCopyImage(named) : nil;
}

static UIImage *lgPageLabelsExtractIconFromSpecifier(PSSpecifier *specifier, id controller) {
    if (!specifier) return nil;

    for (NSString *key in @[
        @"iconImage", @"icon", @"lazy-icon", @"icon-name", @"largeIcon", @"image",
        @"staticIcon", @"pref:image", @"PSIconImageKey"
    ]) {
        id value = [specifier propertyForKey:key];
        if ([value isKindOfClass:[UIImage class]] && ((UIImage *)value).size.width > 0.0)
            return lgPageLabelsCopyImage((UIImage *)value);
        if ([value isKindOfClass:[NSString class]]) {
            UIImage *named = lgPageLabelsImageNamed((NSString *)value, lgSettings26BundleForController(controller));
            if (named) return named;
        }
    }

    NSBundle *bundle = lgSettings26BundleForController(controller);
    if (bundle) {
        for (NSString *name in @[@"icon", @"Icon", @"icon@2x", @"icon@3x"]) {
            UIImage *named = lgPageLabelsImageNamed(name, bundle);
            if (named) return named;
        }
    }

    for (NSString *selName in @[@"getLazyIcon", @"iconImage", @"_iconImage"]) {
        id lazyIcon = lgPageLabelsSend0((id)specifier, NSSelectorFromString(selName));
        if ([lazyIcon isKindOfClass:[UIImage class]] && ((UIImage *)lazyIcon).size.width > 0.0)
            return lgPageLabelsCopyImage((UIImage *)lazyIcon);
    }
    return nil;
}

static UIImage *lgPageLabelsRasterizeLeadingIconFromContentView(UIView *contentView) {
    if (!contentView || contentView.bounds.size.width < 40.0 || contentView.bounds.size.height < 20.0)
        return nil;

    CGFloat side = MIN(kLGPageLabelsIconSize, CGRectGetHeight(contentView.bounds));
    if (side < 20.0) return nil;
    CGFloat y = (CGRectGetHeight(contentView.bounds) - side) * 0.5;
    NSArray<NSNumber *> *xOffsets = @[@16, @15, @20, @59, @11];

    for (NSNumber *xValue in xOffsets) {
        CGFloat x = xValue.floatValue;
        if (x + side > CGRectGetWidth(contentView.bounds)) continue;
        CGRect cropRect = CGRectMake(x, y, side, side);
        UIGraphicsBeginImageContextWithOptions(cropRect.size, NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (!ctx) {
            UIGraphicsEndImageContext();
            continue;
        }
        CGContextTranslateCTM(ctx, -cropRect.origin.x, -cropRect.origin.y);
        BOOL drew = [contentView drawViewHierarchyInRect:contentView.bounds afterScreenUpdates:YES];
        if (!drew)
            [contentView.layer renderInContext:ctx];
        UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (lgPageLabelsImageHasVisiblePixels(snapshot))
            return lgPageLabelsCopyImage(snapshot);
    }
    return nil;
}

static void lgPageLabelsRememberCapturedIcon(id sourceController, PSSpecifier *specifier, UIImage *icon) {
    lgPageLabelsSetPendingIcon(icon);
    if (icon) {
        gLGPageLabelsLastNavigationIcon = lgPageLabelsCopyImage(icon);
        if (specifier) {
            id label = [specifier propertyForKey:@"label"];
            if ([label isKindOfClass:[NSString class]])
                lgPageLabelsRememberIconForTitle((NSString *)label, icon);
        }
    }
    if (icon && sourceController) {
        objc_setAssociatedObject(sourceController, kLGPageLabelsLastCapturedIconKey,
            lgPageLabelsCopyImage(icon), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (specifier)
            objc_setAssociatedObject(sourceController, kLGPageLabelsLastCapturedSpecifierKey, specifier,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (sourceController) {
        objc_setAssociatedObject(sourceController, kLGPageLabelsLastCapturedIconKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(sourceController, kLGPageLabelsLastCapturedSpecifierKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void lgPageLabelsSetPendingIcon(UIImage *icon) {
    gLGPageLabelsPendingIcon = lgPageLabelsCopyImage(icon);
}

static UIImage *lgPageLabelsIconForController(id controller) {
    id host = lgPageLabelsHeaderHostController(controller);
    id icon = objc_getAssociatedObject(host, kLGPageLabelsIconKey);
    if ([icon isKindOfClass:[UIImage class]]) return (UIImage *)icon;
    if (host != controller) {
        icon = objc_getAssociatedObject(controller, kLGPageLabelsIconKey);
        if ([icon isKindOfClass:[UIImage class]]) return (UIImage *)icon;
    }
    return nil;
}

static void lgPageLabelsCaptureNavigationFromSource(id source, UITableView *tableView, NSIndexPath *indexPath,
    PSSpecifier *specifier) {
    if (!lgPageLabelsShouldCaptureIcons()) return;

    if (indexPath) {
        objc_setAssociatedObject(source, kLGPageLabelsLastSelectedIndexPathKey, indexPath,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (tableView) {
        indexPath = [tableView indexPathForSelectedRow];
    }

    UITableViewCell *cell = nil;
    if (indexPath && tableView) {
        cell = [tableView cellForRowAtIndexPath:indexPath];
        if (!cell) {
            for (UITableViewCell *visible in tableView.visibleCells) {
                NSIndexPath *visiblePath = [tableView indexPathForCell:visible];
                if (visiblePath && [visiblePath isEqual:indexPath]) {
                    cell = visible;
                    break;
                }
            }
        }
    }

    if (!specifier && indexPath && [source respondsToSelector:@selector(specifierAtIndexPath:)]) {
        specifier = [(PSListController *)source specifierAtIndexPath:indexPath];
    }
    lgPageLabelsCaptureIconFromCell(cell, source, specifier);
}

static void lgPageLabelsCaptureIconFromCell(UITableViewCell *cell, id sourceController, PSSpecifier *specifier) {
    NSIndexPath *indexPath = nil;
    if (sourceController) {
        id stored = objc_getAssociatedObject(sourceController, kLGPageLabelsLastSelectedIndexPathKey);
        if ([stored isKindOfClass:[NSIndexPath class]])
            indexPath = (NSIndexPath *)stored;
    }
    if (!indexPath && cell) {
        UITableView *tableView = lgSettings26OwningTableViewForView(cell);
        if (tableView)
            indexPath = [tableView indexPathForCell:cell];
    }

    UIImage *icon = lgPageLabelsExtractIconAggressive(cell, specifier, sourceController, indexPath);
    lgPageLabelsRememberCapturedIcon(sourceController, specifier, icon);
    if (icon && sourceController)
        lgPageLabelsCacheIconForController(sourceController, indexPath, specifier, icon);
}

static UIImage *lgPageLabelsExtractIconForNavigationFromSource(id source, NSIndexPath *indexPath) {
    if (!source) return nil;

    PSSpecifier *specifier = nil;
    if (indexPath && [source respondsToSelector:@selector(specifierAtIndexPath:)])
        specifier = [(PSListController *)source specifierAtIndexPath:indexPath];
    if (!specifier) {
        id storedSpec = objc_getAssociatedObject(source, kLGPageLabelsLastCapturedSpecifierKey);
        Class specClass = objc_getClass("PSSpecifier");
        if (specClass && [storedSpec isKindOfClass:specClass])
            specifier = (PSSpecifier *)storedSpec;
    }

    UITableView *tableView = lgPageLabelsTableViewForController(source);
    UITableViewCell *cell = (tableView && indexPath) ? [tableView cellForRowAtIndexPath:indexPath] : nil;
    return lgPageLabelsExtractIconAggressive(cell, specifier, source, indexPath);
}

static UIImage *lgPageLabelsExtractIconFromSourceListController(id source) {
    if (!source) return nil;

    id cached = objc_getAssociatedObject(source, kLGPageLabelsLastCapturedIconKey);
    if ([cached isKindOfClass:[UIImage class]])
        return lgPageLabelsCopyImage((UIImage *)cached);

    NSIndexPath *indexPath = nil;
    UITableView *tableView = lgPageLabelsTableViewForController(source);
    if (tableView)
        indexPath = [tableView indexPathForSelectedRow];
    if (!indexPath) {
        id stored = objc_getAssociatedObject(source, kLGPageLabelsLastSelectedIndexPathKey);
        if ([stored isKindOfClass:[NSIndexPath class]])
            indexPath = (NSIndexPath *)stored;
    }
    if (indexPath)
        return lgPageLabelsExtractIconForNavigationFromSource(source, indexPath);

    id storedSpec = objc_getAssociatedObject(source, kLGPageLabelsLastCapturedSpecifierKey);
    Class specClass = objc_getClass("PSSpecifier");
    if (specClass && [storedSpec isKindOfClass:specClass])
        return lgPageLabelsExtractIconAggressive(nil, (PSSpecifier *)storedSpec, source, nil);
    return nil;
}

static void lgPageLabelsStoreIconForController(id controller, UIImage *icon) {
    if (!controller || !icon) return;
    id host = lgPageLabelsHeaderHostController(controller);
    UIImage *copy = lgPageLabelsCopyImage(icon);
    objc_setAssociatedObject(host, kLGPageLabelsIconKey, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (host != controller)
        objc_setAssociatedObject(controller, kLGPageLabelsIconKey, lgPageLabelsCopyImage(icon),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id lgPageLabelsPageContentController(id controller) {
    id host = lgPageLabelsHeaderHostController(controller);
    return host ?: controller;
}

static UIImage *lgPageLabelsResolveAnyIconFromSource(id source) {
    if (!source) return nil;

    id cached = objc_getAssociatedObject(source, kLGPageLabelsLastCapturedIconKey);
    if ([cached isKindOfClass:[UIImage class]])
        return lgPageLabelsCopyImage((UIImage *)cached);

    UIImage *icon = gLGPageLabelsPendingIcon ?: gLGPageLabelsLastNavigationIcon;
    if (icon) return lgPageLabelsCopyImage(icon);

    icon = lgPageLabelsCaptureFromPendingPushSpec(source);
    if (icon) return icon;

    return lgPageLabelsExtractIconFromSourceListController(source);
}

static void lgPageLabelsResolveIconAfterPushFromSource(id source, id destination) {
    if (!lgPageLabelsDestinationAcceptsIcon(destination)) return;

    NSString *destTitle = lgPageLabelsPageTitleForController(destination);
    UIImage *icon = lgPageLabelsIconForTitle(destTitle);
    if (!icon)
        icon = gLGPageLabelsLastNavigationIcon ?: gLGPageLabelsPendingIcon;
    if (!icon)
        icon = lgPageLabelsResolveAnyIconFromSource(source);
    if (!icon) {
        PSSpecifier *spec = objc_getAssociatedObject(source, kLGPageLabelsLastCapturedSpecifierKey);
        icon = lgPageLabelsExtractIconAggressive(nil, spec, source, nil);
    }
    if (!icon && destTitle.length)
        icon = lgPageLabelsIconForTitle(destTitle);
    if (!icon) return;

    lgPageLabelsStoreIconForController(destination, icon);
    gLGPageLabelsPendingIcon = nil;
}

static BOOL lgPageLabelsDestinationAcceptsIcon(id destination) {
    if (!destination || !LGPageLabelsFeatureEnabled()) return NO;
    return lgSettingsShouldModifyController(destination);
}

static CGFloat lgPageLabelsResolvedCardHeight(id controller, CGFloat cardWidth);
static BOOL lgPageLabelsIsActiveForController(id controller) {
    return LGPageLabelsFeatureEnabled() && lgSettingsShouldModifyController(controller);
}

static UITableView *lgPageLabelsTableViewForController(id controller) {
    if (!controller) return nil;
    if ([controller respondsToSelector:@selector(table)]) {
        UITableView *tableView = [(PSListController *)controller table];
        if (tableView) return tableView;
    }
    return nil;
}

static id lgPageLabelsHeaderHostController(id controller) {
    return controller;
}

static CGFloat lgPageLabelsHorizontalInsetForTableView(UITableView *tableView) {
    if (!tableView) return kLGPageLabelsHorizontalInset;
    CGFloat left = tableView.layoutMargins.left;
    if (left >= 8.0 && left <= 40.0) return left;
    if (@available(iOS 11.0, *)) {
        CGFloat leading = tableView.directionalLayoutMargins.leading;
        if (leading >= 8.0 && leading <= 40.0) return leading;
    }
    return kLGPageLabelsHorizontalInset;
}

static UIView *lgPageLabelsCardViewInContainer(UIView *container) {
    return container ? [container viewWithTag:kLGPageLabelsCardViewTag] : nil;
}

static BOOL lgPageLabelsSpecifierNavigatesToDetail(PSSpecifier *specifier) {
    if (!specifier) return NO;
    if ([specifier respondsToSelector:@selector(detailControllerClass)]) {
        Class detailClass = [specifier detailControllerClass];
        if (detailClass) return YES;
    }
    for (NSString *key in @[@"detail", @"bundle", @"bundleController", @"lazy-bundle", @"pane", @"navigate"]) {
        if ([specifier propertyForKey:key]) return YES;
    }
    id cellType = [specifier propertyForKey:@"cell"];
    if ([cellType isKindOfClass:[NSString class]]) {
        NSString *cell = (NSString *)cellType;
        if ([cell isEqualToString:@"PSLinkCell"] || [cell isEqualToString:@"PSLinkListCell"])
            return YES;
    }
    return NO;
}

static BOOL lgPageLabelsShouldCaptureIconForSpecifier(PSSpecifier *specifier) {
    if (!specifier || lgPageLabelsIsPageLabelSpecifier(specifier)) return NO;
    if (lgPageLabelsSpecifierNavigatesToDetail(specifier)) return YES;
    id cellType = [specifier propertyForKey:@"cell"];
    if ([cellType isKindOfClass:[NSString class]]) {
        NSString *cell = (NSString *)cellType;
        if ([cell containsString:@"Group"]) return NO;
        if ([cell containsString:@"Link"] || [cell containsString:@"List"] || [cell containsString:@"Item"]
            || [cell containsString:@"Giant"])
            return YES;
    }
    if ([specifier propertyForKey:@"icon"] || [specifier propertyForKey:@"iconImage"]
        || [specifier propertyForKey:@"hasIcon"] || [specifier propertyForKey:@"appIDForLazyIcon"])
        return YES;
    return NO;
}

static UIColor *lgPageLabelsTitleTextColor(UIView *view) {
    UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
    if (@available(iOS 12.0, *)) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor whiteColor] : [UIColor blackColor];
    }
    return [UIColor blackColor];
}

static UILabel *lgPageLabelsEnsureTitleLabelInCard(UIView *card) {
    if (!card) return nil;
    UILabel *label = [card viewWithTag:kLGPageLabelsTitleViewTag];
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = kLGPageLabelsTitleViewTag;
        label.numberOfLines = 1;
        label.textAlignment = NSTextAlignmentLeft;
        label.autoresizingMask = UIViewAutoresizingNone;
        label.backgroundColor = [UIColor clearColor];
        [card addSubview:label];
    }
    return label;
}

static UIImageView *lgPageLabelsEnsureIconViewInCard(UIView *card, UIImage *icon) {
    if (!card) return nil;
    UIImageView *iconView = [card viewWithTag:kLGPageLabelsIconViewTag];
    if (!icon) {
        if (iconView) [iconView removeFromSuperview];
        return nil;
    }
    if (!iconView) {
        iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        iconView.tag = kLGPageLabelsIconViewTag;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.clipsToBounds = YES;
        iconView.backgroundColor = [UIColor clearColor];
        [card addSubview:iconView];
    }
    iconView.image = icon.renderingMode == UIImageRenderingModeAlwaysTemplate
        ? icon : [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    iconView.tintColor = [UIColor labelColor];
    iconView.alpha = 1.0;
    iconView.hidden = NO;
    return iconView;
}

static void lgPageLabelsRemoveLegacyCellFromCard(UIView *card) {
    if (!card) return;
    Class cellClass = NSClassFromString(@"PSTableCell");
    if (!cellClass) return;
    for (UIView *subview in [card.subviews copy]) {
        if ([subview isKindOfClass:cellClass])
            [subview removeFromSuperview];
    }
}

static UIFont *lgPageLabelsTitleFont(void) {
    return [UIFont systemFontOfSize:kLGPageLabelsTitleFontSize weight:UIFontWeightBold];
}

static UIFont *lgPageLabelsSubtitleFont(void) {
    return [UIFont systemFontOfSize:kLGPageLabelsSubtitleFontSize weight:UIFontWeightRegular];
}

static CGFloat lgPageLabelsTitleLineHeightValue(void) {
    return ceil([lgPageLabelsTitleFont() lineHeight]);
}

static CGFloat lgPageLabelsMeasuredSubtitleHeight(NSString *text, CGFloat textWidth) {
    if (textWidth <= 0.0 || !text.length) return 0.0;
    CGRect rect = [text boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
        options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
        attributes:@{NSFontAttributeName: lgPageLabelsSubtitleFont()}
        context:nil];
    return ceil(CGRectGetHeight(rect));
}

static CGFloat lgPageLabelsTextWidthForCard(CGFloat cardWidth) {
    return MAX(cardWidth - (2.0 * kLGPageLabelsCellHorizontalInset), 0.0);
}

static CGFloat lgPageLabelsResolvedCardHeight(id controller, CGFloat cardWidth) {
    NSString *description = lgPageLabelsDescriptionForController(controller);
    if (!description.length) return 0.0;
    CGFloat textWidth = lgPageLabelsTextWidthForCard(cardWidth);
    CGFloat textBlockHeight = lgPageLabelsTitleLineHeightValue()
        + kLGPageLabelsTitleSubtitleGap + lgPageLabelsMeasuredSubtitleHeight(description, textWidth);
    CGFloat contentHeight = textBlockHeight;
    if (lgPageLabelsIconForController(controller))
        contentHeight += kLGPageLabelsIconSize + kLGPageLabelsIconLabelGap;
    CGFloat height = kLGPageLabelsCellVerticalInset + contentHeight + kLGPageLabelsCellVerticalInset;
    return MAX(height, lgPageLabelsCellHeight());
}

static UILabel *lgPageLabelsEnsureSubtitleLabelInCard(UIView *card) {
    if (!card) return nil;
    UILabel *label = [card viewWithTag:kLGPageLabelsSubtitleViewTag];
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = kLGPageLabelsSubtitleViewTag;
        label.numberOfLines = 0;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.textAlignment = NSTextAlignmentLeft;
        label.autoresizingMask = UIViewAutoresizingNone;
        label.backgroundColor = [UIColor clearColor];
        [card addSubview:label];
    }
    return label;
}

static void lgPageLabelsConfigureCard(UIView *card, id controller) {
    if (!card) return;
    UILabel *titleLabel = lgPageLabelsEnsureTitleLabelInCard(card);
    UILabel *subtitleLabel = lgPageLabelsEnsureSubtitleLabelInCard(card);
    if (!titleLabel || !subtitleLabel) return;

    NSString *pageTitle = lgPageLabelsPageTitleForController(controller);
    titleLabel.text = pageTitle.length ? pageTitle : @" ";
    titleLabel.font = lgPageLabelsTitleFont();
    titleLabel.textAlignment = NSTextAlignmentLeft;
    titleLabel.textColor = lgPageLabelsTitleTextColor(card);

    NSString *description = lgPageLabelsDescriptionForController(controller);
    subtitleLabel.text = description.length ? description : @" ";
    subtitleLabel.font = lgPageLabelsSubtitleFont();
    subtitleLabel.textAlignment = NSTextAlignmentLeft;
    subtitleLabel.textColor = [lgPageLabelsTitleTextColor(card) colorWithAlphaComponent:kLGPageLabelsSubtitleTextAlpha];
}

static void lgPageLabelsLayoutCardSubviews(UIView *card, id controller) {
    if (!card) return;
    lgPageLabelsRemoveLegacyCellFromCard(card);
    CGFloat cardWidth = CGRectGetWidth(card.bounds);
    if (cardWidth <= 0.0) return;

    UIImage *icon = lgPageLabelsIconForController(controller);
    UIImageView *iconView = lgPageLabelsEnsureIconViewInCard(card, icon);
    UILabel *titleLabel = lgPageLabelsEnsureTitleLabelInCard(card);
    UILabel *subtitleLabel = lgPageLabelsEnsureSubtitleLabelInCard(card);

    CGFloat y = kLGPageLabelsCellVerticalInset;
    CGFloat textX = kLGPageLabelsCellHorizontalInset;
    CGFloat textWidth = lgPageLabelsTextWidthForCard(cardWidth);

    if (icon && iconView) {
        iconView.frame = CGRectMake(kLGPageLabelsCellHorizontalInset, y,
            kLGPageLabelsIconSize, kLGPageLabelsIconSize);
        y += kLGPageLabelsIconSize + kLGPageLabelsIconLabelGap;
    } else if (iconView) {
        [iconView removeFromSuperview];
    }

    CGFloat titleH = lgPageLabelsTitleLineHeightValue();
    titleLabel.frame = CGRectMake(textX, y, textWidth, titleH);
    y += titleH + kLGPageLabelsTitleSubtitleGap;

    NSString *description = lgPageLabelsDescriptionForController(controller);
    CGFloat subtitleH = lgPageLabelsMeasuredSubtitleHeight(description, textWidth);
    subtitleLabel.frame = CGRectMake(textX, y, textWidth, subtitleH);
    [card bringSubviewToFront:subtitleLabel];
    [card bringSubviewToFront:titleLabel];
    if (iconView) [card bringSubviewToFront:iconView];
}

static void lgPageLabelsUpdateCardStyle(UIView *card) {
    if (!card) return;
    card.clipsToBounds = YES;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    if (LGSettings26FeatureEnabled()) {
        card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        card.layer.cornerRadius = kLGSettings26CornerRadius;
    } else {
        card.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
        card.layer.cornerRadius = 10.0;
    }
}

static void lgPageLabelsLayoutHeaderContainer(UIView *container, UITableView *tableView, id controller) {
    if (!container || !tableView) return;
    if (lgSettingsIsWiFiSettingsController(controller)) {
        lgPageLabelsClearWiFiPaneCustomizations(controller);
        return;
    }
    id pageController = lgPageLabelsPageContentController(controller);
    if (!lgPageLabelsShouldShowPageHeader(pageController)) {
        lgPageLabelsRemoveTableHeader(controller);
        return;
    }

    id host = lgPageLabelsHeaderHostController(controller);
    if (objc_getAssociatedObject(host, kLGPageLabelsLayoutInProgressKey)) return;
    objc_setAssociatedObject(host, kLGPageLabelsLayoutInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        CGFloat width = CGRectGetWidth(tableView.bounds);
        if (width <= 0.0) width = CGRectGetWidth([UIScreen mainScreen].bounds);
        CGFloat inset = lgPageLabelsHorizontalInsetForTableView(tableView);
        CGFloat cardWidth = width - (2.0 * inset);
        CGFloat cardHeight = lgPageLabelsResolvedCardHeight(pageController, cardWidth);
        CGFloat height = kLGPageLabelsHeaderTopGap + cardHeight + kLGPageLabelsHeaderBottomGap;

        CGRect previousFrame = container.frame;
        container.frame = CGRectMake(0, 0, width, height);

        UIView *staleIcon = [container viewWithTag:kLGPageLabelsIconViewTag];
        if (staleIcon) [staleIcon removeFromSuperview];

        UIView *card = lgPageLabelsCardViewInContainer(container);
        if (card) {
            card.frame = CGRectMake(inset, kLGPageLabelsHeaderTopGap, cardWidth, cardHeight);
            lgPageLabelsUpdateCardStyle(card);
            lgPageLabelsConfigureCard(card, pageController);
            lgPageLabelsLayoutCardSubviews(card, pageController);
        }

        BOOL headerAlreadyAssigned = (tableView.tableHeaderView == container);
        BOOL frameChanged = fabs(CGRectGetWidth(previousFrame) - width) >= 0.5
            || fabs(CGRectGetHeight(previousFrame) - height) >= 0.5;
        if (!headerAlreadyAssigned || frameChanged)
            tableView.tableHeaderView = container;
    } @finally {
        objc_setAssociatedObject(host, kLGPageLabelsLayoutInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL lgPageLabelsIsPageLabelSpecifier(PSSpecifier *specifier) {
    if (!specifier) return NO;
    id specID = [specifier propertyForKey:@"id"];
    return [specID isKindOfClass:[NSString class]] && [specID isEqualToString:kLGPageLabelsMarkerID];
}

static id lgPageLabelsListControllerForCellView(UIView *cellView) {
    if (!cellView) return nil;
    return lgPageLabelsListControllerForTableView(lgSettings26OwningTableViewForView(cellView));
}

static BOOL lgPageLabelsShouldBlockPageLabelCell(UIView *cellView) {
    if (!cellView || !lgPageLabelsIsPageLabelSpecifier([cellView valueForKey:@"specifier"])) return NO;
    return lgSettingsIsWiFiSettingsController(lgPageLabelsListControllerForCellView(cellView));
}

static NSString *lgPageLabelsPageTitleForController(id controller) {
    if (!controller) return @"";
    if ([controller respondsToSelector:@selector(navigationItem)]) {
        NSString *navTitle = [[controller navigationItem] title];
        if (navTitle.length) return navTitle;
    }
    if ([controller respondsToSelector:@selector(title)]) {
        NSString *title = [controller title];
        if (title.length) return title;
    }
    if ([controller respondsToSelector:@selector(parentViewController)]) {
        UIViewController *parent = [(id)controller parentViewController];
        if (parent && parent != controller) {
            NSString *parentTitle = lgPageLabelsPageTitleForController(parent);
            if (parentTitle.length) return parentTitle;
        }
    }
    return @"";
}

static void lgPageLabelsRemoveTableHeader(id controller) {
    id host = lgPageLabelsHeaderHostController(controller);
    UITableView *tableView = lgPageLabelsTableViewForController(host);
    if (tableView) tableView.tableHeaderView = nil;
    objc_setAssociatedObject(host, kLGPageLabelsHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void lgPageLabelsClearWiFiPaneCustomizations(id controller) {
    lgPageLabelsRemoveTableHeader(controller);
}

static void lgPageLabelsInstallTableHeader(id controller) {
    if (lgSettingsIsWiFiSettingsController(controller)) {
        lgPageLabelsClearWiFiPaneCustomizations(controller);
        return;
    }
    id host = lgPageLabelsHeaderHostController(controller);
    id pageController = lgPageLabelsPageContentController(controller);
    if (!lgPageLabelsShouldShowPageHeader(pageController)) {
        lgPageLabelsRemoveTableHeader(controller);
        return;
    }

    UITableView *tableView = lgPageLabelsTableViewForController(host);
    if (!tableView) return;

    UIView *existing = objc_getAssociatedObject(host, kLGPageLabelsHeaderViewKey);
    if (existing) {
        lgPageLabelsLayoutHeaderContainer(existing, tableView, pageController);
        return;
    }

    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (width <= 0.0) width = CGRectGetWidth([UIScreen mainScreen].bounds);
    CGFloat inset = lgPageLabelsHorizontalInsetForTableView(tableView);
    CGFloat cardWidth = width - (2.0 * inset);
    CGFloat cardHeight = lgPageLabelsResolvedCardHeight(pageController, cardWidth);
    CGFloat height = kLGPageLabelsHeaderTopGap + cardHeight + kLGPageLabelsHeaderBottomGap;

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    container.backgroundColor = [UIColor clearColor];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(inset, kLGPageLabelsHeaderTopGap, cardWidth, cardHeight)];
    card.tag = kLGPageLabelsCardViewTag;
    lgPageLabelsUpdateCardStyle(card);
    [container addSubview:card];

    lgPageLabelsConfigureCard(card, pageController);
    lgPageLabelsLayoutCardSubviews(card, pageController);
    lgPageLabelsLayoutHeaderContainer(container, tableView, pageController);
    objc_setAssociatedObject(host, kLGPageLabelsHeaderViewKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void lgPageLabelsHandleHostedViewWillAppear(id controller) {
    if (lgSettingsIsWiFiSettingsController(controller)) {
        lgPageLabelsClearWiFiPaneCustomizations(controller);
        return;
    }
    if (!lgPageLabelsIsActiveForController(controller)) {
        lgPageLabelsRemoveTableHeader(controller);
        return;
    }
    if (!lgPageLabelsIconForController(controller)) {
        UIImage *titleIcon = lgPageLabelsIconForTitle(lgPageLabelsPageTitleForController(controller));
        if (titleIcon)
            lgPageLabelsStoreIconForController(controller, titleIcon);
    }
    if (!lgPageLabelsIconForController(controller)) {
        UINavigationController *nav = [(id)controller navigationController];
        if ([nav isKindOfClass:[UINavigationController class]] && nav.viewControllers.count >= 2) {
            id previous = nav.viewControllers[nav.viewControllers.count - 2];
            lgPageLabelsHandleNavigationFromSourceToDestination(previous, controller);
        }
    }
    lgPageLabelsInstallTableHeader(controller);
}

static void lgPageLabelsHandleHostedViewWillLayoutSubviews(id controller) {
    if (lgSettingsIsWiFiSettingsController(controller)) {
        lgPageLabelsClearWiFiPaneCustomizations(controller);
        return;
    }
    if (!lgPageLabelsIsActiveForController(controller)) return;
    id host = lgPageLabelsHeaderHostController(controller);
    id pageController = lgPageLabelsPageContentController(controller);
    if (!lgPageLabelsShouldShowPageHeader(pageController)) {
        lgPageLabelsRemoveTableHeader(controller);
        return;
    }
    if (objc_getAssociatedObject(host, kLGPageLabelsLayoutInProgressKey)) return;
    UIView *container = objc_getAssociatedObject(host, kLGPageLabelsHeaderViewKey);
    UITableView *tableView = lgPageLabelsTableViewForController(host);
    if (container && tableView)
        lgPageLabelsLayoutHeaderContainer(container, tableView, pageController);
}

%group PageLabels
%hook PSSpecifier
+ (instancetype)preferenceSpecifierNamed:(NSString *)identifier target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(NSInteger)cellType edit:(Class)edit {
    if (LGPageLabelsFeatureEnabled()
        && [identifier isKindOfClass:[NSString class]]
        && [(NSString *)identifier isEqualToString:kLGPageLabelsMarkerID]
        && lgSettingsIsWiFiSettingsController(target)) {
        return nil;
    }
    return %orig;
}
%end

%hook PSListController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    lgPageLabelsHandleHostedViewWillAppear(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (lgSettingsIsWiFiSettingsController(self)) {
        lgPageLabelsClearWiFiPaneCustomizations(self);
        return;
    }
    if (!lgPageLabelsIsActiveForController(self) || lgPageLabelsIconForController(self)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (lgPageLabelsIconForController(self)) return;
        UINavigationController *nav = [(id)self navigationController];
        if ([nav isKindOfClass:[UINavigationController class]] && nav.viewControllers.count >= 2) {
            id previous = nav.viewControllers[nav.viewControllers.count - 2];
            lgPageLabelsHandleNavigationFromSourceToDestination(previous, self);
        }
        if (!lgPageLabelsIconForController(self)) {
            UIImage *titleIcon = lgPageLabelsIconForTitle(lgPageLabelsPageTitleForController(self));
            if (titleIcon)
                lgPageLabelsStoreIconForController(self, titleIcon);
        }
    });
}

- (void)viewWillLayoutSubviews {
    %orig;
    lgPageLabelsHandleHostedViewWillLayoutSubviews(self);
}

- (void)reloadSpecifiers {
    %orig;
    if (lgSettingsIsWiFiSettingsController(self)) {
        lgPageLabelsClearWiFiPaneCustomizations(self);
        return;
    }
    if (lgPageLabelsShouldShowPageHeader(self))
        lgPageLabelsInstallTableHeader(self);
    else
        lgPageLabelsRemoveTableHeader(self);
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (lgSettingsIsWiFiSettingsController(self)) {
        %orig;
        return;
    }
    if (lgPageLabelsShouldCaptureIcons()) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        if (lgPageLabelsShouldCaptureIconForSpecifier(spec)) {
            UIImage *icon = lgPageLabelsExtractIconAggressive(cell, spec, self, indexPath);
            if (icon)
                lgPageLabelsCacheIconForController(self, indexPath, spec, icon);
        }
    }
    %orig;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (lgSettingsIsWiFiSettingsController(self)) return %orig;
    if (lgPageLabelsShouldCaptureIcons()) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        if (lgPageLabelsShouldCaptureIconForSpecifier(spec))
            lgPageLabelsCaptureNavigationFromSource(self, tableView, indexPath, spec);
        else {
            lgPageLabelsSetPendingIcon(nil);
            objc_setAssociatedObject(self, kLGPageLabelsLastCapturedIconKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kLGPageLabelsLastCapturedSpecifierKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (lgSettingsIsWiFiSettingsController(self)) {
        %orig;
        return;
    }
    if (lgPageLabelsShouldCaptureIcons()) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        if (lgPageLabelsShouldCaptureIconForSpecifier(spec))
            lgPageLabelsCaptureNavigationFromSource(self, tableView, indexPath, spec);
    }
    %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (lgSettingsIsWiFiSettingsController(self)) {
        %orig;
        return;
    }
    if (lgPageLabelsShouldCaptureIcons()) {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        if (lgPageLabelsShouldCaptureIconForSpecifier(spec))
            lgPageLabelsCaptureNavigationFromSource(self, tableView, indexPath, spec);
    }
    %orig;
}

- (void)didSelectSpecifier:(PSSpecifier *)specifier {
    if (lgSettingsIsWiFiSettingsController(self)) {
        %orig;
        return;
    }
    if (lgPageLabelsShouldCaptureIcons() && lgPageLabelsShouldCaptureIconForSpecifier(specifier)) {
        NSIndexPath *indexPath = nil;
        if ([self respondsToSelector:@selector(indexPathForSpecifier:)])
            indexPath = [(PSListController *)self indexPathForSpecifier:specifier];
        if (!indexPath) {
            id stored = objc_getAssociatedObject(self, kLGPageLabelsLastSelectedIndexPathKey);
            if ([stored isKindOfClass:[NSIndexPath class]])
                indexPath = (NSIndexPath *)stored;
        }
        lgPageLabelsCaptureNavigationFromSource(self, lgPageLabelsTableViewForController(self), indexPath, specifier);
    }
    %orig;
}

- (void)pushController:(id)controller {
    %orig;
    if (LGPageLabelsFeatureEnabled() && controller && !lgSettingsIsWiFiSettingsController(controller))
        lgPageLabelsHandleNavigationFromSourceToDestination(self, controller);
}

- (void)showController:(id)controller {
    %orig;
    if (LGPageLabelsFeatureEnabled() && controller && !lgSettingsIsWiFiSettingsController(controller))
        lgPageLabelsHandleNavigationFromSourceToDestination(self, controller);
}

- (void)pushDetailController:(id)controller {
    %orig;
    if (LGPageLabelsFeatureEnabled() && controller && !lgSettingsIsWiFiSettingsController(controller))
        lgPageLabelsHandleNavigationFromSourceToDestination(self, controller);
}
%end

%hook UINavigationController
- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    %orig;
    if (!LGPageLabelsFeatureEnabled()) return;
    if (lgSettingsIsWiFiSettingsController(viewController)) {
        lgPageLabelsClearWiFiPaneCustomizations(viewController);
        return;
    }
    UINavigationController *nav = (UINavigationController *)self;
    if (nav.viewControllers.count >= 2) {
        id source = nav.viewControllers[nav.viewControllers.count - 2];
        lgPageLabelsHandleNavigationFromSourceToDestination(source, viewController);
    }
}
%end

%hook PSTableCell
- (void)setIcon:(UIImage *)icon {
    %orig;
    if (!LGPageLabelsFeatureEnabled() || !icon || lgPageLabelsShouldBlockPageLabelCell((UIView *)self)) return;
    PSSpecifier *spec = [self valueForKey:@"specifier"];
    if (lgPageLabelsIsPageLabelSpecifier(spec)) return;
    UITableView *tableView = lgSettings26OwningTableViewForView((UIView *)self);
    id controller = lgPageLabelsListControllerForTableView(tableView);
    NSIndexPath *indexPath = tableView ? [tableView indexPathForCell:(UITableViewCell *)self] : nil;
    if (controller)
        lgPageLabelsCacheIconForController(controller, indexPath, spec, icon);
    id label = [spec propertyForKey:@"label"];
    if ([label isKindOfClass:[NSString class]])
        lgPageLabelsRememberIconForTitle((NSString *)label, icon);
    NSString *rowTitle = lgPageLabelsTitleTextForCell((UITableViewCell *)self);
    if (rowTitle.length)
        lgPageLabelsRememberIconForTitle(rowTitle, icon);
    gLGPageLabelsLastNavigationIcon = lgPageLabelsCopyImage(icon);
    lgPageLabelsSetPendingIcon(icon);
    if (controller)
        lgPageLabelsStoreCapturedIconOnSource(controller, spec, icon);
    UITableViewCell *tableCell = (UITableViewCell *)self;
    if (tableCell.selected || tableCell.highlighted)
        lgPageLabelsRememberCapturedIcon(controller, spec, icon);
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    if (selected && lgPageLabelsShouldCaptureIcons() && !lgPageLabelsShouldBlockPageLabelCell((UIView *)self)) {
        UITableView *tableView = lgSettings26OwningTableViewForView((UIView *)self);
        id controller = lgPageLabelsListControllerForTableView(tableView);
        if (lgSettingsIsWiFiSettingsController(controller)) {
            %orig;
            return;
        }
        if (lgPageLabelsShouldCaptureIcons()) {
            PSSpecifier *spec = [self valueForKey:@"specifier"];
            if (!lgPageLabelsIsPageLabelSpecifier(spec)) {
                NSIndexPath *indexPath = tableView ? [tableView indexPathForCell:(UITableViewCell *)self] : nil;
                lgPageLabelsCaptureIconFromCell((UITableViewCell *)self, controller, spec);
                if (indexPath && controller) {
                    objc_setAssociatedObject(controller, kLGPageLabelsLastSelectedIndexPathKey, indexPath,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        }
    }
    %orig;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    if (LGPageLabelsFeatureEnabled()
        && (lgPageLabelsIsPageLabelSpecifier(specifier) || lgPageLabelsShouldBlockPageLabelCell((UIView *)self)))
        return;
    %orig;
}

- (void)layoutSubviews {
    if (LGPageLabelsFeatureEnabled() && lgPageLabelsShouldBlockPageLabelCell((UIView *)self)) return;
    PSSpecifier *spec = [self valueForKey:@"specifier"];
    if (LGPageLabelsFeatureEnabled() && lgPageLabelsIsPageLabelSpecifier(spec)) return;
    %orig;
}
%end
%end

static Class lgSettings26CellClassForSpecifier(PSSpecifier *specifier) {
    if (!specifier) return Nil;
    id cellClassValue = [specifier propertyForKey:@"cellClass"];
    if (cellClassValue && object_isClass(cellClassValue)) return (Class)cellClassValue;
    if ([cellClassValue isKindOfClass:[NSString class]])
        return NSClassFromString((NSString *)cellClassValue);
    id cellClassName = [specifier propertyForKey:@"cellClassName"];
    if ([cellClassName isKindOfClass:[NSString class]]) return NSClassFromString((NSString *)cellClassName);
    return Nil;
}

static NSString *lgSettings26TitleCaseString(NSString *text) {
    if (!text.length) return text ?: @"";
    NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
    NSLocale *locale = [NSLocale currentLocale];
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    BOOL atWordStart = YES;

    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([whitespace characterIsMember:c]) {
            [result appendFormat:@"%C", c];
            atWordStart = YES;
            continue;
        }
        NSString *character = [text substringWithRange:NSMakeRange(i, 1)];
        if (atWordStart && [letters characterIsMember:c]) {
            [result appendString:[character uppercaseStringWithLocale:locale]];
            atWordStart = NO;
        } else if ([letters characterIsMember:c]) {
            [result appendString:[character lowercaseStringWithLocale:locale]];
            atWordStart = NO;
        } else {
            [result appendFormat:@"%C", c];
        }
    }
    return result;
}

static BOOL lgSettings26IsHeaderFooterViewLabel(UILabel *label) {
    if (!label) return NO;
    Class headerFooterLabel = NSClassFromString(@"_UITableViewHeaderFooterViewLabel");
    return headerFooterLabel && [label isKindOfClass:headerFooterLabel];
}

static BOOL lgSettings26StringUsesAllUppercaseLetters(NSString *text) {
    if (!text.length) return NO;
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSLocale *locale = [NSLocale currentLocale];
    BOOL foundLetter = NO;

    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (![letters characterIsMember:c]) continue;
        foundLetter = YES;
        NSString *character = [text substringWithRange:NSMakeRange(i, 1)];
        if (![character isEqualToString:[character uppercaseStringWithLocale:locale]])
            return NO;
    }
    return foundLetter;
}

static BOOL lgSettings26ShouldTitleCaseLabelText(UILabel *label, NSString *text) {
    if (!lgSettings26IsHeaderFooterViewLabel(label)) return YES;
    return lgSettings26StringUsesAllUppercaseLetters(text);
}

static void lgSettings26UpdateHeaderFooterLabelBoldMark(UILabel *label, NSString *sourceText) {
    if (!lgSettings26IsHeaderFooterViewLabel(label)) return;
    if (lgSettings26StringUsesAllUppercaseLetters(sourceText))
        objc_setAssociatedObject(label, kLGSettings26HeaderFooterLabelBoldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else
        objc_setAssociatedObject(label, kLGSettings26HeaderFooterLabelBoldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL lgSettings26ShouldApplyBoldLabelStyle(UILabel *label, NSString *text) {
    if (!lgSettings26IsHeaderFooterViewLabel(label)) return YES;
    if (lgSettings26StringUsesAllUppercaseLetters(text)) return YES;
    return [objc_getAssociatedObject(label, kLGSettings26HeaderFooterLabelBoldKey) boolValue];
}

static BOOL lgSettings26LabelIsInTableHeaderOrFooter(UILabel *label) {
    for (UIView *parent = label; parent; parent = parent.superview) {
        NSString *cls = NSStringFromClass([parent class]);
        if ([cls containsString:@"HeaderFooterView"]) return YES;
    }
    return NO;
}

static BOOL lgSettings26IsSectionFooterLabelClass(UILabel *label) {
    if (!label) return NO;
    Class headerFooterLabel = NSClassFromString(@"_UITableViewHeaderFooterViewLabel");
    if (headerFooterLabel && [label isKindOfClass:headerFooterLabel]) return YES;
    NSString *cls = NSStringFromClass([label class]);
    return [cls containsString:@"HeaderFooter"] && [cls containsString:@"Label"];
}

static BOOL lgSettings26ShouldAffectSectionLabel(UILabel *label) {
    if (!label || !LGIsSettingsHostApplication()) return NO;
    if (!lgSettings26LabelIsInTableHeaderOrFooter(label) && !lgSettings26IsSectionFooterLabelClass(label))
        return NO;
    UITableView *tableView = lgSettings26OwningTableViewForView(label);
    if (!tableView) return YES;
    if (!tableView.delegate) return YES;
    return lgSettings26ShouldAffectController(tableView.delegate);
}

static UIFont *lgSettings26SectionHeaderFontForLabel(UILabel *label, UIFont *referenceFont) {
    UIFont *font = referenceFont ?: label.font;
    if (!font || !label) return nil;

    CGFloat size = font.pointSize;

    UIFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits;
    traits |= UIFontDescriptorTraitBold;
    UIFontDescriptor *descriptor = [[font.fontDescriptor fontDescriptorWithSymbolicTraits:traits]
        fontDescriptorByAddingAttributes:@{
            UIFontDescriptorTraitsAttribute: @{ UIFontWeightTrait: @(UIFontWeightBold) }
        }];
    UIFont *sectionFont = [UIFont fontWithDescriptor:descriptor size:size];
    if (!sectionFont)
        sectionFont = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
    return sectionFont;
}

static void lgSettings26ApplySectionLabelStyle(UILabel *label) {
    if (!LGSettings26SectionLabelsFeatureEnabled() || !lgSettings26ShouldAffectSectionLabel(label)) return;

    NSAttributedString *attr = label.attributedText;
    if (attr.length) {
        NSString *source = attr.string;
        lgSettings26UpdateHeaderFooterLabelBoldMark(label, source);
        BOOL shouldTitleCase = lgSettings26ShouldTitleCaseLabelText(label, source);
        BOOL shouldBold = lgSettings26ShouldApplyBoldLabelStyle(label, source);
        if (!shouldTitleCase && !shouldBold) return;

        NSString *displayText = shouldTitleCase ? lgSettings26TitleCaseString(source) : source;
        NSMutableAttributedString *mutable = [attr mutableCopy];
        if (![mutable.string isEqualToString:displayText])
            [mutable replaceCharactersInRange:NSMakeRange(0, mutable.length) withString:displayText];
        if (shouldBold) {
            UIFont *baseFont = [attr attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
            UIFont *attrFont = lgSettings26SectionHeaderFontForLabel(label, baseFont);
            if (attrFont)
                [mutable addAttribute:NSFontAttributeName value:attrFont range:NSMakeRange(0, mutable.length)];
        }
        if (![attr isEqualToAttributedString:mutable])
            label.attributedText = [mutable copy];
        return;
    }

    NSString *raw = label.text;
    if (!raw.length) return;
    lgSettings26UpdateHeaderFooterLabelBoldMark(label, raw);
    BOOL shouldTitleCase = lgSettings26ShouldTitleCaseLabelText(label, raw);
    BOOL shouldBold = lgSettings26ShouldApplyBoldLabelStyle(label, raw);
    if (!shouldTitleCase && !shouldBold) return;

    if (shouldTitleCase) {
        NSString *titleCased = lgSettings26TitleCaseString(raw);
        if (![raw isEqualToString:titleCased])
            label.text = titleCased;
    }
    if (shouldBold) {
        UIFont *sectionFont = lgSettings26SectionHeaderFontForLabel(label, label.font);
        if (sectionFont) label.font = sectionFont;
    }
}

@interface _UITableViewHeaderFooterViewLabel : UILabel
@end

%group Settings26Cell
%hook PSListController
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    %orig;
    if (!LGSettings26SectionLabelsFeatureEnabled() || !lgSettings26ShouldAffectCellLayout(self)) return;
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        lgSettings26ApplySectionLabelStyle(header.textLabel);
    }
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    %orig;
    if (!LGSettings26SectionLabelsFeatureEnabled() || !lgSettings26ShouldAffectCellLayout(self)) return;
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        lgSettings26ApplySectionLabelStyle(footer.textLabel);
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat originalHeight = %orig;
    if (!LGSettings26FeatureEnabled() || !lgSettings26ShouldAffectCellLayout(self)) return originalHeight;
    if (![self respondsToSelector:@selector(specifierAtIndexPath:)]) return originalHeight;
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    if (!spec) return originalHeight;
    Class cellClass = lgSettings26CellClassForSpecifier(spec);
    if (lgSettings26ShouldPreserveCellHeight(cellClass)) return originalHeight;
    return lgSettings26ResolvedCellHeight(originalHeight);
}
%end

%hook PSTableCell
- (void)setFrame:(CGRect)frame {
    if (lgPageLabelsShouldBlockPageLabelCell((UIView *)self) || lgPageLabelsIsPageLabelSpecifier([self valueForKey:@"specifier"])) {
        %orig(frame);
        return;
    }
    if (LGSettings26FeatureEnabled() && lgSettings26ShouldAffectCell((UIView *)self) &&
        !lgSettings26ShouldPreserveCellHeight(object_getClass((id)self))) {
        frame.size.height = lgSettings26ResolvedCellHeight(frame.size.height);
    }
    %orig(frame);
}

- (void)setBounds:(CGRect)bounds {
    if (lgPageLabelsShouldBlockPageLabelCell((UIView *)self) || lgPageLabelsIsPageLabelSpecifier([self valueForKey:@"specifier"])) {
        %orig(bounds);
        return;
    }
    if (LGSettings26FeatureEnabled() && lgSettings26ShouldAffectCell((UIView *)self) &&
        !lgSettings26ShouldPreserveCellHeight(object_getClass((id)self))) {
        bounds.size.height = lgSettings26ResolvedCellHeight(bounds.size.height);
    }
    %orig(bounds);
}

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!LGSettings26FeatureEnabled() || lgSettings26ShouldPreserveCellHeight((Class)self)) return %orig;
    return lgSettings26ResolvedCellHeight(%orig);
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!LGSettings26FeatureEnabled() || !lgSettings26ShouldAffectCell((UIView *)self) ||
        lgSettings26ShouldPreserveCellHeight(object_getClass((id)self))) {
        return %orig;
    }
    return lgSettings26ResolvedCellHeight(%orig);
}

- (void)layoutSubviews {
    %orig;
    if (lgPageLabelsShouldBlockPageLabelCell((UIView *)self) || lgPageLabelsIsPageLabelSpecifier([self valueForKey:@"specifier"])) return;
    lgSettings26ApplyTableCellLayout((UIView *)self);
}
%end

%hook PSUIAppleAccountCell
- (void)layoutSubviews {
    %orig;
    lgSettings26ApplyTableCellLayout((UIView *)self);
}
%end

%hook UITableViewHeaderFooterView
- (void)layoutSubviews {
    %orig;
    if (!LGSettings26SectionLabelsFeatureEnabled()) return;
    UITableViewHeaderFooterView *headerFooter = (UITableViewHeaderFooterView *)self;
    lgSettings26ApplySectionLabelStyle(headerFooter.textLabel);
}

- (void)setTextLabel:(UILabel *)textLabel {
    %orig;
    lgSettings26ApplySectionLabelStyle(textLabel);
}
%end

%hook _UITableViewHeaderFooterViewLabel
- (void)setText:(NSString *)text {
    if (LGSettings26SectionLabelsFeatureEnabled() && lgSettings26ShouldAffectSectionLabel((UILabel *)self) && text.length) {
        lgSettings26UpdateHeaderFooterLabelBoldMark((UILabel *)self, text);
        if (lgSettings26ShouldTitleCaseLabelText((UILabel *)self, text))
            text = lgSettings26TitleCaseString(text);
    }
    %orig(text);
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (LGSettings26SectionLabelsFeatureEnabled() && lgSettings26ShouldAffectSectionLabel((UILabel *)self) && attributedText.length) {
        lgSettings26UpdateHeaderFooterLabelBoldMark((UILabel *)self, attributedText.string);
        BOOL shouldTitleCase = lgSettings26ShouldTitleCaseLabelText((UILabel *)self, attributedText.string);
        BOOL shouldBold = lgSettings26ShouldApplyBoldLabelStyle((UILabel *)self, attributedText.string);
        if (shouldTitleCase || shouldBold) {
            NSMutableAttributedString *mutable = [attributedText mutableCopy];
            if (shouldTitleCase) {
                NSString *titleCased = lgSettings26TitleCaseString(mutable.string);
                if (![mutable.string isEqualToString:titleCased])
                    [mutable replaceCharactersInRange:NSMakeRange(0, mutable.length) withString:titleCased];
            }
            if (shouldBold) {
                UIFont *baseFont = [attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
                UIFont *sectionFont = lgSettings26SectionHeaderFontForLabel((UILabel *)self, baseFont);
                if (sectionFont)
                    [mutable addAttribute:NSFontAttributeName value:sectionFont range:NSMakeRange(0, mutable.length)];
            }
            attributedText = [mutable copy];
        }
    }
    %orig(attributedText);
}

- (void)layoutSubviews {
    %orig;
    lgSettings26ApplySectionLabelStyle((UILabel *)self);
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    if (LGSettings26SectionLabelsFeatureEnabled()
        && !LGIsSettingsNavActionLabel(self)
        && lgSettings26ShouldAffectSectionLabel(self)
        && text.length) {
        lgSettings26UpdateHeaderFooterLabelBoldMark(self, text);
        if (lgSettings26ShouldTitleCaseLabelText(self, text))
            text = lgSettings26TitleCaseString(text);
    }
    %orig(text);
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (LGSettings26SectionLabelsFeatureEnabled()
        && !LGIsSettingsNavActionLabel(self)
        && lgSettings26ShouldAffectSectionLabel(self)
        && attributedText.length) {
        lgSettings26UpdateHeaderFooterLabelBoldMark(self, attributedText.string);
        BOOL shouldTitleCase = lgSettings26ShouldTitleCaseLabelText(self, attributedText.string);
        BOOL shouldBold = lgSettings26ShouldApplyBoldLabelStyle(self, attributedText.string);
        if (shouldTitleCase || shouldBold) {
            NSMutableAttributedString *mutable = [attributedText mutableCopy];
            if (shouldTitleCase) {
                NSString *titleCased = lgSettings26TitleCaseString(mutable.string);
                if (![mutable.string isEqualToString:titleCased])
                    [mutable replaceCharactersInRange:NSMakeRange(0, mutable.length) withString:titleCased];
            }
            if (shouldBold) {
                UIFont *baseFont = [attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
                UIFont *sectionFont = lgSettings26SectionHeaderFontForLabel(self, baseFont);
                if (sectionFont)
                    [mutable addAttribute:NSFontAttributeName value:sectionFont range:NSMakeRange(0, mutable.length)];
            }
            attributedText = [mutable copy];
        }
    }
    %orig(attributedText);
}

- (void)layoutSubviews {
    %orig;
    if (LGSettings26SectionLabelsFeatureEnabled()
        && !LGIsSettingsNavActionLabel(self)
        && lgSettings26ShouldAffectSectionLabel(self)) {
        lgSettings26ApplySectionLabelStyle(self);
    }
}
%end
%end

// ── Preferences ──────────────────────────────────────────────────────────────
// Matches LiquidGlassAL.x: one shared NSUserDefaults per suite, read once on
// first access (dispatch_once). Keys default to YES when not set except
// pageBackButtonEnabled (NO). Opt-out per section via Settings.

static NSString *const kLGPrefsSuite = @"com.strayfade.liquidglass~prefs";
static NSString *const kLGPrefsLockedKey = @"lgPrefsLockedForCrashDebug";

static NSUserDefaults *lgPrefsDefaults(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:kLGPrefsSuite];
    });
    return d;
}

static BOOL lgPrefsLockedForCrashDebug(void) {
    return [lgPrefsDefaults() boolForKey:kLGPrefsLockedKey];
}

/// Master toggle from the header cell (`Enabled`); falls back to legacy `enabled`.
static BOOL lgMasterEnabled(void) {
    if (lgPrefsLockedForCrashDebug()) return NO;
    NSUserDefaults *d = lgPrefsDefaults();
    if ([d objectForKey:@"Enabled"] != nil) return [d boolForKey:@"Enabled"];
    if ([d objectForKey:@"enabled"] != nil) return [d boolForKey:@"enabled"];
    return YES;
}

static BOOL lgPrefDefaultValue(NSString *key) {
    if ([key isEqualToString:@"pageBackButtonEnabled"]) return NO;
    if ([key isEqualToString:@"pageLabelsEnabled"]) return NO;
    return YES;
}

/// Returns the stored BOOL for `key`; uses lgPrefDefaultValue when the key is absent.
static BOOL lgPref(NSString *key) {
    if (lgPrefsLockedForCrashDebug()) return NO;
    id val = [lgPrefsDefaults() objectForKey:key];
    return [val isKindOfClass:[NSNumber class]] ? [val boolValue] : lgPrefDefaultValue(key);
}

// Temporary crash-debug mode: keep only core rendering path active.
static const BOOL kLGRenderOnlyDebugMode = NO;

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    BOOL isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];
    BOOL isSettings = [bundleID isEqualToString:@"com.apple.Preferences"];
    if (!isSpringBoard && !isSettings) return;

    BOOL shouldInitUngrouped = NO;
    BOOL shouldInitSettingsBackButtonOnly = NO;

    if (kLGRenderOnlyDebugMode) {
        shouldInitSettingsBackButtonOnly = isSettings;
    } else if (isSpringBoard) {
            // ── Load preferences (default YES; pageBackButtonEnabled defaults NO) ─
            // A Respring is required for changes to take effect (the Settings page
            // has a Respring button for exactly this purpose).
            BOOL prefOn       = lgMasterEnabled();
            BOOL prefDock     = prefOn && lgPref(@"dockEnabled");
            BOOL prefFolder   = prefOn && lgPref(@"folderEnabled");
            BOOL prefSearch   = prefOn && lgPref(@"searchBarEnabled");
            BOOL prefCC       = prefOn && lgPref(@"controlCenterEnabled");
            BOOL prefNotif    = prefOn && lgPref(@"notificationEnabled");
            BOOL prefBanner   = prefOn && lgPref(@"bannerEnabled");
            BOOL prefMedia    = prefOn && lgPref(@"mediaPlayerEnabled");
            BOOL prefQuick    = prefOn && lgPref(@"quickActionEnabled");
            BOOL prefContextMenu = prefOn && lgPref(@"contextMenuEnabled");
            BOOL prefSpot     = prefOn && lgPref(@"spotlightSearchEnabled");

            if (prefDock) {
                Class c1 = NSClassFromString(@"SBFloatingDockView");
            if (c1) %init(FloatingDock, SBFloatingDockView = c1);

            Class c2 = NSClassFromString(@"SBDockView");
            if (c2) %init(Dock, SBDockView = c2);
            }

            if (prefFolder) {
            Class c6 = NSClassFromString(@"SBFolderIconImageView");
            if (c6) %init(FolderIcon, SBFolderIconImageView = c6);

            Class c7 = NSClassFromString(@"SBFolderBackgroundView");
            if (c7) %init(FolderBG, SBFolderBackgroundView = c7);

            Class c8 = NSClassFromString(@"_UIBackdropView");
            if (c8) %init(FolderBackdropKiller, _UIBackdropView = c8);
            }

            if (prefBanner) {
            Class cBanner = NSClassFromString(@"NCNotificationShortLookView");
            if (cBanner) %init(Banner, NCNotificationShortLookView = cBanner);
            }

            if (prefNotif) {
            Class c9 = NSClassFromString(@"NCNotificationListCell");
            if (c9) %init(Notification, NCNotificationListCell = c9);

            Class cNC = NSClassFromString(@"NCNotificationListScrollView");
            if (cNC) %init(NCContainer, NCNotificationListScrollView = cNC);

            Class cCoverSheet = NSClassFromString(@"CSCoverSheetViewController");
            Class cCoverSheetView = NSClassFromString(@"CSCoverSheetView");
            Class cDashBoard = NSClassFromString(@"SBDashBoardViewController");
            Class cNCListView = NSClassFromString(@"NCNotificationListView");
            Class cNCStructuredList = NSClassFromString(@"NCNotificationStructuredListViewController");
            if (cCoverSheet || cCoverSheetView || cDashBoard || cNCListView || cNCStructuredList) {
                %init(LockScreenNotificationDim,
                      CSCoverSheetViewController = cCoverSheet,
                      CSCoverSheetView = cCoverSheetView,
                      SBDashBoardViewController = cDashBoard,
                      NCNotificationListView = cNCListView,
                      NCNotificationStructuredListViewController = cNCStructuredList);
            }

            Class cSeamless = NSClassFromString(@"NCNotificationSeamlessContentView");
            Class cRelativeDate = NSClassFromString(@"BSUIRelativeDateLabel");
            if (cSeamless || cRelativeDate) {
                %init(NotificationSeamlessText,
                      NCNotificationSeamlessContentView = cSeamless,
                      BSUIRelativeDateLabel = cRelativeDate);
            }
            }

            if (prefMedia) {
            Class c10 = NSClassFromString(@"CSAdjunctItemView");
            if (c10) %init(MediaPlayer, CSAdjunctItemView = c10);

            Class c11 = NSClassFromString(@"MPUSystemMediaControlsView");
            if (c11) %init(MediaPlayerControls, MPUSystemMediaControlsView = c11);
            }

            if (prefSearch) {
            Class c12 = NSClassFromString(@"SBHSearchTextField");
            if (c12) %init(SearchBar, SBHSearchTextField = c12);
            }

            if (prefSpot) {
            Class c12b = NSClassFromString(@"SBSearchBarTextField");
            if (c12b) %init(SpotlightSearch, SBSearchBarTextField = c12b);
            }

            if (prefSearch || prefSpot) {
            Class c13 = NSClassFromString(@"_UITextFieldRoundedRectBackgroundViewNeue");
            if (c13) %init(SearchBarBackground, _UITextFieldRoundedRectBackgroundViewNeue = c13);
            }

            if (prefOn) {
            Class c14 = NSClassFromString(@"MTMaterialView");
            if (c14) %init(SearchBarMaterial, MTMaterialView = c14);

            if (prefContextMenu) %init(ContextMenu);
            shouldInitUngrouped = YES;
            }

            if (prefQuick) {
            %init(QuickActionVisualEffect);

            Class c19 = NSClassFromString(@"SBUICallToActionButton");
            if (c19) %init(QuickActionSBUI, SBUICallToActionButton = c19);

            Class c20 = NSClassFromString(@"CSCallToActionButton");
            if (c20) %init(QuickActionCS, CSCallToActionButton = c20);

            Class c21 = NSClassFromString(@"SBFunctionButtonView");
            if (c21) %init(QuickActionFunctionButton, SBFunctionButtonView = c21);
            }

            if (prefCC) {
            Class cc3 = NSClassFromString(@"CCUIModuleInstanceView");
            Class cc4 = NSClassFromString(@"CCUIModuleBackgroundView");
            Class cc5 = NSClassFromString(@"CCUIContentModuleContentContainerView");
            if (cc3 || cc4 || cc5) {
                %init(ControlCenter, CCUIModuleInstanceView = cc3,
                                    CCUIModuleBackgroundView = cc4,
                                    CCUIContentModuleContentContainerView = cc5);
            }
            }

            // Suppress widget VC background material updates — prevent system from
            // re-adding MTMaterial blur after we've hidden it and injected LiquidGlass.
            if (lgPref(@"widgetEnabled")) {
                Class cWH1 = NSClassFromString(@"CHUISWidgetHostViewController");
                Class cWH2 = NSClassFromString(@"CHUISAvocadoHostViewController");
                if (cWH1 || cWH2) %init(WidgetSuppress);
            }
    } else if (isSettings) {
        if (lgMasterEnabled() && lgPref(@"pageBackButtonEnabled"))
            shouldInitSettingsBackButtonOnly = YES;
        if (lgMasterEnabled() && lgPref(@"pageLabelsEnabled")) {
            Class cPSListLabels = NSClassFromString(@"PSListController");
            Class cPSTableLabels = NSClassFromString(@"PSTableCell");
            Class cPSSpecifier = NSClassFromString(@"PSSpecifier");
            if (cPSListLabels || cPSTableLabels || cPSSpecifier) {
                %init(PageLabels,
                      PSListController = cPSListLabels,
                      PSTableCell = cPSTableLabels,
                      PSSpecifier = cPSSpecifier,
                      UINavigationController = [UINavigationController class]);
            }
        }
        if (lgMasterEnabled() && (lgPref(@"settings26Enabled") || lgPref(@"sectionLabelsEnabled"))) {
            Class cPSList = NSClassFromString(@"PSListController");
            Class cPSTable = NSClassFromString(@"PSTableCell");
            Class cAppleAccount = NSClassFromString(@"PSUIAppleAccountCell");
            Class cHeaderLabel = NSClassFromString(@"_UITableViewHeaderFooterViewLabel");
            if (cPSList || cPSTable || cAppleAccount || cHeaderLabel) {
                %init(Settings26Cell,
                      PSListController = cPSList,
                      PSTableCell = cPSTable,
                      PSUIAppleAccountCell = cAppleAccount,
                      _UITableViewHeaderFooterViewLabel = cHeaderLabel,
                      UITableViewHeaderFooterView = [UITableViewHeaderFooterView class],
                      UILabel = [UILabel class]);
            }
        }
    }

    if (shouldInitSettingsBackButtonOnly) {
        Class cPageBackOnly = NSClassFromString(@"_UIButtonBarButton");
        Class cBarBackgroundOnly = NSClassFromString(@"_UIBarBackground");
        Class cNavBarOnly = [UINavigationBar class];
        Class cNavContentOnly = NSClassFromString(@"_UINavigationBarContentView");
        if (cPageBackOnly || cBarBackgroundOnly || cNavBarOnly || cNavContentOnly) {
            LGEnsureFeatherBlurFrameworkLoaded();
            %init(SettingsBackButtonOnly,
                  _UIButtonBarButton = cPageBackOnly,
                  _UIBarBackground = cBarBackgroundOnly,
                  UINavigationBar = cNavBarOnly,
                  _UINavigationBarContentView = cNavContentOnly);
        }
    }

    if (shouldInitUngrouped) %init(_ungrouped);

    if (kLGRenderOnlyDebugMode) return;

    // Shared UIKit hooks — SpringBoard and Settings only (not other apps).
    BOOL prefOnHost = lgMasterEnabled();
    BOOL prefKnockoutHost = prefOnHost && isSpringBoard && lgPref(@"knockoutBackdropEnabled");
    if (prefKnockoutHost) {
        Class cKnockout = NSClassFromString(@"_UIDimmingKnockoutBackdropView");
        if (cKnockout) %init(DimmingKnockoutBackdrop, _UIDimmingKnockoutBackdropView = cKnockout);
        Class cAlertPhone = NSClassFromString(@"_UIAlertControllerPhoneTVMacView");
        Class cAlertView = NSClassFromString(@"_UIAlertControllerView");
        Class cAlertSep = NSClassFromString(@"_UIInterfaceActionVibrantSeparatorView");
        Class cAlertAction = NSClassFromString(@"_UIAlertControllerActionView");
        Class cAlertActionRep = NSClassFromString(@"_UIInterfaceActionCustomViewRepresentationView");
        Class cActionGroup = NSClassFromString(@"UIInterfaceActionGroupView");
        if (cAlertPhone || cAlertView || cAlertSep || cAlertAction || cAlertActionRep || cActionGroup) {
            %init(AlertControllerPresentation,
                   _UIAlertControllerPhoneTVMacView = cAlertPhone,
                   _UIAlertControllerView = cAlertView,
                   _UIInterfaceActionVibrantSeparatorView = cAlertSep,
                   _UIAlertControllerActionView = cAlertAction,
                   _UIInterfaceActionCustomViewRepresentationView = cAlertActionRep,
                   UIInterfaceActionGroupView = cActionGroup);
        }
        lg_initAlertActionSequenceHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
            lg_initAlertActionSequenceHooks();
        });
    }

    // Slider/switch overlays are SpringBoard-only — replacing UISwitch inside Settings panes crashes.
    if (isSpringBoard && prefOnHost && lgPref(@"sliderEnabled")) %init(Slider);
    if (isSpringBoard && prefOnHost && lgPref(@"switchEnabled")) %init(Switch);

    // Page back + nav bar blur/gradient: Settings uses SettingsBackButtonOnly instead.
    LGRegisterPageBackPrefsObserver();
    if (prefOnHost && !isSettings) {
        LGEnsureFeatherBlurFrameworkLoaded();
        Class cPageBack = NSClassFromString(@"_UIButtonBarButton");
        Class cNavContent = NSClassFromString(@"_UINavigationBarContentView");
        Class cBarBackground = NSClassFromString(@"_UIBarBackground");
        if (cPageBack || cNavContent || cBarBackground) {
            %init(PageBackButton,
                   _UIButtonBarButton = cPageBack,
                   _UINavigationBarContentView = cNavContent,
                   _UIBarBackground = cBarBackground,
                   UINavigationBar = [UINavigationBar class]);
        }
    }

}

