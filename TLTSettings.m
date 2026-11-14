#import "TLTShared.h"

BOOL enabled = YES;
BOOL hideFocus = NO;
BOOL hideBreadcrumb = NO;
BOOL pillTwoLines = NO;
BOOL iosLine1 = YES;
CGFloat offsetY = 0;
NSArray<TLTLine *> *lines;

@implementation TLTLine
@end

static NSDateFormatter *makeFormatter(NSString *format) {
    if (!format.length) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = format;
    return f;
}

static BOOL formatHasSeconds(NSString *format) {
    BOOL quoted = NO;
    for (NSUInteger i = 0; i < format.length; i++) {
        unichar c = [format characterAtIndex:i];
        if (c == '\'') quoted = !quoted;
        else if (c == 's' && !quoted) return YES;
    }
    return NO;
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

void loadSettings(void) {
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
    hideBreadcrumb = (value = [prefs objectForKey:@"hideBreadcrumb"]) ? [value boolValue] : NO;
    pillTwoLines = (value = [prefs objectForKey:@"pillTwoLines"]) ? [value boolValue] : NO;
    offsetY = (value = [prefs objectForKey:@"offset"]) ? [value doubleValue] : 0;
    TLTDebugOn = (value = [prefs objectForKey:@"debug"]) ? [value boolValue] : NO;

    lines = @[loadLine(prefs, @"1", format1, 12, YES), loadLine(prefs, @"2", format2, 12, YES)];
    // with seconds on line 1 the seconds already move, a blinking colon on top would only be noise
    lines[0].blink = ((value = [prefs objectForKey:@"blink1"]) ? [value boolValue] : NO) && !lines[0].seconds;
    updateTicker();
    TLTLog(@"settings: enabled=%d format1='%@' size1=%g format2='%@' size2=%g",
           enabled, format1, lines[0].size, format2, lines[1].size);
}
