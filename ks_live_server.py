# -*- coding: utf-8 -*-
"""
ks_live_server: 快手实况图直链服务（mitmproxy addon）

链路:
  插件 -> GET http://127.0.0.1:8765/live_photo?photo_id=X
       -> addon 调 adb 打开 ksnebula://work/X (PhotoDetailActivity)
       -> App 自己签名请求 /rest/nebula/photo/info2
       -> addon 从 response 钩子缓存解析实况数据
       -> 轮询命中后返回 JSON

返回格式:
  {"result": 1, "photo_id": X, "mtype": 3|6,
   "images": [{"index": 0, "is_live": false, "static_url": "...", "live_url": null}, ...],
   "main_mv_urls": ["..."]}     # mtype=3 单图实况时非空
"""
import json
import threading
import subprocess
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mitmproxy.http
from mitmproxy import ctx

ADB = __import__('os').environ.get('KS_ADB', '/usr/bin/adb')
ADB_SERIAL = __import__('os').environ.get('KS_ADB_SERIAL', '127.0.0.1:5555')
KS_PKG = 'com.kuaishou.nebula'
KS_PKG_MAIN = 'com.smile.gifmaker'  # 快手主版, 平板上两个都装, 用完一起杀
LISTEN_PORT = 8765
# FlClash 抓包配置静态托管(平板用 URL 导入)
PROFILE_PATH = '/home/zm/zmbot/astrbot_plugin_LinkFlow_aux/ks-mitm.yaml'
WAIT_TIMEOUT = 20.0

_lock = threading.Lock()
_info2_cache = {}  # photo_id(str) -> parsed result
_info2_ts = {}  # photo_id(str) -> cached time
_CACHE_TTL = 1800.0  # cached URLs expire (CDN pkey has TTL), 30min
_info2_err = {}  # photo_id(str) -> (ts, error dict) 错误响应快速通道, 不进主缓存
_pend_request = None  # 正在等的 photo_id
_woke_screen = False  # 本次请求是否因深链拉黑背光醒来(用完灭回去)
_saved_brightness = None  # 唤醒前的系统亮度, 用完还原
_saved_brightness_mode = None  # 唤醒前的亮度模式(0手动/1自动), 用完还原


def _adb_shell(*args, timeout=10):
    return subprocess.run([ADB, '-s', ADB_SERIAL, 'shell', *args],
                          capture_output=True, timeout=timeout)


def _screen_off():
    """屏幕是否处于不可用状态(灭屏 或 锁屏)。
    ⚠️ 2026-11-08 踩坑: 原来只看 'Display Power: state=OFF'。
       实际挂机平板经常是【屏幕亮着但处于锁屏】(Display Power: state=ON
       + isKeyguardShowing=true), 这种状态下深链同样会被系统吞掉
       (Activity 直接 onStop, 不发 info2) -> 504。
       现象: 截图显示锁屏界面"上滑解锁", App 进程在但详情页没渲染。"""
    try:
        out = _adb_shell('dumpsys', 'power').stdout.decode('utf-8', 'ignore')
        if 'Display Power: state=OFF' in out:
            return True
    except Exception:
        pass
    try:
        out = _adb_shell('dumpsys', 'window').stdout.decode('utf-8', 'ignore')
        if 'isKeyguardShowing=true' in out:
            return True
    except Exception:
        pass
    return False


