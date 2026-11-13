/*
 * wifitetherd - runs as root in the background.
 *
 * Every 2 seconds (and whenever the app flips the switch) it checks:
 *   - is the iPhone on Wi-Fi (en0 has an IPv4 address)?
 *   - is Personal Hotspot up (a bridge interface has an IPv4 address)?
 * If both are true and sharing is switched on, it turns on IP forwarding and
 * loads NAT + DNS rules so hotspot/USB clients reach the internet through
 * Wi-Fi. Otherwise it removes them. Status goes to status.plist for the app.
 */

#import <Foundation/Foundation.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <limits.h>
#include <fcntl.h>
#include <net/route.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <net/if_dl.h>
#include <notify.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include "pfnat.h"

#define WT_DIR      "/var/mobile/Library/WiFiTether"
#define WT_ENABLED  WT_DIR "/enabled"
#define WT_STATUS   WT_DIR "/status.plist"
#define WT_NOTIFY   "com.wifitether.changed"
#define MOBILE_UID  501

typedef struct {
    char      name[IFNAMSIZ];
    in_addr_t ip;
    in_addr_t mask;
    int       ok;
} WTIf;

static int  g_applied;
static char g_key[160];
static char g_anchor[64];
static int  g_savedFwd = -1;

static dispatch_source_t g_timer, g_sigterm, g_sigint, g_dirWatch;
static int g_notifyToken;
static int g_timerRunning;   /* the 1-second check runs only while the switch is on */

static void ensureDir(void)
{
    mkdir(WT_DIR, 0755);
    chown(WT_DIR, MOBILE_UID, MOBILE_UID);
}

static int isEnabled(void)
{
    FILE *f = fopen(WT_ENABLED, "r");
    int c;
    if (!f)
        return 1; /* on by default */
    c = fgetc(f);
    fclose(f);
    return c != '0';
}

