# WiFi Tether

Shares a jailbroken iPhone's **Wi-Fi** connection with a computer over **USB**.
For palera1n (rootless) on iOS 15.

It works together with the [Share](https://github.com/amineross/share) tweak:
Share makes Personal Hotspot available without a SIM, but on purpose gives
connected devices no internet. WiFi Tether adds the missing part: it routes
hotspot/USB traffic out through Wi-Fi (NAT) and forwards DNS lookups.

## Use it

1. Install Share (repo `https://aminerostane.com/repo`) and WiFi Tether.
2. Connect the iPhone to Wi-Fi.
3. Turn on Personal Hotspot.
4. Plug the iPhone into the computer.

Open the WiFi Tether app to see the status or switch sharing off.

## Build

Push this folder to a GitHub repository. The **Build** workflow compiles it on
GitHub's Mac servers and publishes the .deb as a release named "latest".

To build on a Mac yourself: `brew install ldid dpkg && bash build.sh`.

## How it works

- `src/daemon` — a root background service. Every 2 seconds it checks for a
  Wi-Fi address on `en0` and a hotspot address on a `bridge` interface. When
  both exist it turns on `net.inet.ip.forwarding` and loads pf rules through
  `/dev/pf`:
  - `nat on en0 from <hotspot subnet> to any -> <Wi-Fi address>`
  - `rdr on bridge100 proto udp/tcp to <bridge address> port 53 -> <Wi-Fi DNS server>`
  It removes them again when sharing is switched off or the hotspot goes away.
- `src/app` — the switch and status screen.

Files on the phone: status and log in `/var/mobile/Library/WiFiTether/`.
