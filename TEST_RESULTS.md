# MicroWARP 测试结果对照表

测试日期：2026-08-14 至 2026-08-16（含本机 LAN 上游、MASQUE、多实例 DNS 修复复测、管理面板与强制重连验证）
测试环境：macOS Docker Desktop（arm64）、Docker 29.7.2、Cloudflare WARP、项目本地构建镜像 `microwarp-dev:local`。

> `UPSTREAM_SOCKS5_TRANSPORT=tun` 路径在 Docker 中需要 TUN 权限；本次集成测试以 `--privileged` 提供等效权限。`UPSTREAM_SOCKS5_TRANSPORT=tcp`（仅 MASQUE HTTP/2）不创建 TUN，也不需要 `/dev/net/tun`。

| 功能 | 测试方式与关键结果 | 结果 | 边界/备注 |
|---|---|---|---|
| Shell / Python 静态检查 | `bash -n`、`python3 -m py_compile`、`git diff --check` | 通过 | 覆盖入口、健康、滚动、实例控制和上游脚本。 |
| 控制台日志格式与脱敏 | `bash tests/test_log_utils.sh`、`python3 tests/test_lb_proxy.py`、`bash tests/test_microsocks_egress_family.sh microwarp-test:local`；Docker 镜像内输出 `[MicroWARP][组件][级别]` 冒烟测试 | 通过 | 统一控制面、实例、上游、健康、滚动重启和 LB 的日志前缀；上游 URI 不输出凭据。`LB_ACCESS_LOG=1` 会记录请求 ID、客户端地址/端口、用户 ID、目标、实际 IPv4 / IPv6 出口、后端实例序号与地址；HTTP 可解析请求头默认记录，认证、Cookie、Token、API Key 等字段值回归验证为脱敏。HTTP CONNECT 仅记录明文握手头；默认 `0` 不记录每个客户端目标。 |
| 实例状态变化表 | `bash tests/test_health_events.sh` | 通过 | 首次观测与状态/出口/国家代码 `loc`/PoP `colo`/后端池变化时输出完整图标表；每个就绪行并列展示 IPv4 / IPv6 出口和对应后端的 LB 活跃连接数。`🆕`、`🔄`、`✅`、`⏳`、`❌`、`⏸️` 和汇总均有回归验证。`checked_at` 或单独的连接数变化不会刷屏，`STATUS_EVENT_LOG=0` 可关闭表格；不经过 LB 的单实例轻量直连明确显示 `活跃连接=—`。 |
| 多实例命名空间 DNS | `bash tests/test_netns_utils.sh`；特权 Docker 中验证 `ip netns exec` 将 `/etc/netns/microwarpN/resolv.conf` 挂载为子实例的 `/etc/resolv.conf` | 通过 | 修复 Docker DNS `127.0.0.11` 仅在默认网络命名空间监听，导致多实例 `usque` / `wgcf` 注册域名解析报 `connection refused` 的问题。 |
| 镜像与 Compose | `docker build -t microwarp-dev:local .`；`docker compose config` | 通过 | microsocks 补丁、usque、hev-socks5-tunnel 均完成构建。 |
| 单实例 WireGuard SOCKS5 | `wg show` 有最近握手；经 SOCKS5 请求 trace 返回 `warp=on` | 通过 | 默认轻量路径。 |
| 同端口 Mixed | `PROXY_MODE=mixed`、唯一 `BIND_PORT=1080`；SOCKS5 和 HTTP CONNECT 均返回 `warp=on` | 通过 | 内部 microsocks 仅监听 `127.0.0.1:1081`。 |
| Mixed 认证 | `admin/secret` 的 SOCKS5 与 HTTP Basic 成功；无认证 SOCKS5 被拒绝 | 通过 | 对外认证只在 Mixed/LB 前端执行。 |
| Mixed 单元测试 | `python3 tests/test_lb_proxy.py` | 通过 | 覆盖 SOCKS5、HTTP CONNECT、普通 HTTP path 重写、`Proxy-Connection` 剥离、`SOCKS_USER/SOCKS_PASS` 认证；兼容 `LB_STICKY_MODE=username-hash` 的 Rendezvous Hash 及匿名 `round`/`rotate` 分发。默认 `LB_STICKY_MODE=username-round` 采用仅内存的 username 状态型轮询，健康池稳定时严格均匀；后端摘流会删除受影响映射，恢复节点作为新的轮询候选重新加入。 |
| 单端口匿名管理面板 | `python3 tests/test_lb_proxy.py`、`bash tests/test_management_control.sh` | 通过 | `MANAGEMENT_UI_ENABLED=1` 时，`/__microwarp/` 与状态/连接 API 复用 BIND_PORT；在 `socks5` 模式及开启代理认证时管理路径仍匿名可用，非管理 HTTP 不会被放宽为 HTTP Proxy。覆盖活跃连接实时登记、字节统计、关闭移除，以及停用、启用、优雅重连的摘流/排空状态机；实例表完整展示进程、人工状态、健康状态、IPv4 / IPv6 出口、国家、PoP、后端池与连接数；每条活跃连接展示内部 SOCKS 成功响应回传的实际 IPv4 / IPv6 出口地址族。强制重连会摘流后跳过排空、立即重建实例并明确中断其既有连接。 |
| 启动健康入池 | Mixed 模式启动后约 6 秒写入 `backends.txt`，trace 为 `warp=on` | 通过 | `HEALTH_START_PERIOD=90` 只抑制重启；不会再延迟已就绪后端入池。 |
| 标准 SOCKS5 上游建立 WireGuard WARP | 临时标准 SOCKS5 relay 的 TCP + UDP relay 验证通过；TUN 就绪；WireGuard 最近握手 12 秒；trace `warp=on`；Docker health 通过 | 通过 | 验证注册、握手和实际业务流量均经上游 TUN。 |
| 上游失败保护 | 启动时数值 HTTPS 与 `1.1.1.1:53` UDP DNS 均经 TUN 探测 | 通过 | UDP 不可用时恢复原路由并以退出码 1 退出，`UPSTREAM_REQUIRED=1` 不会回退直连。 |
| 本机 `127.0.0.1:20122` 上游，`udp` 模式 | TCP 探测通过；UDP 探测超时；容器退出而未注册/直连 WARP | 未通过（已定位） | Sing-box 的 UDP ASSOCIATE 返回 `127.0.0.1:动态端口`，在 Docker bridge 中该地址指向容器自身。 |
| 本机 `127.0.0.1:20122` 上游，`tcp` 模式 | TCP 探测通过；UDP 探测失败 | 未通过（已定位） | `tcp` 是 UDP-in-TCP 扩展，并非普通 TCP CONNECT；当前 Sing-box 配置未提供该扩展。 |
| 标准 TCP-only SOCKS5 上游 + MASQUE HTTP/2 | `bash tests/test_upstream_tcp_mode.sh`、`python3 tests/test_tcp_socks5_relay.py`；Docker 内以仅支持 SOCKS5 CONNECT 的 MicroSOCKS 作为上游，`TUNNEL_PROTOCOL=masque`、`MASQUE_PROXY_MODE=socks`、`MASQUE_HTTP2=1`、`UPSTREAM_SOCKS5_TRANSPORT=tcp`；trace 返回 `warp=on` | 通过 | 注册经标准 SOCKS5 CONNECT；数据面经本地 `127.0.0.1:443` 固定 endpoint relay 转发，保留 usque 公钥钉扎；未挂载 `/dev/net/tun`，不需要 UDP ASSOCIATE。 |
| 本机 `192.168.1.15:20122` 上游 | TCP CONNECT 成功；UDP ASSOCIATE 返回 `192.168.1.15:动态端口`；上游 TUN TCP+UDP 验证通过；自动注册、WireGuard 握手、trace `warp=on`、health 均通过 | 通过 | Sing-box 已改为 LAN 可达监听，且回传容器可路由的 UDP relay 地址。 |
| 域名 IPv4/IPv6 偏好 | `bash tests/test_resolve_preference.sh`；MicroSOCKS 构建补丁包含 `ipv4_prefer`、`ipv6_prefer`、`ipv4_only`、`ipv6_only` 与优先失败回退 | 通过 | `ipv4` / `ipv6` 兼容为 `*_only`。仅 WireGuard 的域名 SOCKS 请求受影响；数值 IPv4/IPv6 不触发代理 DNS，MASQUE 由 usque DNS 决定。 |
| 双实例唯一入口、轮询和滚动重启 | 前序全链路集成：两个 network namespace 均握手；唯一入口的 SOCKS5/HTTP 均为 `warp=on`；逐实例摘流、排空、重启、验证成功 | 通过 | 需要 `NET_ADMIN`、`SYS_MODULE`、`SYS_ADMIN`、`net.ipv4.ip_forward=1`；部分宿主还需要 `seccomp=unconfined`。 |
| MASQUE HTTP/3/QUIC 直连及经临时标准 SOCKS5 上游 | usque 注册成功，但连接 `162.159.198.2:443` 均报 `failed to dial connect-ip: timeout: no recent network activity` | 未通过（当前网络） | 临时上游 relay 与 Docker Desktop 处在同一 UDP 受限网络，不能改变 UDP/443 可达性。 |
| MASQUE HTTP/3/QUIC 经本机 `192.168.1.15:20122` 上游 | 上游 TUN TCP+UDP 验证、MASQUE 注册与 `l4-socks` 监听均成功；实际 SOCKS CONNECT 在 10 秒后失败 | 未通过 | 同一上游已可承载 WireGuard UDP，但到 Cloudflare MASQUE HTTP/3/UDP 443 的 CONNECT-IP 数据面仍超时。 |
| MASQUE HTTP/2 TCP 回退直连 | `TUNNEL_PROTOCOL=masque`、`MASQUE_PROXY_MODE=socks`、`MASQUE_HTTP2=1`；日志 `Connected to MASQUE server`；trace `warp=on` | 通过 | full `socks` 模式才支持 HTTP/2 回退。 |
| MASQUE HTTP/2 经标准 SOCKS5 上游 | 上游 TUN TCP+UDP 验证通过；MASQUE 注册完成并连接成功；trace `warp=on`；health 通过 | 通过 | 证明 MASQUE 注册和外层 TCP/443 也可经标准 SOCKS5 上游。 |
| MASQUE IPv4-only DNS | `ENABLE_IPV6=0` 时注入 `MASQUE DNS=1.1.1.1,1.0.0.1` | 通过 | 避免 usque 默认向不可达 IPv6 DNS 发起查询。 |

## 本机 20122 的可用条件

容器访问宿主可设置：

```dotenv
UPSTREAM_SOCKS5=socks5://host.docker.internal:20122
UPSTREAM_SOCKS5_UDP_MODE=udp
UPSTREAM_VERIFY=1
UPSTREAM_REQUIRED=1
```

但这要求 SOCKS5 服务对 Docker 容器返回**可路由的 UDP relay 地址**。若服务绑定在宿主 `127.0.0.1` 且返回同一 loopback 地址，可在原生 Linux 使用 `network_mode: host`，或调整 SOCKS5 服务监听/UDP relay 的对外地址。只验证 `curl --proxy socks5h://…` 的 TCP CONNECT 成功不足以验证 WARP。
