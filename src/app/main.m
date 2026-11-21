/*
 * WiFi Tether - the on/off switch and status screen.
 * The real work happens in the background service (wifitetherd).
 */

#include <mach/machine.h>
#include <sys/sysctl.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#include "../common/bandicon.h"   /* the band icon's shape, the same as on the status bar */
#import <objc/message.h>
#include <notify.h>
#include <dlfcn.h>

#define WT_DIR      @"/var/mobile/Library/WiFiTether"
#define WT_ENABLED  WT_DIR @"/enabled"
#define WT_STATUS   WT_DIR @"/status.plist"
#define WT_PREFER5  WT_DIR @"/prefer-5ghz"
#define WT_PREFER24 WT_DIR @"/prefer-24ghz"
#define WT_NOTIFY   "com.wifitether.changed"
#define WT_RECONNECT "com.wifitether.reconnect"   /* restarts the tries to reach the computer */
#define WT_BANDLABEL  WT_DIR @"/band-label"            /* "0": no band on the Wi-Fi icon */
#define WT_STATUSNOTE WT_DIR @"/status-notification"   /* "0": no status notification */
#define WT_SETUP      WT_DIR @"/setup-done"            /* the welcome screen has been answered */
#define WT_VPNPASS    WT_DIR @"/vpn-passthrough"       /* "0": the computer doesn't go through the VPN */
#define WT_HSIND      WT_DIR @"/hotspot-indicator"     /* "0": no Personal Hotspot indicator */
#define WT_SUMMARY    WT_DIR @"/summary.plist"         /* what it says, written by wifitetherd */
#define WT_REPO       @"https://github.com/scog3/iOS-WiFi-tether"

@interface WTViewController : UIViewController
@end

/* A12 and newer (arm64e): the band switcher's no-drop hand-over is new and
 * untested there (built for them from 1.1). */
static BOOL handoverUntested(void)
{
    cpu_subtype_t sub = 0;
    size_t n = sizeof(sub);
    if (sysctlbyname("hw.cpusubtype", &sub, &n, NULL, 0) != 0)
        return NO;
    return (sub & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

/* "iPhone", "iPad" or "iPod touch", for the texts. */
static NSString *deviceWord(void)
{
    NSString *m = UIDevice.currentDevice.model;
    return [m hasPrefix:@"iPad"] ? @"iPad" : [m hasPrefix:@"iPod"] ? @"iPod touch" : @"iPhone";
}

/* Which band the iPhone's Wi-Fi is on, from the network it's joined (MobileWiFi; needs
 * com.apple.wifi.manager-access). nil if there's no Wi-Fi or it can't tell. */
static NSString *wifiBand(void)
{
    static void *mgr;
    static CFArrayRef (*copyDevices)(void *);
    static void *(*copyCurrent)(void *);
    static CFTypeRef (*getProp)(void *, CFStringRef);
    static BOOL tried;
    NSString *band = nil;

    if (!tried) {
        void *(*create)(CFAllocatorRef, int);
        tried = YES;
        dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
        create = dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
        copyDevices = dlsym(RTLD_DEFAULT, "WiFiManagerClientCopyDevices");
        copyCurrent = dlsym(RTLD_DEFAULT, "WiFiDeviceClientCopyCurrentNetwork");
        getProp = dlsym(RTLD_DEFAULT, "WiFiNetworkGetProperty");
        if (create && copyDevices && copyCurrent && getProp)
            mgr = create(kCFAllocatorDefault, 0);
    }
    if (!mgr)
        return nil;
    CFArrayRef devs = copyDevices(mgr);
    if (!devs)
        return nil;
    void *net = CFArrayGetCount(devs) > 0 ? copyCurrent((void *)CFArrayGetValueAtIndex(devs, 0)) : NULL;
    if (net) {
        CFTypeRef ch = getProp(net, CFSTR("CHANNEL")), fl = getProp(net, CFSTR("CHANNEL_FLAGS"));
        int c = 0, f = 0;
        if (ch && CFGetTypeID(ch) == CFNumberGetTypeID())
            CFNumberGetValue(ch, kCFNumberIntType, &c);
        if (fl && CFGetTypeID(fl) == CFNumberGetTypeID())
            CFNumberGetValue(fl, kCFNumberIntType, &f);
        if (f & 0x2000)                 band = @"6 GHz";   /* 6 GHz channel numbers overlap the others */
        else if (c >= 1 && c <= 14)     band = @"2.4 GHz";
        else if (c >= 32 && c <= 177)   band = @"5 GHz";
        else if (f & 0x10)              band = @"5 GHz";
        else if (f & 0x8)               band = @"2.4 GHz";
        CFRelease(net);
    }
    CFRelease(devs);
    return band;
}

/* ── Settings ───────────────────────────────────────────────────────────── */

static void writeSetting(NSString *path, BOOL on)
{
    [[NSFileManager defaultManager] createDirectoryAtPath:WT_DIR withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    [(on ? @"1" : @"0") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    notify_post(WT_NOTIFY);
}

static BOOL bandLabelOn(void)   /* on unless switched off */
{
    NSString *s = [NSString stringWithContentsOfFile:WT_BANDLABEL encoding:NSUTF8StringEncoding error:nil];
    return s == nil || ![s hasPrefix:@"0"];
}

static BOOL hotspotIndicatorOn(void)   /* on unless switched off */
{
    NSString *s = [NSString stringWithContentsOfFile:WT_HSIND encoding:NSUTF8StringEncoding error:nil];
    return s == nil || ![s hasPrefix:@"0"];
}

static BOOL vpnPassOn(void)   /* on unless switched off */
{
    NSString *s = [NSString stringWithContentsOfFile:WT_VPNPASS encoding:NSUTF8StringEncoding error:nil];
    return s == nil || ![s hasPrefix:@"0"];
}

static BOOL statusNoteOn(void)   /* on unless switched off */
{
    NSString *s = [NSString stringWithContentsOfFile:WT_STATUSNOTE encoding:NSUTF8StringEncoding error:nil];
    return s == nil || ![s hasPrefix:@"0"];
}

/* ── The status notification ────────────────────────────────────────────
 * One quiet notification in Notification Centre (no sound, no banner) with
 * what wifitetherd writes to summary.plist: the band and the band switch on
 * the first line, sharing and VPN on the second. It's replaced in place
 * (same identifier), never added to. wifitetherd starts the app in the
 * background when the summary changes; the app updates it and quits, so the
 * next change starts it afresh. */
static NSDictionary *g_posted;   /* what's in Notification Centre, as far as this run knows */
static BOOL          g_cleared;  /* removed once in this run */

static void updateStatusNotification(void (^done)(void))
{
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    NSDictionary *sum = statusNoteOn() ? [NSDictionary dictionaryWithContentsOfFile:WT_SUMMARY] : nil;

    if (![sum[@"show"] boolValue]) {
        if (g_posted || !g_cleared) {
            [c removeDeliveredNotificationsWithIdentifiers:@[@"status"]];
            g_posted = nil;
            g_cleared = YES;
        }
        if (done)
            done();
        return;
    }
    if ([sum isEqualToDictionary:g_posted]) {
        if (done)
            done();
        return;
    }
    /* Only if notifications are already allowed. This never asks iOS: that's
     * done by the welcome screen's Continue or the switch in Settings, with
     * the app on screen (this also runs in the background, when wifitetherd
     * starts the app to update the notification). */
    [c getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *ns) {
        BOOL ok = ns.authorizationStatus == UNAuthorizationStatusAuthorized ||
                  ns.authorizationStatus == UNAuthorizationStatusProvisional;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                if (done)
                    done();
                return;
            }
            UNMutableNotificationContent *n = [UNMutableNotificationContent new];
            n.title = [sum[@"title"] description] ?: @"Tether & Band";
            n.body = [sum[@"body"] description] ?: @"";
            n.threadIdentifier = @"status";
            n.interruptionLevel = UNNotificationInterruptionLevelPassive;   /* straight to the list, quietly */
            UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:@"status" content:n trigger:nil];
            [c addNotificationRequest:r withCompletionHandler:^(NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!e) {
                        g_posted = sum;
                        g_cleared = NO;
                    }
                    if (done)
                        done();
                });
            }];
        });
    }];
}

/* ── Shared look: cards and grey section titles, like Settings ───────────── */

