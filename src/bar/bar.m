/*
 * WiFiTetherBar: the status bar's Wi-Fi icon shows the band. In the same box
 * as iOS's own icon: three thin arcs for the signal (iOS's own level, solid
 * or dimmed the way iOS dims weak bars) over the band's number, "2.4", "5"
 * or "6", as big as fits. It's drawn in the icon's own colour, so it follows
 * the status bar (white, black, on the blue or green bars...) like the icon
 * it replaces. It stays inside the icon's box, so it can't overlap anything
 * next to it, and needs no extra room on any iPhone.
 *
 * Since iOS 13 every app draws its own status bar, so this add-on loads into
 * every app that uses UIKit (and SpringBoard, for the home and lock screens).
 * How: one layer in the icon's colour on top of iOS's own drawing, and a mask
 * on the icon in the new shape (solid where the shape is, dimmed for weak
 * bars, clear elsewhere), so what shows is exactly the new icon. It touches
 * only _UIStatusBarWifiSignalView, three methods that still run as before:
 *   - layoutSubviews (size), applyStyleAttributes: (colours), and
 *     setNumberOfActiveBars: (signal); after them the icon is updated;
 *   - if that class or layoutSubviews isn't there (another iOS version), it
 *     does nothing at all; without the other two, it updates at the next
 *     layout instead.
 * Not on Wi-Fi, band unknown, or switched off in the app: iOS's own icon.
 *
 * In SpringBoard it also makes iOS's own "Personal Hotspot" indicator
 * show while the computer is connected (hotspot.m).
 *
 * The band comes from wifitetherd, on the Darwin notification
 * com.wifitether.band: state = (switched on ? 0x100 : 0) | band, with band 2
 * (2.4 GHz), 5, 6, or 0 (none / not on Wi-Fi). Switching it off in the app's
 * settings puts iOS's icon back everywhere at once.
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <notify.h>
#include "../common/bandicon.h"   /* the icon's shape, shared with the app */

#define WT_BAND_NOTIFY "com.wifitether.band"

static Class        g_cls;
static IMP          g_origLayout;        /* the class's own layoutSubviews, if it has one */
static IMP          g_origStyle;         /* applyStyleAttributes: */
static IMP          g_origBars;          /* setNumberOfActiveBars: */
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

static id wtGet(UIView *v, NSString *name)
{
    SEL s = NSSelectorFromString(name);
    return [v respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(v, s) : nil;
}

/* iOS's signal level for the icon: 0-3. */
static int wtBars(UIView *v)
{
    SEL s = NSSelectorFromString(@"numberOfActiveBars");
    Method m = class_getInstanceMethod(object_getClass(v), s);
    char t[8] = "";
    long long n = 3;
    if (m) {
        method_getReturnType(m, t, sizeof(t));
        if (t[0] && strchr("iI", t[0]))
            n = ((int (*)(id, SEL))objc_msgSend)(v, s);
        else if (t[0] && strchr("qQlL", t[0]))
            n = ((long long (*)(id, SEL))objc_msgSend)(v, s);
    }
    return (int)MAX(0, MIN(3, n));
}

/* The icon's colour (opaque), and how strong its full and dimmed parts are. */
static UIColor *wtColors(UIView *v, CGFloat *full, CGFloat *dim)
{
    UIColor *on = wtGet(v, @"activeColor"), *off = wtGet(v, @"inactiveColor");
    CGFloat r = 1, g = 1, b = 1, a = 1, w, oa = 0;
    if (![on isKindOfClass:[UIColor class]])
        on = v.tintColor ?: UIColor.whiteColor;
    if (![on getRed:&r green:&g blue:&b alpha:&a] && [on getWhite:&w alpha:&a])
        r = g = b = w;
    if ([off isKindOfClass:[UIColor class]] && !([off getRed:&w green:&w blue:&w alpha:&oa] || [off getWhite:&w alpha:&oa]))
        oa = 0;
    *full = a > 0.05 ? a : 1;
    /* iOS dims weak bars by making them see-through; if its dim colour is
     * solid, use iOS's usual strength */
    *dim = (oa > 0.02 && oa < 0.99) ? MIN(1, oa / *full) : 0.3;
    return [UIColor colorWithRed:r green:g blue:b alpha:1];
}

/* Puts the new icon on v (or iOS's back). */
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
    CGFloat full, dim;
    UIColor *color = wtColors(v, &full, &dim);
    int bars = wtBars(v);
    CGFloat pad = 1;   /* a little room so edge pixels aren't cut */
    CGRect area = CGRectInset(b, -pad, -pad);

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
    o.backgroundColor = color.CGColor;   /* the shape comes from the mask */
    [CATransaction commit];

    NSString *key = [NSString stringWithFormat:@"%@|%.2f|%.2f|%.1f|%d|%.2f|%.2f", text, b.size.width,
                                               b.size.height, scale, bars, full, dim];
    if ([objc_getAssociatedObject(v, kWTKey) isEqualToString:key] && [v.layer.mask.name isEqualToString:kWTName])
        return;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIImage *mask = [[[UIGraphicsImageRenderer alloc] initWithSize:area.size format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            wtDrawShape(CGRectMake(pad, pad, b.size.width, b.size.height), text, bars, full, dim);
        }];
    if (!mask.CGImage) {
        wtRemove(v);
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
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
 * appeared...): follow them. */
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

/* The signal level changed. */
static void wtSetBars(UIView *self, SEL _cmd, long long n)
{
    if (g_origBars) {
        ((void (*)(UIView *, SEL, long long))g_origBars)(self, _cmd, n);
    } else {
        struct objc_super sup = { self, class_getSuperclass(g_cls) };
        ((void (*)(struct objc_super *, SEL, long long))objc_msgSendSuper)(&sup, _cmd, n);
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

/* iOS's "Personal Hotspot" indicator while the computer is connected
 * (SpringBoard only; see hotspot.m). */
#include "hotspot.m"

__attribute__((constructor)) static void wtBarInit(void)
{
    SEL sel = @selector(layoutSubviews);
    Method m;
    int tok = -1;
    uint64_t st = 0;

    @try {
        wtHotspotStart();
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

    /* Signal changes (only if it takes a 64-bit number, as expected). */
    sel = NSSelectorFromString(@"setNumberOfActiveBars:");
    char arg[8] = "";
    if ((m = class_getInstanceMethod(g_cls, sel)) && method_getNumberOfArguments(m) == 3) {
        method_getArgumentType(m, 2, arg, sizeof(arg));
        if (arg[0] && strchr("qQlL", arg[0])) {
            if (class_addMethod(g_cls, sel, (IMP)wtSetBars, method_getTypeEncoding(m)))
                g_origBars = NULL;
            else
                g_origBars = method_setImplementation(m, (IMP)wtSetBars);
        }
    }
}
