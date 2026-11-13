#import <UIKit/UIKit.h>
#import <notify.h>
#import "TLTLog.h"

#define kDomain    @"com.qn.twolinetime"
#define kReloadKey CFSTR("com.qn.twolinetime/settingschanged")
#define kRespring  CFSTR("com.qn.twolinetime/respring")
#define kBlanked   "com.apple.springboard.hasBlankedScreen"

// State we keep on the status bar's string label (%property avoids hand-rolled associated objects). Two status bar
// stacks exist and both need it: UIKit's _UIStatusBar* (apps, and SpringBoard on iOS 15/16) and SystemStatusUI's
// STUIStatusBar* (SpringBoard on newer iOS, e.g. iOS 17 with the Dynamic Island).
@protocol TLTLabel <NSObject>
@property (nonatomic, assign) BOOL tlt_managed;     // we rewrote this label
@property (nonatomic, strong) NSNumber *tlt_scale;  // font scale needed to fit the width the status bar gave it (nil = 1)
@property (nonatomic, copy) NSString *tlt_orig;     // the time text iOS drew, for "iOS default" on line 1
@property (nonatomic, copy) NSString *tlt_last;     // the text we last put on the label, to tell it from iOS's
@property (nonatomic, strong) NSNumber *tlt_origCap; // cap height of the font iOS gave the label
@property (nonatomic, strong) NSNumber *tlt_origSize; // point size of iOS's own font
@property (nonatomic, strong) NSNumber *tlt_dy;      // vertical shift we applied to the label (nil = none)
@end

@interface UILabel (TLTBaseline)
- (BOOL)prefersBaselineAlignment; // _UIStatusBarStringView / STUIStatusBarStringView
@end
typedef UILabel<TLTLabel> TLTStatusLabel;

@interface _UIStatusBarStringView : UILabel <TLTLabel>
@end
@interface STUIStatusBarStringView : UILabel <TLTLabel>
@end

// What the display items and time items of both stacks answer to
@interface TLTDisplayItem : NSObject
@property (nonatomic, readonly) id identifier;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) id item;
@end
@interface TLTTimeItem : NSObject
+ (id)dateDisplayIdentifier;
+ (id)pillTimeDisplayIdentifier;
@end

@interface FBSystemService : NSObject
+ (instancetype)sharedInstance;
- (void)exitAndRelaunch:(BOOL)relaunch;
@end

// Settings of one line
@interface TLTLine : NSObject
@property (nonatomic, strong) NSDateFormatter *formatter; // nil: nothing of ours on this line
@property (nonatomic, assign) CGFloat size;
@property (nonatomic, assign) BOOL bold, italic;
@property (nonatomic, assign) BOOL blink;   // line 1 only: hide the colons on odd seconds
@property (nonatomic, assign) BOOL seconds; // the format shows seconds, so the label must be refreshed every second
@end
@implementation TLTLine
@end

static BOOL enabled = YES;
static BOOL hideFocus = NO; // hide the Focus indicator (Do Not Disturb, Sleep, Work...)
static BOOL iosLine1 = YES; // line 1 stays whatever iOS draws
static CGFloat offsetY = 0; // manual vertical offset, added to the automatic position
static NSArray<TLTLine *> *lines; // [line 1, line 2]
static BOOL applying;
static NSTimer *ticker;
static NSHashTable<TLTStatusLabel *> *managedLabels; // labels to refresh every second (weak)
static int blankedToken = NOTIFY_TOKEN_INVALID;

static NSDateFormatter *makeFormatter(NSString *format) {
    if (!format.length) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = format;
    return f;
}

static UIFont *fontOfSize(TLTLine *line, CGFloat size) {
    UIFont *font = [UIFont systemFontOfSize:size weight:line.bold ? UIFontWeightBold : UIFontWeightRegular];
    if (line.italic) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitItalic];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:size];
    }
    return font;
}