static UILabel *wtLabel(CGFloat size, UIFontWeight weight, UIColor *color)
{
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UIView *wtCard(NSArray<UIView *> *views)
{
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 12;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 10;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    return card;
}

static UILabel *wtHeader(NSString *text)
{
    UILabel *l = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.firstLineHeadIndent = 16;
    p.headIndent = 16;
    l.attributedText = [[NSAttributedString alloc] initWithString:text.uppercaseString attributes:@{
        NSFontAttributeName: l.font, NSForegroundColorAttributeName: l.textColor, NSParagraphStyleAttributeName: p}];
    return l;
}

/* A scrolling page of cards, at most 540 points wide (iPads), like the main screen. */
static void wtScrollPage(UIViewController *vc, UIStackView *stack)
{
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:540],
    ]];
    NSLayoutConstraint *fill = [stack.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-32];
    fill.priority = UILayoutPriorityRequired - 1;
    fill.active = YES;
}

/* A grey note under a card, lined up with the text in it. */
static UIView *wtFooter(NSString *text)
{
    UILabel *l = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    l.text = text;
    UIView *box = [UIView new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:box.topAnchor],
        [l.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [l.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [l.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
    ]];
    return box;
}

/* ── Asking for notifications ───────────────────────────────────────────
 * iOS lists the app in Settings → Notifications (Info.plist's
 * SBAppUsesLocalNotifications) and may ask "Allow notifications?" the first
 * time. Only called with the app on screen: the welcome screen's Continue,
 * and the switch in Settings. done runs on the main queue. */
static void wtAskNotifications(void (^done)(BOOL ok, NSError *error))
{
    UNUserNotificationCenter *nc = UNUserNotificationCenter.currentNotificationCenter;
    [nc requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError *error) {
        [nc getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *ns) {
            BOOL ok = granted || ns.authorizationStatus == UNAuthorizationStatusAuthorized ||
                      ns.authorizationStatus == UNAuthorizationStatusProvisional;
            dispatch_async(dispatch_get_main_queue(), ^{
                done(ok, error);
            });
        }];
    }];
}

/* Not allowed: either switched off for this app in Settings, or iOS hasn't
 * listed the app there yet (it does that when the app is installed). */
static void wtNotificationsOffAlert(UIViewController *vc, NSError *error)
{
    NSLog(@"WiFiTether: notifications not allowed (%@ %ld)", error.domain, (long)error.code);
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Notifications are off"
                         message:@"Turn on Allow Notifications in Settings → Notifications → Tether & Band, then turn "
                                 @"on Status notification again (☰ → Settings).\n\nNot in the list? Respring and try "
                                 @"again. If it's still missing, reboot userspace in your jailbreak app (Dopamine: "
                                 @"Reboot Userspace)."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) {
            NSString *url = UIApplicationOpenSettingsURLString;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
            /* iOS 15.4 and newer: straight to this app's notifications */
            if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 4, 0}] &&
                &UIApplicationOpenNotificationSettingsURLString != NULL)
                url = UIApplicationOpenNotificationSettingsURLString;
#pragma clang diagnostic pop
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:^(BOOL ok) {
                if (!ok)
                    [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]
                                                     options:@{} completionHandler:nil];
            }];
        }]];
    [vc presentViewController:a animated:YES completion:nil];
}

static NSString *appVersion(void)
{
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
}

/* GitHub builds are "1.6-87": the number after the dash is the build. */
static NSString *appBuild(void)
{
    NSString *v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    NSRange dash = [v rangeOfString:@"-" options:NSBackwardsSearch];
    return dash.location != NSNotFound ? [v substringFromIndex:dash.location + 1] : nil;   /* GitHub's build number */
}

/* "1.6, build 37", or "1.6" for a build made elsewhere. */
static NSString *versionText(NSString *joiner)
{
    NSString *b = appBuild();
    return b ? [NSString stringWithFormat:@"%@%@%@", appVersion(), joiner, b] : appVersion();
}

/* ── The log, to send with a problem report ─────────────────────────────── */

static NSString *readText(NSString *path)   /* UTF-8, or byte-for-byte if a cut left a broken character */
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d.length)
        return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
}

/* The background service's log (the older part first), with the version and
 * device on top and the end of the VPN helper's log after it. */
static NSString *logText(void)
{
    char machine[64] = "";
    size_t n = sizeof(machine);
    NSMutableString *t = [NSMutableString string];
    NSDateFormatter *f = [NSDateFormatter new];

    sysctlbyname("hw.machine", machine, &n, NULL, 0);
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    /* The first line names the log: pasted into Files or Notes, it becomes the file's name. */
    [t appendFormat:@"Tether & Band log %@ (version %@, %s, iOS %@)\n\n", [f stringFromDate:[NSDate date]],
                    versionText(@", build "), machine, UIDevice.currentDevice.systemVersion];
    for (NSString *name in @[@"daemon.log.old", @"daemon.log"]) {
        NSString *s = readText([WT_DIR stringByAppendingPathComponent:name]);
        if (s.length)
            [t appendFormat:@"===== %@ =====\n%@\n", name, s];
    }
    NSString *vpn = readText([WT_DIR stringByAppendingPathComponent:@"vpn.log"]);
    if (vpn.length)
        [t appendFormat:@"===== vpn.log (end) =====\n%@\n",
                        vpn.length > 100000 ? [vpn substringFromIndex:vpn.length - 100000] : vpn];
    /* The status bar add-on in SpringBoard: the Personal Hotspot indicator. */
    for (NSString *name in @[@"springboard.log.old", @"springboard.log"]) {
        NSString *s = readText([WT_DIR stringByAppendingPathComponent:name]);
        if (s.length)
            [t appendFormat:@"===== %@ =====\n%@\n", name, s];
    }
    return t;
}

/* ── Settings page ──────────────────────────────────────────────────────── */

@interface WTSettingsController : UIViewController
@end

@implementation WTSettingsController {
    UISwitch *_label;
    UISwitch *_note;
    UISwitch *_hsInd;
    UISwitch *_vpnPass;
    UIButton *_share;
    UIButton *_copy;
}

- (UIButton *)logButton:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/* As a .txt file: AirDrop, Save to Files, Mail, Messages... */
- (void)shareLog:(UIButton *)sender
{
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd-HHmm";
    NSString *dir = [WT_DIR stringByAppendingPathComponent:@"export"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dir error:nil];   /* only the latest one is kept */
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"TetherBand-log-%@.txt", [f stringFromDate:[NSDate date]]]];
    if (![logText() writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        [sender setTitle:@"Couldn't read the log" forState:UIControlStateNormal];
        return;
    }
    UIActivityViewController *a = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = sender;   /* iPad */
    a.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

/* As text, to paste somewhere: the newest 500 KB. */
- (void)copyLog
{
    NSString *t = logText();
    if (t.length > 500000) {   /* keep the first line (the log's name), then the newest part */
        NSRange nl = [t rangeOfString:@"\n"];
        NSString *head = nl.location != NSNotFound && nl.location < 400 ? [t substringToIndex:nl.location + 1] : @"";
        t = [NSString stringWithFormat:@"%@(older lines left out)\n%@", head, [t substringFromIndex:t.length - 500000]];
    }
    UIPasteboard.generalPasteboard.string = t;
    [_copy setTitle:@"Copied" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self->_copy setTitle:@"Copy log" forState:UIControlStateNormal];
    });
}

