#import "TLTShared.h"

@interface FBSystemService : NSObject
+ (instancetype)sharedInstance;
- (void)exitAndRelaunch:(BOOL)relaunch;
@end
@interface _UIStatusBarPillView : UIView
@end
@interface STUIStatusBarPillView : UIView
@end

// ---- UIKit status bar ----

%hook _UIStatusBarStringView

%property (nonatomic, assign) BOOL tlt_managed;
%property (nonatomic, strong) NSNumber *tlt_scale;
%property (nonatomic, copy) NSString *tlt_orig;
%property (nonatomic, copy) NSString *tlt_last;
%property (nonatomic, strong) NSNumber *tlt_origCap;
%property (nonatomic, strong) NSNumber *tlt_origSize;
%property (nonatomic, strong) NSNumber *tlt_dy;
%property (nonatomic, assign) BOOL tlt_pill;

- (void)setFont:(UIFont *)font {
    %orig;
    labelDidSetFont(self);
}

- (void)layoutSubviews {
    %orig;
    labelDidLayout(self);
}

// a status bar copy shown during app <-> Home animations is not laid out before its first frame: shift it as soon as it has a window
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        alignVertically(self);
    }
}

// the pill follows the text only while the text is visible (see alignPill)
- (void)setAlpha:(CGFloat)alpha {
    %orig;
    if (self.tlt_pill) alignPill(self);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    if (self.tlt_pill) alignPill(self);
}

- (void)setTransform:(CGAffineTransform)transform {
    %orig;
    if (!settingTransform && enabled && self.tlt_managed && self.tlt_dy && fabs(transform.ty - self.tlt_dy.doubleValue) > 0.1) {
        alignVertically(self);
    }
}

%end

%hook _UIStatusBarTimeItem

- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    id result = %orig;
    timeItemDidUpdate(item, %c(_UIStatusBarTimeItem), %c(_UIStatusBarStringView));
    return result;
}

%end

%hook _UIStatusBarDisplayItem

- (BOOL)isEnabled {
    return hidesItem(self) ? NO : %orig;
}

%end

// The "back to <app>" breadcrumb makes the status bar taller and pushes the clock up even when its item is hidden (the
// visual provider lays out for the data, not for the item), so the status bar is told there is no back/forward link.
%hook _UIStatusBarData
- (id)backNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
- (id)forwardNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
%end

// The location indicator next to the two-line time squeezes the status bar layout (the font grows, the indicator is
// distorted), so it is always hidden: these hooks skip %orig and return nil.
%hook _UIStatusBarIndicatorLocationItem

- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    return nil;
}

%end

%hook _UIStatusBarPillView
- (void)layoutSubviews {
    %orig;
    pillDidLayout(self);
}
%end

%hook STUIStatusBarPillView
- (void)layoutSubviews {
    %orig;
    pillDidLayout(self);
}
%end

// ---- SystemStatusUI status bar (same items under other names) ----

%hook STUIStatusBarStringView

%property (nonatomic, assign) BOOL tlt_managed;
%property (nonatomic, strong) NSNumber *tlt_scale;
%property (nonatomic, copy) NSString *tlt_orig;
%property (nonatomic, copy) NSString *tlt_last;
%property (nonatomic, strong) NSNumber *tlt_origCap;
%property (nonatomic, strong) NSNumber *tlt_origSize;
%property (nonatomic, strong) NSNumber *tlt_dy;
%property (nonatomic, assign) BOOL tlt_pill;

- (void)setFont:(UIFont *)font {
    %orig;
    labelDidSetFont(self);
}

- (void)layoutSubviews {
    %orig;
    labelDidLayout(self);
}

// a status bar copy shown during app <-> Home animations is not laid out before its first frame: shift it as soon as it has a window
- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        alignVertically(self);
    }
}

// the pill follows the text only while the text is visible (see alignPill)
- (void)setAlpha:(CGFloat)alpha {
    %orig;
    if (self.tlt_pill) alignPill(self);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    if (self.tlt_pill) alignPill(self);
}

- (void)setTransform:(CGAffineTransform)transform {
    %orig;
    if (!settingTransform && enabled && self.tlt_managed && self.tlt_dy && fabs(transform.ty - self.tlt_dy.doubleValue) > 0.1) {
        alignVertically(self);
    }
}

%end

%hook STUIStatusBarTimeItem

- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    id result = %orig;
    timeItemDidUpdate(item, %c(STUIStatusBarTimeItem), %c(STUIStatusBarStringView));
    return result;
}

%end

%hook STUIStatusBarDisplayItem

- (BOOL)isEnabled {
    return hidesItem(self) ? NO : %orig;
}

%end

// On iOS 17 the data class is STUIStatusBarData, whose parents (STMutableStatusBarData < STStatusBarData, from
// SystemStatus) define the navigation entries, and the bar may be handed a plain STStatusBarData: hook the parents too,
// otherwise the Dynamic Island provider still sees the breadcrumb and keeps the room for it.
%hook STStatusBarData
- (id)backNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
- (id)forwardNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
%end

%hook STMutableStatusBarData
- (id)backNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
- (id)forwardNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
%end

%hook STUIStatusBarData
- (id)backNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
- (id)forwardNavigationEntry { return enabled && hideBreadcrumb ? nil : %orig; }
%end

// same, SystemStatusUI stack
%hook STUIStatusBarIndicatorLocationItem

- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    return nil;
}

%end

static void settingsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    TLTLog(@"settings changed notification");
    loadSettings();
    refreshLabels();
}

static void screenChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    TLTScreenChanged();
}

static void respring(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    TLTLog(@"respring requested");
    [[%c(FBSystemService) sharedInstance] exitAndRelaunch:YES];
}

%ctor {
    TLTRenderInit();
    loadSettings();
    TLTHookPillProviders();
    TLTLog(@"loaded in %@, iOS %@", NSProcessInfo.processInfo.processName, UIDevice.currentDevice.systemVersion);
    TLTLog(@"classes: _UIStatusBarTimeItem=%d STUIStatusBarTimeItem=%d _UIStatusBarStringView=%d STUIStatusBarStringView=%d",
           %c(_UIStatusBarTimeItem) != nil, %c(STUIStatusBarTimeItem) != nil,
           %c(_UIStatusBarStringView) != nil, %c(STUIStatusBarStringView) != nil);
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, settingsChanged, kReloadKey, NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(center, NULL, screenChanged, CFSTR(kBlanked), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(center, NULL, respring, kRespring, NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}
