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
#include <sys/ioctl.h>
#include <sys/socket.h>
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

/* "iPhone", "iPad" or "iPod touch", for messages people see. */
static NSString *deviceWord(void)
{
    char m[64] = "";
    size_t n = sizeof(m);
    sysctlbyname("hw.machine", m, &n, NULL, 0);
    return !strncmp(m, "iPad", 4) ? @"iPad" : !strncmp(m, "iPod", 4) ? @"iPod touch" : @"iPhone";
}

/* vpn.log (the VPN helper's output) is emptied past 1 MB; launchd appends to
 * it, so truncating is safe. */
static void trimLog(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0 && st.st_size > 1024 * 1024)
        truncate(path, 0);
}

/* daemon.log (this service's output, opened by launchd) stays under 1 MB:
 * past that it's renamed daemon.log.old, replacing the previous one, and a
 * new daemon.log starts. Never more than two files, about 2 MB in all, and
 * the newest history is always kept. */
static void rotateOwnLog(void)
{
    const char *path = WT_DIR "/daemon.log";
    struct stat st;
    int fd;

    if (stat(path, &st) != 0 || st.st_size <= 1024 * 1024)
        return;
    rename(path, WT_DIR "/daemon.log.old");
    fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return;
    fflush(stdout);
    fflush(stderr);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO)
        close(fd);
    NSLog(@"wifitetherd: log: daemon.log reached 1 MB; the previous part is in daemon.log.old");
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

static void teardown(NSString *why)
{
    if (!g_applied)
        return;
    pfn_clear(g_anchor, NULL, 0);
    restoreFwd();
    pfn_stop();
    g_applied = 0;
    g_key[0] = 0;
    NSLog(@"wifitetherd: sharing stopped (%@)", why);
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

/* Process id of a running program by name (first match), or 0. */
static pid_t pidOf(const char *comm)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    struct kinfo_proc *procs;
    size_t n, i;
    pid_t found = 0;

    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0)
        return 0;
    len += len / 4;
    procs = malloc(len);
    if (!procs)
        return 0;
    if (sysctl(mib, 3, procs, &len, NULL, 0) == 0) {
        n = len / sizeof(struct kinfo_proc);
        for (i = 0; i < n && !found; i++)
            if (strcmp(procs[i].kp_proc.p_comm, comm) == 0)
                found = procs[i].kp_proc.p_pid;
    }
    free(procs);
    return found;
}

static void signalBootpd(void)
{
    pid_t p = pidOf("bootpd");
    if (p)
        kill(p, SIGHUP);   /* bootpd re-reads its settings */
}

/* ── The Share tweak ──────────────────────────────────────────────
 * Share patches iOS's hotspot service (misd) so it runs without a SIM.
 * Without it WiFi Tether can't do anything, so it acts as switched off.
 * Read from dpkg's database, only when that file changes. */
#define DPKG_STATUS "/var/jb/var/lib/dpkg/status"
#define SHARE_PKG   "com.rostane.share"

static int shareInstalled(void)
{
    static time_t mtime;
    static off_t size;
    static int cached = -1;
    struct stat st;
    NSString *db;
    NSRange r;

    if (stat(DPKG_STATUS, &st) != 0)
        return cached < 0 ? 1 : cached;   /* can't tell: don't block */
    if (cached >= 0 && st.st_mtime == mtime && st.st_size == size)
        return cached;
    mtime = st.st_mtime;
    size = st.st_size;
    db = [NSString stringWithContentsOfFile:@DPKG_STATUS encoding:NSUTF8StringEncoding error:nil];
    if (!db)
        return cached < 0 ? 1 : cached;
    cached = 0;
    r = [db rangeOfString:@"Package: " SHARE_PKG "\n"];
    if (r.location != NSNotFound) {
        NSUInteger start = r.location;
        NSRange end = [db rangeOfString:@"\n\n" options:0 range:NSMakeRange(start, db.length - start)];
        NSString *stanza = [db substringWithRange:NSMakeRange(start, (end.location == NSNotFound ? db.length : end.location) - start)];
        cached = [stanza containsString:@"Status: install ok installed"];
    }
    return cached;
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
static pid_t g_misdPid;           /* the hotspot service we're connected to */

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
    g_misdPid = pidOf("misd");
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

/* ── Airplane mode ────────────────────────────────────────────────
 * Personal Hotspot can't run in airplane mode (iOS stops it, reason 4, and
 * ignores requests). Switching WiFi Tether on turns airplane mode off and
 * remembers that (WT_AIR_RESTORE); switching off turns it back on.
 * RadiosPreferences (AppSupport) is what Control Center's button uses. */
#define WT_AIR_RESTORE WT_DIR "/airplane-restore"
#define RADIOS_PLIST "/Library/Preferences/SystemConfiguration/com.apple.radios.plist"
static id g_radios;

/* 1 on, 0 off, -1 unknown */
static int airplaneMode(void)
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@RADIOS_PLIST];
    id v = d[@"AirplaneMode"];
    if ([v respondsToSelector:@selector(boolValue)])
        return [v boolValue] ? 1 : 0;
    v = scValue(@"com.apple.MobileInternetSharing")[@"Reason"];
    return d ? 0 : ([v intValue] == 4 ? 1 : -1);
}

static int setAirplaneMode(BOOL on)
{
    SEL set = NSSelectorFromString(@"setAirplaneMode:"), sync = NSSelectorFromString(@"synchronize");
    if (g_hsCrashed)
        return -1;
    if (!g_radios) {
        Class c;
        dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
        c = objc_getClass("RadiosPreferences");
        if (c)
            g_radios = ((id (*)(id, SEL))objc_msgSend)(((id (*)(Class, SEL))objc_msgSend)(c, @selector(alloc)), @selector(init));
    }
    if (![g_radios respondsToSelector:set]) {
        NSLog(@"wifitetherd: can't change airplane mode (RadiosPreferences missing)");
        return -1;
    }
    guardBegin("airplane");
    ((void (*)(id, SEL, BOOL))objc_msgSend)(g_radios, set, on);
    if ([g_radios respondsToSelector:sync])
        ((void (*)(id, SEL))objc_msgSend)(g_radios, sync);
    guardEnd();
    NSLog(@"wifitetherd: airplane mode %s", on ? "on" : "off");
    return 0;
}

/* A system pop-up (CFUserNotification, shown by SpringBoard). */
typedef struct __WTUserNotification *WTUserNotificationRef;
static WTUserNotificationRef g_alert;
static CFRunLoopSourceRef g_alertSource;

static void alertAnswered(WTUserNotificationRef n, CFOptionFlags response)
{
    if (g_alertSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), g_alertSource, kCFRunLoopDefaultMode);
        CFRelease(g_alertSource);
        g_alertSource = NULL;
    }
    if (g_alert) {
        CFRelease((CFTypeRef)g_alert);
        g_alert = NULL;
    }
    if ((response & 3) == 0) {   /* default button: turn airplane mode off */
        if (setAirplaneMode(NO) == 0) {
            FILE *f = fopen(WT_AIR_RESTORE, "w");
            if (f)
                fclose(f);
        }
    } else {
        NSLog(@"wifitetherd: keeping airplane mode on");
    }
}

static void askAirplane(NSString *message)
{
    static WTUserNotificationRef (*create)(CFAllocatorRef, CFTimeInterval, CFOptionFlags, SInt32 *, CFDictionaryRef);
    static CFRunLoopSourceRef (*source)(CFAllocatorRef, WTUserNotificationRef,
                                        void (*)(WTUserNotificationRef, CFOptionFlags), CFIndex);
    SInt32 error = 0;
    NSDictionary *d;

    if (g_alert)
        return;   /* one at a time */
    if (!create) {
        create = dlsym(RTLD_DEFAULT, "CFUserNotificationCreate");
        source = dlsym(RTLD_DEFAULT, "CFUserNotificationCreateRunLoopSource");
    }
    if (!create || !source)
        return;
    d = @{ @"AlertHeader": @"Airplane Mode Is On",
           @"AlertMessage": message,
           @"DefaultButtonTitle": @"Turn Off Airplane Mode",
           @"AlternateButtonTitle": @"Keep It On" };
    g_alert = create(kCFAllocatorDefault, 120, 0, &error, (__bridge CFDictionaryRef)d);
    if (!g_alert) {
        NSLog(@"wifitetherd: couldn't show the airplane mode pop-up (%d)", (int)error);
        return;
    }
    g_alertSource = source(kCFAllocatorDefault, g_alert, alertAnswered, 0);
    if (g_alertSource)
        CFRunLoopAddSource(CFRunLoopGetMain(), g_alertSource, kCFRunLoopDefaultMode);
}

/* ── Is a computer plugged in? ─────────────────────────────────────
 * From the battery's entry in the I/O registry (IOPMPowerSource, the same data
 * that shows the phone charging):
 *   - ExternalConnected: anything plugged in at all. With nothing, there's no
 *     computer, so nothing to wait for or retry.
 *   - AdapterDetails: what it is. A computer's USB port reports the USB host
 *     family codes; chargers report others. (IOKit's
 *     IOPMCopyExternalPowerAdapterDetails, used before, isn't there on iOS 15,
 *     so it's only the fallback.)
 * 1 computer, 0 nothing or a charger, 2 power of unknown kind. */
static CFTypeRef powerProp(CFStringRef key)   /* retained, or NULL */
{
    static CFMutableDictionaryRef (*matching)(const char *);
    static uint32_t (*getService)(uint32_t, CFDictionaryRef);
    static CFTypeRef (*getProp)(uint32_t, CFStringRef, CFAllocatorRef, uint32_t);
    static uint32_t svc;
    static int tried;

    if (!tried) {
        tried = 1;
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        matching = dlsym(RTLD_DEFAULT, "IOServiceMatching");
        getService = dlsym(RTLD_DEFAULT, "IOServiceGetMatchingService");
        getProp = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
    }
    if (!svc && matching && getService)
        svc = getService(0 /* kIOMainPortDefault */, matching("IOPMPowerSource"));   /* consumes the dictionary */
    return svc && getProp ? getProp(svc, key, kCFAllocatorDefault, 0) : NULL;
}

static int externalPower(void)   /* 1 yes, 0 no, -1 can't tell */
{
    CFTypeRef v = powerProp(CFSTR("ExternalConnected"));
    int r = -1;

    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID())
            r = CFBooleanGetValue(v) ? 1 : 0;
        CFRelease(v);
    }
    return r;
}

static int computerPlugged(void)
{
    static CFDictionaryRef (*details)(void);
    static int tried, lastExt = -2;
    static NSString *lastAd;
    NSDictionary *ad = nil;
    NSNumber *n;
    NSString *adText;
    uint32_t fam;
    int ext = externalPower();

    if (!tried) {
        tried = 1;
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        details = dlsym(RTLD_DEFAULT, "IOPMCopyExternalPowerAdapterDetails");
    }
    if (ext != 0) {
        CFTypeRef v = powerProp(CFSTR("AdapterDetails"));
        if (v && CFGetTypeID(v) == CFDictionaryGetTypeID())
            ad = CFBridgingRelease(v);
        else if (v)
            CFRelease(v);
        if (!ad && details) {
            CFDictionaryRef d = details();
            if (d)
                ad = CFBridgingRelease(d);
        }
    }
    n = [ad[@"FamilyCode"] isKindOfClass:NSNumber.class] ? ad[@"FamilyCode"] : nil;
    fam = (uint32_t)n.unsignedIntValue;

    /* What the phone reports, logged when it changes, to learn how a computer
     * and a charger look on each device. */
    adText = ext == 0 ? @"" : !ad ? @"; adapter details unavailable"
           : [NSString stringWithFormat:@"; adapter %@%@%@", n ? [NSString stringWithFormat:@"family 0x%08x", fam] : @"family unknown",
              [ad[@"Description"] isKindOfClass:NSString.class] ? [NSString stringWithFormat:@", \"%@\"", ad[@"Description"]] : @"",
              [ad[@"Watts"] isKindOfClass:NSNumber.class] ? [NSString stringWithFormat:@", %@ W", ad[@"Watts"]] : @""];
    if (ext != lastExt || ![adText isEqualToString:lastAd]) {
        NSLog(@"wifitetherd: power: %s%@", ext == 1 ? "plugged in" : ext == 0 ? "not plugged in" : "can't tell", adText);
        lastExt = ext;
        lastAd = adText;
    }
    if (ext == 0)
        return 0;
    if (!ad)
        return ext == 1 || !details ? 2 : 0;   /* power but nothing says what kind: could be a computer */
    if (!n)
        return 2;
    /* kIOPSFamilyCodeUSBHost, ...USBHostSuspended, ...USBChargingPortDownstream
     * (a computer port that charges faster) */
    if (fam == 0xE0004000u || fam == 0xE0004001u || fam == 0xE0004005u)
        return 1;
    if (fam == 0xE0004007u || fam == 0)   /* ...USBUnknown */
        return 2;
    return 0;   /* a charger */
}

