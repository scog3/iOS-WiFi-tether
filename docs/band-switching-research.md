# Wi-Fi band switching: what was tried, what worked and what didn't

These are the development notes behind the **Force 5 GHz** and **Force 2.4 GHz** switches,
so anyone working on them can see what has already been tried. Everything here was
measured on one iPhone 6s (iOS 15.8.5, Dopamine rootless) and one ISP router that uses a
single network name on both bands, with band steering that can't be turned off and bands
that can't be given separate names.

## Summary

- **The cause is the router, not iOS.** The router's band steering disconnects the iPhone
  from 5 GHz when its 5 GHz signal is weak (about −76 to −84 dBm), and the Wi-Fi chip is on
  the router's 2.4 GHz radio within about 2 ms, before iOS's Wi-Fi service does anything.
- **Nothing on the phone has stopped those moves**, so the switches undo them instead, as
  fast and as gently as possible.
- **What works now:** notice the move from the Wi-Fi driver's events, then move back with
  iOS's own hand-over (roam), requested by a small add-on inside `wifid`. In testing that
  took 250–500 ms with no disconnect; a ping to the router through the iPhone loses about
  one reply per hand-over. The fallback, disconnect and join with an avoid list,
  takes about 0.66 s, with about 0.45 s of no Wi-Fi.

## What moves the iPhone between bands

Found by logging the Wi-Fi driver's event messages (read-only) with the channel at each
event:

- **Every move starts the same way:** BSSID changed, DEAUTH_RECEIVED, LINK_CHANGED, BSSID
  changed again, all within 2–3 ms. The channel already reads 2.4 GHz at the first event,
  and iOS runs no join of its own.
- **Not iOS roaming:** Apple documents a roam trigger around −70 dBm, but the iPhone sat on
  5 GHz at −80 dBm for 45 s and at −84 dBm for 6½ minutes, and only moved when the router
  disconnected it.
- **When:** with the 5 GHz signal at about −76 to −84 dBm. Gaps between moves ranged from
  33 seconds to 18 minutes.
- **The router sometimes refuses 5 GHz for a few seconds afterwards.** Moves back 4–5 s after
  a kick landed on 2.4 GHz again twice; moves 0.1–0.5 s and 16–21 s after all worked.

## Everything tried, version by version

Newest first. The 0.4.18 builds were development builds that led to 1.0.

| Version | What changed | Result |
| --- | --- | --- |
| 1.4 | Scan requests spaced at least 0.15 s apart, and an unanswered one retried after a few seconds; the hand-over is given up after 1.2 s instead of about 3 s; after a real scan, one more hand-over before the fallback join; if iOS turns down scans twice in a move, Wi-Fi is turned off and on (at most every 10 minutes); the app's own hand-overs no longer counted as router kicks | Fixes a hang in 1.3 (see Open questions). Not yet measured |
| 1.3 | When the hand-over doesn't move it and no radio is known, the radio is looked up in wifid's beacon cache (scan option `BeaconCacheOnly`) instead of a real scan, so the fallback join starts at once | The first switch to 2.4 GHz from 5 GHz should take about 4 s instead of 30 s or more |
| 1.2 | Moves start with the hand-over straight away, with no scan (iOS picks the radio); a scan only for the fallback join. A scan that misses a band seen before on this network no longer counts as "not in range" | iOS often turns down scans while on 5 GHz, which delayed band switches by up to 30 s and once gave up for 5 minutes |
| 1.1 | Hand-over add-on also built for arm64e (A12 and newer), with Apple's compiler on a Mac build runner; hand-overs stop if iOS's Wi-Fi service restarts right after one | Untested on A12 and newer |
| 1.0 | Force 2.4 GHz switch, one switch on at a time; experiments that did nothing removed | Released |
| 0.4.18 dev 9 | Status line in the log every 5 minutes; the scan that learns the radio gives up after 3 busy refusals | Worked |
| 0.4.18 dev 8 | Add-on inside `wifid` asks for iOS's own hand-over to the forced band; disconnect-and-join kept as the fallback | Worked: 278 ms, no disconnect |
| 0.4.18 dev 7 | Checks 0.1 s after a move; a failed move noticed in 1 s instead of 10; up to 3 tries, 2 and 8 s apart; no 30 s cooldown; empty scans retried in 5 s; the radio remembered until it fails | Back on 5 GHz in 0.66 s, about 0.45 s without Wi-Fi |
| 0.4.18 dev 6 | Reacts to the driver's events instead of waiting for the 5-second check | Back on 5 GHz in 1.5 s |
| 0.4.18 dev 5 | Logs the Wi-Fi driver's event messages | Found the cause (previous section) |
| 0.4.18 dev 4 | Sending the log from inside the app | App crashed on open; removed |
| 0.4.18 dev 1–3 | Experiments with lower-level Wi-Fi settings | Abandoned; one left Wi-Fi unable to join any network until a reboot |
| 0.4.17 | Reuses the remembered 5 GHz radio instead of scanning again; limits only quick bounces | Back within about 5 s of a move |
| 0.4.16 | Each join carries a list of the other band's radios to avoid (`BSS_BLACKLIST` on the join record) | Joins land on 5 GHz in about 0.5 s |
| 0.4.15 | Crash fix for the lasting block below | No crash, but the iPhone 6s's chip doesn't support the lasting block (iOS returns an empty list) |
| 0.4.13–0.4.14 | Lasting block of the 2.4 GHz radios through iOS's own access-point block list | Crashed the background service (a missing argument), then fixed |
| 0.4.12 | Joins only once the disconnect has actually happened; 2 tries, then waits 1, 5, 15 minutes | Fixed repeated drops |
| 0.4.11 | Renamed Force 5 GHz, with a warning; −85 dBm floor; checks every 5 s | Shortening the disconnect wait to 300 ms broke joins |
| 0.4.10 | Disconnects first, then joins the 5 GHz radio | iOS's auto-join often won the race back to 2.4 GHz |
| 0.4.9 | Asks iOS to join the 5 GHz radio | iOS ignores a join to another radio of the network it's already on |
| 0.4.8 | Shows the band in the app | — |