/* wantBridge = 0: Wi-Fi (en0). wantBridge = 1: hotspot bridge (bridge100 etc). */
static WTIf findIf(int wantBridge)
{
    WTIf r;
    struct ifaddrs *ifs = NULL, *i;

    memset(&r, 0, sizeof(r));
    if (getifaddrs(&ifs) != 0)
        return r;
    for (i = ifs; i; i = i->ifa_next) {
        in_addr_t ip;
        int isBridge;

        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET)
            continue;
        if (!(i->ifa_flags & IFF_UP))
            continue;
        isBridge = strncmp(i->ifa_name, "bridge", 6) == 0;
        if (wantBridge ? !isBridge : strcmp(i->ifa_name, "en0") != 0)
            continue;
        ip = ((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr;
        if ((ntohl(ip) >> 16) == 0xA9FE) /* 169.254.x.x: no real address */
            continue;
        strlcpy(r.name, i->ifa_name, sizeof(r.name));
        r.ip = ip;
        r.mask = i->ifa_netmask ? ((struct sockaddr_in *)i->ifa_netmask)->sin_addr.s_addr
                                : htonl(0xFFFFFFF0);
        r.ok = 1;
        break;
    }
    freeifaddrs(ifs);
    return r;
}

/* Read a value from iOS's network state (SCDynamicStore, private on iOS). */
static NSDictionary *scValue(NSString *key)
{
    static void *h;
    static void *(*scCreate)(CFAllocatorRef, CFStringRef, void *, void *);
    static CFPropertyListRef (*scCopyValue)(void *, CFStringRef);
    NSDictionary *d = nil;

    if (!h) {
        h = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (h) {
            scCreate = dlsym(h, "SCDynamicStoreCreate");
            scCopyValue = dlsym(h, "SCDynamicStoreCopyValue");
        }
    }
    if (scCreate && scCopyValue) {
        void *store = scCreate(NULL, CFSTR("wifitetherd"), NULL, NULL);
        if (store) {
            id v = (__bridge_transfer id)scCopyValue(store, (__bridge CFStringRef)key);
            if ([v isKindOfClass:[NSDictionary class]])
                d = v;
            CFRelease((CFTypeRef)store);
        }
    }
    return d;
}

static int ifIPv4(const char *name, in_addr_t *ip)
{
    struct ifaddrs *ifs = NULL, *i;
    int found = 0;
    if (getifaddrs(&ifs) != 0)
        return 0;
    for (i = ifs; i; i = i->ifa_next) {
        in_addr_t a;
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || strcmp(i->ifa_name, name) != 0)
            continue;
        a = ((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr;
        if ((ntohl(a) >> 16) == 0xA9FE)
            continue;
        *ip = a;
        found = 1;
        break;
    }
    freeifaddrs(ifs);
    return found;
}

/* Which interface the kernel would send internet traffic out of: a route
 * lookup (RTM_GET) for a public address. Returns 1 and the name on success. */
static int routeInterface(char *name, size_t namelen)
{
    struct {
        struct rt_msghdr h;
        char space[512];
    } m;
    struct sockaddr_in *dst;
    struct sockaddr_dl *ifp;
    int s, seq = 0x5754, n, found = 0;
    pid_t pid = getpid();
    char *cp;
    int i;

    s = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (s < 0)
        return 0;
    memset(&m, 0, sizeof(m));
    m.h.rtm_version = RTM_VERSION;
    m.h.rtm_type = RTM_GET;
    m.h.rtm_addrs = RTA_DST | RTA_IFP;
    m.h.rtm_seq = seq;
    dst = (struct sockaddr_in *)m.space;
    dst->sin_len = sizeof(*dst);
    dst->sin_family = AF_INET;
    dst->sin_addr.s_addr = inet_addr("1.1.1.1");
    ifp = (struct sockaddr_dl *)(m.space + sizeof(*dst));
    ifp->sdl_len = sizeof(*ifp);
    ifp->sdl_family = AF_LINK;
    m.h.rtm_msglen = (u_short)(sizeof(m.h) + sizeof(*dst) + sizeof(*ifp));

    {
        struct timeval tv = { 1, 0 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    if (write(s, &m, m.h.rtm_msglen) < 0) {
        close(s);
        return 0;
    }
    do {
        n = (int)read(s, &m, sizeof(m));
    } while (n > 0 && (m.h.rtm_seq != seq || m.h.rtm_pid != pid));
    close(s);
    if (n <= (int)sizeof(m.h) || m.h.rtm_errno)
        return 0;

    cp = m.space;
    for (i = 0; i < RTAX_MAX; i++) {
        struct sockaddr *sa;
        if (!(m.h.rtm_addrs & (1 << i)))
            continue;
        sa = (struct sockaddr *)cp;
        if (i == RTAX_IFP && sa->sa_family == AF_LINK) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)sa;
            if (sdl->sdl_nlen > 0 && (size_t)sdl->sdl_nlen < namelen) {
                memcpy(name, sdl->sdl_data, sdl->sdl_nlen);
                name[sdl->sdl_nlen] = 0;
                found = 1;
            }
            break;
        }
        cp += sa->sa_len ? ((sa->sa_len + 3) & ~3) : 4;
        if (cp >= m.space + sizeof(m.space))
            break;
    }
    return found;
}

static int isLocalIf(const char *name, const WTIf *wifi)
{
    return strcmp(name, wifi->name) == 0 || strncmp(name, "en", 2) == 0 ||
           strncmp(name, "bridge", 6) == 0 || strncmp(name, "pdp_ip", 6) == 0 ||
           strncmp(name, "lo", 2) == 0;
}

/* A connected VPN, whatever kind (utun from a VPN app, ipsec from IKEv2, ...):
 * when a full-tunnel VPN is up, the phone's own internet traffic goes through
 * it, so find the interface the phone itself uses for the internet. If that's Wi-Fi
 * (no VPN, or a split-tunnel one), there's nothing to share. */
static WTIf findVPN(const WTIf *wifi)
{
    WTIf r;
    char name[IFNAMSIZ] = "";

    memset(&r, 0, sizeof(r));
    /* 1. Ask the kernel where traffic to the internet goes. */
    if (!routeInterface(name, sizeof(name))) {
        /* 2. Otherwise ask iOS which interface is primary. */
        NSDictionary *g = scValue(@"State:/Network/Global/IPv4");
        NSString *pi = g[@"PrimaryInterface"];
        if (![pi isKindOfClass:[NSString class]] || !pi.length)
            return r;
        strlcpy(name, pi.UTF8String, sizeof(name));
    }
    if (isLocalIf(name, wifi))
        return r;   /* Wi-Fi: no VPN, or a split-tunnel one */
    strlcpy(r.name, name, sizeof(r.name));
    r.ok = ifIPv4(r.name, &r.ip);
    return r;
}

/* Tell the VPN helper which interface to use ("" = none). Written only on change. */
static void writeVpnIf(const char *name)
{
    static char last[IFNAMSIZ] = "\x01";
    if (strcmp(last, name) == 0)
        return;
    ensureDir();
    [[NSString stringWithFormat:@"%s\n", name] writeToFile:@WT_DIR "/vpn-if" atomically:YES
                                                  encoding:NSUTF8StringEncoding error:nil];
    strlcpy(last, name, sizeof(last));
    if (name[0])
        NSLog(@"wifitetherd: VPN interface %s", name);
}

/* Keep the logs small: launchd appends to them, so truncating is safe. */
static void trimLog(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > 1024 * 1024)
        truncate(path, 0);
}

/* The DNS server iOS is using; falls back to 1.1.1.1. */
static in_addr_t findDNS(void)
{
    in_addr_t out = 0;
    NSDictionary *d = scValue(@"State:/Network/Global/DNS");
    for (NSString *s in d[@"ServerAddresses"]) {
        struct in_addr a;
        uint32_t hv;
        if (![s isKindOfClass:[NSString class]] || inet_pton(AF_INET, s.UTF8String, &a) != 1)
            continue;
        hv = ntohl(a.s_addr);
        if ((hv >> 24) == 127 || (hv >> 16) == 0xA9FE || hv == 0)
            continue;
        out = a.s_addr;
        break;
    }
    if (!out)
        out = inet_addr("1.1.1.1");
    return out;
}

static int getFwd(void)
{
    int v = 0;
    size_t l = sizeof(v);
    if (sysctlbyname("net.inet.ip.forwarding", &v, &l, NULL, 0) != 0)
        return -1;
    return v;
}

static int setFwd(int v)
{
    return sysctlbyname("net.inet.ip.forwarding", NULL, NULL, &v, sizeof(v));
}

static void restoreFwd(void)
{
    if (g_savedFwd >= 0) {
        setFwd(g_savedFwd);
        g_savedFwd = -1;
    }
}

static void teardown(void)
{
    if (!g_applied)
        return;
    pfn_clear(g_anchor, NULL, 0);
    restoreFwd();
    pfn_stop();
    g_applied = 0;
    g_key[0] = 0;
    NSLog(@"wifitetherd: sharing stopped");
}

static NSString *ipStr(in_addr_t a)
{
    char b[INET_ADDRSTRLEN];
    struct in_addr x;
    x.s_addr = a;
    inet_ntop(AF_INET, &x, b, sizeof(b));
    return [NSString stringWithUTF8String:b];
}

/* ── Gateway and DNS for hotspot clients ──────────────────────────
 * misd's local hotspot mode configures Apple's DHCP server (bootpd) without a
 * router or DNS option, so clients get an address but no way out. Add both,
 * pointing at the phone, and tell bootpd to reload. misd may rewrite the file
 * when the hotspot restarts; the 2-second check puts the entries back. */
#define BOOTPD_PLIST "/Library/Preferences/SystemConfiguration/bootpd.plist"
#define WT_MARK @"_wifitether"

static void signalBootpd(void)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    struct kinfo_proc *procs;
    size_t n, i;

    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0)
        return;
    len += len / 4;
    procs = malloc(len);
    if (!procs)
        return;
    if (sysctl(mib, 3, procs, &len, NULL, 0) == 0) {
        n = len / sizeof(struct kinfo_proc);
        for (i = 0; i < n; i++)
            if (strcmp(procs[i].kp_proc.p_comm, "bootpd") == 0)
                kill(procs[i].kp_proc.p_pid, SIGHUP); /* bootpd re-reads its settings */
    }
    free(procs);
}