static time_t g_usbWaitStart, g_usbNextRetry, g_usbRestartUntil;
static int    g_usbTries;

static time_t g_lastWifiUp;       /* last time Wi-Fi had an address */
static time_t g_hsNextTry, g_hsWindow;
static int    g_hsTries;
static time_t g_wifiNextFix;
static int    g_wifiFixStep;
static time_t g_b5QuietUntil;     /* moving to 5 GHz: a short disconnect, not a drop */
static int    g_lastEnabled = -1;

/* Called every second while the switch is on. Returns a message for the app, or nil. */
static NSString *controlHotspot(const WTIf *up, const WTIf *lan, int air)
{
    time_t now = time(NULL);
    int hs = hotspotState();
    BOOL hsOn = hs == MIS_ON || lan->ok;

    if (air == 1)
        return @"Personal Hotspot can't run in airplane mode. Turn airplane mode off; Wi-Fi can stay on.";
    if (!hsOn && now < g_usbRestartUntil)
        return nil;   /* we're restarting it for the computer (see usbWait) */

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
                    ? [NSString stringWithFormat:@"Turning Personal Hotspot on automatically crashed on this %@, so it's off. "
                                                 @"Turn Personal Hotspot on in Settings.", deviceWord()]
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
    if (!up->ok && g_lastWifiUp && now - g_lastWifiUp < 120 && g_wifiFixStep < 3 && now >= g_wifiNextFix &&
        now >= g_b5QuietUntil) {
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

/* ── How the computer has set up the phone's USB side (read-only) ──────
 * From the phone's own USB entries in the I/O registry. A computer picks one
 * of the phone's USB configurations; on an iPhone 6s with iOS 15: 3 (photos
 * and Apple's device connection), 4 (the same plus the tethering network,
 * "AppleUSBEthernet"), and 5 from a Mac (Apple's private network instead).
 * Once Personal Hotspot is on, the computer's Apple software switches to 4
 * and starts using the network (HostAttached on AppleUSBEthernetDevice).
 * So, while waiting:
 *   - nothing picked: nothing plugged in, or a charger;
 *   - tethering not picked yet: the computer hasn't caught up, and a
 *     hotspot restart makes it look again;
 *   - tethering picked but not used: the computer is choosing not to (a Mac
 *     that's online another way); restarts change nothing.
 * ok = 0 where these entries aren't there (other devices or iOS versions):
 * then the power checks above decide, as before. */
typedef struct { int ok, configured, config, eth, ethUsed; } WTUSB;

static WTUSB usbState(void)
{
    static CFMutableDictionaryRef (*matching)(const char *);
    static int (*getServices)(uint32_t, CFDictionaryRef, uint32_t *);
    static uint32_t (*next)(uint32_t);
    static int (*release)(uint32_t);
    static int (*getName)(uint32_t, char *);
    static CFTypeRef (*getProp)(uint32_t, CFStringRef, CFAllocatorRef, uint32_t);
    static int tried;
    WTUSB u = {0, 0, 0, 0, 0};
    uint32_t it = 0, e;

    if (!tried) {
        tried = 1;
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        matching = dlsym(RTLD_DEFAULT, "IOServiceMatching");
        getServices = dlsym(RTLD_DEFAULT, "IOServiceGetMatchingServices");
        next = dlsym(RTLD_DEFAULT, "IOIteratorNext");
        release = dlsym(RTLD_DEFAULT, "IOObjectRelease");
        getName = dlsym(RTLD_DEFAULT, "IORegistryEntryGetName");
        getProp = dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
    }
    if (!matching || !getServices || !next || !release || !getName || !getProp)
        return u;
    int (^num)(uint32_t, CFStringRef) = ^int(uint32_t entry, CFStringRef key) {
        CFTypeRef v = getProp(entry, key, kCFAllocatorDefault, 0);
        int r = -1;
        if (v) {
            if (CFGetTypeID(v) == CFNumberGetTypeID() || CFGetTypeID(v) == CFBooleanGetTypeID())
                r = [(__bridge NSNumber *)v intValue];
            CFRelease(v);
        }
        return r;
    };
    if (getServices(0, matching("IOUSBDeviceInterface"), &it) == 0 && it) {   /* consumes the dictionary */
        while ((e = next(it))) {
            char name[128] = "";
            int active = num(e, CFSTR("IsActive"));
            getName(e, name);
            u.ok = 1;
            if (active > 0) {
                u.configured = 1;
                u.config = num(e, CFSTR("Configuration"));
                if (strcmp(name, "AppleUSBEthernet") == 0)
                    u.eth = 1;
            }
            release(e);
        }
        release(it);
    }
    it = 0;
    if (u.eth && getServices(0, matching("AppleUSBEthernetDevice"), &it) == 0 && it) {
        while ((e = next(it))) {
            if (num(e, CFSTR("HostAttached")) > 0)
                u.ethUsed = 1;
            release(e);
        }
        release(it);
    }
    return u;
}

/* iOS's lockdown service posts these when a computer running Apple's device
 * software (Finder, iTunes or Apple Devices) starts or stops talking to the
 * phone over USB. That says a computer is connected, though not whether it
 * will use the phone for internet: a Mac that's online another way keeps
 * "iPhone USB" on standby ("Attached"). Used for the waiting message and the
 * log. -1: no word since WiFi Tether started. */
static int g_hostAttached = -1;

static void hostWatchStart(void)
{
    static int onTok = -1, offTok = -1;

    if (onTok >= 0)
        return;
    notify_register_dispatch("com.apple.mobile.lockdown.host_attached", &onTok, dispatch_get_main_queue(), ^(int t) {
        if (g_hostAttached != 1)
            NSLog(@"wifitetherd: a computer is connected to the %@ (its Apple device software)", deviceWord());
        g_hostAttached = 1;
    });
    notify_register_dispatch("com.apple.mobile.lockdown.host_detached", &offTok, dispatch_get_main_queue(), ^(int t) {
        if (g_hostAttached != 0)
            NSLog(@"wifitetherd: the computer's Apple device software disconnected");
        g_hostAttached = 0;
    });
}

/* Hotspot on, but the computer isn't using the phone yet. When the hotspot
 * comes on with the cable already in, Windows sometimes misses it; restarting
 * the hotspot is the software version of replugging, and makes it look again.
 * But a restart while the computer is still setting up starts it over:
 * Windows can take up to about 15 seconds by itself. So the first try comes
 * after 15 seconds, the next ones 15-25 seconds apart, and never within 10
 * seconds of the computer changing the phone's USB setup (it's busy). No tries
 * at all while the computer has picked the tethering network but isn't using
 * it (a Mac that's online another way): restarts change nothing there. After
 * 4 tries, or 30 seconds of that, the app shows a Reconnect button
 * (WT_RECONNECT), which tries straight away and starts the tries again.
 * Returns a short status detail; nil if no computer is plugged in. */
#define USB_TRIES    4
#define WT_RECONNECT "com.wifitether.reconnect"
static int    g_usbDone;          /* the automatic tries are over */
static int    g_usbForce;         /* Reconnect: try now */
static int    g_usbKey = -2;      /* the USB setup last seen, to notice changes */
static time_t g_usbChangedAt, g_usbStandbySince, g_usbAbsentSince;

static int usbStandby(time_t now)   /* tethering picked but not used, for 8 s or more */
{
    return g_usbStandbySince && now - g_usbStandbySince >= 8;
}

static NSString *usbWait(void)
{
    time_t now = time(NULL);
    WTUSB u = usbState();
    int pc = computerPlugged();   /* power (logged); decides where the USB setup can't be read */
    int present = u.ok ? u.configured : (pc != 0 || g_hostAttached == 1);
    int key = u.ok ? (u.configured | (u.config & 0x3f) << 1 | u.eth << 7 | u.ethUsed << 8) : -1;
    static const int gaps[USB_TRIES] = { 15, 15, 20, 25 };   /* after tries 1-4 */

    if (key != g_usbKey) {
        g_usbKey = key;
        g_usbChangedAt = now;
        if (u.ok)
            NSLog(@"wifitetherd: usb: %@", !u.configured ? @"no computer (nothing plugged in, or a charger)"
                  : [NSString stringWithFormat:@"computer connected (configuration %d); tethering %s", u.config,
                     !u.eth ? "not picked yet" : u.ethUsed ? "in use" : "picked but not in use"]);
    }
    /* The computer drops the USB setup for a moment whenever it re-reads it
     * (after a restart, or switching to tethering): only 5 seconds with no
     * computer means it's gone. */
    if (!present) {
        if (!g_usbAbsentSince)
            g_usbAbsentSince = now;
        if (!g_usbWaitStart || now - g_usbAbsentSince >= 5) {
            g_usbWaitStart = g_usbStandbySince = 0;
            g_usbDone = g_usbForce = 0;
            return nil;
        }
    } else {
        g_usbAbsentSince = 0;
    }
    if (!g_usbWaitStart) {
        g_usbWaitStart = now;
        g_usbTries = 0;
        g_usbDone = 0;
        g_usbNextRetry = now + 15;
    }
    if (u.ok && u.eth && !u.ethUsed) {
        if (!g_usbStandbySince)
            g_usbStandbySince = now;
    } else {
        g_usbStandbySince = 0;
    }
    if (g_usbForce || (!g_usbDone && !usbStandby(now) && now >= g_usbNextRetry && now - g_usbChangedAt >= 10)) {
        if (!g_usbForce && g_usbTries >= USB_TRIES) {
            g_usbDone = 1;
            NSLog(@"wifitetherd: the computer still hasn't connected after %d tries", USB_TRIES);
        } else {
            g_usbForce = 0;
            g_usbTries++;
            NSLog(@"wifitetherd: computer hasn't connected; restarting Personal Hotspot (try %d)", g_usbTries);
            g_usbRestartUntil = now + 8;
            hotspotSet(NO);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                hotspotSet(YES);
            });
            g_usbNextRetry = now + gaps[g_usbTries - 1 < USB_TRIES ? g_usbTries - 1 : USB_TRIES - 1];
        }
    }
    if (usbStandby(now))
        return [NSString stringWithFormat:@"The computer isn't using it. On a Mac, turn its Wi-Fi off, or to keep "
                                          @"Wi-Fi on: System Settings → Network → ⋯ → Set Service Order, and drag "
                                          @"%@ USB to the top.", deviceWord()];
    if (g_usbDone)
        return @"Tap Reconnect, or unplug and plug back in.";
    return g_usbTries ? [NSString stringWithFormat:@"Retrying (%d of %d)…", g_usbTries, USB_TRIES] : @"";
}

/* The app's Reconnect button: try now, then start the tries again. */
static void usbReconnect(void)
{
    if (!g_usbWaitStart)
        return;
    NSLog(@"wifitetherd: Reconnect tapped; trying again");
    g_usbTries = 0;
    g_usbDone = 0;
    g_usbForce = 1;
}

/* Why sharing stopped, for the log. "The USB network went away" while the
 * cable still reads as plugged in means the computer (or a loose connection)
 * reset the USB link; not plugged in means the cable or port lost contact. */
static NSString *stopReason(int en, const WTIf *up, const WTIf *lan)
{
    if (!en)
        return @"switched off";
    if (!up->ok)
        return @"Wi-Fi has no connection";
    if (!lan->ok) {
        if (hotspotState() != MIS_ON)
            return @"Personal Hotspot went off";
        switch (computerPlugged()) {
        case 0:  return @"the USB network to the computer went away; no computer reads as plugged in";
        case 1:  return @"the USB network to the computer went away; the cable still reads as plugged in";
        default: return @"the USB network to the computer went away";
        }
    }
    return @"settings changed";
}

