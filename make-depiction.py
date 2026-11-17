#!/usr/bin/env python3
"""Writes WiFi Tether & Band Switcher's package page, with its details and the changelog from
CHANGELOG.md, in two forms:
  depiction.json - Sileo's own format (Details and Changelog tabs)
  depiction.html - a web page, for package managers that don't read Sileo's format
Both go next to the file named on the command line (default repo/depiction.json)."""
import html, json, os, re, sys

out = sys.argv[1] if len(sys.argv) > 1 else "repo/depiction.json"
text = open("CHANGELOG.md", encoding="utf-8").read()

# "## 0.4.3" sections, newest first
parts = re.split(r"^## +(\S+)\s*$", text, flags=re.M)
versions = [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts) - 1, 2)]

def md(s):
    # Sileo's markdown wants list items on one line
    return re.sub(r"\n(?!\s*[-*] |\n)\s+", " ", s)

# Where the repo is published (from the control file), for the screenshots
base = re.search(r"^SileoDepiction: *(\S+/)depiction\.json",
                 open("packaging/control", encoding="utf-8").read(), re.M).group(1)
screenshots = [("screenshots/tethering-5ghz.png", "Sharing Wi-Fi over USB with Force 5 GHz on"),
               ("screenshots/tethering-vpn.png", "Sharing the iPhone's VPN over USB"),
               ("screenshots/band-switch.png", "Force 2.4 GHz on its own, with sharing off")]

details = (
    "**USB tethering, plus a Wi-Fi band switcher.** Plug your iPhone or iPad into a computer and the "
    "computer is online through its **Wi-Fi**, or through its **VPN**. No SIM or data plan "
    "needed, so **Wi-Fi-only iPads** work too, and nothing to set up on the computer. And switches that keep its Wi-Fi on "
    "**5 GHz** or **2.4 GHz**.\n\n"
    "- **Plug and play.** Leave the switch on and just plug in. If Windows misses the "
    "connection, WiFi Tether retries by itself. On a Mac that's also on Wi-Fi, put iPhone USB "
    "above Wi-Fi in its Network settings (Set Service Order).\n"
    "- **Shares your VPN.** VPN apps or the built-in VPN: the computer goes through it too, DNS included.\n"
    "- **Switch VPN location while plugged in.** The computer follows within a second or two.\n"
    "- **Full speed.** No cap: about what the iPhone itself gets, up to what the USB port "
    "carries. Through a VPN, as fast as the VPN runs on the phone.\n"
    "- **Barely any added latency.** Only a millisecond or two on top of the iPhone's own ping.\n"
    "- **One switch.** Turns Personal Hotspot on, keeps Wi-Fi connected, handles airplane mode.\n"
    "- **Force 5 GHz or 2.4 GHz.** Keeps it on the band you pick, even when the router "
    "moves it. Handy with routers that won't let you split the bands, like BT's Smart Hub 2, "
    "Sky's Max Hub, Google Nest Wifi and eero. "
    "Works on its own, without tethering or Share. Moving back is near-instant, with no "
    "disconnect, on iPhone X and older (A11 chip or older, iPads too). On newer devices that's new "
    "and untested; if it doesn't work there, Wi-Fi drops for about half a second each time.\n"
    "- **See it at a glance.** The band shows as a small 5 or 2.4 on the Wi-Fi icon in every app "
    "(respring once after installing), and an optional quiet notification says what's on.\n"
    "- **No battery drain when it's off.**\n"
    "- **Free and open source** (MIT).\n\n"
    "USB tethering needs the **Share** tweak (the app has a button that adds its repo in Sileo); "
    "the band switches work without it. "
    "iPhone and iPad, rootless jailbreaks, iOS 15 and later.\n\n"
    "[Source code on GitHub](https://github.com/scog3/iOS-WiFi-tether)"
)

changelog = []
for v, body in versions:
    changelog.append({"class": "DepictionSubheaderView", "title": v, "useBoldText": True, "useBottomMargin": False})
    changelog.append({"class": "DepictionMarkdownView", "markdown": md(body), "useSpacing": True})

dep = {
    "minVersion": "0.4",
    "class": "DepictionTabView",
    "tintColor": "#007aff",
    "headerImage": "",
    "tabs": [
        {"tabname": "Details", "class": "DepictionStackView",
         "views": [{"class": "DepictionScreenshotsView", "itemCornerRadius": 8,
                    "itemSize": "{160, 284.5}",   # the screenshots are 750 x 1334
                    "screenshots": [{"url": base + p, "accessibilityText": t} for p, t in screenshots]},
                   {"class": "DepictionMarkdownView", "markdown": details, "useSpacing": True}]},
        {"tabname": "Changelog", "class": "DepictionStackView", "views": changelog},
    ],
}
dep.pop("headerImage")
json.dump(dep, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

# --- web page version ---
def inline(t):
    t = html.escape(t, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"\*([^*]+)\*", r"<i>\1</i>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return t

def to_html(src):
    out, kind = [], None
    for block in re.split(r"\n\s*\n", md(src).strip()):
        lines = [l.strip() for l in block.split("\n") if l.strip()]
        if all(re.match(r"[-*] ", l) for l in lines):
            out.append("<ul>" + "".join(f"<li>{inline(l[2:])}</li>" for l in lines) + "</ul>")
        elif all(re.match(r"\d+\. ", l) for l in lines):
            out.append("<ol>" + "".join(f"<li>{inline(re.sub(r'^\d+\. ', '', l))}</li>" for l in lines) + "</ol>")
        else:
            out.append("<p>" + inline(" ".join(lines)) + "</p>")
    return "\n".join(out)

page = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WiFi Tether &amp; Band Switcher</title>
<style>
:root{{color-scheme:light dark;--bg:#fff;--fg:#111;--muted:#666;--line:#ddd;--code:#f0f0f0}}
@media (prefers-color-scheme:dark){{:root{{--bg:#000;--fg:#eee;--muted:#999;--line:#333;--code:#1c1c1e}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.45 -apple-system,Helvetica,Arial,sans-serif;margin:0;padding:16px}}
h2{{font-size:20px;margin:24px 0 8px}} h3{{font-size:16px;margin:18px 0 4px}}
ul,ol{{padding-left:20px;margin:6px 0}} li{{margin:4px 0}} p{{margin:8px 0}}
code{{background:var(--code);padding:1px 4px;border-radius:4px;font-size:14px}}
a{{color:#0a84ff}} hr{{border:0;border-top:1px solid var(--line);margin:20px 0}}
.shots{{display:flex;gap:10px}} .shots img{{width:calc(50% - 5px);max-width:220px;border-radius:10px}}
</style></head><body>
<div class="shots">{"".join(f'<img src="{html.escape(p)}" alt="{html.escape(t)}">' for p, t in screenshots)}</div>
{to_html(details)}
<hr><h2>Changelog</h2>
{"".join(f"<h3>{html.escape(v)}</h3>{to_html(b)}" for v, b in versions)}
</body></html>
"""
html_out = os.path.join(os.path.dirname(out) or ".", "depiction.html")
open(html_out, "w", encoding="utf-8").write(page)
print(f"Wrote {out} and {html_out}: {len(versions)} versions")
