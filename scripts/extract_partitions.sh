#!/usr/bin/env bash
# 从 tesla_ROM1_*.bin 全量镜像中按 GPT 分区表提取各分区为独立文件。
# 基于 sfdisk 的 JSON 输出（精确到扇区，512B），避免字节偏移取整误差。
# 用法: ./extract_partitions.sh <image.bin> <out_dir>
set -euo pipefail

IMG="${1:?usage: extract_partitions.sh <image.bin> <out_dir>}"
OUT="${2:?usage: extract_partitions.sh <image.bin> <out_dir>}"
mkdir -p "$OUT"

SECTOR=512

sfdisk -d "$IMG" | grep '^.*: start=' | while read -r line; do
    dev=$(echo "$line" | awk -F: '{print $1}' | xargs)
    start=$(echo "$line" | grep -oP 'start=\s*\K[0-9]+')
    size=$(echo "$line" | grep -oP 'size=\s*\K[0-9]+')
    name=$(echo "$line" | grep -oP 'name="\K[^"]+' || echo "part_${dev##*[!0-9]}")
    idx=$(echo "$dev" | grep -oP '[0-9]+$')

    out_file="$OUT/part${idx}_${name}.img"
    echo "提取分区 $idx ($name): start=$start sectors, size=$size sectors -> $out_file"
    dd if="$IMG" of="$out_file" bs="$SECTOR" skip="$start" count="$size" status=progress
done
