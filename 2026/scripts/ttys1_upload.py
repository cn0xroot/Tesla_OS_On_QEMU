#!/usr/bin/env python3
"""
通过 custom_init.c 挂在 ttyS1 上的 root shell，把一个小文件用 base64 分片
+ shell 追加写的方式传进 guest（没有共享文件系统时的土办法）。

用法: ttys1_upload.py <unix_socket_path> <本地文件> <guest目标路径>
"""
import socket
import sys
import time
import base64

def main():
    sock_path = sys.argv[1]
    local_path = sys.argv[2]
    remote_path = sys.argv[3]

    with open(local_path, "rb") as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(sock_path)

    def send(cmd, wait=0.3):
        s.sendall(cmd.encode() + b"\n")
        end = time.time() + wait
        s.settimeout(0.3)
        buf = b""
        while time.time() < end:
            try:
                d = s.recv(65536)
                if not d:
                    break
                buf += d
            except socket.timeout:
                pass
        return buf

    send(f"rm -f {remote_path}.b64", 0.5)
    CHUNK = 400
    n = len(b64)
    for i in range(0, n, CHUNK):
        chunk = b64[i:i+CHUNK]
        send(f"printf '%s' '{chunk}' >> {remote_path}.b64", 0.15)
    out = send(f"base64 -d {remote_path}.b64 > {remote_path} && wc -c {remote_path}", 1.0)
    print(out.decode(errors="replace"))
    s.close()

if __name__ == "__main__":
    main()