- (UIView *)switchRow:(NSString *)title on:(UISwitch *)sw
{
    UILabel *t = wtLabel(17, UIFontWeightRegular, UIColor.labelColor);
    t.text = title;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[t, sw]];
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

    _label = [UISwitch new];
    [_label addTarget:self action:@selector(labelToggled:) forControlEvents:UIControlEventValueChanged];
    _note = [UISwitch new];
    [_note addTarget:self action:@selector(noteToggled:) forControlEvents:UIControlEventValueChanged];
    _hsInd = [UISwitch new];
    [_hsInd addTarget:self action:@selector(hsIndToggled:) forControlEvents:UIControlEventValueChanged];
    _vpnPass = [UISwitch new];
    [_vpnPass addTarget:self action:@selector(vpnPassToggled:) forControlEvents:UIControlEventValueChanged];

    UILabel *labelFoot = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    labelFoot.text = @"Band on the Wi-Fi icon: the Wi-Fi icon at the top of the screen shows 2.4, 5 or 6 under "
                     @"its signal arcs, in every app.\n"
                     @"Personal Hotspot indicator: iOS's coloured bar with the link icon while a computer is "
                     @"connected, as when sharing mobile data.\n"
                     @"After installing or updating, respring once for them to appear.\n\n"
                     @"The Wi-Fi icon loads into every app, so an app that looks for tweaks (some banking apps and "
                     @"games) could notice it, even with it off. If one does, turn tweaks off for that app with "
                     @"Choicy.";
    UILabel *noteFoot = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    noteFoot.text = @"A quiet notification in Notification Centre: the band Wi-Fi is on now, then USB sharing, "
                    @"VPN pass-through and Force band. It updates by itself, with no sound or banner. If you "
                    @"clear it, it comes back at the next change.";
    UILabel *vpnFoot = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    vpnFoot.text = [NSString stringWithFormat:
        @"While a VPN is connected on this %1$@, the computer's traffic goes through it too. Turn this off "
        @"to send the computer straight out over Wi-Fi instead, without the VPN; this %1$@ itself still uses "
        @"the VPN.", deviceWord()];
    UILabel *statusHead = wtHeader(@"Status bar"), *noteHead = wtHeader(@"Notification Centre"),
            *tetherHead = wtHeader(@"USB tethering"), *logHead = wtHeader(@"Log");

    _share = [self logButton:@"Share log file…" action:@selector(shareLog:)];
    _copy = [self logButton:@"Copy log" action:@selector(copyLog)];
    UILabel *logFoot = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    logFoot.text = @"A record of what the app has been doing. If something isn't working, attach it to your "
                   @"report on GitHub. It contains your network addresses, so only share it with people you trust.";

    UIView *labelBox = [self indented:labelFoot], *noteBox = [self indented:noteFoot], *vpnBox = [self indented:vpnFoot];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        statusHead, wtCard(@[[self switchRow:@"Band on the Wi-Fi icon" on:_label],
                             [self switchRow:@"Personal Hotspot indicator" on:_hsInd]]), labelBox,
        noteHead, wtCard(@[[self switchRow:@"Status notification" on:_note]]), noteBox,
        tetherHead, wtCard(@[[self switchRow:@"VPN pass-through" on:_vpnPass]]), vpnBox,
        logHead, wtCard(@[_share, _copy]), [self indented:logFoot],
    ]];
    stack.spacing = 6;
    [stack setCustomSpacing:28 afterView:labelBox];
    [stack setCustomSpacing:28 afterView:noteBox];
    [stack setCustomSpacing:28 afterView:vpnBox];
    wtScrollPage(self, stack);
}

/* Footers line up with the text in the cards. */
- (UIView *)indented:(UILabel *)l
{
    UIView *box = [UIView new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.topAnchor constraintEqualToAnchor:box.topAnchor],
        [l.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
        [l.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [l.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
    ]];
    return box;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _label.on = bandLabelOn();
    _note.on = statusNoteOn();
    _hsInd.on = hotspotIndicatorOn();
    _vpnPass.on = vpnPassOn();
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)labelToggled:(UISwitch *)sender
{
    writeSetting(WT_BANDLABEL, sender.on);
}

/* Takes effect straight away: the background service tells SpringBoard. */
- (void)hsIndToggled:(UISwitch *)sender
{
    writeSetting(WT_HSIND, sender.on);
}

/* Takes effect straight away: the computer's connections start again on the
 * new path. */
- (void)vpnPassToggled:(UISwitch *)sender
{
    writeSetting(WT_VPNPASS, sender.on);
}

- (void)noteToggled:(UISwitch *)sender
{
    if (!sender.on) {
        writeSetting(WT_STATUSNOTE, NO);
        updateStatusNotification(nil);   /* takes it away */
        return;
    }
    wtAskNotifications(^(BOOL ok, NSError *error) {
        writeSetting(WT_STATUSNOTE, ok);
        if (ok) {
            updateStatusNotification(nil);
            return;
        }
        [self->_note setOn:NO animated:YES];
        wtNotificationsOffAlert(self, error);
    });
}

@end

/* ── About page ─────────────────────────────────────────────────────────── */

@interface WTAboutController : UIViewController
@end

@implementation WTAboutController

- (UIView *)textCard:(NSString *)text
{
    UILabel *l = wtLabel(15, UIFontWeightRegular, UIColor.labelColor);
    l.text = text;
    return wtCard(@[l]);
}

- (UIButton *)link:(NSString *)title action:(SEL)action
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSString *d = deviceWord();
    self.title = @"About";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    icon.layer.cornerRadius = 14;
    icon.layer.masksToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:64].active = YES;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;
    UILabel *name = wtLabel(22, UIFontWeightBold, UIColor.labelColor);
    name.text = @"WiFi Tether & Band Switcher";
    name.textAlignment = NSTextAlignmentCenter;
    UILabel *tag = wtLabel(15, UIFontWeightRegular, UIColor.secondaryLabelColor);
    tag.text = [NSString stringWithFormat:@"Shares this %@'s Wi-Fi or VPN with a computer over USB, and keeps "
                                          @"Wi-Fi on the band you choose.", d];
    tag.textAlignment = NSTextAlignmentCenter;
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[icon, name, tag]];
    top.axis = UILayoutConstraintAxisVertical;
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 8;

    NSString *usb = [NSString stringWithFormat:
        @"1. Connect this %1$@ to Wi-Fi.\n"
        @"2. Turn on Share Wi-Fi over USB.\n"
        @"3. Plug the %1$@ into the computer.\n\n"
        @"The computer goes online through this %1$@'s Wi-Fi, or through its VPN when one is connected. "
        @"It needs the Share tweak. Windows needs Apple's drivers, which come with iTunes or Apple Devices. "
        @"On a Mac that's also on Wi-Fi, turn its Wi-Fi off, or drag %1$@ USB to the top in System Settings → "
        @"Network → ⋯ → Set Service Order.", d];
    NSString *band = [NSString stringWithFormat:
        @"Turn on Force 5 GHz or Force 2.4 GHz. It works with sharing off.\n\n"
        @"Routers that use one name for both bands keep moving devices between them. When that happens, the "
        @"%@ is moved straight back, usually in well under a second without disconnecting. The first switch "
        @"after a while can take a few seconds while it finds the band.", d];
    NSString *how = [NSString stringWithFormat:
        @"Sharing turns on Personal Hotspot over USB and passes the computer's traffic, DNS included, through "
        @"Wi-Fi or the VPN. The band switcher notices the router's moves the moment they happen and asks iOS for "
        @"its own quick hand-over back; if that doesn't work, it rejoins the right band. Nothing about your "
        @"network or its saved settings is changed.\n\n"
        @"The band on the Wi-Fi icon and the status notification are in Settings. If something goes wrong, "
        @"daemon.log in /var/mobile/Library/WiFiTether (Filza) shows what happened."];

    UIButton *repo = [self link:@"Source code and full instructions" action:@selector(openRepo)];
    UIButton *issue = [self link:@"Report a problem" action:@selector(openIssues)];

    UILabel *foot = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    foot.text = [NSString stringWithFormat:@"Version %@\nDeveloper: scog3\nFree and open source (MIT)",
                                           versionText(@" · Build ")];
    foot.textAlignment = NSTextAlignmentCenter;

    UILabel *h1 = wtHeader(@"USB tethering"), *h2 = wtHeader(@"Wi-Fi band"), *h3 = wtHeader(@"How it works"),
            *h4 = wtHeader(@"GitHub");
    UIView *c1 = [self textCard:usb], *c2 = [self textCard:band], *c3 = [self textCard:how],
           *c4 = wtCard(@[repo, issue]);
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, h1, c1, h2, c2, h3, c3, h4, c4, foot]];
    stack.spacing = 6;
    for (UIView *v in @[top, c1, c2, c3, c4])
        [stack setCustomSpacing:26 afterView:v];
    wtScrollPage(self, stack);
}

- (void)done
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openRepo
{
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:WT_REPO] options:@{} completionHandler:nil];
}

- (void)openIssues
{
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:WT_REPO @"/issues"] options:@{}
                           completionHandler:nil];
}

@end

/* ── Welcome screen ─────────────────────────────────────────────────────
 * Shown once, the first time the app opens after installing (until
 * Continue): the two ways to see the band without opening the app, each
 * with a preview and a switch, both on to start with. Settings changes them
 * later. Nothing about USB tethering or the Share tweak here: that's on the
 * main screen, for whoever wants it. */

/* The band icon as the status bar shows it, drawn by the same code
 * (bandicon.h), `scale` times its real size; a template, so it takes the
 * tint like an SF Symbol. */
