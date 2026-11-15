/*
 * WiFiTetherRoam: a small add-on loaded into wifid, iOS's Wi-Fi service.
 *
 * Force 5 GHz normally moves the iPhone back to 5 GHz by disconnecting and
 * joining the 5 GHz radio, which costs about half a second without Wi-Fi.
 * iOS has a quicker way of its own: a roam (a hand-over between radios with
 * no disconnect), which wifid asks for itself when 2.4 GHz is poor ("host
 * triggered roam to 5GHz band"). Only wifid can ask for one, so this add-on
 * runs inside it. When wifitetherd posts the Darwin notification
 * com.wifitether.roam5, it makes the same request wifid's roam manager
 * (-[WiFiRoamManager roamWithReason:bandPreference:]) makes: the local
 * notification com.apple.wifid.wifiroammanagerroamnotification, posted on the
 * roam manager's queue, with a band preference and a reason (5, the one
 * wifid uses for "prefer 5 GHz"). wifid then roams the usual way.
 *
 * The band preference rides on the request's notify state: 1 = 2.4 GHz
 * (Force 2.4 GHz), 2 = 5 GHz (Force 5 GHz; also when the state is unset).
 * wifid accepts 0-2; 2 for 5 GHz was confirmed on an iPhone 6s (0.4.18~dev8).
 *
 * It hooks and patches nothing, and does nothing until asked. On load it
 * publishes wifid's process id under com.wifitether.roam5.ready so
 * wifitetherd can tell it's there, and it answers each request on
 * com.wifitether.roam5.done (state: request number << 8 | 1 asked,
 * 2 no roam manager).
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <notify.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define WT_ROAM_REQUEST "com.wifitether.roam5"
#define WT_ROAM_READY   "com.wifitether.roam5.ready"
#define WT_ROAM_DONE    "com.wifitether.roam5.done"

static int      g_readyToken = -1, g_doneToken = -1, g_requestToken = -1;
static uint64_t g_count;

static void wtReport(uint64_t n, uint64_t status)
{
    if (g_doneToken < 0)
        return;
    notify_set_state(g_doneToken, n << 8 | status);
    notify_post(WT_ROAM_DONE);
}

static void wtRoam(char band)
{
    Class cls = objc_getClass("WiFiRoamManager");
    SEL shared = sel_registerName("sharedWiFiRoamManager");
    SEL queueSel = sel_registerName("dispatchQueue");
    id mgr = nil;
    dispatch_queue_t q = nil;
    uint64_t n = ++g_count;

    if (cls && class_respondsToSelector(object_getClass(cls), shared))
        mgr = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    if (!mgr) {
        wtReport(n, 2);
        return;
    }
    if ([mgr respondsToSelector:queueSel])
        q = ((id (*)(id, SEL))objc_msgSend)(mgr, queueSel);
    if (!q)
        q = dispatch_get_main_queue();
    dispatch_async(q, ^{
        NSDictionary *info = @{
            @"com.apple.wifid.wifiroammangerroamtype": [NSNumber numberWithChar:band],
            @"com.apple.wifid.wifiroammangerroamreason": [NSNumber numberWithInteger:5],
        };
        CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
                                             CFSTR("com.apple.wifid.wifiroammanagerroamnotification"),
                                             NULL, (__bridge CFDictionaryRef)info, true);
        wtReport(n, 1);
    });
}

__attribute__((constructor)) static void wtInit(void)
{
    const char *me = getprogname();

    if (!me || strcmp(me, "wifid") != 0)
        return;
    if (notify_register_check(WT_ROAM_DONE, &g_doneToken) != NOTIFY_STATUS_OK)
        g_doneToken = -1;
    if (notify_register_dispatch(WT_ROAM_REQUEST, &g_requestToken, dispatch_get_main_queue(),
                                 ^(int t) {
                                     uint64_t pref = 0;
                                     notify_get_state(t, &pref);
                                     wtRoam(pref == 1 ? 1 : 2);
                                 }) != NOTIFY_STATUS_OK)
        return;
    if (notify_register_check(WT_ROAM_READY, &g_readyToken) == NOTIFY_STATUS_OK) {
        notify_set_state(g_readyToken, (uint64_t)getpid());
        notify_post(WT_ROAM_READY);
    }
}
