#!/usr/bin/env bash
# ============================================================================
# run_qemu_test_mac.sh  —  run_qemu_test.sh 的 Intel Mac 移植版
# ============================================================================
# 与 Linux 版 run_qemu_test.sh 行为、环境变量接口完全一致，只把 4 处对
# Linux 宿主的耦合改成 macOS 等价物：
#
#   1. 加速   : -enable-kvm -cpu host,migratable=off  ->  -accel hvf -cpu host
#               （Intel Mac 用 Hypervisor.framework 硬件加速，x86_64 客户机
#                 接近原生速度。tsc=reliable 内核参数保留——Intel Mac 的
#                 CPU 同样是 constant_tsc/nonstop_tsc，正好满足那颗 4.14
#                 内核对稳定 TSC 的假设，避免退到 hpet 撞 seccomp。）
#   2. 音频   : PulseAudio/PipeWire socket 探测 + pactl 解静音  ->  coreaudio
#               （macOS 没有 pulse socket，也没有 pactl；CoreAudio 直接出声。）
#   3. 显示   : GTK/SDL + X11 DISPLAY  ->  cocoa（macOS 原生窗口）
#               （GPU=vga-gl 的 egl-headless 路径在 macOS 无 EGL，自动退回 vga。）
#   4. 超时   : GNU timeout  ->  timeout 或 gtimeout 自动探测
#               （macOS 自带没有 timeout，需 `brew install coreutils` 得到 gtimeout。）
#
# 依赖（一次性）：
#   brew install qemu swtpm coreutils
#
# 用法（和 Linux 版相同）：
#   ./scripts/run_qemu_test_mac.sh [duration_seconds]
#   GUI=on ./scripts/run_qemu_test_mac.sh 180
#   TPM=on GUI=on ./scripts/run_qemu_test_mac.sh 600
# ============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."   # -> .../Tesla/2026

PARENT="$(cd .. && pwd)"

# ---- 超时命令探测（macOS 自带没有 timeout）---------------------------------
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "缺少 timeout/gtimeout，请先执行：brew install coreutils" >&2
    exit 1
fi

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "缺少 qemu-system-x86_64，请先执行：brew install qemu" >&2; exit 1; }

BZIMAGE="${KERNEL:-$PARENT/extracted/ias_a/bzImage_redirect_smp8_9p}"
INITRD="${INITRD:-extracted/initrd_ttys1fix.cpio.xz}"
# Mac 上应指向 pack_for_mac.sh 合并出的自包含镜像（无 backing 依赖），
# 默认沿用 Linux 版路径，可用 OVERLAY= 覆盖。
OVERLAY="${OVERLAY:-extracted/overlay_2026.qcow2}"
ROOTFS="${ROOTFS:-extracted/rootfs_2026_current.squashfs}"
DURATION="${1:-180}"
SMP="${SMP:-4}"
TPM="${TPM:-off}"
APPARMOR="${APPARMOR:-1}"
TTYS1="${TTYS1:-off}"
GPU="${GPU:-vga}"
QMP="${QMP:-off}"
VIRTFS="${VIRTFS:-off}"
GUI="${GUI:-off}"
AUDIO="${AUDIO:-on}"

TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p logs
SERIAL_LOG="logs/serial_${TS}.log"
STDOUT_LOG="logs/qemu_stdout_${TS}.log"

for f in "$BZIMAGE" "$INITRD" "$OVERLAY" "$ROOTFS"; do
    [ -f "$f" ] || { echo "缺少文件: $f"; exit 1; }
done

echo "内核:  $BZIMAGE"
echo "initrd: $INITRD"
echo "overlay: $OVERLAY"
echo "rootfs: $ROOTFS"
echo "串口日志: $SERIAL_LOG"
echo "加速: HVF (Intel Mac)"

