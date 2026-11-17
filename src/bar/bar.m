/*
 * WiFiTetherBar: the Wi-Fi band on the status bar's Wi-Fi icon ("2.4", "5",
 * "6"), centred over the icon. "2.4" is as wide as the icon's top arc (tip to
 * tip); "5" and "6" are bigger, most of the icon's height. The colours follow
 * the status bar's own: where its icons are white (dark bars, wallpapers, the
 * blue, green and red bars), yellow with a black outline; where they're black
 * (light bars), violet with a white outline. A small gap is cut round the
 * text so the arcs stay readable.
 *
 * Since iOS 13 every app draws its own status bar, so this add-on loads into
 * every app that uses UIKit (and SpringBoard, for the home and lock screens).
 * It keeps iOS's own icon as it is and adds one layer on top of it, plus a
 * mask for the gap. It touches nothing else:
 *   - two methods of _UIStatusBarWifiSignalView: layoutSubviews and
 *     applyStyleAttributes: (the status bar's colours changed), which still
 *     run as before; after them, the label is added or updated;
 *   - if that class or layoutSubviews isn't there (another iOS version), it
 *     does nothing at all.
 *
 * The band comes from wifitetherd, on the Darwin notification
 * com.wifitether.band: state = (label switched on ? 0x100 : 0) | band, with
 * band 2 (2.4 GHz), 5, 6, or 0 (none / not on Wi-Fi). Turning the label off
 * in the app's settings removes it everywhere at once.
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <notify.h>

#define WT_BAND_NOTIFY "com.wifitether.band"

static Class        g_cls;
static IMP          g_origLayout;        /* the class's own layoutSubviews, if it has one */
static IMP          g_origStyle;         /* and applyStyleAttributes: */
static int          g_band;              /* 0 none, 2, 5, 6 */
static int          g_show;              /* the label is switched on in the app */
static NSHashTable *g_views;             /* the Wi-Fi icons seen, to update when the band changes */
static const void  *kWTKey = &kWTKey;    /* what's drawn on an icon now */
static NSString *const kWTName = @"com.wifitether.band";

static NSString *wtText(void)
{
    if (!g_show)
        return nil;
    return g_band == 2 ? @"2.4" : g_band == 5 ? @"5" : g_band == 6 ? @"6" : nil;
}

static CALayer *wtOverlay(UIView *v)
{
    for (CALayer *l in v.layer.sublayers)
        if ([l.name isEqualToString:kWTName])
            return l;
    return nil;
}

