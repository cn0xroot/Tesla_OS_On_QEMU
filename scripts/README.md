# `scripts/` — 2024 firmware-version tooling / 2024 版本固件工具

**EN** — Tooling for unpacking the 2024 Tesla firmware and booting it under QEMU (OEM 4.14 kernel lineage). For the 2026 new-kernel firmware version, see [`../2026/scripts/`](../2026/scripts/).

**中文** — 解包 2024 Tesla 固件并在 QEMU 下启动的工具(OEM 4.14 内核一系)。2026 新内核版本固件见 [`../2026/scripts/`](../2026/scripts/)。

> Binaries (firmware/ROM/rootfs/kernel), keys and logs are **not** shipped (see root `.gitignore`); these scripts expect you to produce those locally from the firmware.
> 二进制(固件/ROM/rootfs/内核)、密钥、日志**不随仓库分发**(见根 `.gitignore`),需你自己从固件产出。

## Firmware unpacking / 固件解包

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `tesla_fw.py` | **Main all-in-one CLI**: `unpack` / `patch` / `run` — unified entry wrapping the scattered scripts below | **一体化主入口**:`unpack`/`patch`/`run`,统一调度下面这些脚本 |
| `extract_iasImage.py` | Extract `bzImage` from the Tesla iasImage (offsets verified against device bootlog) | 从 Tesla iasImage 提取 `bzImage`(偏移经实测 bootlog 验证) |
| `extract_initramfs_from_bzimage.sh` | Extract the kernel-embedded initramfs (`cpio.lz4`) from the bzImage | 从 bzImage 解出编译进内核的 initramfs(`cpio.lz4`) |
| `extract_partitions.sh` | Extract GPT partitions from `tesla_ROM1_*.bin` via sfdisk JSON (sector-precise) | 按 GPT 从 `tesla_ROM1_*.bin` 提取各分区(sfdisk JSON,扇区精确) |
| `reconstruct_dm_linear_rootfs.py` | Reconstruct the dm-linear rootfs from extracted partitions | 从提取的分区重建 dm-linear rootfs |

## QEMU launch & access / 启动与访问

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `run_qemu.sh` | Boot the firmware (bank_a/kernel-a) — 180 s headless test | 引导固件(bank_a/kernel-a)—— 180 秒无头测试 |
| `run_qemu_ui.sh` | Daily-use launcher: GUI window, runs until manually stopped | 日常版:GUI 窗口,持续运行至手动关闭 |
| `run_qemu_gdb.sh` | Graphics-test QEMU + dual-layer GDB debug channels | 图形测试 QEMU + 两层 GDB 调试通道 |
| `run_v62_glamor.sh` | One-click v62 (forked graphics-stack port) — full render + smooth | 一键 v62(fork 图形栈移植)—— 完整渲染 + 流畅 |
| `ssh_qemu.sh` | SSH into the running guest | 一键 SSH 进运行中的客户机 |

## In-guest fixes & input / 客户机内修复与输入

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `apply_network_fix.sh` | Apply the v68 dual-NIC + connman static-IP network fix in a running guest | 在运行中客户机内套用 v68 双网卡 + connman 静态 IP 修复 |
| `connman-run-v64.sh` | v64: skip TCU/wpa_supplicant precheck so `connmand` starts under QEMU (no TCU/wifi hw) | v64:跳过 TCU/wpa_supplicant 前置检查,让 `connmand` 在 QEMU 下能起 |
| `capture_pcap.sh` | Run tcpdump in guest, stream pcap back to host over SSH (no guest disk write) | 客户机内 tcpdump,pcap 经 SSH 回传宿主机(不落盘) |
| `focus_qemu.sh` | Fix "QEMU window clicks / keyboard not responding" (window focus) | 修"QEMU 窗口点了/键盘没反应"(窗口焦点) |
| `qemu_snapshot.py` | Live snapshot (RAM+CPU+disk) of the guest via QMP — fast restore | 经 QMP 给客户机做活体快照(RAM+CPU+磁盘),秒级恢复 |
| `qmp_tap.py` | Inject a touch tap (abs move + btn down/up) via QMP | 经 QMP 注入一次触摸点击(移动+按下+抬起) |

## C helpers (compiled into / used by the rootfs) / C 辅助(编入/供 rootfs 用)

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `custom_init.c` | Minimal replacement init (PID 1) that bypasses the dm-verity signature check | 绕过 dm-verity 签名校验的精简替代 init(PID 1) |
| `touch-proxy.c` | QEMU `usb-tablet` → MT type-B for QtCar's TouchDriver | QEMU `usb-tablet` → MT type-B,供 QtCar TouchDriver |
| `x11-input-proxy.c` | Read QEMU `usb-tablet` evdev events, inject into X11 via XTest | 读 QEMU `usb-tablet` evdev 事件,经 XTest 注入 X11 |

---
*Offensive/experimental tools (D-Bus fuzzer, deprecated squashfs recovery scripts) are intentionally **not** included — see root `.gitignore`.*
*攻击性/实验性工具(D-Bus fuzzer、已废弃的 squashfs 恢复脚本)**刻意不收录** —— 见根 `.gitignore`。*