static UIFont *lineFont(TLTLine *line, CGFloat scale) {
    return fontOfSize(line, line.size * scale);
}

// Line 1 alone (line 2 hidden) keeps iOS's own size; our size only applies when there are two lines to fit
static CGFloat line1Size(TLTStatusLabel *label) {
    return (!lines[1].formatter && label.tlt_origSize) ? label.tlt_origSize.doubleValue : lines[0].size;
}

static UIFont *line1Font(TLTStatusLabel *label, CGFloat scale) {
    return fontOfSize(lines[0], line1Size(label) * scale);
}

static NSAttributedString *lineString(NSString *text, UIFont *font, BOOL tight, BOOL hideColons) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    // one line per format: never wrap into a hidden third line; the status bar label shrinks the font to fit
    style.lineBreakMode = NSLineBreakByClipping;
    if (tight) style.maximumLineHeight = font.ascender + 1;
    NSDictionary *attributes = @{NSFontAttributeName: font, NSParagraphStyleAttributeName: style};
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:text attributes:attributes];
    if (hideColons) {
        // invisible instead of removed: the width stays the same, so the time does not jump every second
        for (NSUInteger i = 0; i < text.length; i++) {
            if ([text characterAtIndex:i] == ':') [result addAttribute:NSForegroundColorAttributeName value:UIColor.clearColor range:NSMakeRange(i, 1)];
        }
    }
    return result;
}

// Text of line 1: our format, or what iOS drew
static NSString *line1Text(TLTStatusLabel *label, NSDate *now) {
    NSDateFormatter *formatter = lines[0].formatter;
    if (formatter) return [formatter stringFromDate:now];
    return iosLine1 ? label.tlt_orig : nil;
}

// Width of the widest line at full size
static CGFloat neededWidth(TLTStatusLabel *label) {
    NSDate *now = [NSDate date];
    CGFloat width = 0;
    NSString *first = line1Text(label, now);
    if (first) width = [first sizeWithAttributes:@{NSFontAttributeName: line1Font(label, 1)}].width;
    if (lines[1].formatter) {
        CGFloat w = [[lines[1].formatter stringFromDate:now] sizeWithAttributes:@{NSFontAttributeName: lineFont(lines[1], 1)}].width;
        if (w > width) width = w;
    }
    return width;
}

static void alignVertically(TLTStatusLabel *label);
static BOOL settingTransform; // our own setTransform: call

static void applyTo(TLTStatusLabel *label) {
    NSDate *now = [NSDate date];
    CGFloat scale = label.tlt_scale ? label.tlt_scale.doubleValue : 1;
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSInteger count = 0;

    NSString *first = line1Text(label, now);
    if (first.length) {
        [result appendAttributedString:lineString(first, line1Font(label, scale), NO, lines[0].blink && (long)floor(now.timeIntervalSince1970) % 2 == 1)];
        count++;
    }
    if (lines[1].formatter) {
        NSString *text = [lines[1].formatter stringFromDate:now];
        if (count) text = [@"\n" stringByAppendingString:text];
        // the tight line height only makes sense under another line; alone it clips the glyphs
        [result appendAttributedString:lineString(text, lineFont(lines[1], scale), count, NO)];
        count++;
    }
    if (!count || (iosLine1 && !lines[0].blink && !lines[0].formatter && !lines[1].formatter)) {
        TLTLog(@"nothing to change, leaving the label to iOS");
        return;
    }

    TLTLog(@"applied %ld line(s) at scale %.2f: %@", (long)count, scale, [result.string stringByReplacingOccurrencesOfString:@"\n" withString:@" / "]);
    label.numberOfLines = count;
    label.attributedText = result;
    label.tlt_managed = YES;
    [managedLabels addObject:label];
    label.tlt_last = result.string;
    alignVertically(label); // a new label may not be laid out again after this, so do not wait for layoutSubviews
}