static void wtRemove(UIView *v)
{
    CALayer *o = wtOverlay(v);
    if (!o && !objc_getAssociatedObject(v, kWTKey))
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [o removeFromSuperlayer];
    if ([v.layer.mask.name isEqualToString:kWTName])
        v.layer.mask = nil;
    [CATransaction commit];
    objc_setAssociatedObject(v, kWTKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* The letters' own outline (not the line's), relative to where the text starts
 * on its baseline (y up). */
static CGRect wtInk(NSString *text, UIFont *font)
{
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{ NSFontAttributeName: font }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGRect r = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    CFRelease(line);
    if (CGRectIsNull(r) || r.size.width <= 0) {   /* fall back to the line's width */
        CGSize s = [text sizeWithAttributes:@{ NSFontAttributeName: font }];
        r = CGRectMake(0, 0, s.width, font.capHeight);
    }
    return r;
}

/* "2.4": as wide as the icon. "5" and "6": digits 86% of the icon's height
 * (no wider than the icon). */
static UIFont *wtFont(NSString *text, CGSize icon)
{
    UIFont *ref = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    CGFloat byWidth = 10 * icon.width / wtInk(text, ref).size.width;
    CGFloat size = byWidth;
    if (text.length == 1)
        size = MIN(byWidth, 10 * icon.height * 0.86 / ref.capHeight);
    size = MIN(size, 10 * icon.height / ref.capHeight);   /* digits no taller than the icon */
    return [UIFont systemFontOfSize:MAX(5.0, round(size * 4) / 4) weight:UIFontWeightBold];
}

/* Are the status bar's icons white (dark or coloured bar) or black (light
 * bar)? From the Wi-Fi icon's own colour. */
static BOOL wtLightIcons(UIView *v)
{
    UIColor *c = nil;
    CGFloat r, g, b, a, white;
    SEL active = NSSelectorFromString(@"activeColor");   /* _UIStatusBarSignalView's bar colour */
    if ([v respondsToSelector:active])
        c = ((UIColor * (*)(id, SEL))objc_msgSend)(v, active);
    if (![c isKindOfClass:[UIColor class]])
        c = v.tintColor;
    if ([c getRed:&r green:&g blue:&b alpha:&a])
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.5;
    if ([c getWhite:&white alpha:&a])
        return white > 0.5;
    return YES;
}

/* Draws the label (and the mask that cuts the gap) for this icon's size. */
static void wtApply(UIView *v)
{
    NSString *text = wtText();
    CGRect b = v.bounds;

    if (!text || b.size.width < 6 || b.size.height < 6) {
        wtRemove(v);
        return;
    }
    if (v.layer.mask && ![v.layer.mask.name isEqualToString:kWTName]) {
        wtRemove(v);   /* iOS masks the icon itself: leave it alone */
        return;
    }
    CGFloat scale = v.window.screen.scale > 0 ? v.window.screen.scale : UIScreen.mainScreen.scale;
    BOOL light = wtLightIcons(v);
    NSString *key = [NSString stringWithFormat:@"%@|%.2f|%.2f|%.1f|%d", text, b.size.width, b.size.height, scale, light];
    if ([objc_getAssociatedObject(v, kWTKey) isEqualToString:key] && wtOverlay(v))
        return;

    /* Centred on the icon, digits halfway up it. White icons: yellow, black
     * outline. Black icons: violet, white outline. */
    UIFont *font = wtFont(text, b.size);
    UIColor *textColor = light ? [UIColor colorWithRed:1.0 green:0.839 blue:0.039 alpha:1.0]
                               : [UIColor colorWithRed:0.427 green:0.157 blue:0.851 alpha:1.0];
    UIColor *lineColor = light ? UIColor.blackColor : UIColor.whiteColor;
    NSDictionary *fill = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: textColor };
    CGRect ink = wtInk(text, font);
    CGFloat pad = 4;   /* the mask reaches a little past the icon, so nothing of it gets clipped */
    CGRect area = CGRectInset(b, -pad, -pad);
    CGFloat baseline = pad + b.size.height / 2 + font.capHeight / 2;
    CGPoint at = CGPointMake(pad + b.size.width / 2 - (ink.origin.x + ink.size.width / 2), baseline - font.ascender);
    /* How far the outline, and the gap cut in the arcs, reach past the letters
     * (points), as stroke widths: % of the font size, and a stroke is centred
     * on the letters' edges, so half of it is outside. */
    NSNumber *outline = @(100 * 2 * 0.4 / font.pointSize), *gap = @(100 * 2 * 0.65 / font.pointSize);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:area.size format:fmt];

    /* The text with its outline. */
    UIImage *label = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [text drawAtPoint:at withAttributes:@{ NSFontAttributeName: font,
                                               NSForegroundColorAttributeName: UIColor.clearColor,
                                               NSStrokeColorAttributeName: lineColor,
                                               NSStrokeWidthAttributeName: outline }];
        [text drawAtPoint:at withAttributes:fill];
    }];
    /* The mask: everything shows except a thin ring round the text. */
    UIImage *mask = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.blackColor setFill];
        UIRectFill(CGRectMake(0, 0, area.size.width, area.size.height));
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeClear);
        [text drawAtPoint:at withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.blackColor,
                                               NSStrokeColorAttributeName: UIColor.blackColor,
                                               NSStrokeWidthAttributeName: @(-gap.doubleValue) }];
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeNormal);
        [text drawAtPoint:at withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.blackColor,
                                               NSStrokeColorAttributeName: UIColor.blackColor,
                                               NSStrokeWidthAttributeName: @(-outline.doubleValue) }];
    }];
    if (!label.CGImage || !mask.CGImage) {
        wtRemove(v);
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer *o = wtOverlay(v);
    if (!o) {
        o = [CALayer layer];
        o.name = kWTName;
        o.zPosition = 1000;
        [v.layer addSublayer:o];
    }
    o.frame = area;
    o.contentsScale = scale;
    o.contents = (__bridge id)label.CGImage;
    CALayer *m = [CALayer layer];
    m.name = kWTName;
    m.frame = area;
    m.contentsScale = scale;
    m.contents = (__bridge id)mask.CGImage;
    v.layer.mask = m;
    [CATransaction commit];
    objc_setAssociatedObject(v, kWTKey, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void wtLayout(UIView *self, SEL _cmd)
{
    if (g_origLayout) {
        ((void (*)(UIView *, SEL))g_origLayout)(self, _cmd);
    } else {   /* the class didn't have its own: call its superclass's, as before */
        struct objc_super sup = { self, class_getSuperclass(g_cls) };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
    }
    @try {
        [g_views addObject:self];
        wtApply(self);
    } @catch (NSException *e) {
        /* never let the label break the status bar */
    }
}

/* The status bar's colours changed (light bar to dark, a blue or green bar
 * appeared...): redraw in the matching colours. */
static void wtStyle(UIView *self, SEL _cmd, id attrs)
{
    if (g_origStyle) {
        ((void (*)(UIView *, SEL, id))g_origStyle)(self, _cmd, attrs);
    } else {
        struct objc_super sup = { self, class_getSuperclass(g_cls) };
        ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, _cmd, attrs);
    }
    @try {
        if ([g_views containsObject:self])
            wtApply(self);
    } @catch (NSException *e) {
    }
}

static void wtSetState(uint64_t st)
{
    int show = (st & 0x100) != 0, band = (int)(st & 0xff);
    if (show == g_show && band == g_band)
        return;
    g_show = show;
    g_band = band;
    for (UIView *v in g_views.allObjects) {
        @try {
            wtApply(v);
        } @catch (NSException *e) {
        }
    }
}

/* Temporary, for the 1.6 test builds: why iOS's blue hotspot indicator
 * doesn't show (see diag.m). */
#include "diag.m"

__attribute__((constructor)) static void wtBarInit(void)
{
    SEL sel = @selector(layoutSubviews);
    Method m;
    int tok = -1;
    uint64_t st = 0;

    @try {
        wtDiagStart();
    } @catch (NSException *e) {
    }
    g_cls = objc_getClass("_UIStatusBarWifiSignalView");
    if (!g_cls || !(m = class_getInstanceMethod(g_cls, sel)))
        return;
    g_views = [NSHashTable weakObjectsHashTable];
    if (notify_register_dispatch(WT_BAND_NOTIFY, &tok, dispatch_get_main_queue(), ^(int t) {
            uint64_t s = 0;
            notify_get_state(t, &s);
            wtSetState(s);
        }) == NOTIFY_STATUS_OK && notify_get_state(tok, &st) == NOTIFY_STATUS_OK) {
        g_show = (st & 0x100) != 0;
        g_band = (int)(st & 0xff);
    }
    /* Only this class's own method: add one if it inherits layoutSubviews,
     * so other status bar views aren't touched. */
    if (class_addMethod(g_cls, sel, (IMP)wtLayout, method_getTypeEncoding(m)))
        g_origLayout = NULL;
    else
        g_origLayout = method_setImplementation(m, (IMP)wtLayout);

    /* Colour changes. Optional: without it the colours update at the next
     * layout instead. */
    sel = NSSelectorFromString(@"applyStyleAttributes:");
    if ((m = class_getInstanceMethod(g_cls, sel))) {
        if (class_addMethod(g_cls, sel, (IMP)wtStyle, method_getTypeEncoding(m)))
            g_origStyle = NULL;
        else
            g_origStyle = method_setImplementation(m, (IMP)wtStyle);
    }
}
