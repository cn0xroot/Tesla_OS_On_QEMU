#!/usr/bin/env bash
# 日常使用版：开 GUI 窗口、持续运行直到手动关闭（不像 run_qemu.sh 那样
# 180 秒自动超时退出、也不像它一样 -display none）。
#
# 用的是 docs/workflow_report.md Stage 03/05/06 里记录的完整修复链路：
#   - custom_init 自定义 initrd（跳过 dm-verity/dm-linear，见 Stage 03.1）
#   - bzImage_graphics_test_fbdev（内置 bochs-drm/virtio-gpu 驱动，见 Stage 05.1）
#   - virtio-vga 纯 2D scanout（放弃 3D 加速换取画面能正常显示，见 Stage 05.6）
#   - rootfs_edited_v47.squashfs（触屏三处修复 + sshd 网络修复 + gdbserver，
#     见 Stage 06.1/06.3 与本次新增的 GDB 支持）
#
# 用法:
#   ./scripts/run_qemu_ui.sh
#   Ctrl+C 或关闭 SDL 窗口结束；也可以另开终端 pkill 掉。
#
# 交互:
#   - USB 鍵盘/触摸板(usb-tablet)已挂载，窗口内点击应能像真实设备一样投递事件
#     （若发现点了/敲键盘完全没反应，大概率不是客户机的问题，是宿主机 GNOME
#     Shell 没有把真正的 X 输入焦点转移到这个窗口——任务栏显示"已激活"不等于
#     真正拿到了输入焦点。跑一下 ./scripts/focus_qemu.sh 强制把焦点按过去，
#     已用 evtest 实测验证这能立刻修好）。
#   - SSH: ./scripts/ssh_qemu.sh（一键连接，见该脚本）
#
# 常见故障：
#   若启动瞬间报 "Failed to get \"write\" lock" 或类似锁错误，说明有旧的
#   QEMU 进程还占着 overlay.qcow2，先执行:
#     ps aux | grep qemu-system-x86_64
#     pkill -9 -f qemu-system-x86_64   # 或按 PID 精确 kill

set -euo pipefail
cd "$(dirname "$0")/.."

BZIMAGE="${KERNEL:-extracted/ias_a/bzImage_redirect_smp8}"
# initrd:启动必需产物不放易失的 /tmp(bug #39:/tmp 被 systemd-tmpfiles 清理导致
# 丢失、无法启动)。改用项目内持久文件,可用 INITRD= 覆盖。
INITRD="${INITRD:-extracted/graphics_test/initrd_custom_v38.cpio.gz}"
OVERLAY="extracted/overlay.qcow2"
# rootfs 默认用网络/SSH/音频/Chromium/地图全部修好的稳定版(见 workflow_report.md v68)。
ROOTFS_SQUASHFS="${1:-extracted/graphics_test/rootfs_v68_net_ssh_audio_chromium_mapfix_STABLE.squashfs}"
LOGDIR="/tmp/tesla_qemu"
SERIAL_LOG="$LOGDIR/serial_ui.log"
# 默认4，可用 SMP=8 ./scripts/run_qemu_ui.sh 覆盖——workflow_report.md 里
# 记录的实验：QtCar+godot两个软件渲染进程各占满一个核心，宿主机核心/内存
# 富余时加大vCPU数看能否缓解UI刷新率过低的问题。
SMP="${SMP:-8}"

mkdir -p "$LOGDIR"

# initrd 自愈(bug #39):持久备份是 v38 之后的 ttys1fix 版(custom_init 跳过 dm-verity,
# 直接挂 /dev/vda squashfs)。持久文件缺失时从 2026 项目的 initrd_ttys1fix.cpio.gz 恢复。
INITRD_SRC="2026/extracted/initrd_ttys1fix.cpio.gz"
if [ ! -f "$INITRD" ] && [ -f "$INITRD_SRC" ]; then
    echo "initrd: 持久备份缺失,从 $INITRD_SRC 恢复(v38 之后 ttys1fix 版)"
    cp "$INITRD_SRC" "$INITRD"
fi

[ -f "$BZIMAGE" ]         || { echo "缺少内核: $BZIMAGE"; exit 1; }
[ -f "$INITRD" ]          || { echo "缺少 initrd: $INITRD"; exit 1; }
[ -f "$OVERLAY" ]         || { echo "缺少 overlay: $OVERLAY（先跑一次 run_qemu.sh 让它自动创建）"; exit 1; }
[ -f "$ROOTFS_SQUASHFS" ] || { echo "缺少 rootfs: $ROOTFS_SQUASHFS"; exit 1; }

