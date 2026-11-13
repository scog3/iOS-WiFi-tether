# WiFi Tether: share a jailbroken iPhone's Wi-Fi over USB

**Free, open-source tethering for rootless jailbreaks on iOS 15 and later, on iPhone and iPad.**
Plug your iPhone into a computer and the computer gets internet through the
iPhone's **Wi-Fi** connection. It works without a SIM card, without mobile data
and without a carrier tethering plan.

If a **VPN** is connected on the iPhone, the computer's traffic goes through the VPN
too, with nothing to set up on the computer.

Useful when a computer has no Wi-Fi, broken Wi-Fi, or can't join a network the
iPhone can, like a captive portal you've already signed in to on the phone.
It's a free alternative to paid tweaks such as Tethera and TetherMe.

> **Beta.** Tested on iPhone with iOS 15.8.5 (Dopamine, rootless) and a Windows PC.
> iPads should work too, since Share supports them (including Wi-Fi-only models), but haven't been tested yet.
> Reports from other devices are welcome; please open an issue.

## What you need

- A **rootless** jailbreak on iOS 15 or later (for example palera1n or Dopamine)
- The **[Share](https://github.com/amineross/share)** tweak by amineross, from the repo
  `https://aminerostane.com/repo`. Share turns on Personal Hotspot without a SIM.
  WiFi Tether adds the internet connection on top.
- A USB cable, and a computer that supports iPhone USB tethering
  (Windows needs Apple's iPhone drivers, which come with iTunes or Apple Devices;
  macOS and most Linux distributions work out of the box)

## Install

1. Install **Share** from `https://aminerostane.com/repo` and respring.
2. Download the latest `.deb` from this repository's
   **[Releases](../../releases)** page in Safari on the iPhone.
3. Open the file in **Filza** or **Sileo** and install it.

## Use

1. Connect the iPhone to **Wi-Fi**.
2. Turn on **Personal Hotspot** (Settings → Personal Hotspot).
3. Plug the iPhone into the computer.

That's it: the computer gets an address, gateway and DNS automatically and is online.
Open the **WiFi Tether** app to see the status or switch sharing off.

| Status in the app | Meaning |
| --- | --- |
| 🟢 Sharing Wi-Fi over USB | Working |
| 🟠 Waiting for Wi-Fi | Connect the iPhone to a Wi-Fi network |
| 🟠 Waiting for Personal Hotspot | Turn on Personal Hotspot, then plug in |
| 🔴 Couldn't set up sharing | See the message underneath, and the log below |
| 🔴 Background service isn't running | Re-jailbreak or reinstall the package |

The **VPN** row shows *Not connected*, *Shared via utunN* (the computer's traffic goes
through the iPhone's VPN), or *not shared yet* (the VPN was just connected; give it a
couple of seconds).

## Sharing the iPhone's VPN

Connect a VPN on the iPhone and the computer's traffic follows it automatically.
Disconnect it and traffic goes straight out through Wi-Fi again.

- Works with VPN apps that create a normal packet tunnel with an IPv4 address
  (WireGuard, sing-box / Hiddify and similar). Only IPv4 goes through the VPN.
- With sing-box based apps (Hiddify etc.), set the TUN stack to **mixed**, not
  *gvisor*: gvisor can run out of memory under heavy uploads and iOS stops the VPN.
- iOS limits VPN apps to 50 MB of memory. WiFi Tether raises that to 128 MB while
  sharing, slows uploads down if the VPN gets close to its limit, and restarts the
  VPN if iOS stops it anyway. The automatic restart needs **python3** (installed with
  WiFi Tether when you install from a repo; with Filza, install python3 from Sileo).
- DNS lookups from the computer go through the VPN as well.
- Don't also install the stand-alone *ios-hotspot-vpn-keepalive* `pftun`; WiFi Tether
  includes it and stops the separate copy on install.

This part is based on [pftun](https://github.com/maliv2/ios-hotspot-vpn-keepalive)
by Muhammet Ali Aydın (MIT). Upstream tested it on iOS 17.6.1; on iOS 15 it's new.

## Troubleshooting

- **Computer says "No internet" or "Unidentified network".** Unplug and plug the
  iPhone back in so the computer asks for a new address. On Windows,
  `ipconfig /renew` in Command Prompt does the same.
- **Testing while the computer is also on Wi-Fi.** The computer may keep using
  its own Wi-Fi. Turn the computer's Wi-Fi off to test.
- **Log and status files** are on the iPhone in `/var/mobile/Library/WiFiTether/`
  (`daemon.log`, `vpn.log` and `status.plist`). Attach them to an issue if
  something fails. Logs are capped at 1 MB.

## How it works

Share starts Apple's Personal Hotspot in a local-only mode: the computer gets an
address but has no route to the internet. WiFi Tether's background service
(`wifitetherd`, runs as root) fills that gap whenever sharing is switched on:

1. **Routing.** It turns on IP forwarding and loads NAT rules into the kernel packet
   filter through `/dev/pf` (no `pfctl` needed):
   - `nat on en0 from <hotspot subnet> to any -> <Wi-Fi address>`
   - `rdr on bridge100 proto udp/tcp to <phone> port 53 -> <Wi-Fi DNS server>`
2. **Gateway and DNS.** It adds `dhcp_router` and `dhcp_domain_name_server` to the
   hotspot's DHCP settings (`bootpd.plist`), so clients set themselves up
   automatically. It watches that file and puts the entries back the moment iOS
   rewrites it.

3. **VPN.** `src/vpn` is pftun from ios-hotspot-vpn-keepalive with a few marked
   changes. When a VPN is up, a `route-to` rule sends client traffic to pftun's own
   utun; pftun re-sends each packet through a raw socket bound to the VPN's utun,
   where a `nat` rule translates it. (Routing straight into the VPN's utun can panic
   the kernel; upstream's README explains why.) Share's local-only hotspot has no
   pf anchors of its own, so `wifitetherd` links pftun's anchor `wifitether.vpn`
   into the main ruleset with a `nat-anchor` and a filter `anchor` rule.

Everything is removed again when you switch sharing off or uninstall.

## Build it yourself

Every push to this repository builds the `.deb` on GitHub Actions (Ubuntu) and
publishes it as a release named after the version in `VERSION`, with that version's
notes from [CHANGELOG.md](CHANGELOG.md). Building the same version again replaces its
`.deb`; bump `VERSION` and add a changelog entry to make a new release. To build locally on Linux, install `clang`, `lld`,
`ldid` and `dpkg`, then run `bash build-linux.sh`.

The script downloads an iPhone SDK (from [theos/sdks](https://github.com/theos/sdks))
and Apple's open-source XNU sources for the packet filter and other private headers.

## Credits

- **[Share](https://github.com/amineross/share)** by amineross, which makes the
  SIM-less hotspot possible. WiFi Tether depends on it.
- **[pftun](https://github.com/maliv2/ios-hotspot-vpn-keepalive)** by Muhammet Ali
  Aydın (MIT licence, included in `src/vpn/LICENSE`), which does the VPN sharing.
- Packet filter structures from Apple's open-source
  [XNU](https://github.com/apple-oss-distributions/xnu).
