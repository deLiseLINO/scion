#!/bin/bash
# build-avfboot.sh KERNEL_CHECKOUT: avfboot (avf/shim/build.sh) with the iPhone identity, as ios-bundle.yml makes it.
#   -> $SCION_BUILD_ROOT/out/<slug>/vm/Image
# The identity (xnuloader/identity.h, xnuloader/mkidentity.sh) comes from the IPSW's device tree, kept in
# $SCION_BUILD_ROOT/cache/sysimage. Every build is from scratch (5 files, about a second).
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-avfboot.sh KERNEL_CHECKOUT"
K=$(realpath "$1"); S=$(slug "$K"); W=$IB/work/$S; O=$IB/out/$S
[ -f "$K/avf/shim/build.sh" ] || die "$K has no avf/shim/build.sh"
T0=$(date +%s)
mkdir -p "$O/vm"
sync_src "$K" "$W"
cd "$W"
DT=$IB/cache/sysimage/DeviceTree.d22ap.im4p
if [ ! -f xnuloader/identity.h ] || [ xnuloader/mkidentity.py -nt xnuloader/identity.h ]; then
	if [ ! -f "$DT" ]; then
		. "$HERE/sysimage-prep.sh"   # (the whole unpack, once; it leaves the device tree in the cache)
	fi
	xnuloader/mkidentity.sh "$DT" >&2
fi
avf/shim/build.sh >&2
cp -p avf/shim/out/Image "$O/vm/Image"
log "build-avfboot.sh: done in $(( $(date +%s) - T0 )) s: $O/vm/Image ($(stat -c %s "$O/vm/Image") bytes)"
