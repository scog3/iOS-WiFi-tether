# Changelog

## 0.4.12

- **Force 5 GHz** joins 5 GHz only once the disconnect has actually happened. Joining
  a moment too early was ignored, and iOS went straight back to 2.4 GHz. It then
  watches for up to 10 seconds whether the iPhone lands on 5 GHz, and tries up to 3
  times.
- **Force 5 GHz works without the Share tweak**; only USB sharing needs Share.
- The app is split into **USB tethering** and **5 GHz Wi-Fi** sections, and the
  package is now called **WiFi Tether & Force 5 GHz** in Sileo.

## 0.4.11

- **Force 5 GHz Wi-Fi** (was *Keep Wi-Fi on 5 GHz*) now keeps the iPhone on 5 GHz
  however weak the signal, unless it's too weak to connect to at all (below −85 dBm).
  Turning it on asks first, because a weak 5 GHz signal can make Wi-Fi slower or
  unstable.
- Checks every 5 seconds instead of 10, so when iOS switches back to 2.4 GHz it's moved
  back to 5 GHz sooner. The safety limit is now 10 moves in 10 minutes.

## 0.4.10

- **Keep Wi-Fi on 5 GHz** actually moves the iPhone now: iOS ignores a request to
  join another radio of the network it's already on, so WiFi Tether disconnects first
  and joins the 5 GHz radio straight away. If iOS's own auto-join wins the race back
  to 2.4 GHz, it tries once more.

## 0.4.9

- New **Keep Wi-Fi on 5 GHz** switch (off by default). Once an iPhone has joined a
  router's 2.4 GHz radio it stays there, even right next to the router, because iOS
  only looks for another radio when the signal gets weak; iOS has no setting to pick
  the band. With the switch on, WiFi Tether moves the iPhone to the same network's
  5 GHz radio, and moves it back whenever iOS drifts to 2.4 GHz. Works with sharing
  off too.
- It stays on 2.4 GHz when 5 GHz is too weak where you are, and if iOS keeps drifting
  back it waits a few minutes before trying again, so Wi-Fi doesn't keep dropping.
  The switch shows what it's doing. New, so please report how it goes.

## 0.4.8

- The **Wi-Fi** row shows which band the iPhone is on, e.g. *192.168.1.133 · 5 GHz*.
  On 2.4 GHz everything is a lot slower, the computer included; many routers decide
  the band themselves and can leave the iPhone on 2.4 GHz.

## 0.4.7

- **Add Share's Repo in Sileo** button: opens Sileo with Share's repo address filled
  in, every time. Tap **Add Dist Repo**, then **Add**; the app's instructions now say so.
  (Sileo's *Add Source* runs an online check first that can drop the repo silently.)
- The installer no longer adds Share's repo to Sileo's list. Sileo could overwrite the
  change, so the repo sometimes never appeared and the button then said Share
  couldn't be found.

## 0.4.6

- Fixes the app squeezing everything into a narrow column on iPhones (from 0.4.4's
  iPad layout change).

## 0.4.5

- Share's repo is now added to **Sileo's own list**, so it appears and can be removed in
  Sileo like any repo you added yourself. The separate file 0.4.3 and 0.4.4 used is
  moved over automatically.

## 0.4.4

- **Share is required.** Without the Share tweak WiFi Tether now does nothing: the switch
  is greyed out and the app explains what's missing, with a **Get Share in Sileo**
  button.
- Fixes Personal Hotspot not turning on when WiFi Tether was installed before Share.
  When Share is installed WiFi Tether restarts iOS's hotspot service so Share loads, and
  whenever that service restarts WiFi Tether reconnects to it.
- On iPads and other wide screens the app keeps a phone-width layout, centred.
- Every build has its own package version, so Sileo never gets two different files with
  the same version.

## 0.4.3

- **Install and update from Sileo.** WiFi Tether now has its own repo:
  `https://scog3.github.io/iOS-WiFi-tether/`. Updates show up in Sileo like any tweak.
- Installing WiFi Tether adds the Share tweak's repo to Sileo if it isn't there yet, and
  Sileo offers Share alongside it.
- WiFi Tether's page in Sileo has a **Changelog** tab, and other package managers show
  the changelog as a web page.

## 0.4.2

- Removed the *Personal Hotspot settings* button.

## 0.4.1

- **Connections switch over instantly** when the VPN connects, disconnects or changes
  location. Before, the computer kept sending on connections that no longer went
  anywhere and took about a minute to give up; now the phone tells it straight away
  that they're closed, so it reconnects at once through the new route.
- The VPN also counts as changed when it reconnects with the same interface name but a
  new address.
- **Airplane mode.** Switching WiFi Tether on turns airplane mode off, and switching it
  off turns airplane mode back on (only if WiFi Tether turned it off). If airplane mode
  is turned on while sharing, a pop-up offers to turn it off again.
- **Computer not connecting** (e.g. the first time on a new USB port): when a computer
  is plugged in but hasn't connected after 10 seconds, the hotspot is restarted
  automatically, the software version of replugging, and retried while it's plugged
  in. New **Waiting for the computer** status shows what's happening.
- New **Airplane mode is on** status.

## 0.4.0

- **One switch does everything.** Turning WiFi Tether on now turns Personal Hotspot on
  for you, without dropping Wi-Fi, and keeps it on, including after re-jailbreaking.
  Turning it off turns Personal Hotspot off. No more Settings page, Control Center or
  "turn on Wi-Fi?" prompt.
- The hotspot is switched on quietly, only for USB: it isn't made visible to Wi-Fi
  devices, which is what made iOS disconnect Wi-Fi. If Wi-Fi drops anyway, it's
  reconnected automatically.
- If the hotspot turns itself off while the switch is on, it's turned back on (at most
  three times in 10 minutes).