/* Rewrites bootpd.plist through `edit`; returns 1 if the file changed. */
static int editBootpd(BOOL (^edit)(NSMutableDictionary *root))
{
    char real[PATH_MAX];
    struct stat info;
    NSString *path;
    NSData *data, *out;
    NSMutableDictionary *root;
    NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;

    if (!realpath(BOOTPD_PLIST, real) || stat(real, &info) != 0)
        return 0;
    path = [NSString stringWithUTF8String:real];
    data = [NSData dataWithContentsOfFile:path];
    if (!data)
        return 0;
    root = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers
                                                      format:&format error:NULL];
    if (![root isKindOfClass:[NSMutableDictionary class]] || !edit(root))
        return 0;
    out = [NSPropertyListSerialization dataWithPropertyList:root format:format options:0 error:NULL];
    if (!out || ![out writeToFile:path atomically:YES])
        return 0;
    chown(real, info.st_uid, info.st_gid);
    chmod(real, info.st_mode & 07777);
    signalBootpd();
    return 1;
}

/* The phone's own address on a hotspot subnet: from its name ("172.20.10.1/28"),
 * otherwise the first address after net_address. */
static NSString *subnetGateway(NSDictionary *s)
{
    struct in_addr a;
    NSString *name = s[@"name"], *net = s[@"net_address"];
    if ([name isKindOfClass:[NSString class]]) {
        NSString *ip = [name componentsSeparatedByString:@"/"].firstObject;
        if (inet_pton(AF_INET, ip.UTF8String, &a) == 1)
            return ip;
    }
    if ([net isKindOfClass:[NSString class]] && inet_pton(AF_INET, net.UTF8String, &a) == 1)
        return ipStr(htonl(ntohl(a.s_addr) + 1));
    return nil;
}