// iOS updates the status bar clock once a minute, so seconds (and the blinking colon) only run if we refresh the label
// ourselves. Only while a format shows seconds or the colon blinks, and the screen is on; an NSTimer is not user activity and does not touch Auto-Lock.
static BOOL formatHasSeconds(NSString *format) {
    BOOL quoted = NO;
    for (NSUInteger i = 0; i < format.length; i++) {
        unichar c = [format characterAtIndex:i];
        if (c == '\'') quoted = !quoted;
        else if (c == 's' && !quoted) return YES;
    }
    return NO;
}

static BOOL screenIsOn(void) {
    uint64_t blanked = 0;
    if (blankedToken != NOTIFY_TOKEN_INVALID) notify_get_state(blankedToken, &blanked);
    return blanked == 0;
}

// Rebuild the text of every label we manage (the clock moved on, or a setting changed)
static void refreshLabels(void) {
    for (TLTStatusLabel *label in managedLabels.allObjects) {
        if (enabled) {
            applying = YES;
            applyTo(label);
            applying = NO;
        }
        [label setNeedsLayout];
    }
}

static void updateTicker(void) {
    BOOL want = enabled && (lines[0].seconds || lines[1].seconds || lines[0].blink) && screenIsOn();
    if (want && !ticker) {
        NSDate *start = [NSDate dateWithTimeIntervalSince1970:ceil([NSDate date].timeIntervalSince1970)]; // on the second
        ticker = [[NSTimer alloc] initWithFireDate:start interval:1 repeats:YES block:^(NSTimer *timer) { refreshLabels(); }];
        ticker.tolerance = 0.05;
        [[NSRunLoop mainRunLoop] addTimer:ticker forMode:NSRunLoopCommonModes];
        TLTLog(@"ticker started");
    } else if (!want && ticker) {
        [ticker invalidate];
        ticker = nil;
        TLTLog(@"ticker stopped");
    }
}

static TLTLine *loadLine(NSUserDefaults *prefs, NSString *n, NSString *format, CGFloat defaultSize, BOOL defaultBold) {
    id value;
    TLTLine *line = [TLTLine new];
    line.formatter = makeFormatter(format);
    line.seconds = formatHasSeconds(format);
    line.size = (value = [prefs objectForKey:[@"size" stringByAppendingString:n]]) ? [value doubleValue] : defaultSize;
    if (line.size < 1) line.size = defaultSize;
    line.bold = (value = [prefs objectForKey:[@"bold" stringByAppendingString:n]]) ? [value boolValue] : defaultBold;
    line.italic = (value = [prefs objectForKey:[@"italic" stringByAppendingString:n]]) ? [value boolValue] : NO;
    return line;
}

static void loadSettings(void) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id value;

    // The tweak is made for Face ID iPhones (notch or Dynamic Island): off by default elsewhere, still switchable
    enabled = (value = [prefs objectForKey:@"enabled"]) ? [value boolValue] : TLTDeviceHasFaceID();
    NSString *format1 = [(value = [prefs objectForKey:@"format1"]) isKindOfClass:NSString.class] ? value : @"ios";
    NSString *format2 = [(value = [prefs objectForKey:@"format2"]) isKindOfClass:NSString.class] ? value : @"E MM/dd";
    // "custom" takes the typed format; "ios" (line 1) and "none" (line 2) mean no formatter of ours
    if ([format1 isEqual:@"custom"]) format1 = [(value = [prefs objectForKey:@"format1Custom"]) isKindOfClass:NSString.class] ? value : @"";
    if ([format2 isEqual:@"custom"]) format2 = [(value = [prefs objectForKey:@"format2Custom"]) isKindOfClass:NSString.class] ? value : @"";
    iosLine1 = [format1 isEqual:@"ios"] || !format1.length;
    if (iosLine1) format1 = @"";
    if ([format2 isEqual:@"none"]) format2 = @"";
    hideFocus = (value = [prefs objectForKey:@"hideFocus"]) ? [value boolValue] : NO;
    offsetY = (value = [prefs objectForKey:@"offset"]) ? [value doubleValue] : 0;
    TLTDebugOn = (value = [prefs objectForKey:@"debug"]) ? [value boolValue] : NO;

    lines = @[loadLine(prefs, @"1", format1, 12, YES), loadLine(prefs, @"2", format2, 12, YES)];
    // with seconds on line 1 the seconds already move, a blinking colon on top would only be noise
    lines[0].blink = ((value = [prefs objectForKey:@"blink1"]) ? [value boolValue] : NO) && !lines[0].seconds;
    updateTicker();
    TLTLog(@"settings: enabled=%d format1='%@' size1=%g format2='%@' size2=%g",
           enabled, format1, lines[0].size, format2, lines[1].size);
}

