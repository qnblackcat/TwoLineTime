#import <UIKit/UIKit.h>
#import <notify.h>
#import "TLTLog.h"

// Shared by Tweak.x (the hooks) and the TLT*.m files (what the hooks call). Everything here is internal to the
// dylib, so the globals and functions are hidden: no symbol of ours can clash with another tweak's.
#define TLT_HIDDEN __attribute__((visibility("hidden")))

#define kDomain    @"com.qn.twolinetime"
#define kReloadKey CFSTR("com.qn.twolinetime/settingschanged")
#define kRespring  CFSTR("com.qn.twolinetime/respring")
#define kPillSupportedKey CFSTR("pillSupported") // written by the tweak (TLTPill.m), read by the preferences
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
@property (nonatomic, assign) BOOL tlt_pill;         // the label sits in a coloured pill (screen recording, call...): short, so the text must fit its height
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

// Settings of one line
@interface TLTLine : NSObject
@property (nonatomic, strong) NSDateFormatter *formatter; // nil: nothing of ours on this line
@property (nonatomic, assign) CGFloat size;
@property (nonatomic, assign) BOOL bold, italic;
@property (nonatomic, assign) BOOL blink;   // line 1 only: hide the colons on odd seconds
@property (nonatomic, assign) BOOL seconds; // the format shows seconds, so the label must be refreshed every second
@end

// ---- TLTSettings.m: preferences ----
TLT_HIDDEN extern BOOL enabled;
TLT_HIDDEN extern BOOL hideBreadcrumb; // hide the "back to <app>" link
TLT_HIDDEN extern BOOL hideFocus;      // hide the Focus indicator (Do Not Disturb, Sleep, Work...)
TLT_HIDDEN extern BOOL pillTwoLines;   // experimental: two lines in the red/green/blue status bar pill
TLT_HIDDEN extern BOOL iosLine1;       // line 1 stays whatever iOS draws
TLT_HIDDEN extern CGFloat offsetY;     // manual vertical offset, added to the automatic position
TLT_HIDDEN extern NSArray<TLTLine *> *lines; // [line 1, line 2]
TLT_HIDDEN void loadSettings(void);

// ---- TLTRender.m: the two-line text, its size and place, the once-a-second refresh ----
TLT_HIDDEN extern BOOL settingTransform;     // our own setTransform: call
TLT_HIDDEN void TLTRenderInit(void);         // once, from the constructor
TLT_HIDDEN void TLTScreenChanged(void);      // the screen turned on or off
TLT_HIDDEN void refreshLabels(void);
TLT_HIDDEN void updateTicker(void);
TLT_HIDDEN void realignLabels(void);
TLT_HIDDEN UIFont *lineFont(TLTLine *line, CGFloat scale);
TLT_HIDDEN UIFont *line1Font(TLTStatusLabel *label, CGFloat scale);
TLT_HIDDEN NSString *line1Text(TLTStatusLabel *label, NSDate *now);
TLT_HIDDEN void applyTo(TLTStatusLabel *label);
TLT_HIDDEN void alignVertically(TLTStatusLabel *label);
TLT_HIDDEN void labelDidSetFont(TLTStatusLabel *label);
TLT_HIDDEN void labelDidLayout(TLTStatusLabel *label);
TLT_HIDDEN void timeItemDidUpdate(id displayItem, Class timeItemClass, Class stringViewClass);

// A pill holding two lines (text and pill together) sits this much lower than the clock would (points)
#define kPillDrop 5.0

// ---- TLTPill.m: the coloured pill (screen recording, call...) that replaces the clock ----
TLT_HIDDEN BOOL pillCanGrow(id displayItem); // the pill of this time item can hold two lines (not Dynamic Island)
TLT_HIDDEN CGFloat pillHeightScale(TLTStatusLabel *label); // font scale at which both lines fit the pill's height
TLT_HIDDEN void alignPill(TLTStatusLabel *label);
TLT_HIDDEN void pillDidLayout(UIView *pill);
TLT_HIDDEN void TLTHookPillProviders(void); // hook pillSize of every status bar visual provider class
TLT_HIDDEN CGSize tallerPill(id provider, CGSize size); // what the visual providers' pillSize answers

// ---- TLTFocus.m: hiding the Focus icon and the breadcrumb ----
TLT_HIDDEN BOOL hidesItem(id displayItem); // the status bar item must not show (isEnabled answers NO)
// Passes a display item's isEnabled answer through, remembering whether a breadcrumb item is on screen
TLT_HIDDEN BOOL trackBreadcrumb(id displayItem, BOOL isEnabled);
TLT_HIDDEN extern BOOL breadcrumbVisible; // a breadcrumb is on screen (never while it is hidden)