# ---- swtpm（macOS 上 brew 的 swtpm 用法与 Linux 一致）-----------------------
TPM_ARGS=()
SWTPM_PID=""
if [ "$TPM" = "on" ]; then
    command -v swtpm >/dev/null 2>&1 || { echo "缺少 swtpm：brew install swtpm" >&2; exit 1; }
    TPM_DIR="${TPM_STATE_DIR:-extracted/swtpm_state}"
    mkdir -p "$TPM_DIR"
    SWTPM_LOG="logs/swtpm_${TS}.log"
    SWTPM_SOCK="$TPM_DIR/swtpm-sock"
    swtpm socket --tpmstate dir="$TPM_DIR" \
        --ctrl type=unixio,path="$SWTPM_SOCK" \
        --tpm2 --log file="$SWTPM_LOG",level=5 &
    SWTPM_PID=$!
    for i in $(seq 1 50); do [ -S "$SWTPM_SOCK" ] && break; sleep 0.1; done
    [ -S "$SWTPM_SOCK" ] || { echo "swtpm 控制 socket 未建立: $SWTPM_SOCK"; kill "$SWTPM_PID" 2>/dev/null || true; exit 1; }
    TPM_ARGS=(-chardev "socket,id=chrtpm,path=$SWTPM_SOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
    echo "TPM: 已挂软件 TPM (swtpm pid=$SWTPM_PID, 状态目录=$TPM_DIR, 日志=$SWTPM_LOG)"
    trap 'kill "$SWTPM_PID" 2>/dev/null || true' EXIT
else
    echo "TPM: 未挂（TPM=on 开启）"
fi

TTYS1_ARGS=()
if [ "$TTYS1" = "on" ]; then
    TTYS1_SOCK="logs/ttys1_${TS}.sock"
    TTYS1_ARGS=(-chardev "socket,id=ttys1,path=$TTYS1_SOCK,server=on,wait=off" -serial chardev:ttys1)
    echo "ttyS1: $TTYS1_SOCK (用 scripts/ttys1_probe.py 连接)"
fi

# ---- 显示（macOS 用 cocoa 原生窗口；vga-gl 的 egl-headless 无法用）----------
RES="${RES:-1920x1200}"
RES_X="${RES%x*}"
RES_Y="${RES#*x}"
if [ "$GPU" = "vga-gl" ]; then
    echo "警告: macOS 无 EGL/virgl，GPU=vga-gl 不可用，已退回 vga（软件渲染）。" >&2
    GPU="vga"
fi
GPU_ARGS=(-device "virtio-vga,xres=$RES_X,yres=$RES_Y" -display none)
if [ "$GUI" = "on" ]; then
    # macOS 原生 Cocoa 窗口：没有 Linux 版 GTK/SDL 的 XSetInputFocus/mutter
    # 焦点坑，鼠标点击直接由 QEMU Cocoa 窗口注入。
    for i in "${!GPU_ARGS[@]}"; do
        [ "${GPU_ARGS[$i]}" = "-display" ] && GPU_ARGS[$((i+1))]="cocoa,show-cursor=on"
    done
    echo "GUI: 真实窗口模式（Cocoa，分辨率 ${RES}）"
fi

QMP_ARGS=()
if [ "$QMP" = "on" ]; then
    QMP_SOCK="${QMP_SOCK:-/tmp/tesla2026_qmp_${TS}.sock}"
    QMP_ARGS=(-qmp "unix:$QMP_SOCK,server,nowait")
    echo "QMP: $QMP_SOCK"
fi

# ---- 9p 共享（macOS 上 QEMU 的 virtfs local 可用，security_model=none）------
# 注意：macOS 下 9p host 性能一般且偶有兼容问题，若不稳可改用 SSHFS
# （guest 已开 sshd，转发在 2222）。guest 内挂载命令不变：
#   mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host
VIRTFS_ARGS=()
if [ "$VIRTFS" = "on" ]; then
    mkdir -p extracted/hostshare
    VIRTFS_ARGS=(-virtfs "local,path=extracted/hostshare,mount_tag=hostshare,security_model=none,id=hostshare0")
    echo "virtfs(9p): extracted/hostshare -> guest /mnt/host (mount_tag=hostshare)"
fi

# ---- 音频（macOS: CoreAudio，无 pulse 探测/无 pactl 解静音）-----------------
AUDIO_ARGS=(-audiodev none,id=snd0)
if [ "$AUDIO" != "off" ]; then
    AUDIO_ARGS=(-audiodev coreaudio,id=snd0)
    echo "audio: CoreAudio"
else
    echo "audio: 静音 (AUDIO=off)"
fi

echo "启动中（最长 ${DURATION}s$([ "$GUI" = "on" ] && echo "，GUI 窗口" || echo "，headless")）..."

# ---- QEMU（Intel Mac / HVF）------------------------------------------------
# 与 Linux 版差异仅：-enable-kvm -cpu host,migratable=off  ->  -accel hvf -cpu host
# 其余设备（sdhci/sd-card、virtio-blk、igb、qemu-xhci、AC97、hostfwd）跨平台一致。
# Stage 20.65：同 run_qemu_test.sh 的 CPU_STRIP_FLAGS——如果这台 Intel Mac 是
# iMac Pro/Mac Pro 那类带 AVX-512 的 Xeon-W，会透传出 Tesla 真机 CPU 不可能有
# 的扩展，触发 glibc ifunc 选路错误、chromium/ChromiumAdapter 在 minijail0 里
# 于 execve 前 #GP 崩溃循环，浏览器永远起不来，见 docs/47。普通消费级 Intel
# Mac（无 AVX-512）加这串裁剪项是无害的空操作。
CPU_STRIP_FLAGS="-avx512f,-avx512dq,-avx512ifma,-avx512cd,-avx512bw,-avx512vl,-avx512vbmi,-avx512vbmi2,-avx512vnni,-avx512bitalg,-avx512-vpopcntdq,-avx512-vp2intersect,-avx512-bf16,-avx-vnni,-amx-tile,-amx-bf16,-amx-int8"

QEMU_CMD=(qemu-system-x86_64 \
  -name "Tesla 2026 on QEMU (test)" -M q35 -cpu "host,${CPU_STRIP_FLAGS}" -accel hvf -m 8192 -smp "$SMP" \
  -kernel "$BZIMAGE" \
  -initrd "$INITRD" \
  -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clocksource=tsc tsc=reliable panic=1 $([ "$APPARMOR" = "1" ] && echo "security=apparmor apparmor=1" || echo "apparmor=0") intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000" \
  -device sdhci-pci -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  -drive if=virtio,file="$ROOTFS",format=raw,readonly=on \
  "${GPU_ARGS[@]}" \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp::2222-10.0.2.15:22 \
  -device igb,netdev=net0 \
  "${AUDIO_ARGS[@]}" -device AC97,audiodev=snd0 \
  "${TPM_ARGS[@]}" "${QMP_ARGS[@]}" "${VIRTFS_ARGS[@]}" \
  -serial file:"$SERIAL_LOG" "${TTYS1_ARGS[@]}" -no-reboot)

if [ "$TTYS1" = "on" ]; then
    trap - EXIT
    nohup "$TIMEOUT_BIN" "$DURATION" "${QEMU_CMD[@]}" > "$STDOUT_LOG" 2>&1 &
    echo "QEMU 已在后台启动，PID=$!，swtpm PID=$SWTPM_PID"
    echo "$! $SWTPM_PID" > logs/qemu_ttys1_${TS}.pids
else
    "$TIMEOUT_BIN" "$DURATION" "${QEMU_CMD[@]}" > "$STDOUT_LOG" 2>&1 || true
    echo "结束（超时被杀属正常）。"
    echo "查看日志: less $SERIAL_LOG"
fi
