/*
 * 用于图形驱动实验的精简替代 init。
 *
 * 目的：完全跳过 dm-verity/dm-linear 那一套（因为我们要挂载的是一份
 * 手工改过 /etc/X11/xorg.conf.d/10-monitor.conf 的 squashfs，不再匹配
 * 真机的 verity 签名），直接把一块新增的 virtio-blk 磁盘（原始 squashfs
 * 镜像，不经压缩容器、不经验证）挂载为根文件系统。
 *
 * 挂载/切根的具体步骤严格复用 docs/analysis.md 第22.1/22.4 节反汇编
 * 真实 verity-init 得到的算法，只是去掉了 verity 建立和 commit hash
 * 校验这两步。
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <time.h>
#include <errno.h>

static void die(const char *msg)
{
	fprintf(stderr, "custom_init: %s: %s\n", msg, strerror(errno));
	sleep(9999);
	exit(1);
}

static void wait_for_device(const char *path)
{
	struct stat st;
	for (int i = 0; i < 500; i++) {
		if (stat(path, &st) == 0 && S_ISBLK(st.st_mode))
			return;
		usleep(10000);
	}
	fprintf(stderr, "custom_init: device %s never appeared\n", path);
	sleep(9999);
	exit(1);
}

int main(void)
{
	FILE *kmsg;
	int consfd;

	if (mount(NULL, "/dev", "devtmpfs", 0, NULL) < 0)
		die("mount /dev");

	/* 补回真实 verity-init 会做、之前这份精简版漏掉的两步：
	 * (1) setsid() 让自己成为新会话的组长；
	 * (2) 打开 /dev/console 并 dup2 到 0/1/2——PID 1 在 devtmpfs
	 *     刚挂载出来之前继承的 stdin/stdout/stderr 未必指向真正的
	 *     控制台设备，后续 fork 出来的所有服务的标准输入输出都是从
	 *     这里继承的，缺这一步会导致大量子进程在做终端相关的 ioctl/
	 *     读写时行为不确定。 */
	setsid();
	consfd = open("/dev/console", O_RDWR);
	if (consfd >= 0) {
		dup2(consfd, 0);
		dup2(consfd, 1);
		dup2(consfd, 2);
		if (consfd > 2)
			close(consfd);
	}

	kmsg = fopen("/dev/kmsg", "w");
	if (kmsg)
		setvbuf(kmsg, NULL, _IONBF, 0);

	if (kmsg) fprintf(kmsg, "custom_init: booting (graphics driver bypass test)\n");
	if (kmsg) fprintf(kmsg, "TESLA2026_TTYS1FIX_MARKER_V2\n");

	if (mount(NULL, "/proc", "proc", 0, NULL) < 0)
		die("mount /proc");
	if (mount(NULL, "/sys", "sysfs", 0, NULL) < 0)
		die("mount /sys");

	if (kmsg) fprintf(kmsg, "custom_init: waiting for /dev/vda\n");
	wait_for_device("/dev/vda");

	if (kmsg) fprintf(kmsg, "custom_init: mounting /dev/vda as squashfs on /mnt\n");
	if (mount("/dev/vda", "/mnt", "squashfs", MS_RDONLY, NULL) < 0)
		die("mount squashfs");

	if (kmsg) fprintf(kmsg, "custom_init: switching root and executing /sbin/init\n");

	/* 严格按 docs/analysis.md §22.1 第22步的真实顺序：先卸载旧根的
	 * /sys /proc /dev，再做 chdir/mount--move/chroot——上一版把卸载
	 * 放在了 chroot 之后，那时候卸载的其实已经是新根自己的
	 * /sys//proc//dev（如果新根里也有同名挂载点的话），旧根那三个
	 * 挂载点反而变成了孤儿挂载，白白占用资源、顺序也和真机不一致。 */
	umount2("/sys", MNT_DETACH);
	if (kmsg) fprintf(kmsg, "custom_init: BISECT-1 after umount /sys\n");
	umount2("/proc", MNT_DETACH);
	if (kmsg) fprintf(kmsg, "custom_init: BISECT-2 after umount /proc\n");
	umount2("/dev", MNT_DETACH);
	if (kmsg) fprintf(kmsg, "custom_init: BISECT-3 after umount /dev\n");

	if (kmsg) fprintf(kmsg, "custom_init: BISECT-A after umounts, before chroot\n");

	if (chdir("/mnt") < 0) die("chdir /mnt");
	if (mount(".", "/", NULL, MS_MOVE, NULL) < 0) die("mount --move");
	if (chroot(".") < 0) die("chroot");
	if (chdir("/") < 0) die("chdir /");

	if (kmsg) fprintf(kmsg, "custom_init: BISECT-B after chroot+chdir\n");

	/* 图形驱动测试专用（docs/analysis.md 第63节）：在真正 execve 进
	 * /sbin/init 之前先 fork 一个后台子进程，专门等 /dev/ttyS1（第二
	 * 个串口，由 runit/1 稍后重新挂载 devtmpfs 时才会真正出现）出现
	 * 后挂一个交互式 root shell 上去，用来直接在客户机内部验证
	 * evtest/xinput 之类的底层输入事件，而不是继续从宿主机外部截图
	 * 靠猜测排查。不依赖 runit 服务扫描的时序，保证一定会执行。 */
	pid_t marker_pid = fork();
	if (marker_pid < 0) {
		if (kmsg) fprintf(kmsg, "custom_init: fork() FAILED errno=%d\n", errno);
	}
	if (marker_pid > 0) {
		/* 图形驱动测试专用（docs/analysis.md 第63节）：先在这里停
		 * 3 秒，用 kill(pid,0) 直接探测子进程是否还存活——这个时间
		 * 窗口在 execve 进 /sbin/init（runit-init）之前，不受它后续
		 * 任何"清理不认识的子进程"之类行为的影响，用来隔离判断
		 * fork() 本身以及子进程的早期存活状态。只打印一次，不会被
		 * kmsg 限速吞掉。 */
		sleep(3);
		int alive = (kill(marker_pid, 0) == 0);
		char b[96];
		int bn = snprintf(b, sizeof(b), "custom_init: marker child pid=%d alive_after_3s=%d errno=%d\n", (int)marker_pid, alive, errno);
		write(2, b, bn);
		if (kmsg) fprintf(kmsg, "custom_init: marker child pid=%d alive_after_3s=%d errno=%d\n", (int)marker_pid, alive, errno);
	}
	if (marker_pid == 0) {
		/* 图形驱动测试专用（docs/analysis.md 第63节）：绕开所有实时
		 * 通信通道（kmsg 限速、ttyS1/socat 时序），直接用本次会话
		 * 反复验证过可靠的持久化标记文件方法——只要子进程真的在跑，
		 * 关机后离线挂载磁盘查这个文件就能确凿看到。 */
		for (;;) {
			int mfd = open("/var/etc/shellchild_marker", O_CREAT | O_WRONLY | O_APPEND, 0644);
			if (mfd >= 0) {
				char buf[32];
				int n = snprintf(buf, sizeof(buf), "%ld\n", (long)time(NULL));
				write(mfd, buf, n);
				close(mfd);
			}
			sleep(1);
		}
	}

	pid_t shell_pid = fork();
	if (shell_pid == 0) {
		struct stat st;
		for (;;) {
			if (stat("/dev/ttyS1", &st) == 0 && S_ISCHR(st.st_mode))
				break;
			usleep(200000);
		}
		setsid();
		/* 2026/scripts/ttys1_probe.py 调试用途修复：原版这里有一段
		 * "心跳" for(;;) 死循环（每秒写 HEARTBEAT 到 ttyS1，验证串口
		 * 通道本身通不通），但它永远不返回，导致下面真正 fork 交互式
		 * shell 的循环从未被执行到——ttyS1 上连的调试 shell 因此从来
		 * 没真正可用过。见 2026/docs/00_overview.md Stage 05。这里
		 * 直接删掉心跳段，让流程正常走到 shell 循环。 */
		for (;;) {
			int fd = open("/dev/ttyS1", O_RDWR);
			if (fd < 0) { usleep(500000); continue; }
			pid_t sh_pid = fork();
			if (sh_pid == 0) {
				dup2(fd, 0);
				dup2(fd, 1);
				dup2(fd, 2);
				if (fd > 2)
					close(fd);
				ioctl(0, TIOCSCTTY, 1);
				char *const shargv[] = {"/bin/sh", NULL};
				char *const shenvp[] = {
					"PATH=/usr/tesla/UI/bin:/sbin:/usr/sbin:/bin:/usr/bin",
					"HOME=/root",
					"TERM=linux",
					"PS1=guest# ",
					NULL
				};
				execve("/bin/sh", shargv, shenvp);
				_exit(1);
			}
			close(fd);
			if (sh_pid > 0)
				waitpid(sh_pid, NULL, 0);
			usleep(300000);
		}
	}

	/* 之前传的是空 envp，/sbin/init 及其派生的大量 runit 服务脚本
	 * 隐含依赖 PATH 才能找到 ifconfig/ip/mount 等命令，之前那种"没有
	 * 任何环境变量"的状态很可能是引发一连串服务反复失败重启的
	 * 真正原因之一，这里补上一个最基础的环境。 */
	char *const argv[] = {"/sbin/init", NULL};
	char *const envp[] = {
		"PATH=/usr/tesla/UI/bin:/sbin:/usr/sbin:/bin:/usr/bin",
		"HOME=/root",
		"TERM=linux",
		NULL
	};
	execve("/sbin/init", argv, envp);
	die("execve /sbin/init");
	return 1;
}
