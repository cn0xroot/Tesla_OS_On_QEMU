# Tesla OS on QEMU — 2026 版本固件工具（linux-amd-5.4 内核）

> 顶层仓库的 `scripts/` 是 **2024 版本固件**工具（OEM 4.14 内核）。
> 本目录 `2026/scripts/` 是 **2026 版本固件**：启动一颗**自编译的 Linux 5.4.265
> 内核**，配 2026 固件的 rootfs。两套平行演进，互不依赖。

本目录**只分发文本工具/源码/构建配方**。内核二进制、rootfs、overlay 磁盘、
swtpm 状态、SSH 密钥、日志一律**不进仓库**（体积大 + 敏感 + 合规，见根目录
`.gitignore`）—— 你需要自己从固件产出这些本地产物。

---

## 目录结构

```
2026/
├── README.md              # 本文件
├── kernel/
│   ├── BUILD_KERNEL.md    # 5.4 内核构建配方（含串口日志关键坑）
│   └── linux-5.4.265.config
└── scripts/               # 启动/辅助工具（下表）
```

## 脚本一览

| 脚本 | 作用 | 内核 |
|---|---|---|
| **`run_and_fix.sh`** ⭐ | 一键：启动 QEMU + 自动应用全部可用性修复（黑屏/触摸/地图/浏览器/抓包/Cookie 持久）。**新手从这个开始。** | 5.4 |
| `run_qemu_test.sh` | 底层引擎：拼 QEMU 命令行、起 swtpm、挂 9p。被上面的脚本调用，也可单独跑。 | 默认 4.14，`KERNEL=` 可覆盖 |
| `launch_gui_v2.sh` | 图形窗口启动（GTK，`DISPLAY=:1`），显式用 5.4 内核。 | 5.4 |
| `start_tesla.sh` / `stop_tesla.sh` | 另一套干净启停（`stop` 会先 `sync` 保 Cookie 再停）。 | 5.4 |
| `stop_gui.sh` | 停止 `launch_gui*/run_qemu_test`(TTYS1=on) 起的实例，清理 swtpm/9p 挂载。 | — |
| `ssh_qemu.sh` | SSH 进正在运行的客户机（`-p 2222 root@127.0.0.1`）。 | — |
| `run_qemu_web.sh` | 浏览器专用启动变体。 | 4.14 |
| `run_qemu_test_mac.sh` / `pack_for_mac.sh` | Intel Mac（HVF）移植：打包 + 启动。 | — |
| `patch_rootfs.sh` | rootfs 可用性补丁工具（AppArmor/quota/Mesa 等）。 | — |
| `*.c` / `ttys1_*.py` | `custom_init` 的 ttyS1 文件传输通道 + EGL trace shim 等辅助。 | — |

> 实验性/重复入口（`launch_gui.sh` v1、`run_hybrid_gui.sh`）**不随仓库分发**，
> 以免多个启动脚本让人困惑。

## 跑起来需要的本地产物（不随仓库走）

脚本假设以下文件在 `2026/` 下存在，这些都**不分发**，需你自己产出：

1. **内核 `bzImage`** —— 按 [`kernel/BUILD_KERNEL.md`](kernel/BUILD_KERNEL.md) 从
   kernel.org 源码 + 本仓库 `.config` 自行编译。
2. **rootfs squashfs**（如 `extracted/rootfs_2026_beeeye.squashfs`）—— 从 2026
   固件解包、再用 `patch_rootfs.sh` 打可用性补丁得到。解包流程参考 2024 版本固件的
   `scripts/tesla_fw.py unpack`。
3. **overlay qcow2** —— backing 到只读固件 ROM 的 CoW 磁盘（绝对路径，拷到别的
   机器会失效，见 `pack_for_mac.sh` 注释）。
4. **SSH 密钥**（`keys/qemu_ssh_key{,.pub}`）—— 自己 `ssh-keygen -t ed25519`
   生成，公钥随 rootfs 打进 `authorized_keys_dev`（见 `ssh_qemu.sh` 注释）。

## 快速开始（产物就位后）

```bash
# 从仓库根目录（2026/ 的上一级）执行：
./2026/scripts/run_and_fix.sh 300      # 启动并跑 5 分钟；日志见 2026/logs/
./2026/scripts/ssh_qemu.sh             # 另开终端 SSH 进去
./2026/scripts/stop_gui.sh --all       # 收尾
```

启动日志落在 `2026/logs/serial_<时间戳>.log`（**前提是内核按 BUILD_KERNEL.md
用了 `console=ttyS0`**，否则该文件恒为空——这是本版本修过的一个坑）。

## 合规

- **不分发任何内核二进制**：OEM 4.14 是从固件 ROM 抠出的无源 blob（传公开仓库
  = GPL 违规 + 重分发固件），绝不上传；5.4 以源码配方形式提供。
- Tesla 的 `drivers/misc/tesla/` 为 **GPL-2.0-only**，构建说明**指向 Tesla 官方
  GPL 源码发布**，本仓库不 re-host。
