#!/system/bin/sh
# 快手实况图链路·平板控制台  MT管理器/终端直接执行即可, 自动提权
[ "$(id -u)" = "0" ] || exec su -c "sh /data/local/tmp/ks.sh $*"
A=/data/local/tmp
getstate() { dumpsys power | sed -n 's/.*Display Power: state=\([A-Z]*\).*/\1/p'; }
case "$1" in
off)
  [ "$(getstate)" = "ON" ] && { input keyevent 26; echo 已灭屏; } || echo 本来就是灭屏
  ;;
on)
  [ "$(getstate)" = "OFF" ] && { input keyevent 224; echo 已亮屏; } || echo 本来就亮着
  ;;
status)
  echo "屏幕   : $(getstate)"
  echo "唤醒锁 : $(cat /sys/power/wake_lock | tr -s ' ' '\n' | grep -c ksassist) ksassist"
  echo "CA信任 : $(ls /system/etc/security/cacerts/ 2>/dev/null | grep -c c8750f0d) c8750f0d"
  echo "快手   : $(pidof com.kuaishou.nebula >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
  echo "FlClash: $(pidof com.follow.clash >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
  echo "VPN隧道: $(ip addr show tun0 >/dev/null 2>&1 && echo 已建立 || echo 未建立)"
  echo "代理   : $(settings get global http_proxy)  (应为 null)"
  ;;
*)
  echo "用法: su -c \"sh $A/ks.sh off|on|status\""
  ;;
esac