// The status bar re-styles the label (applyStyleAttributes: -> setFont: 15.5) whenever it likes, and UILabel applies
// that font over our whole attributed string: the text jumps back to the big system size until the next minute.
// So put our text back right after each restyle. applyTo only sets attributedText, so this cannot loop.
static void labelDidSetFont(TLTStatusLabel *label) {
    if (enabled && !applying && label.tlt_managed) {
        applying = YES;
        applyTo(label);
        applying = NO;
    }
}

// Some status bars (e.g. the Dynamic Island ones) align the label by the baseline of its LAST line: our two lines then
// sit one line higher than the single iOS line did. Move the block down so its middle is where the iOS text's middle was.
static void alignVertically(TLTStatusLabel *label) {
    CGFloat dy = 0;
    BOOL baseline = [label respondsToSelector:@selector(prefersBaselineAlignment)] && [label prefersBaselineAlignment];
    if (enabled && label.tlt_managed) {
        // only the two-line block is moved: one line (line 2 hidden) stays where iOS puts it
        if (label.numberOfLines == 2) {
            if (baseline) {
                CGFloat scale = label.tlt_scale ? label.tlt_scale.doubleValue : 1;
                UIFont *font = lineFont(lines[1], scale);
                CGFloat cap = label.tlt_origCap ? label.tlt_origCap.doubleValue : 11;
                dy = MAX(0, (font.ascender + 1 + font.capHeight - cap) / 2); // automatic
            }
            dy += offsetY; // manual
        }
    }
    if (!label.tlt_dy && dy == 0) return;
    label.tlt_dy = @(dy);
    // compare with the real transform: the status bar may have reset it behind our back
    if (fabs(label.transform.ty - dy) < 0.1) return;
    TLTLog(@"label %p vertical shift %.1f pt (baseline aligned=%d, manual offset %.1f, iOS cap %.1f, window %@)", label, dy, baseline, offsetY,
           label.tlt_origCap.doubleValue, label.window.class);
    settingTransform = YES;
    label.transform = CGAffineTransformMakeTranslation(0, dy);
    settingTransform = NO;
}

// The status bar gives the label a fixed width and clips what does not fit, so shrink both fonts to the width we
// were given (never below half size). Only for labels we rewrote.
static void labelDidLayout(TLTStatusLabel *label) {
    alignVertically(label);
    if (!enabled || !label.tlt_managed) return;
    CGFloat available = label.bounds.size.width;
    CGFloat needed = neededWidth(label);
    if (available <= 0 || needed <= 0) return;

    CGFloat current = label.tlt_scale ? label.tlt_scale.doubleValue : 1;
    CGFloat scale;
    if (needed <= available) scale = 1;                    // full size fits
    else if (needed * current <= available + 0.5) return;  // already shrunk enough; don't chase our own shrinking
    else scale = MAX(0.5, available / needed);
    if (fabs(scale - current) < 0.01) return;

    TLTLog(@"layout: width %.1f, needs %.1f, scale %.2f", available, needed, scale);
    label.tlt_scale = @(scale);
    applyTo(label);
}

