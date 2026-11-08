#!/bin/bash
ulimit -n 65535
cd /home/zm/zmbot/astrbot_plugin_LinkFlow_aux
exec ~/.local/bin/mitmdump --mode transparent -p 18080 --set block_global=false -w ks_live.flows -s ks_filter.py -s ks_live_server.py
