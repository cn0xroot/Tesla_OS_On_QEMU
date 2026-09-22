#!/usr/bin/env bash
# 在 QEMU 中引导本目录下的 Tesla 固件镜像（bank_a / kernel-a）。
#
# 背景：
#   镜像是特斯拉车机（Elkhart Lake / x86_64 平台，很可能是 MCU/仪表 IC 类 ECU）
#   的完整 eMMC dump。boot 分区里的 iasImage 是厂商自定义容器，内嵌标准 Linux
#   bzImage；真正的根文件系统由内置的 verity-init 依据 cmdline 中的
#   `bootpart=kernel-a|kernel-b` 通过 device-mapper 动态拼装（squashfs 只读根
#   + LVM 逻辑卷承载 /var、/log 等可写数据），而不是靠传统的 root=/dev/xxx。
#
# 用法:
#   ./scripts/run_qemu.sh [原始镜像路径] [持续时间秒，默认120] [gui|nogui，默认nogui]
#
# 输出（统一放在 /tmp/tesla_qemu/，不污染项目目录）:
#   /tmp/tesla_qemu/serial.log       -- 串口(ttyS0)完整启动日志
#   /tmp/tesla_qemu/qemu_stdout.log  -- QEMU 自身的 stdout/stderr
#
# 注意:
#   - 原始 .bin 文件全程只读；所有可能的写入都发生在 extracted/overlay.qcow2
#     写时复制层里，不会污染原始镜像。
#   - QEMU 的 sd-card 后端要求容量为 2 的幂，所以 overlay 会被扩到 64GiB
#     （多出的空间是稀疏空洞，不影响原有分区数据）。
#   - 需要提前用 scripts/extract_iasImage.py 从 boot 分区的 bank_a.iasImage
#     中提取出 extracted/ias_a/bzImage（见 docs/analysis.md 第 3 节）。
#   - 若 CPU 不支持 KVM（如虚拟机套虚拟机），去掉 -enable-kvm，
#     并把 -cpu host 换成 -cpu max（否则车机自带的 dmsetup 等二进制
#     可能因缺少指令集而 "trap invalid opcode" 崩溃）。
#
# 关于 cmdline 的重要说明（详见 docs/analysis.md 第7节的完整排查记录）：
#   这里 **刻意不加** `tsc=reliable`。实测发现两者互相冲突、无法两全：
#     - 不加 tsc=reliable：稳定在 ~125s 进入真实 UI 后端 QtCarDvServer/
#       CenterDisplay/Bluetooth/NetManager 等（两次独立测试均复现），代价是
#       QtCarDvServer 之后会周期性触发一次 clock_gettime 被 seccomp 拒绝导致
#       的崩溃重启（TSC 在多核间不同步 -> vDSO 快速路径失效 -> 退化为真实
#       系统调用 -> 被沙箱策略拒绝），但 runit 会自动拉起，其它独立服务不受
#       影响，系统整体不会卡死。
#     - 加了 tsc=reliable：QtCarDvServer 自己的崩溃循环消失，但早期阶段大量
#       经由 minijail0 启动的辅助程序反而更容易撞上另一个原因不明的、固定发生在
#       libc.so.6 内偏移 0x500 处的竞态崩溃，实测中会导致启动卡在真正进入
#       UI 层之前（多次测试跑到 5-10 分钟都未到达）。
#     - 换 CPU 型号（-cpu host / Snowridge）、关闭 AVX/FMA、改单核(-smp 1)
#       均未能同时解决两个问题，怀疑是该车机固件在虚拟化环境下的一个更深层、
#       和真实 Intel 硬件时序特性相关的竞态条件，非 QEMU 参数可完全根治。
#   综上，当前脚本采用实测下"能可靠进入 UI 层"的配置作为默认值。

set -euo pipefail
cd "$(dirname "$0")/.."

IMG="${1:-tesla_ROM1_000000000000_000ED2000000.bin}"
DURATION="${2:-180}"
DISPLAY_MODE="${3:-nogui}"

BZIMAGE="extracted/ias_a/bzImage"
LOGDIR="/tmp/tesla_qemu"
OVERLAY="extracted/overlay.qcow2"
SERIAL_LOG="$LOGDIR/serial.log"
CMDLINE_FILE="$LOGDIR/cmdline.txt"

mkdir -p "$LOGDIR"

[ -f "$BZIMAGE" ] || { echo "缺少 $BZIMAGE，请先运行 extract_iasImage.py"; exit 1; }

if [ ! -f "$OVERLAY" ]; then
    echo "创建 qcow2 写时复制覆盖层（不修改原始镜像）..."
    qemu-img create -f qcow2 -b "$(readlink -f "$IMG")" -F raw "$OVERLAY"
    qemu-img resize "$OVERLAY" 64G
fi

cat > "$CMDLINE_FILE" <<'EOF'
console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel bootpart=kernel-a clocksource=tsc panic=1 security=apparmor apparmor=1 intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000
EOF
CMDLINE=$(cat "$CMDLINE_FILE")

DISPLAY_ARGS=(-display none)
if [ "$DISPLAY_MODE" = "gui" ]; then
    DISPLAY_ARGS=(-vga std -display gtk)
fi

echo "启动 QEMU（最长运行 ${DURATION}s，串口日志见 $SERIAL_LOG，模式=$DISPLAY_MODE）..."
timeout "$DURATION" qemu-system-x86_64 \
  -M q35 \
  -cpu host -enable-kvm \
  -m 8192 \
  -smp 4 \
  -kernel "$BZIMAGE" \
  -append "$CMDLINE" \
  -device sdhci-pci \
  -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  "${DISPLAY_ARGS[@]}" -serial file:"$SERIAL_LOG" -no-reboot \
  > "$LOGDIR/qemu_stdout.log" 2>&1 || true

echo "结束（超时被杀属正常，说明系统仍在运行未崩溃）"
echo "查看日志: less $SERIAL_LOG"
