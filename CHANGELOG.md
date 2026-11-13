# Changelog

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
