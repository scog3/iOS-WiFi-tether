#!/usr/bin/env python3
"""Writes WiFi Tether's package page, with its details and the changelog from
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

details = (
    "Share your jailbroken iPhone's **Wi-Fi** connection with a computer over **USB**, "
    "or its **VPN** when one is connected.\n\n"
    "1. Connect the iPhone to Wi-Fi.\n"
    "2. Open **WiFi Tether** and turn the switch on.\n"
    "3. Plug the iPhone into the computer.\n\n"
    "Needs the **Share** tweak: the app has a button that adds its repo in Sileo. "
    "Rootless jailbreaks, iOS 15 and later.\n\n"
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
         "views": [{"class": "DepictionMarkdownView", "markdown": details, "useSpacing": True}]},
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
<title>WiFi Tether</title>
<style>
:root{{color-scheme:light dark;--bg:#fff;--fg:#111;--muted:#666;--line:#ddd;--code:#f0f0f0}}
@media (prefers-color-scheme:dark){{:root{{--bg:#000;--fg:#eee;--muted:#999;--line:#333;--code:#1c1c1e}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.45 -apple-system,Helvetica,Arial,sans-serif;margin:0;padding:16px}}
h2{{font-size:20px;margin:24px 0 8px}} h3{{font-size:16px;margin:18px 0 4px}}
ul,ol{{padding-left:20px;margin:6px 0}} li{{margin:4px 0}} p{{margin:8px 0}}
code{{background:var(--code);padding:1px 4px;border-radius:4px;font-size:14px}}
a{{color:#0a84ff}} hr{{border:0;border-top:1px solid var(--line);margin:20px 0}}
</style></head><body>
{to_html(details)}
<hr><h2>Changelog</h2>
{"".join(f"<h3>{html.escape(v)}</h3>{to_html(b)}" for v, b in versions)}
</body></html>
"""
html_out = os.path.join(os.path.dirname(out) or ".", "depiction.html")
open(html_out, "w", encoding="utf-8").write(page)
print(f"Wrote {out} and {html_out}: {len(versions)} versions")