/* When the hotspot's DHCP server (bootpd) gives the computer an address, from
 * its lease file (read-only, if iOS keeps it where macOS does), so the log
 * shows whether the computer got that far. Only addresses on the hotspot's
 * subnet are logged, and nothing about the computer itself. */
#define DHCP_LEASES "/var/db/dhcpd_leases"

static void dhcpLeaseCheck(const WTIf *lan)
{
    static struct timespec seenTime;
    static NSMutableDictionary *seen;   /* address -> lease expiry */
    static int first = 1, missingLogged;
    struct stat sb;
    NSString *text;

    if (!lan->ok)
        return;
    if (stat(DHCP_LEASES, &sb) != 0) {
        if (!missingLogged) {
            NSLog(@"wifitetherd: can't see the hotspot's DHCP leases (" DHCP_LEASES "), "
                  "so the log won't say when the computer gets an address");
            missingLogged = 1;
        }
        return;
    }
    if (!first && sb.st_mtimespec.tv_sec == seenTime.tv_sec && sb.st_mtimespec.tv_nsec == seenTime.tv_nsec)
        return;
    seenTime = sb.st_mtimespec;
    text = [NSString stringWithContentsOfFile:@DHCP_LEASES encoding:NSUTF8StringEncoding error:nil];
    if (!text)
        return;
    if (!seen)
        seen = [NSMutableDictionary dictionary];
    for (NSString *entry in [text componentsSeparatedByString:@"}"]) {
        NSString *ip = nil, *lease = nil;
        struct in_addr a;
        for (NSString *line in [entry componentsSeparatedByString:@"\n"]) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([t hasPrefix:@"ip_address="])
                ip = [t substringFromIndex:11];
            else if ([t hasPrefix:@"lease="])
                lease = [t substringFromIndex:6];
        }
        if (!ip || !lease || inet_pton(AF_INET, ip.UTF8String, &a) != 1)
            continue;
        if ((a.s_addr & lan->mask) != (lan->ip & lan->mask) || a.s_addr == lan->ip)
            continue;
        if ([seen[ip] isEqualToString:lease])
            continue;
        if (!first)   /* leases from before WiFi Tether started aren't news */
            NSLog(@"wifitetherd: the hotspot's DHCP gave the computer %@", ip);
        seen[ip] = lease;
    }
    first = 0;
}

/* ---------------------------------------------------------------------------
 * Wi-Fi band switches: Force 5 GHz / Force 2.4 GHz (their own switches in the
 * app; they work with sharing off too, and only one is on at a time).
 *
 * iOS has no band setting, and routers with one network name on both bands
 * often push an iPhone from one band to the other ("band steering"). On the
 * iPhone this was built on, the router's disconnect moves it to the other
 * radio within milliseconds, before iOS does anything, so nothing on the phone
 * can prevent it; WiFi Tether undoes it instead:
 *   - Wi-Fi driver events (a kernel event socket, read-only) say the moment
 *     the connection changes; there's also a check every 5 seconds.
 *   - The forced band's radio is remembered from a scan.
 *   - Move back by hand-over first: the add-on in wifid (src/roam) asks iOS
 *     for its own roam to that band, with no disconnect.
 *   - The first hand-over after the iPhone has sat on one band for a while
 *     often doesn't move it (the chip hasn't seen the other band lately):
 *     then find the radio (iOS's recently seen networks, else a scan and one
 *     more hand-over).
 *   - Fallback: disconnect, then join the radio with the other band's radios
 *     on that join's avoid list (BSS_BLACKLIST).
 *   - If iOS won't scan, turn Wi-Fi off and on (as toggling it in Settings
 *     does), at most every 10 minutes.
 *   - Back off when it doesn't stick, so Wi-Fi stays usable.
 * Nothing about the network or its saved settings is changed.
 * docs/band-switching-research.md has what was tried and what worked.
 * ------------------------------------------------------------------------- */
#define WT_PREFER5     WT_DIR "/prefer-5ghz"
#define WT_PREFER24    WT_DIR "/prefer-24ghz"
#define B5_MIN_RSSI    (-85)   /* weaker than this, it can't really connect */

typedef void (*B5ScanCb)(void *dev, CFArrayRef results, void *err, void *ctx);
typedef void (*B5JoinCb)(void *dev, void *net, CFDictionaryRef info, void *err, void *ctx);

static struct {
    int          tried, ok;
    void        *mgr, *dev;
    CFArrayRef   (*copyDevices)(void *);
    void        *(*copyCurrent)(void *);
    CFTypeRef    (*getProp)(void *, CFStringRef);
    CFStringRef  (*getSSID)(void *);
    void         (*scan)(void *, CFDictionaryRef, B5ScanCb, void *);
    void         (*join)(void *, void *, B5JoinCb, CFDictionaryRef);
    void         (*disassociate)(void *);
    CFArrayRef   (*copyKnown)(void *);
    CFStringRef  (*copyPassword)(void *);
    void         (*setPassword)(void *, CFStringRef);
    void         (*setPower)(void *, bool);
    int          (*getPower)(void *);
    CFDictionaryRef (*copyRecord)(void *);
    void         (*setProp)(void *, CFStringRef, CFTypeRef);
} B5;

static dispatch_source_t g_b5Timer;
static int         g_b5Running;
static NSString   *g_b5State = @"off";
static int         g_b5Rssi;                 /* the forced band's signal, for the app */
static int         g_b5Busy;                 /* a scan or join is in progress */
static time_t      g_b5BusySince, g_b5NextTry, g_b5LastJoin;
static int         g_b5JoinTries;            /* joins in this move */
static int         g_b5Rescued;              /* already turned Wi-Fi off and on after this move */
static CFStringRef g_b5SSID;                 /* the network the iPhone is on */
static void       *g_b5Joining;              /* the radio being moved to (retained for the move) */
static NSArray    *g_b5Avoid;                /* this network's other-band BSSIDs, 6-byte NSData each */
static void       *g_b5Target;               /* the forced band's radio from the last scan (retained) */
static time_t      g_b5TargetAt, g_b5LandedAt;
static int         g_b5QuickBacks;           /* times in a row iOS went back within 30 s */
static time_t      g_b5LastWifi, g_b5NextScan5;

/* The hand-over add-on in wifid (src/roam): asks iOS to roam to 5 GHz
 * without disconnecting. */
#define WT_ROAM_REQUEST "com.wifitether.roam5"
#define WT_ROAM_READY   "com.wifitether.roam5.ready"
#define WT_ROAM_DONE    "com.wifitether.roam5.done"
static int         g_b5HandReady = -1;       /* add-on loaded in wifid: -1 not checked, 0 no, 1 yes */
static int         g_b5HandWorked;           /* a hand-over has worked since Force 5 GHz went on */
static int         g_b5HandFails;            /* moves in a row where hand-overs didn't work */
static int         g_b5HandTries;            /* hand-overs in this move */
static time_t      g_b5HandOffUntil;         /* hand-overs paused (not working here) until */
static pid_t       g_b5HandPid;              /* the wifid asked for the last hand-over */
static int         g_b5HandBroken;           /* wifid restarted right after a hand-over: off until the switch is */
static int         g_b5ScanThenJoin;         /* a hand-over with no radio known didn't work: scan, then join */
static int         g_b5ScanCache;            /* the scan in flight reads iOS's recently seen networks only */
static int         g_b5SkipCache;            /* a join to a radio failed: the next lookup scans for real */
static int         g_b5SeenBands;            /* bands this network was seen on: 1 = 2.4 GHz, 2 = 5 GHz */
static int         g_b5Kicks, g_b5MoveCount;  /* since Force went on, for the status line */
static time_t      g_b5LastKick, g_b5LastBeat;
static int         g_b5ScanLearn;            /* the scan in flight only learns the radio (already on the band) */
static int         g_b5LearnFails;           /* learning scans iOS turned down in a row */
static int         g_b5Band;                 /* the band it's on (2, 5, 6; 0 unknown), for the app */
static double      g_b5LastScanCall;         /* iOS rejects scan requests less than 0.1 s apart */
static unsigned    g_b5ScanGen;              /* which scan request an answer (or its time-out) belongs to */
static int         g_b5HandAfterScan;        /* 1: after the scan, hand over again before joining; 2: done */
static int         g_b5MoveScanFails;        /* scans in this move iOS turned down or didn't answer */
static time_t      g_b5PowerCycledAt;        /* last time Wi-Fi was turned off and on to unstick a move */
static double      g_b5OwnUntil;             /* driver events until then come from our own move */

static void b5Tick(void);
static void b5TickSoon(double seconds);
static void indNoteBand(int band);   /* status indicators (below): the band just read */
static void indEventSoon(void);      /* status indicators: the Wi-Fi driver reported a change */
static int  indWanted(void);

/* If one of these private calls ever crashes the service, it must not take
 * sharing down with it on every restart: a file marks a call in progress, and
 * after a crash the 5 GHz feature stays off until its switch is turned off and
 * on again (like the hotspot calls). */
#define WT_B5_GUARD WT_DIR "/band5-call"
static int g_b5Crashed;

static void b5GuardBegin(const char *what)
{
    FILE *f = fopen(WT_B5_GUARD, "w");
    if (f) {
        fputs(what, f);
        fclose(f);
    }
}

static void b5GuardEnd(void)
{
    unlink(WT_B5_GUARD);
}

static int b5Init(void)
{
    void *(*create)(CFAllocatorRef, int);
    void (*schedule)(void *, CFRunLoopRef, CFStringRef);

    if (B5.tried)
        return B5.ok;
    B5.tried = 1;
    dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    create = dlsym(RTLD_DEFAULT, "WiFiManagerClientCreate");
    schedule = dlsym(RTLD_DEFAULT, "WiFiManagerClientScheduleWithRunLoop");
    B5.copyDevices = dlsym(RTLD_DEFAULT, "WiFiManagerClientCopyDevices");
    B5.copyCurrent = dlsym(RTLD_DEFAULT, "WiFiDeviceClientCopyCurrentNetwork");
    B5.getProp = dlsym(RTLD_DEFAULT, "WiFiNetworkGetProperty");
    B5.getSSID = dlsym(RTLD_DEFAULT, "WiFiNetworkGetSSID");
    B5.scan = dlsym(RTLD_DEFAULT, "WiFiDeviceClientScanAsync");
    B5.join = dlsym(RTLD_DEFAULT, "WiFiDeviceClientAssociateAsync");
    B5.disassociate = dlsym(RTLD_DEFAULT, "WiFiDeviceClientDisassociate");
    B5.copyKnown = dlsym(RTLD_DEFAULT, "WiFiManagerClientCopyNetworks");
    B5.copyPassword = dlsym(RTLD_DEFAULT, "WiFiNetworkCopyPassword");
    B5.setPassword = dlsym(RTLD_DEFAULT, "WiFiNetworkSetPassword");
    B5.setPower = dlsym(RTLD_DEFAULT, "WiFiManagerClientSetPower");
    B5.getPower = dlsym(RTLD_DEFAULT, "WiFiManagerClientGetPower");
    B5.copyRecord = dlsym(RTLD_DEFAULT, "WiFiNetworkCopyRecord");
    B5.setProp = dlsym(RTLD_DEFAULT, "WiFiNetworkSetProperty");
    if (!create || !schedule || !B5.copyDevices || !B5.copyCurrent || !B5.getProp ||
        !B5.getSSID || !B5.scan || !B5.join) {
        NSLog(@"wifitetherd: band: iOS's Wi-Fi functions weren't found; not available");
        return 0;
    }
    B5.mgr = create(kCFAllocatorDefault, 0);
    if (!B5.mgr) {
        NSLog(@"wifitetherd: band: couldn't connect to iOS's Wi-Fi service");
        return 0;
    }
    schedule(B5.mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);   /* scan/join answers */
    B5.ok = 1;
    return 1;
}

static int b5Int(void *net, CFStringRef key)
{
    CFTypeRef v = B5.getProp(net, key);
    int i = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue(v, kCFNumberIntType, &i);
    return i;
}

/* 2 = 2.4 GHz, 5 = 5 GHz, 6 = 6 GHz, 0 = can't tell */
static int b5Band(void *net)
{
    int c = b5Int(net, CFSTR("CHANNEL")), f = b5Int(net, CFSTR("CHANNEL_FLAGS"));
    if (f & 0x2000)              return 6;   /* 6 GHz channel numbers overlap the others */
    if (c >= 1 && c <= 14)       return 2;
    if (c >= 32 && c <= 177)     return 5;
    if (f & 0x10)                return 5;
    if (f & 0x8)                 return 2;
    return 0;
}

