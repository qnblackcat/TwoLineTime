#import "TLTShared.h"
#import <objc/runtime.h>
#import <substrate.h>

// Which kind of status bar this is comes from its visual provider (the class that lays the bar out): the Dynamic
// Island iPhones use ..VisualProvider_DynamicSplit (and ..DynamicSplitMedium), the notch ones ..Split1170, ..Split828...
// Dynamic Island has no notch pill to grow, so only the notch providers get a taller pill.
@interface TLTProviderBar : NSObject
- (id)visualProvider;
@end
@interface TLTBarItem : NSObject
- (id)statusBar;
@end

static BOOL isDynamicProvider(id provider) {
    static Class classes[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes[0] = NSClassFromString(@"_UIStatusBarVisualProvider_DynamicSplit");
        classes[1] = NSClassFromString(@"STUIStatusBarVisualProvider_DynamicSplit");
    });
    return (classes[0] && [provider isKindOfClass:classes[0]]) || (classes[1] && [provider isKindOfClass:classes[1]]);
}

// The preferences (the Settings app) cannot see the status bar's provider, so SpringBoard writes down what it found:
// the preferences grey out the pill switch when it says no. Once per launch, and SpringBoard's status bar only.
static void publishPillSupport(BOOL supported) {
    static BOOL published;
    if (published || ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    published = YES;
    CFPreferencesSetAppValue(kPillSupportedKey, supported ? kCFBooleanTrue : kCFBooleanFalse, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    TLTLog(@"pill support (visual provider) written to the preferences: %d", supported);
}

// The pill of this time display item can be made taller. No provider yet (the bar is not set up): not now, the next
// update asks again.
BOOL pillCanGrow(id displayItem) {
    id item = [(TLTDisplayItem *)displayItem item];
    TLTProviderBar *bar = [(TLTBarItem *)item respondsToSelector:@selector(statusBar)] ? [(TLTBarItem *)item statusBar] : nil;
    id provider = [bar respondsToSelector:@selector(visualProvider)] ? [bar visualProvider] : nil;
    static BOOL loggedMissing, loggedProvider;
    if (!provider) {
        if (!loggedMissing) { loggedMissing = YES; TLTLog(@"pillCanGrow: no provider (item %@, status bar %@)", [(id)item class], [bar class]); }
        return NO;
    }
    if (!loggedProvider) { loggedProvider = YES; TLTLog(@"pillCanGrow: visual provider %@", [provider class]); }
    BOOL grows = !isDynamicProvider(provider);
    publishPillSupport(grows);
    return grows;
}

static BOOL isPillView(UIView *view) {
    static Class classes[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes[0] = NSClassFromString(@"_UIStatusBarPillView");
        classes[1] = NSClassFromString(@"STUIStatusBarPillView");
    });
    return (classes[0] && [view isKindOfClass:classes[0]]) || (classes[1] && [view isKindOfClass:classes[1]]);
}

// In a pill the text keeps the place it has in the normal two-line clock; the pill moves to be centred around it, so
// it surrounds both lines evenly. (The pill is laid out before its label exists, so the label drives this.)
void alignPill(TLTStatusLabel *label) {
    if (!enabled || !pillTwoLines || !label.tlt_pill || !label.tlt_managed) return;
    for (UIView *v in label.superview.subviews) {
        if (!isPillView(v)) continue;
        if (label.center.x < CGRectGetMinX(v.frame) || label.center.x > CGRectGetMaxX(v.frame)) continue;
        CGFloat dy = label.center.y + label.transform.ty - v.center.y; // where the text is drawn, relative to the pill
        // The pill also shows the recording icon, and then the label is still there but hidden: the pill must stay put
        // for the icon, and follow the text as it fades in or out.
        dy *= label.hidden ? 0 : label.alpha;
        if (fabs(v.transform.ty - dy) > 0.1) {
            TLTLog(@"pill %p frame %@: text centre y %.1f (label %.1f + shift %.1f), pill centre %.1f -> pill moves %.1f pt", v, NSStringFromCGRect(v.frame),
                   label.center.y + label.transform.ty, label.center.y, label.transform.ty, v.center.y, dy);
            v.transform = CGAffineTransformMakeTranslation(0, dy);
        }
        return;
    }
}

// Height of a pill that holds two lines (a fixed value: the pill is clipped by the top of the screen, so a taller one
// would not show). The text gets that minus some padding.
#define kPillHeight 30.0
#define kPillPadding 3.0

CGFloat pillHeightScale(TLTStatusLabel *label) {
    CGFloat height = 0;
    if (line1Text(label, [NSDate date]).length) height += line1Font(label, 1).lineHeight;
    if (lines[1].formatter) {
        UIFont *font = lineFont(lines[1], 1);
        height += height > 0 ? font.ascender + 1 : font.lineHeight; // the tight line height lineString uses under line 1
    }
    CGFloat room = kPillHeight - kPillPadding;
    return height > room ? MAX(0.4, room / height) : 1;
}

// Back to its own place when two lines in the pill are off (or the pill holds the recording icon, with no text to follow)
void pillDidLayout(UIView *pill) {
    BOOL follows = NO;
    if (enabled && pillTwoLines) {
        for (UIView *v in pill.superview.subviews) {
            if (![v isKindOfClass:UILabel.class] || ![v respondsToSelector:@selector(tlt_pill)] || !((TLTStatusLabel *)v).tlt_pill) continue;
            alignPill((TLTStatusLabel *)v);
            follows = YES;
        }
    }
    if (!follows && pill.transform.ty != 0) pill.transform = CGAffineTransformIdentity;
}

// The status bar's visual provider (one class per screen width) decides how big the pill is. Two lines do not fit
// the stock ~21 pt, so make it taller while the pill holds two lines (it never gets smaller than iOS wants).

CGSize tallerPill(id provider, CGSize size) {
    if (enabled && pillTwoLines && !isDynamicProvider(provider) && size.height < kPillHeight) size.height = kPillHeight;
    return size;
}

// The provider classes are not hard-coded: every class named ..VisualProvider_..Split.. that implements pillSize itself is
// found at startup and hooked, so a screen width this tweak has never heard of is covered too. A %hook cannot do this
// (Logos needs the class name at compile time), hence MSHookMessageEx and one saved original per class.
static NSMutableDictionary<NSValue *, NSValue *> *pillSizeOriginals;

static CGSize hookedPillSize(id self, SEL _cmd) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSValue *saved = pillSizeOriginals[[NSValue valueWithPointer:(__bridge void *)c]];
        if (saved) return tallerPill(self, ((CGSize (*)(id, SEL))saved.pointerValue)(self, _cmd));
    }
    return CGSizeZero;
}

void TLTHookPillProviders(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pillSizeOriginals = [NSMutableDictionary dictionary]; });
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = all[i];
        const char *name = class_getName(cls);
        const char *provider = strstr(name, "StatusBarVisualProvider_");
        if (!provider || !strstr(provider, "Split") || (strncmp(name, "_UI", 3) && strncmp(name, "STUI", 4))) continue;
        NSValue *key = [NSValue valueWithPointer:(__bridge void *)cls];
        if (pillSizeOriginals[key]) continue;
        // only a pillSize the class defines itself; subclasses without one reach a hooked ancestor
        BOOL own = NO;
        unsigned int n = 0;
        Method *methods = class_copyMethodList(cls, &n);
        for (unsigned int m = 0; m < n; m++) own |= method_getName(methods[m]) == @selector(pillSize);
        free(methods);
        if (!own) continue;
        IMP orig = NULL;
        MSHookMessageEx(cls, @selector(pillSize), (IMP)hookedPillSize, &orig);
        if (orig) {
            pillSizeOriginals[key] = [NSValue valueWithPointer:(void *)orig];
            TLTLog(@"hooked pillSize of %s", name);
        }
    }
    free(all);
}
