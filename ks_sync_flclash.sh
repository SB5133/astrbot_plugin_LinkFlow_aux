#!/bin/bash
# ============================================================================
# FlClash 配置同步 / 漂移自愈  (服务器侧唯一真源)
# ----------------------------------------------------------------------------
# 【为什么需要这个】(2026-11-08 实测踩坑)
#   1) FlClash 的 profile 原本是 type='file'(本地文件) + url=''  —— 没有订阅源,
#      服务器上的 ks-mitm.yaml 改了之后平板【永远不会】自动同步。
#      (现已改成 type='url' 指向 http://192.168.2.31:8765/ks-mitm.yaml,
#       但实测 FlClash 不会因为文件缺失而自动重下, 只有 App 内部触发/到期才拉,
#       所以服务器侧主动同步仍然是必须的兜底。)
#
#   2) FlClash App 的全局设置 patchClashConfig(存在 shared_prefs 的
#      flutter.config JSON 里) 会在【每次"启动 App"时】重新生成整个 config.yaml,
#      并且覆盖 profile 里的同名键:
#        find-process-mode: strict  ->  "off"    <-- 实测: 改 prefs 无效,
#                                              直接改 config.yaml 也会被改回
#        dns.enable / log-level / external-controller / tun ... 同理
#      但 sniffer 不在 patchClashConfig 里, 所以 sniffer 能从 profile 存活
#      —— 这也正是"能抓到 info2"的关键(sniffer 从 TLS ClientHello 还原 SNI 域名,
#      否则裸 IP 匹配不上任何 DOMAIN 规则, 会走 MATCH,DIRECT 漏出抓包)。
#
#   3) 实测有效的两条路径:
#      a) 让 profile 内容生效: 改 profile -> 删 config.yaml -> 重启 FlClash
#         (FlClash 按 schema 白名单合并 profile, 自定义键会被丢弃,
#          但 sniffer/rules/proxies 等认识的键会保留。已验证:
#          profile 的 sniffer.force-domain 加一项, 确实出现在生效 config.yaml。)
#      b) 让内核吃到改过的 config.yaml: com.follow.clash.action.STOP/START
#         (只重启 VPN service, 不会重新生成 config.yaml -> 改动能保留,
#          且比重启 App 轻得多。已验证。)
#
# 【本脚本职责】每分钟由 keepalive.sh 调用:
#   - 比对服务器 yaml 与平板 profile 的 md5, 不一致就推送
#   - 用平板侧的 ks_cfg_doctor.sh 做 7 项体检(sniffer/代理端口/rules/
#     PROCESS-NAME/find-process-mode/MATCH 兜底)
#   - 有偏差就重载, 并把 App 覆盖掉的 find-process-mode 强制改回 strict
#   - 重载后恢复 VPN(tun0)
# ============================================================================
set -u
AUX=/home/zm/zmbot/astrbot_plugin_LinkFlow_aux
SERIAL=192.168.2.32:5555
YML=$AUX/ks-mitm.yaml
LOG=$AUX/keepalive.log
BASE=/data/data/com.follow.clash
CFG=$BASE/files/config.yaml
PROF_DIR=$BASE/files/profiles
DOCTOR=/data/local/tmp/ks_cfg_doctor.sh
MARK_PORT=18080

log(){ echo "[$(date '+%F %T')] [flclash-sync] $*" >> "$LOG"; }

adb connect "$SERIAL" >/dev/null 2>&1
[ -f "$YML" ] || { log "服务器 yaml 不存在, 跳过"; exit 0; }

if ! adb -s "$SERIAL" shell true >/dev/null 2>&1; then
  log "平板不在线, 跳过配置同步"
  exit 0
fi

# --- 0) 确保辅助脚本在平板上(内容变了就重推) ---
push_if_changed(){
  local src="$1" dst="$2"
  local m1 m2
  m1=$(md5sum "$src" 2>/dev/null | awk '{print $1}')
  m2=$(adb -s "$SERIAL" shell "su -c 'md5sum $dst 2>/dev/null'" | awk '{print $1}' | tr -d '\r')
  if [ -n "$m1" ] && [ "$m1" != "$m2" ]; then
    adb -s "$SERIAL" push "$src" "$dst" >/dev/null 2>&1
    adb -s "$SERIAL" shell "su -c 'chmod 755 $dst'" >/dev/null 2>&1
  fi
}
push_if_changed "$AUX/ks_cfg_doctor.sh"   "$DOCTOR"
push_if_changed "$AUX/ks_fix_sniffer.sh"  "/data/local/tmp/ks_fix_sniffer.sh"

# 在平板上跑体检, 返回 key=value 行
doctor(){
  adb -s "$SERIAL" shell "su -c 'sh $DOCTOR'" 2>/dev/null | tr -d '\r'
}

