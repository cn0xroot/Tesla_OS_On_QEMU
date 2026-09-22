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
qemu_snapshot.py —— 给跑在 QEMU 里的 Tesla 客户机做活体快照（RAM+CPU+磁盘
全状态），配合 dbus_fuzz.py 用：每次可疑用例之后不用冷启动重来一遍，
`restore` 几秒钟就能回到快照那一刻的精确状态继续测。

依赖 QEMU 的 QMP 管理接口，走的是仓库里 `scripts/qmp_tap.py` 已经在用的
同一个 unix socket（`run_qemu_ui.sh`/`run_v62_glamor.sh` 默认会开在
`/tmp/tesla_v60_qmp.sock`，其余模式没接 QMP，用之前先给对应脚本加
`-qmp unix:$QMP_SOCK,server,nowait`）。

底层用的是 QEMU 经典的 `savevm`/`loadvm`/`delvm`/`info snapshots` 人机
监视器命令（通过 QMP 的 human-monitor-command 转发），不是较新的、异步
job 形式的原生 QMP snapshot 命令——选这条路是为了兼容性：这几个 HMP
命令从 QEMU 很早的版本就有，任何还在跑的 QEMU 版本基本都支持，不用先
探测版本/能力。

用法：
    qemu_snapshot.py save <tag> [--qmp-sock PATH]
    qemu_snapshot.py restore <tag> [--qmp-sock PATH]
    qemu_snapshot.py delete <tag> [--qmp-sock PATH]
    qemu_snapshot.py list [--qmp-sock PATH] [--overlay PATH]
        QMP socket 能连上就走 QMP(`info snapshots`)问正在跑的那个实例；
        连不上就退化成 `qemu-img snapshot -l <overlay>` 离线读磁盘文件
        本身记录的快照列表(适用于 QEMU 没在跑、只是想看 overlay.qcow2
        里存了哪些快照的场景)。

注意：
  - `savevm` 需要磁盘后端支持内部快照——qcow2 支持，本项目默认用的
    `extracted/overlay.qcow2` 覆盖层就是 qcow2，可以直接用。
  - 快照存在覆盖层文件内部，不会碰原始 .bin 固件，符合"原始镜像全程
    只读"的项目约定。
  - 保存/恢复大内存配置(默认 8192MB)可能需要几秒到十几秒，脚本会等
    QMP 返回结果而不是掐时间瞎等，但仍建议先用小 --timeout 试一次
    确认能连上，再拉长跑正式流程。