static BOOL isHotspotSubnet(NSDictionary *s)
{
    return [s isKindOfClass:[NSDictionary class]] &&
        ([s[@"_creator"] isEqual:@"com.apple.MobileInternetSharing"] ||
         ([s[@"interface"] isKindOfClass:[NSString class]] && [s[@"interface"] hasPrefix:@"bridge"]));
}

/* Make every hotspot subnet hand out the phone as gateway and DNS.
 * Returns 1 if the file now has a gateway for the hotspot. */
static int dhcpEnsure(void)
{
    __block int ready = 0;
    int changed = editBootpd(^BOOL(NSMutableDictionary *root) {
        BOOL dirty = NO;
        NSArray *subnets = root[@"Subnets"];
        if (![subnets isKindOfClass:[NSArray class]])
            return NO;
        for (NSMutableDictionary *s in subnets) {
            NSString *gw;
            if (![s isKindOfClass:[NSMutableDictionary class]] || !isHotspotSubnet(s))
                continue;
            gw = subnetGateway(s);
            if (!gw)
                continue;
            ready = 1;
            if (![s[@"dhcp_router"] isEqual:@[gw]]) {
                s[@"dhcp_router"] = @[gw];
                dirty = YES;
            }
            if (s[@"dhcp_domain_name_server"] == nil || [s[WT_MARK] boolValue]) {
                if (![s[@"dhcp_domain_name_server"] isEqual:@[gw]]) {
                    s[@"dhcp_domain_name_server"] = @[gw];
                    dirty = YES;
                }
            }
            if (![s[WT_MARK] boolValue]) {
                s[WT_MARK] = @YES;
                dirty = YES;
            }
        }
        return dirty;
    });
    if (changed)
        NSLog(@"wifitetherd: hotspot DHCP now gives the phone as gateway/DNS");
    return ready;
}

/* Remove what dhcpEnsure added. */
static void dhcpRestore(void)
{
    editBootpd(^BOOL(NSMutableDictionary *root) {
        BOOL dirty = NO;
        NSArray *subnets = root[@"Subnets"];
        if (![subnets isKindOfClass:[NSArray class]])
            return NO;
        for (NSMutableDictionary *s in subnets) {
            if (![s isKindOfClass:[NSMutableDictionary class]] || ![s[WT_MARK] boolValue])
                continue;
            [s removeObjectsForKeys:@[@"dhcp_router", @"dhcp_domain_name_server", WT_MARK]];
            dirty = YES;
        }
        return dirty;
    });
}

