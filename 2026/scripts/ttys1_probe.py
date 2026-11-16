#!/usr/bin/env python3
"""
连到 custom_init.c 在 /dev/ttyS1 上挂的那个 root shell（见
extracted/graphics_test/custom_init.c 第154~203行），发一串诊断命令，
把回显抓下来存文件。用于在不依赖 SSH/网络的情况下直接在 guest 内部
执行命令（本次用来对比 apparmor_parser 版本和内核 /sys/kernel/security/
apparmor/features 输出，排查 Stage 03/04 发现的 "network unix" mediation
不生效问题）。

用法: ttys1_probe.py <unix_socket_path> <output_file> [cmd1] [cmd2] ...
"""
import socket
import sys
import time

def main():
    sock_path = sys.argv[1]
    out_path = sys.argv[2]
    cmds = sys.argv[3:]

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(sock_path)

    buf = b""

    def drain(t=2.0):
        nonlocal buf
        end = time.time() + t
        s.settimeout(0.3)
        while time.time() < end:
            try:
                d = s.recv(65536)
                if not d:
                    break
                buf += d
            except socket.timeout:
                pass

    # 先敲个回车，把 shell 提示符唤出来，也把之前 HEARTBEAT 心跳行冲掉一部分
    s.sendall(b"\n")
    drain(2.0)

    for c in cmds:
        s.sendall(c.encode() + b"\n")
        drain(3.0)

    with open(out_path, "wb") as f:
        f.write(buf)

    s.close()

if __name__ == "__main__":
    main()