def _dim_wake():
    """背光拉黑式唤醒: 灭屏时 am start 的深链会被系统吞掉(Activity 直接
    onStop, 不发 info2), 必须让屏幕处于活动态; 但挂机平板不能真亮屏,
    所以先存亮度/亮度模式->手动模式亮度0->亮屏, 屏幕是"开"的、光是灭的
    (OLED 亮度0 = 像素不发光, 真黑屏, 也无烧屏风险)。"""
    global _saved_brightness, _saved_brightness_mode
    try:
        cur = _adb_shell('settings', 'get', 'system', 'screen_brightness') \
            .stdout.decode('utf-8', 'ignore').strip()
        _saved_brightness = cur if cur.isdigit() else None
        mode = _adb_shell('settings', 'get', 'system', 'screen_brightness_mode') \
            .stdout.decode('utf-8', 'ignore').strip()
        _saved_brightness_mode = mode if mode.isdigit() else None
    except Exception:
        _saved_brightness = _saved_brightness_mode = None
    try:
        _adb_shell('settings', 'put', 'system', 'screen_brightness_mode', '0')
        _adb_shell('settings', 'put', 'system', 'screen_brightness', '0')
    except Exception:
        pass
    try:
        _adb_shell('input', 'keyevent', 'KEYCODE_WAKEUP')
        _adb_shell('wm', 'dismiss-keyguard')
    except Exception:
        pass
    # dismiss-keyguard 在锁屏(尤其有密码/通知栏展开)时可能一次不生效,
    # 轮询确认, 最多等 6s —— 不解锁的话深链必被吞(必 504)
    # 注意: 不用 KEYCODE_BACK 收通知栏(会连带退出快手 App, 反而坏事)
    for _ in range(6):
        try:
            out = _adb_shell('dumpsys', 'window').stdout.decode('utf-8', 'ignore')
            if 'isKeyguardShowing=true' not in out:
                break
        except Exception:
            break
        _adb_shell('input', 'keyevent', 'KEYCODE_MENU')  # 部分 ROM 用 MENU 消 keyguard
        _adb_shell('wm', 'dismiss-keyguard')
        time.sleep(1.0)


def _sleep_restore():
    """灭屏 + 还原亮度与亮度模式(先灭后还原, 下次手动亮屏显示正常)"""
    try:
        _adb_shell('input', 'keyevent', 'KEYCODE_SLEEP')
    except Exception:
        pass
    if _saved_brightness is not None:
        try:
            _adb_shell('settings', 'put', 'system', 'screen_brightness',
                       _saved_brightness)
        except Exception:
            pass
    if _saved_brightness_mode is not None:
        try:
            _adb_shell('settings', 'put', 'system', 'screen_brightness_mode',
                       _saved_brightness_mode)
        except Exception:
            pass


def _force_stop_app():
    """深链用完即杀 App。挂在作品页后台会持续拉广告/保活请求, 且留在
    前台快照里下次深链可能不重新加载; 冷启动仅多花 ~1s(实测), 换来每次
    都是干净会话。info2 响应已被 mitm 钩子截获缓存后才执行, 不会丢数据。
    平板同时装了极速版(nebula)和主版(gifmaker), 两个都杀, 防止主版被
    分享链/ scheme 拉起后常驻后台。"""
    for pkg in (KS_PKG, KS_PKG_MAIN):
        try:
            _adb_shell('am', 'force-stop', pkg)
        except Exception:
            pass


