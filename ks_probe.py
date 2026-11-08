# -*- coding: utf-8 -*-
"""ks_probe: 快手请求探针 —— 记录所有快手业务请求(method/host/path/status),
并重点检测 feed/photo/info 与 photo/info2 响应里是否携带实况图数据
(ext_params.atlas / atlasLivePhotoInfos / main_mv_urls)。
只写 /tmp/ks_probe.jsonl, 不影响既有缓存逻辑。"""
import json
import os
import time

from mitmproxy import http, ctx

KS_HOSTS = ("kuaishou", "gifshow", "yxcorp", "ksapisrv")
OUT = "/tmp/ks_probe.jsonl"
INTEREST = ("photo", "feed", "atlas", "live", "detail", "discover", "vision")


def _line(obj):
    try:
        with open(OUT, "a", encoding="utf-8") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _probe_live(resp_data):
    """在响应 JSON 里找实况图数据"""
    out = []
    if not isinstance(resp_data, dict):
        return out
    photos = resp_data.get("photos")
    if not isinstance(photos, list):
        photos = []
    for ph in photos:
        if not isinstance(ph, dict):
            continue
        ep = ph.get("ext_params")
        if isinstance(ep, str):
            try:
                ep = json.loads(ep)
            except Exception:
                ep = {}
        ep = ep or {}
        atlas = ep.get("atlas") if isinstance(ep.get("atlas"), dict) else {}
        ali = ph.get("atlasLivePhotoInfos") or []
        mv = ph.get("main_mv_urls") or []
        if atlas.get("list") or ali or ep.get("mtype"):
            out.append({
                "photo_id": str(ph.get("photo_id")),
                "mtype": ep.get("mtype"),
                "atlas_cdn": (atlas.get("cdn") or [None])[0],
                "atlas_list_n": len(atlas.get("list") or []),
                "live_info_n": len(ali),
                "mv_n": len(mv),
                "live_urls": [r.get("url") for i in ali for a in (i.get("streamManifest") or {}).get("adaptationSet") or []
                              for r in (a.get("representation") or []) if r.get("url")][:2],
                "static_urls": [("http://" + (atlas.get("cdn") or [""])[0] + x if not x.startswith("http") else x)
                                for x in (atlas.get("list") or [])][:2],
            })
    return out


class KsProbe:
    def request(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        if not any(k in host for k in KS_HOSTS):
            return
        p = flow.request.path.split("?")[0]
        _line({
            "t": time.time(),
            "kind": "req",
            "method": flow.request.method,
            "host": host,
            "path": p,
            "full": f"https://{host}{flow.request.path[:300]}",
            "interest": any(k in p for k in INTEREST),
            "req_body": (flow.request.get_text(strict=False) or "")[:600]
            if flow.request.method == "POST" and any(k in p for k in INTEREST) else "",
        })

    def response(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        if not any(k in host for k in KS_HOSTS):
            return
        p = flow.request.path.split("?")[0]
        status = flow.response.status_code
        rec = {
            "t": time.time(),
            "kind": "resp",
            "method": flow.request.method,
            "host": host,
            "path": p,
            "status": status,
            "size": len(flow.response.raw_content or b""),
        }
        if any(k in p for k in INTEREST):
            try:
                data = json.loads(flow.response.get_text(strict=False) or "")
            except Exception:
                data = None
            if data is not None:
                rec["result"] = data.get("result") if isinstance(data, dict) else None
                hits = _probe_live(data)
                if hits:
                    rec["LIVE"] = hits
        _line(rec)


addons = [KsProbe()]
