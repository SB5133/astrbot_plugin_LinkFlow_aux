#!/bin/bash
# 在平板上直接跑的配置体检(避免多层 adb shell 引号地狱)
# 输出 key=value 形式, 供服务器侧脚本解析
T=192.168.2.32:5555
BASE=/data/data/com.follow.clash
CFG=$BASE/files/config.yaml

if [ ! -f "$CFG" ]; then
  echo "CFG_MISSING=1"
  exit 0
fi

echo "CFG_MISSING=0"

# sniffer.enable
SNIFF_LINE=$(grep -A1 "^sniffer:" "$CFG" 2>/dev/null | tail -1)
case "$SNIFF_LINE" in
  *"enable: true"*) echo "SNIFFER_OK=1" ;;
  *) echo "SNIFFER_OK=0" ;;
esac

# proxies 里的抓包代理端口
if grep -A6 "^proxies:" "$CFG" 2>/dev/null | grep -q "port: 18080"; then
  echo "PROXY_PORT_OK=1"
else
  echo "PROXY_PORT_OK=0"
fi

# rules 段存在且含 PROCESS-NAME
if grep -q "^rules:" "$CFG" 2>/dev/null; then
  echo "RULES_OK=1"
else
  echo "RULES_OK=0"
fi
if grep -q "PROCESS-NAME,com.kuaishou.nebula" "$CFG" 2>/dev/null; then
  echo "PROC_RULE_OK=1"
else
  echo "PROC_RULE_OK=0"
fi

# find-process-mode
FPM=$(grep "^find-process-mode:" "$CFG" 2>/dev/null)
case "$FPM" in
  *strict*) echo "FPM_OK=1" ;;
  *) echo "FPM_OK=0" ;;
esac

# MATCH,DIRECT 兜底规则存在(其它流量直连)
if grep -q "MATCH,DIRECT" "$CFG" 2>/dev/null; then
  echo "MATCH_OK=1"
else
  echo "MATCH_OK=0"
fi
