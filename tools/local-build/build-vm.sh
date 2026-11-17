#!/bin/bash
# build-vm.sh KERNEL_CHECKOUT: the whole vm/ folder of the iOS bundle from one scion-kernel checkout:
#   kernel (build-kernel.sh), root.apfs + system.apfs (build-userland.sh), payload.bin, avfboot Image (build-avfboot.sh),
#   avf.properties (the checkout's avf/scion/avf.properties)
#   -> $SCION_BUILD_ROOT/out/<slug>/vm/{Image,payload.bin,system.apfs,avf.properties}
# Each step is incremental; for a driver change alone build-kernel.sh is enough (it remakes payload.bin).
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
[ $# -ge 1 ] || die "usage: build-vm.sh KERNEL_CHECKOUT"
T0=$(date +%s)
NO_PAYLOAD=1 "$HERE/build-kernel.sh" "$1"
"$HERE/build-userland.sh" "$1"
"$HERE/build-avfboot.sh" "$1"
O=$IB/out/$(slug "$1")
(cd "$O/vm" && ls -l && sha256sum Image payload.bin avf.properties) >&2
log "build-vm.sh: done in $(( $(date +%s) - T0 )) s: $O/vm"
