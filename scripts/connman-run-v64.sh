#!/bin/bash

LOG_TAG=connman
SANDBOX_PROFILE=connman

exec 2>&1

. /etc/sandbox/sandbox.bash "$LOG_TAG" "$SANDBOX_PROFILE"

StopSandbox

. /etc/cfi-ubsan.vars

# v64 修正:QEMU 无 TCU/wifi 硬件,is-tcu-available 不存在会导致服务退出重启循环、
# 永远到不了下面的 connmand。这里直接跳过 TCU/wpa_supplicant 前置检查。
true

mkdir -p /var/lib/connman
chown -hR connman:connman /var/lib/connman
chmod -R u=rwx,g=rwx,o=r /var/lib/connman

mkdir -p /var/run/connman
chown -hR connman:connman /var/run/connman

CONF=/etc/connman/main.conf
if /usr/bin/is-in-factory; then
    CONF=/etc/connman/main-factory.conf;
else
    if /usr/bin/is-china-car; then
        CONF=/etc/connman/main-cn.conf;
    fi;
fi

export GLIBC_TUNABLES=glibc.malloc.tcache_count=0

# v64(fork §23):去掉 Tesla 的 -I eth0,eth0.2 黑名单,改 -i eth0 让 ConnMan 管住
# 唯一的以太口(QEMU 无 wifi/蜂窝),NetManager 才会报 CONN_connectedToInternet=true。
# 绕过沙箱裸启(与 x/run 裸启 Ubuntu Xorg 同思路,已实测有效)。
exec /usr/sbin/connmand -c "$CONF" --nodnsproxy -n -i eth0

