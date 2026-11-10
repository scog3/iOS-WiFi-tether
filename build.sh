#!/bin/bash
# Builds the rootless .deb. Runs on macOS with Xcode, ldid and dpkg
# (the GitHub Actions workflow sets all of that up).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
B=build
rm -rf "$B"
mkdir -p "$B/include/xnu" "$B/include/libkern"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MACSDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
CFLAGS=(-isysroot "$SDK" -arch arm64 -miphoneos-version-min=15.0 -Os -Wall -Wno-unused-parameter)

echo "== Fetching Apple's pf header from XNU"
got=""
for tag in xnu-8020.240.18 xnu-8020.140.41 xnu-8020.121.3 xnu-8019.80.24; do
    base="https://raw.githubusercontent.com/apple-oss-distributions/xnu/$tag"
    if curl -fsSL "$base/bsd/net/pfvar.h" -o "$B/include/xnu/pfvar.h" &&
       curl -fsSL "$base/libkern/libkern/tree.h" -o "$B/include/libkern/tree.h"; then
        got="$tag"
        break
    fi
done
[ -n "$got" ] || { echo "Couldn't download pfvar.h from Apple's XNU sources"; exit 1; }
echo "Using $got"

echo "== Building background service"
"$CLANG" "${CFLAGS[@]}" -I"$B/include" -idirafter "$MACSDK/usr/include" \
    -c src/daemon/pfnat.c -o "$B/pfnat.o"
"$CLANG" "${CFLAGS[@]}" -fobjc-arc -c src/daemon/main.m -o "$B/daemon_main.o"
"$CLANG" "${CFLAGS[@]}" "$B/pfnat.o" "$B/daemon_main.o" -framework Foundation -o "$B/wifitetherd"

echo "== Building app"
"$CLANG" "${CFLAGS[@]}" -fobjc-arc src/app/main.m -framework UIKit -framework Foundation -o "$B/WiFiTether"

echo "== Packaging"
S="$B/stage"
APP="$S/var/jb/Applications/WiFiTether.app"
mkdir -p "$S/DEBIAN" "$APP" "$S/var/jb/usr/libexec" "$S/var/jb/Library/LaunchDaemons"

cp "$B/WiFiTether" "$APP/WiFiTether"
sed "s/@VERSION@/$VERSION/g" src/app/Info.plist > "$APP/Info.plist"
cp "$B/wifitetherd" "$S/var/jb/usr/libexec/wifitetherd"
cp packaging/com.wifitether.daemon.plist "$S/var/jb/Library/LaunchDaemons/"

ldid -Ssrc/app/entitlements.plist "$APP/WiFiTether"
ldid -Ssrc/daemon/entitlements.plist "$S/var/jb/usr/libexec/wifitetherd"

sed "s/@VERSION@/$VERSION/g" packaging/control > "$S/DEBIAN/control"
cp packaging/postinst packaging/prerm "$S/DEBIAN/"

chmod 755 "$S/DEBIAN/postinst" "$S/DEBIAN/prerm" "$APP/WiFiTether" "$S/var/jb/usr/libexec/wifitetherd"
chmod 644 "$S/var/jb/Library/LaunchDaemons/com.wifitether.daemon.plist" "$APP/Info.plist" "$S/DEBIAN/control"

OUT="$B/com.wifitether_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip -b "$S" "$OUT"
echo "== Built $OUT"
