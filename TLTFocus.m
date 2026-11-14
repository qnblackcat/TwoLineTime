#import "TLTShared.h"

// Status bar items that can be hidden: the Focus indicator and the breadcrumb. Both are hidden by answering "not
// enabled" whenever the status bar asks the display item (isEnabled, hook in Tweak.x).
//
// The Focus indicator (moon, bed, briefcase...) and the short announcement when a Focus turns on or off. Optional,
// because they share the status bar with the clock and can get squeezed when the clock is wide.
// Dropping the item's updates instead let the icon flash for a moment when the Control Center closed and the status bar
// restored its state.
@interface TLTStatusBarItem : NSObject
- (UIView *)statusBar;
@end

// The Control Center header has its own status bar (CCUIStatusBar) built from the same items: leave the Focus icon
// there alone, only hide it in the regular status bar.
static BOOL inControlCenter(id item) {
    UIView *bar = [(TLTStatusBarItem *)item respondsToSelector:@selector(statusBar)] ? [(TLTStatusBarItem *)item statusBar] : nil;
    for (UIView *v = bar; v; v = v.superview) {
        // Only the header's own CCUIStatusBar counts. A regular status bar can also be hosted in SBControlCenterWindow
        // (it sits in the window the Control Center uses): that one is the regular status bar and must stay hidden.
        if ([NSStringFromClass(v.class) hasPrefix:@"CCUIStatusBar"]) return YES;
    }
    return NO;
}

static BOOL isFocusItem(id item) {
    static Class classes[4];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes[0] = NSClassFromString(@"_UIStatusBarIndicatorQuietModeItem");
        classes[1] = NSClassFromString(@"_UIStatusBarIndicatorQuietModeAnnounceItem");
        classes[2] = NSClassFromString(@"STUIStatusBarIndicatorQuietModeItem");
        classes[3] = NSClassFromString(@"STUIStatusBarIndicatorQuietModeAnnounceItem");
    });
    for (int i = 0; i < 4; i++) {
        if (classes[i] && [item isKindOfClass:classes[i]]) return YES;
    }
    return NO;
}

// The breadcrumb: the "back to <app>" link shown at the left of the status bar after jumping from one app to another.
static BOOL isBreadcrumbItem(id item) {
    static Class classes[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes[0] = NSClassFromString(@"_UIStatusBarNavigationItem");
        classes[1] = NSClassFromString(@"STUIStatusBarNavigationItem");
    });
    for (int i = 0; i < 2; i++) {
        if (classes[i] && [item isKindOfClass:classes[i]]) return YES;
    }
    return NO;
}

BOOL hidesItem(id displayItem) {
    if (!enabled || !(hideFocus || hideBreadcrumb)) return NO;
    id item = [(TLTDisplayItem *)displayItem item];
    if (hideFocus && isFocusItem(item)) return !inControlCenter(item);
    if (hideBreadcrumb && isBreadcrumbItem(item)) return YES;
    return NO;
}