/* The band Force keeps the iPhone on: 5 (Force 5 GHz) or 2 (Force 2.4 GHz).
 * The rest of this code was written for 5 GHz; "on5" and the band5* status
 * keys mean "on the wanted band" either way. */
static int g_b5Want = 5;
static int b5OnWant(int band) { return g_b5Want == 2 ? band == 2 : band >= 5; }
static const char *b5WantName(void) { return g_b5Want == 2 ? "2.4 GHz" : "5 GHz"; }
static const char *b5OtherName(void) { return g_b5Want == 2 ? "5 GHz" : "2.4 GHz"; }
static const char *b5BandName(int band)
{
    return band < 0 ? "no Wi-Fi" : band == 2 ? "2.4 GHz" : band == 5 ? "5 GHz" : band == 6 ? "6 GHz" : "an unknown band";
}

/* Wi-Fi off, then on again 1.5 s later, like toggling it in Settings. Checks
 * afterwards that it really came back on, so it's never left off. */
static void b5PowerOn(int tries)
{
    if (B5.getPower && B5.getPower(B5.mgr) != 0)
        return;
    if (tries >= 3) {
        NSLog(@"wifitetherd: band: Wi-Fi didn't come back on; turn it on in Settings");
        return;
    }
    if (tries)
        NSLog(@"wifitetherd: band: Wi-Fi still off; turning it on again");
    b5GuardBegin("power");
    B5.setPower(B5.mgr, true);
    b5GuardEnd();
    if (B5.getPower)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            b5PowerOn(tries + 1);
        });
}

static void b5Power(void)
{
    if (!B5.setPower)
        return;
    b5GuardBegin("power");
    B5.setPower(B5.mgr, false);
    b5GuardEnd();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ b5PowerOn(0); });
}

static NSString *b5Str(NSDictionary *rec, NSString *key)
{
    id v = rec[key];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

/* "aa:bb:cc:dd:ee:ff" (iOS sometimes drops leading zeros: "a:b:c:...") -> 6 bytes. */
static NSData *b5BSSIDBytes(NSString *s)
{
    NSArray *parts = [s componentsSeparatedByString:@":"];
    unsigned char b[6];
    if (parts.count != 6)
        return nil;
    for (int i = 0; i < 6; i++) {
        unsigned v = 0;
        NSScanner *sc = [NSScanner scannerWithString:parts[i]];
        if (![sc scanHexInt:&v] || v > 0xff)
            return nil;
        b[i] = (unsigned char)v;
    }
    return [NSData dataWithBytes:b length:6];
}

static void b5EndMove(void)
{
    if (g_b5Joining) {
        CFRelease(g_b5Joining);
        g_b5Joining = NULL;
    }
    if (g_b5Busy)   /* the driver can report a hand-over's own events just after it's done */
        g_b5OwnUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    g_b5Busy = 0;
    b5GuardEnd();
}

/* The band now: 2, 5, 6, 0 can't tell, -1 not on Wi-Fi. */
static int b5CurrentBand(void)
{
    void *cur = B5.dev ? B5.copyCurrent(B5.dev) : NULL;
    int band;
    if (!cur)
        return -1;
    band = b5Band(cur);
    g_b5Band = band;
    if (b5OnWant(band))
        g_b5Rssi = b5Int(cur, CFSTR("RSSI"));
    CFRelease(cur);
    indNoteBand(band);
    return band;
}

static void b5JoinNow(void);
static double g_b5T0;   /* when this try started, for the log */
static int    g_b5FailStreak;   /* moves in a row that never landed on 5 GHz */

static int b5Ms(void)
{
    return (int)((CFAbsoluteTimeGetCurrent() - g_b5T0) * 1000);
}

static void b5DropTarget(void)
{
    if (g_b5Target)
        CFRelease(g_b5Target);
    g_b5Target = NULL;
    g_b5SkipCache = 1;   /* maybe it moved channel: don't trust older sightings */
}

/* After a join: watch every 0.1 s whether the iPhone ends up on 5 GHz. If it
 * settles on 2.4 GHz for a second (the router refused 5 GHz, or iOS's own
 * auto-join won), or gets nowhere for 10 seconds, the try failed. The router
 * can refuse 5 GHz for several seconds after it kicks the iPhone off, and
 * each try drops Wi-Fi for a moment, so tries are spaced out: up to 3, then
 * 2 and 8 seconds apart. A move that still doesn't work backs off: 1, then
 * 5, then 15 minutes. */
static void b5WatchLanding(int checks, int on24)
{
    int band = b5CurrentBand();

    if (!g_b5Running || !g_b5Joining) {
        b5EndMove();
        return;
    }
    if (b5OnWant(band)) {
        NSLog(@"wifitetherd: band: on %s (%d ms after disconnecting)", b5WantName(), b5Ms());
        g_b5LandedAt = time(NULL);
        g_b5State = @"on5";
        g_b5FailStreak = 0;
        g_b5NextTry = 0;   /* the next kick is answered straight away */
        b5EndMove();
        return;
    }
    on24 = band > 0 && !b5OnWant(band) ? on24 + 1 : 0;   /* settled on the other band */
    if (on24 < 10 && checks < 100) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            b5WatchLanding(checks + 1, on24);
        });
        return;
    }
    if (g_b5JoinTries < 3) {
        int gap = g_b5JoinTries == 1 ? 2 : 8;
        NSLog(@"wifitetherd: band: try %d ended up on %s; trying again in %d s", g_b5JoinTries,
              b5BandName(band), gap);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, gap * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!g_b5Running || !g_b5Joining) {
                b5EndMove();
                return;
            }
            b5JoinNow();
        });
        return;
    }
    {
        int wait = g_b5FailStreak == 0 ? 60 : g_b5FailStreak == 1 ? 300 : 900;
        g_b5FailStreak++;
        NSLog(@"wifitetherd: band: ended up on %s again; trying in %d minute(s)",
              b5BandName(band), wait / 60);
        g_b5State = @"notsticking";
        g_b5NextTry = time(NULL) + wait;
    }
    b5DropTarget();   /* maybe the radio moved channel: scan afresh next time */
    b5EndMove();
}

static void b5Joined(void *dev, void *net, CFDictionaryRef info, void *err, void *ctx)
{
    /* What iOS says it joined (for the log): which channel, and its answer. */
    {
        int ch = net ? b5Int(net, CFSTR("CHANNEL")) : 0;
        NSString *answer = info && CFGetTypeID(info) == CFDictionaryGetTypeID()
            ? [(__bridge NSDictionary *)info description] : @"";
        answer = [[answer componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                  componentsJoinedByString:@" "];
        if (answer.length > 600)
            answer = [answer substringToIndex:600];
        NSLog(@"wifitetherd: band: join answer: channel %d %@", ch, answer);
    }
    b5GuardEnd();
    if (err) {
        NSLog(@"wifitetherd: band: iOS couldn't join the %s radio (error %p, %d ms); trying again in 30 seconds",
              b5WantName(), err, b5Ms());
        g_b5State = @"failed";
        g_b5NextTry = time(NULL) + 30;
        b5DropTarget();
        b5EndMove();
        return;
    }
    NSLog(@"wifitetherd: band: join answered after %d ms", b5Ms());
    b5WatchLanding(0, 0);
}

/* Join only once the disconnect has actually happened: a join sent while
 * still connected is ignored, and auto-join then reconnects to 2.4 GHz. */
static void b5JoinWhenDisconnected(int waited)
{
    void *cur;

    if (!g_b5Running || !g_b5Joining) {
        b5EndMove();
        return;
    }
    cur = B5.copyCurrent(B5.dev);
    if (cur)
        CFRelease(cur);
    if (cur && waited < 3000) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            b5JoinWhenDisconnected(waited + 10);
        });
        return;
    }
    NSLog(@"wifitetherd: band: try %d: %s after %d ms; joining %s", g_b5JoinTries,
          cur ? "still connected" : "disconnected", b5Ms(), b5WantName());
    b5GuardBegin("join");
    B5.join(B5.dev, g_b5Joining, b5Joined, NULL);
}

/* Disconnect, then join the 5 GHz radio the moment the disconnect is done
 * (before auto-join picks 2.4 GHz again). */
static void b5JoinNow(void)
{
    time_t now = time(NULL);

    g_b5JoinTries++;
    g_b5Busy = 1;
    g_b5BusySince = g_b5LastJoin = now;
    g_b5Rescued = 0;
    g_b5QuietUntil = now + 40;   /* the brief disconnect isn't a Wi-Fi drop to fix */
    g_b5T0 = CFAbsoluteTimeGetCurrent();
    if (B5.disassociate)
        B5.disassociate(B5.dev);
    b5JoinWhenDisconnected(0);
}

static void b5Join(void *net, int rssi)
{
    int havePw = 0;

    /* A scan result has no password: give it the one saved for this network. */
    if (B5.copyKnown && B5.copyPassword && B5.setPassword) {
        CFArrayRef known = B5.copyKnown(B5.mgr);
        for (CFIndex i = 0; known && i < CFArrayGetCount(known) && !havePw; i++) {
            void *k = (void *)CFArrayGetValueAtIndex(known, i);
            CFStringRef s = B5.getSSID(k);
            if (s && CFStringCompare(s, g_b5SSID, 0) == kCFCompareEqualTo) {
                CFStringRef pw = B5.copyPassword(k);
                if (pw) {
                    B5.setPassword(net, pw);
                    CFRelease(pw);
                    havePw = 1;
                }
            }
        }
        if (known)
            CFRelease(known);
    }
    NSLog(@"wifitetherd: band: on %s; moving to the %s radio (channel %d, %d dBm)%s", b5OtherName(), b5WantName(),
          b5Int(net, CFSTR("CHANNEL")), rssi, havePw ? "" : ", saved password not readable");
    g_b5State = @"switching";
    g_b5NextTry = time(NULL) + 30;
    if (g_b5Joining)
        CFRelease(g_b5Joining);
    g_b5Joining = (void *)CFRetain(net);
    g_b5JoinTries = 0;
    /* Tell this join which radios to avoid: wifid hands a network's
     * BSS_BLACKLIST { BSS_BLACKLIST_BSSIDS: up to 3 six-byte BSSIDs } to the
     * Wi-Fi driver with the association (wifid _performAssociation), the same
     * way it does for its own joins. With 2.4 GHz excluded, iOS can't pick it. */
    if (g_b5Avoid.count && B5.setProp) {
        NSArray *avoid = g_b5Avoid.count > 3 ? [g_b5Avoid subarrayWithRange:NSMakeRange(0, 3)] : g_b5Avoid;
        B5.setProp(g_b5Joining, CFSTR("BSS_BLACKLIST"), (__bridge CFTypeRef)@{ @"BSS_BLACKLIST_BSSIDS": avoid });
        NSLog(@"wifitetherd: band: this join avoids %lu %s radio(s)", (unsigned long)avoid.count, b5OtherName());
    }
    b5JoinNow();
}

/* Is the hand-over add-on loaded in wifid? It publishes wifid's process id. */
static int b5HandoverReady(void)
{
    int tok, ready = 0;
    uint64_t pid = 0;

    if (notify_register_check(WT_ROAM_READY, &tok) == NOTIFY_STATUS_OK) {
        notify_get_state(tok, &pid);
        notify_cancel(tok);
    }
    ready = pid > 1 && kill((pid_t)pid, 0) == 0;
    if (ready)
        g_b5HandPid = (pid_t)pid;
    if (ready != g_b5HandReady)
        NSLog(@"wifitetherd: band: hand-over add-on %s", ready
              ? [NSString stringWithFormat:@"loaded in iOS's Wi-Fi service (pid %llu)", pid].UTF8String
              : "not loaded in iOS's Wi-Fi service; moving by disconnecting and rejoining");
    g_b5HandReady = ready;
    return ready;
}

/* Can a move start with a hand-over right now? */
static int b5HandAvailable(time_t now)
{
    return !g_b5HandBroken && now >= g_b5HandOffUntil && b5HandoverReady();
}

