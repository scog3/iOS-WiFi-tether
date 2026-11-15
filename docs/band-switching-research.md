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
  took 278 ms with no disconnect. The fallback, disconnect and join with an avoid list,
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

Seven moves in the order they happened during testing.

| Move | Build | 5 GHz signal | Time on 5 GHz before | Back on 5 GHz after | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | dev 5 | −80 dBm | 45 s | 4.6 s | Try at +4.2 s accepted |
| 2 | dev 5 | −84 dBm | 6½ min | 16.5 s | Try at +4.3 s refused; try at +16 s worked |
| 3 | dev 5 | −84 dBm | 33 s | 22.8 s | Try at +5 s refused; try at +21 s worked |
| 4 | dev 5 | not logged | 18 min | gave up for 5 min | A scan straight after the move saw nothing; fixed in dev 7 |
| 5 | dev 6 | −75 dBm | 37 s | 1.5 s | Accepted 0.5 s after the move |
| 6 | dev 7 | −81 dBm | 51 s | 0.66 s | Disconnect and join, about 0.45 s without Wi-Fi |
| 7 | dev 8 | −78 dBm | — | 278 ms | Hand-over from 2.4 GHz, no disconnect (started by hand, not by the router) |

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
| Sending logs from inside the app | Crashed the app; logs are copied off the phone with Filza instead |

## Open questions

- [ ] **Hand-over straight after a router move:** the hand-over was first tested from a
  manual start on 2.4 GHz. Watch the log for a move followed by `handed over` or
  `hand-over didn't move it`.
- [ ] **Does the router give up steering?** After the first hand-overs the iPhone stayed on
  5 GHz for long stretches at about −80 dBm. That could be chance or band steering giving up
  on a device that keeps coming straight back. The 5-minute status lines will show it.
- [ ] **Band preference 1 for 2.4 GHz** in the hand-over request is inferred (`wifid`
  accepts 0–2; 2 for 5 GHz is confirmed). Force 2.4 GHz falls back to disconnect-and-join if
  it's wrong.
- [ ] **Why iOS turns down scans while on 5 GHz** (error 0x10, busy) on the iPhone 6s.
  Scans on 2.4 GHz work.
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
| `WiFiTetherRoam.dylib`, loaded into `wifid` | Posts `wifid`'s own roam request: `com.apple.wifid.wifiroammanagerroamnotification` on `WiFiRoamManager`'s queue, band preference 1 (2.4 GHz) or 2 (5 GHz), reason 5 |
| Darwin notifications `com.wifitether.roam5`, `.ready`, `.done` | Request (state = band preference), add-on loaded (state = `wifid`'s pid), answer |
| `prefer-5ghz`, `prefer-24ghz` in `/var/mobile/Library/WiFiTether/` | The two switches |
| `band5-call` in the same folder | Crash guard: if a Wi-Fi call crashes the service, the band switch stays off until it's turned off and on |

Log lines worth searching `daemon.log` for: `force 5 GHz: on`, `hand-over add-on loaded`,
`the router disconnected the iPhone`, `handed over to`, `hand-over didn't move it`,
`ms after disconnecting`, and `status:` (every 5 minutes).
