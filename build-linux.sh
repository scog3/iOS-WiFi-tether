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
if [ ! -d "$T/sdks/.git" ]; then
    rm -rf "$T/sdks"
    git clone --quiet --depth 1 --filter=blob:none --no-checkout https://github.com/theos/sdks.git "$T/sdks"
fi
SDK_NAME="$(git -C "$T/sdks" ls-tree --name-only HEAD | grep -E '^iPhoneOS1[4-9][0-9.]*\.sdk$' | sort -V | tail -1)"
[ -n "$SDK_NAME" ] || { echo "No iPhone SDK found in theos/sdks"; exit 1; }
git -C "$T/sdks" sparse-checkout set --no-cone "/$SDK_NAME/"
git -C "$T/sdks" checkout --quiet
SDK="$T/sdks/$SDK_NAME"
echo "Using $SDK_NAME"

echo "== Getting Apple's XNU headers (for the packet filter)"
XNU=""
for tag in xnu-8020.240.18 xnu-8020.140.41 xnu-8020.121.3 xnu-8019.80.24; do
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
"$CLANG" "${CFLAGS[@]}" -fobjc-arc -c src/daemon/main.m -o "$B/daemon_main.o"
"$CLANG" "${CFLAGS[@]}" "${LDFLAGS[@]}" "$B/pfnat.o" "$B/daemon_main.o" \
    -framework Foundation -o "$B/wifitetherd"

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

ldid -Ssrc/app/entitlements.plist "$APP/WiFiTether"
ldid -Ssrc/daemon/entitlements.plist "$S/var/jb/usr/libexec/wifitetherd"

sed "s/@VERSION@/$VERSION/g" packaging/control > "$S/DEBIAN/control"
cp packaging/postinst packaging/prerm "$S/DEBIAN/"

chmod 755 "$S/DEBIAN/postinst" "$S/DEBIAN/prerm" "$APP/WiFiTether" "$S/var/jb/usr/libexec/wifitetherd"
chmod 644 "$S/var/jb/Library/LaunchDaemons/com.wifitether.daemon.plist" "$APP/Info.plist" "$S/DEBIAN/control"

OUT="$B/com.wifitether_${VERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip -b "$S" "$OUT"
echo "== Built $OUT"