static void timeItemDidUpdate(id displayItem, Class timeItemClass, Class stringViewClass) {
    TLTDisplayItem *item = displayItem;
    UIView *view = item.view;
    BOOL isString = [view isKindOfClass:stringViewClass];
    // dateView is the Lock Screen / Control Center date; pillTimeView sits inside the blue location pill, which is
    // too short for two lines
    BOOL skip = [item.identifier isEqual:[(id)timeItemClass dateDisplayIdentifier]]
             || [item.identifier isEqual:[(id)timeItemClass pillTimeDisplayIdentifier]];
    TLTLog(@"time item update: id=%@ view=%@ string=%d skip=%d enabled=%d", item.identifier, view.class, isString, skip, enabled);
    if (!isString) return;

    TLTStatusLabel *label = (TLTStatusLabel *)view;
    // remember the text iOS just drew, unless iOS left our own text on the label (a single line of ours has no newline
    // to tell it apart, so compare with what we last set)
    NSString *drawn = label.text;
    if (drawn.length && ![drawn isEqual:label.tlt_last]) {
        label.tlt_orig = drawn;
        label.tlt_origSize = @(label.font.pointSize);
        label.tlt_origCap = @(label.font.capHeight); // plain text here, so this is iOS's own font
    }
    if (enabled && !skip) applyTo(label);
}

// The location indicator next to the two-line time squeezes the status bar layout: the font grows and the indicator is
// distorted. It is always hidden: its hooks below deliberately skip %orig and return nil.

// The Focus indicator (moon, bed, briefcase...) and the short announcement when a Focus turns on or off. Optional,
// because they share the status bar with the clock and can get squeezed when the clock is wide.
// Hidden by answering "not enabled" whenever the status bar asks the display item (isEnabled). Dropping the item's
// updates instead let the icon flash for a moment when the Control Center closed and the status bar restored its state.
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
        classes[0] = %c(_UIStatusBarIndicatorQuietModeItem);
        classes[1] = %c(_UIStatusBarIndicatorQuietModeAnnounceItem);
        classes[2] = %c(STUIStatusBarIndicatorQuietModeItem);
        classes[3] = %c(STUIStatusBarIndicatorQuietModeAnnounceItem);
    });
    for (int i = 0; i < 4; i++) {
        if (classes[i] && [item isKindOfClass:classes[i]]) return YES;
    }
    return NO;
}

static BOOL hidesFocus(id displayItem) {
    if (!enabled || !hideFocus) return NO;
    id item = [(TLTDisplayItem *)displayItem item];
    if (!isFocusItem(item)) return NO;
    return !inControlCenter(item);
}

// ---- UIKit status bar ----

%hook _UIStatusBarStringView

%property (nonatomic, assign) BOOL tlt_managed;
%property (nonatomic, strong) NSNumber *tlt_scale;
%property (nonatomic, copy) NSString *tlt_orig;
%property (nonatomic, copy) NSString *tlt_last;
%property (nonatomic, strong) NSNumber *tlt_origCap;
%property (nonatomic, strong) NSNumber *tlt_origSize;
%property (nonatomic, strong) NSNumber *tlt_dy;

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
    return hidesFocus(self) ? NO : %orig;
}

%end

%hook _UIStatusBarIndicatorLocationItem

- (id)applyUpdate:(id)update toDisplayItem:(id)item {
    return nil;
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
    return hidesFocus(self) ? NO : %orig;
}

%end

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
    TLTLog(@"screen %@", screenIsOn() ? @"on" : @"off");
    updateTicker();
    if (ticker) refreshLabels(); // catch up right away after waking
}

static void respring(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    TLTLog(@"respring requested");
    [[%c(FBSystemService) sharedInstance] exitAndRelaunch:YES];
}

%ctor {
    managedLabels = [NSHashTable weakObjectsHashTable];
    notify_register_check(kBlanked, &blankedToken);
    loadSettings();
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
