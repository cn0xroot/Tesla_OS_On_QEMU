# 构建 2026 版 QEMU 用内核（linux-amd-5.4）

2026 版本固件脚本（`2026/scripts/` 下的 `run_and_fix.sh` / `launch_gui_v2.sh` /
`run_hybrid_gui.sh` / `start_tesla.sh`）启动的是一颗**自编译的 Linux 5.4.265 内核**，
而不是 2024 那套用的 OEM 4.14 内核。本仓库**不分发内核二进制**（见根目录
`.gitignore` 的白名单说明），只提供这份**构建配方 + `.config`**，你自己编出
`bzImage` 即可。

> 已随附 [`linux-5.4.265.config`](linux-5.4.265.config)（4986 行）。

---

## 1. 取源码

从 kernel.org 下 **linux-5.4.265**（stable 树）：

```bash
wget https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.4.265.tar.xz
tar xf linux-5.4.265.tar.xz
cd linux-5.4.265
```

## 2. 叠加 Tesla 的 GPL 车机驱动

这颗内核内置了 Tesla 的几个树外驱动：`drivers/misc/tesla/{oem,hsti,hsti1,psb,panic-biosram}`。
它们在 Tesla 自己的源码里标的是 **`SPDX-License-Identifier: GPL-2.0-only`，
`Copyright (C) 2021 Tesla, Inc.`**，属于 Tesla **官方 GPL 内核源码发布**的一部分。

- 请从 **Tesla 官方 GPL 源码发布**获取这些驱动源码并放到 `drivers/misc/tesla/`，
  本仓库**不 re-host** Tesla 代码，只说明来源。
- 对应的 `Kconfig` / `Makefile` 挂接方式参考 `drivers/misc/Kconfig` 里 `source
  "drivers/misc/tesla/Kconfig"` 一行；`.config` 里相关符号已开启，`make
  olddefconfig` 会提示你补齐缺失项。

> 若你只想先跑通、暂不接 Tesla 驱动，可在 `make menuconfig` 里关掉
> `drivers/misc/tesla` 的相关 CONFIG，功能上不影响 QEMU 启动与串口日志。

## 3. 套用本仓库的 .config 并编译

```bash
cp /path/to/2026/kernel/linux-5.4.265.config .config
make olddefconfig           # 按本机工具链归一（缺失项用默认值补齐）
make -j"$(nproc)" bzImage    # 增量/全量编译；本项目用 gcc 13.3 实测通过
```

编出的 `arch/x86/boot/bzImage` 即为启动脚本默认要找的那颗。脚本里用
`KERNEL=` 环境变量覆盖路径，例如：

```bash
KERNEL=/path/to/linux-5.4.265/arch/x86/boot/bzImage ./scripts/launch_gui_v2.sh
```

---

## 4. ⚠ 关键配置：`CONFIG_CMDLINE` 必须用 `ttyS0`，否则串口日志全空

本仓库的 `.config` 里：

```
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE="console=ttyS0,115200n8 console=tty0"
# CONFIG_CMDLINE_OVERRIDE is not set
```

**这一行是踩过坑后修正的，别改回去。** 曾经的值是
`console=ttyS4,115200n8 console=tty0`：

- `CONFIG_CMDLINE_OVERRIDE` 未设 = 这段被**前置追加**到 QEMU `-append` 传的
  cmdline 最前面；
- 但 QEMU q35 只有 `ttyS0`(0x3f8)/`ttyS1`(0x2f8) 两个 ISA 串口，**根本不存在
  `ttyS4`**；
- 结果内核主 console 掉到 `tty0`/netconsole，`-serial file:` 挂的 ttyS0 从不被
  激活 —— `logs/serial_<ts>.log` **恒为 0 字节**。

**判定指征**：`dmesg` 里只有 `console [tty0] enabled`，**没有
`console [ttyS0] enabled`**；且 `Kernel command line:` 一行里能看到多出来的
`console=ttyS4`。改成 `ttyS0` 重编后，`console [ttyS0] enabled` 出现，串口日志
恢复正常（实测一次完整启动约 170KB / 2100+ 行）。

注意：`CONFIG_SERIAL_8250_CONSOLE=y` 看着没问题，它是**被烘焙 cmdline 架空**的，
容易误判成「串口驱动没编进去」。
