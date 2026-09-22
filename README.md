# Tesla_OS_On_QEMU

中文说明见 [README.zh-CN.md](README.zh-CN.md)。

Tooling to unpack a Tesla infotainment ECU ("ICE") firmware/eMMC dump,
optionally patch its root filesystem for research, and boot it under QEMU
for offline analysis — built from a full reverse-engineering pass over a
real Model 3 Intel Elkhart Lake ("ICE-MRB") firmware image.

Repository: https://github.com/cn0xroot/Tesla_OS_On_QEMU

> **This repository ships tooling and documentation only.** No firmware
> image, extracted filesystem, key material, packet capture, or log file
> is included or downloaded by anything here — see [What's *not* in this
> repo](#whats-not-in-this-repo) below. You must supply your own firmware
> dump.

## What this is

Tesla's Intel-based infotainment ECU stores its root filesystem as a
squashfs image protected by dm-verity, spread across GPT partitions using
a private `dm-linear` layout that the stock `verity-init` reconstructs at
boot time. Getting a working, inspectable copy of that filesystem — and
being able to boot it in an emulator instead of on real hardware — takes
several non-obvious steps (documented in full, including the debugging
dead-ends, in `docs/firmware_unpacking_reproduction.md` if you keep a
local copy of that analysis).

`scripts/tesla_fw.py` is a single CLI that wraps the whole pipeline:

| Stage | What it does |
|---|---|
| `unpack` | Partition table → extract kernel from the `iasImage` container → reconstruct the `dm-linear`-spliced rootfs → `unsquashfs` it |
| `patch` | Build a minimal dm-verity-bypass `init` + initrd, and repack an edited rootfs directory back into squashfs |
| `run` | Boot the (optionally patched) firmware in QEMU — headless, interactive GUI, GDB-attached, or a full accelerated graphics stack |
| `ssh` / `focus` / `capture` | Day-to-day helpers for a running QEMU guest: SSH in, fix host input focus, capture traffic |

## Requirements

- Linux host, Python 3.8+
- `qemu-system-x86_64`, `qemu-img` (with KVM available for reasonable boot speed)
- `squashfs-tools` (`unsquashfs`, `mksquashfs`)
- `gcc` (to statically build the bypass `init`), `cpio`, `gzip`
- `fdisk`/`sfdisk` (partition inspection/extraction)
- `openssh-client` (for the `ssh`/`capture` helpers)

## Quickstart

```bash
git clone https://github.com/cn0xroot/Tesla_OS_On_QEMU
cd Tesla_OS_On_QEMU

# 1. Unpack a firmware dump you already have (not provided by this repo)
python3 scripts/tesla_fw.py unpack /path/to/tesla_ROM1_*.bin ./extracted both \
    --ias-image ./extracted/boot/bank_a.iasImage --bzimage-len 0x832fa0 \
    --make-overlay

# 2. (optional) Modify extracted/rootfs_reconstructed/squashfs-root-a/...,
#    then repack it and build a verity-bypass boot path:
python3 scripts/tesla_fw.py patch repack \
    extracted/rootfs_reconstructed/squashfs-root-a rootfs_edited.squashfs
python3 scripts/tesla_fw.py patch build-init ./patched_boot

# 3. Boot it
python3 scripts/tesla_fw.py run --mode headless --image /path/to/tesla_ROM1_*.bin --duration 180
python3 scripts/tesla_fw.py run --mode ui --rootfs rootfs_edited.squashfs

# 4. While it's running
python3 scripts/tesla_fw.py ssh
python3 scripts/tesla_fw.py capture eth0 30
```

Every subcommand has its own `--help` with the full option list.

### `unpack` in detail

```
tesla_fw.py unpack <image.bin> <outdir> [a|b|both]
    --ias-image PATH        boot-partition bankX.iasImage (also extracts the kernel)
    --bzimage-len HEX       exact bzImage length read from the device's own bootlog.0
    --skip-unsquashfs       stop after reconstructing the raw image
    --make-overlay          also create a QEMU qcow2 copy-on-write overlay
    --p2-off/--p3-off/--seg1-len/--p4-off/--p4-end-incl
                             override the GPT offsets if your image's
                             partition table differs from the default
```

The reconstruction step matters: on this firmware family, a single GPT
partition is *too small* to hold the full squashfs + dm-verity metadata.
The real root device is a `dm-linear` splice of that partition plus a
1GiB slice borrowed from the tail of the LVM data partition — the exact
offsets are derived from the vendor's own `verity-init` binary. Getting a
truncation/rounding detail in that formula wrong produces a rootfs that
*looks* corrupt (squashfs table pointers point past EOF) when it's really
just misaligned by a few thousand bytes; `tesla_fw.py unpack` reproduces
the corrected formula.

### `patch` in detail

```
tesla_fw.py patch build-init <outdir>          # compiles scripts/custom_init.c,
                                                # packs it as a 1-file initrd
tesla_fw.py patch repack <rootfs_dir> <out.squashfs> [--comp lz4] [--block-size 131072]
tesla_fw.py patch legacy-tables <squashfs>     # deprecated/archival only, see --help
```

The stock rootfs is dm-verity protected: touch a single byte and the
vendor's `verity-init` will refuse to mount it. `patch build-init`
compiles a small replacement PID 1 (`scripts/custom_init.c`) that mirrors
the vendor init's mount/switch-root sequence but skips the RSA signature
check, so any *structurally valid* squashfs — edited or not — can boot.
This does not, and cannot, make edited content pass Tesla's real
signature verification; it's for offline emulator research only.

### `run` in detail

```
tesla_fw.py run --mode headless --image IMG --duration 180 [--gui]
tesla_fw.py run --mode ui       --rootfs squashfs [--kernel ...] [--initrd ...]
tesla_fw.py run --mode gdb      --rootfs squashfs
tesla_fw.py run --mode glamor
```

`--mode` selects between the four QEMU launch profiles already present
under `scripts/` (`run_qemu.sh`, `run_qemu_ui.sh`, `run_qemu_gdb.sh`,
`run_v62_glamor.sh`) — a fixed-duration headless boot, a long-running
interactive GUI session, a session with kernel- and userspace-GDB stubs
attached, and a full accelerated 2D graphics stack respectively. See each
script's header comment for the details of what it configures.

## Device / feature status in QEMU

What actually works once you're booted, and what still doesn't:

| Subsystem | Status | Fix | Reproducible from this repo? |
|---|---|---|---|
| Touch input | Working | Replaced `touch-proxy` (wrong coordinate space) with `x11-input-proxy`, which injects clicks via X11 XTest directly in screen coordinates (v63) | Partially — `scripts/x11-input-proxy.c` is tracked; the rootfs-side wiring that runs it isn't |
| Browser — Apple Music web view (`chromium-app`) | Working (renders, stable) | Forced software rendering (`--disable-gpu --disable-gpu-compositing`) plus sandbox netns/bind-mount fixes; the streaming backend itself is unreachable from an emulator, which isn't a guest bug | No — baked into the rootfs only |
| Browser — built-in in-car Browser | Partially working | Panel opens after a boot-race workaround, but page content renders as a black screen: no GPU acceleration and no swiftshader software-GL fallback compiled in — an open, unresolved hard limit | No — open issue |
| Audio / sound card | Working (host playback) | The OEM kernel ships no PCI/USB sound driver at all; a custom AC97 kernel module plus QEMU `-audiodev pa,...` streams guest audio out to the host's PulseAudio/PipeWire. A prior crash loop was fixed separately by pre-creating `/var/lib/alsa` and `/var/lib/audiod` | Partially — the QEMU-side `-audiodev` wiring is in `run_qemu_ui.sh`/`run_v62_glamor.sh`; the kernel module and rootfs directory fix aren't |
| Network (app connectivity + stable SSH, simultaneously) | Working | v68's dual-NIC design: `eth0` stays under `connman`'s static IP for app connectivity, `eth1` gets its own static IP outside connman's reach for SSH, so neither interferes with the other. A separate earlier fix stops `connman` from picking a factory-only config that drops the whole connection | **Yes** — `tesla_fw.py patch network-fix` (see below) |
| UI rendering (2D) | Working | Pure 2D scanout (`-device virtio-vga`, `gl=on` left off) — the real Tesla UI fully renders and keeps running (Factory Net label, map grid, loading cards, bottom taskbar all visible and animating) | No — QEMU display flags only, no rootfs change needed |
| 3D hardware acceleration | Not available on this host | Tried `virtio-vga-gl` + `gl=on` (virgl) to fix both the sluggish 2D refresh rate and the mame black screen below — QEMU segfaults inside `libGLX_nvidia.so` around the 35s mark when the guest starts creating a GL context; forcing Mesa software GLX avoids that crash but QEMU still silently dies at the same point. Permanently disabled; kept as an experimental `GL=on` switch in `run_qemu_ui.sh` only | N/A — host GPU/driver limitation, not something this repo's tooling can fix |
| Maps / navigation | Working | Needed a kernel rebuild (`CONFIG_NETFILTER_XT_TARGET_REDIRECT`, `CONFIG_NF_NAT_REDIRECT`) so a transparent SOCKS proxy can `REDIRECT` the map/streaming traffic that ignores `http_proxy`, plus raising `CONFIG_NR_CPUS` from 4 to 8. This is what "mapfix" in the STABLE rootfs filename refers to. Confirmed with real Google map tiles and a live supercharger list | No — baked into the custom `bzImage_redirect_smp8` kernel build, not a rootfs file |
| Built-in games | Mixed | Native Toybox mini-games (Light Show, Sketchpad, etc.) work — they're rendered by QtCar itself, no separate GL process needed. The Arcade app opens, but its downloadable titles (Beach Buggy Racing 2, etc.) can't install — Tesla's CDN backend is unreachable from an emulator, an environment limit rather than a bug. Classic mame titles (Missile Command, Asteroids, ...) don't render at all: no GPU, no software SDL renderer compiled in, and Mesa's software EGL-on-X11 path doesn't work in this build — the same hard limit as 3D acceleration above | Partially — the audio-gate workaround (a synthetic `gameaudio-ready` runit service) is a rootfs change, not reproducible from this repo yet; the mame/Arcade limitations aren't fixable from software at all |

A few things worth being explicit about:

- Touch, Chromium, audio, maps, and the games audio-gate workaround are "working" only in the pre-built `..._STABLE.squashfs` images referenced by `run_qemu_ui.sh`/`run_v62_glamor.sh` by default — those images aren't distributed with this repo (see [What's *not* in this repo](#whats-not-in-this-repo)), so a rootfs you build yourself from scratch via `unpack` + `patch repack` won't have those fixes unless you reconstruct them yourself. The graphics/audio/touch/maps fixes involve binary patches, a rebuilt kernel, and a custom kernel module that aren't reproduced as standalone tooling here yet.
- The network fix is the one exception: it's fully reproducible from this repo. Run it against an already-booted guest (one started with `run --mode ui` or `--mode glamor`, which already carry the second NIC):

  ```bash
  python3 scripts/tesla_fw.py patch network-fix
  ```

  This applies the exact `connmanctl` sequence documented in [Part 2](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/) to configure `eth0`, and a standard-tooling equivalent (not the original file, which wasn't preserved) to bring up a static IP on `eth1`. It only affects the currently running guest — it edits runtime network state, not `/etc/runit/1` itself, so it doesn't survive a reboot. See the script's own header comment (`scripts/apply_network_fix.sh`) for the full detail on what's verified-exact versus reconstructed.

## Further reading

The full research write-up — methodology, dead ends, and the findings
this toolchain distills — is published in two parts on the author's
blog:

- [Part 1: Unpacking](https://cn0xroot.wordpress.com/2026/09/19/root-tesla-os-on-qemu-part-1-unpacking/)
  — GPT partition analysis, reverse-engineering the `iasImage` container
  from the device's own `bootlog.0`, disassembling `verity-init` to
  recover the exact `dm-linear` splice formula, and the ±2MB exhaustive
  search that traced a "corrupted" rootfs down to one missed
  `(p4_bytes >> 12) << 3` truncation.
- [Part 2: Debugging + fixing](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/)
  — the boot-chain fixes (kernel module version pinning, RCU stall
  tuning, a LUKS/quota reformat-on-every-boot loop), the graphics stack
  port (DRM driver selection, Mesa ABI mismatches, the
  `virtio-gpu-gl` → `virtio-vga` fallback), the touch-input protocol
  translation, and two security findings worth flagging on their own:
  `sshd_config`'s dev/production split gated by `is-fused()`, and a
  missing `clock_gettime` entry in `QtCarDvServer.kafel`'s seccomp
  allowlist that only surfaces because this build's glibc skips the
  VDSO fast path.

## What's *not* in this repo

`.gitignore` is a strict allowlist: everything is ignored by default, and
only the tool sources (`scripts/*.py`, `*.sh`, `*.c`, `*.patch`) and this
README are tracked. In particular, **none of the following are ever
committed**:

- The firmware dump itself, or anything derived from it (extracted
  partitions, reconstructed rootfs images, `.squashfs`/`.qcow2` files)
- SSH keys (`scripts/ssh_key/`)
- Packet captures, serial console logs, screenshots of the booted UI
- Any file under `extracted/`, `build/`, `docs/`, or similar working
  directories your own local checkout may accumulate

If you fork this for your own research, keep that boundary: the tooling
is safe to share, the artifacts it produces from a real device usually
are not.

## Scope and ethics

This project exists to make Tesla's own infotainment firmware inspectable
and bootable *offline*, in an emulator, for security research and
defensive analysis — not to defeat vehicle security controls on a live,
in-service car. The dm-verity bypass in `patch build-init` only helps you
boot a modified image *inside QEMU*; it has no effect on, and provides no
path to, a real vehicle's own verity/TPM chain. Use this against firmware
you're authorized to analyze (your own hardware, or under a disclosed
research/bug-bounty engagement), and follow responsible disclosure for
anything you find.

## Acknowledgments

Thanks to [@vessial](https://x.com/vessial) ([GitHub](https://github.com/vessial)) for guidance on the firmware
unpacking approach — the `dm-linear` reconstruction work in `unpack`
benefited directly from that input (credited in [Part 2](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/)
of the write-up above).

The accelerated graphics stack used by `run --mode glamor`
(`scripts/run_v62_glamor.sh`) ports the Ubuntu Xorg + `modesetting` +
glamor (llvmpipe) approach pioneered by
[denysvitali/tesla-qemu](https://github.com/denysvitali/tesla-qemu) onto
this project's real Tesla 4.14 rootfs, including its vblank-wait DRM
patch. `scripts/touch-proxy.c` is likewise based on that project's
`tools/touch-proxy.c`. Credit to [@denysvitali](https://github.com/denysvitali)
for the original QEMU-graphics groundwork this builds on.

Tesla's own public source releases were essential reference material for
identifying and cross-checking the platform this firmware targets:

- [teslamotors/linux](https://github.com/teslamotors/linux) — the vendor
  kernel source, used to cross-reference the extracted `bzImage`
  (version, `Tesla Model3 hardware core support` string, driver
  selection) against a known-authentic build.
- [teslamotors/coreboot](https://github.com/teslamotors/coreboot) —
  Tesla's coreboot sources, relevant to the early Intel Elkhart Lake
  boot chain that hands off into the `iasImage`/`verity-init` sequence
  this project's `unpack`/`patch` tooling targets.
- [teslamotors/buildroot](https://github.com/teslamotors/buildroot) —
  confirmed the `ice-mrb` ("In-Car Entertainment") platform naming and
  general userspace layout (`runit`, `connman`, package set) match this
  firmware, and gave a version baseline to diff the extracted rootfs
  against.

## License

This project is licensed under the **GNU General Public License v3.0** —
see [`LICENSE`](LICENSE) for the full text.

One exception: `scripts/touch-proxy.c` is a derivative of
[denysvitali/tesla-qemu](https://github.com/denysvitali/tesla-qemu)'s
`tools/touch-proxy.c`, and that upstream project does not declare a
license of its own. That single file is therefore *not* covered by this
repository's GPL-3.0 grant — see the note at the top of the file.
Everything else in this repository (including `scripts/tesla_fw.py`,
`scripts/custom_init.c`, and this documentation) is original work
licensed under GPL-3.0.