/* ── Personal Hotspot and Wi-Fi control ──────────────────────────
 * The calls are the ones AutoHotspot uses (github.com/27445688/AutoHotspot,
 * MIT, see LICENSE.AutoHotspot), which are what Settings uses:
 *   MISManager setState: (WirelessModemSettings.bundle) turns the hotspot on/off,
 *   WiFiManagerClient{Get,Set}Power (MobileWiFi) reads/sets Wi-Fi power,
 *   WFClient setMISDiscoveryState:immediateDisable: (WiFiKit) hides the hotspot
 *   from Wi-Fi devices.
 * WiFi Tether only needs the hotspot for USB, so it never makes it visible over
 * Wi-Fi: that is what takes the Wi-Fi chip away and drops the Wi-Fi connection.
 * If Wi-Fi drops anyway, it is brought back. */
#define MIS_ON  1023
#define MIS_OFF 1022

static int   g_hsInit;            /* 0 not tried, 1 ok, -1 failed */
static int   g_hsCrashed;         /* a hotspot call crashed the service last time */

/* Crash guard: Apple's hotspot code is loaded into this service, which is new on
 * some iOS versions. If a call crashes, launchd restarts us and the marker is
 * still there: then hotspot control stays off (and everything else keeps working)
 * until the switch is turned off and on again. */
#define WT_HS_GUARD WT_DIR "/hotspot-call"
static void guardBegin(const char *what)
{
    FILE *f = fopen(WT_HS_GUARD, "w");
    if (f) {
        fputs(what, f);
        fclose(f);
    }
}
static void guardEnd(void)
{
    unlink(WT_HS_GUARD);
}
static id    g_mis, g_wf;
static void *g_wifiMgr;
static int  (*g_wifiGetPower)(void *);
static void (*g_wifiSetPower)(void *, bool);

static int hsInit(void)
{
    void *(*create)(CFAllocatorRef, int);
    Class misClass, wfClass;

    if (g_hsInit)
        return g_hsInit > 0;
    g_hsInit = -1;
    if (g_hsCrashed)
        return 0;
    guardBegin("init");
    dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/WiFiKit.framework/WiFiKit", RTLD_LAZY);
    dlopen("/System/Library/PreferenceBundles/WirelessModemSettings.bundle/WirelessModemSettings", RTLD_LAZY);
    create = dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
    g_wifiGetPower = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower");
    g_wifiSetPower = dlsym(RTLD_DEFAULT, "WiFiManagerClientSetPower");
    misClass = objc_getClass("MISManager");
    wfClass = objc_getClass("WFClient");
    if (create)
        g_wifiMgr = create(kCFAllocatorDefault, 0);
    if (misClass)
        g_mis = ((id (*)(Class, SEL))objc_msgSend)(misClass, NSSelectorFromString(@"sharedManager"));
    if (wfClass)
        g_wf = ((id (*)(Class, SEL))objc_msgSend)(wfClass, NSSelectorFromString(@"sharedInstance"));
    guardEnd();
    NSLog(@"wifitetherd: hotspot control: MISManager=%d WiFiManager=%d power=%d/%d WFClient=%d",
          g_mis != nil, g_wifiMgr != NULL, g_wifiGetPower != NULL, g_wifiSetPower != NULL, g_wf != nil);
    if (!g_mis)
        return 0;
    g_hsInit = 1;
    return 1;
}

static int hotspotState(void)
{
    NSDictionary *d = scValue(@"com.apple.MobileInternetSharing");
    return [d[@"State"] intValue];
}

static void hotspotSet(BOOL on)
{
    if (!hsInit())
        return;
    guardBegin("setState");
    ((void (*)(id, SEL, int))objc_msgSend)(g_mis, NSSelectorFromString(@"setState:"), on ? MIS_ON : MIS_OFF);
    guardEnd();
}

static void hotspotHide(void)
{
    SEL sel = NSSelectorFromString(@"setMISDiscoveryState:immediateDisable:");
    if (hsInit() && g_wf && [g_wf respondsToSelector:sel]) {
        guardBegin("discovery");
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(g_wf, sel, NO, YES);
        guardEnd();
    }
}

static int wifiPowered(void)
{
    return (hsInit() && g_wifiMgr && g_wifiGetPower) ? g_wifiGetPower(g_wifiMgr) != 0 : -1;
}

