#!/bin/bash
# build-userland.sh KERNEL_CHECKOUT: userland/root.apfs and userland/system.apfs as ios-bundle.yml makes them
# (userland/build.sh GL=gfx REST=1 VK_DIR=...), plus the iPhone identity (xnuloader/identity.h) avfboot needs.
#
#   KERNEL_CHECKOUT  a scion-kernel clone (only read; built in $SCION_BUILD_ROOT/work/<slug>)
#   -> $SCION_BUILD_ROOT/out/<slug>/vm/system.apfs, $SCION_BUILD_ROOT/out/<slug>/root.apfs,
#      and vm/payload.bin again when the kernel of this checkout is built (build-kernel.sh)
#
# iOS's files: the IPSW (20F66, iPhone10,3) is downloaded once to $SCION_BUILD_ROOT/dl/ios.ipsw (checked by size and
# sha1), unpacked once by sysimage/unpack.sh into $SCION_BUILD_ROOT/cache/sysimage, and every mirror's sysimage/ is made of
# hard links to that (as tools/new-workspace.sh does). A checkout whose sysimage/select-system.py differs unpacks its own.
# Incremental: build.sh keeps system.apfs when stage0, the manifest and the cryptexes are older than it; root.apfs is
# always made again (seconds).
# env: VK_DIR (default $SCION_BUILD_ROOT/cache/vk-ci, the CI artifact scion-vk-for-bundle, as in the CI bundle;
#      VK_DIR=$SCION_BUILD_ROOT/out/<slug>/vk for build-vk.sh's Linux build, not yet tried on the phone),
#      GL (default gfx), USERLAND_OPTS (more NAME=VALUE for build.sh)
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-userland.sh KERNEL_CHECKOUT"
K=$(realpath "$1"); S=$(slug "$K"); W=$IB/work/$S; O=$IB/out/$S
[ -f "$K/userland/build.sh" ] || die "$K is not a scion-kernel checkout"
T0=$(date +%s)
mkdir -p "$O/vm"
sync_src "$K" "$W"
cd "$W"
. "$HERE/kernel-prep.sh"
. "$HERE/sysimage-prep.sh"
[ -f xnuloader/identity.h ] && [ xnuloader/identity.h -nt sysimage/DeviceTree.d22ap.im4p ] || xnuloader/mkidentity.sh >&2

VK_DIR=${VK_DIR:-$IB/cache/vk-ci}
[ -f "$VK_DIR/libhakios.vk.dylib" ] || die "no guest Vulkan in $VK_DIR (build-vk.sh, or the CI artifact scion-vk-for-bundle)"
log "userland: GL=${GL:-gfx} REST=1 VK_DIR=$VK_DIR (log $W/userland.log)"
(source ./xnu-env.sh && cd userland && env GL="${GL:-gfx}" REST=1 VK_DIR="$VK_DIR" ${USERLAND_OPTS:-} bash build.sh) > "$W/userland.log" 2>&1 ||
	{ tail -60 "$W/userland.log"; die "userland build failed: $W/userland.log"; }
tail -3 "$W/userland.log" >&2
grep -aq 'guest.s Vulkan' "$W/userland.log" || die "the root has no Vulkan library"
cp -p userland/root.apfs "$O/root.apfs"
rsync -a userland/system.apfs "$O/vm/system.apfs"
cp avf/scion/avf.properties "$O/vm/avf.properties"
KERNEL=$W/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837
if [ -f "$KERNEL" ]; then
	python3 xnuloader/mkpayload.py -o "$O/vm/payload.bin" kernel="$KERNEL" ramdisk="$W/userland/root.apfs" > /dev/null
fi
ls -l "$O/root.apfs" "$O/vm/"* >&2
log "build-userland.sh: done in $(( $(date +%s) - T0 )) s"
