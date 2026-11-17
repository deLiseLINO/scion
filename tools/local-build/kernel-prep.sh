# kernel-prep.sh: sourced by the build scripts, in a kernel mirror ($W, the current directory), after lib.sh.
# Makes what `make kernel` and userland/build.sh need there, sharing downloads through $IB/cache:
#   xnu-src/xnu-8796.121.2   xnu/apply.sh, the fork fetched from $IB/cache/xnu.git (a local copy of Scion-Project/xnu)
#   xnu-deps/...             xnu-deps/setup.sh, its fetched sources copied from $IB/cache/xnu-deps
# the mirror has no .git: tools/kernel-version.py (kernel.ver in payload.bin) gets the checkout's commit this way
if [ -z "${HAKIOS_VERSION_SUFFIX+x}" ] && [ -f .ib-head ]; then
	HAKIOS_VERSION_SUFFIX=-g$(cut -c1-8 .ib-head)
	[ -z "$(git --no-optional-locks -C "$K" status --porcelain -uno 2>/dev/null)" ] || HAKIOS_VERSION_SUFFIX+=-dirty
	export HAKIOS_VERSION_SUFFIX
fi
DEPS_SRC="AvailabilityVersions libdispatch libpthread mm_bootstrap_cmds tcsh unifdef MacOSX13.3.sdk"
for d in $DEPS_SRC; do
	if [ ! -e "xnu-deps/$d" ] && [ -e "$IB/cache/xnu-deps/$d" ]; then cp -a "$IB/cache/xnu-deps/$d" xnu-deps/; fi
done
# tools/gfxstream/fetch.sh's files (codegen inputs from raw.githubusercontent.com, gl.xml), which userland GL=gfx needs:
# kept once, so that a mirror does not depend on those downloads working (they failed once, silently)
if [ -d "$IB/cache/gfxstream-codegen" ]; then
	mkdir -p xnu-deps/build/gfxstream && cp -a --update=none "$IB/cache/gfxstream-codegen/." xnu-deps/build/gfxstream/
fi
if [ ! -d xnu-src/xnu-8796.121.2 ]; then
	FORK_COMMIT=$(OS_PROFILE_QUIET=1 python3 tools/os-profile.py get fork_commit)
	FORK_URL=$(OS_PROFILE_QUIET=1 python3 tools/os-profile.py get xnu_fork)
	# a full mirror (xnu-tree.py also wants Apple's base commit and the history down to the release tag)
	[ -d "$IB/cache/xnu.git" ] || timed "mirror xnu fork" git clone -q --mirror "$FORK_URL" "$IB/cache/xnu.git"
	git -C "$IB/cache/xnu.git" cat-file -e "$FORK_COMMIT^{commit}" 2>/dev/null ||
		timed "update xnu mirror" git -C "$IB/cache/xnu.git" remote update --prune
	timed "xnu/apply.sh" env XNU_FORK_URL="file://$IB/cache/xnu.git" xnu/apply.sh > "$W/apply.log" 2>&1 ||
		{ tail -30 "$W/apply.log"; die "xnu/apply.sh failed"; }
fi
# what setup.sh builds (host tools, the SDK with libfirehose_kernel.a and libpthread_kext.a, hostinc/) is the same for
# every mirror with the same setup.sh and fork commit: made once, then copied (the paths compiled into migcom and tcsh
# are only their build directories)
READY=$IB/cache/xnu-deps-ready-$( { cat xnu-deps/setup.sh; OS_PROFILE_QUIET=1 python3 tools/os-profile.py get fork_commit; } | sha256sum | cut -c1-12)
deps_ok() { [ -e xnu-deps/host/bin/ld64 ] && [ -f xnu-deps/sdk/iPhoneOS16.5.xnu.sdk/usr/local/lib/kernel/libfirehose_kernel.a ] &&
	[ -f xnu-deps/sdk/iPhoneOS16.5.xnu.sdk/usr/local/lib/kernel/libpthread_kext.a ]; }
if ! deps_ok && [ -f "$READY/.ib-ready" ]; then
	# (no clobber: host/bin's tracked wrappers -- xnu-clang, xcrun, ... -- stay this checkout's own)
	for d in host sdk hostinc; do mkdir -p "xnu-deps/$d"; cp -a --update=none "$READY/$d/." "xnu-deps/$d/"; done
fi
if ! deps_ok; then
	timed "xnu-deps/setup.sh" xnu-deps/setup.sh > "$W/setup.log" 2>&1 ||
		{ tail -30 "$W/setup.log"; for f in xnu-deps/*.log; do echo "== $f"; tail -30 "$f"; done; die "xnu-deps/setup.sh failed"; }
	mkdir -p "$IB/cache/xnu-deps"
	for d in $DEPS_SRC; do
		[ -e "$IB/cache/xnu-deps/$d" ] || cp -a "xnu-deps/$d" "$IB/cache/xnu-deps/"
	done
	if [ ! -f "$READY/.ib-ready" ]; then
		rm -rf "$READY" && mkdir -p "$READY"
		cp -a xnu-deps/host xnu-deps/sdk xnu-deps/hostinc "$READY/" && touch "$READY/.ib-ready"
	fi
fi
