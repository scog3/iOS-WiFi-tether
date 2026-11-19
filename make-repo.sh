#!/bin/bash
# Puts this project's package into your Sileo repo, then rebuilds the repo's
# indexes:
#   bash make-repo.sh <repo folder> <.deb files>
#
# The repo folder is a checkout of your Sileo repo's own GitHub repository
# (REPO_URL is where GitHub Pages serves it). It's one repo for all your
# projects: it can hold any number of packages. This
#   - adds this project's .deb to debs/, removing its older versions (other
#     packages' .debs are left alone),
#   - writes this package's pages under packages/<package id>/ (a web page,
#     Sileo's depiction, the icon and the screenshots),
#   - rebuilds Packages, Release and the repo's home page from every .deb in
#     debs/, so they list every package in the repo.
# Another project can publish to the same repo with a copy of this script:
# change the "This package" part.
#
# Needs dpkg-dev (dpkg-scanpackages, dpkg-deb), gzip, bzip2 and python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ $# -ge 2 ] || { echo "usage: make-repo.sh <repo folder> <.deb files>"; exit 1; }
R="$(cd "$1" && pwd)"
shift
DEBS=()
for d in "$@"; do DEBS+=("$(cd "$(dirname "$d")" && pwd)/$(basename "$d")"); done

REPO_URL="${REPO_URL:-https://scog3.github.io/repo/}"
case "$REPO_URL" in */) ;; *) REPO_URL="$REPO_URL/" ;; esac
DEFAULT_TITLE="scog3's Repo"   # (an apostrophe inside \${...:-...} confuses bash)
REPO_TITLE="${REPO_TITLE:-$DEFAULT_TITLE}"
REPO_ABOUT="${REPO_ABOUT:-Tweaks and apps by scog3 for jailbroken iPhones and iPads.}"