static void wifiSetPower(BOOL on)
{
    if (hsInit() && g_wifiMgr && g_wifiSetPower) {
        guardBegin("wifiPower");
        g_wifiSetPower(g_wifiMgr, on);
        guardEnd();
    }
}

static time_t g_lastWifiUp;       /* last time Wi-Fi had an address */
static time_t g_hsNextTry, g_hsWindow;
static int    g_hsTries;
static time_t g_wifiNextFix;
static int    g_wifiFixStep;
static int    g_lastEnabled = -1;

/* Called every second while the switch is on. Returns a message for the app, or nil. */
static NSString *controlHotspot(const WTIf *up, const WTIf *lan)
{
    time_t now = time(NULL);
    int hs = hotspotState();
    BOOL hsOn = hs == MIS_ON || lan->ok;

    if (up->ok) {
        g_lastWifiUp = now;
        g_wifiFixStep = 0;
    }

    /* Hotspot off: turn it on. At most 3 times in 10 minutes, so we don't
     * fight iOS (or you) forever. */
    if (!hsOn) {
        if (now - g_hsWindow > 600) {
            g_hsWindow = now;
            g_hsTries = 0;
        }
        if (now >= g_hsNextTry && g_hsTries < 3) {
            if (!hsInit())
                return g_hsCrashed
                    ? @"Turning Personal Hotspot on automatically crashed on this iPhone, so it's off. Turn Personal Hotspot on in Settings."
                    : @"Couldn't reach iOS's Personal Hotspot controls. Turn Personal Hotspot on in Settings.";
            NSLog(@"wifitetherd: turning on Personal Hotspot (state %d)", hs);
            hotspotSet(YES);
            g_hsTries++;
            g_hsNextTry = now + 10;
        }
        if (g_hsTries >= 3 && now >= g_hsNextTry)
            return @"Personal Hotspot keeps turning off. Turn it on in Settings, or switch WiFi Tether off and on again.";
        return @"Turning on Personal Hotspot…";
    }

    /* Hotspot on but Wi-Fi gone, and it was connected in the last 2 minutes:
     * most likely the hotspot took the Wi-Fi chip. Up to 3 steps per drop. */
    if (!up->ok && g_lastWifiUp && now - g_lastWifiUp < 120 && g_wifiFixStep < 3 && now >= g_wifiNextFix) {
        int pw = wifiPowered();
        if (g_wifiFixStep == 0) {
            NSLog(@"wifitetherd: Wi-Fi dropped; hiding the hotspot from Wi-Fi devices (power %d)", pw);
            hotspotHide();
            if (pw == 0)
                wifiSetPower(YES);
        } else if (pw == 0) {
            NSLog(@"wifitetherd: Wi-Fi still off; turning it on");
            wifiSetPower(YES);
        } else {
            NSLog(@"wifitetherd: Wi-Fi on but not connected; turning it off and on");
            wifiSetPower(NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{ wifiSetPower(YES); });
        }
        g_wifiFixStep++;
        g_wifiNextFix = now + 8;
    }
    if (!up->ok && g_lastWifiUp && now - g_lastWifiUp < 120 && g_wifiFixStep > 0)
        return @"Reconnecting Wi-Fi…";
    return nil;
}

static void writeStatus(NSDictionary *d)
{
    ensureDir();
    [d writeToFile:@WT_STATUS atomically:YES];
    chown(WT_STATUS, MOBILE_UID, MOBILE_UID);
    chmod(WT_STATUS, 0644);
}

