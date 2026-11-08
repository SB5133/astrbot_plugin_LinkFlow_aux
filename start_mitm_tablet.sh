#!/bin/bash
# 平板版启动: 常规 proxy 模式(NekoBox 连过来), 深链目标由 KS_ADB_SERIAL 指定
ulimit -n 65535
cd /home/zm/zmbot/astrbot_plugin_LinkFlow_aux
export KS_ADB=/usr/bin/adb
export KS_ADB_SERIAL=${KS_ADB_SERIAL:-192.168.2.32:5555}
exec ~/.local/bin/mitmdump -p 18080 --set block_global=false -w ks_live.flows -s ks_filter.py -s ks_live_server.py -s ks_probe.py