/* The add-on's answer to each request, for the log. */
static void b5HandoverListen(void)
{
    static int tok = -1;

    if (tok >= 0)
        return;
    notify_register_dispatch(WT_ROAM_DONE, &tok, dispatch_get_main_queue(), ^(int t) {
        uint64_t st = 0;
        notify_get_state(t, &st);
        if ((st & 0xff) != 1)
            NSLog(@"wifitetherd: band: the add-on couldn't ask for a hand-over (request %llu: %s)", st >> 8,
                  (st & 0xff) == 2 ? "iOS's roam manager wasn't found" : "unknown answer");
    });
}

static void b5Scanned(void *dev, CFArrayRef results, void *err, void *ctx);

/* Asks iOS for a scan; the answer goes to b5Scanned. learn: only to learn
 * the forced band's radio while already on it. fromCache: answer from the
 * networks iOS has seen recently (wifid's beacon cache, "BeaconCacheOnly"),
 * with no radio scan: instant, and never turned down as busy, which iOS
 * often does to real scans while on 5 GHz. If the radio isn't there, a real
 * scan follows. */
static unsigned g_b5ScanWaiting;   /* the scan request an answer is due for; 0 none */

/* iOS turns down a scan request that comes less than 0.1 s after the previous
 * one ("called 0.02s ago, rejecting") and never answers it, so requests are
 * spaced 0.15 s apart. A scan that isn't answered in time (3 s from the
 * cache, 8 s for a real scan) counts as turned down. */
static void b5ScanCall(unsigned gen)
{
    static CFDictionaryRef opts, cacheOpts;
    double now = CFAbsoluteTimeGetCurrent(), wait = g_b5LastScanCall + 0.15 - now;
    int fromCache = g_b5ScanCache;

    if (gen != g_b5ScanGen || !g_b5Running || !g_b5Busy)
        return;   /* superseded, or the switch went off */
    if (wait > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            b5ScanCall(gen);
        });
        return;
    }
    if (!opts)
        opts = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    if (!cacheOpts)
        cacheOpts = CFBridgingRetain(@{ @"BeaconCacheOnly": @YES });
    g_b5LastScanCall = now;
    g_b5ScanWaiting = gen;
    b5GuardBegin("scan");
    B5.scan(B5.dev, fromCache ? cacheOpts : opts, b5Scanned, (void *)(uintptr_t)gen);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (fromCache ? 3 : 8) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (g_b5ScanWaiting != gen || !g_b5Running)
            return;
        NSLog(@"wifitetherd: band: no answer to the %s after %d s", fromCache ? "look-up" : "scan", fromCache ? 3 : 8);
        b5Scanned(B5.dev, NULL, NULL, (void *)(uintptr_t)gen);
    });
}

static void b5StartScan(int learn, int fromCache)
{
    if (fromCache && g_b5SkipCache)
        fromCache = 0;
    if (!fromCache)
        g_b5SkipCache = 0;
    g_b5Busy = 1;
    g_b5BusySince = time(NULL);
    g_b5ScanLearn = learn;
    g_b5ScanCache = fromCache;
    b5ScanCall(++g_b5ScanGen);
}

/* Last resort when iOS won't scan during a move: turn Wi-Fi off and on, the
 * same as toggling it in Settings. iOS scans everything as it reconnects, and
 * hand-overs work after that. At most once every 10 minutes. */
static int b5Unstick(time_t now)
{
    if (g_b5MoveScanFails < 2 || !B5.setPower || (g_b5PowerCycledAt && now - g_b5PowerCycledAt < 600))
        return 0;
    NSLog(@"wifitetherd: band: iOS won't scan for the %s radio; turning Wi-Fi off and on, like toggling it in Settings",
          b5WantName());
    g_b5PowerCycledAt = now;
    g_b5MoveScanFails = 0;
    g_b5ScanThenJoin = 0;
    g_b5HandAfterScan = 0;
    g_b5State = @"restarting";
    g_b5Rescued = 1;
    g_b5QuietUntil = now + 30;   /* sharing: not a Wi-Fi drop to fix */
    g_b5NextTry = now + 6;       /* then a hand-over as usual, now that iOS has scanned */
    b5Power();
    b5TickSoon(7);
    return 1;
}

/* A scan in a move was turned down, wasn't answered, or saw nothing: try
 * again in 2 seconds; the second time, turn Wi-Fi off and on (b5Unstick);
 * after 4, wait a minute. */
static void b5MoveScanFailed(time_t now, NSString *what)
{
    g_b5MoveScanFails++;
    if (b5Unstick(now))
        return;
    if (g_b5MoveScanFails >= 4) {
        NSLog(@"wifitetherd: band: %@; trying again in a minute", what);
        g_b5MoveScanFails = 0;
        g_b5State = @"failed";
        g_b5NextTry = now + 60;
        return;
    }
    NSLog(@"wifitetherd: band: %@; trying again in 2 seconds", what);
    g_b5NextTry = now + 2;
    b5TickSoon(2.2);
}

/* A check sooner than the next 5-second one. */
static void b5TickSoon(double seconds)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_b5Running && !g_b5Busy)
            b5Tick();
    });
}

static void b5Join(void *net, int rssi);
static void b5HandoverTry(int rssi);

/* After a hand-over request: watch every 50 ms, for 1.2 seconds (the ones
 * that work take 0.25-0.5 s), whether the iPhone is on the forced band. If
 * not: once hand-overs have worked here, try again (2, then 4 seconds later;
 * a hand-over doesn't drop Wi-Fi, so it's cheap), then fall back to
 * disconnecting and joining. */
static void b5HandWatch(int checks, int rssi)
{
    int band = b5CurrentBand();

    if (!g_b5Running) {
        b5EndMove();
        return;
    }
    if (b5OnWant(band)) {
        NSLog(@"wifitetherd: band: handed over to %s in %d ms, without disconnecting%s", b5BandName(band), b5Ms(),
              g_b5HandAfterScan == 2 ? " (after a scan)" : "");
        g_b5LandedAt = time(NULL);
        g_b5State = @"on5";
        g_b5FailStreak = 0;
        g_b5NextTry = 0;
        g_b5HandWorked = 1;
        g_b5HandFails = 0;
        g_b5HandAfterScan = 0;
        g_b5MoveScanFails = 0;
        b5EndMove();
        return;
    }
    if (b5Ms() < 1200) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            b5HandWatch(checks + 1, rssi);
        });
        return;
    }
    if (g_b5HandWorked && g_b5HandTries < 3 && g_b5HandAfterScan != 2) {
        int gap = g_b5HandTries == 1 ? 2 : 4;
        NSLog(@"wifitetherd: band: hand-over %d didn't move it (on %s); trying again in %d s", g_b5HandTries,
              b5BandName(band), gap);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, gap * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!g_b5Running) {
                b5EndMove();
                return;
            }
            if (b5OnWant(b5CurrentBand())) {   /* got there in the meantime */
                b5HandWatch(0, rssi);
                return;
            }
            b5HandoverTry(rssi);
        });
        return;
    }
    if (g_b5HandPid > 1 && kill(g_b5HandPid, 0) != 0) {
        /* The wifid that was asked is gone: the request may have crashed it
         * (the add-on is untested on some devices). Don't ask again until the
         * switch is turned off and on. */
        NSLog(@"wifitetherd: band: iOS's Wi-Fi service restarted right after a hand-over request; hand-overs are off "
              @"until the switch is turned off and on");
        g_b5HandBroken = 1;
    }
    /* The second try after a scan doesn't count: the first one already did. */
    if (g_b5HandAfterScan != 2 && ++g_b5HandFails >= 3) {
        NSLog(@"wifitetherd: band: hand-overs aren't working here; disconnecting and rejoining for the next 10 minutes");
        g_b5HandOffUntil = time(NULL) + 600;
        g_b5HandFails = 0;
    }
    if (g_b5Joining) {
        void *net = (void *)CFRetain(g_b5Joining);   /* b5Join replaces g_b5Joining */
        NSLog(@"wifitetherd: band: hand-over didn't move it (on %s after %d ms); disconnecting and rejoining instead",
              b5BandName(band), b5Ms());
        b5Join(net, rssi);
        CFRelease(net);
    } else {
        /* It went without a scan, and the chip may only hand over to radios
         * it has seen lately (the first switch after the iPhone has sat on
         * one band for a while). Find the radio: from iOS's recently seen
         * networks, else with a scan and then one more hand-over; join it if
         * that doesn't move it either. */
        NSLog(@"wifitetherd: band: hand-over didn't move it (on %s after %d ms); looking for the %s radio",
              b5BandName(band), b5Ms(), b5WantName());
        g_b5ScanThenJoin = 1;
        if (!g_b5HandAfterScan)
            g_b5HandAfterScan = 1;
        g_b5State = @"finding";
        b5StartScan(0, 1);
    }
}

static void b5HandoverTry(int rssi)
{
    g_b5HandTries++;
    g_b5BusySince = time(NULL);
    g_b5T0 = CFAbsoluteTimeGetCurrent();
    NSLog(@"wifitetherd: band: hand-over %d: asking iOS to roam to %s", g_b5HandTries, b5WantName());
    {
        /* The band preference rides on the request's state: 1 = 2.4 GHz, 2 = 5 GHz. */
        static int tok = -1;
        if (tok < 0 && notify_register_check(WT_ROAM_REQUEST, &tok) != NOTIFY_STATUS_OK)
            tok = -1;
        if (tok >= 0)
            notify_set_state(tok, g_b5Want == 2 ? 1 : 2);
    }
    notify_post(WT_ROAM_REQUEST);
    b5HandWatch(0, rssi);
}

/* Moves to 5 GHz. iOS switching back after a while is expected where 5 GHz is
 * weak (it roams below -70 dBm), and each move costs only about a second, so
 * that's not limited; going back within 30 seconds 5 times in a row means it
 * can't hold here, so it pauses for 5 minutes. */
static void b5Move(void *net, int rssi)
{
    time_t now = time(NULL);

    if (g_b5LandedAt && now - g_b5LandedAt < 30) {
        if (++g_b5QuickBacks >= 5) {
            NSLog(@"wifitetherd: band: the iPhone keeps going straight back to %s; pausing for 5 minutes", b5OtherName());
            g_b5QuickBacks = 0;
            g_b5LandedAt = 0;
            g_b5State = @"flapping";
            g_b5NextTry = now + 300;
            return;
        }
    } else {
        g_b5QuickBacks = 0;
    }
    g_b5MoveCount++;
    g_b5HandAfterScan = 0;
    g_b5MoveScanFails = 0;
    /* Hand-over first, where the add-on is there: no disconnect, and no scan
     * needed, since iOS picks the radio. net (the radio from a scan, for the
     * fallback) may be NULL. */
    if (b5HandAvailable(now)) {
        void *old = g_b5Joining;
        g_b5Joining = net ? (void *)CFRetain(net) : NULL;
        if (old)
            CFRelease(old);
        if (net)
            NSLog(@"wifitetherd: band: on %s; handing over to the %s radio (channel %d, %d dBm)",
                  b5OtherName(), b5WantName(), b5Int(net, CFSTR("CHANNEL")), rssi);
        else
            NSLog(@"wifitetherd: band: on %s; handing over to %s", b5OtherName(), b5WantName());
        g_b5State = @"switching";
        g_b5NextTry = now + 30;
        g_b5Busy = 1;
        g_b5HandTries = 0;
        b5HandoverTry(rssi);
        return;
    }
    if (!net) {   /* no hand-over and no radio known: find it first */
        g_b5MoveCount--;
        b5StartScan(0, 1);
        return;
    }
    b5Join(net, rssi);
}

static void b5ScannedBody(CFArrayRef results, void *err);

static void b5Scanned(void *dev, CFArrayRef results, void *err, void *ctx)
{
    if ((unsigned)(uintptr_t)ctx != g_b5ScanWaiting || !g_b5ScanWaiting)
        return;   /* an answer that came after its time-out, or for a scan the switch no longer wants */
    g_b5ScanWaiting = 0;
    b5GuardBegin("scan result");
    b5ScannedBody(results, err);
    if (!g_b5Busy)   /* a join started inside keeps the mark until it answers */
        b5GuardEnd();
}

