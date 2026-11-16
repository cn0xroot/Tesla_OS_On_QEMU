#!/usr/bin/env bash
# ============================================================================
# run_qemu_web.sh  —  把 Tesla 2026 车机 GUI 通过浏览器（noVNC）显示
# ============================================================================
# 显示走 QEMU 内置 VNC + WebSocket（QEMU 8.2 原生支持 vnc 的 websocket= 选项，
# 不需要额外的 websockify 代理），浏览器端用 noVNC 静态页直连。
#
# 两种典型用法：
#   A. QEMU 跑这台 Linux，Mac / 手机 / 任何设备的浏览器远程看（推荐，Mac 上
#      连 QEMU 都不用装，也省去拷 60G 数据）。
#   B. QEMU 跑在 Intel Mac 本地，本机浏览器连 localhost。
# 加速后端按宿主自动探测：Linux -> KVM，macOS -> HVF。
#
# 依赖：
#   Linux: qemu-system-x86_64, python3, (TPM=on 时) swtpm
#   macOS: brew install qemu python3 coreutils swtpm
#   noVNC 静态页：vendor/noVNC/（本仓库已 clone；缺失时脚本给出拉取命令）
#
# 用法：
#   ./scripts/run_qemu_web.sh [duration_seconds]     # 默认 86000（长跑）
#   TPM=on ./scripts/run_qemu_web.sh
#   HTTP_PORT=8080 WS_PORT=6080 VNC_DISP=10 ./scripts/run_qemu_web.sh
#   VNC_PASSWORD=secret ./scripts/run_qemu_web.sh    # 给 VNC 设访问密码
#
# 停止：kill 掉打印出来的 QEMU / noVNC / swtpm PID（也写在 logs/web_*.pids）。
# ============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."          # -> .../Tesla/2026
PARENT="$(cd .. && pwd)"

# ---- 端口（避开本机 5900 上的 TigerVNC）------------------------------------
VNC_DISP="${VNC_DISP:-10}"        # VNC 传统端口 = 5900 + VNC_DISP = 5910
WS_PORT="${WS_PORT:-6080}"        # 浏览器用的 WebSocket 端口
HTTP_PORT="${HTTP_PORT:-6081}"    # 伺服 noVNC 静态页的 http 端口

# ---- 加速后端按宿主探测 -----------------------------------------------------
# Stage 20.65：-cpu host 会把宿主机 Ryzen 9950X 的 AVX-512/AMX 全家桶透传进
# guest，glibc 2.41 的 ifunc resolver 遇到这批 Tesla 真机不可能有的 CPUID
# 组合会选错实现，间接跳转落进 libc.so.6 的只读数据段，表现为
# "traps: minijail0[PID] general protection ... in libc.so.6" 崩溃循环——
# chromium/ChromiumAdapter 这类大量走 glibc ifunc 分发的动态 PIE 二进制稳定
# 命中，车机浏览器因此起不来。摘掉这批扩展逼 ifunc 落回真机也会走的 AVX2/SSE
# 实现，详见 docs/47、scripts/run_qemu_test.sh 同一处注释。
CPU_STRIP_FLAGS="-avx512f,-avx512dq,-avx512ifma,-avx512cd,-avx512bw,-avx512vl,-avx512vbmi,-avx512vbmi2,-avx512vnni,-avx512bitalg,-avx512-vpopcntdq,-avx512-vp2intersect,-avx512-bf16,-avx-vnni,-amx-tile,-amx-bf16,-amx-int8"

if [ "$(uname)" = "Darwin" ]; then
    ACCEL_ARGS=(-accel hvf -cpu host)
    AUDIODEV="coreaudio"
    command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout" || TIMEOUT_BIN="timeout"
else
    ACCEL_ARGS=(-enable-kvm -cpu "host,migratable=off,${CPU_STRIP_FLAGS}")   # 见主文档 Stage 20.55/20.65
    AUDIODEV="none"                                     # VNC 不传音频，默认静音
    TIMEOUT_BIN="timeout"
fi
command -v "$TIMEOUT_BIN" >/dev/null 2>&1 || { echo "缺少 $TIMEOUT_BIN（macOS: brew install coreutils）" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "缺少 qemu-system-x86_64" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "缺少 python3（伺服 noVNC 用）" >&2; exit 1; }

NOVNC_DIR="${NOVNC_DIR:-vendor/noVNC}"
if [ ! -f "$NOVNC_DIR/vnc.html" ]; then
    echo "缺少 noVNC 静态页：$NOVNC_DIR/vnc.html" >&2
    echo "拉取： git clone --depth 1 https://github.com/novnc/noVNC.git $NOVNC_DIR" >&2
    exit 1
fi

BZIMAGE="${KERNEL:-$PARENT/extracted/ias_a/bzImage_redirect_smp8_9p}"
INITRD="${INITRD:-extracted/initrd_ttys1fix.cpio.xz}"
OVERLAY="${OVERLAY:-extracted/overlay_2026.qcow2}"
ROOTFS="${ROOTFS:-extracted/rootfs_2026_current.squashfs}"
DURATION="${1:-86000}"
SMP="${SMP:-4}"
TPM="${TPM:-off}"
APPARMOR="${APPARMOR:-1}"
RES="${RES:-1920x1200}"
RES_X="${RES%x*}"; RES_Y="${RES#*x}"

TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p logs
SERIAL_LOG="logs/serial_web_${TS}.log"
STDOUT_LOG="logs/qemu_web_${TS}.log"
NOVNC_LOG="logs/novnc_${TS}.log"
PIDS_FILE="logs/web_${TS}.pids"

for f in "$BZIMAGE" "$INITRD" "$OVERLAY" "$ROOTFS"; do
    [ -f "$f" ] || { echo "缺少文件: $f"; exit 1; }
done

# ---- VNC 密码（可选）-------------------------------------------------------
# 给了 VNC_PASSWORD 就用 QMP secret 传入，避免明文进 ps；否则无密码（方便，
# 但意味着能连到 WS_PORT 的人都能操作，仅在可信网络里这样用）。
VNC_ARGS=()
if [ -n "${VNC_PASSWORD:-}" ]; then
    VNC_ARGS=(-object "secret,id=vncsec,data=$VNC_PASSWORD"
              -vnc ":$VNC_DISP,websocket=$WS_PORT,password-secret=vncsec")
    echo "VNC: 已设密码"
else
    VNC_ARGS=(-vnc ":$VNC_DISP,websocket=$WS_PORT")
    echo "VNC: 无密码（仅在可信网络使用；设 VNC_PASSWORD= 加密码）"
fi

# ---- swtpm ------------------------------------------------------------------
TPM_ARGS=(); SWTPM_PID=""
if [ "$TPM" = "on" ]; then
    command -v swtpm >/dev/null 2>&1 || { echo "缺少 swtpm" >&2; exit 1; }
    TPM_DIR="${TPM_STATE_DIR:-extracted/swtpm_state}"; mkdir -p "$TPM_DIR"
    SWTPM_SOCK="$TPM_DIR/swtpm-sock"
    swtpm socket --tpmstate dir="$TPM_DIR" --ctrl type=unixio,path="$SWTPM_SOCK" \
        --tpm2 --log file="logs/swtpm_${TS}.log",level=5 &
    SWTPM_PID=$!
    for i in $(seq 1 50); do [ -S "$SWTPM_SOCK" ] && break; sleep 0.1; done
    [ -S "$SWTPM_SOCK" ] || { echo "swtpm socket 未建立"; kill "$SWTPM_PID" 2>/dev/null||true; exit 1; }
    TPM_ARGS=(-chardev "socket,id=chrtpm,path=$SWTPM_SOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
    echo "TPM: 已挂 swtpm (pid=$SWTPM_PID)"
fi

# ---- 起 noVNC 静态服务 ------------------------------------------------------
python3 -m http.server "$HTTP_PORT" --directory "$NOVNC_DIR" >"$NOVNC_LOG" 2>&1 &
NOVNC_PID=$!

# 探测一个可展示给用户的本机 IP（远程访问用）
HOST_IP="$( (ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}') || true )"
[ -z "${HOST_IP:-}" ] && HOST_IP="$( (ipconfig getifaddr en0 2>/dev/null) || echo "<本机IP>")"
[ -z "${HOST_IP:-}" ] && HOST_IP="<本机IP>"

URL="http://${HOST_IP}:${HTTP_PORT}/vnc.html?host=${HOST_IP}&port=${WS_PORT}&autoconnect=true&resize=scale&reconnect=true"

echo "内核:  $BZIMAGE"
echo "rootfs: $ROOTFS"
echo "串口日志: $SERIAL_LOG"
echo "noVNC http: pid=$NOVNC_PID, 目录=$NOVNC_DIR, 端口=$HTTP_PORT"
echo
echo "==================== 浏览器打开 ===================="
echo "  $URL"
echo "  （本机测试可用 http://localhost:${HTTP_PORT}/vnc.html?host=localhost&port=${WS_PORT}&autoconnect=true&resize=scale ）"
echo "  UI 约需 3~4 分钟从冷启动到出画面；先连上会显示黑屏，属正常。"
echo "===================================================="
echo

# ---- QEMU -------------------------------------------------------------------
QEMU_CMD=(qemu-system-x86_64 \
  -name "Tesla 2026 on QEMU (web)" -M q35 "${ACCEL_ARGS[@]}" -m 8192 -smp "$SMP" \
  -kernel "$BZIMAGE" -initrd "$INITRD" \
  -append "console=ttyS0,115200n8 loglevel=8 ignore_loglevel clocksource=tsc tsc=reliable panic=1 $([ "$APPARMOR" = "1" ] && echo "security=apparmor apparmor=1" || echo "apparmor=0") intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000" \
  -device sdhci-pci -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  -drive if=virtio,file="$ROOTFS",format=raw,readonly=on \
  -device "virtio-vga,xres=$RES_X,yres=$RES_Y" "${VNC_ARGS[@]}" \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp::2222-10.0.2.15:22 -device igb,netdev=net0 \
  -audiodev "${AUDIODEV},id=snd0" -device AC97,audiodev=snd0 \
  "${TPM_ARGS[@]}" \
  -serial file:"$SERIAL_LOG" -no-reboot)

nohup "$TIMEOUT_BIN" "$DURATION" "${QEMU_CMD[@]}" >"$STDOUT_LOG" 2>&1 &
QEMU_PID=$!
echo "$QEMU_PID $NOVNC_PID $SWTPM_PID" > "$PIDS_FILE"
echo "QEMU pid=$QEMU_PID  noVNC pid=$NOVNC_PID  swtpm pid=${SWTPM_PID:-无}"
echo "停止： kill \$(cat $PIDS_FILE)"
