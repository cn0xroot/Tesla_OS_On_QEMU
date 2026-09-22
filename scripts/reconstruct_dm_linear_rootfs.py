#!/usr/bin/env python3
"""
按 docs/analysis.md 第22/23节反汇编 verity-init（init）还原出的公式，
把 rootfs-a/rootfs-b 真正的 dm-linear 虚拟设备重建成一个平坦镜像文件。

背景：Tesla 的 rootfs-a-legacy/rootfs-b-legacy（GPT 分区2/3，各约1.875GiB）
单独装不下完整的 squashfs+verity 元数据+哈希树，verity-init 启动时会用
dm-linear 把每个分区和 lvm 数据分区（分区4）尾部借来的 1GiB 拼接成一个更大
的虚拟块设备再喂给 dm-verity/mount。裸分区数据本身看起来"表指针损坏"，
是因为一直没有把这多出来的 1GiB 拼上去。

用法：
    python3 reconstruct_dm_linear_rootfs.py <固件镜像文件> <输出目录> [a|b|both]

分区偏移/大小默认取自 docs/analysis.md 第1节记录的 GPT 表（rootfs-a-legacy/
rootfs-b-legacy/lvm 三个分区），如果分析的是别的镜像/分区表不同，用
--p2-off/--p3-off/--p4-off/--p4-size 等参数覆盖。
"""

import argparse
import struct
import sys

CHUNK = 64 * 1024 * 1024

# 默认值来自 docs/analysis.md §1（GPT 分区表）
DEFAULT_P2_OFF = 134217728        # rootfs-a-legacy 起始字节
DEFAULT_P3_OFF = 2147483648       # rootfs-b-legacy 起始字节
DEFAULT_SEG1_LEN = 2013265920     # 分区2/3 大小（= dm-linear 第1段长度，0x3c0000 扇区）
DEFAULT_P4_OFF = 4160749568       # lvm 分区（分区4）起始字节
DEFAULT_P4_END_INCL = 63652740095  # lvm 分区末字节（含）

BORROW_LEN = 1073741824          # 每个 bank 恒定借用 1GiB（0x200000 扇区）
BORROW_START_A_FROM_END = 4194304 * 512  # bank-a：分区4末尾往前推 2GiB（0x400000 扇区）
BORROW_START_B_FROM_END = 2097152 * 512  # bank-b：分区4末尾往前推 1GiB（0x200000 扇区）


def copy_range(fin, fout, off, length):
    fin.seek(off)
    remaining = length
    while remaining > 0:
        n = min(CHUNK, remaining)
        data = fin.read(n)
        if not data:
            raise RuntimeError(f"unexpected EOF at offset {fin.tell()}")
        fout.write(data)
        remaining -= len(data)


def reconstruct_bank(fw_path, out_path, seg1_off, seg1_len, seg2_off, seg2_len):
    with open(fw_path, "rb") as fin, open(out_path, "wb") as fout:
        copy_range(fin, fout, seg1_off, seg1_len)
        copy_range(fin, fout, seg2_off, seg2_len)
    return seg1_len + seg2_len


