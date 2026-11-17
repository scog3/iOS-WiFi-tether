/*
 * Temporary diagnostic for the 1.6 test builds (included by bar.m).
 *
 * iOS's hotspot service counts the computer as connected over USB, yet iOS's
 * blue "Personal Hotspot" indicator doesn't show. The indicator is drawn by
 * SpringBoard, so this lists, from inside SpringBoard, what it has to do with
 * Personal Hotspot / tethering and the coloured status bar indicators: class,
 * method and variable names (Objective-C runtime, read only), the indicator
 * names iOS defines, and the current values in the objects that keep the
 * status bar's tethering state, each time the hotspot's connection count
 * changes (wifitetherd posts com.wifitether.hotspot).
 *
 * SpringBoard only. It only reads; the one call it makes into SpringBoard is
 * +sharedInstance on the status bar state class, which already exists there.
 * The full list is made once per install of this add-on; the values at most
 * 6 times per respring. If SpringBoard ever stopped while reading the values,
 * that part is skipped from then on. Written to
 * /var/mobile/Library/WiFiTether/springboard-diag.txt, which the app's
 * "Share log file…" includes.
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#define WT_DIAG_FILE    "/var/mobile/Library/WiFiTether/springboard-diag.txt"
#define WT_DIAG_RUNNING "/var/mobile/Library/WiFiTether/springboard-diag.running"
#define WT_HOTSPOT_NOTIFY "com.wifitether.hotspot"

static void wtDiagWrite(NSString *s)
{
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@WT_DIAG_FILE];
    if (!h) {
        [s writeToFile:@WT_DIAG_FILE atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static BOOL wtHas(const char *s, const char *const *words)
{
    for (; s && *words; words++)
        if (strcasestr(s, *words))
            return YES;
    return NO;
}

static const char *wtBase(const char *path)
{
    const char *b = path ? strrchr(path, '/') : NULL;
    return b ? b + 1 : (path ? path : "?");
}

static void wtDumpClass(NSMutableString *o, Class c)
{
    unsigned n, i;
    Class sup = class_getSuperclass(c);
    [o appendFormat:@"\n%s : %s  (%s)\n", class_getName(c), sup ? class_getName(sup) : "-", wtBase(class_getImageName(c))];
    Ivar *iv = class_copyIvarList(c, &n);
    for (i = 0; i < n; i++)
        [o appendFormat:@"  ivar %s  %s\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: ""];
    free(iv);
    objc_property_t *pr = class_copyPropertyList(c, &n);
    for (i = 0; i < n; i++)
        [o appendFormat:@"  prop %s  %s\n", property_getName(pr[i]), property_getAttributes(pr[i]) ?: ""];
    free(pr);
    Method *m = class_copyMethodList(object_getClass(c), &n);
    for (i = 0; i < n; i++)
        [o appendFormat:@"  + %s\n", sel_getName(method_getName(m[i]))];
    free(m);
    m = class_copyMethodList(c, &n);
    for (i = 0; i < n; i++)
        [o appendFormat:@"  - %s\n", sel_getName(method_getName(m[i]))];
    free(m);
}

/* The names: once per install of this add-on (the file is newer than it). */
static void wtDiagScan(void)
{
    static const char *const classWords[] = { "tether", "hotspot", "backgroundactivit", "statusbarstateaggregator",
                                              "styleoverride", "internetsharing", "MISManager", NULL };
    static const char *const selWords[] = { "tether", "hotspot", NULL };
    static const char *const consts[] = {
        "STBackgroundActivityIdentifierTethering", "STBackgroundActivityIdentifierHotspot",
        "STBackgroundActivityIdentifierPersonalHotspot", "STBackgroundActivityIdentifierInCall",
        "STBackgroundActivityIdentifierRecording", "STBackgroundActivityIdentifierNavigation",
        "STBackgroundActivityIdentifierScreenRecording", NULL };
    NSMutableString *o = [NSMutableString string];
    NSMutableString *sels = [NSMutableString string];
    unsigned count = 0, i, n, j, dumped = 0;
    Dl_info info;

    [o appendFormat:@"===== SpringBoard diagnostic: names (iOS %@, %@) =====\n",
                    UIDevice.currentDevice.systemVersion, [NSDate date]];
    for (i = 0; consts[i]; i++) {
        void *p = dlsym(RTLD_DEFAULT, consts[i]);
        if (p && dladdr(p, &info))
            [o appendFormat:@"symbol %s = %@  (%s)\n", consts[i],
                            *(__unsafe_unretained NSString **)p,
                            wtBase(info.dli_fname)];
        else
            [o appendFormat:@"symbol %s: not found\n", consts[i]];
    }

    Class *all = objc_copyClassList(&count);
    for (i = 0; i < count; i++) {
        const char *name = class_getName(all[i]);
        if (wtHas(name, classWords) && dumped < 120) {
            wtDumpClass(o, all[i]);
            dumped++;
            continue;
        }
        for (int meta = 0; meta < 2; meta++) {
            Method *m = class_copyMethodList(meta ? object_getClass(all[i]) : all[i], &n);
            for (j = 0; j < n; j++) {
                const char *s = sel_getName(method_getName(m[j]));
                if (wtHas(s, selWords))
                    [sels appendFormat:@"  %c[%s %s]  (%s)\n", meta ? '+' : '-', name, s,
                                       wtBase(class_getImageName(all[i]))];
            }
            free(m);
        }
    }
    free(all);
    [o appendFormat:@"\n----- other methods with tether/hotspot in the name (%u classes looked at) -----\n%@\n",
                    count, sels];
    wtDiagWrite(o);
}

