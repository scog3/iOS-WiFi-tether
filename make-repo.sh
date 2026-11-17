#!/bin/bash
# Builds a Sileo/Cydia repo in ./repo from the .deb files given as arguments.
# The build workflow publishes ./repo with GitHub Pages:
#   https://<user>.github.io/<repository>/
# Needs dpkg-scanpackages (dpkg-dev), gzip, bzip2.
set -euo pipefail
cd "$(dirname "$0")"

R=repo
rm -rf "$R"
mkdir -p "$R/debs"
cp "$@" "$R/debs/"
cp src/app/icons/AppIcon60x60@2x.png "$R/CydiaIcon.png"   # repo icon in Sileo
cp src/app/icons/AppIcon60x60@3x.png "$R/icon.png"        # package icon
cp -r screenshots "$R/"                                   # for the package page

python3 make-depiction.py "$R/depiction.json"           # Sileo's package page

(cd "$R" && dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null)
sed -i 's/^Sileodepiction:/SileoDepiction:/' "$R/Packages"   # dpkg-scanpackages changes the case
gzip -9 -k -n "$R/Packages"
bzip2 -9 -k "$R/Packages"

{
    echo "Origin: WiFi Tether & Band Switcher"
    echo "Label: WiFi Tether & Band Switcher"
    echo "Suite: stable"
    echo "Version: 1.0"
    echo "Codename: wifitether"
    echo "Architectures: iphoneos-arm64"
    echo "Components: main"
    echo "Description: WiFi Tether & Band Switcher: USB tethering and Wi-Fi band control for jailbroken iPhones and iPads"
    for algo in MD5Sum:md5sum SHA256:sha256sum; do
        echo "${algo%%:*}:"
        for f in Packages Packages.gz Packages.bz2; do
            printf ' %s %s %s\n' "$("${algo#*:}" "$R/$f" | cut -d' ' -f1)" "$(stat -c %s "$R/$f")" "$f"
        done
    done
} > "$R/Release"

cat > "$R/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Tether &amp; Band Switcher repo</title>
<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;line-height:1.5}
a.b{display:inline-block;background:#007aff;color:#fff;padding:10px 16px;border-radius:10px;text-decoration:none;font-weight:600}
code{background:#f0f0f0;padding:2px 5px;border-radius:4px}</style></head><body>
<h1>WiFi Tether &amp; Band Switcher</h1>
<p>Plug-and-play USB tethering of a jailbroken iPhone or iPad's Wi-Fi or VPN, plus switches that keep Wi-Fi on 5 GHz or 2.4 GHz, even with routers that won't let you split the bands, like BT's Smart Hub 2, Sky's Max Hub, Google Nest Wifi and eero. No SIM or data plan needed, so Wi-Fi-only iPads work too, and nothing to set up on the computer. iPhone and iPad, rootless jailbreaks, iOS 15 and later.</p>
<p style="display:flex;gap:8px"><img src="screenshots/tethering-5ghz.png" alt="Sharing Wi-Fi over USB with Force 5 GHz on" style="width:calc(33.3% - 6px);max-width:180px;border-radius:10px"><img src="screenshots/tethering-vpn.png" alt="Sharing the iPhone's VPN over USB" style="width:calc(33.3% - 6px);max-width:180px;border-radius:10px"><img src="screenshots/band-switch.png" alt="Force 2.4 GHz on its own, with sharing off" style="width:calc(33.3% - 6px);max-width:180px;border-radius:10px"></p>
<p><a class="b" id="add" href="#">Add to Sileo</a></p>
<p>Or add this source in Sileo by hand: <code id="url"></code></p>
<p>Once it's installed, it's called <b>Tether &amp; Band</b> on the home screen.</p>
<h2>USB tethering</h2>
<ol><li>Connect the iPhone or iPad to Wi-Fi.</li><li>Open Tether &amp; Band and turn on <b>Share Wi-Fi over USB</b>.</li><li>Plug it into the computer with a USB cable.</li></ol>
<p>On a Mac that's also on Wi-Fi: <b>System Settings → Network → ⋯ → Set Service Order</b>, and drag <b>iPhone USB</b> above Wi-Fi (or turn the Mac's Wi-Fi off).</p>
<p>Needs the <a href="https://github.com/amineross/share">Share</a> tweak: in Tether &amp; Band, tap <b>Add Share's Repo in Sileo</b>, then <b>Add Dist Repo</b> and <b>Add</b>, and install Share. (Or add <code>https://aminerostane.com/repo</code> in Sileo yourself; if <b>Add Source</b> doesn't add it, use <b>Add Dist Repo</b>.)</p>
<h2>Wi-Fi band switcher</h2>
<p>Open Tether &amp; Band and turn on <b>Force 5 GHz Wi-Fi</b> or <b>Force 2.4 GHz Wi-Fi</b>. Only one can be on. It doesn't need Share or tethering. The first switch after a while can take a few seconds; after that it's near-instant.</p>
<p><a href="https://github.com/scog3/iOS-WiFi-tether">Source code and releases on GitHub</a></p>
<script>var u=location.href.replace(/index\.html$/,'');if(!u.endsWith('/'))u+='/';
document.getElementById('url').textContent=u;document.getElementById('add').href='sileo://source/'+u;</script>
</body></html>
EOF

echo "Repo built in $R:"
ls -la "$R" "$R/debs"
