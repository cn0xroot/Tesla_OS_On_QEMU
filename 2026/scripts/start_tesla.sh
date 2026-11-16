#!/usr/bin/env bash
# ============================================================================
# Tesla 2026 QEMU 车机 —— 一键启动(全自动修复版)
# ============================================================================
# 用全部修复已烘焙进 rootfs 的镜像启动, 开机自动生效, 无需任何手动操作:
#   • 黑屏      : qemu-fixes 服务自动设 drive-rail DV
#   • 鼠标点击  : touch-translate 监管服务(usb-tablet -> 虚拟触摸屏 BTN_TOUCH)
#   • 地图      : tsocks-relay 透明代理自启(经宿主 Clash 出网)
#   • 浏览器    : chromium netns MASQUERADE/转发自动配好(可开 YouTube 并保持登录)
#   • BeeEye    : 抓包工具自启, web :8090 (/connections 抓包页) / MITM :8453
#   • Cookie持久: check-lvm-parts 用 e2fsck -y 保留 /home(登录不丢)
#
# 详见 docs/51_qemu_usability_fixes.md
#
# 用法:
#   ./scripts/start_tesla.sh            # 启动(默认长跑 24h)
#   ./scripts/start_tesla.sh 3600       # 只跑 1 小时
#   ./scripts/stop_tesla.sh             # 干净停止(sync 保 cookie) —— 或 stop_gui.sh --all
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

KERNEL="${KERNEL:-$ROOT/kernel-build/linux-amd-5.4/arch/x86/boot/bzImage}"
ROOTFS="${ROOTFS:-extracted/rootfs_2026_beeeye.squashfs}"
DURATION="${1:-86400}"
SSH="ssh -i keys/qemu_ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -p 2222 root@127.0.0.1"

echo "==================================================================="
echo " Tesla 2026 QEMU 一键启动(全自动修复版)"
echo "==================================================================="
[ -f "$KERNEL" ] || { echo "✗ 内核不存在: $KERNEL"; exit 1; }
[ -f "$ROOTFS" ] || { echo "✗ rootfs 不存在: $ROOTFS"; exit 1; }

# 若已有实例在跑, 先干净停(sync 保 cookie)
if pgrep -f 'qemu-system-x86_64 -name Tesla 2026' >/dev/null 2>&1; then
  echo "==> 检测到已有实例, 先干净停止..."
  ./scripts/stop_gui.sh --all >/dev/null 2>&1 || true
  sleep 2
fi

echo "==> 启动 QEMU"
echo "    内核  : $KERNEL"
echo "    rootfs: $ROOTFS  (全部修复已烘焙)"
KERNEL="$KERNEL" ROOTFS="$ROOTFS" GUI=on TPM=on VIRTFS=on TTYS1=on \
  ./scripts/run_qemu_test.sh "$DURATION"

echo "==> 等待 guest 启动就绪(首次启动含 fsck, 约 1-2 分钟)..."
ok=0
for i in $(seq 1 60); do
  if $SSH 'echo ok' 2>/dev/null | grep -q ok; then ok=1; echo "    SSH 就绪 (~$((i*4))s)"; break; fi
  sleep 4
done
if [ "$ok" != 1 ]; then echo "⚠ SSH 迟迟未就绪, 请稍等或查 logs/serial_*.log"; exit 0; fi

# 等修复服务把 drive-rail 设好(显示点亮), 最多 ~40s
echo "==> 等待自动修复生效(drive-rail / 触摸 / BeeEye)..."
for i in $(seq 1 20); do
  st=$($SSH 'dbus-send --system --print-reply --dest=com.tesla.VehicleService /LocalDataValue com.tesla.LocalDataValue.DataGetValueRequest string:VAPI_driveRailOn 2>/dev/null | grep string | tail -1' 2>/dev/null || true)
  echo "$st" | grep -q '"true"' && { echo "    ✓ drive-rail 已设(显示点亮)"; break; }
  sleep 3
done

echo "==================================================================="
echo " ✓ 启动完成"
echo "==================================================================="
$SSH 'echo "  修复服务: $(sv status qemu-fixes touch-translate beeeye tsocks-relay 2>/dev/null | grep -c "^run:")/4 running"; echo "  BeeEye  : $(ss -tlnp 2>/dev/null | grep -q :8090 && echo 已监听 :8090 || echo 未起)"' 2>/dev/null || true
cat <<'INFO'
  ------------------------------------------------------------------
  画面 : 宿主 DISPLAY=:1 的 QEMU 窗口(TigerVNC 可远程看/点)
  SSH  : ssh -i keys/qemu_ssh_key -p 2222 root@127.0.0.1
  BeeEye 抓包(guest 浏览器内打开): http://10.0.2.15:8090/connections
  浏览器: Tesla UI 里的浏览器 app, 可开网页并保持登录(cookie 已持久)
  停止 : ./scripts/stop_tesla.sh   (会 sync 保留 cookie)
  ------------------------------------------------------------------
INFO
