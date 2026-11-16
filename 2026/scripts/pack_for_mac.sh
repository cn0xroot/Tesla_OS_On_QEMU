#!/usr/bin/env bash
# ============================================================================
# pack_for_mac.sh  —  在 Linux 端把 2026 项目打包成 Intel Mac 可直接运行的一份 dist
# ============================================================================
# 解决两个搬到 Mac 会踩的坑：
#   1. overlay_2026.qcow2 backing 到 59G 的 tesla_ROM1_*.bin，且是绝对路径
#      <home>/... —— 拷到 Mac 后 backing file 找不到，无法启动。
#   2. 内核在上级 extracted/，rootfs/initrd 在 2026/extracted/，跨两层目录。
#
# 本脚本用 qemu-img convert 把 overlay+backing 压平成一个自包含、带压缩的
# qcow2（无 backing 依赖），再把内核/initrd/rootfs/脚本收进一个平铺的
# tesla2026_mac_dist/ 目录，拷到 Mac 解开即可用 run_qemu_test_mac.sh 启动。
#
# 用法:
#   ./scripts/pack_for_mac.sh [输出目录]     # 默认 ../tesla2026_mac_dist
#   COMPRESS=off ./scripts/pack_for_mac.sh   # 不压缩（更快但更大，约 59G）
# ============================================================================

set -euo pipefail
cd "$(dirname "$0")/.."          # -> .../Tesla/2026
PARENT="$(cd .. && pwd)"

OUT="${1:-$PARENT/tesla2026_mac_dist}"
COMPRESS="${COMPRESS:-on}"

KERNEL="$PARENT/extracted/ias_a/bzImage_redirect_smp8_9p"
INITRD="extracted/initrd_ttys1fix.cpio.xz"
ROOTFS="extracted/rootfs_2026_current.squashfs"
OVERLAY="extracted/overlay_2026.qcow2"

for f in "$KERNEL" "$INITRD" "$ROOTFS" "$OVERLAY"; do
    [ -f "$f" ] || { echo "缺少文件: $f" >&2; exit 1; }
done
command -v qemu-img >/dev/null 2>&1 || { echo "缺少 qemu-img" >&2; exit 1; }

echo "输出目录: $OUT"
mkdir -p "$OUT/extracted/ias_a" "$OUT/scripts"

echo "[1/4] 压平 overlay + 59G ROM backing -> 自包含 qcow2（compress=$COMPRESS，耗时较长）..."
CONV_OPTS=(-O qcow2)
[ "$COMPRESS" = "off" ] || CONV_OPTS+=(-c)
qemu-img convert -p "${CONV_OPTS[@]}" "$OVERLAY" "$OUT/extracted/overlay_2026.qcow2"
qemu-img info "$OUT/extracted/overlay_2026.qcow2" | grep -E "backing file|disk size" || true

echo "[2/4] 复制内核 / initrd / rootfs ..."
cp -v "$KERNEL" "$OUT/extracted/ias_a/"
cp -v "$INITRD" "$OUT/extracted/"
cp -v "$ROOTFS" "$OUT/extracted/"

echo "[3/4] 复制脚本 + swtpm 初始状态 ..."
cp -v scripts/run_qemu_test_mac.sh "$OUT/scripts/"
for aux in scripts/ttys1_probe.py scripts/ttys1_upload.py scripts/ssh_qemu.sh; do
    [ -f "$aux" ] && cp -v "$aux" "$OUT/scripts/"
done
# swtpm 状态：给一份空目录即可，首启会重新初始化（真机 TPM 密封密钥本就无法带出，
# 加密数据分区在任何虚拟机里都解不开，只跑只读 rootfs+overlay）。
mkdir -p "$OUT/extracted/swtpm_state"

# Mac 端修正：内核路径。Mac 脚本用 $PARENT/extracted/ias_a/，而 dist 是平铺的，
# 令 dist 根 = 脚本的 PARENT。dist/2026 作为脚本工作目录的软链，保持相对结构。
echo "[4/4] 搭 Mac 端目录结构 ..."
mkdir -p "$OUT/2026"
ln -sfn ../extracted "$OUT/2026/extracted"
ln -sfn ../scripts   "$OUT/2026/scripts"
# 让 Mac 上： cd tesla2026_mac_dist/2026 && ./scripts/run_qemu_test_mac.sh
# 时，$PARENT=tesla2026_mac_dist、$PARENT/extracted/ias_a/bzImage... 命中，
# 且 extracted/、scripts/ 经软链指向平铺实体。

cat > "$OUT/README_MAC.txt" <<'EOF'
Intel Mac 运行步骤
==================
1. 一次性安装依赖：
     brew install qemu swtpm coreutils
2. 进入 2026 子目录并启动（headless 冒烟）：
     cd 2026
     ./scripts/run_qemu_test_mac.sh 180
   带 GUI 窗口 + TPM：
     TPM=on GUI=on ./scripts/run_qemu_test_mac.sh 600
3. SSH 进 guest（另开终端）：
     ssh -p 2222 root@localhost      # 或用 scripts/ssh_qemu.sh
4. 串口日志在 2026/logs/serial_*.log。

说明：overlay 已压平为自包含镜像，无需 59G 原始 ROM。
EOF

echo
echo "完成。dist 大小："
du -sh "$OUT"
echo "拷到 Mac 后： cd $(basename "$OUT")/2026 && ./scripts/run_qemu_test_mac.sh 180"