# --- 1) 定位平板 profile 文件(靠内容特征, 不写死 id) ---
PROF=""
for f in $(adb -s "$SERIAL" shell "su -c 'ls $PROF_DIR/*.yaml 2>/dev/null'" | tr -d '\r'); do
  if adb -s "$SERIAL" shell "su -c 'grep -l $MARK_PORT $f 2>/dev/null'" | grep -q .; then
    PROF="$f"; break
  fi
done
if [ -z "$PROF" ]; then
  log "平板上找不到我们的 profile(含 $MARK_PORT)"
  exit 1
fi

# --- 2) md5 比对 ---
SRV_MD5=$(md5sum "$YML" | awk '{print $1}')
TAB_MD5=$(adb -s "$SERIAL" shell "su -c 'md5sum $PROF 2>/dev/null'" | awk '{print $1}' | tr -d '\r')
NEED_SYNC=0
if [ -z "$TAB_MD5" ]; then
  log "平板 profile 缺失($PROF), 需重新下发"
  NEED_SYNC=1
elif [ "$SRV_MD5" != "$TAB_MD5" ]; then
  log "配置漂移: 服务器=$SRV_MD5 平板=$TAB_MD5, 重新下发"
  NEED_SYNC=1
fi

# --- 3) 体检 ---
NEED_RELOAD=0
if [ "$NEED_SYNC" -eq 0 ]; then
  D=$(doctor)
  getf(){ echo "$D" | grep "^$1=" | head -1 | cut -d= -f2; }
  CFG_MISSING=$(getf CFG_MISSING)
  SNIFFER_OK=$(getf SNIFFER_OK)
  PROXY_PORT_OK=$(getf PROXY_PORT_OK)
  RULES_OK=$(getf RULES_OK)
  PROC_RULE_OK=$(getf PROC_RULE_OK)
  FPM_OK=$(getf FPM_OK)
  MATCH_OK=$(getf MATCH_OK)

  BAD=""
  [ "$CFG_MISSING" = "1" ] && BAD="$BAD CFG_MISSING"
  [ "$SNIFFER_OK" = "1" ] || BAD="$BAD SNIFFER"
  [ "$PROXY_PORT_OK" = "1" ] || BAD="$BAD PROXY_PORT"
  [ "$RULES_OK" = "1" ] || BAD="$BAD RULES"
  [ "$PROC_RULE_OK" = "1" ] || BAD="$BAD PROC_RULE"
  [ "$MATCH_OK" = "1" ] || BAD="$BAD MATCH"

  if [ -n "$BAD" ]; then
    # App 重建 config.yaml 期间会读到半成品, 隔几秒复判一次, 避免误判重载
    sleep 6
    D=$(doctor)
    getf(){ echo "$D" | grep "^$1=" | head -1 | cut -d= -f2; }
    BAD2=""
    [ "$(getf CFG_MISSING)" = "1" ] && BAD2="$BAD2 CFG_MISSING"
    [ "$(getf SNIFFER_OK)" = "1" ] || BAD2="$BAD2 SNIFFER"
    [ "$(getf PROXY_PORT_OK)" = "1" ] || BAD2="$BAD2 PROXY_PORT"
    [ "$(getf RULES_OK)" = "1" ] || BAD2="$BAD2 RULES"
    [ "$(getf PROC_RULE_OK)" = "1" ] || BAD2="$BAD2 PROC_RULE"
    [ "$(getf MATCH_OK)" = "1" ] || BAD2="$BAD2 MATCH"
    if [ -n "$BAD2" ]; then
      log "生效配置异常($BAD2), 需重载"
      NEED_RELOAD=1
    fi
  fi

  # find-process-mode 被 App 顶成 off 时, PROCESS-NAME 双保险失效 -> 单独修正(不必重载 App)
  if [ "$(getf FPM_OK)" != "1" ]; then
    log "生效配置 find-process-mode 非 strict, 需修正"
    FIX_FPM=1
  else
    FIX_FPM=0
  fi
else
  FIX_FPM=0
fi

if [ "$NEED_SYNC" -eq 0 ] && [ "$NEED_RELOAD" -eq 0 ] && [ "$FIX_FPM" -eq 0 ]; then
  exit 0
fi

# --- 4) 下发 profile (cat > 覆盖, 保留原 inode 属主/权限) ---
if [ "$NEED_SYNC" -eq 1 ]; then
  adb -s "$SERIAL" push "$YML" /data/local/tmp/ks-mitm.yaml >/dev/null 2>&1
  adb -s "$SERIAL" shell "su -c 'cat /data/local/tmp/ks-mitm.yaml > $PROF && rm -f /data/local/tmp/ks-mitm.yaml'" >/dev/null 2>&1
  NEW_MD5=$(adb -s "$SERIAL" shell "su -c 'md5sum $PROF 2>/dev/null'" | awk '{print $1}' | tr -d '\r')
  if [ "$NEW_MD5" = "$SRV_MD5" ]; then
    log "profile 已同步($PROF), md5=$NEW_MD5"
  else
    log "profile 同步失败: $NEW_MD5 != $SRV_MD5"
    exit 1
  fi
