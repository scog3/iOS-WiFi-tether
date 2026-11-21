/*
 * iOS's "Personal Hotspot" indicator (included by bar.m; SpringBoard
 * only).
 *
 * SpringBoard shows the indicator from its telephony manager's tethering
 * state (-[SBTelephonyManager isNetworkTethering] and
 * numberOfNetworkTetheredDevices), which the phone's cellular service
 * (CommCenter) sets through -_setIsNetworkTethering:withNumberOfDevices:.
 * When the hotspot shares Wi-Fi instead (no SIM, or no mobile data), the
 * cellular service never says it's tethering, so the indicator never shows,
 * although iOS's hotspot service (misd) counts the computer as connected.
 *
 * wifitetherd posts misd's count (Darwin notification com.wifitether.hotspot,
 * state = devices connected; 0 while the indicator is switched off in the
 * app's Settings, which takes it away at once). This wraps that setter so the state SpringBoard
 * keeps says "tethering" when either the cellular service or the hotspot
 * service does, with the larger count; calls it again when the count changes;
 * then asks the status bar to update (-[SBStatusBarStateAggregator
 * _updateTetheringState]). Nothing else changes: the indicator is iOS's own.
 * If the setter isn't there with the expected arguments (another iOS
 * version), it does nothing.
 *
 * What it did is noted in /var/mobile/Library/WiFiTether/springboard.log
 * (included in the app's "Share log file…").
 */
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>

#define WT_HOTSPOT_NOTIFY "com.wifitether.hotspot"
#define WT_SB_LOG         "/var/mobile/Library/WiFiTether/springboard.log"

static SEL       g_tetherSel;
static IMP       g_origTether;      /* -[SBTelephonyManager _setIsNetworkTethering:withNumberOfDevices:] */
static BOOL      g_tetherWide;      /* the count is 64-bit (else 32-bit) */
static BOOL      g_ctTether;        /* what the cellular service last said */
static long long g_ctCount;
static long long g_hsCount;         /* what the hotspot service counts */
static id        g_telephony;

