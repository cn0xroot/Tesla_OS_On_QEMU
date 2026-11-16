#!/usr/bin/env bash
# 一键启动 2026 QEMU 车机 + 自动应用全部可用性修复
# (黑屏drive-rail / 鼠标点击touch / 地图透明代理 / BeeEye抓包)
# 详见 docs/51_qemu_usability_fixes.md
#
# rootfs 默认用 rootfs_2026_beeeye.squashfs(而不是 rootfs_2026_current.squashfs):
# 后者是 9/29 的旧快照,没有 check-lvm-parts 的 e2fsck -y cookie 保留补丁——用它跑的话,
# 一旦下次开机 check-lvm-parts 判定 /home 卷需要修复就会直接 mkfs.ext4 -F 重建,把
# chromium 的 Cookies(含 YouTube 登录态)连带清空。beeeye 镜像同时已把 BeeEye/
# touch-translate/qemu-fixes 三个 runit 服务烘焙成开机自启,不必每次靠下面的
# apply_all_fixes.sh 补一遍。
#
# 用法:  ./scripts/run_and_fix.sh [duration_seconds]
# 停止:  ./scripts/stop_gui.sh --all
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

KERNEL_DEFAULT="$ROOT/kernel-build/linux-amd-5.4/arch/x86/boot/bzImage"
KERNEL="${KERNEL:-$KERNEL_DEFAULT}"
ROOTFS="${ROOTFS:-extracted/rootfs_2026_beeeye.squashfs}"
SMP="${SMP:-8}"          # vCPU 数(2026-10-01 从 4 提到 8)
MEM="${MEM:-16384}"      # MiB(2026-10-01 从 8192 提到 16384)
DURATION="${1:-86400}"
SSH="ssh -i keys/qemu_ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -p 2222 root@127.0.0.1"

echo "==> 1/4 用内核启动 QEMU: $KERNEL"
echo "    rootfs: $ROOTFS (cookie 保留补丁 + BeeEye 开机自启已烘焙)"
echo "    CPU: ${SMP} 核  内存: ${MEM}MiB"
[ -f "$KERNEL" ] || { echo "内核不存在: $KERNEL"; exit 1; }
[ -f "$ROOTFS" ] || { echo "rootfs 不存在: $ROOTFS"; exit 1; }
KERNEL="$KERNEL" ROOTFS="$ROOTFS" SMP="$SMP" MEM="$MEM" GUI=on TPM=on VIRTFS=on TTYS1=on ./scripts/run_qemu_test.sh "$DURATION"

echo "==> 2/4 等待 guest SSH 就绪(首次启动含 fsck 可能 1-2 分钟)..."
for i in $(seq 1 60); do
  if $SSH 'echo ok' 2>/dev/null | grep -q ok; then echo "    SSH 就绪 (~$((i*4))s)"; break; fi
  sleep 4
done
$SSH 'echo ok' 2>/dev/null | grep -q ok || { echo "SSH 迟迟未就绪, 请手动检查"; exit 1; }

echo "==> 3/4 检查开机自启修复是否已生效..."
# beeeye rootfs 已把 qemu-fixes/touch-translate/beeeye 三个服务烘焙成开机自启(见
# docs/51 第9节), 裸启动即自带全部修复, 不需要再跑 apply_all_fixes.sh。
# 旧版 apply_all_fixes.sh 的"鼠标点击"那段会 pkill 掉 runit 托管的 touch-translate
# 再自己起一份不带 1920x1200 分辨率参数的副本, 跟自启服务抢同一个 usb-tablet 输入源、
# 各建一个 qemu-tablet-touch 虚拟设备, 坐标映射对不上导致点击失效——这是本项目
# 2026-10-01 实测到的真实故障, 千万不要在已自启的 rootfs 上再跑它。
if $SSH 'sv status qemu-fixes touch-translate beeeye 2>/dev/null | grep -c "^run:"' 2>/dev/null | grep -q '^3$'; then
  echo "    qemu-fixes / touch-translate / beeeye 已自启(3/3 running), 跳过 apply_all_fixes.sh"
else
  echo "    自启服务未就绪, 退回旧版 apply_all_fixes.sh 手动补(仅用于非 beeeye rootfs)"
  $SSH 'mkdir -p /mnt/host; mountpoint -q /mnt/host || mount -t 9p -o trans=virtio,version=9p2000.L,msize=262144 hostshare /mnt/host; sh /mnt/host/apply_all_fixes.sh 2>&1 | grep apply_all'
fi

echo "==> 4/4 完成。访问方式:"
cat <<'INFO'
    - 画面: 宿主 DISPLAY=:1 的 QEMU GTK 窗口(TigerVNC 可远程看/点)
    - SSH : ssh -i keys/qemu_ssh_key -p 2222 root@127.0.0.1
    - BeeEye 抓包: guest :8090 (web, /connections 是抓包页) / :8453 (MITM) —— 已开机自启
    - 停止: ./scripts/stop_gui.sh --all (sync 保 cookie, 见 stop_gui.sh 注释)
    修复项: 黑屏(drive-rail) / 鼠标点击(虚拟触摸屏) / 地图(透明代理) / 浏览器(veth+MASQUERADE内核) /
            BeeEye开机自启 / Cookie持久(check-lvm-parts e2fsck -y 保留 /home)
INFO
