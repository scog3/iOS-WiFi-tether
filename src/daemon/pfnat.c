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
#include <netinet/tcp.h>
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
        memcpy(&rt, &g_token, sizeof(g_token)); /* first field is the token */
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

/* Count the rules in one ruleset, and how many of them carry `label`. */
static int ruleset_info_label(const char *anchor, int action, const char *label,
                              u_int32_t *total, u_int32_t *ours)
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
        if (strncmp(pr.rule.label, label, sizeof(pr.rule.label)) == 0)
            mine++;
    }
    if (total) *total = n;
    if (ours)  *ours = mine;
    return 0;
}

static int ruleset_info(const char *anchor, int action, u_int32_t *total, u_int32_t *ours)
{
    return ruleset_info_label(anchor, action, WT_LABEL, total, ours);
}

/* ── VPN sharing hook ─────────────────────────────────────────────
 * The VPN helper (wifitether-vpn, based on pftun) keeps its rules in the
 * anchor WT_VPN_ANCHOR. Nothing evaluates an anchor unless the active ruleset
 * points at it, and with Share's local-only hotspot iOS loads no anchors of its
 * own. So while sharing is active we link it in twice:
 *   nat-anchor "/wifitether.vpn"   (part of our NAT transaction, see pfn_apply)
 *   anchor "/wifitether.vpn"       (one rule at the head of the main filter
 *                                   ruleset, added with DIOCCHANGERULE so iOS's
 *                                   own filter rules are never touched)
 * Both carry our label so they can be found and removed again. */

static int filter_hook_index(u_int32_t *ticket)
{
    struct pfioc_rule pr;
    u_int32_t n, i;

    memset(&pr, 0, sizeof(pr));
    pr.rule.action = PF_PASS;
    if (ioctl(g_fd, DIOCGETRULES, &pr) < 0)
        return -2;
    n = pr.nr;
    *ticket = pr.ticket;
    for (i = 0; i < n; i++) {
        struct pfioc_rule r;
        memset(&r, 0, sizeof(r));
        r.rule.action = PF_PASS;
        r.nr = i;
        r.ticket = *ticket;
        if (ioctl(g_fd, DIOCGETRULE, &r) < 0)
            continue;
        if (strncmp(r.rule.label, WT_LABEL, sizeof(r.rule.label)) == 0)
            return (int)i;
    }
    return -1;
}

/* Our rules in the main filter ruleset (see pfn_filter_hook_add). */
#define WT_FILTER_RULES 3

static int filter_hook_count(void)
{
    u_int32_t t = 0, mine = 0;
    if (ruleset_info("", PF_PASS, &t, &mine) < 0)
        return -1;
    return (int)mine;
}

int pfn_filter_hook_present(void)
{
    return g_fd >= 0 && filter_hook_count() == WT_FILTER_RULES;
}

/* Add one rule at the head of the main filter ruleset. */
static int filter_add_head(struct pf_rule *r, const char *call, const char *what, char *err, size_t errlen)
{
    struct pfioc_pooladdr pp;
    struct pfioc_rule pr;
    u_int32_t ticket;

    memset(&pp, 0, sizeof(pp));
    if (ioctl(g_fd, DIOCBEGINADDRS, &pp) < 0) {
        ERR("%s: DIOCBEGINADDRS failed: %s", what, strerror(errno));
        return -1;
    }
    if (filter_hook_index(&ticket) == -2) {
        ERR("%s: can't read filter rules: %s", what, strerror(errno));
        return -1;
    }
    memset(&pr, 0, sizeof(pr));
    pr.action = PF_CHANGE_ADD_HEAD;
    pr.ticket = ticket;
    pr.pool_ticket = pp.ticket;
    if (call)
        strlcpy(pr.anchor_call, call, sizeof(pr.anchor_call));
    memcpy(&pr.rule, r, sizeof(pr.rule));
    strlcpy(pr.rule.label, WT_LABEL, sizeof(pr.rule.label));
    if (ioctl(g_fd, DIOCCHANGERULE, &pr) < 0) {
        ERR("%s: DIOCCHANGERULE failed: %s", what, strerror(errno));
        return -1;
    }
    return 0;
}

/*
 * Main filter ruleset, in this order (each added at the head, so last first):
 *   1. block return-rst in quick on <lan_if> inet proto tcp
 *          from <lan subnet> to ! <lan subnet> flags /S
 *      A packet of a connection the phone has no record of (because the route
 *      changed: VPN on/off/switched and the old records were dropped) gets a
 *      TCP reset straight away, so the computer reconnects at once instead of
 *      retrying into nothing for about a minute.
 *   2. anchor "/wifitether.vpn"           the VPN helper's rules
 *   3. pass in quick on <lan_if> inet proto tcp
 *          from <lan subnet> to ! <lan subnet> flags S/SA keep state
 *      Records every new connection from the computer, so rule 1 only ever
 *      hits connections whose record was dropped.
 * Rules only see packets without a record; recorded ones skip all rules.
 */
