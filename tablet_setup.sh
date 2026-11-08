#!/system/bin/sh
# 步步高平板(Android 11, root) 快手实况图链路一次性配置
# 原则: 零系统分区写入, 全部运行时生效, 重启自动还原
set -e

CA=/data/local/tmp/c8750f0d.0
CERTDIR=/data/local/tmp/cacerts
KS=com.kuaishou.nebula

echo "== 1. CA 系统信任 (bind mount, 不碰 /system) =="
if ! ls /system/etc/security/cacerts/ | grep -q c8750f0d; then
  rm -rf $CERTDIR && mkdir -p $CERTDIR
  cp /system/etc/security/cacerts/* $CERTDIR/
  cp $CA $CERTDIR/
  chmod 644 $CERTDIR/*
  chown root:root $CERTDIR/*
  chcon u:object_r:system_security_cacerts_file:s0 $CERTDIR/* 2>/dev/null || true
  chcon u:object_r:system_security_cacerts_file:s0 $CERTDIR 2>/dev/null || true
  mount -o bind $CERTDIR /system/etc/security/cacerts
  echo "   CA mounted: $(ls /system/etc/security/cacerts/ | grep -c c8750f0d)"
else
  echo "   already mounted, skip"
fi

echo "== 2. 防休眠 (运行时) =="
# 快手进 Doze 白名单, 灭屏不断网
dumpsys deviceidle whitelist +$KS
# 内核级 CPU 唤醒锁: 屏幕可灭, CPU 不睡
echo ksassist > /sys/power/wake_lock 2>/dev/null && echo "   wake_lock ok" || echo "   wake_lock fail(可忽略, 靠白名单兜底)"

echo "== 3. 无线 adb 常开 (每次重启后需重跑本脚本第3步) =="
setprop service.adb.tcp.port 5555
setprop persist.adb.tcp.port 5555
# 后台脱离执行, 避免自己杀掉自己的 shell
nohup sh -c 'sleep 1; stop adbd; sleep 1; start adbd' >/dev/null 2>&1 &
echo "   adbd restarting in background"

echo "== done =="
