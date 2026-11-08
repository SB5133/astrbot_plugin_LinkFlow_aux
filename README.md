# astrbot_plugin_LinkFlow_aux

快手实况图（Live Photo / kvif）直链获取**辅助服务端**。为 [astrbot_plugin_LinkFlow](https://github.com/SB5133/astrbot_plugin_LinkFlow) v2.0.0+ 提供稳定的 `live_url` 数据源。

> 仅作个人学习研究用途。工作原理与实现思路不公开，本仓库只提供部署与使用说明。

## 一、需要什么

| 角色 | 要求 | 说明 |
|---|---|---|
| 服务器 | 任意能跑 Python 的 Linux（无头机器也行） | 跑 mitmproxy 与本服务，CPU 占用≈0 |
| 安卓设备 | **已 root**，Android 11+，与服务器同局域网 | 原生 ARM 优先；推荐二手平板 7×24 挂机 |
| 快手极速版 | 装在安卓设备上 | 游客身份即可，无需登录 |
| AstrBot | astrbot_plugin_LinkFlow ≥ v2.0.0 | 插件配置指向本服务 |

软件清单：mitmproxy、adb（服务器端）、**FlClash**（平板端代理，规则分流：仅快手系域名走抓包代理，其余全部直连）、Magisk。

## 二、部署

### 2.1 服务器端

```bash
# 1. 依赖
pip install --user mitmproxy
apt install android-tools-adb

# 2. 首次启动生成 CA (~/.mitmproxy/)
./start_mitm_tablet.sh &
# 仓库内 c8750f0d.0 为示例证书；自建环境请用自己的 CA 重新算哈希名
# openssl x509 -inform PEM -subject_hash_old -in ~/.mitmproxy/mitmproxy-ca-cert.pem | head -1

# 3. 平板的 adb 序列号在 start_mitm_tablet.sh 里改（默认 192.168.2.32:5555）
adb connect <平板IP>:5555

# 4. 防火墙放行局域网
ufw allow from 192.168.2.0/24 to any port 18080 proto tcp

# 5. systemd: proxy 常驻 + keepalive 每 120s 兜底
cp ks-live-proxy.service ks-live.service ks-live.timer /etc/systemd/system/
systemctl enable --now ks-live-proxy.service
systemctl enable --now ks-live.timer
```

> `ks-live-proxy.service` 常驻 mitmdump + ks_live_server(:8765)，崩溃 5s 自愈；
> `ks-live.timer` 每 120s 跑 keepalive.sh 只做平板侧维护(ADB/CA/wake_lock/VPN/App)。
> 不要把 mitmdump 放回 keepalive.sh 里 nohup 拉起——oneshot 退出时 systemd 会按
> cgroup 把顺手拉起的进程全部杀掉(KillMode=control-group 默认行为)，重启后必丢。

### 2.2 平板端（root，零 /system 写入，重启自动还原）

```bash
adb connect <平板IP>:5555
adb push tablet_setup.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/tablet_setup.sh'"
```

tablet_setup.sh 做三件事：
1. mitm CA 挂入系统信任链（bind mount，不写系统分区，不怕变砖）
2. Doze 白名单 + 内核 wake_lock（灭屏 CPU 不睡）
3. 无线 adb（步步高等魔改系统请用系统自带开关，脚本第 3 步可跳过）

设备上还需（**FlClash 方案**，取代已废弃的 NekoBox）：
- 安装 FlClash（`com.follow.clash`），在「配置 → 添加配置 → **链接**」填入
  `http://<服务器IP>:8765/ks-mitm.yaml`
- **必须用「链接」类型，不能用「本地文件」**：本地文件型 profile 不会自动更新，
  服务器改了配置平板永远不知道（见 2.2.3 配置同步与漂移自愈）
- 导入后启动 VPN 即可；平板上 VPN 隧道设备名为 `tun0`（FlClash 占用 `198.18.0.1/30`）
- 抓包用的 mitm CA 仍由 `tablet_setup.sh` bind mount 进系统信任链，**FlClash 自身无需再装 CA**

> 为什么不用 NekoBox：全局接管导致大量 App 不可用；FlClash 的规则分流把影响面收敛到快手。
> FlClash 未注册 `BOOT_COMPLETED`，平板重启后不会自启 VPN，靠服务端 `ks-live.timer`
> 每 120s 的 keepalive 兜底拉起（广播 `com.follow.clash.intent.action.VPN_START_REQUESTED`）。

#### 2.2.1 sniffer 必须开（2026-11-08 修复的关键）

抓包配置里 `sniffer.enable: true` **不能关**。原因：

- mihomo 在 TUN 模式下对 TLS 连接只能看到**目标 IP**，看不到域名。
  没有 sniffer 时，规则里的 `DOMAIN-KEYWORD,kuaishou` 之类全部匹配不上
  （历史日志里见过 `POST https://118.121.194.206/rest/nebula/photo/info2`，
  裸 IP 连 `DOMAIN-KEYWORD` 命不中 → 落到 `MATCH,DIRECT` → **绕过抓包**）。
- 开了 sniffer 之后 mihomo 从 TLS ClientHello 的 SNI 里还原出域名，
  `az3-api.ksapisrv.com` 这类业务域名才能正确命中规则走代理。

实测症状：作品详情页能正常打开（App 侧正常），但 mitmproxy 只看得到
`gdfp / kste / ulogjs / pushjs` 这类启动类请求，**始终收不到
`/rest/nebula/photo/info2`** → 服务端一直 504「timeout waiting info2」。

配置里另加了两条 `PROCESS-NAME` 规则作为双保险（裸 IP 也走代理）：

```yaml
rules:
  - DOMAIN-KEYWORD,kuaishou,PROXY
  - DOMAIN-KEYWORD,gifshow,PROXY
  - DOMAIN-KEYWORD,yxcorp,PROXY
  - DOMAIN-KEYWORD,ksapisrv,PROXY
  - DOMAIN-SUFFIX,kuaishou.com,PROXY
  - DOMAIN-SUFFIX,kuaishouapp.com,PROXY
  - DOMAIN-SUFFIX,kwai.com,PROXY
  - DOMAIN-SUFFIX,ksapis.cn,PROXY
  - PROCESS-NAME,com.kuaishou.nebula,PROXY
  - PROCESS-NAME,com.smile.gifmaker,PROXY
  - MATCH,DIRECT
```

> **注意**：FlClash 每次启动会用「profile + App 内全局设置」重新生成
> `files/config.yaml`，App 全局设置里的 `find-process-mode`/`sniffer` 开关
> 会覆盖 profile 里的同名项。若发现抓不到包，用 MT 管理器改
> `/data/data/com.follow.clash/files/config.yaml`（需 root），或直接在
> FlClash 设置里打开对应开关。

#### 2.2.2 必须阻断快手系 UDP（2026-11-08 修复的关键之二）

只开 sniffer 还不够。快手详情页 API 集群（`az3-api.ksapisrv.com`、
`az3-live.ksapisrv.com`、`api.kwaizt.com`、`api.kuaishouzt.com`）走的是
**8443 端口的 QUIC(HTTP/3) over UDP**，而 mitmproxy 上游是 `type: http` 代理，
**不支持 UDP 转发**。

mihomo 命中 PROXY 规则后对 UDP 连接会**静默回退 DIRECT** —— 域名规则写对了，
流量照样绕过抓包。症状：详情页在 App 侧完全正常，但 mitmproxy 永远收不到
`/rest/nebula/photo/info2` → 服务端干等到 504；FlClash 连接面板里这些域名
的出口显示 `DIRECT :8443`。

对策是**用 REJECT 逼 App 从 QUIC 回退到 TCP+TLS**，这样才会走 PROXY 进抓包：

```yaml
rules:
  - AND,((DOMAIN-KEYWORD,kuaishou),(NETWORK,udp)),REJECT
  - AND,((DOMAIN-KEYWORD,gifshow),(NETWORK,udp)),REJECT
  - AND,((DOMAIN-KEYWORD,yxcorp),(NETWORK,udp)),REJECT
  - AND,((DOMAIN-KEYWORD,ksapisrv),(NETWORK,udp)),REJECT
  - AND,((DOMAIN-KEYWORD,kwaizt),(NETWORK,udp)),REJECT
  - AND,((DOMAIN-KEYWORD,kuaishouzt),(NETWORK,udp)),REJECT
  - AND,((DOMAIN-KEYWORD,kwaixiaodian),(NETWORK,udp)),REJECT
  # 进程兜底: sniffer 失配还原不出域名时再拦一次
  - AND,((PROCESS-NAME,com.kuaishou.nebula),(NETWORK,udp)),REJECT
  - AND,((PROCESS-NAME,com.smile.gifmaker),(NETWORK,udp)),REJECT
```

修复后对比：面板里四个域名出口 `DIRECT :8443` → `ks-mitm :443`，
`ks_live.flows` 里 `photo/info2` 计数 0 → 1，`kwaizt` 0 → 15，`kuaishouzt` 0 → 35。

> **代价**：这台平板上的快手 App 用不了 HTTP/3。这是抓包的必要代价。
> 以后要抓别的 App 的 QUIC 流量，得把上游换成支持 UDP 的 SOCKS5 代理。

> **别忘了同步过滤器**：mihomo 规则放行了域名，mitmproxy 侧
> `ks_filter.py` 的 `KS_HOSTS` 也必须包含同样的关键字，否则即使抓到了
> 也不打印，形成「明明有流量但查不到」的盲区。

#### 2.2.3 配置同步与漂移自愈

FlClash 的 profile 一旦是「本地文件」类型，服务器改了配置平板永远不知道；
即使改成 URL 订阅，App 全局设置也会在每次启动时把 profile 里的
`find-process-mode` 顶成 `off`（改 prefs 无效，直接改 `config.yaml` 也会被改回）。

因此**服务器上的 `ks-mitm.yaml` 是唯一真源**，由 `ks_sync_flclash.sh` 每分钟
（`ks-live.timer` 周期）比对 md5 并自愈：

| 脚本 | 作用 |
|---|---|
| `ks_sync_flclash.sh` | 比对 md5 → 漂移则推送 profile + 删 `config.yaml` + 重启 App 重建 → 强制把 `find-process-mode` 修正回 `strict` → STOP/START 广播重载内核 |
| `ks_cfg_doctor.sh` | 平板侧 7 项体检（profile 类型/URL、config.yaml 是否含新规则、sniffer、find-process-mode、tun0、代理残留…） |
| `ks_fix_sniffer.sh` | 只改 sniffer 段，不误伤其它 `enable: false` 字段 |

> **验证新规则是否真的生效，必须看平板上
> `/data/data/com.follow.clash/files/config.yaml` 里的 `rules` 条数**，
> 只看 profile md5 一致是不够的 —— 早期同步脚本有个路径判定 bug
> （`NEED_RELOAD && NEED_SYNC` 写成 `&&`），profile 漂移但体检通过时只走
> 「轻量修复」，profile 里的新 rules 永远进不了生效的 `config.yaml`。
> 已修为 `||`。

### 2.3 平板日常控制（MT 管理器一键执行）

| 脚本 | 作用 |
|---|---|
| `ks_status.sh` | 体检：屏幕/唤醒锁/CA/快手 App/FlClash 进程/VPN 隧道/全局代理 七项 |
| `ks_off.sh` / `ks_on.sh` | 灭屏 / 亮屏（CPU 不睡，服务不受影响） |
| `ks.sh off\|on\|status` | 合订本（终端用，自动提权） |

> 灭屏本质是 KEYCODE_POWER 锁屏，CPU 靠 wake_lock 保持；`screen_off.sh`/`screen_on.sh` 是裸版本。

### 2.4 插件端

astrbot_plugin_LinkFlow ≥ v2.0.0。在**平台配置 → 快手(kuaishou)** 里填：

| 配置项 | 值 |
|---|---|
| `live_photo_native_url` | `http://<容器可达的宿主IP>:8765` |
| `live_photo_enabled` | `true` |

> **地址不能填 `127.0.0.1`**：AstrBot 容器有独立 netns（本项目是 `zmbot_net`），
> `127.0.0.1` 指向容器自身，访问不到宿主上的 mitmdump。
> 用宿主在容器网络里的网关地址，实测 `http://172.21.0.1:8765` 可通。
> 同机部署（非容器）时才可以用 `127.0.0.1:8765`。
>
> 注意这两项是**平台级**配置，落在 `parsers_template` 里 `__template_key=kuaishou`
> 的那一项；写到配置 JSON 顶层会被 AstrBot 当无效键清掉。

## 三、验证

```bash
# 服务端自测
curl 'http://127.0.0.1:8765/live_photo?photo_id=<数字ID>&refresh=1'
# 期望: {"result":1, "mtype":6, "images":[{"is_live":true,
#         "static_url":"http://...kvif", "live_url":"https://...mp4",
#         "backup_urls":[...], "static_backups":[...]}]}
# 灭屏下同样可用；目标 App 被杀会冷启动，多花 ~1s
```

实测样例（photo_id=5206161384390293650，2026-11-08）：

| 字段 | 值 |
|---|---|
| `mtype` | `6` |
| `static_url` | `http://zj66.a.kwimgs.com/ufile/atlas/..._0.kvif`（200, image/kvif） |
| `live_url` | `https://v1-plat-fdl.wsukwai.com/ksc2/....mp4?...pkey=...`（200, video/mp4） |
| `backup_urls` | 1 条备用实况 CDN |
| `static_backups` | 1 条备用静态 CDN |

> **字段位置易踩坑**：实况静态封面在 `photo.cover_urls[]`（完整 URL），
> **不是** `ext_params.atlas.list`——后者是同一张图的相对路径（且是 `.kvif` 私有格式）。
> `ext_params.mtype` 才是类型标记（6=实况图，3=单图实况）。

## 四、运维备忘

- 平板/容器上**永远不要设全局 http_proxy**（keepalive 会自动清残留）
- Android 14 的系统 CA 在 APEX 分区，Android 11 直接 bind mount `/system/etc/security/cacerts`
- **x86 模拟器跑不了**目标 App（转译层崩溃），必须真机/原生 ARM
- toybox grep 不支持 `grep -o 'A\|B'` 交替写法（静默返回空），脚本里用 sed
- 某些厂商 ROM 的 adbd 被 vendor 接管，root 改 `service.adb.tcp.port` 无效，用系统自带开关
- 桌面「全部清除」批量杀 App 不影响本服务：目标 App 冷启动多花 ~1s，VPN 由 always-on 自动复活
- mitm FD 耗尽（Errno 24）：启动脚本已带 `ulimit -n 65535`
- 短链 → 数字 photo_id：`curl -sIL 'http://v.kuaishou.com/<code>'` 看 Location，
  落地页 `https://kphm5nf3.m.chenzhongtech.com/fw/photo/...` 的 HTML 里
  `"photoId":"<19~20位数字>"` 就是数字 ID（URL 上的 `photoId=3xeavfs25ngpb4m` 是字符串形式）

## 五、文件清单

```
ks_live_server.py        # mitmproxy addon + HTTP API :8765
ks_filter.py             # mitm 日志过滤器(KS_HOSTS 需与 mihomo 规则一致)
ks_probe.py              # 请求探针(诊断用): 落 /tmp/ks_probe.jsonl, 含实况字段探测
start_mitm_tablet.sh     # 启动脚本（proxy 模式 :18080）
keepalive.sh             # 120s 兜底保活（配 systemd timer）
ks-live.service/.timer   # systemd 单元
ks-mitm.yaml             # FlClash 抓包配置（服务器托管, :8765/ks-mitm.yaml）
ks_sync_flclash.sh       # 配置同步 / 漂移自愈（服务器唯一真源 -> 平板 profile）
ks_cfg_doctor.sh         # 平板侧 7 项配置体检
ks_fix_sniffer.sh        # 只修 sniffer 段（不误伤其它 enable:false）
ca_remount.sh            # CA bind mount 重挂（平板重启后丢则重挂）
tablet_setup.sh          # 平板一次性配置
tablet_undo.sh           # 一键还原
ks.sh / ks_off.sh / ks_on.sh / ks_status.sh  # 平板本地控制台
screen_off.sh / screen_on.sh                 # 裸灭屏/亮屏
c8750f0d.0               # mitm CA 证书示例
```

> `apk/` 目录已移除：原 `nekobox-1.4.2-arm64.apk` 随 NekoBox 废弃一并清掉
> （NekoBox 全局接管导致大量 App 不可用，已换 FlClash 规则分流）。