static void reconcile(void)
{
    @autoreleasepool {
        NSMutableDictionary *st = [NSMutableDictionary dictionary];
        NSString *state, *detail = @"";
        int en = isEnabled();
        WTIf up = findIf(0), lan = findIf(1);

        trimLog(WT_DIR "/daemon.log");
        trimLog(WT_DIR "/vpn.log");

        /* Switch flipped on: start fresh. Flipped off: turn the hotspot off. */
        if (en && g_lastEnabled == 0 && g_hsCrashed) {
            g_hsCrashed = 0;   /* you switched off and on: try once more */
            g_hsInit = 0;
        }
        if (en && g_lastEnabled != 1) {
            g_hsTries = 0;
            g_hsNextTry = 0;
            g_hsWindow = time(NULL);
            g_wifiFixStep = 0;
            if (up.ok)
                g_lastWifiUp = time(NULL);
        }
        if (!en && g_lastEnabled == 1 && (hotspotState() == MIS_ON || lan.ok)) {
            NSLog(@"wifitetherd: switch off; turning off Personal Hotspot");
            hotspotSet(NO);
        }
        g_lastEnabled = en;

        NSString *control = en ? controlHotspot(&up, &lan) : nil;
        if (en && !lan.ok)
            lan = findIf(1);

        st[@"enabled"] = @(en);
        st[@"wifi"] = up.ok ? ipStr(up.ip) : @"";
        st[@"hotspot"] = lan.ok ? [NSString stringWithFormat:@"%@ on %s", ipStr(lan.ip), lan.name] : @"";

        /* Gateway entries stay as long as sharing is switched on, so a client
         * that connects while Wi-Fi or the hotspot is still coming up still
         * gets them. */
        int gwOk = 0;
        if (en)
            gwOk = dhcpEnsure();
        else
            dhcpRestore();
        st[@"gateway"] = @(gwOk);

        if (!en || !up.ok || !lan.ok) {
            teardown();
            writeVpnIf("");
            state = !en ? @"off" : (!up.ok ? @"nowifi" : (hotspotState() == MIS_ON ? @"ready" : @"nohotspot"));
            if (control)
                detail = control;
        } else {
            in_addr_t dns = findDNS();
            char key[160], err[256] = "";
            int ok = 1, need;
            WTIf vpn = findVPN(&up);
            writeVpnIf(vpn.ok ? vpn.name : "");

            /* With a VPN connected, client traffic goes through it (src/vpn).
             * A DNS server on the Wi-Fi network itself can't be reached through
             * the VPN, so use a public one instead; it travels through the VPN. */
            if (vpn.ok && (dns & up.mask) == (up.ip & up.mask))
                dns = inet_addr("1.1.1.1");

            st[@"dns"] = ipStr(dns);
            st[@"vpn"] = vpn.ok ? [NSString stringWithFormat:@"%s (%@)", vpn.name, ipStr(vpn.ip)] : @"";
            snprintf(key, sizeof(key), "%s|%08x|%s|%08x|%08x|%08x",
                     up.name, up.ip, lan.name, lan.ip, lan.mask, dns);

            need = !g_applied || strcmp(key, g_key) != 0 || !pfn_present(g_anchor);
            if (need) {
                struct pfn_cfg c;
                ok = 0;
                do {
                    if (pfn_open(err, sizeof(err)))
                        break;
                    if (!g_applied && pfn_pick_anchor(g_anchor, sizeof(g_anchor), err, sizeof(err)))
                        break;
                    if (g_savedFwd < 0)
                        g_savedFwd = getFwd();
                    if (setFwd(1) != 0) {
                        snprintf(err, sizeof(err), "Couldn't turn on IP forwarding: %s", strerror(errno));
                        break;
                    }
                    if (pfn_start(err, sizeof(err)))
                        break;

                    memset(&c, 0, sizeof(c));
                    c.anchor = g_anchor;
                    c.up_if = up.name;
                    c.up_ip = up.ip;
                    c.lan_if = lan.name;
                    c.lan_ip = lan.ip;
                    c.lan_mask = lan.mask;
                    c.dns_ip = dns;
                    if (pfn_apply(&c, err, sizeof(err)))
                        break;

                    g_applied = 1;
                    strlcpy(g_key, key, sizeof(g_key));
                    ok = 1;
                    NSLog(@"wifitetherd: sharing %s -> %s (dns %@, anchor \"%s\")",
                          lan.name, up.name, ipStr(dns), g_anchor);
                } while (0);

                if (!ok) {
                    static char lastErr[256];
                    if (strcmp(err, lastErr) != 0) {
                        NSLog(@"wifitetherd: %s", err);
                        strlcpy(lastErr, err, sizeof(lastErr));
                    }
                    if (!g_applied)
                        restoreFwd();
                }
            }
            /* VPN sharing hook: re-add it if iOS dropped it; report a failure once. */
            if (ok && g_applied && !pfn_filter_hook_present()) {
                static char lastHookErr[256];
                char herr[256] = "";
                if (pfn_filter_hook_add(herr, sizeof(herr)) != 0 && strcmp(herr, lastHookErr) != 0) {
                    NSLog(@"wifitetherd: %s", herr);
                    strlcpy(lastHookErr, herr, sizeof(lastHookErr));
                }
            }
            st[@"vpnShared"] = @(vpn.ok && pfn_vpn_shared());

            state = ok ? @"active" : @"error";
            if (!ok) {
                detail = [NSString stringWithUTF8String:err];
            } else {
                if (!gwOk)
                    detail = @"Couldn't add the gateway to the hotspot's DHCP settings; set it manually on the computer.";
                else if (g_anchor[0])
                    detail = [NSString stringWithFormat:@"Rules loaded in anchor %s", g_anchor];
            }
        }

        if (control && [state isEqualToString:@"active"] && !detail.length)
            detail = control;
        st[@"state"] = state;
        st[@"detail"] = detail;
        st[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
        writeStatus(st);

        /* Switch off: stop the 1-second check, so nothing wakes up until the
         * switch changes (the app posts WT_NOTIFY). */
        if (g_timer && en != g_timerRunning) {
            if (en)
                dispatch_resume(g_timer);
            else
                dispatch_suspend(g_timer);
            g_timerRunning = en;
            NSLog(@"wifitetherd: switch %s", en ? "on" : "off; sleeping");
        }
    }
}

static dispatch_source_t watchSignal(int sig)
{
    dispatch_source_t s;
    signal(sig, SIG_IGN);
    s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{
        teardown();
        dhcpRestore();
        writeStatus(@{ @"state": @"stopped", @"detail": @"",
                       @"updated": @0, @"enabled": @(isEnabled()) });
        exit(0);
    });
    dispatch_resume(s);
    return s;
}

