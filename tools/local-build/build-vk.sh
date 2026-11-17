#!/bin/bash
# build-vk.sh KERNEL_CHECKOUT: the guest's Vulkan library for iOS (libhakios.vk.dylib + vk_test), what CI's apk job
# makes on macOS with `tools/gfxstream/mk-vk.sh ios` and uploads as scion-vk-for-bundle -- here on Linux arm64.
#   -> $SCION_BUILD_ROOT/out/<slug>/vk/{libhakios.vk.dylib,vk_test}   (build-userland.sh takes it from there)
#
# mk-vk.sh itself prepares the source (Mesa 25.0.7, patched, vk/scion copied in, a venv with Mako): it is run with
# the word "none", which does that and builds nothing. The ios build is then mk-vk.sh's own, with Linux tools in
# place of Xcode's: Ubuntu's clang (-target arm64-apple-ios16.0, theos' iPhoneOS16.5.sdk, theos' ld64 as the
# linker), theos' cctools ar/ranlib/strip/nm/install_name_tool, and ldid -S for the ad-hoc signature.
# Incremental: the meson build tree (build-ios) is kept; vk/scion is copied in again each run.
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-vk.sh KERNEL_CHECKOUT"
K=$(realpath "$1"); S=$(slug "$K"); W=$IB/work/$S; O=$IB/out/$S
[ -f "$K/tools/gfxstream/mk-vk.sh" ] || die "$K has no tools/gfxstream/mk-vk.sh"
T0=$(date +%s)
sync_src "$K" "$W"
B=$W/vkbuild
mkdir -p "$B" "$O/vk"
VK_BUILD=$B bash "$W/tools/gfxstream/mk-vk.sh" none > "$B/prep.log" 2>&1 || { tail -20 "$B/prep.log"; die "mk-vk.sh source preparation failed"; }
cd "$B"
export PATH=$B/venv/bin:$PATH
TC=$THEOS/toolchain/linux/iphone/bin
SDK=$THEOS/sdks/iPhoneOS16.5.sdk
M=$(ls -d "$B"/mesa-* | grep -v '\.tar' | head -1)
# the options and target of mk-vk.sh (read from it, so a change there is followed)
OPTS=$(sed -n '/^OPTS="/,/"$/p' "$W/tools/gfxstream/mk-vk.sh" | sed 's/^OPTS="//; s/"$//' | tr '\n\t' '  ')
LIBTARGET=$(sed -n 's/^LIBTARGET=//p' "$W/tools/gfxstream/mk-vk.sh")
CLANG="'/usr/bin/clang', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK'"
cat > linux-native.ini <<INI
[binaries]
ar = 'ar'
ranlib = 'ranlib'
INI
cat > linux-cross-ios.ini <<INI
[binaries]
c = [$CLANG]
cpp = ['/usr/bin/clang++', '-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK']
objc = [$CLANG]
ar = '$TC/ar'
ranlib = '$TC/ranlib'
strip = '$TC/strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
# the Mach-O linker (theos' ld64) only where something is linked: on a compile line clang calls it unused, and
# meson's checks run with -Werror=unused-command-line-argument
c_link_args = ['--ld-path=$TC/ld']
cpp_link_args = ['--ld-path=$TC/ld']
objc_link_args = ['--ld-path=$TC/ld']

[properties]
needs_exe_wrapper = true
INI
# a new tree when the cross file or the options changed (or the Mesa tree was unpacked anew by mk-vk.sh)
SETUP_KEY=$( { cat linux-cross-ios.ini; echo "$OPTS"; cat "$M/.scion-patched"; } | sha256sum | cut -c1-16)
[ "$(cat build-ios/.ib-setup 2>/dev/null)" = "$SETUP_KEY" ] || rm -rf build-ios
if [ ! -f build-ios/build.ninja ]; then
	# shellcheck disable=SC2086
	timed "meson setup" meson setup build-ios "$M" --cross-file linux-cross-ios.ini --native-file linux-native.ini \
		--buildtype=release -Db_ndebug=true $OPTS > meson-ios.log 2>&1 || { tail -30 meson-ios.log; rm -rf build-ios; die "meson setup failed: $B/meson-ios.log"; }
	echo "$SETUP_KEY" > build-ios/.ib-setup
fi
timed "ninja $LIBTARGET" ninja -C build-ios -j"$JOBS" "$LIBTARGET" > ninja-ios.log 2>&1 || { grep -m5 -A8 error ninja-ios.log; die "vk build failed: $B/ninja-ios.log"; }
mkdir -p out-ios
"$TC/strip" -x -o out-ios/libhakios.vk.dylib "build-ios/$LIBTARGET"
"$TC/install_name_tool" -id /redwood/lib/libhakios.vk.dylib out-ios/libhakios.vk.dylib
"$TC/ldid" -S out-ios/libhakios.vk.dylib
bad=$("$TC/nm" -m out-ios/libhakios.vk.dylib | grep '(undefined)' | grep 'dynamically looked up' | grep -v ' weak ' || true)
[ -z "$bad" ] || { echo "$bad" >&2; die "libhakios.vk.dylib looks up symbols that will not be there"; }
/usr/bin/clang -target arm64-apple-ios16.0 -isysroot "$SDK" --ld-path="$TC/ld" -O2 -Wall -I"$M/include" -o out-ios/vk_test \
	"$W/userland/src/vk_test.c" out-ios/libhakios.vk.dylib
"$TC/ldid" -S out-ios/vk_test
cp -p out-ios/libhakios.vk.dylib out-ios/vk_test "$O/vk/"
log "build-vk.sh: done in $(( $(date +%s) - T0 )) s: $O/vk/libhakios.vk.dylib ($(stat -c %s "$O/vk/libhakios.vk.dylib") bytes, $("$TC/nm" -gU "$O/vk/libhakios.vk.dylib" | grep -c ' _vk[A-Z]') vk* functions)"
