#!/system/bin/sh
# 灭屏保活: 关背光但 CPU 不睡(wake_lock ksassist 已挂), 供 adb/su 调用
STATE=$(dumpsys display | grep 'mScreenState=' | grep -o 'ON\|OFF')
if [ "$STATE" = "ON" ]; then
  input keyevent 26
  echo SCREEN_OFF
else
  echo ALREADY_OFF
fi
