#!/usr/bin/env python3
# Copyright (C) 2026 cn0xroot
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
"""
tesla_fw.py —— Tesla 固件解包 / 改包(patch) / QEMU 运行 一体化项目工具。

这是对仓库里原本分散的一批脚本（extract_iasImage.py、
reconstruct_dm_linear_rootfs.py、run_qemu*.sh、ssh_qemu.sh 等）的统一调度
入口，把 docs/firmware_unpacking_reproduction.md 里记录的完整手工操作流程
封装成可重复执行的子命令。不重新发明底层逻辑——每个子命令要么直接调用
已验证有效的原始脚本，要么按文档里还原出的公式/格式实现原本只存在于
文档里、磁盘上还没有对应脚本的那部分（custom_init 编译打包、squashfs
重打包）。

用法总览：
    tesla_fw.py unpack       ...   固件解包全流程（分区表 -> iasImage ->
                                    dm-linear 重建 -> unsquashfs）
    tesla_fw.py unpack-part  ...   仅按 GPT 分区表提取各分区
    tesla_fw.py unpack-initramfs ...  从 bzImage 里抠出编译进内核的 initramfs
    tesla_fw.py patch build-init  ... 编译绕过 dm-verity 签名校验的精简 init
    tesla_fw.py patch repack ...   把改过的 rootfs 目录重新打包成 squashfs
    tesla_fw.py patch legacy-tables ... （已废弃，仅存档）旧的 squashfs 表指针补丁
    tesla_fw.py run           ...  启动 QEMU（headless/ui/gdb/glamor 四种模式）
    tesla_fw.py ssh            ... 一键 SSH 进正在跑的 QEMU 客户机
    tesla_fw.py focus          ... 修复宿主机 QEMU 窗口抢不到输入焦点的问题
    tesla_fw.py capture        ... 客户机内抓包，流回宿主机保存为 pcap

每个子命令都有自己的 -h/--help，具体参数见对应函数。

重要：本工具只操作你本地提供的固件镜像/已解包数据，不在仓库里附带、也
不会自动下载任何固件二进制/密钥/抓包数据——这些都属于应在 .gitignore 里
排除的敏感数据，见仓库根目录 .gitignore 的说明。
"""
import argparse
import os
import shutil
import subprocess
import struct
import sys
import tempfile
import textwrap

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")


def sh(cmd, **kw):
    """打印后执行一条命令（list 形式），沿用调用方 cwd 除非显式传 cwd。"""
    print("+ " + " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, **kw)


def script_path(name):
    p = os.path.join(SCRIPTS_DIR, name)
    if not os.path.exists(p):
        sys.exit(f"缺少依赖脚本: {p}")
    return p


# ----------------------------------------------------------------------
# unpack：固件解包全流程
# ----------------------------------------------------------------------
def cmd_unpack(args):
    """
    完整复现 docs/firmware_unpacking_reproduction.md 第11节"复现速查表"：
      1. 打印 GPT 分区表（仅供人工核对，不影响后续步骤）
      2. 提取 iasImage 中的内核（extract_iasImage.py）
      3. 按 dm-linear 拼接公式重建完整 rootfs（reconstruct_dm_linear_rootfs.py）
      4. 用标准 unsquashfs 解包出根文件系统
      5. （可选）创建 QEMU 用的 qcow2 写时复制覆盖层
    """
    image = args.image
    if not os.path.isfile(image):
        sys.exit(f"固件镜像不存在: {image}")
    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)

    if not args.skip_partition_table:
        print("\n==== [1/5] 分区表（仅供核对） ====")
        try:
            sh(["fdisk", "-l", image])
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            print(f"(fdisk 不可用或失败，跳过: {e})")

    ias_dir = os.path.join(outdir, f"ias_{args.bank if args.bank != 'both' else 'a'}")
    if args.ias_image:
        print("\n==== [2/5] 提取 iasImage 内核 ====")
        os.makedirs(ias_dir, exist_ok=True)
        cmd = [sys.executable, script_path("extract_iasImage.py"), args.ias_image, ias_dir]
        if args.bzimage_len:
            cmd.append(args.bzimage_len)
        sh(cmd)
    else:
        print("\n==== [2/5] 跳过 iasImage 提取（未提供 --ias-image） ====")

    print("\n==== [3/5] 重建 dm-linear 拼接后的完整 rootfs 镜像 ====")
    recon_dir = os.path.join(outdir, "rootfs_reconstructed")
    cmd = [sys.executable, script_path("reconstruct_dm_linear_rootfs.py"),
           image, recon_dir, args.bank]
    for flag, val in (("--p2-off", args.p2_off), ("--p3-off", args.p3_off),
                       ("--seg1-len", args.seg1_len), ("--p4-off", args.p4_off),
                       ("--p4-end-incl", args.p4_end_incl)):
        if val is not None:
            cmd += [flag, str(val)]
    sh(cmd)

    if args.skip_unsquashfs:
        print("\n==== [4/5] 跳过 unsquashfs（--skip-unsquashfs） ====")
    else:
        print("\n==== [4/5] 标准 unsquashfs 解包 ====")
        for bank in (["a", "b"] if args.bank == "both" else [args.bank]):
            img = os.path.join(recon_dir, f"rootfs-{bank}.img")
            if not os.path.isfile(img):
                print(f"(跳过 {img}：不存在)")
                continue
            dest = os.path.join(recon_dir, f"squashfs-root-{bank}")
            sh(["unsquashfs", "-d", dest, "-f", img])
            print(f"bank {bank} 解包完成 -> {dest}")

    if args.make_overlay:
        print("\n==== [5/5] 创建 QEMU qcow2 覆盖层（原始镜像全程只读） ====")
        overlay = args.overlay_out or os.path.join(outdir, "overlay.qcow2")
        if os.path.exists(overlay):
            print(f"(已存在，跳过: {overlay})")
        else:
            sh(["qemu-img", "create", "-f", "qcow2", "-b", os.path.abspath(image),
                "-F", "raw", overlay])
            sh(["qemu-img", "resize", overlay, "64G"])
        print(f"覆盖层就绪: {overlay}")
    else:
        print("\n==== [5/5] 跳过 QEMU 覆盖层创建（加 --make-overlay 开启） ====")

    print("\n解包流程结束。")