int pfn_filter_hook_add(const char *lan_if, in_addr_t lan_ip, in_addr_t lan_mask, char *err, size_t errlen)
{
    struct pf_rule r;

    pfn_filter_hook_remove();

    /* 3. record new connections */
    memset(&r, 0, sizeof(r));
    r.action = PF_PASS;
    r.direction = PF_IN;
    r.quick = 1;
    r.af = AF_INET;
    r.proto = IPPROTO_TCP;
    r.keep_state = PF_STATE_NORMAL;
    r.flags = TH_SYN;
    r.flagset = TH_SYN | TH_ACK;
    strlcpy(r.ifname, lan_if, sizeof(r.ifname));
    set_addrmask(&r.src.addr, lan_ip & lan_mask, lan_mask);
    set_addrmask(&r.dst.addr, lan_ip & lan_mask, lan_mask);
    r.dst.neg = 1;
    if (filter_add_head(&r, NULL, "Connection tracking rule", err, errlen) < 0)
        return -1;

    /* 2. VPN helper's anchor */
    memset(&r, 0, sizeof(r));
    r.action = PF_PASS;
    r.af = AF_INET;
    if (filter_add_head(&r, "/" WT_VPN_ANCHOR, "VPN hook", err, errlen) < 0)
        return -1;

    /* 1. reset connections that lost their record */
    memset(&r, 0, sizeof(r));
    r.action = PF_DROP;
    r.rule_flag = PFRULE_RETURNRST;
    r.direction = PF_IN;
    r.quick = 1;
    r.af = AF_INET;
    r.proto = IPPROTO_TCP;
    r.flags = 0;
    r.flagset = TH_SYN;
    strlcpy(r.ifname, lan_if, sizeof(r.ifname));
    set_addrmask(&r.src.addr, lan_ip & lan_mask, lan_mask);
    set_addrmask(&r.dst.addr, lan_ip & lan_mask, lan_mask);
    r.dst.neg = 1;
    if (filter_add_head(&r, NULL, "Reset rule", err, errlen) < 0)
        return -1;
    return 0;
}

void pfn_filter_hook_remove(void)
{
    int i, guard;
    u_int32_t ticket;

    if (g_fd < 0)
        return;
    for (guard = 0; guard < 8 && (i = filter_hook_index(&ticket)) >= 0; guard++) {
        struct pfioc_rule pr;
        memset(&pr, 0, sizeof(pr));
        pr.action = PF_CHANGE_REMOVE;
        pr.nr = (u_int32_t)i;
        pr.ticket = ticket;
        pr.rule.action = PF_PASS;
        if (ioctl(g_fd, DIOCCHANGERULE, &pr) < 0)
            break;
    }
}

/* Has the VPN helper loaded its NAT rule (label "tunshare")? */
int pfn_vpn_shared(void)
{
    u_int32_t t = 0, mine = 0;
    if (g_fd < 0)
        return 0;
    if (ruleset_info_label(WT_VPN_ANCHOR, PF_NAT, "tunshare", &t, &mine) < 0)
        return 0;
    return mine > 0;
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

/* An anchor rule (nat-anchor / rdr-anchor) inside a transaction. Anchor
 * rules need a pool ticket but no pool address. */
static int add_anchor_rule(const char *anchor, u_int32_t ticket, int action,
                           const char *call, char *err, size_t errlen)
{
    struct pfioc_pooladdr pp;
    struct pfioc_rule pr;

    memset(&pp, 0, sizeof(pp));
    if (ioctl(g_fd, DIOCBEGINADDRS, &pp) < 0) {
        ERR("VPN anchor: DIOCBEGINADDRS failed: %s", strerror(errno));
        return -1;
    }
    memset(&pr, 0, sizeof(pr));
    pr.ticket = ticket;
    pr.pool_ticket = pp.ticket;
    strlcpy(pr.anchor, anchor, sizeof(pr.anchor));
    strlcpy(pr.anchor_call, call, sizeof(pr.anchor_call));
    pr.rule.action = action;
    pr.rule.af = AF_INET;
    strlcpy(pr.rule.label, WT_LABEL, sizeof(pr.rule.label));
    if (ioctl(g_fd, DIOCADDRULE, &pr) < 0) {
        ERR("VPN anchor: DIOCADDRULE failed: %s", strerror(errno));
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

    /* nat-anchor "/wifitether.vpn": the VPN helper's NAT rule lives there */
    if (add_anchor_rule(c->anchor, te[0].ticket, PF_NAT, "/" WT_VPN_ANCHOR, err, errlen) < 0)
        goto fail;

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
    /* The Wi-Fi rules are in. A failing filter hook only affects VPN sharing
     * and fast reconnects; wifitetherd retries it and logs the reason. */
    pfn_filter_hook_add(c->lan_if, c->lan_ip, c->lan_mask, NULL, 0);
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
    pfn_filter_hook_remove();
    init_trans(&t, te, anchor);
    if (ioctl(g_fd, DIOCXBEGIN, &t) < 0 || ioctl(g_fd, DIOCXCOMMIT, &t) < 0) {
        ERR("Couldn't remove packet filter rules: %s", strerror(errno));
        ioctl(g_fd, DIOCXROLLBACK, &t);
        return -1;
    }
    return 0;
}
