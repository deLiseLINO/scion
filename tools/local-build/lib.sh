# Shared helpers for tools/local-build/*.sh (sourced, not run).
# Layout under $IB ($SCION_BUILD_ROOT, default ~/.cache/scion-build; see README.md):
#   theos/            iOS toolchain (L1ghtmann iOSToolchain-aarch64) + iPhoneOS16.5.sdk (theos/sdks)
#   ndk/android-ndk-r28   Android NDK r28 for linux-arm64 (HomuHomu833/android-ndk-custom)
#   sdk/              Android SDK (platform 36, build-tools 36.0.0) + sdk/ndk/28.2.13676358 -> the r28 above
#   aapt2/            Google's x86_64 aapt2 run through qemu-x86_64 (x86root/ is its glibc)
#   dl/               IPSW and other downloads
#   cache/            shared, read-mostly: sysimage (unpacked IPSW), xnu-deps sources, xnu fork, gfxstream, inferno, deps sysroot
#   work/<slug>/      one mirror per source checkout (rsync of the checkout's git-visible files; builds happen here)
#   out/<slug>/       results
set -euo pipefail
SCION_BUILD_ROOT=${SCION_BUILD_ROOT:-$HOME/.cache/scion-build}
IB=$SCION_BUILD_ROOT
export THEOS=$IB/theos
NDK=$IB/ndk/android-ndk-r28
JOBS=${JOBS:-$(nproc)}
# hostbin/: `python` (-> python3), which XNU's lldbmacros install step calls by that name
export PATH=$IB/hostbin:$PATH
# fd 3: the script's own stderr, for timings of steps whose output goes to a log
exec 3>&2

log() { printf '[%s] %s\n' "$(date +%T)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

# slug PATH: a directory name for a checkout path (/tmp/ios-net/scion-kernel -> tmp-ios-net-scion-kernel)
slug() { realpath "$1" | sed 's|^/||; s|/|-|g'; }

# git_files SRC: the files git shows in SRC (tracked + untracked, not ignored), submodules included, one per line
git_files() {
	local src=$1
	git -C "$src" ls-files -co --exclude-standard | while IFS= read -r f; do
		[ -d "$src/$f" ] && [ ! -L "$src/$f" ] || printf '%s\n' "$f"   # a submodule's gitlink: listed below
	done
	git -C "$src" submodule foreach --quiet --recursive \
		'git ls-files -co --exclude-standard | sed "s|^|$displaypath/|"' 2>/dev/null || true
}

# sync_src SRC DEST: DEST gets SRC's files (mtimes kept, so make/ninja see only real changes); files gone from SRC
# since the last sync are removed from DEST. Nothing else in DEST (build output) is touched. SRC is only read.
sync_src() {
	local src dest=$2 list
	src=$(realpath "$1")
	mkdir -p "$dest"
	list=$dest/.ib-files
	if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
		[ "$(git -C "$src" rev-parse --show-toplevel)" = "$src" ]; then
		git_files "$src" | LC_ALL=C sort -u > "$list.new"
		rsync -a --ignore-missing-args --files-from="$list.new" "$src/" "$dest/"
		git -C "$src" rev-parse HEAD > "$dest/.ib-head"
	else
		find "$src" -type f -printf '%P\n' | LC_ALL=C sort -u > "$list.new"
		rsync -a "$src/" "$dest/"
	fi
	if [ -f "$list" ]; then
		LC_ALL=C comm -23 "$list" "$list.new" | while IFS= read -r f; do rm -f "$dest/$f"; done
	fi
	mv "$list.new" "$list"
	printf '%s\n' "$src" > "$dest/.ib-src"
}

# timed NAME CMD...: run CMD, log its wall time
timed() {
	local name=$1 t0 rc=0; shift
	t0=$(date +%s)
	"$@" || rc=$?
	log "$name: $(( $(date +%s) - t0 )) s (exit $rc)" 2>&3
	return $rc
}
