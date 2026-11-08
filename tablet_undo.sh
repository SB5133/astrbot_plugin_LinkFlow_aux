#!/system/bin/sh
# 还原脚本: 撤销 tablet_setup.sh 的一切 (应急/换方案用)
KS=com.kuaishou.nebula
echo "== unmount CA =="
mount | grep -q "cacerts" && umount /system/etc/security/cacerts && echo "   umounted"
echo "== wake unlock =="
echo ksassist > /sys/power/wake_unlock 2>/dev/null
echo "== doze whitelist remove =="
dumpsys deviceidle whitelist -$KS
echo "== done (全部还原, /system 从未被写入) =="
