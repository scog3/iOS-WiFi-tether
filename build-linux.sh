#!/bin/bash
# Builds the rootless .deb on Linux (Ubuntu). Used by the GitHub Actions workflow.
# Needs: clang, lld, ldid, dpkg-deb, git, curl (the workflow installs them).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
B=build
T="${TOOLS:-$HOME/ios-build-tools}"
rm -rf "$B"
mkdir -p "$B/include/xnu" "$T"

echo "== Getting an iPhone SDK"
if [ -n "${SDK_DIR:-}" ]; then
    SDK="$SDK_DIR"
else
if [ ! -d "$T/sdks/.git" ]; then
    rm -rf "$T/sdks"
    git clone --quiet --depth 1 --filter=blob:none --no-checkout https://github.com/theos/sdks.git "$T/sdks"
fi
SDK_NAME="$(git -C "$T/sdks" ls-tree --name-only HEAD | grep -E '^iPhoneOS1[4-9][0-9.]*\.sdk$' | sort -V | tail -1)"
[ -n "$SDK_NAME" ] || { echo "No iPhone SDK found in theos/sdks"; exit 1; }
git -C "$T/sdks" sparse-checkout set --no-cone "/$SDK_NAME/"
git -C "$T/sdks" checkout --quiet
SDK="$T/sdks/$SDK_NAME"
fi
echo "Using $(basename "$SDK")"

echo "== Getting Apple's XNU headers (for the packet filter)"
XNU="${XNU_DIR:-}"
[ -n "$XNU" ] || for tag in xnu-8020.240.18 xnu-8020.140.41 xnu-8020.121.3 xnu-8019.80.24; do
    if [ -d "$T/$tag" ] || curl -fsSL "https://github.com/apple-oss-distributions/xnu/archive/refs/tags/$tag.tar.gz" \
            | tar -xz -C "$T" --transform "s,^xnu-$tag,$tag," 2>/dev/null; then
        if [ -f "$T/$tag/bsd/net/pfvar.h" ]; then XNU="$T/$tag"; break; fi
    fi
done
[ -n "$XNU" ] || { echo "Couldn't download Apple's XNU sources"; exit 1; }
cp "$XNU/bsd/net/pfvar.h" "$B/include/xnu/pfvar.h"
echo "Using $(basename "$XNU")"

CLANG="${CLANG:-clang}"
CFLAGS=(-target arm64-apple-ios15.0 -isysroot "$SDK" -Os -Wall -Wno-unused-parameter)
LDFLAGS=(-fuse-ld=lld)

echo "== Building background service"
"$CLANG" "${CFLAGS[@]}" -I"$B/include" -idirafter "$XNU/bsd" -idirafter "$XNU/libkern" \
    -c src/daemon/pfnat.c -o "$B/pfnat.o"
"$CLANG" "${CFLAGS[@]}" -fobjc-arc -idirafter "$XNU/bsd" -c src/daemon/main.m -o "$B/daemon_main.o"
"$CLANG" "${CFLAGS[@]}" "${LDFLAGS[@]}" "$B/pfnat.o" "$B/daemon_main.o" \
    -framework Foundation -o "$B/wifitetherd"

echo "== Building VPN sharing helper (src/vpn, based on pftun)"
# It needs a few private headers the iPhone SDK leaves out; take them from XNU.
# sys/event.h must win over the SDK's public copy, so it goes in an -I folder.
mkdir -p "$B/include/vpn/sys"
cp "$XNU/bsd/sys/event.h" "$B/include/vpn/sys/event.h"
"$CLANG" -target arm64-apple-ios15.0 -isysroot "$SDK" -Os -I"$B/include/vpn" \
    -idirafter "$XNU/bsd" -idirafter "$XNU/libkern" -idirafter "$XNU/osfmk" \
    -DPRIVATE -D__APPLE_API_PRIVATE -Wno-everything "${LDFLAGS[@]}" \
    src/vpn/pftun.c -o "$B/wifitether-vpn"

echo "== Building app"
"$CLANG" "${CFLAGS[@]}" -fobjc-arc -c src/app/main.m -o "$B/app_main.o"
"$CLANG" "${CFLAGS[@]}" "${LDFLAGS[@]}" "$B/app_main.o" \
    -framework UIKit -framework Foundation -o "$B/WiFiTether"

echo "== Packaging"
S="$B/stage"
APP="$S/var/jb/Applications/WiFiTether.app"
mkdir -p "$S/DEBIAN" "$APP" "$S/var/jb/usr/libexec" "$S/var/jb/Library/LaunchDaemons"

cp "$B/WiFiTether" "$APP/WiFiTether"
sed "s/@VERSION@/$VERSION/g" src/app/Info.plist > "$APP/Info.plist"
cp src/app/icons/AppIcon*.png "$APP/"
chmod 644 "$APP"/AppIcon*.png
cp "$B/wifitetherd" "$S/var/jb/usr/libexec/wifitetherd"
cp packaging/com.wifitether.daemon.plist "$S/var/jb/Library/LaunchDaemons/"
cp "$B/wifitether-vpn" "$S/var/jb/usr/libexec/wifitether-vpn"
cp src/vpn/pftun-vpnid "$S/var/jb/usr/libexec/wifitether-vpnid"
cp packaging/com.wifitether.vpn.plist "$S/var/jb/Library/LaunchDaemons/"
mkdir -p "$S/var/jb/usr/share/doc/com.wifitether"
cp src/vpn/LICENSE "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.pftun"
cp src/daemon/LICENSE.AutoHotspot "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.AutoHotspot"

ldid -Ssrc/app/entitlements.plist "$APP/WiFiTether"
ldid -Ssrc/daemon/entitlements.plist "$S/var/jb/usr/libexec/wifitetherd"
ldid -Ssrc/daemon/entitlements.plist "$S/var/jb/usr/libexec/wifitether-vpn"

sed "s/@VERSION@/$VERSION/g" packaging/control > "$S/DEBIAN/control"
cp packaging/postinst packaging/prerm "$S/DEBIAN/"

chmod 755 "$S/DEBIAN/postinst" "$S/DEBIAN/prerm" "$APP/WiFiTether" "$S/var/jb/usr/libexec/wifitetherd" \
    "$S/var/jb/usr/libexec/wifitether-vpn" "$S/var/jb/usr/libexec/wifitether-vpnid"
chmod 644 "$S/var/jb/Library/LaunchDaemons/"*.plist "$APP/Info.plist" "$S/DEBIAN/control" \
    "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.pftun" "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.AutoHotspot"

OUT="$B/com.wifitether_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip -b "$S" "$OUT"
echo "== Built $OUT"
