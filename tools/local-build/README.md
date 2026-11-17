# Local builds on Linux arm64

These scripts build the iOS bundle's VM files and the Scion APK on a Linux arm64 machine. They do the same steps as the CI workflows (`ios-bundle.yml`, `apk-gfx.yml`) and reuse earlier work on later runs, so a second build only redoes what changed.

Each script takes a checkout and only reads it. Its git-visible files are copied with rsync, keeping mtimes, into `$SCION_BUILD_ROOT/work/<slug>`, and the build runs there. Results go to `$SCION_BUILD_ROOT/out/<slug>`. The slug is the checkout's absolute path with `/` turned into `-` (so `/src/scion-kernel` becomes `src-scion-kernel`).

`SCION_BUILD_ROOT` defaults to `~/.cache/scion-build`. `JOBS` defaults to `nproc`.

## Scripts

| Script | Input | Builds |
| --- | --- | --- |
| `build-kernel.sh` | scion-kernel checkout | XNU guest kernel and `vm/payload.bin` |
| `build-userland.sh` | scion-kernel checkout | `root.apfs`, `vm/system.apfs`, the iPhone identity for avfboot |
| `build-avfboot.sh` | scion-kernel checkout | `vm/Image` (avfboot) |
| `build-vk.sh` | scion-kernel checkout | `vk/libhakios.vk.dylib` and `vk_test`, the guest Vulkan library |
| `build-vm.sh` | scion-kernel checkout | the whole `vm/` folder, by running the scripts above |
| `build-gfxstream.sh` | scion-kernel checkout, optional gfxstream tree | `libgfxstream_backend.so`, the host renderer |
| `build-apk.sh` | scion checkout, optional `GFX` | `app-debug.apk` |
| `../install-apk.sh` | an APK | installs it and keeps the VM files on the device |

`lib.sh`, `kernel-prep.sh` and `sysimage-prep.sh` are sourced by the others. Each script's header lists its inputs, environment variables and outputs.

`build-apk.sh` needs a renderer. Pass `GFX` as a `.so`, as a scion-kernel checkout, or as `none`. If you leave it out, it builds one from `$KERNEL_CHECKOUT`.

## Prerequisites

Packages (Debian/Ubuntu, as installed on the machine these were measured on): `build-essential clang lld llvm cmake ninja-build meson pkg-config bison flex python3 python3-venv git rsync curl unzip openjdk-21-jdk-headless qemu-user` (`qemu-user` provides `qemu-x86_64`).

Put these under `$SCION_BUILD_ROOT` yourself. The scripts don't download them:

- `theos/`: [theos](https://theos.dev) with the L1ghtmann iOSToolchain for aarch64 Linux and `sdks/iPhoneOS16.5.sdk`.
- `ndk/android-ndk-r28/`: an Android NDK r28 built for linux-arm64 (for example HomuHomu833/android-ndk-custom). Google ships only x86_64 host builds.
- `sdk/`: Android SDK platform 36 and build-tools 36.0.0, with `sdk/ndk/28.2.13676358` linking to the NDK above.
- `aapt2/`: Google's x86_64 `aapt2` with the glibc it needs in `aapt2/x86root/`, run through `qemu-x86_64`.
- `hostbin/python`: a link to `python3`. XNU's lldbmacros step calls it by that name.

The scripts download the iOS 16.5.1 IPSW (20F66, iPhone10,3) into `dl/` on first use and check its size and SHA-1. They also fetch the xnu fork, the xnu-deps sources and gfxstream into `cache/`. None of these files go into git.

## Typical times

Measured on an 18-core arm64 VM. Cold means empty `work/` and `out/` for that checkout with `cache/` filled. Incremental means a rerun after a small source change.

| Build | Cold | Incremental |
| --- | --- | --- |
| kernel + payload | 100 s | ~10 s |
| userland | 240–690 s | 16–27 s |
| gfxstream | 189 s | 1–17 s |
| APK | 360 s | 5–110 s |
| avfboot | ~2 s | ~2 s (always rebuilt) |

## Installing the APK

```sh
tools/install-apk.sh -s 192.168.1.20:5555 -b path/to/scion-ios-bundle app-debug.apk
```

The script re-signs every APK with one debug key, `~/.config/scion/debug.keystore` by default (use `-k` or `SCION_KEYSTORE` to change it). It creates the key on first use. Because the signature stays the same, `adb install -r` keeps the 2.5 GB of VM files in the app's data. If the installed app has another signature, the script uninstalls it, installs the new APK and pushes the VM files again with the bundle's `install.sh`, which needs `-b`. The serial comes from `-s` or `ANDROID_SERIAL`. `APKSIGNER` overrides the `apksigner` command.