static UIImage *wtBandIconImage(NSString *text, CGFloat scale)
{
    CGSize box = CGSizeMake(round(15.33 * scale), round(11 * scale));
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.opaque = NO;
    UIImage *im = [[[UIGraphicsImageRenderer alloc] initWithSize:box format:f]
        imageWithActions:^(UIGraphicsImageRendererContext *c) {
            wtDrawShape(CGRectMake(0, 0, box.width, box.height), text, 3, 1, 0.3);
        }];
    return [im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

/* A status bar, a bit bigger than life: the time, and the new Wi-Fi icon
 * next to the battery. */
static UIView *wtStatusBarPreview(void)
{
    UIView *bar = [UIView new];
    bar.backgroundColor = UIColor.blackColor;
    bar.layer.cornerRadius = 12;
    bar.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *time = wtLabel(17, UIFontWeightSemibold, UIColor.whiteColor);
    time.text = @"9:41";
    time.numberOfLines = 1;
    UIImageView *icon = [[UIImageView alloc] initWithImage:wtBandIconImage(@"5", 1.7)];
    icon.tintColor = UIColor.whiteColor;
    UIImageView *batt = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"battery.100"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular]]];
    batt.tintColor = UIColor.whiteColor;
    UIStackView *right = [[UIStackView alloc] initWithArrangedSubviews:@[icon, batt]];
    right.spacing = 8;
    right.alignment = UIStackViewAlignmentCenter;
    for (UIView *v in @[time, right]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [bar addSubview:v];
    }
    icon.accessibilityLabel = @"Wi-Fi icon showing 5 under the signal arcs";
    [NSLayoutConstraint activateConstraints:@[
        [bar.heightAnchor constraintEqualToConstant:46],
        [time.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:18],
        [time.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [right.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-16],
        [right.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
    ]];
    return bar;
}

/* What the status notification looks like in Notification Centre. */
static UIView *wtNotificationPreview(void)
{
    UIView *n = [UIView new];
    n.backgroundColor = UIColor.tertiarySystemGroupedBackgroundColor;
    n.layer.cornerRadius = 13;
    n.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    icon.layer.cornerRadius = 4.5;
    icon.layer.masksToBounds = YES;
    [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    [icon.heightAnchor constraintEqualToConstant:20].active = YES;
    UILabel *app = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    app.text = @"TETHER & BAND";
    app.numberOfLines = 1;
    UILabel *when = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    when.text = @"now";
    when.numberOfLines = 1;
    [when setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[icon, app, when]];
    head.spacing = 7;
    head.alignment = UIStackViewAlignmentCenter;
    UILabel *title = wtLabel(15, UIFontWeightSemibold, UIColor.labelColor);
    title.text = @"Wi-Fi band: 5 GHz";
    UILabel *body = wtLabel(15, UIFontWeightRegular, UIColor.labelColor);
    body.text = @"USB sharing: ON (connected)\nVPN pass-through: ON (connected)\nForce band: 5 GHz";
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[head, title, body]];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 1;
    [s setCustomSpacing:7 afterView:head];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [n addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:n.topAnchor constant:11],
        [s.bottomAnchor constraintEqualToAnchor:n.bottomAnchor constant:-12],
        [s.leadingAnchor constraintEqualToAnchor:n.leadingAnchor constant:13],
        [s.trailingAnchor constraintEqualToAnchor:n.trailingAnchor constant:-13],
    ]];
    return n;
}

@interface WTWelcomeController : UIViewController
@end

@implementation WTWelcomeController {
    UISwitch *_label;
    UISwitch *_note;
    UIView   *_labelPreview;
    UIView   *_notePreview;
    UIButton *_go;
}

/* One option: its name with a short line under it and the switch beside
 * them, then the preview and, if there is one, a warning. Compact, so both
 * options fit on the screen of an iPhone 6s/7/8 without scrolling. */
- (UIView *)option:(NSString *)name detail:(NSString *)detail on:(UISwitch *)sw preview:(UIView *)preview
           warning:(NSString *)warning
{
    UILabel *t = wtLabel(17, UIFontWeightSemibold, UIColor.labelColor);
    t.text = name;
    UILabel *d = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    d.text = detail;
    UIStackView *names = [[UIStackView alloc] initWithArrangedSubviews:@[t, d]];
    names.axis = UILayoutConstraintAxisVertical;
    names.spacing = 1;
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[names, sw]];
    top.alignment = UIStackViewAlignmentCenter;
    top.spacing = 12;
    [sw setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:top, preview, nil];
    if (warning) {
        UIImageView *sign = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.triangle.fill"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]]];
        sign.tintColor = UIColor.systemOrangeColor;
        [sign setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [sign setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *w = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
        w.text = warning;
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[sign, w]];
        row.spacing = 8;
        row.alignment = UIStackViewAlignmentFirstBaseline;
        [rows addObject:row];
    }
    UIView *card = wtCard(rows);
    UIStackView *inner = (UIStackView *)card.subviews.firstObject;
    inner.spacing = 12;
    return card;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.modalInPresentation = YES;   /* answered with Continue, not swiped away */

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    icon.layer.cornerRadius = 13;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.layer.masksToBounds = YES;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:44].active = YES;
    [icon.heightAnchor constraintEqualToConstant:44].active = YES;
    icon.layer.cornerRadius = 10;
    UIStackView *iconRow = [[UIStackView alloc] initWithArrangedSubviews:@[icon]];
    iconRow.axis = UILayoutConstraintAxisVertical;
    iconRow.alignment = UIStackViewAlignmentCenter;
    UILabel *title = wtLabel(24, UIFontWeightBold, UIColor.labelColor);
    title.text = @"Welcome to Tether & Band";
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.75;
    UILabel *sub = wtLabel(15, UIFontWeightRegular, UIColor.secondaryLabelColor);
    sub.text = @"See your Wi-Fi band without opening the app. Change these later in Settings.";
    sub.textAlignment = NSTextAlignmentCenter;

    _label = [UISwitch new];
    _label.on = bandLabelOn();
    _note = [UISwitch new];
    _note.on = statusNoteOn();
    for (UISwitch *sw in @[_label, _note])
        [sw addTarget:self action:@selector(switched) forControlEvents:UIControlEventValueChanged];
    _labelPreview = wtStatusBarPreview();
    _notePreview = wtNotificationPreview();

    UIView *one = [self option:@"Band on the Wi-Fi icon" detail:@"2.4, 5 or 6 under the arcs, in every app"
                            on:_label preview:_labelPreview
                       warning:@"Banking apps and games that look for jailbreaks may spot it. Choicy can hide it."];
    UIView *two = [self option:@"Status notification" detail:@"Quiet: no sound or banners"
                            on:_note preview:_notePreview warning:nil];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iconRow, title, sub, one, two]];
    stack.spacing = 14;
    [stack setCustomSpacing:10 afterView:iconRow];
    [stack setCustomSpacing:6 afterView:title];
    [stack setCustomSpacing:20 afterView:sub];
    wtScrollPage(self, stack);
    UIScrollView *scroll = (UIScrollView *)stack.superview;

    /* Continue stays at the bottom; the options scroll above it. */
    _go = [UIButton buttonWithType:UIButtonTypeSystem];
    [_go setTitle:@"Continue" forState:UIControlStateNormal];
    [_go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _go.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _go.backgroundColor = UIColor.systemBlueColor;
    _go.layer.cornerRadius = 14;
    _go.layer.cornerCurve = kCACornerCurveContinuous;
    [_go addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
    UIView *bottom = [UIView new];
    bottom.backgroundColor = UIColor.systemGroupedBackgroundColor;
    for (UIView *v in @[bottom, _go])
        v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bottom];
    [bottom addSubview:_go];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    for (NSLayoutConstraint *c in scroll.superview.constraints)   /* the page now ends at the button bar */
        if ((c.firstItem == scroll && c.firstAttribute == NSLayoutAttributeBottom) ||
            (c.secondItem == scroll && c.secondAttribute == NSLayoutAttributeBottom))
            c.active = NO;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor],
        [bottom.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_go.topAnchor constraintEqualToAnchor:bottom.topAnchor constant:12],
        [_go.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
        [_go.heightAnchor constraintEqualToConstant:50],
        [_go.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_go.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [_go.widthAnchor constraintLessThanOrEqualToConstant:540],
    ]];
    NSLayoutConstraint *wide = [_go.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-32];
    wide.priority = UILayoutPriorityRequired - 1;
    wide.active = YES;
    [self switched];
}

