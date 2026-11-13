# Changelog

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
