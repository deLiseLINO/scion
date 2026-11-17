#!/bin/bash
# build-gfxstream.sh KERNEL_CHECKOUT [GFXSTREAM_TREE]: libgfxstream_backend.so, gfxstream's host renderer for Android
# arm64, the way scion-kernel's tools/gfxstream/mk-host-android.sh makes it (apk-gfx.yml, native/fetch-gfxstream.sh).
#
#   KERNEL_CHECKOUT  gives the gfxstream commit (mk-host-android.sh's COMMIT) and tools/gfxstream/android-host.patch
#   GFXSTREAM_TREE   optional: a gfxstream checkout of your own, already patched (e.g. /tmp/ios-gpu/gfx); it is
#                    mirrored and built as it is, and nothing is applied to it
#   -> $SCION_BUILD_ROOT/out/<slug>/libgfxstream_backend.so   (<slug> of GFXSTREAM_TREE if given, else of KERNEL_CHECKOUT)
#
# Without GFXSTREAM_TREE the source is the commit, patched, in $SCION_BUILD_ROOT/cache/gfxstream-<commit>-<patch hash>.
# Built with the NDK r28 for linux-arm64 ($SCION_BUILD_ROOT/ndk), CMake + Ninja; incremental (the build tree is kept).
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-gfxstream.sh KERNEL_CHECKOUT [GFXSTREAM_TREE]"
K=$(realpath "$1")
[ -f "$K/tools/gfxstream/mk-host-android.sh" ] || die "$K has no tools/gfxstream/mk-host-android.sh"
T0=$(date +%s)
if [ -n "${2:-}" ]; then
	G=$(realpath "$2"); S=$(slug "$G"); W=$IB/work/$S
	sync_src "$G" "$W/src"
	SRC=$W/src
else
	S=$(slug "$K"); W=$IB/work/$S/gfxstream
	COMMIT=${GFXSTREAM_COMMIT:-$(sed -n 's/^COMMIT=\${GFXSTREAM_COMMIT:-\([0-9a-f]*\)}.*/\1/p' "$K/tools/gfxstream/mk-host-android.sh")}
	[ -n "$COMMIT" ] || die "no COMMIT= in $K/tools/gfxstream/mk-host-android.sh"
	PATCHED=$(git hash-object "$K/tools/gfxstream/android-host.patch")
	SRC=$IB/cache/gfxstream-${COMMIT:0:12}-${PATCHED:0:12}
	if [ ! -f "$SRC/.ib-ready" ]; then
		M=$IB/cache/gfxstream.git
		[ -d "$M" ] || git init -q --bare "$M"
		git -C "$M" cat-file -e "$COMMIT^{commit}" 2>/dev/null ||
			timed "fetch gfxstream $COMMIT" git -C "$M" fetch -q --depth 1 https://github.com/google/gfxstream.git "$COMMIT"
		rm -rf "$SRC" && mkdir -p "$SRC"
		git -C "$M" archive "$COMMIT" | tar -x -C "$SRC"
		(cd "$SRC" && git apply "$K/tools/gfxstream/android-host.patch") || die "android-host.patch does not apply"
		touch "$SRC/.ib-ready"
	fi
fi
O=$IB/out/$S
mkdir -p "$O" "$W"
B=$W/build
[ -f "$B/build.ninja" ] || timed "cmake configure" cmake -S "$SRC" -B "$B" -G Ninja -Wno-dev \
	-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=arm64-v8a \
	-DANDROID_PLATFORM=android-34 -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
	-DBUILD_STANDALONE=ON -DDEPENDENCY_RESOLUTION=SYSTEM -DENABLE_VKCEREAL_TESTS=OFF > "$W/cmake.log" 2>&1 ||
	{ tail -30 "$W/cmake.log"; rm -f "$B/build.ninja"; die "cmake failed: $W/cmake.log"; }
timed "ninja gfxstream_backend" ninja -C "$B" -j"$JOBS" gfxstream_backend > "$W/ninja.log" 2>&1 ||
	{ grep -B2 -A12 -m3 'error' "$W/ninja.log" | head -60; die "gfxstream build failed: $W/ninja.log"; }
"$NDK/toolchains/llvm/prebuilt/linux-arm64/bin/llvm-strip" -o "$O/libgfxstream_backend.so" "$B/libgfxstream_backend.so"
log "build-gfxstream.sh: done in $(( $(date +%s) - T0 )) s: $O/libgfxstream_backend.so ($(stat -c %s "$O/libgfxstream_backend.so") bytes)"