## Measurements

Moves in the order they happened during testing.

| Move | Build | 5 GHz signal | Time on 5 GHz before | Back on 5 GHz after | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | dev 5 | −80 dBm | 45 s | 4.6 s | Try at +4.2 s accepted |
| 2 | dev 5 | −84 dBm | 6½ min | 16.5 s | Try at +4.3 s refused; try at +16 s worked |
| 3 | dev 5 | −84 dBm | 33 s | 22.8 s | Try at +5 s refused; try at +21 s worked |
| 4 | dev 5 | not logged | 18 min | gave up for 5 min | A scan straight after the move saw nothing; fixed in dev 7 |
| 5 | dev 6 | −75 dBm | 37 s | 1.5 s | Accepted 0.5 s after the move |
| 6 | dev 7 | −81 dBm | 51 s | 0.66 s | Disconnect and join, about 0.45 s without Wi-Fi |
| 7 | dev 8 | −78 dBm | — | 278 ms | Hand-over from 2.4 GHz, no disconnect (started by hand, not by the router) |
| 8–13 | 1.3 | −77 to −83 dBm | 30 s to 8 min | 255–502 ms | Six router kicks in 14 minutes, each handed back with no disconnect |

Where the time goes with disconnect-and-join: the move is noticed in the same millisecond;
iOS's own view of the connection catches up in 0.1–0.5 s; then about 0.2 s to disconnect
and 0.5–0.7 s for the join handshake with the router.

## Ruled out or not built

| Idea | Why it was dropped |
| --- | --- |
| Lasting block of the other band's radios (iOS's access-point block list) | The iPhone 6s's chip doesn't support it (capability 84 missing; iOS returns an empty list). Might work on newer iPhones; removed in 1.0 because it did nothing here |
| Making iOS skip 2.4 GHz in its own scans (`wifid` does this for CarPlay and Bluetooth calls) | Only affects iOS's scans and joins; the router's move happens in the chip without either |
| Changing iOS's −70 dBm roam trigger | Not the cause: the iPhone held 5 GHz at −84 dBm until the router moved it |
| Checking every millisecond | Moves are already noticed instantly; the join handshake sets the floor, faster retries meet the router's refusals and add drops, and it costs battery |
| Router settings (separate band names, turning off steering, fixed channels) | Not available on the router used; fixed channels made no difference |
| A band lock in the Wi-Fi chip itself | Not tried yet; see Open questions |
| Sending logs from inside the app (0.4.18 dev 4) | Crashed the app on open; removed. 1.6 adds it back in Settings (Share log file, Copy log), built only when tapped |

## Open questions

- [x] **Hand-over straight after a router move:** works. Six router kicks in a row were
  handed back in 255–502 ms with no disconnect (moves 8–13).
- [x] **Does the router give up steering?** No sign of it. One night it kicked six times in
  14 minutes at −77 to −83 dBm, 30 s to 8 minutes after each hand-back; another evening
  there were no kicks for 50 minutes at −73 to −82 dBm. The kicks come and go rather than
  stopping.
- [x] **Band preference 1 for 2.4 GHz** in the hand-over request: confirmed on the iPhone 6s
  (handed over to 2.4 GHz in 233 ms, no disconnect).