static void wtSBLog(NSString *fmt, ...)
{
    va_list ap;
    struct stat st;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ SpringBoard: %@\n", [f stringFromDate:[NSDate date]], msg];
    if (stat(WT_SB_LOG, &st) == 0 && st.st_size > 200000)
        rename(WT_SB_LOG, WT_SB_LOG ".old");
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@WT_SB_LOG];
    if (!h) {
        [line writeToFile:@WT_SB_LOG atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static id wtCall(id obj, NSString *name)
{
    SEL s = NSSelectorFromString(name);
    return [obj respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(obj, s) : nil;
}

static id wtTelephony(void)
{
    if (g_telephony)
        return g_telephony;
    Class c = objc_getClass("SBTelephonyManager");
    return wtCall(c, @"sharedTelephonyManager") ?: wtCall(c, @"sharedInstance")
        ?: wtCall(wtCall(objc_getClass("SBStatusBarStateAggregator"), @"sharedInstance"), @"_telephonyManager");
}

/* The cellular service's updates: kept, with the hotspot's count merged in. */
static void wtSetTethering(id self, SEL _cmd, BOOL on, long long n)
{
    if (!g_tetherWide)
        n = (int)n;
    g_telephony = self;
    g_ctTether = on;
    g_ctCount = n;
    BOOL merged = on || g_hsCount > 0;
    long long count = MAX(on ? n : 0, g_hsCount);
    ((void (*)(id, SEL, BOOL, long long))g_origTether)(self, _cmd, merged, count);
}

/* The hotspot service's count changed: tell SpringBoard, then let the status
 * bar catch up. */
static void wtHotspotApply(NSString *why)
{
    id tm = wtTelephony();
    if (!g_origTether || !tm) {
        wtSBLog(@"%@: can't reach SpringBoard's telephony manager", why);
        return;
    }
    BOOL merged = g_ctTether || g_hsCount > 0;
    long long count = MAX(g_ctTether ? g_ctCount : 0, g_hsCount);
    ((void (*)(id, SEL, BOOL, long long))g_origTether)(tm, g_tetherSel, merged, count);

    id agg = wtCall(objc_getClass("SBStatusBarStateAggregator"), @"sharedInstance");
    SEL upd = NSSelectorFromString(@"_updateTetheringState");
    if ([agg respondsToSelector:upd])
        ((void (*)(id, SEL))objc_msgSend)(agg, upd);

    /* What SpringBoard now has, to check it took. */
    SEL isT = NSSelectorFromString(@"isNetworkTethering"), num = NSSelectorFromString(@"numberOfNetworkTetheredDevices");
    BOOL nowT = [tm respondsToSelector:isT] ? ((BOOL (*)(id, SEL))objc_msgSend)(tm, isT) : NO;
    long long nowN = -1;
    Method nm = class_getInstanceMethod(object_getClass(tm), num);
    if (nm) {
        char t[8] = "";
        method_getReturnType(nm, t, sizeof(t));
        nowN = strchr("iI", t[0]) ? ((int (*)(id, SEL))objc_msgSend)(tm, num)
                                  : ((long long (*)(id, SEL))objc_msgSend)(tm, num);
    }
    Ivar iv = agg ? class_getInstanceVariable(object_getClass(agg), "_tetheringStatusBarStyleOverrideAssertion") : NULL;
    NSString *shown = iv ? (object_getIvar(agg, iv) ? @"on" : @"off") : @"unknown";
    wtSBLog(@"%@: hotspot counts %lld; cellular service says %s (%lld); SpringBoard now: tethering %d, %lld "
            @"device(s), hotspot indicator %@", why, g_hsCount, g_ctTether ? "tethering" : "not tethering",
            g_ctCount, nowT, nowN, shown);
}

static void wtHotspotStart(void)
{
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])
        return;
    /* the 1.6 test builds' diagnostic files */
    unlink("/var/mobile/Library/WiFiTether/springboard-diag.txt");
    unlink("/var/mobile/Library/WiFiTether/springboard-diag.running");

    Class c = objc_getClass("SBTelephonyManager");
    g_tetherSel = NSSelectorFromString(@"_setIsNetworkTethering:withNumberOfDevices:");
    Method m = c ? class_getInstanceMethod(c, g_tetherSel) : NULL;
    char ret[8] = "", a[8] = "", b[8] = "";
    if (m && method_getNumberOfArguments(m) == 4) {
        method_getReturnType(m, ret, sizeof(ret));
        method_getArgumentType(m, 2, a, sizeof(a));
        method_getArgumentType(m, 3, b, sizeof(b));
    }
    if (!(ret[0] == 'v' && strchr("Bc", a[0]) && a[0] && strchr("iIqQlL", b[0]) && b[0])) {
        wtSBLog(@"hotspot indicator: SBTelephonyManager's tethering setter isn't here as expected "
                @"(%s); leaving it alone", m ? method_getTypeEncoding(m) : "missing");
        return;
    }
    g_tetherWide = strchr("qQlL", b[0]) != NULL;
    g_origTether = method_setImplementation(m, (IMP)wtSetTethering);

    int tok;
    uint64_t st = 0;
    if (notify_register_dispatch(WT_HOTSPOT_NOTIFY, &tok, dispatch_get_main_queue(), ^(int t) {
            uint64_t s = 0;
            notify_get_state(t, &s);
            if ((long long)s == g_hsCount)
                return;
            g_hsCount = (long long)s;
            @try {
                wtHotspotApply(@"hotspot changed");
            } @catch (NSException *e) {
            }
        }) != NOTIFY_STATUS_OK)
        return;
    notify_get_state(tok, &st);
    g_hsCount = (long long)st;
    wtSBLog(@"hotspot indicator: ready (%s); hotspot counts %lld", method_getTypeEncoding(m), g_hsCount);
    if (g_hsCount > 0)   /* already connected (a respring while sharing) */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            @try {
                wtHotspotApply(@"SpringBoard started");
            } @catch (NSException *e) {
            }
        });
}