def cmd_unpack_part(args):
    """按 GPT 分区表把各分区提取为独立文件（包 extract_partitions.sh）。"""
    sh(["bash", script_path("extract_partitions.sh"), args.image, args.outdir])


def cmd_unpack_initramfs(args):
    """从 bzImage 中抠出编译进内核的 initramfs（包 extract_initramfs_from_bzimage.sh）。"""
    sh(["bash", script_path("extract_initramfs_from_bzimage.sh"), args.bzimage, args.outdir])


# ----------------------------------------------------------------------
# patch：修改固件内容 + 绕过 dm-verity 签名校验
# ----------------------------------------------------------------------
CUSTOM_INIT_SRC = os.path.join(SCRIPTS_DIR, "custom_init.c")


def cmd_patch_build_init(args):
    """
    编译 custom_init.c（docs/firmware_unpacking_reproduction.md 第9节描述的、
    绕过 dm-verity 签名校验的精简替代 init），静态链接后打包成最小 initrd
    （仅含这一个 /init 文件），用于给改过内容的 squashfs 提供一条不受
    verity 签名限制的启动路径。
    """
    if not os.path.isfile(CUSTOM_INIT_SRC):
        sys.exit(f"缺少源码: {CUSTOM_INIT_SRC}")
    os.makedirs(args.outdir, exist_ok=True)
    binpath = os.path.join(args.outdir, "custom_init")

    print("==== 静态编译 custom_init ====")
    sh(["gcc", "-static", "-O2", "-Wall", "-o", binpath, CUSTOM_INIT_SRC])

    print("==== 打包最小 initrd（仅含 /init） ====")
    initrd_path = args.initrd_out or os.path.join(args.outdir, "initrd_custom.cpio.gz")
    with tempfile.TemporaryDirectory() as td:
        shutil.copy2(binpath, os.path.join(td, "init"))
        os.chmod(os.path.join(td, "init"), 0o755)
        find = subprocess.run(["find", "."], cwd=td, capture_output=True, text=True, check=True)
        cpio = subprocess.Popen(["cpio", "-o", "-H", "newc"], cwd=td,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        gzip = subprocess.Popen(["gzip", "-9"], stdin=cpio.stdout,
                                 stdout=open(initrd_path, "wb"))
        cpio.stdin.write(find.stdout.encode())
        cpio.stdin.close()
        cpio.wait()
        gzip.wait()
    print(f"initrd 已生成: {initrd_path}")
    print("用法：把它作为 -initrd 传给 QEMU（参考 tesla_fw.py run --help），"
          "并给内核 cmdline 按需加 patchroot=/dev/vda 指定根设备"
          "（不加则默认 /dev/vda）。")


def cmd_patch_repack(args):
    """把（人工或脚本）改过的 rootfs 目录重新打包成 squashfs 镜像。

    默认压缩参数（lz4, block_size=131072）对齐原始固件参数（见
    docs/firmware_unpacking_reproduction.md 6.8 节 unsquashfs -stat 结果），
    仅供走 custom_init 绕过 verity 这条路径启动用；不会、也不可能让改过的
    内容重新通过 Tesla 官方的 dm-verity RSA 签名校验。
    """
    if not os.path.isdir(args.rootfs_dir):
        sys.exit(f"目录不存在: {args.rootfs_dir}")
    cmd = ["mksquashfs", args.rootfs_dir, args.out, "-noappend",
           "-comp", args.comp, "-b", str(args.block_size)]
    if args.no_xattrs:
        cmd.append("-no-xattrs")
    sh(cmd)
    print(f"重打包完成: {args.out}")


def cmd_patch_legacy_tables(args):
    """（已废弃，仅存档）尝试静态修补 squashfs 辅助表指针，让主线 unsquashfs
    通过超级块校验。docs/firmware_unpacking_reproduction.md 第6节记录了
    根因其实是 dm-linear 重建脚本的位运算截断漏洞，修好之后走标准
    unsquashfs 即可零补丁解包成功——这条路线已被证实不再必要，保留只为
    存档历史调试过程，正常流程不要用它。"""
    print("!! 警告：这是已废弃的路线，正常解包流程用 `tesla_fw.py unpack` 即可，"
          "不需要这个补丁。仅为存档历史调试过程保留。", file=sys.stderr)
    if not args.yes:
        resp = input("确认仍要继续吗？[y/N] ")
        if resp.strip().lower() != "y":
            sys.exit("已取消")
    sh([sys.executable, script_path("patch_squashfs_tables.py"), args.squashfs])


# ----------------------------------------------------------------------
# run：QEMU 启动调度（统一封装 run_qemu*.sh / run_v62_glamor.sh）
# ----------------------------------------------------------------------
RUN_MODE_SCRIPTS = {
    "headless": "run_qemu.sh",   # 默认模式，自动超时退出，无图形界面
    "ui": "run_qemu_ui.sh",      # 日常交互用，开 GUI 窗口，手动关闭
    "gdb": "run_qemu_gdb.sh",    # 附加内核态/用户态 GDB 调试
    "glamor": "run_v62_glamor.sh",  # 完整渲染 + 流畅图形栈（v62 移植版）
}


def cmd_run(args):
    """启动 QEMU。--mode 对应仓库里原本四个独立脚本，这里只是统一入口，
    不改变它们各自的行为（各模式的详细说明见对应脚本头部注释）。"""
    script = RUN_MODE_SCRIPTS[args.mode]
    cmd = ["bash", script_path(script)]
    if args.mode == "headless":
        cmd += [args.image or "tesla_ROM1_000000000000_000ED2000000.bin",
                str(args.duration), "gui" if args.gui else "nogui"]
    else:
        if args.rootfs:
            cmd.append(args.rootfs)
    env = os.environ.copy()
    if args.kernel:
        env["KERNEL"] = args.kernel
    if args.initrd:
        env["INITRD"] = args.initrd
    sh(cmd, env=env)


def cmd_ssh(args):
    """一键 SSH 进正在运行的 QEMU 客户机（包 ssh_qemu.sh）。"""
    cmd = ["bash", script_path("ssh_qemu.sh")]
    if args.cmd:
        cmd.append(" ".join(args.cmd))
    env = os.environ.copy()
    if args.port:
        env["SSH_PORT"] = str(args.port)
    os.execvpe(cmd[0], cmd, env)


def cmd_focus(args):
    """修复宿主机 QEMU 窗口抢不到输入焦点的问题（包 focus_qemu.sh）。"""
    sh(["bash", script_path("focus_qemu.sh")])


def cmd_capture(args):
    """客户机内抓包，通过 SSH 流回宿主机保存为 pcap（包 capture_pcap.sh）。"""
    sh(["bash", script_path("capture_pcap.sh"), args.iface, str(args.duration), args.filter or ""])


# ----------------------------------------------------------------------
# argparse 组装
# ----------------------------------------------------------------------
def build_parser():
    ap = argparse.ArgumentParser(
        prog="tesla_fw.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)

    # unpack
    p = sub.add_parser("unpack", help="固件解包全流程（分区表->iasImage->dm-linear重建->unsquashfs）")
    p.add_argument("image", help="原始固件镜像文件（tesla_ROM1_*.bin 一类的完整 eMMC dump）")
    p.add_argument("outdir", help="输出目录")
    p.add_argument("bank", nargs="?", default="both", choices=["a", "b", "both"])
    p.add_argument("--ias-image", help="boot 分区里的 bankX.iasImage 路径；提供则同时提取内核")
    p.add_argument("--bzimage-len", help="bootlog.0 里读到的 bzimage_len（十六进制，如 0x832fa0）")
    p.add_argument("--skip-partition-table", action="store_true", help="跳过 fdisk -l 打印")
    p.add_argument("--skip-unsquashfs", action="store_true", help="只重建镜像，不跑 unsquashfs")
    p.add_argument("--make-overlay", action="store_true", help="额外创建 QEMU qcow2 覆盖层")
    p.add_argument("--overlay-out", help="覆盖层输出路径（默认 <outdir>/overlay.qcow2）")
    p.add_argument("--p2-off", type=int, help="覆盖默认 rootfs-a-legacy 起始偏移")
    p.add_argument("--p3-off", type=int, help="覆盖默认 rootfs-b-legacy 起始偏移")
    p.add_argument("--seg1-len", type=int, help="覆盖默认分区2/3大小")
    p.add_argument("--p4-off", type=int, help="覆盖默认 lvm 分区起始偏移")
    p.add_argument("--p4-end-incl", type=int, help="覆盖默认 lvm 分区末字节（含）")
    p.set_defaults(func=cmd_unpack)

    p = sub.add_parser("unpack-part", help="按 GPT 分区表提取各分区为独立文件")
    p.add_argument("image")
    p.add_argument("outdir")
    p.set_defaults(func=cmd_unpack_part)

    p = sub.add_parser("unpack-initramfs", help="从 bzImage 中抠出编译进内核的 initramfs")
    p.add_argument("bzimage")
    p.add_argument("outdir")
    p.set_defaults(func=cmd_unpack_initramfs)

    # patch
    patch = sub.add_parser("patch", help="修改固件内容 + 绕过 dm-verity 签名校验")
    patch_sub = patch.add_subparsers(dest="patch_command", required=True)

    p = patch_sub.add_parser("build-init", help="编译绕过 verity 签名校验的精简 init + 打包最小 initrd")
    p.add_argument("outdir", help="输出目录（custom_init 二进制 + initrd_custom.cpio.gz）")
    p.add_argument("--initrd-out", help="initrd 输出路径（默认 <outdir>/initrd_custom.cpio.gz）")
    p.set_defaults(func=cmd_patch_build_init)

    p = patch_sub.add_parser("repack", help="把改过的 rootfs 目录重新打包成 squashfs")
    p.add_argument("rootfs_dir", help="unsquashfs 解包后、已做过修改的目录")
    p.add_argument("out", help="输出 squashfs 文件路径")
    p.add_argument("--comp", default="lz4", help="压缩算法（默认 lz4，对齐原始固件参数）")
    p.add_argument("--block-size", type=int, default=131072, help="块大小（默认 131072，对齐原始固件）")
    p.add_argument("--no-xattrs", action="store_true", help="不保留 xattr")
    p.set_defaults(func=cmd_patch_repack)

    p = patch_sub.add_parser("legacy-tables", help="[已废弃/仅存档] 静态修补 squashfs 表指针")
    p.add_argument("squashfs")
    p.add_argument("-y", "--yes", action="store_true", help="跳过确认提示")
    p.set_defaults(func=cmd_patch_legacy_tables)

    # run
    p = sub.add_parser("run", help="启动 QEMU（headless/ui/gdb/glamor 四种模式）")
    p.add_argument("--mode", choices=list(RUN_MODE_SCRIPTS), default="headless")
    p.add_argument("--image", help="[headless 模式] 原始固件镜像路径")
    p.add_argument("--duration", type=int, default=180, help="[headless 模式] 运行时长(秒)")
    p.add_argument("--gui", action="store_true", help="[headless 模式] 开图形窗口而非纯串口")
    p.add_argument("--rootfs", help="[ui/gdb/glamor 模式] squashfs 根文件系统路径")
    p.add_argument("--kernel", help="覆盖 KERNEL 环境变量（bzImage 路径）")
    p.add_argument("--initrd", help="覆盖 INITRD 环境变量（initrd 路径）")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("ssh", help="一键 SSH 进正在运行的 QEMU 客户机")
    p.add_argument("cmd", nargs="*", help="远程执行的命令；留空则进交互 shell")
    p.add_argument("--port", type=int, help="覆盖 SSH_PORT（默认 2223，见 ssh_qemu.sh）")
    p.set_defaults(func=cmd_ssh)

    p = sub.add_parser("focus", help="修复宿主机 QEMU 窗口抢不到输入焦点的问题")
    p.set_defaults(func=cmd_focus)

    p = sub.add_parser("capture", help="客户机内抓包，流回宿主机保存为 pcap")
    p.add_argument("iface", nargs="?", default="eth0")
    p.add_argument("duration", nargs="?", type=int, default=30)
    p.add_argument("filter", nargs="?", default="")
    p.set_defaults(func=cmd_capture)

    return ap


def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except subprocess.CalledProcessError as e:
        sys.exit(f"子命令失败（退出码 {e.returncode}）: {' '.join(str(c) for c in e.cmd)}")


if __name__ == "__main__":
    main()