static void b5ScannedBody(CFArrayRef results, void *err)
{
    time_t now = time(NULL);
    void *best = NULL;
    int bestRssi = -200, n24 = 0, n5 = 0, band;
    NSMutableArray *avoid = [NSMutableArray array];
    int learn = g_b5ScanLearn, cached = g_b5ScanCache;

    g_b5Busy = 0;
    g_b5ScanLearn = 0;
    g_b5ScanCache = 0;
    if (!g_b5Running)
        return;
    if (cached && (!results || CFGetTypeID(results) != CFArrayGetTypeID())) {
        NSLog(@"wifitetherd: band: iOS's recently seen networks weren't available (%p); scanning", err);
        b5StartScan(learn, 0);
        return;
    }
    if (!results || CFGetTypeID(results) != CFArrayGetTypeID()) {
        if (learn) {
            /* Only learning the radio: iOS on this iPhone often turns these
             * down (busy, 0x10). Give up after 3; the next move learns it. */
            if (++g_b5LearnFails < 3)
                NSLog(@"wifitetherd: band: scan to learn the %s radio turned down (error %p); trying again in "
                      @"30 seconds", b5WantName(), err);
            else if (g_b5LearnFails == 3)
                NSLog(@"wifitetherd: band: iOS keeps turning down scans while on %s; the radio will be "
                      @"learned at the next move instead", b5WantName());
            g_b5NextScan5 = now + (g_b5LearnFails >= 3 ? 1800 : 30);
            return;
        }
        /* Usually busy: iOS is scanning or roaming itself. */
        b5MoveScanFailed(now, err ? [NSString stringWithFormat:@"scan turned down (error %p)", err]
                                  : @"the scan wasn't answered");
        return;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(results); i++) {
        void *net = (void *)CFArrayGetValueAtIndex(results, i);
        CFStringRef s = B5.getSSID(net);
        int band, rssi;
        if (!s || !g_b5SSID || CFStringCompare(s, g_b5SSID, 0) != kCFCompareEqualTo)
            continue;
        band = b5Band(net);
        rssi = b5Int(net, CFSTR("RSSI"));
        if (band == 2)
            n24++;
        else if (band >= 5)
            n5++;
        /* avoid: this network's radios on the other band */
        if (band > 0 && !b5OnWant(band)) {
            if (B5.copyRecord) {
                NSDictionary *rec = CFBridgingRelease(B5.copyRecord(net));
                if ([rec isKindOfClass:NSDictionary.class] && b5Str(rec, @"BSSID")) {
                    NSData *bytes = b5BSSIDBytes(b5Str(rec, @"BSSID"));
                    if (bytes)
                        [avoid addObject:bytes];
                }
            }
        }
        if (!b5OnWant(band))
            continue;
        if (rssi > bestRssi) {
            bestRssi = rssi;
            best = net;
        }
    }
    if (n24)
        g_b5SeenBands |= 1;
    if (n5)
        g_b5SeenBands |= 2;
    if (cached && !best) {
        NSLog(@"wifitetherd: band: the %s radio isn't among iOS's recently seen networks; scanning", b5WantName());
        b5StartScan(learn, 0);
        return;
    }
    if (!best && n24 + n5 == 0) {
        /* Didn't even see the network the iPhone is on: iOS was busy or
         * the iPhone was asleep. Not a sign that the band is out of range. */
        if (learn) {
            g_b5NextScan5 = now + (++g_b5LearnFails >= 3 ? 1800 : 30);
            return;
        }
        b5MoveScanFailed(now, @"the scan didn't see this network at all");
        return;
    }
    if (learn)
        g_b5LearnFails = 0;
    if (!best && (g_b5SeenBands & (g_b5Want == 2 ? 1 : 2))) {
        /* This network's radio on the forced band has been seen before (or
         * the iPhone was on it): the scan was incomplete, often because the
         * iPhone was dozing. Not a reason to give up for minutes. */
        NSLog(@"wifitetherd: band: the scan didn't show this network's %s radio, seen before; trying again in "
              @"15 seconds", b5WantName());
        if (learn)
            g_b5NextScan5 = now + 30;
        else
            g_b5NextTry = now + 15;
        return;
    }
    if (!best) {
        g_b5ScanThenJoin = 0;
        static int logged;
        if (!logged++)
            NSLog(@"wifitetherd: band: this network has no %s radio in range (%d on 2.4 GHz, %d on 5 GHz)",
                  b5WantName(), n24, n5);
        g_b5State = @"no5";
        g_b5NextTry = now + 300;
        return;
    }
    g_b5Rssi = bestRssi;
    NSLog(@"wifitetherd: band: this network has %d radio(s) on 2.4 GHz and %d on 5 GHz in range; "
          @"the best %s one is at %d dBm%s", n24, n5, b5WantName(), bestRssi,
          cached ? " (from iOS's recently seen networks)" : "");
    if (bestRssi < B5_MIN_RSSI) {
        NSLog(@"wifitetherd: band: the %s radio is too weak to connect to here (%d dBm)", b5WantName(), bestRssi);
        g_b5ScanThenJoin = 0;
        g_b5State = @"weak";
        g_b5NextTry = now + 120;
        return;
    }
    g_b5Avoid = avoid;
    /* Remember this radio, so when the iPhone is pushed back to 2.4 GHz
     * later it's moved straight back without waiting for another scan. */
    if (g_b5Target)
        CFRelease(g_b5Target);
    g_b5Target = (void *)CFRetain(best);
    g_b5TargetAt = now;
    band = b5CurrentBand();
    if (b5OnWant(band)) {   /* already on the wanted band: nothing to move */
        g_b5State = @"on5";
        g_b5ScanThenJoin = 0;
        return;
    }
    if (g_b5ScanThenJoin) {   /* a hand-over already didn't work */
        g_b5ScanThenJoin = 0;
        g_b5MoveScanFails = 0;
        if (!cached && g_b5HandAfterScan == 1 && b5HandAvailable(now)) {
            /* A real scan: the chip has now seen the radio, so the hand-over
             * may work this time, with no disconnect. If not, b5HandWatch
             * joins this radio. */
            g_b5HandAfterScan = 2;
            NSLog(@"wifitetherd: band: found the %s radio (channel %d, %d dBm); trying the hand-over again",
                  b5WantName(), b5Int(best, CFSTR("CHANNEL")), bestRssi);
            if (g_b5Joining)
                CFRelease(g_b5Joining);
            g_b5Joining = (void *)CFRetain(best);
            g_b5Busy = 1;
            g_b5BusySince = now;
            b5HandoverTry(bestRssi);
            return;
        }
        b5Join(best, bestRssi);
        return;
    }
    b5Move(best, bestRssi);
}

static void b5TickBody(void);

static void b5Tick(void)
{
    if (!g_b5Running || g_b5Crashed)
        return;
    rotateOwnLog();   /* the band switches log even with sharing off */
    b5GuardBegin("check");
    b5TickBody();
    if (!g_b5Busy)   /* a scan or join in progress keeps the mark until it answers */
        b5GuardEnd();
}

static void b5TickBody(void)
{
    time_t now = time(NULL);
    CFArrayRef devs;
    void *cur;
    int band;

    if (!g_b5Running)
        return;
    if (!b5Init()) {
        g_b5State = @"unsupported";
        return;
    }
    devs = B5.copyDevices(B5.mgr);   /* the Wi-Fi device; it can change if iOS's Wi-Fi service restarts */
    if (devs && CFArrayGetCount(devs) > 0) {
        void *d = (void *)CFArrayGetValueAtIndex(devs, 0);
        if (d != B5.dev) {
            if (B5.dev)
                CFRelease(B5.dev);
            B5.dev = (void *)CFRetain(d);
        }
    }
    if (devs)
        CFRelease(devs);
    if (!B5.dev) {
        g_b5State = @"nowifi";
        return;
    }
    if (g_b5Busy && now - g_b5BusySince > 30) {   /* scans time out sooner, in b5ScanCall */
        NSLog(@"wifitetherd: band: no answer from iOS's Wi-Fi service; trying again in 15 seconds");
        g_b5ScanWaiting = 0;
        b5EndMove();
        g_b5State = @"failed";
        g_b5NextTry = now + 15;
    }

    cur = B5.copyCurrent(B5.dev);
    if (!cur) {
        /* A move left Wi-Fi disconnected: turn Wi-Fi off and on so iOS
         * reconnects by itself. Once per move. */
        if (g_b5LastJoin && !g_b5Rescued && now - g_b5LastJoin >= 15 && now - g_b5LastJoin < 90) {
            NSLog(@"wifitetherd: band: Wi-Fi didn't reconnect after the move; turning it off and on");
            g_b5Rescued = 1;
            g_b5QuietUntil = now + 30;
            b5Power();
        }
        g_b5Band = 0;
        if (!g_b5Busy && !(g_b5PowerCycledAt && now - g_b5PowerCycledAt < 20))
            g_b5State = @"nowifi";   /* (turning Wi-Fi off and on keeps saying so for a while) */
        return;
    }
    g_b5LastWifi = now;
    band = b5Band(cur);
    g_b5Band = band;
    if (now - g_b5LastBeat >= 300) {   /* a status line every 5 minutes, so a quiet log still says something */
        g_b5LastBeat = now;
        NSLog(@"wifitetherd: band: status: on %s at %d dBm (channel %d); %d kick(s) and %d move(s) since Force %s "
              @"went on%@", b5BandName(band), b5Int(cur, CFSTR("RSSI")), b5Int(cur, CFSTR("CHANNEL")), g_b5Kicks,
              g_b5MoveCount, b5WantName(), g_b5LastKick
              ? [NSString stringWithFormat:@"; last kick %ld min ago", (long)(now - g_b5LastKick) / 60] : @"");
    }
    {
        CFStringRef s = B5.getSSID(cur);
        if (s && (!g_b5SSID || CFStringCompare(s, g_b5SSID, 0) != kCFCompareEqualTo)) {
            if (g_b5SSID)
                CFRelease(g_b5SSID);
            g_b5SSID = CFStringCreateCopy(NULL, s);
            g_b5NextTry = 0;
            g_b5NextScan5 = 0;
            if (g_b5Target)
                CFRelease(g_b5Target);
            g_b5Target = NULL;
            g_b5LandedAt = 0;
            g_b5LearnFails = 0;
            g_b5SeenBands = 0;
        }
    }
    if (b5OnWant(band))
        g_b5Rssi = b5Int(cur, CFSTR("RSSI"));
    if (band == 2)   /* on it: this network has a radio on this band */
        g_b5SeenBands |= 1;
    else if (band >= 5)
        g_b5SeenBands |= 2;
    CFRelease(cur);

    if (b5OnWant(band)) {
        if (![g_b5State isEqualToString:@"on5"] && g_b5LastJoin)
            NSLog(@"wifitetherd: band: on %s", b5WantName());
        g_b5State = @"on5";
        /* Already on the forced band. Without hand-overs, scan once to learn
         * its radio, so a kick to the other band is answered without a
         * scan; hand-overs don't need one. */
        if (!g_b5Target && !g_b5Busy && now >= g_b5NextScan5 && !b5HandAvailable(now)) {
            g_b5NextScan5 = now + 300;
            b5StartScan(1, 1);
        }
        return;
    }
    if (band == 0) {
        g_b5State = @"unknown";
        return;
    }
    /* On the other band. */
    if (g_b5LandedAt && [g_b5State isEqualToString:@"on5"]) {
        /* Moved off the forced band: that's a kick (counted here rather than
         * at the driver's disconnect event, which hand-overs send too). */
        NSLog(@"wifitetherd: band: on %s again after %ld s on %s", b5BandName(band), (long)(now - g_b5LandedAt),
              b5WantName());
        g_b5Kicks++;
        g_b5LastKick = now;
        g_b5State = @"searching";
    }
    if (g_b5Busy || now < g_b5NextTry || !g_b5SSID)
        return;
    if (g_b5Target || (!g_b5ScanThenJoin && b5HandAvailable(now))) {
        g_b5State = @"switching";
        b5Move(g_b5Target, g_b5Rssi);   /* no radio known: hand-over, which needs none */
        return;
    }
    if (![g_b5State isEqualToString:@"weak"] && ![g_b5State isEqualToString:@"no5"] &&
        ![g_b5State isEqualToString:@"flapping"] && ![g_b5State isEqualToString:@"failed"] &&
        !g_b5ScanThenJoin)
        g_b5State = @"searching";
    b5StartScan(0, 1);
}