def parse_info2(data):
    """photo/info2 响应 -> 精简实况结构

    实况图(mtype=6)在 info2 里的字段分布(2026-11-08 实测):
      静态封面 : photo.cover_urls[]      —— {cdn, url}, url 是完整 http 地址
                 (ext_params.atlas.list 是同一个 kvif 图集路径, 但只有相对路径)
      实况视频 : photo.atlasLivePhotoInfos[].streamManifest
                 .adaptationSet[].representation[].url (+ backupUrl[])
      类型标记 : ext_params.mtype (6=实况图 3=单图实况), photo.atlasHasLivePhoto
    注意: ext_params.atlas 是「图集」原图(音乐 kvif 封面), 不是实况静态帧,
          早期误用 atlas 导致 static_url 为空。
    """
    out = []
    for p in (data.get('photos') or []):
        pid = str(p.get('photo_id') or '')
        if not pid:
            continue
        ep = p.get('ext_params')
        if isinstance(ep, str):
            try:
                ep = json.loads(ep)
            except Exception:
                ep = {}
        ep = ep or {}
        mtype = ep.get('mtype')

        # 静态封面: 优先 cover_urls(完整 URL), 退回 ext_params.atlas.list + cdn
        static_urls = []
        for cu in (p.get('cover_urls') or []):
            if isinstance(cu, dict) and cu.get('url'):
                static_urls.append(cu['url'])
        if not static_urls:
            atlas = ep.get('atlas') or {}
            cdns = atlas.get('cdn') or [c.get('cdn') for c in (atlas.get('cdnList') or []) if isinstance(c, dict)]
            cdns = [c for c in cdns if c]
            for path in (atlas.get('list') or []):
                if not path:
                    continue
                if path.startswith('http'):
                    static_urls.append(path)
                elif cdns:
                    static_urls.append(f'http://{cdns[0]}{path}')

        # 实况视频
        infos = p.get('atlasLivePhotoInfos') or []
        live_videos = []   # [(live_url, [backup...]), ...]
        for info in infos:
            if not isinstance(info, dict) or not info.get('isLivePhoto'):
                continue
            sm = info.get('streamManifest') or {}
            lv = None
            backup = []
            for aset in (sm.get('adaptationSet') or []):
                for rep in (aset.get('representation') or []):
                    if not rep.get('url'):
                        continue
                    if lv is None:
                        lv = rep['url']
                        backup = list(rep.get('backupUrl') or [])
                    else:
                        backup.append(rep['url'])
            if lv:
                live_videos.append((lv, backup))

        images = []
        # 静态封面: cover_urls 里多个 cdn 是同一张图的镜像(备份), 不是多张图 ——
        # 只取第一个当主图, 其余进 static_backups, 避免多出一张 is_live=False 的空图
        main_static = static_urls[0] if static_urls else None
        static_backups = static_urls[1:]
        if not live_videos:
            images.append({'index': 0, 'is_live': False,
                           'static_url': main_static, 'live_url': None,
                           'backup_urls': [], 'static_backups': static_backups})
        else:
            for i, (lv, bk) in enumerate(live_videos):
                images.append({'index': i, 'is_live': True,
                               'static_url': main_static if i == 0 else None,
                               'live_url': lv,
                               'backup_urls': bk,
                               'static_backups': static_backups if i == 0 else []})

        mv_urls = []
        for mv in (p.get('main_mv_urls') or []):
            if isinstance(mv, dict) and mv.get('url'):
                mv_urls.append(mv['url'])

        out.append({'result': 1, 'photo_id': pid, 'mtype': mtype, 'images': images,
                    'main_mv_urls': mv_urls,
                    'atlas_has_live_photo': bool(p.get('atlasHasLivePhoto')),
                    'caption': p.get('caption'), 'user_name': p.get('user_name'),
                    'like_count': p.get('like_count')})
    return out


class KsLiveAddon:
    def response(self, flow: mitmproxy.http.HTTPFlow):
        if flow.request.path.split('?')[0] != '/rest/nebula/photo/info2':
            return
        try:
            data = json.loads(flow.response.get_text(strict=False) or '')
        except Exception:
            return
        # 请求体 photoInfos=[{"photoId":...}], 拿到本次请求的 pid
        pid = None
        try:
            body = urllib.parse.parse_qs(flow.request.get_text(strict=False) or '')
            infos = json.loads((body.get('photoInfos') or ['[]'])[0])
            if isinstance(infos, list) and infos and isinstance(infos[0], dict):
                pid = str(infos[0].get('photoId') or '') or None
        except Exception:
            pid = None
        now = time.time()
        items = parse_info2(data)
        if not items:
            # 错误响应(如 403 仅关注者可见/作品已删除): 按 pid 进错误快速通道,
            # HTTP 侧立即返回, 不用傻等 20s 超时, 平板也不用每次白冷启动。
            # 不进主缓存(无 30min TTL 粘连), 作品转公开后下次深链即恢复。
            if pid and isinstance(data, dict) and data.get('result') not in (1, None):
                with _lock:
                    _info2_err[pid] = (now, {'result': data.get('result'),
                                             'error_msg': data.get('error_msg')})
            return
        for item in items:
            with _lock:
                _info2_cache[item['photo_id']] = item
                _info2_ts[item['photo_id']] = now
        ctx.log.info(f'[ks_live] info2 cached, total={len(_info2_cache)}')

    def load(self, loader):
        t = threading.Thread(target=_serve, daemon=True)
        t.start()
        ctx.log.info(f'[ks_live] http server on :{LISTEN_PORT}')


