#!/usr/bin/env bash
# 在图形驱动测试用 QEMU 环境基础上，同时开启两层 GDB 调试通道：
#
#   1) 内核态 gdbstub（QEMU 自带，零成本）：
#      用于调试 verity-init/驱动代码/内核 panic，对应 docs/analysis.md
#      / docs/workflow_report.md 里记录的 RCU stall、驱动加载等问题。
#      符号文件用 build/buildroot/output/build/linux-*/vmlinux（只有
#      symtab，没有 DWARF，因为内核 .config 未开 CONFIG_DEBUG_INFO——
#      能做到函数级别的反汇编断点和栈回溯，不能做源码级单步）。
#
#   2) 用户态 gdbserver（本次新增，通过 buildroot `make gdb` 编译，
#      已装进 rootfs_edited_v47.squashfs 的 /usr/bin/gdbserver）：
#      用于附加到客户机内真实运行的用户态进程（minijail0 沙箱内的
#      QtCarDvServer、vcrypt、godot/apviz 等），配合已经打通的 SSH
#      root shell（docs 第6.3节）做面向漏洞挖掘的用户态调试。
#
# 用法:
#   ./scripts/run_qemu_gdb.sh [rootfs squashfs 路径，默认 v47]
#
# 启动后:
#   - 内核态: gdb-multiarch -ex "target remote localhost:1234" \
#         build/buildroot/output/build/linux-*/vmlinux
#     注意默认带 -S，QEMU 会在第一条指令处暂停，需要在 gdb 里
#     `continue` 才会真正开始跑。
#   - 用户态: ssh 进客户机后，对目标进程执行
#         gdbserver :2345 --attach <pid>
#     或者从一开始就用 gdbserver 起进程：
#         gdbserver :2345 /usr/bin/some-tesla-binary
#     然后宿主机侧:
#         build/buildroot/output/host/bin/x86_64-tesla-linux-gnu-gdb \
#           -ex "target remote localhost:2345" \
#           extracted/rootfs_reconstructed/squashfs-root-a/usr/bin/some-tesla-binary

set -euo pipefail
cd "$(dirname "$0")/.."

ROOTFS_SQUASHFS="${1:-extracted/graphics_test/rootfs_v68_net_ssh_audio_chromium_mapfix_STABLE.squashfs}"

BZIMAGE="extracted/ias_a/bzImage_graphics_test_fbdev"
# initrd:不放易失的 /tmp(bug #39:/tmp 被清导致丢失、无法启动),改用项目内持久文件;
# 持久文件缺失时从 2026 项目的 initrd_ttys1fix.cpio.gz(v38 之后版)恢复。可用 INITRD= 覆盖。
INITRD="${INITRD:-extracted/graphics_test/initrd_custom_v38.cpio.gz}"
INITRD_SRC="2026/extracted/initrd_ttys1fix.cpio.gz"
[ -f "$INITRD" ] || { [ -f "$INITRD_SRC" ] && cp "$INITRD_SRC" "$INITRD"; }
OVERLAY="extracted/overlay.qcow2"
VMLINUX=$(find build/buildroot/output/build -maxdepth 1 -regextype posix-extended -regex '.*/linux-[0-9a-f]{40}' -type d | head -1)/vmlinux
LOGDIR="/tmp/tesla_qemu"
SERIAL_LOG="$LOGDIR/serial_gdb.log"

mkdir -p "$LOGDIR"

[ -f "$BZIMAGE" ]         || { echo "缺少内核: $BZIMAGE"; exit 1; }
[ -f "$INITRD" ]          || { echo "缺少 initrd: $INITRD（先跑一次已有的 run_qemu.sh 流程生成）"; exit 1; }
[ -f "$ROOTFS_SQUASHFS" ] || { echo "缺少 rootfs: $ROOTFS_SQUASHFS"; exit 1; }
[ -f "$VMLINUX" ]         || echo "警告: 未找到 vmlinux，内核态符号解析会不可用: $VMLINUX"

echo "内核态调试符号: $VMLINUX"
echo "gdbserver（客户机内）: /usr/bin/gdbserver（已打包进 $ROOTFS_SQUASHFS）"
echo
echo "启动 QEMU（内核态 gdbstub 监听 :1234，客户机启动即暂停，等待 gdb attach 后 continue）..."

qemu-system-x86_64 -name "Tesla on QEMU (gdb)" -M q35 -cpu host -enable-kvm -m 8192 -smp 4 \
  -kernel "$BZIMAGE" \
  -initrd "$INITRD" \
  -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clocksource=tsc panic=1 security=apparmor apparmor=1 intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000" \
  -device sdhci-pci -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  -drive if=virtio,file="$ROOTFS_SQUASHFS",format=raw,readonly=on \
  -device virtio-vga -display sdl \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp::2222-10.0.2.15:22,hostfwd=tcp::2345-10.0.2.15:2345 \
  -device igb,netdev=net0 \
  -serial file:"$SERIAL_LOG" -no-reboot \
  -s -S \
  > "$LOGDIR/qemu_gdb_stdout.log" 2>&1 &

QEMU_PID=$!
echo "QEMU PID=$QEMU_PID，已暂停在第一条指令。"
echo
echo "连接内核态 gdbstub:"
echo "  gdb-multiarch -ex 'target remote localhost:1234' '$VMLINUX'"
echo "  (gdb) continue   # 客户机才会真正开始执行"
echo
echo "客户机跑起来、SSH 可用后（见 docs 第6.3节），远程附加用户态进程:"
echo "  ssh -i scripts/ssh_key/id_ed25519 -p 2222 root@127.0.0.1 'gdbserver :2345 --attach \$(pidof QtCarDvServer)'"
echo "  build/buildroot/output/host/bin/x86_64-tesla-linux-gnu-gdb \\"
echo "    -ex 'target remote localhost:2345' \\"
echo "    extracted/rootfs_reconstructed/squashfs-root-a/usr/tesla/UI/bin/QtCarDvServer"
