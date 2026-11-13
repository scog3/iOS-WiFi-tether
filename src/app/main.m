/*
 * WiFi Tether - the switches and status screen.
 * The real work happens in the background service (wifitetherd).
 *
 * Two switches, one file each in WT_DIR ("1" = on, missing = off):
 *   sharing  - Internet sharing (needs the hotspot, so it turns that on too)
 *   hotspot  - Personal Hotspot on its own (Share's local network, unchanged)
 * Both off: the background services sleep.
 */

#import <UIKit/UIKit.h>
#include <notify.h>

#define WT_DIR      @"/var/mobile/Library/WiFiTether"
#define WT_SHARING  WT_DIR @"/sharing"
#define WT_HOTSPOT  WT_DIR @"/hotspot"
#define WT_STATUS   WT_DIR @"/status.plist"
#define WT_NOTIFY   "com.wifitether.changed"

@interface WTViewController : UIViewController
@end

@implementation WTViewController {
    UIView   *_dot;
    UILabel  *_state;
    UILabel  *_detail;
    UISwitch *_sharing;
    UISwitch *_hotspot;
    UILabel  *_wifi;
    UILabel  *_usb;
    UILabel  *_vpn;
    UILabel  *_dns;
    NSTimer  *_timer;
    unsigned  _ticks;
}

#pragma mark - Building blocks

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color
{
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

- (UIView *)card:(NSArray<UIView *> *)views spacing:(CGFloat)spacing
{
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 12;

    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = spacing;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
    ]];
    return card;
}

/* Title and explanation on the left, switch on the right. */
- (UIView *)switchRow:(UISwitch *)sw title:(NSString *)title subtitle:(NSString *)subtitle
{
    UILabel *t = [self labelWithSize:17 weight:UIFontWeightSemibold color:UIColor.labelColor];
    t.text = title;
    UILabel *st = [self labelWithSize:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    st.text = subtitle;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[t, st]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[text, sw]];
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    return row;
}