static NSString *wtDescribe(id v)
{
    if (!v)
        return @"nil";
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]])
        return [NSString stringWithFormat:@"%@ %@", NSStringFromClass([v class]), v];
    if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *items = [NSMutableArray array];
        id each = [v isKindOfClass:[NSDictionary class]] ? [v allKeys] : v;
        for (id x in each) {
            if (items.count == 12)
                break;
            [items addObject:([x isKindOfClass:[NSString class]] || [x isKindOfClass:[NSNumber class]])
                                 ? [x description] : NSStringFromClass([x class])];
        }
        return [NSString stringWithFormat:@"%@ (%lu): %@", NSStringFromClass([v class]), (unsigned long)[v count],
                                          [items componentsJoinedByString:@", "]];
    }
    return [NSString stringWithFormat:@"<%@>", NSStringFromClass([v class])];
}

/* The current values of an object's variables (its own class and the ones
 * above it, up to NSObject). Objects are named, not asked anything. */
static void wtDumpValues(NSMutableString *o, id obj)
{
    char *base = (__bridge void *)obj;
    for (Class c = object_getClass(obj); c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(iv[i]) ?: "?";
            char *p = base + ivar_getOffset(iv[i]);
            NSString *val;
            switch (t[0]) {
            case '@': val = wtDescribe(object_getIvar(obj, iv[i])); break;
            case 'B': case 'c': val = [NSString stringWithFormat:@"%d", *(signed char *)p]; break;
            case 'C': val = [NSString stringWithFormat:@"%u", *(unsigned char *)p]; break;
            case 's': val = [NSString stringWithFormat:@"%d", *(short *)p]; break;
            case 'S': val = [NSString stringWithFormat:@"%u", *(unsigned short *)p]; break;
            case 'i': val = [NSString stringWithFormat:@"%d", *(int *)p]; break;
            case 'I': val = [NSString stringWithFormat:@"%u", *(unsigned *)p]; break;
            case 'l': case 'q': val = [NSString stringWithFormat:@"%lld", *(long long *)p]; break;
            case 'L': case 'Q': val = [NSString stringWithFormat:@"%llu", *(unsigned long long *)p]; break;
            case 'f': val = [NSString stringWithFormat:@"%g", *(float *)p]; break;
            case 'd': val = [NSString stringWithFormat:@"%g", *(double *)p]; break;
            default: val = [NSString stringWithFormat:@"(%s)", t]; break;
            }
            [o appendFormat:@"  %s.%s = %@\n", class_getName(c), ivar_getName(iv[i]), val];
        }
        free(iv);
    }
}

/* The values: the status bar state, and anything with "tether" in its name
 * that SpringBoard already keeps as a shared object. */
static void wtDiagValues(NSString *why)
{
    static int times;
    struct stat st;
    if (times >= 6)
        return;
    if (stat(WT_DIAG_RUNNING, &st) == 0) {   /* last time didn't finish: don't try again */
        if (times++ == 0)
            wtDiagWrite(@"\n(values skipped: reading them didn't finish last time)\n");
        return;
    }
    times++;
    close(open(WT_DIAG_RUNNING, O_CREAT | O_WRONLY, 0644));

    NSMutableString *o = [NSMutableString string];
    [o appendFormat:@"\n===== SpringBoard diagnostic: values (%@, %@) =====\n", why, [NSDate date]];
    for (NSString *name in @[@"SBStatusBarStateAggregator", @"SBTetheringStatusController", @"SBTetheringManager"]) {
        Class c = objc_getClass(name.UTF8String);
        SEL shared = NSSelectorFromString(@"sharedInstance");
        if (!c || !class_getClassMethod(c, shared)) {
            [o appendFormat:@"%@: %s\n", name, c ? "no shared object" : "not here"];
            continue;
        }
        id obj = ((id (*)(id, SEL))objc_msgSend)(c, shared);
        [o appendFormat:@"%@ %p:\n", name, (__bridge void *)obj];
        if (obj)
            wtDumpValues(o, obj);
    }
    wtDiagWrite(o);
    unlink(WT_DIAG_RUNNING);
}

static void wtDiagStart(void)
{
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])
        return;
    int tok;
    notify_register_dispatch(WT_HOTSPOT_NOTIFY, &tok, dispatch_get_main_queue(), ^(int t) {
        uint64_t s = 0;
        notify_get_state(t, &s);
        @try {
            wtDiagValues([NSString stringWithFormat:@"hotspot now counts %llu connected", s]);
        } @catch (NSException *e) {
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            Dl_info me;
            struct stat a, b;
            /* once per install: skip if the file is newer than this add-on */
            if (!(dladdr((const void *)wtDiagStart, &me) && stat(me.dli_fname, &a) == 0 &&
                  stat(WT_DIAG_FILE, &b) == 0 && b.st_mtime > a.st_mtime)) {
                unlink(WT_DIAG_FILE);
                @try {
                    wtDiagScan();
                } @catch (NSException *e) {
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    wtDiagValues(@"15 s after SpringBoard started");
                } @catch (NSException *e) {
                }
            });
        }
    });
}
