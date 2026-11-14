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

python3 make-depiction.py "$R/depiction.json"           # Sileo's package page

(cd "$R" && dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null)
sed -i 's/^Sileodepiction:/SileoDepiction:/' "$R/Packages"   # dpkg-scanpackages changes the case
gzip -9 -k -n "$R/Packages"
bzip2 -9 -k "$R/Packages"

{
    echo "Origin: WiFi Tether"
    echo "Label: WiFi Tether"
    echo "Suite: stable"
    echo "Version: 1.0"
    echo "Codename: wifitether"
    echo "Architectures: iphoneos-arm64"
    echo "Components: main"
    echo "Description: WiFi Tether: share a jailbroken iPhone's Wi-Fi over USB"
    for algo in MD5Sum:md5sum SHA256:sha256sum; do
        echo "${algo%%:*}:"
        for f in Packages Packages.gz Packages.bz2; do
            printf ' %s %s %s\n' "$("${algo#*:}" "$R/$f" | cut -d' ' -f1)" "$(stat -c %s "$R/$f")" "$f"
        done
    done
} > "$R/Release"

cat > "$R/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Tether repo</title>
<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;line-height:1.5}
a.b{display:inline-block;background:#007aff;color:#fff;padding:10px 16px;border-radius:10px;text-decoration:none;font-weight:600}
code{background:#f0f0f0;padding:2px 5px;border-radius:4px}</style></head><body>
<h1>WiFi Tether</h1>
<p>Share a jailbroken iPhone's Wi-Fi over USB. Rootless jailbreaks, iOS 15 and later.</p>
<p><a class="b" id="add" href="#">Add to Sileo</a></p>
<p>Or add this source in Sileo by hand: <code id="url"></code></p>
<p>Installing WiFi Tether also adds the repo for the <a href="https://github.com/amineross/share">Share</a> tweak, which it needs; install Share from Sileo afterwards.</p>
<p><a href="https://github.com/scog3/iOS-WiFi-tether">Source code and releases on GitHub</a></p>
<script>var u=location.href.replace(/index\.html$/,'');if(!u.endsWith('/'))u+='/';
document.getElementById('url').textContent=u;document.getElementById('add').href='sileo://source/'+u;</script>
</body></html>
EOF

echo "Repo built in $R:"
ls -la "$R" "$R/debs"
