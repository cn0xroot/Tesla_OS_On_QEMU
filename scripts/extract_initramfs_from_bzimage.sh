#!/bin/bash
# 从 Tesla iasImage 提取出的 bzImage 中，把编译进内核里的 initramfs（cpio.lz4）解出来。
#
# 原理：
#   1. Tesla 内核配置 CONFIG_INITRAMFS_SOURCE="${BR_BINARIES_DIR}/initramfs.cpio.lz4"
#      （由 ikconfig 提取确认，见 docs/analysis.md 第21节），initramfs 在编译期被
#      内核构建系统压缩后直接链接进 vmlinux 的 .init.data 段，运行时由内核自解压。
#   2. 用标准内核脚本 scripts/extract-vmlinux 把裸 vmlinux ELF 从 bzImage 里还原出来
#      （随便一个 linux-headers 包里都有这个脚本，不需要 Tesla 专属工具）。
#   3. 用 objcopy 把 .init.data 段整段导出成裸二进制。
#   4. 在这段数据里搜索 LZ4 legacy frame magic（小端字节序 02 21 4C 18，即
#      0x184C2102），从这个偏移开始就是被 CONFIG_INITRAMFS_COMPRESSION=".lz4"
#      压缩后的 cpio 归档，一直到 .init.data 段结尾（含少量尾部 padding）。
#   5. 用 `lz4 -d` 解压。因为末尾有内核链接脚本插入的对齐 padding，lz4 在处理完
#      真正的数据后会因为尾部垃圾字节报 "Corrupted input detected"——这是预期的，
#      不代表提取失败：只要看 `file` 输出已经是 "ASCII cpio archive" 即说明真正
#      的归档内容已经完整解压出来了（可以直接用 cpio -idm 展开验证）。
#
# 用法：
#   ./extract_initramfs_from_bzimage.sh <bzImage文件> <输出目录>
#
# 输出目录下会生成：
#   vmlinux.elf              还原出的裸内核 ELF
#   init_data.bin            .init.data 段原始内容
#   initramfs.cpio.lz4       切出来的压缩 initramfs
#   initramfs.cpio           解压后的 cpio 归档
#   rootfs/                  cpio 展开后的完整 initramfs 文件树（含 verity-init /
#                            dmsetup / libtesla-verity.so 等真实 Tesla 二进制）

set -euo pipefail

BZIMAGE="${1:?用法: $0 <bzImage文件> <输出目录>}"
OUTDIR="${2:?用法: $0 <bzImage文件> <输出目录>}"

EXTRACT_VMLINUX="$(find /usr/src /root /home -maxdepth 6 -iname extract-vmlinux 2>/dev/null | head -1)"
if [ -z "$EXTRACT_VMLINUX" ]; then
    echo "找不到 scripts/extract-vmlinux，请安装任意一个 linux-headers 包" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
cd "$OUTDIR"

echo "[1/5] 还原 vmlinux ELF ..."
"$EXTRACT_VMLINUX" "$BZIMAGE" > vmlinux.elf

echo "[2/5] 导出 .init.data 段 ..."
objcopy -O binary --only-section=.init.data vmlinux.elf init_data.bin

echo "[3/5] 搜索 LZ4 legacy magic 并切出压缩 initramfs ..."
python3 - "$PWD/init_data.bin" "$PWD/initramfs.cpio.lz4" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
magic = b'\x02\x21\x4c\x18'  # LZ4 legacy frame magic, 0x184C2102 小端
idx = data.find(magic)
if idx < 0:
    sys.exit("未找到 LZ4 legacy magic，该内核可能未内嵌 initramfs 或压缩方式不同")
print(f"  找到偏移 0x{idx:x}")
open(sys.argv[2], 'wb').write(data[idx:])
PYEOF

echo "[4/5] lz4 解压（结尾报 Corrupted input 是预期的 padding 噪声，可忽略）..."
lz4 -d -f initramfs.cpio.lz4 initramfs.cpio || true
file initramfs.cpio

echo "[5/5] 展开 cpio 归档到 rootfs/ ..."
mkdir -p rootfs
( cd rootfs && cpio -idm < ../initramfs.cpio )

echo "完成。initramfs 文件树位于: $OUTDIR/rootfs/"
