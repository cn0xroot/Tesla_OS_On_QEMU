/*
 * custom_init.c —— 绕过 dm-verity 签名校验的精简替代 init（PID 1）。
 *
 * Copyright (C) 2026 cn0xroot
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * 背景（见 docs/firmware_unpacking_reproduction.md 第 9 节）：
 *   Tesla 真机的 verity-init 会对 squashfs 根文件系统做 RSA 签名校验，
 *   任何对 squashfs 内容的手工修改都会让签名失效、真机 verity-init 拒绝
 *   挂载。这个精简 init 严格复刻 verity-init 反汇编还原出的挂载/切根
 *   控制流（见文档第 6.2 节），只是去掉签名校验和 dm-verity 建立这两步，
 *   直接挂载一块裸块设备（QEMU 里通常是 -drive if=virtio 呈现的
 *   /dev/vda）——只要目标内容是合法的 squashfs 格式，改过什么都能挂载
 *   启动，不再受 verity 签名限制。
 *
 * 根设备可通过内核命令行 `patchroot=/dev/xxx` 覆盖，默认 /dev/vda。
 *
 * 编译（由 scripts/tesla_fw.py patch build-init 自动调用）：
 *   gcc -static -O2 -Wall -o custom_init custom_init.c
 */
#include <sys/mount.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#define DEFAULT_ROOTDEV "/dev/vda"

static void die(const char *msg) {
    fprintf(stderr, "custom_init: 致命错误: %s: %s\n", msg, strerror(errno));
    /* PID 1 不能退出，退出会导致内核 panic；卡在这里方便看串口日志。 */
    for (;;) pause();
}

static void wait_for_device(const char *path) {
    struct stat st;
    int tries = 0;
    while (stat(path, &st) != 0) {
        usleep(100000);
        if (++tries % 50 == 0) {
            fprintf(stderr, "custom_init: 仍在等待设备 %s 出现 (%ds)...\n",
                    path, tries / 10);
        }
    }
}

/* 从 /proc/cmdline 里找 key=value，找到就把 value 拷进 out（NUL 结尾），
 * 找不到返回 0。非常朴素的实现，够用即可（不是通用 cmdline 解析器）。 */
static int cmdline_get(const char *key, char *out, size_t outsz) {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return 0;
    static char buf[4096];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    size_t keylen = strlen(key);
    char *p = buf;
    while ((p = strstr(p, key)) != NULL) {
        /* 要求 key 前面是行首或空格，后面紧跟 '=' */
        int at_start = (p == buf) || (p[-1] == ' ');
        if (at_start && p[keylen] == '=') {
            const char *v = p + keylen + 1;
            const char *end = v;
            while (*end && *end != ' ') end++;
            size_t vlen = (size_t)(end - v);
            if (vlen >= outsz) vlen = outsz - 1;
            memcpy(out, v, vlen);
            out[vlen] = '\0';
            return 1;
        }
        p += keylen;
    }
    return 0;
}

int main(void) {
    if (mount(NULL, "/dev", "devtmpfs", 0, NULL) < 0) die("mount /dev");

    /* 补回真实 verity-init 会做、精简版最初漏掉的两步：
     * setsid() 成为新会话组长；打开 /dev/console 并 dup2 到 0/1/2——
     * 缺这一步会导致后续所有子进程在终端相关 ioctl 上行为不确定。 */
    setsid();
    int consfd = open("/dev/console", O_RDWR);
    if (consfd >= 0) {
        dup2(consfd, 0);
        dup2(consfd, 1);
        dup2(consfd, 2);
        if (consfd > 2) close(consfd);
    }

    printf("custom_init: 启动（绕过 dm-verity 签名校验，仅供固件内容调试用）\n");

    if (mount(NULL, "/proc", "proc", 0, NULL) < 0) die("mount /proc");
    if (mount(NULL, "/sys", "sysfs", 0, NULL) < 0) die("mount /sys");

    char rootdev[256];
    if (!cmdline_get("patchroot", rootdev, sizeof(rootdev))) {
        strncpy(rootdev, DEFAULT_ROOTDEV, sizeof(rootdev) - 1);
        rootdev[sizeof(rootdev) - 1] = '\0';
    }
    printf("custom_init: 等待根设备 %s ...\n", rootdev);
    wait_for_device(rootdev);

    if (mkdir("/mnt", 0755) < 0 && errno != 17 /* EEXIST */) die("mkdir /mnt");
    if (mount(rootdev, "/mnt", "squashfs", MS_RDONLY, NULL) < 0) die("mount squashfs root");

    /* 严格按真实 verity-init 反汇编出的顺序：先卸载旧根的
     * /sys /proc /dev，再 chdir/mount--move/chroot——顺序反了会导致
     * 卸载到新根自己的同名挂载点，旧根三个挂载点变成孤儿挂载。 */
    umount2("/sys", MNT_DETACH);
    umount2("/proc", MNT_DETACH);
    umount2("/dev", MNT_DETACH);

    if (chdir("/mnt") < 0) die("chdir /mnt");
    if (mount(".", "/", NULL, MS_MOVE, NULL) < 0) die("mount --move");
    if (chroot(".") < 0) die("chroot .");
    if (chdir("/") < 0) die("chdir /");

    char *const argv[] = {"/sbin/init", NULL};
    char *const envp[] = {
        "PATH=/usr/tesla/UI/bin:/sbin:/usr/sbin:/bin:/usr/bin",
        "HOME=/root", "TERM=linux", NULL
    };
    execve("/sbin/init", argv, envp);
    die("execve /sbin/init");
    return 1;
}
