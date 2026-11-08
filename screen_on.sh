#!/system/bin/sh
# 亮屏: 只唤醒不熄灭(KEYCODE_WAKEUP)
STATE=$(dumpsys display | grep 'mScreenState=' | grep -o 'ON\|OFF')
if [ "$STATE" = "OFF" ]; then
  input keyevent 224
  echo SCREEN_ON
else
  echo ALREADY_ON
fi
