#!/bin/bash
# 快手实况图链路保活(平板版): mitm(proxy service 常驻) + 平板 ADB + VPN
# 注意: 不管快手 App 保活 —— 与「深链用完即杀」互斥, 见末尾说明
AUX=/home/zm/zmbot/astrbot_plugin_LinkFlow_aux
SERIAL=192.168.2.32:5555
adb connect $SERIAL >/dev/null 2>&1
# 1) mitmdump 由 ks-live-proxy.service 常驻(Restart=always 自愈), 此处不再拉起
#    (历史教训: oneshot 里 nohup 起的进程会被 systemd 按 cgroup 连带杀掉)
# 2) 平板全局代理残留清除(防回环)
P=$(adb -s $SERIAL shell settings get global http_proxy 2>/dev/null | tr -d '\r\n ')
[ -n "$P" ] && [ "$P" != 'null' ] && adb -s $SERIAL shell settings put global http_proxy :0
# 3) CA bind mount 丢失(重启后)则重挂
if ! adb -s $SERIAL shell 'ls /system/etc/security/cacerts/' 2>/dev/null | grep -q c8750f0d; then
  adb -s $SERIAL shell "su -c 'sh /data/local/tmp/ca_remount.sh'" >/dev/null 2>&1
fi
# 4) wake_lock 丢了补上
adb -s $SERIAL shell 'cat /sys/power/wake_lock' 2>/dev/null | grep -q ksassist || adb -s $SERIAL shell "su -c 'echo ksassist > /sys/power/wake_lock'" >/dev/null 2>&1
# 4.5) VPN 隧道没了则拉起 FlClash(取代已卸载的 NekoBox)
#     FlClash 用启动广播请求 VPN; 拉起后 2 秒复查, 仍无 tun0 就记一条日志
if ! adb -s $SERIAL shell ip addr show tun0 >/dev/null 2>&1; then
  # 一级: 广播(进程还在时最快)
  adb -s $SERIAL shell am broadcast -a com.follow.clash.intent.action.VPN_START_REQUESTED -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
  sleep 2
  # 二级: 拉起进程 —— FlClash 启动后会自动恢复上次的 VPN 运行状态
  if ! adb -s $SERIAL shell ip addr show tun0 >/dev/null 2>&1; then
    adb -s $SERIAL shell am start -n com.follow.clash/.MainActivity >/dev/null 2>&1
    sleep 4
  fi
  adb -s $SERIAL shell ip addr show tun0 >/dev/null 2>&1 || echo "[$(date '+%F %T')] FlClash VPN 拉起失败(tun0 缺失)" >> $AUX/keepalive.log
fi
# 4.6) FlClash 配置同步 / 漂移自愈(服务器 yaml 为唯一真源)
#     背景: FlClash 的 profile 曾是 type='file'(本地文件, 无订阅源), 服务器改了
#     平板不知道; 且 App 全局设置 patchClashConfig 每次启动都重新生成 config.yaml,
#     把 profile 里的 find-process-mode 顶成 "off"(改 prefs 无效, 直接改
#     config.yaml 也会被改回)。现由服务器每分钟比对 md5, 不一致就推送 + 重载,
#     并把 find-process-mode 强制修正回 strict。
#     耗时约 1-2s(配置一致时立即返回), 不影响其它保活逻辑。
bash $AUX/ks_sync_flclash.sh >/dev/null 2>&1

# 5) 不保活拉起快手 App: 原逻辑「App 死了就 am start」与 ks_live_server 的
#    「深链用完 force-stop」直接冲突 —— 杀了最多 120s(timer 周期)又被拉起,
#    永远杀不干净, 后台持续拉广告/保活请求。现在 App 平时保持死亡, 请求来了
#    才冷启动(实测仅多 ~1s), 且 ks_live_server 有 8s 无响应重发深链兜底,
#    不会因此 504。极速版(nebula)是深链目标, 主版(gifmaker)由
#    _force_stop_app 一并杀, 两者此处都不拉。

# 6) 抓包流量文件轮转: 超过 100MB 截断(之前涨到 325MB, 不清会无限长)
F=$AUX/ks_live.flows
if [ -f "$F" ] && [ "$(stat -c%s "$F" 2>/dev/null || echo 0)" -gt 104857600 ]; then
  : > "$F"
  echo "[$(date '+%F %T')] ks_live.flows 超 100MB, 已截断" >> $AUX/keepalive.log
fi