# ---- This package ------------------------------------------------------
ID=com.wifitether
P="$R/packages/$ID"
mkdir -p "$R/debs"
for f in "$R"/debs/*.deb; do
    [ -e "$f" ] || continue
    if [ "$(dpkg-deb -f "$f" Package 2>/dev/null)" = "$ID" ]; then rm -f "$f"; fi
done
cp "${DEBS[@]}" "$R/debs/"

rm -rf "$P"
mkdir -p "$P"
cp "$HERE/src/app/icons/AppIcon60x60@3x.png" "$P/icon.png"
cp -r "$HERE/screenshots" "$P/"
(cd "$HERE" && python3 make-depiction.py "$P/depiction.json" "${REPO_URL}packages/$ID/")

# The package's web page (what the repo's home page links to).
TITLE_HTML="$(printf '%s' "$REPO_TITLE" | sed 's/&/\&amp;/g; s/</\&lt;/g')"
SHOTS=""
for s in welcome:"The welcome screen" tethering:"Sharing Wi-Fi and the VPN over USB, with Force 5 GHz on" \
         band-switch:"Force 2.4 GHz on its own, with sharing off"; do
    f="${s%%:*}.png"
    [ -e "$P/screenshots/$f" ] && SHOTS+="<img src=\"screenshots/$f\" alt=\"${s#*:}\">"
done
cat > "$P/index.html" <<EOF
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Tether &amp; Band Switcher</title>
<style>:root{color-scheme:light dark}body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;line-height:1.5}
a.b{display:inline-block;background:#007aff;color:#fff;padding:10px 16px;border-radius:10px;text-decoration:none;font-weight:600}
code{background:rgba(127,127,127,.18);padding:2px 5px;border-radius:4px}a{color:#0a84ff}
.shots{display:flex;gap:8px}.shots img{width:calc(33.3% - 6px);max-width:180px;border-radius:10px}</style></head><body>
<p><a href="../../">← ${TITLE_HTML}</a></p>
<h1>WiFi Tether &amp; Band Switcher</h1>
<p>Switches that keep a jailbroken iPhone or iPad's Wi-Fi on 5 GHz or 2.4 GHz, even with routers that won't let you split the bands, like BT's Smart Hub 2, Sky's Max Hub, Google Nest Wifi and eero, plus plug-and-play USB tethering of its Wi-Fi or VPN. No SIM or data plan needed, so Wi-Fi-only iPads work too, and nothing to set up on the computer. iPhone and iPad, rootless jailbreaks, iOS 15 and later.</p>
<p class="shots">$SHOTS</p>
<p><a class="b" href="sileo://source/${REPO_URL}">Add the repo to Sileo</a></p>
<p>Or add this source in Sileo by hand: <code>${REPO_URL}</code></p>
<p>Once it's installed, it's called <b>Tether &amp; Band</b> on the home screen.</p>
<h2>Wi-Fi band switcher</h2>
<p>Open Tether &amp; Band and turn on <b>Force 5 GHz Wi-Fi</b> or <b>Force 2.4 GHz Wi-Fi</b>. Only one can be on. It works on its own: no other tweaks needed. The first switch after a while can take a few seconds; after that it's near-instant.</p>
<h2>USB tethering</h2>
<ol><li>Connect the iPhone or iPad to Wi-Fi.</li><li>Open Tether &amp; Band and turn on <b>Share Wi-Fi over USB</b>.</li><li>Plug it into the computer with a USB cable.</li></ol>
<p>On a Mac that's also on Wi-Fi: <b>System Settings → Network → ⋯ → Set Service Order</b>, and drag <b>iPhone USB</b> above Wi-Fi (or turn the Mac's Wi-Fi off).</p>
<p>Only USB tethering needs the <a href="https://github.com/amineross/share">Share</a> tweak: in Tether &amp; Band, tap <b>Add Share's Repo in Sileo</b>, then <b>Add Dist Repo</b> and <b>Add</b>, and install Share. (Or add <code>https://aminerostane.com/repo</code> in Sileo yourself; if <b>Add Source</b> doesn't add it, use <b>Add Dist Repo</b>.)</p>
<p><a href="depiction.html">Details and changelog</a> · <a href="https://github.com/scog3/iOS-WiFi-tether">Source code on GitHub</a></p>
</body></html>
EOF

# A repo icon until you put your own CydiaIcon.png in the repo (it's never replaced).
[ -e "$R/CydiaIcon.png" ] || cp "$HERE/src/app/icons/AppIcon60x60@2x.png" "$R/CydiaIcon.png"

# ---- The whole repo (every package in debs/) ----------------------------
(cd "$R" && dpkg-scanpackages -m debs /dev/null > Packages 2>/dev/null)
sed -i 's/^Sileodepiction:/SileoDepiction:/' "$R/Packages"   # dpkg-scanpackages changes the case
rm -f "$R/Packages.gz" "$R/Packages.bz2"
gzip -9 -k -n "$R/Packages"
bzip2 -9 -k "$R/Packages"

{
    echo "Origin: $REPO_TITLE"
    echo "Label: $REPO_TITLE"
    echo "Suite: stable"
    echo "Version: 1.0"
    echo "Codename: stable"
    echo "Architectures: iphoneos-arm64"
    echo "Components: main"
    echo "Description: $REPO_ABOUT"
    for algo in MD5Sum:md5sum SHA256:sha256sum; do
        echo "${algo%%:*}:"
        for f in Packages Packages.gz Packages.bz2; do
            printf ' %s %s %s\n' "$("${algo#*:}" "$R/$f" | cut -d' ' -f1)" "$(stat -c %s "$R/$f")" "$f"
        done
    done
} > "$R/Release"

# The home page: the repo, an Add to Sileo button, and every package in it.
REPO_URL="$REPO_URL" REPO_TITLE="$REPO_TITLE" REPO_ABOUT="$REPO_ABOUT" python3 - "$R" <<'PY'
import html, os, re, sys
r = sys.argv[1]
url, title, about = os.environ["REPO_URL"], os.environ["REPO_TITLE"], os.environ["REPO_ABOUT"]
pkgs = {}
for block in open(os.path.join(r, "Packages"), encoding="utf-8").read().split("\n\n"):
    f = dict(re.findall(r"^([A-Za-z-]+): *(.*)$", block, re.M))
    if "Package" in f:
        pkgs[f["Package"]] = f          # one entry per package (each keeps only its latest .deb)
items = []
for pid, f in sorted(pkgs.items(), key=lambda kv: kv[1].get("Name", kv[0]).lower()):
    page = f"packages/{pid}/" if os.path.isdir(os.path.join(r, "packages", pid)) else f.get("Depiction", "")
    icon = f"packages/{pid}/icon.png" if os.path.exists(os.path.join(r, "packages", pid, "icon.png")) else f.get("Icon", "")
    desc = f.get("Description", "")
    short = re.split(r"(?<=[.!?])\s", desc, maxsplit=1)[0]
    img = f'<img src="{html.escape(icon)}" alt="">' if icon else '<span class="noicon"></span>'
    items.append(f'<a class="p" href="{html.escape(page)}">{img}'
                 f'<span><b>{html.escape(f.get("Name", pid))}</b> <small>{html.escape(f.get("Version", ""))}</small>'
                 f'<br>{html.escape(short)}</span></a>')
page = f"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
<style>:root{{color-scheme:light dark}}body{{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;line-height:1.45}}
a.b{{display:inline-block;background:#007aff;color:#fff;padding:10px 16px;border-radius:10px;text-decoration:none;font-weight:600}}
code{{background:rgba(127,127,127,.18);padding:2px 5px;border-radius:4px}}
a.p{{display:flex;gap:12px;align-items:center;padding:12px 0;border-top:1px solid rgba(127,127,127,.25);color:inherit;text-decoration:none}}
a.p img,.noicon{{width:58px;height:58px;border-radius:13px;flex:none}}.noicon{{background:rgba(127,127,127,.25)}} small{{opacity:.6}}</style></head><body>
<h1>{html.escape(title)}</h1>
<p>{html.escape(about)}</p>
<p><a class="b" href="sileo://source/{html.escape(url)}">Add to Sileo</a></p>
<p>Or add this source in Sileo by hand: <code>{html.escape(url)}</code></p>
<h2>Packages</h2>
{"".join(items) or "<p>None yet.</p>"}
</body></html>
"""
open(os.path.join(r, "index.html"), "w", encoding="utf-8").write(page)
PY
touch "$R/.nojekyll"   # GitHub Pages serves the files as they are

echo "Repo updated in $R:"
ls -la "$R" "$R/debs" "$P"
