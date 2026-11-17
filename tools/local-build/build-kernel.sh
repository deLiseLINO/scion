#!/bin/bash
# build-kernel.sh KERNEL_CHECKOUT: the AVF guest kernel and payload.bin, as ios-bundle.yml's bundle job makes them.
#
#   KERNEL_CHECKOUT  a scion-kernel clone (only read: its git-visible files are mirrored into
#                    $SCION_BUILD_ROOT/work/<slug>, where xnu/apply.sh, xnu-deps/setup.sh and `make kernel` run)
#   -> $SCION_BUILD_ROOT/out/<slug>/vm/payload.bin   (kernel + userland/root.apfs, xnuloader/mkpayload.py)
#      $SCION_BUILD_ROOT/out/<slug>/kernel           (mach.development.bcm2837)
#
# Incremental: the XNU build tree stays in the mirror; an edited driver under drivers/ is copied into the tree by
# tools/make-kernel.sh (xnu/sync-drivers.sh) and only what depends on it is rebuilt.
# root.apfs comes from build-userland.sh of the same checkout (run here first when it is missing).
# env: JOBS (default nproc), NO_PAYLOAD=1 (kernel only), ROOT_APFS=FILE (the payload's ramdisk instead of this
#      checkout's userland/root.apfs, e.g. $SCION_BUILD_ROOT/out/tmp-scion-kernel/root.apfs, the CI bundle's userland)
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-kernel.sh KERNEL_CHECKOUT"
K=$(realpath "$1"); S=$(slug "$K"); W=$IB/work/$S; O=$IB/out/$S
[ -f "$K/xnu/apply.sh" ] || die "$K is not a scion-kernel checkout"
T0=$(date +%s)
mkdir -p "$O/vm" "$IB/logs"
sync_src "$K" "$W"
cd "$W"
. "$HERE/kernel-prep.sh"
log "kernel: make kernel JOBS=$JOBS (log $W/kernel.log)"
make kernel JOBS="$JOBS" > "$W/kernel.log" 2>&1 || { tail -60 "$W/kernel.log"; die "kernel build failed: $W/kernel.log"; }
KERNEL=$W/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
[ -f "$KERNEL" ] || die "no kernel at $KERNEL"
cp -p "$KERNEL" "$O/kernel"
if [ -z "${NO_PAYLOAD:-}" ]; then
	ROOT_APFS=${ROOT_APFS:-$W/userland/root.apfs}
	[ -f "$ROOT_APFS" ] || { log "kernel: no userland/root.apfs yet: build-userland.sh first"; "$HERE/build-userland.sh" "$K"; }
	python3 xnuloader/mkpayload.py -o "$O/vm/payload.bin" kernel="$KERNEL" ramdisk="$ROOT_APFS" > /dev/null
	ls -l "$O/vm/payload.bin" >&2
fi
log "build-kernel.sh: done in $(( $(date +%s) - T0 )) s: $O/kernel$([ -n "${NO_PAYLOAD:-}" ] || echo ", $O/vm/payload.bin")"