static NSString *hexOf(const void *p, size_t n)
{
    NSMutableString *h = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++)
        [h appendFormat:@"%02x", ((const unsigned char *)p)[i]];
    return h;
}

/* ---------------------------------------------------------------------------
 * While Force 5 GHz is on, log the Wi-Fi driver's events (the kernel event
 * class wifid listens to: vendor Apple, class 6, subclass 1; codes from
 * apple80211_var.h). A switch to 2.4 GHz that the chip does itself shows up
 * as ROAM_START / ROAMED / ROAM_END; one iOS (wifid) decides on is a new
 * association (ASSOC_DONE) or a steering request from the router
 * (BSS_STEERING_REQUEST). After each event the current channel is logged.
 * ------------------------------------------------------------------------- */
struct wt_kev_request { uint32_t vendor_code, kev_class, kev_subclass; };
struct wt_kern_event_msg {
    uint32_t total_size, vendor_code, kev_class, kev_subclass, id, event_code;
    unsigned char data[];
};
static dispatch_source_t g_evSrc;
static unsigned          g_b5EvGen;

/* The connection just changed (the router disconnecting the iPhone, a new
 * radio, the link going down or up): check straight away instead of at the
 * next 5-second check, so a kick back to 2.4 GHz is undone within about a
 * second. iOS's view of the connection takes a moment to catch up, so it
 * checks at 0.1, 0.25, 0.5, 1, 2 and 3 seconds; a burst of events counts once (only the
 * last one's checks run). Events during a move of our own are ignored. */
static void b5EventCheck(void)
{
    static const int64_t at[] = {100, 250, 500, 1000, 2000, 3000};
    unsigned gen;

    if (!g_b5Running || g_b5Crashed || g_b5Busy)
        return;
    gen = ++g_b5EvGen;
    for (int i = 0; i < (int)(sizeof(at) / sizeof(at[0])); i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, at[i] * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (gen != g_b5EvGen || !g_b5Running || g_b5Busy)
                return;
            b5Tick();
        });
}

static const char *evName(uint32_t c)
{
    switch (c) {
    case 1: return "POWER_CHANGED";
    case 2: return "SSID_CHANGED";
    case 3: return "BSSID_CHANGED";
    case 4: return "LINK_CHANGED";
    case 9: return "ASSOC_DONE";
    case 10: return "SCAN_DONE";
    case 20: return "RSN_HANDSHAKE_DONE";
    case 30: return "ROAMED";
    case 32: return "DEAUTH_RECEIVED";
    case 54: return "CHANNEL_SWITCH";
    case 58: return "INTERFACE_STATE";
    case 70: return "ROAM_START";
    case 71: return "ROAM_END";
    case 140: return "BSS_STEERING_REQUEST";
    default: return NULL;
    }
}

static void b5EventsStart(void)
{
    struct wt_kev_request f = {1, 6, 1};
    int s;

    if (g_evSrc)
        return;
    s = socket(32 /* PF_SYSTEM */, SOCK_RAW, 1 /* SYSPROTO_EVENT */);
    if (s < 0 || ioctl(s, 0x800C6502UL /* SIOCSKEVFILT */, &f) < 0) {
        NSLog(@"wifitetherd: events: can't listen to the Wi-Fi driver (%s)", strerror(errno));
        if (s >= 0)
            close(s);
        return;
    }
    g_evSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)s, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_evSrc, ^{
        unsigned char buf[4096];
        ssize_t n = read(s, buf, sizeof(buf));
        for (ssize_t off = 0; n > 0 && off + (ssize_t)sizeof(struct wt_kern_event_msg) <= n; ) {
            struct wt_kern_event_msg *m = (struct wt_kern_event_msg *)(buf + off);
            if (m->total_size < sizeof(*m) || off + (ssize_t)m->total_size > n)
                break;
            const char *name = evName(m->event_code);
            if (name && g_b5Running && m->event_code != 10 && m->event_code != 58) {
                size_t dl = m->total_size - sizeof(*m);
                NSLog(@"wifitetherd: events: %s (%u)%s%@", name, m->event_code,
                      dl ? " data " : "", dl ? hexOf(m->data, dl > 48 ? 48 : dl) : @"");
                if (m->event_code == 32 && !g_b5Busy && CFAbsoluteTimeGetCurrent() >= g_b5OwnUntil)
                    NSLog(@"wifitetherd: band: the router disconnected the %@; checking the band now", deviceWord());
            }
            switch (m->event_code) {
            case 2: case 3: case 4: case 30: case 32: case 140:
                b5EventCheck();
                indEventSoon();
                break;
            case 9:
                indEventSoon();
                break;
            }
            off += m->total_size;
        }
    });
    dispatch_source_set_cancel_handler(g_evSrc, ^{ close(s); });
    dispatch_resume(g_evSrc);
    NSLog(@"wifitetherd: events: listening to the Wi-Fi driver");
}

static void b5EventsStop(void)
{
    if (!g_evSrc)
        return;
    dispatch_source_cancel(g_evSrc);
    g_evSrc = nil;
}

static int b5ReadFlag(const char *path)
{
    char c = '0';
    int on = 0;
    FILE *f = fopen(path, "r");

    if (f) {
        on = fread(&c, 1, 1, f) == 1 && c == '1';
        fclose(f);
    }
    return on;
}

static void b5Stop(void)
{
    dispatch_suspend(g_b5Timer);
    b5EndMove();   /* a move in flight finds nothing to finish */
    g_b5State = @"off";
    g_b5Rssi = 0;
    g_b5Band = 0;
    g_b5ScanWaiting = 0;
    if (!indWanted())   /* the status indicators keep listening */
        b5EventsStop();
    g_b5NextScan5 = 0;
    b5GuardEnd();
}

static void b5Start(void)
{
    b5EventsStart();
    g_b5NextTry = 0;
    g_b5NextScan5 = 0;
    g_b5HandReady = -1;
    g_b5HandWorked = 0;
    g_b5HandFails = 0;
    g_b5HandOffUntil = 0;
    g_b5HandBroken = 0;
    g_b5ScanThenJoin = 0;
    g_b5HandAfterScan = 0;
    g_b5MoveScanFails = 0;
    g_b5Kicks = g_b5MoveCount = 0;
    g_b5LastKick = 0;
    g_b5LastBeat = time(NULL);
    g_b5LearnFails = 0;
    g_b5ScanLearn = 0;
    g_b5LandedAt = 0;
    g_b5QuickBacks = 0;
    g_b5FailStreak = 0;
    g_b5Avoid = nil;
    b5DropTarget();   /* the radio of the other band, or of an older visit */
    g_b5SkipCache = 0;
    b5HandoverListen();
    b5HandoverReady();
    g_b5State = @"searching";
    dispatch_resume(g_b5Timer);
    dispatch_async(dispatch_get_main_queue(), ^{ b5Tick(); });
}

/* Starts or stops the 5-second check to match the app's two switches
 * (Force 5 GHz, Force 2.4 GHz; the app lets only one be on). */
static void b5Update(void)
{
    int want5 = b5ReadFlag(WT_PREFER5), want24 = !want5 && b5ReadFlag(WT_PREFER24);
    int want = want5 || want24, band = want24 ? 2 : 5;

    if (!g_b5Timer) {
        g_b5Timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_b5Timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_b5Timer, ^{ b5Tick(); });
    }
    if (!want && g_b5Crashed) {
        g_b5Crashed = 0;   /* switched off: the next time on, try again */
        g_b5State = @"off";
    }
    if (want && g_b5Crashed) {
        g_b5State = @"crashed";
        return;
    }
    if (want == g_b5Running && (!want || band == g_b5Want))
        return;
    if (g_b5Running) {
        g_b5Running = 0;
        NSLog(@"wifitetherd: force %s: off", b5WantName());
        b5Stop();
    }
    if (!want)
        return;
    g_b5Want = band;
    g_b5Running = 1;
    NSLog(@"wifitetherd: force %s: on", b5WantName());
    b5Start();
}

/* ── Status indicators ───────────────────────────────────────────────────
 * Two ways to see what's on without opening the app, both in its Settings:
 *   - The band on the status bar's Wi-Fi icon (src/bar; on by default). The
 *     band is published on the Darwin notification com.wifitether.band:
 *     state = (switched on ? 0x100 : 0) | band (2, 5, 6; 0 none).
 *   - A quiet notification in Notification Centre (off by default): the band
 *     and what's switched on. Only the app can post notifications, so this
 *     writes the summary (summary.plist) and, when it changes, starts the app
 *     in the background to post it (SpringBoardServices, the way the "open"
 *     command starts apps; com.apple.springboard.launchapplications).
 * The band is read when the Wi-Fi driver reports a change (the same event
 * socket the band switches use) and every 30 seconds in case one is missed.
 * ------------------------------------------------------------------------- */
#define WT_BANDLABEL   WT_DIR "/band-label"            /* "0": off; otherwise on */
#define WT_STATUSNOTE  WT_DIR "/status-notification"   /* "1": on */
#define WT_SUMMARY     WT_DIR "/summary.plist"
#define WT_BAND_NOTIFY "com.wifitether.band"
#define WT_APP_ID      "com.wifitether.app"

static int               g_indLabel = -1, g_indNote = -1;   /* the two settings; -1 not read yet */
static int               g_indBand = -1;                    /* 2, 5, 6; 0 none; -1 not read yet */
static int               g_indVpn, g_indVpnShared;          /* a VPN is connected / shared */
static uint64_t          g_indPublished = UINT64_MAX;
static dispatch_source_t g_indTimer;
static unsigned          g_indEvGen, g_indWakeGen;
static NSDictionary     *g_indSummary, *g_indWoke;          /* the summary now / the app was last woken for */

static int indWanted(void)
{
    return g_indLabel == 1 || g_indNote == 1;
}

static void indPublish(void)
{
    static int tok = -1;
    uint64_t st = (g_indLabel == 1 ? 0x100 : 0) | (uint64_t)(g_indBand > 0 ? g_indBand : 0);

    if (st == g_indPublished)
        return;
    if (tok < 0 && notify_register_check(WT_BAND_NOTIFY, &tok) != NOTIFY_STATUS_OK) {
        tok = -1;
        return;
    }
    notify_set_state(tok, st);
    notify_post(WT_BAND_NOTIFY);
    g_indPublished = st;
}

/* Starts the app in the background, so it updates its notification. */
static void indWakeApp(void)
{
    static int (*launch)(CFStringRef, Boolean);
    static int tried, lastErr;
    int r;

    if (!tried) {
        tried = 1;
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        launch = dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
        if (!launch)
            NSLog(@"wifitetherd: status notification: can't start the app in the background on this iOS");
    }
    if (!launch)
        return;
    r = launch(CFSTR(WT_APP_ID), true);   /* true: in the background (suspended) */
    if (r && r != lastErr)
        NSLog(@"wifitetherd: status notification: couldn't start the app to update it (error %d)", r);
    lastErr = r;
}

static NSString *indBandName(int band)
{
    return band == 2 ? @"2.4 GHz" : band == 5 ? @"5 GHz" : band == 6 ? @"6 GHz" : nil;
}

/* What the notification says: the band on top, then the same three lines
 * every time (only their values change), so nothing appears or disappears:
 *   Wi-Fi: 5 GHz
 *   USB sharing: on, computer connected
 *   VPN pass-through: off (no VPN)
 *   Band lock: Force 5 GHz
 * Shown whenever the notification is switched on. */
static NSDictionary *indSummaryNow(void)
{
    int sharing = g_lastEnabled == 1;
    NSString *band = indBandName(g_indBand);
    NSString *usb = !sharing ? @"off" : g_applied ? @"on, computer connected" : @"on, waiting for the computer";
    NSString *vpn = g_indVpnShared         ? @"on"
                  : !g_indVpn              ? @"off (no VPN)"
                  : !sharing               ? @"off (USB sharing is off)"
                  : !g_applied             ? @"on once the computer connects"
                                           : @"off (VPN not shared)";
    NSString *lock = !g_b5Running ? @"off" : g_b5Want == 2 ? @"Force 2.4 GHz" : @"Force 5 GHz";
    return @{ @"show": @YES,
              @"title": band ? [@"Wi-Fi: " stringByAppendingString:band] : @"Wi-Fi: not connected",
              @"body": [NSString stringWithFormat:@"USB sharing: %@\nVPN pass-through: %@\nBand lock: %@", usb, vpn, lock] };
}