/* misd replaces bootpd.plist when the hotspot starts; that changes the
 * directory, so re-add the gateway straight away, before any client asks. */
static void watchBootpdDir(void)
{
    char real[PATH_MAX];
    int fd;
    if (!realpath("/Library/Preferences/SystemConfiguration", real))
        return;
    fd = open(real, O_EVTONLY);
    if (fd < 0)
        return;
    g_dirWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND,
                                        dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_dirWatch, ^{
        if (isEnabled())
            dhcpEnsure();
    });
    dispatch_source_set_cancel_handler(g_dirWatch, ^{ close(fd); });
    dispatch_resume(g_dirWatch);
}

/* `wifitetherd --cleanup`: remove everything wifitetherd adds (used when
 * uninstalling; launchctl unload may kill the service without a chance to). */
static int cleanup(void)
{
    char a[64] = "";
    if (pfn_open(NULL, 0) == 0) {
        pfn_filter_hook_remove();
        if (pfn_pick_anchor(a, sizeof(a), NULL, 0) == 0 && !a[0])
            pfn_clear("", NULL, 0);
        pfn_clear(WT_FALLBACK_ANCHOR, NULL, 0);
    }
    dhcpRestore();
    writeVpnIf("");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--cleanup") == 0) {
        @autoreleasepool {
            return cleanup();
        }
    }
    @autoreleasepool {
        ensureDir();
        {
            char what[32] = "";
            FILE *f = fopen(WT_HS_GUARD, "r");
            if (f) {
                if (!fgets(what, sizeof(what), f))
                    what[0] = 0;
                fclose(f);
                unlink(WT_HS_GUARD);
                g_hsCrashed = 1;
                NSLog(@"wifitetherd: the last hotspot call (%s) crashed; automatic hotspot control is off "
                      "until the switch is turned off and on", what);
            }
        }
        g_sigterm = watchSignal(SIGTERM);
        g_sigint = watchSignal(SIGINT);

        notify_register_dispatch(WT_NOTIFY, &g_notifyToken, dispatch_get_main_queue(), ^(int t) {
            reconcile();
        });

        watchBootpdDir();

        g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                  1 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(g_timer, ^{ reconcile(); });
        /* Created suspended; reconcile() resumes it while the switch is on. */

        NSLog(@"wifitetherd: started");
        reconcile();
    }
    /* Apple's hotspot and Wi-Fi code answers through the main run loop
     * (dispatch_main would never run it); main-queue blocks run here too. */
    CFRunLoopRun();
    return 0;
}
