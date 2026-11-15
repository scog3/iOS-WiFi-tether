/*
 * WiFi Tether - the on/off switch and status screen.
 * The real work happens in the background service (wifitetherd).
 */

#include <mach/machine.h>
#include <sys/sysctl.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <notify.h>
#include <dlfcn.h>

#define WT_DIR      @"/var/mobile/Library/WiFiTether"
#define WT_ENABLED  WT_DIR @"/enabled"
#define WT_STATUS   WT_DIR @"/status.plist"
#define WT_PREFER5  WT_DIR @"/prefer-5ghz"
#define WT_PREFER24 WT_DIR @"/prefer-24ghz"
#define WT_NOTIFY   "com.wifitether.changed"

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

@implementation WTViewController {
    UISwitch *_toggle;
    UIView   *_dot;
    UILabel  *_state;
    UILabel  *_detail;
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
    UILabel *subtitle = [self labelWithSize:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    subtitle.text = [NSString stringWithFormat:@"Shares this %@'s Wi-Fi or VPN with a computer over USB, and "
                                               @"keeps Wi-Fi on the band you choose.", deviceWord()];

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

    UILabel *help = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    help.text = [NSString stringWithFormat:
                 @"USB tethering: connect this %1$@ to Wi-Fi, turn on Share Wi-Fi over USB, then plug the "
                 @"%1$@ into the computer. The computer goes online through this %1$@'s Wi-Fi, or its VPN "
                 @"when one is connected. Turning sharing off turns Personal Hotspot off.\n\n"
                 @"USB tethering needs the Share tweak; the Wi-Fi band switches don't.", deviceWord()];

    /* Share tweak missing: say so first, with a button that opens Sileo. */
    UILabel *shareTitle = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    shareTitle.text = @"USB sharing needs the Share tweak";
    UILabel *shareText = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    NSString *steps = @"Share turns on Personal Hotspot without a SIM. The Wi-Fi band switches below work without it.\n"
                      @"1. Tap the button below. Sileo opens with Share's repo address filled in.\n"
                      @"2. Tap Add Dist Repo, then Add (leave the other boxes empty).\n"
                      @"3. Install Share from that repo.\n"
                      @"4. Come back here. Tether & Band picks it up by itself.\n"
                      @"Repo address: https://aminerostane.com/repo";
    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:steps
        attributes:@{NSFontAttributeName: shareText.font, NSForegroundColorAttributeName: shareText.textColor}];
    /* the two Sileo buttons to tap, in bold */
    NSRange dist = [steps rangeOfString:@"Add Dist Repo"];
    NSRange add = [steps rangeOfString:@"then Add"];
    add.location += 5; add.length = 3;
    for (NSValue *v in @[[NSValue valueWithRange:dist], [NSValue valueWithRange:add]])
        [as addAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
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
    _shareCard = [self card:@[shareTitle, shareText, getShare]];
    _shareCard.hidden = YES;

    UILabel *tetherHeader = [self sectionHeader:@"USB tethering"];
    UILabel *band5Header = [self sectionHeader:@"Wi-Fi band"];
    UIView *statusCard = [self card:@[stateRow, _detail,
                                      [self row:@"Wi-Fi" value:_wifi],
                                      [self row:@"Hotspot / USB" value:_usb],
                                      [self row:@"DNS" value:_dns],
                                      [self row:@"VPN" value:_vpn]]];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, subtitle,
        tetherHeader,
        _shareCard,
        [self card:@[toggleRow]],
        statusCard,
        band5Header,
        [self card:@[band5Row, band24Row, _band5Info]],
        help,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [stack setCustomSpacing:6 afterView:title];
    [stack setCustomSpacing:24 afterView:subtitle];
    [stack setCustomSpacing:6 afterView:tetherHeader];
    [stack setCustomSpacing:28 afterView:statusCard];
    [stack setCustomSpacing:6 afterView:band5Header];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
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

- (BOOL)enabledSetting
{
    NSString *s = [NSString stringWithContentsOfFile:WT_ENABLED encoding:NSUTF8StringEncoding error:nil];
    return s == nil || ![s hasPrefix:@"0"];
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
    NSString *text;
    if ((!on5 && !on24) || [s isEqualToString:@"off"])
        text = @"Keeps Wi-Fi on one band. 5 GHz is faster; 2.4 GHz reaches further. Works with sharing off too.";
    else if ([s isEqualToString:@"on5"])
        text = [NSString stringWithFormat:@"On %@%@.", want, dbm];
    else if ([s isEqualToString:@"switching"])
        text = [NSString stringWithFormat:@"Moving to %@…", want];
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
        text = [NSString stringWithFormat:@"Couldn't move to %@. Trying again in a couple of minutes.", want];
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
    else if (!_toggle.on)
        _vpn.text = [NSString stringWithFormat:@"Connected: %@", vpn];
    else
        _vpn.text = [NSString stringWithFormat:@"%@, not shared yet", vpn];
    _detail.text = @"";
    _detail.hidden = YES;

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
        [self showState:@"Waiting for the computer" color:UIColor.systemBlueColor];
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

@interface WTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation WTAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [WTViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WTAppDelegate class]));
    }
}