/* After anything that can change the summary: write it, and if it stays
 * changed for 3 seconds (a router kick moves back within half a second),
 * wake the app to update the notification. */
static void indRefresh(void)
{
    NSDictionary *now;
    unsigned gen;

    if (g_indNote != 1)
        return;
    now = indSummaryNow();
    if ([now isEqualToDictionary:g_indSummary])
        return;
    g_indSummary = now;
    ensureDir();
    [now writeToFile:@WT_SUMMARY atomically:YES];
    chown(WT_SUMMARY, MOBILE_UID, MOBILE_UID);
    chmod(WT_SUMMARY, 0644);
    gen = ++g_indWakeGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gen != g_indWakeGen || g_indNote != 1 || [g_indSummary isEqualToDictionary:g_indWoke])
            return;
        g_indWoke = g_indSummary;
        indWakeApp();
    });
}

static int indReadBand(void)
{
    CFArrayRef devs;
    void *cur = NULL;
    int band = 0;

    if (!b5Init())
        return 0;
    devs = B5.copyDevices(B5.mgr);
    if (devs && CFArrayGetCount(devs) > 0)
        cur = B5.copyCurrent((void *)CFArrayGetValueAtIndex(devs, 0));
    if (devs)
        CFRelease(devs);
    if (cur) {
        band = b5Band(cur);
        CFRelease(cur);
    }
    return band;
}

static void indNoteBand(int band)
{
    if (band < 0)
        band = 0;
    if (band == g_indBand)
        return;
    g_indBand = band;
    indPublish();
    indRefresh();
}

static void indCheck(void)
{
    if (!indWanted())
        return;
    if (g_lastEnabled != 1) {   /* sharing off: reconcile isn't watching the VPN */
        WTIf up = findIf(0);
        g_indVpn = up.ok && findVPN(&up).ok;
        g_indVpnShared = 0;
    }
    indNoteBand(indReadBand());
    indRefresh();
}

/* The Wi-Fi driver reported a change: iOS's view of the connection takes a
 * moment to catch up, so look at 0.3, 1 and 3 seconds (a burst counts once). */
static void indEventSoon(void)
{
    static const int64_t at[] = {300, 1000, 3000};
    unsigned gen;

    if (!indWanted())
        return;
    gen = ++g_indEvGen;
    for (int i = 0; i < 3; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, at[i] * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (gen == g_indEvGen)
                indCheck();
        });
}

/* The settings (from reconcile, which runs whenever the app changes one). */
static void indUpdate(void)
{
    char c = 0;
    FILE *f = fopen(WT_BANDLABEL, "r");
    int label, note = b5ReadFlag(WT_STATUSNOTE);

    if (f) {
        if (fread(&c, 1, 1, f) != 1)
            c = 0;
        fclose(f);
    }
    label = c != '0';
    if (label == g_indLabel && note == g_indNote)
        return;
    NSLog(@"wifitetherd: band on the Wi-Fi icon: %s; status notification: %s", label ? "on" : "off", note ? "on" : "off");
    g_indLabel = label;
    g_indNote = note;
    if (!g_indTimer) {
        g_indTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_indTimer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                                  30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(g_indTimer, ^{ indCheck(); });
        dispatch_resume(g_indTimer);
    }
    if (indWanted())
        b5EventsStart();
    else if (!g_b5Running)
        b5EventsStop();
    g_indSummary = g_indWoke = nil;   /* write the summary afresh */
    indPublish();
    indCheck();
}

static void writeStatus(NSDictionary *d)
{
    ensureDir();
    [d writeToFile:@WT_STATUS atomically:YES];
    chown(WT_STATUS, MOBILE_UID, MOBILE_UID);
    chmod(WT_STATUS, 0644);
}

/* What iOS's hotspot service reports (its state, why, and the devices it
 * counts as connected), logged when it changes, and the count passed on for
 * iOS's blue "Personal Hotspot" indicator. */
static void misLog(void)
{
    static NSString *last;
    NSDictionary *d = scValue(@"com.apple.MobileInternetSharing");
    NSString *s = @"nothing";
    if (d && [NSJSONSerialization isValidJSONObject:d]) {
        NSData *j = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil];
        if (j)
            s = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    } else if (d) {
        s = [[d.description componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                componentsJoinedByString:@" "];
    }
    if ([s isEqualToString:last])
        return;
    last = s;
    NSLog(@"wifitetherd: hotspot service reports: %@", s);

    /* The number of connected devices, for the status bar add-on in
     * SpringBoard: iOS's blue hotspot indicator (src/bar/hotspot.m). */
    static int tok = -1;
    id cur = [d[@"Hosts"] isKindOfClass:[NSDictionary class]] ? d[@"Hosts"][@"Current"] : nil;
    if (tok >= 0 || notify_register_check("com.wifitether.hotspot", &tok) == NOTIFY_STATUS_OK) {
        notify_set_state(tok, [cur respondsToSelector:@selector(unsignedLongLongValue)] ? [cur unsignedLongLongValue] : 0);
        notify_post("com.wifitether.hotspot");
    }
}

static void reconcile(void)
{
    @autoreleasepool {
        NSMutableDictionary *st = [NSMutableDictionary dictionary];
        NSString *state, *detail = @"";
        int share = shareInstalled();

        b5Update();
        indUpdate();
        static int lastShare = -1;

        /* Share just got installed: restart iOS's hotspot service so Share's
         * patch loads (the hotspot can't be running without Share anyway). */
        if (share && lastShare == 0) {
            pid_t m = pidOf("misd");
            NSLog(@"wifitetherd: Share installed; restarting the hotspot service so it loads");
            if (m)
                kill(m, SIGTERM);
        }
        lastShare = share;
        misLog();

        /* The hotspot service restarted (Share installed or updated, a crash...):
         * our connection to it is dead, so restart ourselves to reconnect. */
        if (g_hsInit > 0 && g_misdPid) {
            pid_t m = pidOf("misd");
            if (m && m != g_misdPid) {
                NSLog(@"wifitetherd: the hotspot service restarted (%d -> %d); restarting to reconnect",
                      (int)g_misdPid, (int)m);
                teardown(@"the hotspot service restarted");
                b5GuardEnd();
                exit(0);   /* launchd starts us again */
            }
        }

        int en = isEnabled() && share;   /* without Share: act as switched off */
        WTIf up = findIf(0), lan = findIf(1);

        rotateOwnLog();
        trimLog(WT_DIR "/vpn.log");

        int air = airplaneMode();
        static int lastAir = -1;

        if (en && g_lastEnabled == 0 && g_hsCrashed) {
            g_hsCrashed = 0;   /* you switched off and on: try once more */
            g_hsInit = 0;
        }

        /* Airplane mode: switching on turns it off (and remembers that);
         * switching off restores it; turning it on while switched on, or
         * starting up switched on in airplane mode, asks with a pop-up. */
        if (en && g_lastEnabled == 0 && air == 1) {
            if (setAirplaneMode(NO) == 0) {
                FILE *f = fopen(WT_AIR_RESTORE, "w");
                if (f)
                    fclose(f);
                air = 0;
            }
        } else if (en && g_lastEnabled == -1 && air == 1) {
            askAirplane(@"WiFi Tether is switched on, but Personal Hotspot can't run in airplane mode. "
                        "Turn airplane mode off? Wi-Fi stays on.");
        } else if (en && g_lastEnabled == 1 && air == 1 && lastAir == 0) {
            askAirplane([NSString stringWithFormat:@"Personal Hotspot has stopped, so the computer connected to this %@ "
                         @"has lost its internet connection. Turn airplane mode off? Wi-Fi stays on.", deviceWord()]);
        }
        if (!en && g_lastEnabled == 1 && access(WT_AIR_RESTORE, F_OK) == 0) {
            if (air == 0)
                setAirplaneMode(YES);
            unlink(WT_AIR_RESTORE);
        }
        if (en && air == 0 && lastAir == 1) {
            g_hsTries = 0;          /* airplane mode just went off: start the hotspot again */
            g_hsNextTry = 0;
        }
        lastAir = air;

        /* Switch flipped on: start fresh. Flipped off: turn the hotspot off. */
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

        NSString *control = en ? controlHotspot(&up, &lan, air) : nil;
        if (en && !lan.ok)
            lan = findIf(1);

        st[@"enabled"] = @(en);
        st[@"share"] = @(share);
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

        if (en)
            dhcpLeaseCheck(&lan);

        if (!en || !up.ok || !lan.ok) {
            if (g_applied)
                teardown(stopReason(en, &up, &lan));
            writeVpnIf("");
            g_indVpn = g_indVpnShared = 0;
            if (up.ok) {   /* the app shows a connected VPN even while it isn't shared */
                WTIf v = findVPN(&up);
                st[@"vpn"] = v.ok ? [NSString stringWithFormat:@"%s (%@)", v.name, ipStr(v.ip)] : @"";
                g_indVpn = v.ok;
            }
            if (!en)
                state = share ? @"off" : @"noshare";
            else if (air == 1)
                state = @"airplane";
            else if (!up.ok)
                state = @"nowifi";
            else if (hotspotState() == MIS_ON || time(NULL) < g_usbRestartUntil) {
                NSString *wait = usbWait();
                state = wait ? @"waitcomputer" : @"ready";
                if (wait)
                    control = wait;
            } else
                state = @"nohotspot";
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
                if (pfn_filter_hook_add(lan.name, lan.ip, lan.mask, herr, sizeof(herr)) != 0 && strcmp(herr, lastHookErr) != 0) {
                    NSLog(@"wifitetherd: %s", herr);
                    strlcpy(lastHookErr, herr, sizeof(lastHookErr));
                }
            }
            st[@"vpnShared"] = @(vpn.ok && pfn_vpn_shared());
            g_indVpn = vpn.ok;
            g_indVpnShared = vpn.ok && pfn_vpn_shared();

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

        if (lan.ok || !en) {
            g_usbWaitStart = g_usbStandbySince = 0;
            g_usbDone = g_usbForce = 0;
        }
        if (control && [state isEqualToString:@"active"] && !detail.length)
            detail = control;
        st[@"state"] = state;
        st[@"detail"] = detail;
        st[@"host"] = @(g_hostAttached == 1);
        {
            time_t now = time(NULL);
            int standby = g_usbWaitStart && usbStandby(now);
            st[@"usbStandby"] = @(standby);   /* the app says "Connected to the computer" */
            st[@"usbDone"] = @(g_usbWaitStart && (g_usbDone || (standby && now - g_usbStandbySince >= 30)));   /* Reconnect */
        }
        st[@"band5"] = g_b5State;
        st[@"band5want"] = @(g_b5Want);
        st[@"band5band"] = @(g_b5Band);   /* 6 when Force 5 GHz has it on 6 GHz */
        if (g_b5Running && g_b5HandReady >= 0)
            st[@"band5hand"] = @(g_b5HandReady == 1 && !g_b5HandBroken);
        if (g_b5Rssi)
            st[@"band5rssi"] = @(g_b5Rssi);
        st[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
        writeStatus(st);
        indRefresh();

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
        teardown(@"WiFi Tether stopping");
        dhcpRestore();
        writeStatus(@{ @"state": @"stopped", @"detail": @"",
                       @"updated": @0, @"enabled": @(isEnabled()) });
        b5GuardEnd();   /* a deliberate stop, not a crash */
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
        {
            char what[32] = "";
            FILE *f = fopen(WT_B5_GUARD, "r");
            if (f) {
                if (!fgets(what, sizeof(what), f))
                    what[0] = 0;
                fclose(f);
                unlink(WT_B5_GUARD);
                g_b5Crashed = 1;
                NSLog(@"wifitetherd: the last Wi-Fi band call (%s) crashed; the band switch stays off "
                      "until it's turned off and on", what);
            }
        }
        g_sigterm = watchSignal(SIGTERM);
        g_sigint = watchSignal(SIGINT);
        hostWatchStart();

        notify_register_dispatch(WT_NOTIFY, &g_notifyToken, dispatch_get_main_queue(), ^(int t) {
            reconcile();
        });
        {
            int tok;
            notify_register_dispatch(WT_RECONNECT, &tok, dispatch_get_main_queue(), ^(int t) {
                usbReconnect();
                reconcile();
            });
        }

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