- (UIView *)separator
{
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.separatorColor;
    [v.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return v;
}

- (UIView *)infoRow:(NSString *)title value:(UILabel *)value
{
    UILabel *t = [self labelWithSize:15 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    t.text = title;
    [t setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [t setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    value.textAlignment = NSTextAlignmentRight;
    value.numberOfLines = 1;
    value.adjustsFontSizeToFitWidth = YES;
    value.minimumScaleFactor = 0.8;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[t, value]];
    s.spacing = 12;
    return s;
}

#pragma mark - Screen

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *title = [self labelWithSize:28 weight:UIFontWeightBold color:UIColor.labelColor];
    title.text = @"WiFi Tether";

    /* Status: the first thing you see. */
    _dot = [UIView new];
    _dot.layer.cornerRadius = 7;
    _dot.translatesAutoresizingMaskIntoConstraints = NO;
    [_dot.widthAnchor constraintEqualToConstant:14].active = YES;
    [_dot.heightAnchor constraintEqualToConstant:14].active = YES;
    _state = [self labelWithSize:21 weight:UIFontWeightSemibold color:UIColor.labelColor];
    UIStackView *stateRow = [[UIStackView alloc] initWithArrangedSubviews:@[_dot, _state]];
    stateRow.spacing = 10;
    stateRow.alignment = UIStackViewAlignmentCenter;
    _detail = [self labelWithSize:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    UIView *statusCard = [self card:@[stateRow, _detail] spacing:6];

    /* The two switches; Internet sharing first. */
    _sharing = [UISwitch new];
    [_sharing addTarget:self action:@selector(sharingChanged:) forControlEvents:UIControlEventValueChanged];
    _hotspot = [UISwitch new];
    [_hotspot addTarget:self action:@selector(hotspotChanged:) forControlEvents:UIControlEventValueChanged];
    UIView *switchCard = [self card:@[
        [self switchRow:_sharing title:@"Internet sharing"
               subtitle:@"Share this iPhone's Wi-Fi, or its VPN, with the computer"],
        [self separator],
        [self switchRow:_hotspot title:@"Personal Hotspot"
               subtitle:@"Local network over USB only, as with Share on its own"],
    ] spacing:12];

    /* Details */
    _wifi = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    _usb = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    _vpn = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    _dns = [self labelWithSize:15 weight:UIFontWeightMedium color:UIColor.labelColor];
    UIView *infoCard = [self card:@[
        [self infoRow:@"Wi-Fi" value:_wifi],
        [self infoRow:@"USB" value:_usb],
        [self infoRow:@"VPN" value:_vpn],
        [self infoRow:@"DNS" value:_dns],
    ] spacing:8];

    UILabel *footer = [self labelWithSize:12 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    footer.text = @"Needs the Share tweak. Switching on turns airplane mode off; "
                  @"switching both off turns it back on and lets the background services sleep.";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, statusCard, switchCard, infoCard, footer]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    /* Fits an iPhone 6s screen as is; scrolls only with very large text. */
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    ]];

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

#pragma mark - Settings

- (BOOL)fileOn:(NSString *)path
{
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [s hasPrefix:@"1"];
}

- (void)write:(NSString *)path on:(BOOL)on
{
    [[NSFileManager defaultManager] createDirectoryAtPath:WT_DIR withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    [(on ? @"1" : @"0") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)changed
{
    notify_post(WT_NOTIFY);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

/* Internet sharing needs the hotspot, so turning it on turns that on too. */
- (void)sharingChanged:(UISwitch *)sender
{
    if (sender.on) {
        [self write:WT_HOTSPOT on:YES];
        [_hotspot setOn:YES animated:YES];
    }
    [self write:WT_SHARING on:sender.on];
    [self changed];
}

/* Without the hotspot there's nothing to share over, so turning it off
 * turns Internet sharing off too. */
- (void)hotspotChanged:(UISwitch *)sender
{
    if (!sender.on) {
        [self write:WT_SHARING on:NO];
        [_sharing setOn:NO animated:YES];
    }
    [self write:WT_HOTSPOT on:sender.on];
    [self changed];
}

#pragma mark - Status

- (void)showState:(NSString *)text color:(UIColor *)color detail:(NSString *)detail
{
    _state.text = text;
    _dot.backgroundColor = color;
    _detail.text = detail;
    _detail.hidden = detail.length == 0;
}

- (void)refresh
{
    if (++_ticks % 3 == 0)
        notify_post(WT_NOTIFY);   /* keep the status fresh while the app is open */

    BOOL sharing = [self fileOn:WT_SHARING];
    if (!_sharing.isTracking)
        _sharing.on = sharing;
    if (!_hotspot.isTracking)
        _hotspot.on = sharing || [self fileOn:WT_HOTSPOT];

    NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:WT_STATUS];
    BOOL fresh = st && ([[NSDate date] timeIntervalSince1970] - [st[@"updated"] doubleValue]) < 10;

    NSString *wifi = st[@"wifi"], *usb = st[@"hotspot"], *dns = st[@"dns"], *vpn = st[@"vpn"];
    BOOL vpnShared = [st[@"vpnShared"] boolValue];
    _wifi.text = wifi.length ? wifi : @"Not connected";
    _usb.text = usb.length ? @"Connected" : @"Not connected";
    _dns.text = dns.length ? dns : @"–";
    NSString *vpnName = [vpn componentsSeparatedByString:@" "].firstObject;   /* "ipsec1 (10.x.x.x)" */
    if (!vpn.length)
        _vpn.text = @"Not connected";
    else if (vpnShared)
        _vpn.text = [NSString stringWithFormat:@"Shared via %@", vpnName];
    else
        _vpn.text = sharing ? [NSString stringWithFormat:@"%@, starting", vpnName] : vpn;

    if (!fresh) {
        [self showState:@"Background service isn't running" color:UIColor.systemRedColor
                 detail:@"Re-jailbreak, or reinstall WiFi Tether."];
        return;
    }

    NSString *state = st[@"state"], *d = st[@"detail"];
    if (!d.length)
        d = nil;

    if ([state isEqualToString:@"active"]) {
        [self showState:vpnShared ? @"Sharing internet through VPN" : @"Sharing internet"
                  color:UIColor.systemGreenColor
                 detail:d ?: (vpnShared ? @"The computer is online through this iPhone's VPN."
                                        : @"The computer is online through this iPhone's Wi-Fi.")];
    } else if ([state isEqualToString:@"local"]) {
        [self showState:@"Local network only" color:UIColor.systemBlueColor
                 detail:d ?: @"Personal Hotspot is on without Internet sharing. "
                              @"The computer can reach this iPhone at 172.20.10.1."];
    } else if ([state isEqualToString:@"ready"]) {
        [self showState:@"Plug in the USB cable" color:UIColor.systemBlueColor
                 detail:d ?: @"Personal Hotspot is on."];
    } else if ([state isEqualToString:@"waitcomputer"]) {
        [self showState:@"Waiting for the computer" color:UIColor.systemBlueColor detail:d];
    } else if ([state isEqualToString:@"off"]) {
        [self showState:@"Off" color:UIColor.systemGrayColor
                 detail:@"Turn on Internet sharing to share this iPhone's connection over USB."];
    } else if ([state isEqualToString:@"nowifi"]) {
        [self showState:@"Waiting for Wi-Fi" color:UIColor.systemOrangeColor
                 detail:d ?: @"Connect this iPhone to Wi-Fi to share its internet."];
    } else if ([state isEqualToString:@"nohotspot"]) {
        [self showState:@"Starting Personal Hotspot" color:UIColor.systemOrangeColor detail:d];
    } else if ([state isEqualToString:@"airplane"]) {
        [self showState:@"Airplane mode is on" color:UIColor.systemOrangeColor detail:d];
    } else if ([state isEqualToString:@"error"]) {
        [self showState:@"Couldn't set up sharing" color:UIColor.systemRedColor detail:d];
    } else {
        [self showState:state.length ? state : @"Unknown" color:UIColor.systemGrayColor detail:d];
    }
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