/* A switched-off option's preview fades, so it's clear what's on. */
- (void)switched
{
    [UIView animateWithDuration:0.2 animations:^{
        self->_labelPreview.alpha = self->_label.on ? 1 : 0.35;
        self->_notePreview.alpha = self->_note.on ? 1 : 0.35;
    }];
}

- (void)done
{
    [@"1" writeToFile:WT_SETUP atomically:YES encoding:NSUTF8StringEncoding error:nil];
    writeSetting(WT_BANDLABEL, _label.on);   /* (tells the background service, which now shows them) */
    if (!_note.on) {
        writeSetting(WT_STATUSNOTE, NO);
        updateStatusNotification(nil);   /* takes it away, if it was there */
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    _go.enabled = NO;
    wtAskNotifications(^(BOOL ok, NSError *error) {
        writeSetting(WT_STATUSNOTE, ok);
        UIViewController *under = self.presentingViewController;
        [self dismissViewControllerAnimated:YES completion:^{
            if (ok)
                updateStatusNotification(nil);
            else
                wtNotificationsOffAlert(under, error);
        }];
    });
}

@end

/* ── The menu that slides out from the right (the side its button is on) ── */

@interface WTMenuController : UIViewController
@property (nonatomic, copy) void (^onPick)(NSInteger item);   /* 0 Settings, 1 About */
@property (nonatomic) BOOL byFinger;   /* swiped in from the edge: the finger moves it, not an animation */
- (void)follow:(CGFloat)in;            /* the finger is this far in from the right edge */
- (void)letGo:(BOOL)open;
@end

@implementation WTMenuController {
    UIView *_dim;
    UIView *_panel;
    CGFloat _width;
}

- (UIButton *)item:(NSString *)title symbol:(NSString *)symbol tag:(NSInteger)tag
{
    UIButtonConfiguration *c = [UIButtonConfiguration plainButtonConfiguration];
    c.title = title;
    c.image = [UIImage systemImageNamed:symbol];
    c.imagePadding = 14;
    c.baseForegroundColor = UIColor.labelColor;
    c.contentInsets = NSDirectionalEdgeInsetsMake(12, 4, 12, 4);
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *in) {
        NSMutableDictionary *m = [in mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
        return m;
    };
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    b.tag = tag;
    [b addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _dim = [UIView new];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    _dim.alpha = 0;
    _dim.translatesAutoresizingMaskIntoConstraints = NO;
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    [self.view addSubview:_dim];

    _width = MIN(300, round(self.view.bounds.size.width * 0.8));
    _panel = [UIView new];
    _panel.backgroundColor = UIColor.systemBackgroundColor;
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.2;
    _panel.layer.shadowRadius = 12;
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)]];
    [self.view addSubview:_panel];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppIcon60x60"]];
    icon.layer.cornerRadius = 11;
    icon.layer.masksToBounds = YES;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:48].active = YES;
    [icon.heightAnchor constraintEqualToConstant:48].active = YES;
    UILabel *name = wtLabel(20, UIFontWeightBold, UIColor.labelColor);
    name.text = @"Tether & Band";
    UILabel *ver = wtLabel(13, UIFontWeightRegular, UIColor.secondaryLabelColor);
    ver.text = [NSString stringWithFormat:@"Version %@", appVersion()];
    UIStackView *names = [[UIStackView alloc] initWithArrangedSubviews:@[name, ver]];
    names.axis = UILayoutConstraintAxisVertical;
    names.spacing = 2;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[icon, names]];
    head.spacing = 12;
    head.alignment = UIStackViewAlignmentCenter;

    UIView *line = [UIView new];
    line.backgroundColor = UIColor.separatorColor;
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;

    UIStackView *items = [[UIStackView alloc] initWithArrangedSubviews:@[
        head, line,
        [self item:@"Settings" symbol:@"gearshape" tag:0],
        [self item:@"About" symbol:@"info.circle" tag:1],
    ]];
    items.axis = UILayoutConstraintAxisVertical;
    items.spacing = 4;
    [items setCustomSpacing:18 afterView:head];
    [items setCustomSpacing:10 afterView:line];
    items.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addSubview:items];

    [NSLayoutConstraint activateConstraints:@[
        [_dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_panel.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_panel.widthAnchor constraintEqualToConstant:_width],
        [items.topAnchor constraintEqualToAnchor:_panel.safeAreaLayoutGuide.topAnchor constant:24],
        [items.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:20],
        [items.trailingAnchor constraintEqualToAnchor:_panel.safeAreaLayoutGuide.trailingAnchor constant:-20],
    ]];
    _panel.transform = CGAffineTransformMakeTranslation(_width + 20, 0);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!self.byFinger)
        [self letGo:YES];
}

- (void)follow:(CGFloat)in
{
    [self loadViewIfNeeded];
    CGFloat x = MAX(0, _width - MAX(0, in));
    _panel.transform = CGAffineTransformMakeTranslation(x, 0);
    _dim.alpha = 1 - x / _width;
}

- (void)letGo:(BOOL)open
{
    if (!open) {
        [self close];
        return;
    }
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut |
                                                    UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_panel.transform = CGAffineTransformIdentity;
        self->_dim.alpha = 1;
    } completion:nil];
}

- (void)closeThen:(void (^)(void))then
{
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn |
                                                    UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_panel.transform = CGAffineTransformMakeTranslation(self->_width + 20, 0);
        self->_dim.alpha = 0;
    } completion:^(BOOL f) {
        [self dismissViewControllerAnimated:NO completion:then];
    }];
}

- (void)close
{
    [self closeThen:nil];
}

- (void)picked:(UIButton *)b
{
    void (^pick)(NSInteger) = self.onPick;
    NSInteger item = b.tag;
    [self closeThen:^{
        if (pick)
            pick(item);
    }];
}

/* Drag the panel right to close it. */
- (void)dragged:(UIPanGestureRecognizer *)g
{
    CGFloat x = MAX(0, [g translationInView:self.view].x);
    if (g.state == UIGestureRecognizerStateChanged) {
        _panel.transform = CGAffineTransformMakeTranslation(x, 0);
        _dim.alpha = 1 - x / _width;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (x > _width / 3 || [g velocityInView:self.view].x > 500) {
            [self close];
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                self->_panel.transform = CGAffineTransformIdentity;
                self->_dim.alpha = 1;
            }];
        }
    }
}

@end