- **Nothing runs in the background while the switch is off.** Both services sleep until
  the switch changes, instead of checking every second.
- New **Ready: plug in the USB cable** status.
- Uninstalling now always removes the routing rules and gateway settings.
- Hotspot and Wi-Fi control is based on [AutoHotspot](https://github.com/27445688/AutoHotspot)
  by 张小生 (MIT).

## 0.3.1

- **Works with any full-tunnel VPN.** The VPN is now found by asking the kernel which
  interface the iPhone's own internet traffic uses, instead of guessing from interface
  names. Fixes IKEv2 VPNs (`ipsec` interfaces) and VPN apps using `198.18.x.x`
  addresses not being detected.
- **Fixes pages loading forever through the VPN.** VPN tunnels often take smaller
  packets than the computer sends (IKEv2: 1280 bytes). WiFi Tether now tells the
  computer to send smaller packets, the way a router does, instead of dropping them.
- The VPN helper's own interface moved to `192.0.2.1`, an address no VPN uses.
- The VPN helper looks for a VPN app process every 30 seconds instead of every second
  when there isn't one (IKEv2 VPNs have none).

## 0.3.0

- **Share the iPhone's VPN.** When a VPN is connected on the iPhone, the computer's
  traffic goes through it automatically, including DNS lookups. Disconnect the VPN
  and traffic goes straight out through Wi-Fi again.
- Based on [pftun](https://github.com/maliv2/ios-hotspot-vpn-keepalive) by Muhammet
  Ali Aydın (MIT), adapted to work with Share's local-only hotspot.
- Raises the VPN app's memory limit while sharing, slows uploads if the VPN gets close
  to it, and restarts the VPN if iOS stops it anyway (the restart needs python3).
- New **VPN** row in the app.
- Logs are capped at 1 MB, and a repeating error is only logged once.
- Removed the unmaintained macOS build script; GitHub builds with `build-linux.sh`.

## 0.2.1

- The gateway and DNS entries stay in place for as long as sharing is switched on,
  and are put back the instant iOS rewrites the hotspot settings. Fixes computers
  sometimes connecting with "No internet" until unplugged and plugged back in.
- Checks every second instead of every two.

## 0.2.0

- **No setup on the computer.** The iPhone now hands out the gateway and DNS server
  automatically, so the computer gets online as soon as it's plugged in.
- New app icon.

## 0.1.0

- First release: shares the iPhone's Wi-Fi connection over USB on top of Share's
  hotspot (NAT and DNS forwarding through the packet filter).
- App with an on/off switch and status.
