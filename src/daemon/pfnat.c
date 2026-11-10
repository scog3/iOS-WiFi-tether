/*
 * pfnat.c - load NAT and DNS-redirect rules into the kernel's packet filter
 * (pf) through /dev/pf, without needing the pfctl tool.
 *
 * Rules loaded (equivalent pf.conf syntax):
 *   nat on en0 inet from <hotspot subnet> to any -> <en0 address>
 *   rdr on bridge100 inet proto udp to <bridge address> port 53 -> <dns> port 53
 *   rdr on bridge100 inet proto tcp to <bridge address> port 53 -> <dns> port 53
 *
 * Struct layouts come from Apple's own XNU header (fetched at build time),
 * so they match the kernel.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

#ifndef PRIVATE
#define PRIVATE 1
#endif
#include <xnu/pfvar.h>

#include "pfnat.h"

#ifndef PF_NAT_PROXY_PORT_LOW
#define PF_NAT_PROXY_PORT_LOW  50001
#endif
#ifndef PF_NAT_PROXY_PORT_HIGH
#define PF_NAT_PROXY_PORT_HIGH 65535
#endif

static int g_fd = -1;
static int g_started;          /* 0 = not started by us, 1 = via token, 2 = plain start */
static u_int64_t g_token;

#define ERR(...) do { if (err) snprintf(err, errlen, __VA_ARGS__); } while (0)

int pfn_open(char *err, size_t errlen)
{
    if (g_fd >= 0)
        return 0;
    g_fd = open("/dev/pf", O_RDWR);
    if (g_fd < 0) {
        ERR("Couldn't open /dev/pf: %s", strerror(errno));
        return -1;
    }
    return 0;
}

int pfn_start(char *err, size_t errlen)
{
    if (g_started)
        return 0;
#ifdef DIOCSTARTREF
    {
        u_int64_t tok = 0;
        if (ioctl(g_fd, DIOCSTARTREF, &tok) == 0) {
            g_token = tok;
            g_started = 1;
            return 0;
        }
    }
#endif
    if (ioctl(g_fd, DIOCSTART) == 0 || errno == EEXIST) {
        g_started = 2;
        return 0;
    }
    ERR("Couldn't enable the packet filter: %s", strerror(errno));
    return -1;
}

void pfn_stop(void)
{
#ifdef DIOCSTOPREF
    if (g_started == 1) {
        struct pfioc_remove_token rt;
        memset(&rt, 0, sizeof(rt));
        memcpy(&rt, &g_token, sizeof(g_token));
        ioctl(g_fd, DIOCSTOPREF, &rt);
    }
#endif
    /* A plain DIOCSTART is left running: other parts of iOS may rely on pf. */
    g_started = 0;
    g_token = 0;
}

static void set_addrmask(struct pf_addr_wrap *w, in_addr_t addr, in_addr_t mask)
{
    memset(w, 0, sizeof(*w));
    w->type = PF_ADDR_ADDRMASK;
    w->v.a.addr.addr32[0] = addr;
    w->v.a.mask.addr32[0] = mask;
}

/* Count the rules in one ruleset, and how many of them carry our label. */
static int ruleset_info(const char *anchor, int action, u_int32_t *total, u_int32_t *ours)
{
    struct pfioc_rule pr;
    u_int32_t n, ticket, mine = 0, i;

    memset(&pr, 0, sizeof(pr));
    pr.rule.action = action;
    strlcpy(pr.anchor, anchor, sizeof(pr.anchor));
    if (ioctl(g_fd, DIOCGETRULES, &pr) < 0)
        return -1;
    n = pr.nr;
    ticket = pr.ticket;

    for (i = 0; i < n; i++) {
        memset(&pr, 0, sizeof(pr));
        pr.rule.action = action;
        pr.nr = i;
        pr.ticket = ticket;
        strlcpy(pr.anchor, anchor, sizeof(pr.anchor));
        if (ioctl(g_fd, DIOCGETRULE, &pr) < 0)
            return -1;
        if (strncmp(pr.rule.label, WT_LABEL, sizeof(pr.rule.label)) == 0)
            mine++;
    }
    if (total) *total = n;
    if (ours)  *ours = mine;
    return 0;
}

/*
 * Use the main ruleset if its NAT and redirect sections are empty (or only
 * hold our own rules). Otherwise use a separate anchor so we never wipe out
 * rules that iOS put there.
 */
int pfn_pick_anchor(char *anchor, size_t anchorlen, char *err, size_t errlen)
{
    u_int32_t nt = 0, no = 0, rt = 0, ro = 0;

    if (ruleset_info("", PF_NAT, &nt, &no) < 0 || ruleset_info("", PF_RDR, &rt, &ro) < 0) {
        ERR("Couldn't read existing packet filter rules: %s", strerror(errno));
        return -1;
    }
    if (nt == no && rt == ro)
        strlcpy(anchor, "", anchorlen);
    else
        strlcpy(anchor, WT_FALLBACK_ANCHOR, anchorlen);
    return 0;
}

int pfn_present(const char *anchor)
{
    u_int32_t t = 0, mine = 0;
    if (g_fd < 0)
        return 0;
    if (ruleset_info(anchor, PF_NAT, &t, &mine) < 0)
        return 0;
    return mine > 0;
}

