# `2026/scripts/` — 2026 firmware-version tooling / 2026 版本固件工具

**EN** — Launchers & helpers for the 2026 firmware on a **self-built linux-5.4.265 kernel**. Overview and non-shipped local artifacts: [`../README.md`](../README.md); kernel build recipe: [`../kernel/BUILD_KERNEL.md`](../kernel/BUILD_KERNEL.md). The 2024 (OEM 4.14) tools are in [`../../scripts/`](../../scripts/).

**中文** — 2026 固件跑在**自编译 linux-5.4.265 内核**上的启动器与辅助工具。总览与「不随仓库走的本地产物」见 [`../README.md`](../README.md);内核构建配方见 [`../kernel/BUILD_KERNEL.md`](../kernel/BUILD_KERNEL.md)。2024(OEM 4.14)工具在 [`../../scripts/`](../../scripts/)。

> Needs a locally-built kernel + rootfs + overlay + SSH key (none shipped). See [`../README.md`](../README.md).
> 需本地自备内核 + rootfs + overlay + SSH 密钥(均不随仓库走),见 [`../README.md`](../README.md)。

## Launch / 启动

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `run_and_fix.sh` ⭐ | **One-click**: boot QEMU + auto-apply all usability fixes (black-screen / touch / map / browser / capture / cookie). **Start here.** | **一键**:启动 QEMU + 自动套用全部可用性修复(黑屏/触摸/地图/浏览器/抓包/Cookie)。**新手从这个开始。** |
| `run_qemu_test.sh` | Underlying engine: builds the QEMU cmdline, starts swtpm, mounts 9p (called by the others, also runnable alone) | 底层引擎:拼 QEMU 命令行、起 swtpm、挂 9p(被其它脚本调用,也可单跑) |
| `launch_gui_v2.sh` | GUI-window launcher (GTK), explicitly uses the self-built amd-5.4 kernel | 图形窗口启动(GTK),显式用自编译 amd-5.4 内核 |
| `start_tesla.sh` | One-click start (fully-automated fix version) | 一键启动(全自动修复版) |
| `run_qemu_web.sh` | Expose the car GUI via browser (noVNC) | 把车机 GUI 通过浏览器(noVNC)显示 |

## Stop / 停止

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `stop_tesla.sh` | Clean stop: `sync` to preserve the `/home` cookie, then stop QEMU | 干净停止:先 `sync` 保 `/home` cookie,再停 QEMU |
| `stop_gui.sh` | Stop `launch_gui*`/`run_qemu_test`(TTYS1=on) instances; clean up swtpm/9p mounts | 停止 `launch_gui*`/`run_qemu_test`(TTYS1=on) 实例;清理 swtpm/9p 挂载 |

## Access & Mac port / 访问与 Mac 移植

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `ssh_qemu.sh` | SSH into the running 2026 guest | 一键 SSH 进运行中的 2026 客户机 |
| `run_qemu_test_mac.sh` | Intel-Mac (HVF) port of `run_qemu_test.sh` | `run_qemu_test.sh` 的 Intel Mac(HVF)移植版 |
| `pack_for_mac.sh` | Package the 2026 project (on Linux) into an Intel-Mac-runnable dist | 在 Linux 端把 2026 项目打包成 Intel Mac 可直接运行的 dist |

## rootfs & helpers / rootfs 与辅助

| File | Purpose (EN) | 用途(中文) |
|---|---|---|
| `patch_rootfs.sh` | Apply this project's usability patches to the unpacked rootfs | 给解包后的 rootfs 套用本项目的可用性补丁 |
| `custom_init_ttys1fix.c` | Minimal replacement init for graphics-driver experiments (ttyS1 fix) | 用于图形驱动实验的精简替代 init(ttyS1 修复) |
| `egl_trace_shim.c` | `LD_PRELOAD` diagnostic/fix shim intercepting `eglChooseConfig` | `LD_PRELOAD` 诊断/修复 shim,拦截 `eglChooseConfig` |
| `ttys1_probe.py` | Connect to the root shell `custom_init` exposes on ttyS1 | 连到 `custom_init` 在 ttyS1 上挂的 root shell |
| `ttys1_upload.py` | Upload a small file to the guest via base64 chunks over the ttyS1 shell | 经 ttyS1 shell 用 base64 分片把小文件上传到客户机 |