def _trigger_deep_link(photo_id):
    """深链打开作品页。灭屏状态下 am start 会被系统吞掉不处理
    (Activity 直接 onStop 不发 info2), 先背光拉黑式唤醒再打深链
    (挂机平板 7x24 灭屏是常态, 不唤醒必 504; 背光为 0, 屏幕不亮)。"""
    global _woke_screen
    if _screen_off():
        _dim_wake()
        _woke_screen = True
    uri = f'ksnebula://work/{photo_id}'
    try:
        subprocess.run([ADB, '-s', ADB_SERIAL, 'shell', 'am', 'start',
                        '-a', 'android.intent.action.VIEW', '-d', uri, KS_PKG],
                       capture_output=True, timeout=15)
        return True
    except Exception as e:
        ctx.log.error(f'[ks_live] adb fail: {e}')
        return False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ('/ks-mitm.yaml', '/ks-mitm.yml'):
            self._file(PROFILE_PATH)
            return
        if u.path not in ('/live_photo', '/live_photo/'):
            self._json(404, {'result': 404, 'error': 'use /live_photo?photo_id=X'})
            return
        qs = urllib.parse.parse_qs(u.query)
        pid = (qs.get('photo_id') or [''])[0].strip()
        if not pid.isdigit():
            self._json(400, {'result': 400, 'error': 'photo_id required'})
            return

        # 先查缓存（带TTL: 老直链pkey过期会被CDN 403）
        with _lock:
            cached = _info2_cache.get(pid)
            ts = _info2_ts.get(pid, 0.0)
        if cached and not qs.get('refresh') and time.time() - ts < _CACHE_TTL:
            self._json(200, dict(cached, cached=True))
            return

        # 深链触发，等 info2 响应（先清旧缓存防捞到过期直链）
        global _woke_screen
        _woke_screen = False
        with _lock:
            _info2_cache.pop(pid, None)
            _info2_ts.pop(pid, None)
            _info2_err.pop(pid, None)
        deadline = time.time() + WAIT_TIMEOUT
        trigger_ts = time.time()
        if not _trigger_deep_link(pid):
            self._json(502, {'result': 502, 'error': 'adb trigger failed'})
            return
        retried = False
        while time.time() < deadline:
            time.sleep(0.5)
            with _lock:
                item = _info2_cache.get(pid)
                err = _info2_err.get(pid)
            if item:
                self._json(200, dict(item, cached=False))
                if _woke_screen:
                    _sleep_restore()
                    _woke_screen = False
                _force_stop_app()
                return
            # 错误快速通道: 深链之后到达的错误响应(403/作品删除等), 立即返回,
            # 插件据此回落三方接口, 不用等满 20s
            if err and err[0] >= trigger_ts:
                self._json(200, dict(err[1], cached=False))
                if _woke_screen:
                    _sleep_restore()
                    _woke_screen = False
                _force_stop_app()
                return
            # 冷启动偶发深链被吞(App 起来了但没开作品页), 8s 没动静重发一次
            if not retried and time.time() - trigger_ts > 8:
                retried = True
                ctx.log.info(f'[ks_live] no info2 in 8s, re-fire deep link for {pid}')
                _trigger_deep_link(pid)
        self._json(504, {'result': 504, 'error': f'timeout waiting info2 for {pid}'})
        if _woke_screen:
            _sleep_restore()
            _woke_screen = False
        _force_stop_app()

    def _file(self, path):
        try:
            with open(path, 'rb') as f:
                body = f.read()
        except OSError:
            self._json(404, {'result': 404, 'error': 'profile file not found'})
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/yaml; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _serve():
    srv = ThreadingHTTPServer(('0.0.0.0', LISTEN_PORT), Handler)
    srv.serve_forever()


addons = [KsLiveAddon()]