@implementation WTViewController {
    UISwitch *_toggle;
    UIView   *_dot;
    UILabel  *_state;
    UILabel  *_detail;
    UIButton *_reconnect;   /* shown once the automatic tries to reach the computer are over */
    UILabel  *_wifi;
    UILabel  *_usb;
    UILabel  *_dns;
    UILabel  *_vpn;
    UIView   *_shareCard;   /* shown while the Share tweak isn't installed */
    UISwitch *_band5Toggle; /* force 5 GHz */
    UILabel  *_band5Info;
    BOOL      _band5Asking; /* the warning is showing */
    UISwitch *_band24Toggle; /* force 2.4 GHz (only one of the two is on) */
    NSTimer  *_timer;
    unsigned  _ticks;
    WTMenuController *_swiping;   /* the menu being swiped in from the right edge */
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color
{
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

- (UIView *)card:(NSArray<UIView *> *)views
{
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 12;

    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 10;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    return card;
}

/* A grey section title above the cards, like Settings. */
- (UILabel *)sectionHeader:(NSString *)text
{
    UILabel *l = [self labelWithSize:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.firstLineHeadIndent = 16;
    p.headIndent = 16;
    l.attributedText = [[NSAttributedString alloc] initWithString:text.uppercaseString attributes:@{
        NSFontAttributeName: l.font, NSForegroundColorAttributeName: l.textColor, NSParagraphStyleAttributeName: p}];
    return l;
}

- (UIView *)row:(NSString *)title value:(UILabel *)value
{
    UILabel *t = [self labelWithSize:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    t.text = title;
    [t setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    value.textAlignment = NSTextAlignmentRight;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[t, value]];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = 12;
    return s;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *title = [self labelWithSize:34 weight:UIFontWeightBold color:UIColor.labelColor];
    title.text = @"WiFi Tether &\nBand Switcher";

    /* The menu (Settings, About): a button level with the title's first line,
     * on the right, like the buttons beside big titles in Apple's apps; the
     * menu slides out from that side. */
    UIButton *menu = [UIButton buttonWithType:UIButtonTypeSystem];
    [menu setImage:[UIImage systemImageNamed:@"line.3.horizontal"
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22
                                                                                            weight:UIImageSymbolWeightMedium]]
          forState:UIControlStateNormal];
    menu.accessibilityLabel = @"Menu";
    [menu addTarget:self action:@selector(openMenu) forControlEvents:UIControlEventTouchUpInside];
    menu.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;   /* lines up with the cards' edge */
    UIView *titleRow = [UIView new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    menu.translatesAutoresizingMaskIntoConstraints = NO;
    [titleRow addSubview:title];
    [titleRow addSubview:menu];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:titleRow.topAnchor],
        [title.bottomAnchor constraintEqualToAnchor:titleRow.bottomAnchor],
        [title.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:menu.leadingAnchor constant:-8],
        [menu.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],
        [menu.widthAnchor constraintEqualToConstant:44],
        [menu.heightAnchor constraintEqualToConstant:44],
        /* centred on the first line's capitals */
        [menu.centerYAnchor constraintEqualToAnchor:title.firstBaselineAnchor constant:-round(title.font.capHeight / 2)],
    ]];
    UILabel *subtitle = [self labelWithSize:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    subtitle.text = [NSString stringWithFormat:@"Keeps Wi-Fi on the band you choose, and shares this %@'s Wi-Fi "
                                               @"or VPN with a computer over USB.", deviceWord()];

    UILabel *toggleLabel = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    toggleLabel.text = @"Share Wi-Fi over USB";
    _toggle = [UISwitch new];
    [_toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    UIStackView *toggleRow = [[UIStackView alloc] initWithArrangedSubviews:@[toggleLabel, _toggle]];
    toggleRow.alignment = UIStackViewAlignmentCenter;

    _dot = [UIView new];
    _dot.layer.cornerRadius = 6;
    _dot.translatesAutoresizingMaskIntoConstraints = NO;
    [_dot.widthAnchor constraintEqualToConstant:12].active = YES;
    [_dot.heightAnchor constraintEqualToConstant:12].active = YES;
    _state = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    UIStackView *stateRow = [[UIStackView alloc] initWithArrangedSubviews:@[_dot, _state]];
    stateRow.spacing = 10;
    stateRow.alignment = UIStackViewAlignmentCenter;

    _detail = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    _wifi = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    _usb = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    _dns = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    _vpn = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];

    /* Force 5 GHz: separate from sharing, works with it off */
    UILabel *band5Label = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    band5Label.text = @"Force 5 GHz Wi-Fi";
    _band5Toggle = [UISwitch new];
    [_band5Toggle addTarget:self action:@selector(band5Toggled:) forControlEvents:UIControlEventValueChanged];
    UIStackView *band5Row = [[UIStackView alloc] initWithArrangedSubviews:@[band5Label, _band5Toggle]];
    band5Row.alignment = UIStackViewAlignmentCenter;
    UILabel *band24Label = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    band24Label.text = @"Force 2.4 GHz Wi-Fi";
    _band24Toggle = [UISwitch new];
    [_band24Toggle addTarget:self action:@selector(band24Toggled:) forControlEvents:UIControlEventValueChanged];
    UIStackView *band24Row = [[UIStackView alloc] initWithArrangedSubviews:@[band24Label, _band24Toggle]];
    band24Row.alignment = UIStackViewAlignmentCenter;
    _band5Info = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];

    /* The two sections' notes: band switching works by itself; only USB
     * tethering needs the Share tweak. */
    UIView *bandFoot = wtFooter(@"Works on its own. No other tweaks needed.");
    UIView *help = wtFooter([NSString stringWithFormat:
                 @"Connect this %1$@ to Wi-Fi, turn on Share Wi-Fi over USB, then plug the %1$@ into the "
                 @"computer. The computer goes online through this %1$@'s Wi-Fi, or its VPN when one is "
                 @"connected. Turning sharing off turns Personal Hotspot off.", deviceWord()]);

    /* Share tweak missing: at the top of the tethering section, with a button
     * that opens Sileo. */
    UIImageView *piece = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"puzzlepiece.extension.fill"] ?: [UIImage systemImageNamed:@"puzzlepiece.fill"]];
    piece.tintColor = UIColor.systemOrangeColor;
    piece.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:20
                                                                                         weight:UIImageSymbolWeightSemibold];
    [piece setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *shareTitle = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    shareTitle.text = @"Get the Share tweak";
    UILabel *shareWhy = [self labelWithSize:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    shareWhy.text = @"Only needed for USB tethering. Band switching above works without it.";
    UIStackView *shareNames = [[UIStackView alloc] initWithArrangedSubviews:@[shareTitle, shareWhy]];
    shareNames.axis = UILayoutConstraintAxisVertical;
    shareNames.spacing = 2;
    UIStackView *shareHead = [[UIStackView alloc] initWithArrangedSubviews:@[piece, shareNames]];
    shareHead.spacing = 12;
    shareHead.alignment = UIStackViewAlignmentCenter;
    UILabel *shareText = [self labelWithSize:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    NSString *steps = @"Sileo opens with Share's repo filled in: tap Add Dist Repo, then Add, then install Share. "
                      @"This screen updates by itself.\nRepo: https://aminerostane.com/repo";
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:steps
        attributes:@{NSFontAttributeName: shareText.font, NSForegroundColorAttributeName: shareText.textColor}];
    /* the two Sileo buttons to tap, in bold */
    NSRange dist = [steps rangeOfString:@"Add Dist Repo"];
    NSRange add = [steps rangeOfString:@"then Add"];
    add.location += 5; add.length = 3;
    for (NSValue *v in @[[NSValue valueWithRange:dist], [NSValue valueWithRange:add]])
        [as addAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
                            NSForegroundColorAttributeName: UIColor.labelColor} range:v.rangeValue];
    shareText.attributedText = as;
    UIButton *getShare = [UIButton buttonWithType:UIButtonTypeSystem];
    [getShare setTitle:@"Add Share's Repo in Sileo" forState:UIControlStateNormal];
    [getShare setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    getShare.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    getShare.backgroundColor = UIColor.systemBlueColor;
    getShare.layer.cornerRadius = 10;
    [getShare.heightAnchor constraintEqualToConstant:44].active = YES;
    [getShare addTarget:self action:@selector(getShare) forControlEvents:UIControlEventTouchUpInside];
    _shareCard = [self card:@[shareHead, getShare, shareText]];
    _shareCard.hidden = YES;

    _reconnect = [UIButton buttonWithType:UIButtonTypeSystem];
    [_reconnect setTitle:@"Reconnect" forState:UIControlStateNormal];
    [_reconnect setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _reconnect.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _reconnect.backgroundColor = UIColor.systemBlueColor;
    _reconnect.layer.cornerRadius = 10;
    [_reconnect.heightAnchor constraintEqualToConstant:44].active = YES;
    [_reconnect addTarget:self action:@selector(reconnect) forControlEvents:UIControlEventTouchUpInside];
    _reconnect.hidden = YES;

    UILabel *tetherHeader = [self sectionHeader:@"USB tethering · needs the Share tweak"];
    UILabel *band5Header = [self sectionHeader:@"Wi-Fi band"];
    UIView *statusCard = [self card:@[stateRow, _detail, _reconnect,
                                      [self row:@"Wi-Fi" value:_wifi],
                                      [self row:@"Hotspot / USB" value:_usb],
                                      [self row:@"DNS" value:_dns],
                                      [self row:@"VPN" value:_vpn]]];
    /* Band switching first (works on its own), USB tethering below it. */
    UIView *bandCard = [self card:@[band5Row, band24Row, _band5Info]];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleRow, subtitle,
        band5Header,
        bandCard,
        bandFoot,
        tetherHeader,
        _shareCard,
        [self card:@[toggleRow]],
        statusCard,
        help,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [stack setCustomSpacing:6 afterView:titleRow];
    [stack setCustomSpacing:24 afterView:subtitle];
    [stack setCustomSpacing:6 afterView:band5Header];
    [stack setCustomSpacing:8 afterView:bandCard];
    [stack setCustomSpacing:30 afterView:bandFoot];
    [stack setCustomSpacing:6 afterView:tetherHeader];
    [stack setCustomSpacing:8 afterView:statusCard];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];

    /* The menu also comes out with a swipe in from the right edge. Scrolling
     * waits for it, so a swipe from the edge doesn't scroll as well. */
    UIScreenEdgePanGestureRecognizer *edge = [[UIScreenEdgePanGestureRecognizer alloc]
        initWithTarget:self action:@selector(edgeSwiped:)];
    edge.edges = UIRectEdgeRight;
    [self.view addGestureRecognizer:edge];
    [scroll.panGestureRecognizer requireGestureRecognizerToFail:edge];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        /* Phones: full width with 16-point margins. iPads and other wide
         * screens: at most 540 points wide, centred, like a phone layout. */
        [stack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:540],
    ]];
    NSLayoutConstraint *fill = [stack.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-32];
    /* Just below required: beats every label's own sizing (so phones always fill
     * the width) and loses only to the 540 cap. */
    fill.priority = UILayoutPriorityRequired - 1;
    fill.active = YES;

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    notify_post(WT_NOTIFY);   /* the service answers with a fresh status, even while asleep */
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh)
                                            userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

