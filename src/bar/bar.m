/*
 * WiFiTetherBar: the Wi-Fi band on the status bar's Wi-Fi icon ("5", "2.4",
 * "6"), in amber with a thin dark outline, in the icon's bottom-right corner:
 * the text ends level with the icon's widest point (the tips of the top arc)
 * and overlaps the lower arcs a little, with a small gap cut round it so the
 * arcs stay readable.
 *
 * Since iOS 13 every app draws its own status bar, so this add-on loads into
 * every app that uses UIKit (and SpringBoard, for the home and lock screens).
 * It keeps iOS's own icon as it is and adds one layer on top of it, plus a
 * mask for the gap. It touches nothing else:
 *   - one method: -[_UIStatusBarWifiSignalView layoutSubviews], which still
 *     runs as before; after it, the label is added or updated;
 *   - if that class or method isn't there (another iOS version), it does
 *     nothing at all.
 *
 * The band comes from wifitetherd, on the Darwin notification
 * com.wifitether.band: state = (label switched on ? 0x100 : 0) | band, with
 * band 2 (2.4 GHz), 5, 6, or 0 (none / not on Wi-Fi). Turning the label off
 * in the app's settings removes it everywhere at once.
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <notify.h>

#define WT_BAND_NOTIFY "com.wifitether.band"

static Class        g_cls;
static IMP          g_origLayout;        /* the class's own layoutSubviews, if it has one */
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
    NSString *key = [NSString stringWithFormat:@"%@|%.2f|%.2f|%.1f", text, b.size.width, b.size.height, scale];
    if ([objc_getAssociatedObject(v, kWTKey) isEqualToString:key] && wtOverlay(v))
        return;

    /* The text: about half the icon's height, bold, ending at the icon's right
     * edge (the top arc's tips) and sitting on its base. */
    UIFont *font = [UIFont systemFontOfSize:MAX(5.0, round(b.size.height * 0.56 * 2) / 2) weight:UIFontWeightBold];
    NSDictionary *fill = @{ NSFontAttributeName: font,
                            NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.745 blue:0.0 alpha:1.0] };
    CGSize ts = [text sizeWithAttributes:fill];
    CGFloat pad = 4;   /* the mask reaches a little past the icon, so nothing of it gets clipped */
    CGRect area = CGRectInset(b, -pad, -pad);
    CGPoint at = CGPointMake(pad + b.size.width - ceil(ts.width), pad + b.size.height - 0.3 - font.ascender);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:area.size format:fmt];

    /* Amber with a thin dark outline (stroke widths are % of the font size). */
    UIImage *label = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [text drawAtPoint:at withAttributes:@{ NSFontAttributeName: font,
                                               NSForegroundColorAttributeName: UIColor.clearColor,
                                               NSStrokeColorAttributeName: [UIColor colorWithWhite:0 alpha:0.9],
                                               NSStrokeWidthAttributeName: @15 }];
        [text drawAtPoint:at withAttributes:fill];
    }];
    /* The mask: everything shows except a thin ring round the text. */
    UIImage *mask = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [UIColor.blackColor setFill];
        UIRectFill(CGRectMake(0, 0, area.size.width, area.size.height));
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeClear);
        [text drawAtPoint:at withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.blackColor,
                                               NSStrokeColorAttributeName: UIColor.blackColor,
                                               NSStrokeWidthAttributeName: @-26 }];
        CGContextSetBlendMode(ctx.CGContext, kCGBlendModeNormal);
        [text drawAtPoint:at withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.blackColor,
                                               NSStrokeColorAttributeName: UIColor.blackColor,
                                               NSStrokeWidthAttributeName: @-15 }];
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

__attribute__((constructor)) static void wtBarInit(void)
{
    SEL sel = @selector(layoutSubviews);
    Method m;
    int tok = -1;
    uint64_t st = 0;

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
}
