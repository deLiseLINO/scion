#!/usr/bin/env bash
# install-apk.sh [-s SERIAL] [-k KEYSTORE] [-b BUNDLE_DIR] APK: install a Scion APK without losing the iOS VM files
# (files/ios165, 2.5 GB).
#   -s SERIAL      adb device (default: $ANDROID_SERIAL, else adb's single device)
#   -k KEYSTORE    debug keystore, alias scion, password android (default: $SCION_KEYSTORE or
#                  ~/.config/scion/debug.keystore; created on first use)
#   -b BUNDLE_DIR  an unpacked scion-ios-bundle; only needed when the installed app was signed with another key
#   APKSIGNER      apksigner command (default: apksigner on PATH)
# Every APK is re-signed with the same key, so `adb install -r` keeps the app data. If the installed app has
# another signature it is uninstalled, the APK installed, and the VM files pushed again with BUNDLE_DIR/install.sh.
set -euo pipefail
KS=${SCION_KEYSTORE:-$HOME/.config/scion/debug.keystore}
BUNDLE=
while getopts s:k:b: o; do
	case $o in
	s) export ANDROID_SERIAL=$OPTARG ;;
	k) KS=$OPTARG ;;
	b) BUNDLE=$OPTARG ;;
	*) sed -n '2,8p' "$0" >&2; exit 2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || { sed -n '2,8p' "$0" >&2; exit 2; }
PKG=io.github.dylanneve1.iosonpixel
if [ ! -f "$KS" ]; then
	mkdir -p "$(dirname "$KS")"
	keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias scion \
		-keyalg RSA -keysize 2048 -validity 10000 -dname CN=scion-debug
fi
SIGNED=$(mktemp --suffix=.apk)
trap 'rm -f "$SIGNED"' EXIT
${APKSIGNER:-apksigner} sign --ks "$KS" --ks-pass pass:android --ks-key-alias scion --key-pass pass:android \
	--out "$SIGNED" "$1"
adb shell am force-stop $PKG
if ! out=$(adb install -r "$SIGNED" 2>&1); then
	case "$out" in
	*UPDATE_INCOMPATIBLE*|*signatures*do*not*match*)
		[ -n "$BUNDLE" ] || { echo "installed app has another signature; rerun with -b BUNDLE_DIR" >&2; exit 1; }
		echo "== other key installed: reinstalling and pushing the VM files again from $BUNDLE (~2 min)"
		adb uninstall $PKG
		adb install "$SIGNED"
		adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS
		(cd "$BUNDLE" && ./install.sh ${ANDROID_SERIAL:+"$ANDROID_SERIAL"})
		;;
	*) echo "$out" >&2; exit 1 ;;
	esac
fi
adb shell pm grant $PKG android.permission.MANAGE_VIRTUAL_MACHINE
adb shell pm grant $PKG android.permission.USE_CUSTOM_VIRTUAL_MACHINE
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS
adb shell pm grant $PKG android.permission.CAMERA || true
E='Landroid/system/virtualmachine/VirtualMachineCustomImageConfig,Landroid/system/virtualmachine/VirtualMachineConfig\$Builder;->setCustomImageConfig(,Landroid/system/virtualmachine/VirtualizationService;,Landroid/system/virtualizationservice/,Landroid/system/virtualmachine/VirtualMachineManager;->isFeatureEnabled('
adb shell settings put global hidden_api_blacklist_exemptions "\"$E\""
echo "installed; VM files:"; adb shell "run-as $PKG ls -la files/ios165"
