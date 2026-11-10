#ifndef WIFITETHER_PFNAT_H
#define WIFITETHER_PFNAT_H

#include <stddef.h>
#include <netinet/in.h>

#define WT_LABEL "wifitether"
#define WT_FALLBACK_ANCHOR "com.apple/990.WiFiTether"

struct pfn_cfg {
    const char *anchor;   /* "" = main ruleset */
    const char *up_if;    /* Wi-Fi interface, e.g. en0 */
    in_addr_t   up_ip;    /* Wi-Fi IPv4 address (network order) */
    const char *lan_if;   /* hotspot bridge, e.g. bridge100 */
    in_addr_t   lan_ip;   /* bridge IPv4 address */
    in_addr_t   lan_mask; /* bridge netmask */
    in_addr_t   dns_ip;   /* DNS server to send client lookups to */
};

int  pfn_open(char *err, size_t errlen);
int  pfn_start(char *err, size_t errlen);
void pfn_stop(void);
int  pfn_pick_anchor(char *anchor, size_t anchorlen, char *err, size_t errlen);
int  pfn_apply(const struct pfn_cfg *cfg, char *err, size_t errlen);
int  pfn_clear(const char *anchor, char *err, size_t errlen);
int  pfn_present(const char *anchor);

#endif