fi

# --- 5) 修复生效 config.yaml ---
#     关键: App 覆盖 profile 的行为只发生在"启动 App"时, 而 sniffer/端口/rules
#     这些都是 App 认识的键 —— 它们之所以会丢, 是因为 App 重写了整个 config.yaml。
#     所以修复分两种:
#       a) 只是 sniffer/find-process-mode 之类被顶掉 -> 直接改 config.yaml +
#          STOP/START 重载内核即可(轻量, 几秒), 不必重启 App。
#       b) profile 本身变了(md5 漂移) -> 必须删 config.yaml 让 App 按新 profile 重建。
if [ "$NEED_RELOAD" -eq 1 ] || [ "$NEED_SYNC" -eq 1 ]; then
  # 走 (b): 删 config.yaml + 重启 App
  adb -s "$SERIAL" shell am force-stop com.follow.clash >/dev/null 2>&1
  sleep 2
  adb -s "$SERIAL" shell "su -c 'rm -f $CFG'" >/dev/null 2>&1
  adb -s "$SERIAL" shell am start -n com.follow.clash/.MainActivity >/dev/null 2>&1
  sleep 13
else
  # 走 (a): 轻量修复 —— 直接改 config.yaml 里被顶掉的项, 再重载内核
  #   sniffer.enable 用平板侧 awk 脚本精确修(只改 sniffer 段下的那一个,
  #   避免 sed 全局替换误伤 dns.enable / mitm.enable)
  adb -s "$SERIAL" shell "su -c 'sh /data/local/tmp/ks_fix_sniffer.sh'" >/dev/null 2>&1
  adb -s "$SERIAL" shell "su -c 'sed -i \"s/^find-process-mode:.*/find-process-mode: strict/\" $CFG'" >/dev/null 2>&1
  # 重载内核让它吃到新配置
  adb -s "$SERIAL" shell am broadcast -a com.follow.clash.action.STOP \
    -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
  sleep 2
  adb -s "$SERIAL" shell am broadcast -a com.follow.clash.action.START \
    -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
  sleep 3
  log "已轻量修复生效 config.yaml(sniffer / find-process-mode)并重载内核"
fi

# --- 6) find-process-mode 兜底 ---
#     上面 (b) 路径(重启 App)后 App 会再次把它顶成 off, 这里再修一次。
#     (a) 路径已经顺手改好了。
if [ "$NEED_RELOAD" -eq 1 ] || [ "$NEED_SYNC" -eq 1 ]; then
  FPM=$(adb -s "$SERIAL" shell "su -c 'grep \"^find-process-mode:\" $CFG 2>/dev/null'" | tr -d '\r')
  case "$FPM" in
    *strict*) : ;;
    *) adb -s "$SERIAL" shell "su -c 'sed -i \"s/^find-process-mode:.*/find-process-mode: strict/\" $CFG'" >/dev/null 2>&1
       adb -s "$SERIAL" shell am broadcast -a com.follow.clash.action.STOP \
         -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
       sleep 2
       adb -s "$SERIAL" shell am broadcast -a com.follow.clash.action.START \
         -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
       sleep 3
       NEWFPM=$(adb -s "$SERIAL" shell "su -c 'grep \"^find-process-mode:\" $CFG 2>/dev/null'" | tr -d '\r')
       log "已把生效 config.yaml 的 find-process-mode 修正为 strict(原: $FPM, 现: $NEWFPM)" ;;
  esac
fi

# --- 7) 恢复 VPN ---
# 轻量路径: 直接 START VPN service
# 完整路径: 若 service 没起来, 拉起 App —— FlClash 启动后会自动恢复上次 VPN 运行状态
# (纯广播对已退出的进程无效, 这点踩过坑)
adb -s "$SERIAL" shell am broadcast -a com.follow.clash.intent.action.VPN_START_REQUESTED \
  -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
sleep 4
TUN=$(adb -s "$SERIAL" shell ip addr show tun0 2>/dev/null | grep -c 'inet ' | tr -d '\r')
if [ "$TUN" = "0" ]; then
  adb -s "$SERIAL" shell am start -n com.follow.clash/.MainActivity >/dev/null 2>&1
  sleep 7
  adb -s "$SERIAL" shell am broadcast -a com.follow.clash.intent.action.VPN_START_REQUESTED \
    -n com.follow.clash/.ServiceBroadcastReceiver >/dev/null 2>&1
  sleep 4
  TUN=$(adb -s "$SERIAL" shell ip addr show tun0 2>/dev/null | grep -c 'inet ' | tr -d '\r')
fi
log "同步完成, tun0=$( [ "$TUN" != "0" ] && echo UP || echo DOWN )"
[ "$TUN" = "0" ] && exit 1
exit 0