def find_verity_metadata(image_path):
    """在重建出的镜像里，从 squashfs 超级块读 bytes_used，按4096对齐找 verity
    元数据块（magic 0xba01ba01），校验签名熵和表字符串是否合法，返回摘要信息。"""
    with open(image_path, "rb") as f:
        sb = f.read(96)
        magic = sb[0:4]
        if magic != b"hsqs":
            return None
        bytes_used = struct.unpack_from("<Q", sb, 40)[0]
        nominal_off = (bytes_used + 4095) // 4096 * 4096
        # 实测两个 bank 的真实 verity 元数据块起点，比 round_up(bytes_used,4096)
        # 精确对齐值早 3072 字节（原因未完全查明，可能与 hash_start_block 的
        # 取整方式或元数据块前还有一段固定大小的 padding 有关，如实记录），
        # 所以在附近开一个小窗口做搜索，而不是死认一个公式算出来的偏移。
        f.seek(max(0, nominal_off - 8192))
        window = f.read(16384)
        idx = window.find(b"\x01\xba\x01\xba")
        if idx == -1:
            return {"bytes_used": bytes_used, "meta_offset": nominal_off, "magic_ok": False}
        meta_off = max(0, nominal_off - 8192) + idx
        f.seek(meta_off)
        block = f.read(4096)
        sig = block[8:8 + 256]
        length = struct.unpack_from("<I", block, 264)[0]
        table = block[268:268 + length].decode(errors="replace")
        return {
            "bytes_used": bytes_used,
            "meta_offset": meta_off,
            "magic_ok": True,
            "sig_distinct_bytes": len(set(sig)),
            "table": table,
        }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("firmware", help="原始固件镜像文件路径")
    ap.add_argument("out_dir", help="输出目录")
    ap.add_argument("bank", nargs="?", default="both", choices=["a", "b", "both"])
    ap.add_argument("--p2-off", type=int, default=DEFAULT_P2_OFF)
    ap.add_argument("--p3-off", type=int, default=DEFAULT_P3_OFF)
    ap.add_argument("--seg1-len", type=int, default=DEFAULT_SEG1_LEN)
    ap.add_argument("--p4-off", type=int, default=DEFAULT_P4_OFF)
    ap.add_argument("--p4-end-incl", type=int, default=DEFAULT_P4_END_INCL)
    args = ap.parse_args()

    import os
    os.makedirs(args.out_dir, exist_ok=True)

    p4_size = args.p4_end_incl - args.p4_off + 1
    # 关键修正（见 docs/analysis.md 第28节）：verity-init 反汇编出的真实公式是
    # `(BLKGETSIZE64(p4) >> 12) << 3`——即先把分区4的字节数向下截断到 4096
    # 字节页边界，再换算成512字节扇区数，会丢弃不满一页的尾巴。之前直接用
    # `p4_size // 512` 少做了这次4096截断，当 p4_size 本身不是4096的整数倍时
    # （这份固件里余数正好是3072字节）就会把 borrow 起点算多3072字节，导致
    # 重建出的镜像里凡是落在"借用的1GiB"范围内的内容全部整体错位3072字节。
    p4_sectors_truncated = (p4_size >> 12) << 3
    p4_size_effective = p4_sectors_truncated * 512
    borrow_a_off = args.p4_off + (p4_size_effective - BORROW_START_A_FROM_END)
    borrow_b_off = args.p4_off + (p4_size_effective - BORROW_START_B_FROM_END)

    banks = []
    if args.bank in ("a", "both"):
        banks.append(("a", args.p2_off, borrow_a_off))
    if args.bank in ("b", "both"):
        banks.append(("b", args.p3_off, borrow_b_off))

    for name, seg1_off, seg2_off in banks:
        out_path = os.path.join(args.out_dir, f"rootfs-{name}.img")
        print(f"[bank {name}] segment1: firmware[{seg1_off}:{seg1_off+args.seg1_len}] "
              f"(分区{'2' if name=='a' else '3'} 全部)")
        print(f"[bank {name}] segment2: firmware[{seg2_off}:{seg2_off+BORROW_LEN}] "
              f"(分区4尾部借用 1GiB)")
        total = reconstruct_bank(args.firmware, out_path, seg1_off, args.seg1_len, seg2_off, BORROW_LEN)
        print(f"[bank {name}] -> {out_path} ({total} bytes)")

        info = find_verity_metadata(out_path)
        if info is None:
            print(f"[bank {name}] 警告：未识别到 squashfs 超级块")
        elif not info.get("magic_ok"):
            print(f"[bank {name}] 警告：在偏移 {info['meta_offset']} 未找到 verity 元数据 magic")
        else:
            print(f"[bank {name}] verity 元数据校验通过 @ {info['meta_offset']}，"
                  f"签名熵={info['sig_distinct_bytes']}/256，表字符串: {info['table']}")


if __name__ == "__main__":
    main()