/* The first time after installing: the welcome screen. */
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.presentedViewController || [NSFileManager.defaultManager fileExistsAtPath:WT_SETUP])
        return;
    [self presentViewController:[WTWelcomeController new] animated:YES completion:nil];
}

- (BOOL)enabledSetting   /* off until switched on (see the daemon's isEnabled) */
{
    NSString *s = [NSString stringWithContentsOfFile:WT_ENABLED encoding:NSUTF8StringEncoding error:nil];
    return [s hasPrefix:@"1"];
}

- (BOOL)prefer5Setting
{
    NSString *s = [NSString stringWithContentsOfFile:WT_PREFER5 encoding:NSUTF8StringEncoding error:nil];
    return [s hasPrefix:@"1"];
}

- (BOOL)prefer24Setting
{
    NSString *s = [NSString stringWithContentsOfFile:WT_PREFER24 encoding:NSUTF8StringEncoding error:nil];
    return [s hasPrefix:@"1"];
}

/* What the band switches are doing, under them. The service's states are
 * named for 5 GHz ("on5", "no5") but mean the band being forced. */
- (void)refreshBand5:(NSDictionary *)st fresh:(BOOL)fresh
{
    BOOL p5 = [self prefer5Setting], p24 = !p5 && [self prefer24Setting];
    if (!_band5Toggle.isTracking && !_band5Asking)
        _band5Toggle.on = p5;
    if (!_band24Toggle.isTracking)
        _band24Toggle.on = p24;
    BOOL on5 = _band5Toggle.on && !_band5Asking, on24 = _band24Toggle.on && !on5;
    NSString *want = on24 ? @"2.4 GHz" : @"5 GHz", *other = on24 ? @"5 GHz" : @"2.4 GHz";
    NSString *s = fresh ? st[@"band5"] : nil;
    if (s && ![s isEqualToString:@"off"] && [st[@"band5want"] intValue] != (on24 ? 2 : 5))
        s = nil;   /* still about the other switch: the service hasn't caught up yet */
    int rssi = [st[@"band5rssi"] intValue];
    NSString *dbm = rssi ? [NSString stringWithFormat:@" (−%d dBm)", -rssi] : @"";
    NSString *on = !on24 && [st[@"band5band"] intValue] == 6 ? @"6 GHz" : want;   /* Force 5 GHz counts 6 GHz */
    NSString *text;
    if ((!on5 && !on24) || [s isEqualToString:@"off"])
        text = @"Keeps Wi-Fi on one band. 5 GHz is faster; 2.4 GHz reaches further. Works with sharing off too.";
    else if ([s isEqualToString:@"on5"])
        text = [NSString stringWithFormat:@"On %@%@.", on, dbm];
    else if ([s isEqualToString:@"switching"])
        text = [NSString stringWithFormat:@"Moving to %@…", want];
    else if ([s isEqualToString:@"finding"])
        text = [NSString stringWithFormat:@"Moving to %@… The first switch after a while can take a few seconds.", want];
    else if ([s isEqualToString:@"restarting"])
        text = [NSString stringWithFormat:@"Turning Wi-Fi off and on to find %@…", want];
    else if ([s isEqualToString:@"searching"])
        text = [NSString stringWithFormat:@"On %@. Looking for %@…", other, want];
    else if ([s isEqualToString:@"no5"])
        text = [NSString stringWithFormat:@"%@ isn't in range here. Trying again every few minutes.", want];
    else if ([s isEqualToString:@"weak"])
        text = [NSString stringWithFormat:@"%@ is too weak here%@. Trying again in a couple of minutes.", want, dbm];
    else if ([s isEqualToString:@"flapping"])
        text = [NSString stringWithFormat:@"Paused for a few minutes: the %@ keeps getting moved back to %@.",
                                          deviceWord(), other];
    else if ([s isEqualToString:@"notsticking"])
        text = [NSString stringWithFormat:@"Couldn't stay on %@. Trying again in a few minutes.", want];
    else if ([s isEqualToString:@"failed"])
        text = [NSString stringWithFormat:@"Couldn't move to %@ yet. Trying again shortly.", want];
    else if ([s isEqualToString:@"nowifi"])
        text = @"Not connected to Wi-Fi.";
    else if ([s isEqualToString:@"crashed"])
        text = @"Stopped after an error. Turn the switch off and on to try again.";
    else if ([s isEqualToString:@"unsupported"])
        text = [NSString stringWithFormat:@"Not available on this %@.", deviceWord()];
    else if ([s isEqualToString:@"unknown"])
        text = [NSString stringWithFormat:@"Can't tell which band this %@ is on.", deviceWord()];
    else
        text = @"Starting…";
    _band5Info.text = text;
}

