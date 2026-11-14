/*
 * WiFi Tether - the on/off switch and status screen.
 * The real work happens in the background service (wifitetherd).
 */

#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <notify.h>

#define WT_DIR      @"/var/mobile/Library/WiFiTether"
#define WT_ENABLED  WT_DIR @"/enabled"
#define WT_STATUS   WT_DIR @"/status.plist"
#define WT_NOTIFY   "com.wifitether.changed"

@interface WTViewController : UIViewController
@end

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
    title.text = @"WiFi Tether";
    UILabel *subtitle = [self labelWithSize:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    subtitle.text = @"Shares this iPhone's Wi-Fi connection with a computer over USB.";

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

    UILabel *help = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    help.text = @"1. Connect this iPhone to Wi-Fi.\n"
                @"2. Turn the switch on. It turns Personal Hotspot on for you and keeps Wi-Fi connected.\n"
                @"3. Plug the iPhone into the computer with a USB cable.\n\n"
                @"The computer gets internet through this iPhone's Wi-Fi, or through its VPN when one is connected. "
                @"Leave the switch on and it stays ready, even after re-jailbreaking. "
                @"Switch it off to turn Personal Hotspot off; the background services then sleep and use no battery. "
                @"If airplane mode is on, switching on turns it off, and switching off turns it back on.\n\n"
                @"Needs the Share tweak.";

    /* Share tweak missing: say so first, with a button that opens Sileo. */
    UILabel *shareTitle = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    shareTitle.text = @"Install the Share tweak first";
    UILabel *shareText = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    shareText.text = @"WiFi Tether needs Share to turn on Personal Hotspot without a SIM.\n"
                     @"1. Tap Get Share in Sileo.\n"
                     @"2. Install Share there.\n"
                     @"3. Come back here. WiFi Tether picks it up by itself.";
    UIButton *getShare = [UIButton buttonWithType:UIButtonTypeSystem];
    [getShare setTitle:@"Get Share in Sileo" forState:UIControlStateNormal];
    [getShare setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    getShare.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    getShare.backgroundColor = UIColor.systemBlueColor;
    getShare.layer.cornerRadius = 10;
    [getShare.heightAnchor constraintEqualToConstant:44].active = YES;
    [getShare addTarget:self action:@selector(getShare) forControlEvents:UIControlEventTouchUpInside];
    _shareCard = [self card:@[shareTitle, shareText, getShare]];
    _shareCard.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, subtitle,
        _shareCard,
        [self card:@[toggleRow]],
        [self card:@[stateRow, _detail,
                     [self row:@"Wi-Fi" value:_wifi],
                     [self row:@"Hotspot / USB" value:_usb],
                     [self row:@"DNS" value:_dns],
                     [self row:@"VPN" value:_vpn]]],
        help,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [stack setCustomSpacing:6 afterView:title];
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

    NSString *wifi = st[@"wifi"], *usb = st[@"hotspot"], *dns = st[@"dns"];
    _wifi.text = wifi.length ? wifi : @"Not connected";
    _usb.text = usb.length ? usb : @"Off";
    _dns.text = dns.length ? dns : @"–";
    NSString *vpn = st[@"vpn"];
    if (!vpn.length)
        _vpn.text = @"Not connected";
    else if ([st[@"vpnShared"] boolValue])
        _vpn.text = [NSString stringWithFormat:@"Shared via %@", vpn];
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
        _detail.text = @"Install Share from Sileo to use WiFi Tether.";
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
        _detail.text = @"Connect this iPhone to a Wi-Fi network.";
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

/* Opens Share's page in Sileo, or Sileo's "add source" screen if Share's repo
 * isn't added yet. Only on a tap: nothing is added behind your back. */
- (void)getShare
{
    BOOL haveRepo = NO;
    NSString *dir = @"/var/jb/etc/apt/sources.list.d";
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *t = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f]
                                                encoding:NSUTF8StringEncoding error:nil];
        if ([t containsString:@"aminerostane.com/repo"])
            haveRepo = YES;
    }
    NSURL *sileo = [NSURL URLWithString:haveRepo ? @"sileo://package/com.rostane.share"
                                                 : @"sileo://source/https://aminerostane.com/repo/"];
    [[UIApplication sharedApplication] openURL:sileo options:@{} completionHandler:^(BOOL ok) {
        if (!ok)   /* no Sileo: show the repo in Safari instead */
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://aminerostane.com/repo/"]
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
