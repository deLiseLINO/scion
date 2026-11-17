# sysimage-prep.sh: sourced in a kernel mirror ($W) after kernel-prep.sh. Gives sysimage/ the unpacked IPSW:
# hard links to $IB/cache/sysimage (made once from $IB/dl/ios.ipsw by the mirror's own sysimage/unpack.sh).
IPSW=$IB/dl/ios.ipsw
IPSW_SIZE=6165698198
C=$IB/cache/sysimage
ensure_ipsw() {
	[ -f "$IPSW.ok" ] && return 0
	if [ ! -f "$IPSW" ] || [ "$(stat -c %s "$IPSW")" != $IPSW_SIZE ]; then
		curl -s --fail https://api.ipsw.me/v4/ipsw/iPhone10,3/20F66 > "$IB/dl/ipsw.json"
		timed "download IPSW" curl -L --fail --retry 5 -s -C - -o "$IPSW" \
			"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["url"])' "$IB/dl/ipsw.json")"
	fi
	[ "$(stat -c %s "$IPSW")" = $IPSW_SIZE ] || die "the IPSW is $(stat -c %s "$IPSW") bytes, not $IPSW_SIZE"
	local want got
	want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sha1sum",""))' "$IB/dl/ipsw.json")
	got=$(sha1sum "$IPSW" | cut -d' ' -f1)
	[ -z "$want" ] || [ "$got" = "$want" ] || die "the IPSW's sha1 is $got, not $want"
	touch "$IPSW.ok"
}
link_sysimage() { # FROM TO: what userland/build.sh and mkidentity.sh read, as tools/new-workspace.sh shares it
	local d f
	for d in rootfs cryptex cryptex-app bt-hal "20F66__iPhone10,3_6"; do
		[ -e "$1/$d" ] && { rm -rf "${2:?}/$d"; cp -al "$1/$d" "$2/"; }
	done
	for f in system.files system.manifest var.skel rootfs.slt DeviceTree.d22ap.im4p cryptex-app.dmg \
		.done-rootfs .done-cryptex .done-cryptex-app .done-bthal; do
		[ -e "$1/$f" ] && cp -a "$1/$f" "$2/"
	done
	return 0
}
if [ ! -f sysimage/.done-cryptex-app ] || ! cmp -s sysimage/select-system.py "$C/select-system.py"; then
	if [ -f "$C/.done-cryptex-app" ] && cmp -s sysimage/select-system.py "$C/select-system.py"; then
		link_sysimage "$C" sysimage
		touch sysimage/.done-rootfs   # newer than the mirror's select-system.py (rsync kept the checkout's mtime)
	else
		ensure_ipsw
		[ -f "$C/.done-cryptex-app" ] || rm -f sysimage/.done-rootfs
		[ -f "$C/.done-cryptex-app" ] && ! cmp -s sysimage/select-system.py "$C/select-system.py" && rm -f sysimage/.done-rootfs
		timed "sysimage/unpack.sh" sysimage/unpack.sh "$IPSW" > "$W/unpack.log" 2>&1 || { tail -30 "$W/unpack.log"; die "unpack.sh failed"; }
		if [ ! -f "$C/.done-cryptex-app" ]; then
			mkdir -p "$C"
			link_sysimage sysimage "$C"
			cp -p sysimage/select-system.py "$C/select-system.py"
		fi
	fi
fi