"""
import argparse
import json
import socket
import sys
import subprocess
import time

DEFAULT_SOCK = "/tmp/tesla_v60_qmp.sock"


class QMPError(RuntimeError):
    pass


class QMPClient:
    """极简 QMP 客户端：连接、握手、发命令、读完整 JSON 回复。
    比 qmp_tap.py 里那个"sleep 0.15s 就当读完了"的写法更稳一点——
    savevm/loadvm 这类命令耗时不固定，用固定 sleep 很容易读到半截。"""

    def __init__(self, sock_path, timeout=30):
        self.sock_path = sock_path
        self.timeout = timeout
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(timeout)
            self.sock.connect(sock_path)
        except (FileNotFoundError, ConnectionRefusedError, OSError) as e:
            raise QMPError(
                f"连不上 QMP socket {sock_path}：{e}\n"
                f"确认 QEMU 是不是用 run_qemu_ui.sh / run_v62_glamor.sh 起的"
                f"（这两个默认开了 QMP），并且路径和 QMP_SOCK 环境变量对得上。"
            )
        self._buf = b""
        self._greeting = self._read_json()  # QMP 连接后先推一条 greeting
        cap = self._send_and_wait({"execute": "qmp_capabilities"})
        if "error" in cap:
            raise QMPError(f"qmp_capabilities 握手失败: {cap['error']}")

    def _read_json(self):
        """从 socket 读，直到攒出至少一个完整的 JSON 对象（按换行分帧，
        QMP 每条消息以换行结尾）。"""
        while b"\n" not in self._buf:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise QMPError("读 QMP 回复超时——命令可能还在跑(比如大内存 savevm)，"
                                "可以加大 --timeout 重试")
            if not chunk:
                raise QMPError("QMP 连接被对端关闭")
            self._buf += chunk
        line, _, rest = self._buf.partition(b"\n")
        self._buf = rest
        return json.loads(line.decode())

    def _send_and_wait(self, obj, expect_return=True):
        self.sock.sendall((json.dumps(obj) + "\r\n").encode())
        while True:
            resp = self._read_json()
            # QMP 会异步推送事件(event)，命令的真正回复是带 "return" 或
            # "error" 键的那条，跳过事件消息继续等。
            if "event" in resp:
                continue
            return resp

    def human_monitor_command(self, hmp_cmd):
        resp = self._send_and_wait({
            "execute": "human-monitor-command",
            "arguments": {"command-line": hmp_cmd},
        })
        if "error" in resp:
            raise QMPError(f"HMP 命令 `{hmp_cmd}` 失败: {resp['error']}")
        return resp.get("return", "")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def cmd_save(args):
    qmp = QMPClient(args.qmp_sock, timeout=args.timeout)
    try:
        print(f"保存快照 '{args.tag}'（大内存配置可能要等几秒到十几秒）...")
        t0 = time.time()
        out = qmp.human_monitor_command(f"savevm {args.tag}")
        print(f"完成，用时 {time.time()-t0:.1f}s")
        if out.strip():
            print(out.strip())
    finally:
        qmp.close()


def cmd_restore(args):
    qmp = QMPClient(args.qmp_sock, timeout=args.timeout)
    try:
        print(f"恢复快照 '{args.tag}' ...")
        t0 = time.time()
        out = qmp.human_monitor_command(f"loadvm {args.tag}")
        print(f"完成，用时 {time.time()-t0:.1f}s")
        if out.strip():
            print(out.strip())
        if "No block device" in out or "does not exist" in out or "Error" in out:
            print("!! 上面的输出看起来像是失败信息，快照名是不是打错了？"
                  "用 `qemu_snapshot.py list` 先确认现有快照名单。", file=sys.stderr)
    finally:
        qmp.close()


def cmd_delete(args):
    qmp = QMPClient(args.qmp_sock, timeout=args.timeout)
    try:
        out = qmp.human_monitor_command(f"delvm {args.tag}")
        print(f"已删除快照 '{args.tag}'" + (f": {out.strip()}" if out.strip() else ""))
    finally:
        qmp.close()


def cmd_list(args):
    try:
        qmp = QMPClient(args.qmp_sock, timeout=args.timeout)
        try:
            out = qmp.human_monitor_command("info snapshots")
            print("（通过 QMP 问正在运行的 QEMU 实例）")
            print(out.strip() or "(没有任何快照)")
            return
        finally:
            qmp.close()
    except QMPError as e:
        print(f"(QMP 连不上，退化成离线读取 overlay 文件: {e})", file=sys.stderr)

    if not args.overlay:
        sys.exit("QMP 连不上时需要 --overlay 指定 qcow2 文件路径才能离线列出快照")
    p = subprocess.run(["qemu-img", "snapshot", "-l", args.overlay],
                        capture_output=True, text=True)
    print(f"（离线读取 {args.overlay} 里记录的快照）")
    print(p.stdout or "(没有任何快照)")
    if p.returncode != 0:
        print(p.stderr, file=sys.stderr)
        sys.exit(p.returncode)


def build_parser():
    ap = argparse.ArgumentParser(
        prog="qemu_snapshot.py", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--qmp-sock", default=DEFAULT_SOCK,
                     help=f"QMP unix socket 路径（默认 {DEFAULT_SOCK}，"
                          f"对应 run_qemu_ui.sh/run_v62_glamor.sh 的默认值）")
    ap.add_argument("--timeout", type=float, default=30,
                     help="等 QMP 回复的超时时间(秒)，大内存 savevm/loadvm 适当调大")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("save", help="保存一个活体快照（RAM+CPU+磁盘全状态）")
    p.add_argument("tag", help="快照名，比如 clean-boot / post-fuzz-baseline")
    p.set_defaults(func=cmd_save)

    p = sub.add_parser("restore", help="恢复到某个快照")
    p.add_argument("tag")
    p.set_defaults(func=cmd_restore)

    p = sub.add_parser("delete", help="删除一个快照")
    p.add_argument("tag")
    p.set_defaults(func=cmd_delete)

    p = sub.add_parser("list", help="列出现有快照（QEMU在跑就走QMP，没在跑就离线读overlay文件）")
    p.add_argument("--overlay", default="extracted/overlay.qcow2",
                    help="QMP连不上时，离线读取的qcow2文件路径")
    p.set_defaults(func=cmd_list)

    return ap


def main():
    args = build_parser().parse_args()
    try:
        args.func(args)
    except QMPError as e:
        sys.exit(f"错误: {e}")


if __name__ == "__main__":
    main()
