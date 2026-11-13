#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../TLTLog.h"
#include <sys/utsname.h>

#define TLTLogCopyMaxBytes (200 * 1024)

@interface TLTRootListController : PSListController <UIGestureRecognizerDelegate>
@end

@implementation TLTRootListController {
    NSMutableDictionary<NSString *, PSSpecifier *> *_customRows; // "format1"/"format2" -> its Custom format row
}

static NSString *const kSuite = @"com.qn.twolinetime";

// The number pad has no Return key: let a tap outside the field, or a scroll, dismiss the keyboard
- (void)viewDidLoad {
    [super viewDidLoad];
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    tap.delegate = self;
    [self.table addGestureRecognizer:tap];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:UITextField.class]; // tapping another field must still focus it
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        _customRows = [NSMutableDictionary new];

        // On: Face ID iPhones (notch / Dynamic Island). Touch ID iPhones: off by default, and say why.
        BOOL faceID = TLTDeviceHasFaceID();
        PSSpecifier *enabledRow = [self listSpecifierForKey:@"enabled"];
        [enabledRow setProperty:@(faceID) forKey:@"default"];
        if (!faceID && _specifiers.count) {
            [(PSSpecifier *)_specifiers[0] setProperty:@"This device has no Face ID: TwoLineTime is made for iPhones with a notch or the Dynamic Island, so it is off by default here. Settings apply on the next status bar update. Respring if nothing changes." forKey:@"footerText"];
        }
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
        for (NSString *key in @[@"format1", @"format2"]) {
            PSSpecifier *custom = [self specifierForID:[key stringByAppendingString:@"Custom"]];
            if (!custom) continue;
            _customRows[key] = custom;
            // the Custom format row only shows while Custom is selected
            id value = [prefs objectForKey:key];
            if (![value isEqual:@"custom"]) [_specifiers removeObject:custom];
        }
    }
    return _specifiers;
}

- (PSSpecifier *)listSpecifierForKey:(NSString *)key {
    for (PSSpecifier *s in _specifiers) {
        if ([[s propertyForKey:@"key"] isEqual:key]) return s;
    }
    return nil;
}

// Show the Custom format row only while Custom is selected
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    PSSpecifier *custom = _customRows[key];
    if (!custom || specifier == custom) return;
    BOOL wanted = [value isEqual:@"custom"];
    BOOL shown = [self.specifiers containsObject:custom];
    if (wanted && !shown) [self insertSpecifier:custom afterSpecifier:specifier animated:YES];
    else if (!wanted && shown) [self removeSpecifier:custom animated:YES];
}

- (void)respring {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.qn.twolinetime/respring"), NULL, NULL, YES);
}

- (NSString *)tweakVersion:(PSSpecifier *)specifier {
    return @TLT_VERSION;
}

- (void)openURLString:(NSString *)string {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:string] options:@{} completionHandler:nil];
}

- (void)openSourceCode:(PSSpecifier *)specifier {
    [self openURLString:@"https://github.com/qnblackcat/TwoLineTime"];
}

- (void)openTwitter:(PSSpecifier *)specifier {
    [self openURLString:@"https://x.com/t70438299"];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyDebugLog {
    NSString *log = TLTLogFileRead(TLTLogCopyMaxBytes);
    if (!log.length) {
        [self showAlertWithTitle:@"Debug log is empty" message:@"Turn on Debug, then wait for the status bar to update."];
        return;
    }
    struct utsname system;
    uname(&system);
    NSString *header = [NSString stringWithFormat:@"TwoLineTime debug log, iOS %@, %s\n", [UIDevice currentDevice].systemVersion, system.machine];
    [UIPasteboard generalPasteboard].string = [header stringByAppendingString:log];
    [self showAlertWithTitle:@"Copied" message:[NSString stringWithFormat:@"%lu KB of debug log copied to the clipboard.", (unsigned long)(log.length / 1024 + 1)]];
}

- (void)clearDebugLog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear debug log?" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        TLTLogFileClear();
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