/* Writes one band switch; turning one on turns the other off. */
- (void)setBand:(NSString *)path on:(BOOL)on
{
    [[NSFileManager defaultManager] createDirectoryAtPath:WT_DIR withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    if (on) {
        NSString *otherPath = [path isEqualToString:WT_PREFER5] ? WT_PREFER24 : WT_PREFER5;
        [@"0" writeToFile:otherPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [([path isEqualToString:WT_PREFER5] ? _band24Toggle : _band5Toggle) setOn:NO animated:YES];
    }
    [(on ? @"1" : @"0") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    notify_post(WT_NOTIFY);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

- (void)setPrefer5:(BOOL)on
{
    [self setBand:WT_PREFER5 on:on];
}

- (void)band24Toggled:(UISwitch *)sender
{
    [self setBand:WT_PREFER24 on:sender.on];
    if (sender.on && handoverUntested())
        [self showUntestedNoticeOnce];
}

static NSString *untestedText(void)
{
    return [NSString stringWithFormat:@"On this %@, moving back without dropping Wi-Fi is new and hasn't been "
                                      @"tested yet. If it doesn't work, it moves back the older way, with Wi-Fi "
                                      @"dropping for about half a second. If Wi-Fi misbehaves, turn the switch off "
                                      @"and please report it on GitHub with daemon.log.", deviceWord()];
}

/* Once, for Force 2.4 GHz (Force 5 GHz's warning carries the same note). */
- (void)showUntestedNoticeOnce
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:@"untestedNoticeShown"])
        return;
    [d setBool:YES forKey:@"untestedNoticeShown"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Not tested on this device yet"
                                                               message:untestedText()
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

/* Turning it on warns first: a weak 5 GHz signal can make Wi-Fi worse. */
- (void)band5Toggled:(UISwitch *)sender
{
    if (!sender.on) {
        [self setPrefer5:NO];
        return;
    }
    _band5Asking = YES;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Force 5 GHz?"
                         message:handoverUntested()
                                     ? [@"5 GHz is faster but doesn't reach as far as 2.4 GHz. Where its signal is "
                                        @"weak, Wi-Fi may be slower or drop out for a moment.\n\n"
                                        stringByAppendingString:untestedText()]
                                     : @"5 GHz is faster but doesn't reach as far as 2.4 GHz. Where its signal is weak, "
                                       @"Wi-Fi may be slower or drop out for a moment."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        self->_band5Asking = NO;
        [self->_band5Toggle setOn:NO animated:YES];
        [self refresh];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Force 5 GHz" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self->_band5Asking = NO;
        [self setPrefer5:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showState:(NSString *)text color:(UIColor *)color
{
    _state.text = text;
    _dot.backgroundColor = color;
}

- (void)refresh
{
    if (++_ticks % 3 == 0)
        notify_post(WT_NOTIFY);   /* keep the status fresh while the app is open */
    updateStatusNotification(nil);
    if (!_toggle.isTracking)
        _toggle.on = [self enabledSetting];

    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:WT_STATUS];
    double updated = [st[@"updated"] doubleValue];
    BOOL fresh = st && ([[NSDate date] timeIntervalSince1970] - updated) < 10;
    [self refreshBand5:st fresh:fresh];

    NSString *wifi = st[@"wifi"], *usb = st[@"hotspot"], *dns = st[@"dns"];
    NSString *band = wifi.length ? wifiBand() : nil;
    _wifi.text = !wifi.length ? @"Not connected"
               : band ? [NSString stringWithFormat:@"%@ · %@", wifi, band] : wifi;
    _usb.text = usb.length ? usb : @"Off";
    _dns.text = dns.length ? dns : @"–";
    NSString *vpn = st[@"vpn"];
    if (!vpn.length)
        _vpn.text = @"Not connected";
    else if ([st[@"vpnShared"] boolValue])
        _vpn.text = [NSString stringWithFormat:@"Shared via %@", vpn];
    else if ([st[@"vpnBypass"] boolValue])
        _vpn.text = @"Not shared (pass-through off)";
    else if (!_toggle.on)
        _vpn.text = [NSString stringWithFormat:@"Connected: %@", vpn];
    else
        _vpn.text = [NSString stringWithFormat:@"%@, not shared yet", vpn];
    _detail.text = @"";
    _detail.hidden = YES;
    _reconnect.hidden = YES;

    /* Without Share nothing works: show how to get it and grey out the switch. */
    BOOL noShare = fresh && st[@"share"] && ![st[@"share"] boolValue];
    _shareCard.hidden = !noShare;
    _toggle.enabled = !noShare;
    if (noShare) {
        [self showState:@"Share tweak needed" color:UIColor.systemOrangeColor];
        _detail.text = @"Install Share from Sileo to use USB tethering.";
        _detail.hidden = NO;
        return;
    }

    if (!fresh) {
        [self showState:@"Background service isn't running" color:UIColor.systemRedColor];
        _detail.text = @"Try rebooting and re-jailbreaking, or reinstall the package.";
        _detail.hidden = NO;
        return;
    }

    NSString *state = st[@"state"];
    if ([state isEqualToString:@"active"]) {
        [self showState:@"Sharing Wi-Fi over USB" color:UIColor.systemGreenColor];
    } else if ([state isEqualToString:@"off"]) {
        [self showState:@"Off" color:UIColor.systemGrayColor];
        _detail.text = @"Personal Hotspot is off and the background services are asleep.";
    } else if ([state isEqualToString:@"nowifi"]) {
        [self showState:@"Waiting for Wi-Fi" color:UIColor.systemOrangeColor];
        _detail.text = [NSString stringWithFormat:@"Connect this %@ to a Wi-Fi network.", deviceWord()];
    } else if ([state isEqualToString:@"airplane"]) {
        [self showState:@"Airplane mode is on" color:UIColor.systemOrangeColor];
    } else if ([state isEqualToString:@"waitcomputer"]) {
        /* "Connected": the computer has set up the phone's tethering network
         * but isn't using it (a Mac that's online another way). */
        BOOL done = [st[@"usbDone"] boolValue];
        if ([st[@"usbStandby"] boolValue])
            [self showState:@"Connected to the computer" color:UIColor.systemYellowColor];
        else if (done)
            [self showState:@"Computer didn't connect" color:UIColor.systemOrangeColor];
        else
            [self showState:@"Waiting for the computer" color:UIColor.systemBlueColor];
        _reconnect.hidden = !done;
    } else if ([state isEqualToString:@"ready"]) {
        [self showState:@"Ready: plug in the USB cable" color:UIColor.systemBlueColor];
    } else if ([state isEqualToString:@"nohotspot"]) {
        [self showState:@"Starting Personal Hotspot" color:UIColor.systemOrangeColor];
        if (![st[@"detail"] length])
            _detail.text = @"If this doesn't change, plug in the USB cable or turn Personal Hotspot on in Settings.";
    } else if ([state isEqualToString:@"error"]) {
        [self showState:@"Couldn't set up sharing" color:UIColor.systemRedColor];
    } else {
        [self showState:state.length ? state : @"Unknown" color:UIColor.systemGrayColor];
    }

    NSString *detail = st[@"detail"];
    if (detail.length)
        _detail.text = _detail.text.length ? [_detail.text stringByAppendingFormat:@"\n%@", detail] : detail;
    _detail.hidden = _detail.text.length == 0;
}

/* Opens Sileo's "Add Source" box with Share's repo address filled in. Adding it
 * with Sileo's "Add Dist Repo" button (Suites and Components left empty) works
 * reliably: plain "Add Source" first asks an online piracy check, which can drop
 * the repo without a word. Sileo keeps it in its own list, so it can be removed
 * there like any other repo. Only on a tap: nothing is added behind your back. */
#define SHARE_REPO @"https://aminerostane.com/repo/"
- (void)getShare
{
    NSURL *sileo = [NSURL URLWithString:[@"sileo://source/" stringByAppendingString:SHARE_REPO]];
    [[UIApplication sharedApplication] openURL:sileo options:@{} completionHandler:^(BOOL ok) {
        if (!ok)   /* no Sileo: show the repo in Safari instead */
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:SHARE_REPO]
                                               options:@{} completionHandler:nil];
    }];
}

- (WTMenuController *)menu
{
    WTMenuController *m = [WTMenuController new];
    m.modalPresentationStyle = UIModalPresentationOverFullScreen;
    __weak WTViewController *weakSelf = self;
    m.onPick = ^(NSInteger item) {
        UIViewController *page = item == 0 ? [WTSettingsController new] : [WTAboutController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
        [weakSelf presentViewController:nav animated:YES completion:nil];
    };
    return m;
}

- (void)openMenu
{
    if (!self.presentedViewController)
        [self presentViewController:[self menu] animated:NO completion:nil];
}

/* Swiping in from the right edge: the menu follows the finger, and opens if
 * it's let go a third of the way in or flicked. */
- (void)edgeSwiped:(UIScreenEdgePanGestureRecognizer *)g
{
    CGFloat in = -[g translationInView:self.view].x, v = -[g velocityInView:self.view].x;
    switch (g.state) {
    case UIGestureRecognizerStateBegan:
        if (self.presentedViewController)
            return;
        _swiping = [self menu];
        _swiping.byFinger = YES;
        [_swiping follow:in];
        [self presentViewController:_swiping animated:NO completion:nil];
        break;
    case UIGestureRecognizerStateChanged:
        [_swiping follow:in];
        break;
    case UIGestureRecognizerStateEnded: {
        CGFloat w = MIN(300, round(self.view.bounds.size.width * 0.8));
        [_swiping letGo:v > 500 || (in > w / 3 && v > -300)];
        _swiping = nil;
        break;
    }
    default:
        [_swiping letGo:NO];
        _swiping = nil;
        break;
    }
}

- (void)reconnect
{
    _reconnect.hidden = YES;   /* until the tries are over again */
    notify_post(WT_RECONNECT);
}

- (void)toggled:(UISwitch *)sender
{
    [[NSFileManager defaultManager] createDirectoryAtPath:WT_DIR withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    [(sender.on ? @"1" : @"0") writeToFile:WT_ENABLED atomically:YES encoding:NSUTF8StringEncoding error:nil];
    notify_post(WT_NOTIFY);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

@end

@interface WTAppDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WTAppDelegate

/* Updates the status notification, then quits: the next change starts the
 * app afresh (a suspended app wouldn't run when wifitetherd starts it). */
static void updateThenQuit(UIApplication *app)
{
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^quit)(void) = ^{
        if (app.applicationState == UIApplicationStateBackground)
            exit(0);
        if (task != UIBackgroundTaskInvalid) {   /* opened meanwhile: stay */
            [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    };
    task = [app beginBackgroundTaskWithExpirationHandler:quit];
    updateStatusNotification(quit);
}

/* The screen: at launch, or when an app started in the background (for the
 * notification) is opened. */
- (void)showScreen
{
    if (self.window)
        return;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [WTViewController new];
    [self.window makeKeyAndVisible];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    if (application.applicationState == UIApplicationStateBackground) {
        /* Started in the background by wifitetherd: just the notification. */
        updateThenQuit(application);
        return YES;
    }
    [self showScreen];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [self showScreen];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    [self showScreen];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    if (statusNoteOn())
        updateThenQuit(application);
}

/* While the app is open, the status notification still goes to Notification
 * Centre (quietly), not on screen. */
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    completionHandler(UNNotificationPresentationOptionList);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler
{
    completionHandler();   /* tapping it just opens the app */
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WTAppDelegate class]));
    }
}
