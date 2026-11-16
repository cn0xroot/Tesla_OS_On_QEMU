#!/usr/bin/env bash
# 一键启动 Tesla 2026 QEMU 图形窗口 —— V2：默认用自编译的 amd-5.4 内核。
#
# 和 scripts/launch_gui.sh 唯一的区别：默认 KERNEL 指向本项目自己编译出的
# kernel-build/linux-amd-5.4/arch/x86/boot/bzImage（5.4.265-PLK，见
# docs/49_amd54_kernel_build.md），而不是 launch_gui.sh 默认的 2024 项目
# 遗留桩内核（../extracted/ias_a/bzImage_redirect_smp8_9p，4.14.274-PLK，
# 版本和 2026 rootfs 自带的 5.4.302-PLK 内核模块完全对不上）。
#
# 其余参数组合原样沿用 launch_gui.sh 那套"长期验证过、能看见窗口、能用鼠标
# 点、能远程调试"的默认值：
#   GUI=on GUI_BACKEND=gtk   -- 真实 GTK 窗口
#   TPM=on                   -- 挂软件 TPM
#   QMP=on                   -- 开 QMP socket，配合截图/点击小工具
#   VIRTFS=on                -- 9p 共享 extracted/hostshare/
#   TTYS1=on                 -- 应急 ttyS1 控制台，QEMU 放后台跑
#
# 用法：
#   ./scripts/launch_gui_v2.sh            # 检测到旧实例会交互确认是否先关闭
#   ./scripts/launch_gui_v2.sh -y         # 不询问，直接关闭旧实例并启动新的
#   DURATION=3600 ./scripts/launch_gui_v2.sh   # 改运行时长（默认 86400s=24h）
#   KERNEL=/path/to/other/bzImage ./scripts/launch_gui_v2.sh   # 仍可覆盖
#
# 关闭：./scripts/stop_gui.sh，或者直接关 GTK 窗口。

set -euo pipefail
cd "$(dirname "$0")/.."   # -> <repo-root>/2026

FORCE=0
[ "${1:-}" = "-y" ] && FORCE=1
[ "${FORCE_LAUNCH:-0}" = "1" ] && FORCE=1

KERNEL="${KERNEL:-$(pwd)/kernel-build/linux-amd-5.4/arch/x86/boot/bzImage}"
if [ ! -f "$KERNEL" ]; then
    echo "找不到内核镜像: $KERNEL" >&2
    echo "先跑一遍 docs/49_amd54_kernel_build.md 里记录的编译步骤，" \
         "或者传 KERNEL=<其它 bzImage 路径> 覆盖。" >&2
    exit 1
fi

EXISTING_PIDS="$(pgrep -f 'qemu-system-x86_64 -name Tesla 2026' 2>/dev/null || true)"
if [ -n "$EXISTING_PIDS" ]; then
    echo "检测到已有 Tesla 2026 QEMU 实例在运行 (PID: $(echo "$EXISTING_PIDS" | tr '\n' ' '))。"
    echo "同时跑两个实例会抢同一个宿主机端口(2222)和同一份 overlay 镜像"
    echo "(extracted/overlay_2026.qcow2)，可能互相冲突甚至弄坏存档——不建议。"
    if [ "$FORCE" != "1" ]; then
        read -r -p "关闭旧实例、启动新的？[y/N] " ans
        case "$ans" in
            [Yy]*) ;;
            *) echo "已取消。如果只是想连回现有窗口，它应该还开着；" \
                    "要用命令行控制可以看 logs/qemu_ttys1_*.pids 里最新的一份。"; exit 1 ;;
        esac
    fi
    echo "正在关闭旧实例..."
    ./scripts/stop_gui.sh --quiet || true
    sleep 2
fi

mkdir -p extracted/hostshare logs

DURATION="${DURATION:-86400}"

echo "内核: $KERNEL  (amd-5.4 自编译版，见 docs/49_amd54_kernel_build.md)"
echo "正在启动 GUI 窗口（GTK），预计约 60s 后 SSH 可用、约 200s 后车机 UI 稳定..."
echo "本次最长运行 ${DURATION}s；随时可以关窗口或跑 ./scripts/stop_gui.sh 结束。"
echo

env KERNEL="$KERNEL" GUI=on GUI_BACKEND=gtk TPM=on QMP=on VIRTFS=on TTYS1=on \
    ./scripts/run_qemu_test.sh "$DURATION"

echo
LATEST_PIDS_FILE="$(ls -t logs/qemu_ttys1_*.pids 2>/dev/null | head -1)"
if [ -n "$LATEST_PIDS_FILE" ]; then
    read -r QEMU_PID SWTPM_PID < "$LATEST_PIDS_FILE"
    QMP_SOCK="$(ls -t /tmp/tesla2026_qmp_*.sock 2>/dev/null | head -1)"
    echo "已启动：QEMU PID=$QEMU_PID  swtpm PID=$SWTPM_PID"
    echo "  SSH 登录：  ./scripts/ssh_qemu.sh"
    echo "  应急控制台：python3 scripts/ttys1_probe.py <logs/ttys1_*.sock 里最新的一个> <输出文件> '命令'"
    [ -n "$QMP_SOCK" ] && echo "  QMP socket：$QMP_SOCK"
    echo "  关闭：      ./scripts/stop_gui.sh"
else
    echo "没能找到 pids 文件，QEMU 可能没有成功起来，去看 logs/qemu_stdout_*.log 或 logs/serial_*.log。"
fi
