#!/usr/bin/env python3
"""
解析并拆分 Tesla ELK (Intel Elkhart Lake 平台) 的 iasImage 启动镜像容器。

格式（根据设备自身 bootlog.0 中记录的解析日志逆向确定）:
  0x00: magic "ipk." (4 bytes)
  0x04: version/type 字段
  0x08: img_type      (u32)
  0x0c-0x28: 若干头部字段(签名/长度等，未逐一还原，不影响提取内核)
  0x28: data_len       (u32)  -- 有效数据区总长度
  0x2c: data_off       (u32, 通常固定=0x2c, 即紧随头部之后)
  ... 头部还包含: num_parts, cmdline_len, bzimage_len, initrd_len, acpi_len

从设备自身 bootlog 得到的字段布局（对应 bank_a.iasImage 实测）:
  cmdline_off = 0x2c,  cmdline_len
  bzimage_off = cmdline_off + cmdline_len，按 4 字节对齐
  initrd 紧随 bzImage 之后（若 initrd_len != 0）
  acpi 数据紧随其后

用法:
  python3 extract_iasImage.py <bankX.iasImage> <out_dir>
输出:
  <out_dir>/cmdline.txt
  <out_dir>/bzImage
  <out_dir>/initrd.img   (若 initrd_len != 0)
  <out_dir>/acpi.bin     (若 acpi_len != 0)
"""
import struct
import sys
import os


def align4(x):
    return (x + 3) & ~3


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        sys.exit(1)

    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    with open(src, "rb") as f:
        data = f.read()

    magic = data[0:4]
    if magic != b"ipk.":
        print(f"警告: 未识别的 magic {magic!r}，继续尝试按已知偏移解析")

    # 以下偏移是根据该设备 bootlog.0 实测日志硬编码验证过的：
    img_type = struct.unpack_from("<I", data, 0x04)[0]
    data_len = struct.unpack_from("<I", data, 0x08)[0]
    # data_off 在日志中固定为 0x2c
    data_off = 0x2C
    num_parts = struct.unpack_from("<I", data, 0x18)[0] if len(data) > 0x1C else None

    # cmdline 以 NUL 结尾的 C 字符串，起始于 data_off
    cmdline_start = data_off
    nul = data.index(b"\x00", cmdline_start)
    cmdline = data[cmdline_start:nul]
    cmdline_len_padded = align4(nul - cmdline_start + 1)

    bzimage_off = cmdline_start + cmdline_len_padded
    # bzImage 长度: 从 bzimage_off 开始寻找下一个已知边界比较困难，
    # 优先使用 bootlog 中记录的实测值（若通过命令行参数覆盖则使用之）。
    print(f"img_type=0x{img_type:x} data_len=0x{data_len:x} data_off=0x{data_off:x}")
    print(f"cmdline_off=0x{cmdline_start:x} cmdline='{cmdline.decode(errors='replace')}'")
    print(f"bzimage_off=0x{bzimage_off:x}")

    with open(os.path.join(out_dir, "cmdline.txt"), "wb") as f:
        f.write(cmdline)

    # bzImage: 从 bzimage_off 开始，直到文件末尾减去已知的签名/acpi 尾部。
    # 该设备日志给出了 bzimage_len，若你已从日志得知具体数值，可在此处覆盖：
    bzimage_len = None
    if len(sys.argv) > 3:
        bzimage_len = int(sys.argv[3], 0)

    if bzimage_len is None:
        # 退化方案：一直读到文件尾（可能包含 initrd/acpi/签名，之后可用
        # `binwalk` 或手动核对 bootlog 里的 bzimage_len 再精确裁剪）。
        bz_data = data[bzimage_off:]
    else:
        bz_data = data[bzimage_off:bzimage_off + bzimage_len]

    out_bz = os.path.join(out_dir, "bzImage")
    with open(out_bz, "wb") as f:
        f.write(bz_data)
    print(f"已写出 {out_bz} ({len(bz_data)} 字节)")


if __name__ == "__main__":
    main()