- [ ] **Why iOS turns down scans while on 5 GHz** (error 0x10, busy) on the iPhone 6s.
  Scans on 2.4 GHz work. wifid's reasons for refusing include "autojoin is busy", "in
  autojoin deferral period", "critical phase is ON" and "hosting AWDL session"; which one
  applies here isn't known. Since 1.3 the fallback reads wifid's beacon cache first.
  Separately, iOS rejects a scan request that comes less than 0.1 s after the previous one
  ("called 0.02s ago, rejecting, min time between successive calls is 0.10s") and never
  answers it. 1.3's cache look-up followed by a real scan hit this and hung; 1.4 spaces
  requests out.
- [ ] **The first hand-over to a band the iPhone hasn't used lately doesn't move it.**
  Switching to 2.4 GHz from 5 GHz without a recent scan failed three times in a row (about
  3 s each); after one join to 2.4 GHz, hand-overs both ways worked. The same happens the
  other way: after the iPhone had sat on 2.4 GHz for hours, four hand-overs to 5 GHz in a
  row didn't move it; after Wi-Fi was turned off and on, hand-overs both ways worked at
  once (248–302 ms). Likely the chip only roams to channels it has seen the network on
  recently. Hand-overs back after a router kick aren't affected, since the iPhone was just
  there. Since 1.4, a failed first hand-over is followed by a scan and one more hand-over:
  `handed over to … (after a scan)` in the log means a scan is enough.
- [ ] **Newer iPhones:** since 1.1 the add-on is also built for arm64e, so iPhone XS, XR and
  newer should load it, but none has been tested. Check the log for `hand-over add-on loaded`
  and `handed over to`. Clang 18 on Linux can't make a proper arm64e build (its output is
  marked plain arm64), so that part is built with Xcode on a GitHub Mac runner.
- [ ] **Other iOS versions:** the hand-over relies on `wifid`'s `WiFiRoamManager` and its
  roam notification, checked only on iOS 15.8.5.
- [ ] **Other routers:** everything was measured on one router.
- [ ] **A band lock in the Wi-Fi chip itself.** Broadcom Wi-Fi chips, like the one in the
  iPhone 6s, generally support locking to one band: the kind of setting Windows drivers
  offer as "5 GHz only". That would stop the router's moves at the source instead of undoing
  them, and on any router. iOS's Wi-Fi driver has no known way to switch it on, so the
  question is whether the driver (inside the iOS kernel) has a hidden one. A setting to
  ignore the router's move requests could be worth looking for there too. Not tried yet.
- [ ] **A 5 GHz-only access point** plugged into the router would end the moves altogether.
  Not tried.

## What it relies on in iOS

The code is in `src/daemon/main.m` (the Wi-Fi band section) and `src/roam/roam.m`.

| Piece | Used for |
| --- | --- |
| MobileWiFi client calls (`WiFiManagerClientCreate`, `CopyDevices`, `WiFiDeviceClientCopyCurrentNetwork`, `ScanAsync`) | Current band and signal; scans for the network's radios |
| `WiFiDeviceClientDisassociate`, `WiFiDeviceClientAssociateAsync`, the saved password from `WiFiManagerClientCopyNetworks` | The disconnect-and-join fallback |
| `BSS_BLACKLIST { BSS_BLACKLIST_BSSIDS }` set on the join record | Per-join avoid list of the other band's radios (up to 3) |
| Wi-Fi driver event messages (read-only kernel event socket) | Noticing moves the moment they happen |
| `WiFiManagerClientSetPower` / `GetPower` | Last resort when iOS won't scan during a move: Wi-Fi off and on, checked to be back on |
| `WiFiTetherRoam.dylib`, loaded into `wifid` | Posts `wifid`'s own roam request: `com.apple.wifid.wifiroammanagerroamnotification` on `WiFiRoamManager`'s queue, band preference 1 (2.4 GHz) or 2 (5 GHz), reason 5 |
| Darwin notifications `com.wifitether.roam5`, `.ready`, `.done` | Request (state = band preference), add-on loaded (state = `wifid`'s pid), answer |
| `prefer-5ghz`, `prefer-24ghz` in `/var/mobile/Library/WiFiTether/` | The two switches |
| `band5-call` in the same folder | Crash guard: if a Wi-Fi call crashes the service, the band switch stays off until it's turned off and on |

Log lines worth searching `daemon.log` for: `force 5 GHz: on`, `hand-over add-on loaded`,
`the router disconnected the`, `again after`, `handed over to`, `hand-over didn't move it`,
`after a scan`, `ms after disconnecting`, `turning Wi-Fi off and on`, and `status:`
(every 5 minutes; its kick count is the number of `again after` lines).
