WiFi Tether: share a jailbroken iPhone's Wi-Fi over USB

Free, open-source tethering for rootless jailbreaks on iOS 15 and later. Plug your iPhone into a computer and the computer gets internet through the iPhone's Wi-Fi connection. It works without a SIM card, without mobile data and without a carrier tethering plan.

Useful when a computer has no Wi-Fi, broken Wi-Fi, or can't join a network the iPhone can, like a captive portal you've already signed in to on the phone. It's a free alternative to paid tweaks such as Tethera and TetherMe.

Beta. Tested on iPhone with iOS 15.8.5 (palera1n, rootless) and a Windows PC. Reports from other devices are welcome; please open an issue.

What you need
A rootless jailbreak on iOS 15 or later (for example palera1n or Dopamine)
The Share tweak by amineross, from the repo https://aminerostane.com/repo. Share turns on Personal Hotspot without a SIM. WiFi Tether adds the internet connection on top.
A USB cable, and a computer that supports iPhone USB tethering (Windows needs Apple's iPhone drivers, which come with iTunes or Apple Devices; macOS and most Linux distributions work out of the box)
Install
Install Share from https://aminerostane.com/repo and respring.
Download the latest .deb from this repository's Releases page in Safari on the iPhone.
Open the file in Filza or Sileo and install it.
Use
Connect the iPhone to Wi-Fi.
Turn on Personal Hotspot (Settings → Personal Hotspot).
Plug the iPhone into the computer.

That's it: the computer gets an address, gateway and DNS automatically and is online. Open the WiFi Tether app to see the status or switch sharing off.

Status in the app	Meaning
🟢 Sharing Wi-Fi over USB	Working
🟠 Waiting for Wi-Fi	Connect the iPhone to a Wi-Fi network
🟠 Waiting for Personal Hotspot	Turn on Personal Hotspot, then plug in
🔴 Couldn't set up sharing	See the message underneath, and the log below
🔴 Background service isn't running	Re-jailbreak or reinstall the package
Troubleshooting
Computer says "No internet" or "Unidentified network". Unplug and plug the iPhone back in so the computer asks for a new address. On Windows, ipconfig /renew in Command Prompt does the same.
Testing while the computer is also on Wi-Fi. The computer may keep using its own Wi-Fi. Turn the computer's Wi-Fi off to test.
Log and status files are on the iPhone in /var/mobile/Library/WiFiTether/ (daemon.log and status.plist). Attach them to an issue if something fails.
How it works

Share starts Apple's Personal Hotspot in a local-only mode: the computer gets an address but has no route to the internet. WiFi Tether's background service (wifitetherd, runs as root) fills that gap whenever sharing is switched on:

Routing. It turns on IP forwarding and loads NAT rules into the kernel packet filter through /dev/pf (no pfctl needed):
nat on en0 from <hotspot subnet> to any -> <Wi-Fi address>
rdr on bridge100 proto udp/tcp to <phone> port 53 -> <Wi-Fi DNS server>
Gateway and DNS. It adds dhcp_router and dhcp_domain_name_server to the hotspot's DHCP settings (bootpd.plist), so clients set themselves up automatically. It watches that file and puts the entries back the moment iOS rewrites it.

Everything is removed again when you switch sharing off or uninstall.

Build it yourself

Every push to this repository builds the .deb on GitHub Actions (Ubuntu) and publishes it under Releases. To build locally:

Linux: install clang, lld, ldid, dpkg, then run bash build-linux.sh
macOS with Xcode: brew install ldid dpkg, then run bash build.sh

The scripts download an iPhone SDK (from theos/sdks) and Apple's open-source XNU headers for the packet filter structures.

Credits
Share by amineross, which makes the SIM-less hotspot possible. WiFi Tether depends on it.
Packet filter structures from Apple's open-source XNU.
