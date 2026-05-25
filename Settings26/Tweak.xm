#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : NSObject
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
@end

static const CGFloat kSettings26CornerRadius = 25.0;
static const CGFloat kSettings26TargetCellHeight = 50.0;
static const void *kOriginalCornerRadiusKey = &kOriginalCornerRadiusKey;
static NSString *const kSettings26PrefsSuite = @"com.strayfade.settings26~prefs";

static CGFloat settings26ResolvedCellHeight(CGFloat originalHeight) {
    if (originalHeight <= 0.0) {
        return kSettings26TargetCellHeight;
    }
    return kSettings26TargetCellHeight;
}

static BOOL settings26IsAppleAccountCellClass(Class cellClass) {
    if (!cellClass) {
        return NO;
    }

    Class appleAccountClass = NSClassFromString(@"PSUIAppleAccountCell");
    if (appleAccountClass && [cellClass isSubclassOfClass:appleAccountClass]) {
        return YES;
    }

    return [NSStringFromClass(cellClass) isEqualToString:@"PSUIAppleAccountCell"];
}

static BOOL settings26IsEnabled(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), (__bridge CFStringRef)kSettings26PrefsSuite);
    if (!value) {
        return YES;
    }

    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int numberValue = 1;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numberValue)) {
            enabled = (numberValue != 0);
        }
    }

    CFRelease(value);
    return enabled;
}

static BOOL settings26IsAppleSettingsBundle(NSBundle *bundle) {
    if (!bundle) {
        return YES;
    }

    NSString *bundlePath = bundle.bundlePath ?: @"";

    if ([bundlePath containsString:@"/Library/PreferenceBundles/"] &&
        ![bundlePath containsString:@"/System/Library/PreferenceBundles/"]) {
        return NO;
    }

    if ([bundlePath containsString:@"/System/Library/PreferenceBundles/"] ||
        [bundlePath containsString:@"/Applications/Preferences.app/"] ||
        [bundlePath containsString:@"/System/Applications/Settings.app/"]) {
        return YES;
    }

    return YES;
}

static BOOL settings26ShouldAffectController(id controller) {
    if (!controller) {
        return YES;
    }
    Class controllerClass = object_getClass(controller);
    NSBundle *bundle = [NSBundle bundleForClass:controllerClass];
    return settings26IsAppleSettingsBundle(bundle);
}

static UITableView *settings26OwningTableViewForView(UIView *view) {
    UIView *current = view.superview;
    while (current) {
        if ([current isKindOfClass:[UITableView class]]) {
            return (UITableView *)current;
        }
        current = current.superview;
    }
    return nil;
}

static BOOL settings26ShouldAffectCell(id cell) {
    UIView *cellView = (UIView *)cell;
    UITableView *tableView = settings26OwningTableViewForView(cellView);
    if (tableView && !settings26ShouldAffectController(tableView.delegate)) {
        return NO;
    }
    return YES;
}

static Class settings26CellClassForSpecifier(PSSpecifier *specifier) {
    if (!specifier) {
        return Nil;
    }

    id cellClassValue = [specifier propertyForKey:@"cellClass"];
    if (cellClassValue && object_isClass(cellClassValue)) {
        return (Class)cellClassValue;
    }

    if ([cellClassValue isKindOfClass:[NSString class]]) {
        return NSClassFromString((NSString *)cellClassValue);
    }

    id cellClassName = [specifier propertyForKey:@"cellClassName"];
    if ([cellClassName isKindOfClass:[NSString class]]) {
        return NSClassFromString((NSString *)cellClassName);
    }

    return Nil;
}

static void settings26ApplyScaledCornerRadius(CALayer *layer) {
    if (!layer) {
        return;
    }

    NSNumber *storedRadius = objc_getAssociatedObject(layer, kOriginalCornerRadiusKey);
    if (!storedRadius) {
        CGFloat originalRadius = layer.cornerRadius;
        if (originalRadius <= 0.0) {
            return;
        }

        storedRadius = @(originalRadius);
        objc_setAssociatedObject(layer, kOriginalCornerRadiusKey, storedRadius, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    layer.cornerRadius = kSettings26CornerRadius;
}

%hook PSListController

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat originalHeight = %orig;
    if (!settings26IsEnabled() || !settings26ShouldAffectController(self)) {
        return originalHeight;
    }

    Class cellClass = settings26CellClassForSpecifier([self specifierAtIndexPath:indexPath]);
    if (settings26IsAppleAccountCellClass(cellClass)) {
        return originalHeight;
    }
    return settings26ResolvedCellHeight(originalHeight);
}

%end

%hook PSTableCell

- (void)setFrame:(CGRect)frame {
    if (settings26IsEnabled() && settings26ShouldAffectCell((PSTableCell *)self) && !settings26IsAppleAccountCellClass(object_getClass((id)self))) {
        frame.size.height = settings26ResolvedCellHeight(frame.size.height);
    }
    %orig(frame);
}

- (void)setBounds:(CGRect)bounds {
    if (settings26IsEnabled() && settings26ShouldAffectCell((PSTableCell *)self) && !settings26IsAppleAccountCellClass(object_getClass((id)self))) {
        bounds.size.height = settings26ResolvedCellHeight(bounds.size.height);
    }
    %orig(bounds);
}

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!settings26IsEnabled() || settings26IsAppleAccountCellClass((Class)self)) {
        return %orig;
    }
    return settings26ResolvedCellHeight(%orig);
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!settings26IsEnabled() || !settings26ShouldAffectCell((PSTableCell *)self) || settings26IsAppleAccountCellClass(object_getClass((id)self))) {
        return %orig;
    }
    return settings26ResolvedCellHeight(%orig);
}

- (void)layoutSubviews {
    %orig;

    if (!settings26IsEnabled() || !settings26ShouldAffectCell((PSTableCell *)self) || settings26IsAppleAccountCellClass(object_getClass((id)self))) {
        return;
    }

    UITableViewCell *tableCell = (UITableViewCell *)self;
    UIView *rootView = (UIView *)self;
    UIView *contentView = tableCell.contentView;

    CGRect rootBounds = rootView.bounds;
    rootBounds.size.height = settings26ResolvedCellHeight(CGRectGetHeight(rootBounds));
    rootView.bounds = rootBounds;

    if (contentView) {
        CGRect contentBounds = contentView.bounds;
        contentBounds.size.height = settings26ResolvedCellHeight(CGRectGetHeight(contentBounds));
        contentView.bounds = contentBounds;
    }

    if (contentView) {
        CGFloat midpointY = CGRectGetMidY(contentView.bounds);
        for (UIView *subview in contentView.subviews) {
            CGRect frame = subview.frame;
            frame.origin.y = round(midpointY - (CGRectGetHeight(frame) * 0.5));
            subview.frame = frame;
        }
    }

    settings26ApplyScaledCornerRadius(rootView.layer);
    settings26ApplyScaledCornerRadius(contentView.layer);
    settings26ApplyScaledCornerRadius(tableCell.backgroundView.layer);
    settings26ApplyScaledCornerRadius(tableCell.selectedBackgroundView.layer);
}

%end
