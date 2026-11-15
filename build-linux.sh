#!/bin/bash
# Builds the rootless .deb on Linux (Ubuntu). Used by the GitHub Actions workflow.
# Needs: clang, lld, ldid, dpkg-deb, git, curl (the workflow installs them).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
# Package version: VERSION, plus a build number on GitHub (0.4.4-37), so every build
# is a new version to Sileo. The app itself shows plain VERSION.
PKGVERSION="${PKG_VERSION:-$VERSION}"
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

echo "== Building hand-over add-on for iOS's Wi-Fi service (src/roam)"
# A12 and newer (arm64e) need an arm64e build, which only Apple's compiler
# makes properly; GitHub's build makes one on a Mac (ROAM_DYLIB, arm64 +
# arm64e). Without it, this builds arm64 only, and A12-and-newer devices
# move bands by disconnecting and rejoining instead.
if [ -n "${ROAM_DYLIB:-}" ] && [ -f "$ROAM_DYLIB" ]; then
    echo "   using $ROAM_DYLIB (arm64 + arm64e, built with Xcode)"
    cp "$ROAM_DYLIB" "$B/WiFiTetherRoam.dylib"
else
    echo "   arm64 only (no ROAM_DYLIB)"
    "$CLANG" "${CFLAGS[@]}" "${LDFLAGS[@]}" -fobjc-arc -dynamiclib \
        -install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/WiFiTetherRoam.dylib \
        src/roam/roam.m -framework Foundation -framework CoreFoundation -o "$B/WiFiTetherRoam.dylib"
fi
# Which processors the add-on is built for (arm64e = A12 and newer), for the
# log and GitHub's run summary (build/roam-archs.txt).
ROAM_ARCHS="$(python3 - "$B/WiFiTetherRoam.dylib" <<'PY' 2>/dev/null || echo unknown
import struct, sys
d = open(sys.argv[1], 'rb').read()
def name(cpu, sub):
    if cpu == 0x100000c:
        return {0: 'arm64', 1: 'arm64v8', 2: 'arm64e'}.get(sub & 0xffffff, 'arm64 (subtype %d)' % (sub & 0xffffff))
    return 'cpu %#x' % cpu
magic = struct.unpack_from('>I', d, 0)[0]
if magic in (0xcafebabe, 0xcafebabf):   # fat: big-endian headers, 20 or 32 bytes each
    size = 20 if magic == 0xcafebabe else 32
    count = struct.unpack_from('>I', d, 4)[0]
    print(' '.join(name(*struct.unpack_from('>II', d, 8 + i * size)) for i in range(count)))
else:
    print(name(*struct.unpack_from('<II', d, 4)))
PY
)"
echo "   hand-over add-on built for: $ROAM_ARCHS"
echo "$ROAM_ARCHS" > "$B/roam-archs.txt"

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
TW="$S/var/jb/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$TW"
cp "$B/WiFiTetherRoam.dylib" src/roam/WiFiTetherRoam.plist "$TW/"
mkdir -p "$S/var/jb/usr/share/doc/com.wifitether"
cp src/vpn/LICENSE "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.pftun"
cp src/daemon/LICENSE.AutoHotspot "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.AutoHotspot"

ldid -Ssrc/app/entitlements.plist "$APP/WiFiTether"
ldid -Ssrc/daemon/entitlements.plist "$S/var/jb/usr/libexec/wifitetherd"
ldid -Ssrc/daemon/entitlements.plist "$S/var/jb/usr/libexec/wifitether-vpn"
ldid -S "$TW/WiFiTetherRoam.dylib"

sed "s/@VERSION@/$PKGVERSION/g" packaging/control > "$S/DEBIAN/control"
cp packaging/postinst packaging/prerm "$S/DEBIAN/"

chmod 755 "$S/DEBIAN/postinst" "$S/DEBIAN/prerm" "$APP/WiFiTether" "$S/var/jb/usr/libexec/wifitetherd" \
    "$S/var/jb/usr/libexec/wifitether-vpn" "$S/var/jb/usr/libexec/wifitether-vpnid" "$TW/WiFiTetherRoam.dylib"
chmod 644 "$S/var/jb/Library/LaunchDaemons/"*.plist "$APP/Info.plist" "$S/DEBIAN/control" \
    "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.pftun" "$S/var/jb/usr/share/doc/com.wifitether/LICENSE.AutoHotspot" \
    "$TW/WiFiTetherRoam.plist"

OUT="$B/com.wifitether_${PKGVERSION}_iphoneos-arm64.deb"
dpkg-deb --root-owner-group -Zgzip -b "$S" "$OUT"
echo "== Built $OUT"
