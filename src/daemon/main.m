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
#include <sys/sysctl.h>
#include <sys/stat.h>
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

static dispatch_source_t g_timer, g_sigterm, g_sigint;
static int g_notifyToken;

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

/* The DNS server iOS is using on Wi-Fi; falls back to 1.1.1.1. */
static in_addr_t findDNS(void)
{
    static void *h;
    static void *(*scCreate)(CFAllocatorRef, CFStringRef, void *, void *);
    static CFPropertyListRef (*scCopyValue)(void *, CFStringRef);
    in_addr_t out = 0;

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
            CFPropertyListRef v = scCopyValue(store, CFSTR("State:/Network/Global/DNS"));
            NSDictionary *d = (__bridge_transfer NSDictionary *)v;
            if ([d isKindOfClass:[NSDictionary class]]) {
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
            }
            CFRelease((CFTypeRef)store);
        }
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

        st[@"enabled"] = @(en);
        st[@"wifi"] = up.ok ? ipStr(up.ip) : @"";
        st[@"hotspot"] = lan.ok ? [NSString stringWithFormat:@"%@ on %s", ipStr(lan.ip), lan.name] : @"";

        if (!en || !up.ok || !lan.ok) {
            teardown();
            state = !en ? @"off" : (!up.ok ? @"nowifi" : @"nohotspot");
        } else {
            in_addr_t dns = findDNS();
            char key[160], err[256] = "";
            int ok = 1, need;

            st[@"dns"] = ipStr(dns);
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
                    NSLog(@"wifitetherd: %s", err);
                    if (!g_applied)
                        restoreFwd();
                }
            }
            state = ok ? @"active" : @"error";
            if (!ok)
                detail = [NSString stringWithUTF8String:err];
            else if (g_anchor[0])
                detail = [NSString stringWithFormat:@"Rules loaded in anchor %s", g_anchor];
        }

        st[@"state"] = state;
        st[@"detail"] = detail;
        st[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
        writeStatus(st);
    }
}

static dispatch_source_t watchSignal(int sig)
{
    dispatch_source_t s;
    signal(sig, SIG_IGN);
    s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, ^{
        teardown();
        writeStatus(@{ @"state": @"stopped", @"detail": @"",
                       @"updated": @0, @"enabled": @(isEnabled()) });
        exit(0);
    });
    dispatch_resume(s);
    return s;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        ensureDir();
        g_sigterm = watchSignal(SIGTERM);
        g_sigint = watchSignal(SIGINT);

        notify_register_dispatch(WT_NOTIFY, &g_notifyToken, dispatch_get_main_queue(), ^(int t) {
            reconcile();
        });

        g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(g_timer, ^{ reconcile(); });
        dispatch_resume(g_timer);

        NSLog(@"wifitetherd: started");
        reconcile();
    }
    dispatch_main();
    return 0;
}
