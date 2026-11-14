#import "TLTShared.h"

static BOOL applying;
static NSTimer *ticker;
static NSHashTable<TLTStatusLabel *> *managedLabels; // labels to refresh every second (weak)
static int blankedToken = NOTIFY_TOKEN_INVALID;
BOOL settingTransform;

void TLTRenderInit(void) {
    managedLabels = [NSHashTable weakObjectsHashTable];
    notify_register_check(kBlanked, &blankedToken);
}

static UIFont *fontOfSize(TLTLine *line, CGFloat size) {
    UIFont *font = [UIFont systemFontOfSize:size weight:line.bold ? UIFontWeightBold : UIFontWeightRegular];
    if (line.italic) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitItalic];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:size];
    }
    return font;
}

UIFont *lineFont(TLTLine *line, CGFloat scale) {
    return fontOfSize(line, line.size * scale);
}

// Line 1 alone (line 2 hidden) keeps iOS's own size; our size only applies when there are two lines to fit
static CGFloat line1Size(TLTStatusLabel *label) {
    return (!lines[1].formatter && label.tlt_origSize) ? label.tlt_origSize.doubleValue : lines[0].size;
}

UIFont *line1Font(TLTStatusLabel *label, CGFloat scale) {
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
NSString *line1Text(TLTStatusLabel *label, NSDate *now) {
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

void applyTo(TLTStatusLabel *label) {
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
    alignPill(label);
}

// iOS updates the status bar clock once a minute, so seconds (and the blinking colon) only run if we refresh the label
// ourselves. Only while a format shows seconds or the colon blinks, and the screen is on; an NSTimer is not user activity and does not touch Auto-Lock.
static BOOL screenIsOn(void) {
    uint64_t blanked = 0;
    if (blankedToken != NOTIFY_TOKEN_INVALID) notify_get_state(blankedToken, &blanked);
    return blanked == 0;
}

// Rebuild the text of every label we manage (the clock moved on, or a setting changed)
void refreshLabels(void) {
    for (TLTStatusLabel *label in managedLabels.allObjects) {
        if (enabled) {
            applying = YES;
            applyTo(label);
            applying = NO;
        }
        [label setNeedsLayout];
    }
}

// Move every managed label to its place again (the breadcrumb came or went)
void realignLabels(void) {
    for (TLTStatusLabel *label in managedLabels.allObjects) {
        alignVertically(label);
        [label setNeedsLayout];
    }
}

void updateTicker(void) {
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

// The status bar re-styles the label (applyStyleAttributes: -> setFont: 15.5) whenever it likes, and UILabel applies
// that font over our whole attributed string: the text jumps back to the big system size until the next minute.
// So put our text back right after each restyle. applyTo only sets attributedText, so this cannot loop.
void labelDidSetFont(TLTStatusLabel *label) {
    if (enabled && !applying && label.tlt_managed) {
        applying = YES;
        applyTo(label);
        applying = NO;
    }
}

// Some status bars (e.g. the Dynamic Island ones) align the label by the baseline of its LAST line: our two lines then
// sit one line higher than the single iOS line did. Move the block down so its middle is where the iOS text's middle was.
void alignVertically(TLTStatusLabel *label) {
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
            if (label.tlt_pill && pillTwoLines) dy += kPillDrop; // the pill follows the text (alignPill)
            // manual; ignored while a breadcrumb is on screen: the user's offset was set for the bar without it, and
            // would push the second line onto the breadcrumb
            if (!breadcrumbVisible) dy += offsetY;
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
// were given (never below half size; a pill may go lower, down to 0.4, to fit its height). Only for labels we rewrote.
void labelDidLayout(TLTStatusLabel *label) {
    alignVertically(label);
    alignPill(label);
    if (!enabled || !label.tlt_managed) return;
    CGFloat available = label.bounds.size.width;
    CGFloat needed = neededWidth(label);
    if (available <= 0 || needed <= 0) return;

    CGFloat current = label.tlt_scale ? label.tlt_scale.doubleValue : 1;
    CGFloat scale;
    if (needed <= available) scale = 1;                    // full size fits
    else if (needed * current <= available + 0.5 && !label.tlt_pill) return;  // already shrunk enough; don't chase our own shrinking
    else scale = MAX(0.5, available / needed);
    if (label.tlt_pill) {
        scale = MIN(scale, pillHeightScale(label));
        TLTLog(@"pill label %p: superview %@ %@, bounds %@, height scale %.2f", label, label.superview.class,
               NSStringFromCGRect(label.superview.bounds), NSStringFromCGRect(label.bounds), scale);
    }
    if (fabs(scale - current) < 0.01) return;

    TLTLog(@"layout: width %.1f, needs %.1f, scale %.2f", available, needed, scale);
    label.tlt_scale = @(scale);
    applyTo(label);
}

void timeItemDidUpdate(id displayItem, Class timeItemClass, Class stringViewClass) {
    TLTDisplayItem *item = displayItem;
    UIView *view = item.view;
    BOOL isString = [view isKindOfClass:stringViewClass];
    // dateView is the Lock Screen / Control Center date. pillTimeView sits inside the coloured pill (screen recording,
    // call...), which is too short for two full-size lines: with "pillTwoLines" the fonts shrink to its height
    BOOL canGrow = pillCanGrow(item); // asked for every clock update, not only a pill's: the preferences learn the answer early
    BOOL isPill = canGrow && [item.identifier isEqual:[(id)timeItemClass pillTimeDisplayIdentifier]];
    BOOL isAnyPill = [item.identifier isEqual:[(id)timeItemClass pillTimeDisplayIdentifier]];
    BOOL skip = [item.identifier isEqual:[(id)timeItemClass dateDisplayIdentifier]] || (isAnyPill && !(isPill && pillTwoLines)); // a pill we cannot grow keeps iOS's clock
    TLTLog(@"time item update: id=%@ view=%@ string=%d skip=%d enabled=%d", item.identifier, view.class, isString, skip, enabled);
    if (!isString) return;

    TLTStatusLabel *label = (TLTStatusLabel *)view;
    label.tlt_pill = isPill;
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

// The screen turned on or off: start or stop the ticker, and catch up right away after waking
void TLTScreenChanged(void) {
    TLTLog(@"screen %@", screenIsOn() ? @"on" : @"off");
    updateTicker();
    if (ticker) refreshLabels();
}