static int add_rule(const char *anchor, u_int32_t ticket, struct pf_rule *r,
                    in_addr_t pool_ip, const char *what, char *err, size_t errlen)
{
    struct pfioc_pooladdr pp;
    struct pfioc_rule pr;
    u_int32_t pool_ticket;

    memset(&pp, 0, sizeof(pp));
    if (ioctl(g_fd, DIOCBEGINADDRS, &pp) < 0) {
        ERR("%s: DIOCBEGINADDRS failed: %s", what, strerror(errno));
        return -1;
    }
    pool_ticket = pp.ticket;

    pp.af = AF_INET;
    set_addrmask(&pp.addr.addr, pool_ip, 0xffffffff);
    if (ioctl(g_fd, DIOCADDADDR, &pp) < 0) {
        ERR("%s: DIOCADDADDR failed: %s", what, strerror(errno));
        return -1;
    }

    memset(&pr, 0, sizeof(pr));
    pr.ticket = ticket;
    pr.pool_ticket = pool_ticket;
    strlcpy(pr.anchor, anchor, sizeof(pr.anchor));
    memcpy(&pr.rule, r, sizeof(pr.rule));
    if (ioctl(g_fd, DIOCADDRULE, &pr) < 0) {
        ERR("%s: DIOCADDRULE failed: %s", what, strerror(errno));
        return -1;
    }
    return 0;
}

static void init_trans(struct pfioc_trans *t, struct pfioc_trans_e *te, const char *anchor)
{
    memset(te, 0, sizeof(*te) * 2);
    te[0].rs_num = PF_RULESET_NAT;
    strlcpy(te[0].anchor, anchor, sizeof(te[0].anchor));
    te[1].rs_num = PF_RULESET_RDR;
    strlcpy(te[1].anchor, anchor, sizeof(te[1].anchor));

    memset(t, 0, sizeof(*t));
    t->size = 2;
    t->esize = sizeof(te[0]);
    t->array = te;
}

int pfn_apply(const struct pfn_cfg *c, char *err, size_t errlen)
{
    struct pfioc_trans_e te[2];
    struct pfioc_trans t;
    struct pf_rule r;
    int protos[2] = { IPPROTO_UDP, IPPROTO_TCP };
    int i;

    init_trans(&t, te, c->anchor);
    if (ioctl(g_fd, DIOCXBEGIN, &t) < 0) {
        ERR("Couldn't start a packet filter transaction: %s", strerror(errno));
        return -1;
    }

    /* nat on <up_if> inet from <lan subnet> to any -> <up_ip> */
    memset(&r, 0, sizeof(r));
    r.action = PF_NAT;
    r.direction = PF_OUT;
    r.af = AF_INET;
    strlcpy(r.ifname, c->up_if, sizeof(r.ifname));
    strlcpy(r.label, WT_LABEL, sizeof(r.label));
    set_addrmask(&r.src.addr, c->lan_ip & c->lan_mask, c->lan_mask);
    set_addrmask(&r.dst.addr, 0, 0);
    r.rpool.proxy_port[0] = PF_NAT_PROXY_PORT_LOW;
    r.rpool.proxy_port[1] = PF_NAT_PROXY_PORT_HIGH;
    if (add_rule(c->anchor, te[0].ticket, &r, c->up_ip, "NAT rule", err, errlen) < 0)
        goto fail;

    /* rdr on <lan_if> inet proto udp/tcp to <lan_ip> port 53 -> <dns> port 53 */
    for (i = 0; i < 2; i++) {
        memset(&r, 0, sizeof(r));
        r.action = PF_RDR;
        r.direction = PF_IN;
        r.af = AF_INET;
        r.proto = protos[i];
        strlcpy(r.ifname, c->lan_if, sizeof(r.ifname));
        strlcpy(r.label, WT_LABEL, sizeof(r.label));
        set_addrmask(&r.src.addr, 0, 0);
        set_addrmask(&r.dst.addr, c->lan_ip, 0xffffffff);
        r.dst.xport.range.op = PF_OP_EQ;
        r.dst.xport.range.port[0] = htons(53);
        r.rpool.proxy_port[0] = 53;
        if (add_rule(c->anchor, te[1].ticket, &r, c->dns_ip, "DNS rule", err, errlen) < 0)
            goto fail;
    }

    if (ioctl(g_fd, DIOCXCOMMIT, &t) < 0) {
        ERR("Couldn't commit packet filter rules: %s", strerror(errno));
        goto fail;
    }
    return 0;

fail:
    ioctl(g_fd, DIOCXROLLBACK, &t);
    return -1;
}

int pfn_clear(const char *anchor, char *err, size_t errlen)
{
    struct pfioc_trans_e te[2];
    struct pfioc_trans t;

    if (g_fd < 0)
        return 0;
    init_trans(&t, te, anchor);
    if (ioctl(g_fd, DIOCXBEGIN, &t) < 0 || ioctl(g_fd, DIOCXCOMMIT, &t) < 0) {
        ERR("Couldn't remove packet filter rules: %s", strerror(errno));
        ioctl(g_fd, DIOCXROLLBACK, &t);
        return -1;
    }
    return 0;
}
