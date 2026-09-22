#!/usr/bin/env bash
# ============================================================================
# 一键启动 v62（fork 图形栈移植版）—— 完整渲染 + 流畅
# ============================================================================
# 这是本项目图形性能的里程碑版本：把 denysvitali/tesla-qemu fork 的整套
# Ubuntu 22.04 Xorg + modesetting + glamor(llvmpipe/LLVM15 多线程软件 2D 加速)
# 移植进我们的真机 4.14 Tesla rootfs，让 QtCar UI 从"卡在 Factory Net 加载占位
# 态"跃升到"完整渲染(地图/导航/状态栏全出)+ 流畅"，分辨率 1920×1200(真机原生)。
#
# 关键：**不开 gl=on**(gl=on 会让 4.14 内核黑屏——见 workflow_report.md §17.5)。
# glamor 走软件 llvmpipe，靠 Ubuntu 新 Xorg 的渲染效率，不靠 GPU 3D。
#
# v62 里已烘焙(详见 §18)：
#   - Ubuntu 22.04 Xorg 二进制 + modesetting 驱动 + glamor 模块
#   - ~44 个 Mesa/GL/glamor/input 依赖库 + libwacom 数据
#   - libstdc++ 升级到 GLIBCXX_3.4.30(libLLVM-15 依赖)
#   - Ubuntu virtio_gpu DRI + 已打 0x97e4 vblank 补丁的 Ubuntu libdrm
#   - vblank-fix.so LD_PRELOAD shim(拦 DRM_WAIT_VBLANK,黑屏核心修复)
#   - /etc/sv/x/run 改为裸启 Ubuntu Xorg + 注入图形 env(绕 kafel 沙箱)
#   - 承接 v60/v61：5 处 libQtCarUIFramework 触摸补丁 + lockdown/ssh-config 补丁
#     + is-factory-gated 去水印 + 1200×1920 touch-proxy
#
# 用法：  ./scripts/run_v62_glamor.sh
#         SMP=8 ./scripts/run_v62_glamor.sh     # 覆盖 vCPU 数
#         关闭：关 SDL 窗口，或 QMP quit(见 scripts 里的关机片段),别 kill -9
#               (kill -9 会弄脏 overlay 的 ext4 journal → 下次开机卡 journal 恢复)
# SSH:    ./scripts/ssh_qemu.sh   (v68 起走 eth1/端口 2223,密钥 scripts/ssh_key/id_ed25519)
# 网络(v68 双网卡,见 workflow §20):
#   eth0(net0,10.0.2.x)= connman 托管的 app 联网口(开机静态配 10.0.2.15,
#     CONN_connectedToInternet→true);connman 会按车网拓扑重配 eth0,故 eth0 上的
#     2222 SSH 在联网后失效——这是预期,SSH 请走 eth1。
#   eth1(net1,10.0.3.x)= SSH 专用管理口(hostfwd 2223→10.0.3.15:22),connman 不碰,
#     全程稳定。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

BZIMAGE="${KERNEL:-extracted/ias_a/bzImage_redirect_smp8}"
# initrd:不放易失的 /tmp(bug #39:/tmp 被清导致丢失、无法启动),改用项目内持久文件;
# 持久文件缺失时从 2026 项目的 initrd_ttys1fix.cpio.gz(v38 之后版)恢复。可用 INITRD= 覆盖。
INITRD="${INITRD:-extracted/graphics_test/initrd_custom_v38.cpio.gz}"
INITRD_SRC="2026/extracted/initrd_ttys1fix.cpio.gz"
[ -f "$INITRD" ] || { [ -f "$INITRD_SRC" ] && cp "$INITRD_SRC" "$INITRD"; }
OVERLAY="extracted/overlay.qcow2"
ROOTFS="${1:-extracted/graphics_test/rootfs_v68_net_ssh_audio_chromium_mapfix_STABLE.squashfs}"
SMP="${SMP:-8}"
QMP_SOCK="${QMP_SOCK:-/tmp/tesla_v60_qmp.sock}"
LOGDIR="/tmp/tesla_qemu"; mkdir -p "$LOGDIR"

for f in "$BZIMAGE" "$INITRD" "$OVERLAY" "$ROOTFS"; do
    [ -f "$f" ] || { echo "缺少文件: $f"; exit 1; }
done
if pgrep -f "qemu-system-x86_64.*$OVERLAY" >/dev/null 2>&1; then
    echo "已有 QEMU 占用 $OVERLAY，先关掉它(优先 QMP quit,勿 kill -9):"
    pgrep -af "qemu-system-x86_64.*$OVERLAY"; exit 1
fi
rm -f "$QMP_SOCK"

# ---- 音频转宿主(v68,见 workflow §22)----
# 找可用的 PulseAudio/PipeWire native socket。正常情况下直接跑本脚本的用户就拥有它;
# 若以 root(sudo)运行,退回扫描 /run/user/*/pulse/native(socket 一般 world-writable)。
PULSE_NATIVE="${PULSE_NATIVE:-/run/user/$(id -u)/pulse/native}"
if [ ! -S "$PULSE_NATIVE" ]; then
    PULSE_NATIVE="$(ls /run/user/*/pulse/native 2>/dev/null | head -1)"
fi
AUDIO_ARGS=()
if [ -n "$PULSE_NATIVE" ] && [ -S "$PULSE_NATIVE" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(dirname "$(dirname "$PULSE_NATIVE")")}"
    AUDIO_ARGS=(-audiodev "pa,id=snd0,server=unix:$PULSE_NATIVE" -device AC97,audiodev=snd0)
    echo "音频: 转宿主 PulseAudio ($PULSE_NATIVE)"
else
    AUDIO_ARGS=(-audiodev none,id=snd0 -device AC97,audiodev=snd0)
    echo "音频: 未找到宿主 PulseAudio socket,用 none 后端(guest 声卡在、但不出声)"
fi

echo "启动 v62（fork 图形栈：Ubuntu Xorg + glamor）… 串口日志: $LOGDIR/serial_ui.log"
echo "SSH: ./scripts/ssh_qemu.sh"

# 注意：virtio-vga(无 gl=on) + display sdl,show-cursor=on。glamor 用 llvmpipe。
exec qemu-system-x86_64 -name "Tesla on QEMU" -M q35 -cpu host -enable-kvm -m 8192 -smp "$SMP" \
  -kernel "$BZIMAGE" \
  -initrd "$INITRD" \
  -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clocksource=tsc panic=1 security=apparmor apparmor=1 intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000" \
  -device sdhci-pci -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  -drive if=virtio,file="$ROOTFS",format=raw,readonly=on \
  -device virtio-vga -display "${DISPLAY_BACKEND:-sdl}",show-cursor=on \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp::2222-10.0.2.15:22,hostfwd=tcp::2345-10.0.2.15:2345 \
  -device igb,netdev=net0 \
  -netdev user,id=net1,net=10.0.3.0/24,dhcpstart=10.0.3.15,host=10.0.3.2,hostfwd=tcp::2223-10.0.3.15:22 \
  -device igb,netdev=net1 \
  "${AUDIO_ARGS[@]}" \
  -qmp unix:"$QMP_SOCK",server,nowait \
  -serial file:"$LOGDIR/serial_ui.log" -no-reboot
