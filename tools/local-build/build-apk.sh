#!/bin/bash
# build-apk.sh APP_CHECKOUT [GFX]: the Scion app (app-debug.apk) as apk-gfx.yml makes it: static deps, the QEMU
# cross-build (native/build-android.sh deps, qemu), libgfxstream_backend.so in jniLibs, ./gradlew assembleDebug.
#
#   APP_CHECKOUT  a scion (app) clone; only read, built in $SCION_BUILD_ROOT/work/<slug>
#   GFX           libgfxstream_backend.so to put in the APK: a .so file, or a scion-kernel checkout (built with
#                 build-gfxstream.sh); default: built from $KERNEL_CHECKOUT (a scion-kernel clone, required
#                 then). GFX=none: no renderer (as ios-bundle.yml's APK).
#   -> $SCION_BUILD_ROOT/out/<slug>/app-debug.apk
#
# Linux arm64 tools: NDK r28 linux-arm64 ($SCION_BUILD_ROOT/ndk; Gradle sees it as ndk;28.2.13676358 in
# $SCION_BUILD_ROOT/sdk), system CMake/Ninja for the app's own C (cmake.dir=/usr), and Google's aapt2 run by qemu-x86_64
# (android.aapt2FromMavenOverride). The static deps sysroot is shared by every checkout whose deps recipe is the
# same ($SCION_BUILD_ROOT/cache/sysroot-<hash of build-android.sh's deps functions and native/patches>). QEMU's build tree
# and Gradle's daemon/caches persist, so a second run only rebuilds what changed.
# third_party/inferno: the checkout's own when it is checked out, else $SCION_BUILD_ROOT/cache/inferno-<gitlink commit>.
# env: NO_QEMU=1 (skip the QEMU step: Kotlin/resources-only change; the last QEMU build stays in jniLibs)
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-apk.sh APP_CHECKOUT [GFX.so | KERNEL_CHECKOUT | none]"
A=$(realpath "$1"); S=$(slug "$A"); W=$IB/work/$S; O=$IB/out/$S
[ -x "$A/native/build-android.sh" ] && [ -f "$A/app/build.gradle.kts" ] || die "$A is not a scion app checkout"
T0=$(date +%s)
mkdir -p "$O"
sync_src "$A" "$W"
cd "$W"

export ANDROID_NDK_HOME=$NDK ANDROID_HOME=$IB/sdk ANDROID_SDK_ROOT=$IB/sdk GRADLE_USER_HOME=$IB/gradle-home
export JOBS
printf 'sdk.dir=%s\ncmake.dir=/usr\n' "$IB/sdk" > local.properties

# QEMU's source
if [ ! -f third_party/inferno/meson.build ]; then
	SUB=$(git -C "$A" ls-tree HEAD third_party/inferno | awk '{print $3}')
	[ -n "$SUB" ] || die "no third_party/inferno gitlink in $A"
	export INFERNO_SRC=$IB/cache/inferno-${SUB:0:12}
	if [ ! -f "$INFERNO_SRC/meson.build" ]; then
		URL=$(git -C "$A" config -f .gitmodules submodule.third_party/inferno.url)
		rm -rf "$INFERNO_SRC" && git init -q "$INFERNO_SRC" && git -C "$INFERNO_SRC" remote add origin "$URL"
		timed "fetch inferno ${SUB:0:12}" git -C "$INFERNO_SRC" fetch -q --depth 1 origin "$SUB"
		git -C "$INFERNO_SRC" checkout -q FETCH_HEAD
		git -C "$INFERNO_SRC" submodule update -q --init --recursive --depth 1
	fi
fi

# the static deps, shared by recipe
KEY=$( { awk '/^build_gmp\(\)/,/^build_deps\(\)/' native/build-android.sh; grep -E '^(TUNE_CFLAGS|OPT_CFLAGS|API)=' native/build-android.sh;
	cat native/patches/* 2>/dev/null; cat "$NDK/source.properties"; } | sha256sum | cut -c1-16)
SYSROOT=$IB/cache/sysroot-$KEY
mkdir -p native/build "$IB/cache/native-dl" "$SYSROOT"
[ "$(readlink native/build/sysroot 2>/dev/null)" = "$SYSROOT" ] || { rm -rf native/build/sysroot; ln -s "$SYSROOT" native/build/sysroot; }
[ -L native/build/dl ] || { rm -rf native/build/dl; ln -s "$IB/cache/native-dl" native/build/dl; }
(
	flock 9
	if [ ! -f "$SYSROOT/.ib-ready" ]; then
		find "$SYSROOT" -mindepth 1 -delete
		timed "native deps" native/build-android.sh deps > "$W/deps.log" 2>&1 || { tail -40 "$W/deps.log"; die "deps failed: $W/deps.log"; }
		touch "$SYSROOT/.ib-ready"
	fi
) 9> "$SYSROOT.lock"

if [ -z "${NO_QEMU:-}" ]; then
	timed "native qemu" native/build-android.sh qemu > "$W/qemu.log" 2>&1 || { tail -40 "$W/qemu.log"; die "qemu failed: $W/qemu.log"; }
fi

# the GPU renderer
GFX=${2:-${GFX:-}}
mkdir -p app/src/main/jniLibs/arm64-v8a
if [ "$GFX" = none ]; then
	rm -f app/src/main/jniLibs/arm64-v8a/libgfxstream_backend.so
else
	if [ -z "$GFX" ]; then
		[ -n "${KERNEL_CHECKOUT:-}" ] || die "give GFX (a .so, a scion-kernel checkout or none) or set KERNEL_CHECKOUT"
		"$HERE/build-gfxstream.sh" "$KERNEL_CHECKOUT"
		GFX=$IB/out/$(slug "$KERNEL_CHECKOUT")/libgfxstream_backend.so
	elif [ -d "$GFX" ]; then
		"$HERE/build-gfxstream.sh" "$GFX"
		GFX=$IB/out/$(slug "$GFX")/libgfxstream_backend.so
	fi
	[ -f "$GFX" ] || die "no $GFX"
	cp -p "$GFX" app/src/main/jniLibs/arm64-v8a/libgfxstream_backend.so
fi

timed "gradle assembleDebug" ./gradlew -q assembleDebug -Pandroid.aapt2FromMavenOverride="$IB/aapt2/bin/aapt2" \
	> "$W/gradle.log" 2>&1 || { tail -40 "$W/gradle.log"; die "gradle failed: $W/gradle.log"; }
cp -p app/build/outputs/apk/debug/app-debug.apk "$O/app-debug.apk"
unzip -l "$O/app-debug.apk" 'lib/arm64-v8a/*' | sed -n '4,$p' | grep -v -- '---' >&2 || true
log "build-apk.sh: done in $(( $(date +%s) - T0 )) s: $O/app-debug.apk ($(stat -c %s "$O/app-debug.apk") bytes)"
