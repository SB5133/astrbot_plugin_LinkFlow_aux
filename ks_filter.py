# -*- coding: utf-8 -*-
"""mitmdump 过滤器: 只打印快手系域名请求行, 全量流量仍落盘"""
import json
from mitmproxy import http

# 与 FlClash profile(ks-mitm.yaml) 的 DOMAIN 规则保持一致
# 2026-11-08 补: kwaizt / kuaishouzt / kwaixiaodian
#   这三个之前既没被 mihomo 规则覆盖, 也没被本过滤器打印,
#   导致"明明有流量但 flows 里查不到"的盲区。
KS_HOSTS = ("kuaishou", "gifshow", "yxcorp", "ksapisrv",
            "kwaizt", "kuaishouzt", "kwaixiaodian")


def request(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host
    if any(k in host for k in KS_HOSTS):
        line = f"{flow.request.method} https://{host}{flow.request.path[:180]}"
        print(line, flush=True)
        # API 请求的 body 摘要落到单独文件, 供模板校准
        if flow.request.method == "POST" and any(
            k in flow.request.path for k in ("photo", "feed", "detail", "live")
        ):
            entry = {
                "url": f"https://{host}{flow.request.path}",
                "body": flow.request.get_text(strict=False)[:4000],
            }
            with open("/tmp/ks_api_bodies.jsonl", "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