if pgrep -f "qemu-system-x86_64.*$OVERLAY" > /dev/null 2>&1; then
    echo "检测到已有 QEMU 进程占用 $OVERLAY，先清理:"
    pgrep -af "qemu-system-x86_64.*$OVERLAY"
    echo "如需继续，先手动 kill 掉上面的进程再重新运行本脚本。"
    exit 1
fi

# ---- 音频转宿主(v68,见 workflow §22)----
PULSE_NATIVE="${PULSE_NATIVE:-/run/user/$(id -u)/pulse/native}"
[ -S "$PULSE_NATIVE" ] || PULSE_NATIVE="$(ls /run/user/*/pulse/native 2>/dev/null | head -1)"
if [ -n "$PULSE_NATIVE" ] && [ -S "$PULSE_NATIVE" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(dirname "$(dirname "$PULSE_NATIVE")")}"
    AUDIO_ARGS=(-audiodev "pa,id=snd0,server=unix:$PULSE_NATIVE" -device AC97,audiodev=snd0)
    echo "音频: 转宿主 PulseAudio ($PULSE_NATIVE)"
else
    AUDIO_ARGS=(-audiodev none,id=snd0 -device AC97,audiodev=snd0)
    echo "音频: 未找到宿主 PulseAudio socket,用 none 后端"
fi

# ---- 图形后端（virgl 3D 硬件加速可选，见 workflow §25 / bug #38）----
# 默认纯 2D virtio-vga（软件渲染，UI ~15-28fps，mame 经典游戏因 Mesa 软件 EGL-on-X11
# 无法初始化视频而失败）。设 GL=on 改用 virtio-vga-gl + SDL gl=on：宿主 virglrenderer
# 把 3D 能力(cap sets)暴露给 guest，guest 的 virtio_gpu_dri 连宿主 GPU → 真实 GLES/EGL，
# 一举修好 UI 卡顿 + mame/arcade 游戏渲染。需宿主有 GPU + libvirglrenderer + QEMU virtio-vga-gl。
# 显示后端 DISPLAY_BACKEND 可选 sdl(默认)/gtk。
# ⚠️ gtk vs sdl(bug #42):SDL 窗口在 GNOME/mutter 下有顽固的输入焦点问题——窗口即便"激活"
# 也常拿不到真正的 X 输入焦点,鼠标点击不进 guest,表现为"UI 卡死"(实为输入进不去,guest 其实活着)。
# GTK 后端是原生 GTK 窗口,与 GNOME 集成、点击对焦像普通应用一样可靠,彻底绕开该问题,
# 且无需把宿主改成焦点跟随鼠标(那会拖累宿主开应用,见 bug #40/#41 复盘)。故默认改用 gtk。
DB="${DISPLAY_BACKEND:-gtk}"
if [ "$DB" = "gtk" ]; then
    # zoom-to-fit=off 保持 1:1 像素、坐标不缩放;show-cursor=on 强制显示指针
    # (车机是触屏 UI、自身不画光标,不加这个则鼠标进 GUI 后不可见、无法瞄准,见 bug #43)
    DISP="gtk,zoom-to-fit=off,show-cursor=on"
else
    DISP="$DB,show-cursor=on"       # sdl 等
fi
if [ "${GL:-off}" = "on" ]; then
    GPU_ARGS=(-device virtio-vga-gl -display "${DISP}${DISP:+,}gl=on")
    echo "图形: virgl 3D 硬件加速 (virtio-vga-gl + gl=on, 显示后端=$DB)"
else
    GPU_ARGS=(-device virtio-vga -display "$DISP")
    echo "图形: 纯 2D virtio-vga (软件渲染, 显示后端=$DB)"
fi

echo "启动中（GUI 窗口即将弹出，串口完整日志见 $SERIAL_LOG）..."
echo "SSH: ./scripts/ssh_qemu.sh"

exec qemu-system-x86_64 -name "Tesla on QEMU" -M q35 -cpu host -enable-kvm -m 8192 -smp "$SMP" \
  -kernel "$BZIMAGE" \
  -initrd "$INITRD" \
  -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clocksource=tsc panic=1 security=apparmor apparmor=1 intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000" \
  -device sdhci-pci -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  -drive if=virtio,file="$ROOTFS_SQUASHFS",format=raw,readonly=on \
  "${GPU_ARGS[@]}" \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp::2222-10.0.2.15:22,hostfwd=tcp::2345-10.0.2.15:2345 \
  -device igb,netdev=net0 \
  -netdev user,id=net1,net=10.0.3.0/24,dhcpstart=10.0.3.15,host=10.0.3.2,hostfwd=tcp::2223-10.0.3.15:22 \
  -device igb,netdev=net1 \
  "${AUDIO_ARGS[@]}" \
  -qmp unix:${QMP_SOCK:-/tmp/tesla_v60_qmp.sock},server,nowait \
  -serial file:"$SERIAL_LOG" -no-reboot
