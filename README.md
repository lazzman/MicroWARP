# MicroWARP 🚀

[![Docker Pulls](https://img.shields.io/badge/docker-ready-blue.svg)](https://github.com/lazzman/MicroWARP/packages)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *请严格遵守您所在国家和地区的法律法规。任何因违法违规使用本项目而引发的法律纠纷或后果，均与本项目及作者无关。*
>
> *Please strictly comply with the laws and regulations of your country and region. Any legal disputes or consequences arising from illegal use of this project have nothing to do with this project and its authors.*

[English](#english) | [中文说明](#chinese)

### 📊 Performance Comparison

Here is a real-world performance test on a 1C1G (1 vCPU, 1GB RAM) VPS, comparing MicroWARP with the widely used `caomingjun/warp`.

以下是在 1C1G 服务器上的真实运行数据截图对比：

| Metric (指标) | `caomingjun/warp` (Official Daemon) | 🚀 `MicroWARP` (Pure C + Kernel approach) | Improvement (提升) |
| :--- | :--- | :--- | :--- |
| **Image Size**<br>(Docker 镜像体积) | 201 MB | **~30 MB** *(内置可选控制面)* | 📉 **~-85%** |
| **RAM Usage**<br>(日常内存占用) | ~150 MB | **极简模式约 1 MB**；启用 Mixed/LB 后按功能增加 | 📉 **默认路径显著降低** |
| **CPU Overhead**<br>(高并发 CPU 损耗) | High (Userspace App) | **~0.25%** (Kernel Space) | ⚡ **Near Zero** |
| **Core Engine**<br>(底层核心引擎) | Cloudflare `warp-cli` (Rust) | Linux `wg0` + Pure C `microsocks` *(default)*<br>Optional **MASQUE** via `usque` | 🛠️ **Minimalist + Compatible** |
| **IP Stack**<br>(协议栈) | Mostly IPv4-focused | **Dual-stack IPv4 + IPv6** | 🌐 **Native** |
| **Tunnel protocol**<br>(隧道协议) | WireGuard / MASQUE (daemon) | **WireGuard kernel (default)** or **MASQUE userspace** | 🔀 **Selectable** |



> **🔥 Real `docker stats` output:**
> ```text
> CONTAINER ID   NAME       CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O
> 2fa58f84c517   warp       0.25%     800KiB / 967.4MiB     0.08%     48.8MB / 39.1MB   238kB / 36.9kB
> ```
> *Yes, you read that right. It processed ~90MB of traffic using only **800 KB** of RAM!* *是的，你没看错。它仅使用了 **800 KB** 的内存，就处理了约 90 MB 的流量！*

---

<a name="english"></a>
## 🇬🇧 English

A minimalist, high-performance Cloudflare WARP SOCKS5 proxy in Docker.
Designed as a lightweight drop-in replacement for standard WARP proxy images (e.g., `caomingjun/warp`).

### 🌟 Why MicroWARP?

Many popular WARP Docker images rely on the official Cloudflare `warp-cli` daemon. This approach typically results in significant memory usage (often **150MB+**) and potential process overhead under high concurrency.

**MicroWARP** is built differently:
1. **Kernel-Level WireGuard (default)**: Instead of the userspace client, it leverages the native Linux `wg0` interface for near-zero CPU overhead.
2. **Optional MASQUE**: Set `TUNNEL_PROTOCOL=masque` to use [usque](https://github.com/Diniboy1123/usque) (CONNECT-IP over HTTP/3). Better when WireGuard UDP is QoS'd/blocked; traffic looks like HTTPS on **UDP/TCP 443**.
3. **MicroSOCKS Engine**: WireGuard path uses pure C `microsocks`; MASQUE path uses `usque` `l4-socks` / `socks`.
4. **Minimal Memory Footprint (WireGuard)**: Runs smoothly on **< 5MB RAM** (often ~800KB). MASQUE is userspace QUIC and needs far more RAM (see below).
5. **Native Dual-Stack**: Full **IPv4 + IPv6** WARP routing on the WireGuard path (`AllowedIPs = 0.0.0.0/0, ::/0`), with IPv6 policy routing for inbound reply paths.
6. **Seamless Tailscale Integration**: On the WireGuard path, restores asymmetric routing for IPv4 (`100.64.0.0/10`) and IPv6 (`fd7a:115c:a1e0::/48`).
7. **Multi-Arch**: Native support for `amd64` and `arm64` (plus `armv7` registration path).


### 🎯 Use Cases
*   **API Routing**: Route crawlers or AI API gateways (like Grok, ChatGPT) through MicroWARP to leverage high-trust Cloudflare IPs.
*   **Outbound Privacy**: Obfuscate your server's real IP by using WARP as your default egress network to prevent direct traceback.
*   **Sidecar Proxy**: Perfectly designed as an ultra-lightweight Docker Sidecar network gateway.
*   **IPv6 Egress**: Reach IPv6-only destinations via Cloudflare WARP when the host has limited or no native IPv6 peering.

### 🧩 Host prerequisites

Docker containers share the **host Linux kernel**. `TUNNEL_PROTOCOL=wireguard` uses `wgcf + wg-quick` to create a kernel `wg0` interface, so the host must provide the WireGuard netdevice driver; installing `wireguard-tools` only inside the image is not sufficient.

#### WireGuard path: verify the host before starting the container

Run these commands on the Docker host:

```bash
modprobe wireguard
lsmod | grep -w wireguard
ip link add microwarp-wg-check type wireguard
ip link delete microwarp-wg-check
```

If `modprobe` reports `Module wireguard not found` or `ip link add` reports `Unknown device type` / `Protocol not supported`, the default WireGuard path cannot start. `NET_ADMIN` permits the container to create interfaces; `SYS_MODULE` does **not** install a missing host kernel module.

For CentOS / RHEL 8 kernels without the module, install the ELRepo kABI module on the **host**, then load it:

```bash
dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm
dnf --enablerepo=elrepo install -y kmod-wireguard wireguard-tools
depmod -a "$(uname -r)"
modprobe wireguard
printf 'wireguard\n' >/etc/modules-load.d/wireguard.conf
```

Re-run the interface check above before recreating MicroWARP. In nested OpenVZ/LXC environments, the outer host must provide and allow the module; an inner Docker container cannot add it by itself.

#### Generic TUN vs. the WireGuard kernel module

| Requirement | Needed when | Compose setting |
| :--- | :--- | :--- |
| Host `wireguard` kernel module | `TUNNEL_PROTOCOL=wireguard` | Host prerequisite; not replaceable by a container capability. |
| `NET_ADMIN` | WireGuard, MASQUE, policy routing, and network namespaces | `cap_add: [NET_ADMIN]` |
| `/dev/net/tun` | `UPSTREAM_SOCKS5_TRANSPORT=tun` (the built-in `hev-socks5-tunnel`) | `devices: ["/dev/net/tun:/dev/net/tun"]` |
| `SYS_ADMIN`, IP forwarding, relaxed seccomp | `INSTANCE_COUNT > 1` | Enable the commented Compose settings. |

`/dev/net/tun` is a generic TUN device and is not the WireGuard module. A working upstream SOCKS5 TUN does not prove that the host can create `type wireguard`.

#### Hosts without WireGuard support

Use the userspace MASQUE path instead of the kernel WireGuard path:

```dotenv
TUNNEL_PROTOCOL=masque
MASQUE_PROXY_MODE=socks
MASQUE_HTTP2=1
ENABLE_IPV6=0
```

This bypasses `wireguard.ko`; it consumes more memory than the default path. `UPSTREAM_SOCKS5_TRANSPORT=tun` still needs `/dev/net/tun`. The narrow `UPSTREAM_SOCKS5_TRANSPORT=tcp` branch needs no TUN device, but only works with `MASQUE_PROXY_MODE=socks` and `MASQUE_HTTP2=1`.

### 📦 Quick Start

Map port `1080` and grant `NET_ADMIN` privileges. Create a `docker-compose.yml`:

```yaml
services:
  microwarp:
    image: ghcr.io/lazzman/microwarp:latest
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.default.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
    volumes:
      - warp-data:/etc/wireguard

volumes:
  warp-data:
```

Run the container:
```bash
docker compose up -d
```

### ⚙️ Environment Variables

#### Basic listener and tunnel

| Variable | Default | Description |
| :--- | :--- | :--- |
| **`TUNNEL_PROTOCOL`** | `wireguard` | `wireguard` (kernel, default; the host must provide the WireGuard module) or `masque` (usque userspace, no WireGuard module). Aliases: `wg` / `usque`. |
| `BIND_ADDR` | `0.0.0.0` | The only public SOCKS5 / Mixed listener address. Use `::` for IPv6 or dual-stack listen. |
| `BIND_PORT` | `1080` | The only public listener port. `LB_PORT` was removed; do not publish instance-direct ports. |
| `SOCKS_USER` / `SOCKS_PASS` | *(empty)* | Public proxy authentication for every mode; both must be set. On direct single-instance SOCKS5 they configure `microsocks` / `usque`; in Mixed/LB they protect only the public front end, while internal SOCKS backends remain unauthenticated. |
| `ENABLE_IPV6` | `1` | `1`/`true` = dual-stack WARP; `0` = IPv4-only. It enables IPv6 routing but does not choose IPv6 first for domain targets; use `RESOLVE_PREFERENCE` for that. |
| `RESOLVE_PREFERENCE` | `auto` | Domain resolution used by the WireGuard `microsocks` backend: `auto`; `ipv4_prefer` / `ipv6_prefer` (prefer that family, then fall back to the other); `ipv4_only` (A only); or `ipv6_only` (AAAA only). Legacy `ipv4` / `ipv6` remain aliases for `*_only`. It does not rewrite numeric IP addresses supplied by a client and does not control MASQUE resolution. |
| `MTU` | `1280` | WireGuard interface MTU. |
| `KEEPALIVE` | `15` | `PersistentKeepalive` seconds (NAT/QoS keep-alive). |
| `ENDPOINT_IP` | *(wgcf default)* | Override the **WireGuard** endpoint, e.g. `162.159.192.1:4500` or `[2606:4700:d0::a29f:c001]:4500`. |
| `GH_PROXY` | *(none)* | GitHub download proxy prefix for the `wgcf` binary. |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | IPv4 mesh return-path CIDR restored after WireGuard is up. |
| `TAILSCALE_CIDR_V6` | `fd7a:115c:a1e0::/48` | IPv6 mesh return-path CIDR restored after WireGuard is up. |

#### MASQUE / usque

| Variable | Default | Description |
| :--- | :--- | :--- |
| `MASQUE_PROXY_MODE` | `l4-socks` | `l4-socks` (TCP-only, lighter) or `socks` (full gVisor L3, TCP+UDP, heavier). |
| `MASQUE_HTTP2` | `0` | `1` enables TCP/HTTP2 fallback when QUIC is blocked. Requires `MASQUE_PROXY_MODE=socks`. |
| `MASQUE_SNI` | *(empty)* | Optional SNI override (full `socks` only; ignored by `l4-socks`). |
| `MASQUE_MTU` | *(empty)* | Optional usque MTU (full `socks` only). |
| `MASQUE_DNS_SERVERS` | *(auto)* | Comma-separated DNS servers. With `ENABLE_IPV6=0`, defaults to `1.1.1.1,1.0.0.1` to avoid unreachable IPv6 DNS. |
| `GOMEMLIMIT` | `512MiB` | Soft cap for Go RSS on the MASQUE path (small VPS). |
| `WARP_JWT` | *(empty)* | Zero Trust team token for MASQUE `usque register`. |
| `WARP_LICENSE` | *(empty)* | Optional WARP+ license (best-effort apply via usque). |
| `USQUE_DEVICE_NAME` | `MicroWARP` | Device name sent during MASQUE registration. |
| `USQUE_CONFIG` | `/etc/wireguard/masque-config.json` | Persisted MASQUE identity (same volume as `wg0.conf`). |

#### Single-container control plane, Mixed proxy, and load balancing

| Variable | Default | Description |
| :--- | :--- | :--- |
| `INSTANCE_COUNT` | `1` | Number of isolated WARP instances in this one container. Values above `1` require `SYS_ADMIN`, `net.ipv4.ip_forward=1`, and a permissive seccomp profile as shown in Compose. |
| `INSTANCE_START_STAGGER` | `0.2` | 多实例基础工作进程之间的启动错峰秒数。默认值可避免固定 1 秒间隔拖慢初始化；设为 `0` 追求最快拉起，调大可平滑首次 Cloudflare 注册压力。 |
| `NETNS_DNS_SERVERS` | `1.1.1.1,1.0.0.1` | DNS servers written to `/etc/netns/microwarpN/resolv.conf` for multi-instance workers. This avoids Docker DNS `127.0.0.11`, which is only reachable in the default network namespace. |
| `PROXY_MODE` | `socks5` | `socks5` keeps the light direct path; `mixed` enables one-port SOCKS5 + HTTP proxy detection. |
| `CONTROL_PLANE_ENABLED` | `auto` | `auto` enables the supervisor for Mixed, multi-instance, explicitly enabled LB, or the management page. Set `1` to force it; `MANAGEMENT_UI_ENABLED=1` overrides `0`. |
| `LB_ENABLED` | `auto` | `auto` enables the built-in front end for Mixed or multi-instance deployments; `1` forces it. Multi-instance mode and the management page cannot disable it because the same sole listener is required. |
| `LB_STRATEGY` | `round` | New-connection selection: `round`, `random`, `hash`, or `rotate`. |
| `LB_STICKY_MODE` | `username-round` | Sticky policy: `username-round` uses an in-memory stateful username round-robin (default); `username-hash` uses Rendezvous Hash by username; `client-ip-hash` uses Rendezvous Hash by client IP; `disabled` turns off sticky assignment. A supplied SOCKS / HTTP Basic username takes precedence over every new-connection strategy, including `rotate`; anonymous clients continue with `LB_STRATEGY`. When a backend leaves the healthy pool, its username mappings are deleted, so a recovered node rejoins only as a new round-robin candidate. |
| `LB_ROTATE_INTERVAL` | `5m` | Time window for `LB_STRATEGY=rotate`; accepts seconds or a duration such as `5m` / `1h`. |
| `LB_MAX_CONN` | `512` | Maximum concurrent client connections accepted by the built-in Mixed/LB front end. |
| `LB_ACCESS_LOG` | `0` | `1` logs every client request with a process-scoped request ID, client source address/port, supplied SOCKS / HTTP Basic user ID (when present), target, **actual IPv4 / IPv6 egress family**, backend address, and backend instance ID. Default `0` records only lifecycle and abnormal events, preventing log floods and exposure of access metadata. |
| `LB_ACCESS_LOG_HEADERS` | `1` | Effective when `LB_ACCESS_LOG=1`. `1` logs all parseable HTTP proxy request headers, while credential-bearing values (`Authorization`, `Proxy-Authorization`, `Cookie`, `Token`, API keys, and similar) are always redacted. `0` records no header content and marks the access line as `HTTP头=已关闭`, while retaining request-line metadata. For HTTP `CONNECT`, only the plaintext CONNECT handshake headers are visible; HTTPS headers inside the tunnel cannot be decoded. |
| `LB_ACCESS_LOG_HEADER_MAX_CHARS` | `8192` | Maximum characters written for the HTTP-header field of one access-log line; accepts `256`–`65536`. Oversized header blocks are marked as truncated. |
| `MANAGEMENT_UI_ENABLED` | `0` | `1` enables the unauthenticated management page at `http://<host>:<BIND_PORT>/__microwarp/`, reusing the sole listener. It forces the built-in LB and control plane even in direct single-instance SOCKS5 mode. |
| `MANAGEMENT_ACTION_PROBE_TIMEOUT` | `180` | 启用或任一重连操作启动后，等待 WARP 健康探测成功的最长秒数。超过该时间后实例保持摘流，并由健康守护继续恢复。 |
| `LB_IDLE_TIMEOUT` | `600` | Bidirectional no-traffic timeout in seconds for the built-in front end, not a maximum connection lifetime. Any client or backend bytes reset it. The higher default prevents a slow LLM first token or an inter-token pause from being cut off; use a positive value and do not use `0` / a negative value as a disable switch. |
| `LB_HANDSHAKE_TIMEOUT` | `30` | SOCKS5 / HTTP proxy handshake timeout in seconds. |
| `INTERNAL_PROXY_PORT` | `1081` | **Advanced.** Internal backend port used only for single-instance Mixed/LB; it is never published. Usually leave unchanged. |

> **Migration:** New deployments use only `SOCKS_USER` / `SOCKS_PASS`. `PROXY_USER` / `PROXY_PASS` are accepted solely as a legacy fallback and are no longer included in Compose or configuration examples.

#### Health checks and rolling restart

| Variable | Default | Description |
| :--- | :--- | :--- |
| `HEALTH_CHECK_INTERVAL` | `60` | Seconds between regular per-instance WARP trace checks. |
| `HEALTH_PROBE_TIMEOUT` | `10` | Timeout in seconds for a health probe. |
| `HEALTH_PROBE_CONCURRENCY` | `32` | Global maximum number of actual HTTP probe requests across health-daemon, Docker, manual, and management probes. Each instance workflow starts the WARP, IPv4 egress, and (when enabled) IPv6 egress probes in parallel; a successful WARP result immediately admits the backend while egress observations continue. |
| `BACKEND_POOL_LOCK_TIMEOUT` | `90` | Maximum seconds to wait for another backend-pool batch commit; `0` waits indefinitely. Updates are first persisted, so a waiting process never drops a ready/drained state. |
| `BACKEND_POOL_BATCH_WINDOW_MS` | `100` | Short coalescing window in milliseconds before committing pending backend-pool changes. Increase slightly for very large cold starts to reduce full pool rebuilds; lower it for fastest individual state visibility. |
| `HEALTH_SOFT_FAILURES` | `3` | Consecutive failed checks after the start period before the health daemon restarts an instance. |
| `HEALTH_START_PERIOD` | `90` | Startup grace period in seconds; failures are not restarted during this period. Ready instances still enter the pool immediately. |
| `HEALTH_STARTUP_RETRY_INTERVAL` | `3` | Seconds between startup probes until an instance becomes healthy. |
| `STATUS_EVENT_LOG` | `1` | `1` prints a complete icon status table on initial observation and when an instance readiness, egress IP/location (`loc` / `colo`), pool, or maintenance state changes. Each ready row includes separate IPv4 and IPv6 exits plus active connections currently forwarded by the built-in LB; the lightweight single-instance direct path shows `—` for connection count because microsocks/usque has no control-plane counter. `0` disables only this table. |
| `ROTATE_RESTART_ENABLED` | `auto` | `auto` enables rolling restart only with four or more instances; `1` forces it for a multi-instance deployment and `0` disables it. |
| `ROTATE_RESTART_INTERVAL` | `6h` | Interval between rolling restarts; accepts seconds or a duration such as `6h`. |
| `ROTATE_RESTART_PROBE_TIMEOUT` | `90` | Maximum seconds to wait for a restarted instance to pass its WARP probe. |
| `ROTATE_RESTART_RETRIES` | `2` | Retry count when a rolling-restarted instance does not become ready. |
| `ROTATE_RESTART_CONCURRENCY` | `auto` | `auto` sets the concurrency budget to `max(1, floor(current instance count / 5))` (20 for 100 instances). A positive integer explicitly overrides it; a completed idle instance immediately admits the next idle instance. Busy instances do not occupy this budget. |
| `ROTATE_RESTART_DEFERRED_CHECK_INTERVAL` | `60` | Interval for rechecking busy instances in the deferred queue. Accepts seconds or durations such as `1m`; the default checks once per minute. It applies to scheduled rolling restarts and manual graceful actions. |
| `ROTATE_RESTART_HISTORY_LIMIT` | `20` | 管理页面保留的最近定时滚动重启轮次数；每轮保存摘要、失败原因、重试/阶段及跳过诊断到运行时目录。 |

#### Upstream SOCKS5 for WARP registration and outer transport

| Variable | Default | Description |
| :--- | :--- | :--- |
| `UPSTREAM_SOCKS5` | *(empty)* | Upstream URI used before WARP is established, e.g. `socks5://user:pass@192.168.1.15:20122`. `/dev/net/tun` is needed only with `UPSTREAM_SOCKS5_TRANSPORT=tun`. |
| `UPSTREAM_SOCKS5_TRANSPORT` | `tun` | `tun` routes full IP traffic through `hev-socks5-tunnel` and requires upstream UDP support. `tcp` uses ordinary SOCKS5 `CONNECT` without TUN or UDP Associate, but is valid **only** with `TUNNEL_PROTOCOL=masque`, `MASQUE_PROXY_MODE=socks`, and `MASQUE_HTTP2=1`. |
| `UPSTREAM_SOCKS5_UDP_MODE` | `udp` | `udp` uses standard SOCKS5 UDP ASSOCIATE. `tcp` means the UDP-in-TCP extension, **not** normal TCP CONNECT; the upstream server must explicitly support it. |
| `UPSTREAM_MTU` | `1280` | MTU of the internal `hev-socks5-tunnel` TUN interface; ignored by `UPSTREAM_SOCKS5_TRANSPORT=tcp`. |
| `UPSTREAM_VERIFY` | `1` | `tun` probes numeric HTTPS TCP plus `1.1.1.1:53` UDP; `tcp` probes only numeric HTTPS through SOCKS5 `CONNECT`, before WARP registration. |
| `UPSTREAM_PROBE_TIMEOUT` | `8` | Timeout in seconds for each selected upstream reachability probe. |
| `UPSTREAM_REQUIRED` | `1` | `1` stops the instance if the selected upstream path fails, preventing a silent direct-WARP fallback. Set `0` only when direct fallback is intended. |
| `UPSTREAM_SOCKS5_UDP` / `UPSTREAM_TRANSPORT` | *(legacy aliases)* | Deprecated compatibility aliases for `UPSTREAM_SOCKS5_UDP_MODE`. Use the new name in all new deployments. |

#### Advanced runtime paths

| Variable | Default | Description |
| :--- | :--- | :--- |
| `WG_CONF` | `/etc/wireguard/wg0.conf` | **Advanced.** WireGuard identity/configuration path for a direct single instance. Multi-instance mode manages per-instance paths itself. |
| `WG_IFACE` | `wg0` | **Advanced.** WireGuard interface name for a direct single instance. |
| `MICROWARP_RUNTIME_ROOT` | `/run/microwarp` | **Advanced.** Ephemeral control-plane state directory (PIDs, health and backend files). Usually leave unchanged. |
| `MICROWARP_TEST_MODE` | `0` | `1` skips all initialization (CI / dry-run only). |

> **Console logs:** all built-in components use `[MicroWARP][component][level]` prefixes. Docker / the orchestration platform should provide timestamps; MicroWARP deliberately avoids a duplicate timestamp. On initial observation and every instance-state change, the health daemon prints a complete icon table: `🆕` initial, `🔄` changed, `✅` ready, `⏳` probing, `❌` failed, and `⏸️` maintenance. Each ready row reports separately observed `IPv4=… | IPv6=…`, active connections currently forwarded to that backend by the built-in LB, and the Cloudflare trace country (`loc`) / PoP (`colo`), for example `IPv4=104.28.238.182 | IPv6=2a09:… | 活跃连接=7 | 国家=US | 节点=SJC`. When `LB_ACCESS_LOG=1`, each successful request line also includes its actual `出口=IPv4` or `出口=IPv6`. The direct single-instance light path reports `活跃连接=—` because microsocks/usque does not expose a control-plane counter. Connection-count changes alone do not repeat the table; the value is sampled whenever a state table is emitted. Stable states do not repeat; set `STATUS_EVENT_LOG=0` to disable this table.

#### Single-port management page

Set `MANAGEMENT_UI_ENABLED=1` to open the unauthenticated page at `http://<host>:<BIND_PORT>/__microwarp/`. It reuses the proxy listener and shows instances, WARP health/location, pool state, current operation, and only currently active proxy connections. Connection rows contain request ID, protocol, client, supplied username, target, **actual IPv4 / IPv6 egress family**, backend, age, idle time, and bidirectional byte counters; they disappear immediately after closing. The page refreshes every five seconds and includes a manual refresh button. It can gracefully reconnect, disable, or enable an instance. Disable drains and stops it only for the current container run; a container restart enables it again.

The page and API bypass proxy authentication by design. Restrict the published listener to a trusted host, private network, firewall rule, or reverse-proxy ACL before enabling it.

> **MASQUE networking:** use `l4-socks` for HTTP/3/QUIC only when UDP 443 is reachable end-to-end. If QUIC is filtered, use `MASQUE_PROXY_MODE=socks` with `MASQUE_HTTP2=1`; this TCP/443 fallback is verified in the test report.


Example with auth + dual-stack + port hopping (WireGuard):

```yaml
    environment:
      - TUNNEL_PROTOCOL=wireguard
      - BIND_ADDR=0.0.0.0
      - BIND_PORT=1080
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
      - ENABLE_IPV6=1
      - ENDPOINT_IP=162.159.192.1:4500
```

Example MASQUE (anti-block / UDP QoS):

```yaml
    environment:
      - TUNNEL_PROTOCOL=masque
      - MASQUE_PROXY_MODE=l4-socks   # QUIC/UDP 443 可用时的轻量 TCP-only 模式
      # 若 UDP/QUIC 被拦截：改为 full socks + HTTP/2 TCP 回退
      # - MASQUE_PROXY_MODE=socks
      # - MASQUE_HTTP2=1
      - GOMEMLIMIT=512MiB
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
```

### 🔀 WireGuard vs MASQUE

| | **WireGuard (default)** | **MASQUE** |
| :--- | :--- | :--- |
| Engine | Linux kernel `wg0` + `microsocks` | [usque](https://github.com/Diniboy1123/usque) userspace |
| Wire image | UDP 2408 / 4500 (non-standard-ish) | HTTP/3 QUIC **UDP 443** (optional HTTP/2 **TCP 443**) |
| RAM | **~800 KB** | Tens–hundreds of MB (set `GOMEMLIMIT`) |
| Best for | 1C1G VPS, max efficiency | WG blocked/QoSed, captive portals, "looks like HTTPS" |
| Capabilities | Full IP tunnel + dual-stack policy routing | `l4-socks` = TCP only; `socks` = TCP+UDP via gVisor |


> **Identity persistence:** both `wg0.conf` and `masque-config.json` live under `/etc/wireguard`. Always mount the volume — re-registering every restart will hit Cloudflare rate limits.


### 🌐 IPv6 notes

* **WARP tunnel dual-stack** is enabled by default (`ENABLE_IPV6=1`). The entrypoint keeps the IPv6 address from `wgcf` and sets `AllowedIPs = 0.0.0.0/0, ::/0`.
* **Docker host IPv6** must be available for end-to-end IPv6 SOCKS clients. Enable Docker daemon IPv6 if you need published IPv6 ports.
* **SOCKS listen**: default `BIND_ADDR=0.0.0.0` is IPv4-only on the listen socket. Set `BIND_ADDR=::` if clients should connect over IPv6.
* **Disable dual-stack** anytime with `ENABLE_IPV6=0` (useful on hosts where IPv6 breaks `wg-quick`).

### 🚀 混合代理：同端口 SOCKS5 + HTTP

设置 `PROXY_MODE=mixed` 后，同一个公开端口会自动识别 **SOCKS5** 和 **HTTP Proxy** 请求。内置前端会把请求转发到内部 WARP SOCKS 后端，因此目标域名仍由对应 WARP 实例解析和连接。

```yaml
environment:
  - PROXY_MODE=mixed
  - BIND_PORT=1080
  - SOCKS_USER=admin      # 可选认证；两个变量必须同时设置
  - SOCKS_PASS=123456
```

默认 `PROXY_MODE=socks5` 仍走最低资源的 microsocks 路径。多实例模式下，LB 的同一个公开端口也是唯一入口，不会公开任何实例直连端口。启用 `SOCKS_USER` / `SOCKS_PASS` 时，认证只在公开 Mixed/LB 前端执行；内部 SOCKS 后端会刻意保持无认证。

---

<a name="chinese"></a>
## 🇨🇳 中文说明

一个极简、高性能的 Cloudflare WARP SOCKS5 Docker 代理。
致力于为服务器提供极低资源占用的出口网络解耦方案，现已原生支持 **IPv4 / IPv6 双栈**。

### 🌟 为什么选择 MicroWARP？

市面上大多数 WARP 镜像（例如 `caomingjun/warp`）依赖于 Cloudflare 官方的 `warp-cli` 守护进程。这种方式通常会导致较高的内存占用（约 **150MB+**），且在高并发场景下存在一定的性能瓶颈。

**MicroWARP** 采用了不同的底层架构：
1. **内核级 WireGuard（默认）**：采用 Linux 原生内核态的 `wg0` 接口接管流量，CPU 损耗近乎为零。
2. **可选 MASQUE**：`TUNNEL_PROTOCOL=masque` 时使用 [usque](https://github.com/Diniboy1123/usque)（CONNECT-IP / HTTP/3）。适合 WireGuard UDP 被 QoS/封锁的环境，流量外观接近 **443 HTTPS**。
3. **MicroSOCKS 引擎**：WireGuard 路径使用纯 C `microsocks`；MASQUE 路径使用 usque 的 `l4-socks` / `socks`。
4. **极低内存占用（WireGuard）**：高并发下仍 **< 5MB**（常驻约 800KB）。MASQUE 为用户态 QUIC，内存显著更高（见下表）。
5. **原生双栈**：WireGuard 路径完整保留 IPv6，`AllowedIPs` 含 `0.0.0.0/0` 与 `::/0`，并补齐 IPv6 策略路由。
6. **原生兼容 Tailscale**：WireGuard 路径智能保留 IPv4 / IPv6 回程路由，解决非对称路由黑洞。
7. **多架构支持**：原生支持 `amd64` 与 `arm64`（注册路径亦兼容 `armv7`）。


### 🎯 典型应用场景
**⚠️ 声明：本项目专为服务端 (Server-side) 设计，并非个人电脑本地代理软件。**

1. **API 网络路由**：为服务器上的爬虫或大模型 API 网关（如 Grok / ChatGPT）提供稳定的 Cloudflare 出口 IP。
2. **服务端出口隐私**：挂载 MicroWARP 作为服务器的出站网关，隐藏 VPS 真实 IP，降低遭到溯源扫描的风险。
3. **微服务 Sidecar**：极低的资源占用使其非常适合作为 Docker Sidecar 容器，为特定的后端服务提供独立的网络出口。
4. **IPv6 出口**：在宿主机 IPv6 对等质量不佳时，通过 WARP 访问仅 IPv6 的目标。

### 🧩 宿主机前置依赖

Docker 容器与宿主机共享**同一个 Linux 内核**。`TUNNEL_PROTOCOL=wireguard` 会通过 `wgcf + wg-quick` 创建内核 `wg0` 接口，因此宿主机必须提供 WireGuard netdevice 驱动；镜像内安装 `wireguard-tools` 并不能补齐宿主机缺失的内核模块。

#### WireGuard 路径：先在宿主机验证

在运行 Docker 的宿主机执行：

```bash
modprobe wireguard
lsmod | grep -w wireguard
ip link add microwarp-wg-check type wireguard
ip link delete microwarp-wg-check
```

若 `modprobe` 提示 `Module wireguard not found`，或 `ip link add` 提示 `Unknown device type` / `Protocol not supported`，默认 WireGuard 路径就无法启动。`NET_ADMIN` 只授予容器创建接口的权限；`SYS_MODULE` **不能安装或补齐**宿主机缺失的内核模块。

对于没有该模块的 CentOS / RHEL 8 内核，在**宿主机**安装 ELRepo 的 kABI 模块后加载：

```bash
dnf install -y https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm
dnf --enablerepo=elrepo install -y kmod-wireguard wireguard-tools
depmod -a "$(uname -r)"
modprobe wireguard
printf 'wireguard\n' >/etc/modules-load.d/wireguard.conf
```

完成后再次执行上方的接口创建检查，再重建 MicroWARP。OpenVZ / 嵌套 LXC 等环境必须由外层宿主机提供并允许使用该模块，内层 Docker 容器无法自行补上。

#### 通用 TUN 与 WireGuard 内核模块的区别

| 项目 | 何时需要 | Compose 配置 |
| :--- | :--- | :--- |
| 宿主机 `wireguard` 内核模块 | `TUNNEL_PROTOCOL=wireguard` | 宿主机前置条件，容器 capability 无法替代。 |
| `NET_ADMIN` | WireGuard、MASQUE、策略路由和网络命名空间 | `cap_add: [NET_ADMIN]` |
| `/dev/net/tun` | `UPSTREAM_SOCKS5_TRANSPORT=tun` 时，内置 `hev-socks5-tunnel` 使用 | `devices: ["/dev/net/tun:/dev/net/tun"]` |
| `SYS_ADMIN`、IP 转发、宽松 seccomp | `INSTANCE_COUNT > 1` | 启用 Compose 中对应的注释项。 |

`/dev/net/tun` 是通用 TUN 字符设备，不是 WireGuard 内核模块。上游 SOCKS5 TUN 能成功建立，并不代表宿主机一定能创建 `type wireguard` 接口。

#### 宿主机不支持 WireGuard 时

改用 MASQUE 用户态路径，避免创建内核 `wg0`：

```dotenv
TUNNEL_PROTOCOL=masque
MASQUE_PROXY_MODE=socks
MASQUE_HTTP2=1
ENABLE_IPV6=0
```

该路径绕过 `wireguard.ko`，但内存占用高于默认路径。`UPSTREAM_SOCKS5_TRANSPORT=tun` 仍需保留 `/dev/net/tun`；严格限定的 `UPSTREAM_SOCKS5_TRANSPORT=tcp` 分支无需 TUN，但只适用于 `MASQUE_PROXY_MODE=socks` 与 `MASQUE_HTTP2=1`。

### 📦 快速开始

只需映射 `1080` 端口并赋予容器 `NET_ADMIN` 权限。新建一个 `docker-compose.yml`：

```yaml
services:
  microwarp:
    image: ghcr.io/lazzman/microwarp:latest
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080" # 默认无密码 SOCKS5 端口，仅监听本机
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.default.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
    volumes:
      - warp-data:/etc/wireguard # 持久化保存账号凭证

volumes:
  warp-data:
```

启动容器：
```bash
docker compose up -d
```

### ⚙️ 环境变量一览

#### 基础入口与隧道

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| **`TUNNEL_PROTOCOL`** | `wireguard` | `wireguard`（内核，默认；宿主机必须提供 WireGuard 模块）或 `masque`（usque 用户态，无需 WireGuard 模块）。别名：`wg` / `usque`。 |
| `BIND_ADDR` | `0.0.0.0` | 唯一的公开 SOCKS5 / Mixed 监听地址；需要 IPv6 或双栈入站时设为 `::`。 |
| `BIND_PORT` | `1080` | 唯一的公开监听端口。`LB_PORT` 已移除；请不要发布实例直连端口。 |
| `SOCKS_USER` / `SOCKS_PASS` | 空 | 所有模式的公开代理认证，两个变量必须同时设置。直接单实例 SOCKS5 时配置 `microsocks` / `usque`；Mixed/LB 时只保护公开前端，内部 SOCKS 后端始终无认证。 |
| `ENABLE_IPV6` | `1` | `1`/`true` 为 WARP 双栈；`0` 为仅 IPv4。它只决定是否启用 IPv6 路由，不决定域名优先走 IPv6；请用 `RESOLVE_PREFERENCE` 控制后者。 |
| `RESOLVE_PREFERENCE` | `auto` | WireGuard `microsocks` 后端解析域名时的偏好：`auto`；`ipv4_prefer` / `ipv6_prefer`（优先该地址族，不可达时回退另一地址族）；`ipv4_only`（仅 A）；`ipv6_only`（仅 AAAA）。旧值 `ipv4` / `ipv6` 仍兼容，等价于 `*_only`。客户端已传入数值 IP 时不会重新解析或改写地址；该变量不控制 MASQUE 的解析。 |
| `MTU` | `1280` | WireGuard 接口 MTU。 |
| `KEEPALIVE` | `15` | `PersistentKeepalive` 心跳秒数（维持 NAT/QoS 映射）。 |
| `ENDPOINT_IP` | wgcf 默认 | **仅 WireGuard** 自定义节点，如 `162.159.192.1:4500` 或 `[2606:4700:d0::a29f:c001]:4500`。 |
| `GH_PROXY` | 无 | `wgcf` 二进制下载使用的 GitHub 代理前缀。 |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | WireGuard 建立后恢复的 IPv4 组网回程 CIDR。 |
| `TAILSCALE_CIDR_V6` | `fd7a:115c:a1e0::/48` | WireGuard 建立后恢复的 IPv6 组网回程 CIDR。 |

#### MASQUE / usque

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `MASQUE_PROXY_MODE` | `l4-socks` | `l4-socks`（仅 TCP、更轻）或 `socks`（gVisor 全 L3，TCP+UDP、更重）。 |
| `MASQUE_HTTP2` | `0` | `1` 在 QUIC 不通时启用 TCP/HTTP2 回退；需要 `MASQUE_PROXY_MODE=socks`。 |
| `MASQUE_SNI` | 空 | 可选 SNI（仅完整 `socks` 生效；`l4-socks` 忽略）。 |
| `MASQUE_MTU` | 空 | 可选 usque MTU（仅完整 `socks` 生效）。 |
| `MASQUE_DNS_SERVERS` | 自动 | 逗号分隔 DNS。`ENABLE_IPV6=0` 且未设置时默认 `1.1.1.1,1.0.0.1`，避免不可达 IPv6 DNS。 |
| `GOMEMLIMIT` | `512MiB` | MASQUE 路径的 Go RSS 软限制，适用于小内存 VPS。 |
| `WARP_JWT` | 空 | MASQUE `usque register` 使用的 Zero Trust 团队令牌。 |
| `WARP_LICENSE` | 空 | 可选 WARP+ 许可证（通过 usque 尽力绑定）。 |
| `USQUE_DEVICE_NAME` | `MicroWARP` | MASQUE 注册时提交的设备名。 |
| `USQUE_CONFIG` | `/etc/wireguard/masque-config.json` | 持久化 MASQUE 身份路径（与 `wg0.conf` 共用 volume）。 |

#### 单容器控制面、Mixed 代理与负载均衡

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `INSTANCE_COUNT` | `1` | 一个容器中运行的隔离 WARP 实例数，支持 `1`~`255`（实例 ID 为 `0`~`254`）。大于 `1` 时需按 Compose 示例增加 `SYS_ADMIN`、`net.ipv4.ip_forward=1` 和宽松 seccomp；实际可用数量还受宿主机资源及内核/容器限制影响。 |
| `INSTANCE_START_STAGGER` | `0.2` | 基础多实例工作进程之间的启动错峰秒数。默认值将旧版固定 `1` 秒错峰缩短为 `0.2` 秒，以加快初始化；设为 `0` 可最快拉起，调大则可平滑首次 Cloudflare 注册压力。 |
| `NETNS_DNS_SERVERS` | `1.1.1.1,1.0.0.1` | 多实例工作进程写入 `/etc/netns/microwarpN/resolv.conf` 的 DNS 服务器，避免 Docker DNS `127.0.0.11` 只在默认网络命名空间可达。 |
| `PROXY_MODE` | `socks5` | `socks5` 保留最低资源直连路径；`mixed` 在同一端口自动识别 SOCKS5 + HTTP 代理。 |
| `CONTROL_PLANE_ENABLED` | `auto` | `auto` 会在 Mixed、多实例、显式启用 LB 或管理面板时启动控制面；`1` 强制启动。`MANAGEMENT_UI_ENABLED=1` 会覆盖 `0`。 |
| `LB_ENABLED` | `auto` | `auto` 会在 Mixed 或多实例时启用内置前端；`1` 强制启用。多实例和管理面板都不能关闭，因为两者都需要同一个唯一入口。 |
| `LB_STRATEGY` | `round` | 新连接选择：`round`、`random`、`hash` 或 `rotate`。 |
| `LB_STICKY_MODE` | `username-round` | 粘性策略：`username-round` 使用仅内存的状态型 username 轮询（默认）；`username-hash` 按 username 做 Rendezvous Hash；`client-ip-hash` 按来源 IP 做 Rendezvous Hash；`disabled` 关闭粘性分配。提供 SOCKS / HTTP Basic username 时，该分支优先于所有新连接策略（包括 `rotate`）；匿名请求继续按 `LB_STRATEGY`。节点离开健康池时会删除其 username 映射，节点恢复后只作为新的轮询候选重新加入。 |
| `LB_ROTATE_INTERVAL` | `5m` | `LB_STRATEGY=rotate` 的时间窗口；支持秒数或 `5m`、`1h` 等时长。 |
| `LB_MAX_CONN` | `512` | 内置 Mixed/LB 前端允许的最大并发客户端连接数。 |
| `LB_ACCESS_LOG` | `0` | `1` 记录每个客户端请求的进程内请求 ID、客户端源地址/端口、已提供的 SOCKS / HTTP Basic 用户 ID（如有）、目标、**实际 IPv4 / IPv6 出口地址族**、后端地址与后端实例序号。默认 `0` 仅记录生命周期和异常，避免日志刷屏及暴露访问元数据。 |
| `LB_ACCESS_LOG_HEADERS` | `1` | 仅在 `LB_ACCESS_LOG=1` 时生效。`1` 记录全部可解析的 HTTP 代理请求头；`Authorization`、`Proxy-Authorization`、`Cookie`、Token、API Key 等敏感字段值始终脱敏。`0` 不记录任何请求头内容，但会标注 `HTTP头=已关闭`，并保留请求行元数据。HTTP `CONNECT` 只能看到明文 CONNECT 握手头，无法解密隧道内 HTTPS 请求头。 |
| `LB_ACCESS_LOG_HEADER_MAX_CHARS` | `8192` | 单条访问日志中 HTTP 请求头字段的最大字符数，范围 `256`–`65536`；超出时会标记为截断。 |
| `MANAGEMENT_UI_ENABLED` | `0` | `1` 启用匿名管理页面 `http://<宿主机>:<BIND_PORT>/__microwarp/`，复用唯一监听端口。即使原本是单实例直接 SOCKS5，也会强制启动内置 LB 与控制面。 |
| `MANAGEMENT_ACTION_PROBE_TIMEOUT` | `180` | 启用、优雅重连或强制重连实际开始后等待 WARP 探测成功的最大秒数（默认 3 分钟）；不是连接排空超时。超时后实例保持摘流，并交由健康守护继续恢复。管理页会记录失败阶段 `warp-probe` 与原因码 `warp-probe-timeout`。 |
| `MICROWARP_LOG_FILE` | `/run/microwarp/console.log` | 网页控制台展示的运行时日志文件。该文件不应挂载到持久卷，容器重启会重新创建。 |
| `MANAGEMENT_LOG_LINES` | `300` | 网页控制台一次返回的最近日志行数，范围 `50`–`2000`。 |
| `LB_IDLE_TIMEOUT` | `600` | 内置前端的双向无流量超时秒数，不是连接总时长；客户端或后端任一方向有字节流动都会重置计时。提高默认值可避免 LLM 首个 token 较慢或流式中短暂停顿时被断开；请使用正数，`0` 或负数不是关闭超时的开关。 |
| `LB_HANDSHAKE_TIMEOUT` | `30` | SOCKS5 / HTTP 代理握手超时秒数。 |
| `INTERNAL_PROXY_PORT` | `1081` | **高级。** 单实例 Mixed/LB 使用的内部后端端口，绝不发布到容器外；通常无需修改。 |

> **迁移说明：** 新部署只使用 `SOCKS_USER` / `SOCKS_PASS`。`PROXY_USER` / `PROXY_PASS` 仅作为旧部署兼容回退读取，已不再出现在 Compose 与配置示例中。

> **管理操作诊断：** 管理页将“当前实例状态”和“最近操作结果”分开呈现。终态操作会固定记录开始时间、结束时间和真实执行耗时；失败记录还会保留阶段、原因码和可读原因。若一次重连未在时限内完成、但健康守护随后已使实例恢复并重新入池，列表会显示“已恢复”，不会误报为当前实例故障。点击“最近操作”可展开完整诊断与本次日志入口。

#### 健康检查与滚动重启

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `HEALTH_CHECK_INTERVAL` | `60` | 常规单实例 WARP trace 健康检查间隔（秒）。 |
| `HEALTH_PROBE_TIMEOUT` | `10` | 单次健康探测超时秒数。 |
| `HEALTH_PROBE_CONCURRENCY` | `32` | 健康守护、Docker 健康检查、手工探测和管理面探测共享的实际 HTTP 探测全局并发上限。每个实例工作流会并行启动 WARP 主探测、IPv4 出口探测，以及启用 IPv6 时的 IPv6 出口探测；WARP 主探测成功即入池，出口观测继续补齐状态。 |
| `BACKEND_POOL_LOCK_TIMEOUT` | `90` | 等待其他后端池批量提交者的最长秒数；设为 `0` 表示持续等待。状态会先持久化，因此等待中的进程不会丢失实例就绪或摘流更新。 |
| `BACKEND_POOL_BATCH_WINDOW_MS` | `100` | 提交待处理后端池更新前的短暂聚合窗口（毫秒）。大规模冷启动时可适当调大以减少全量重建；追求单实例状态可见性时可调小。 |
| `HEALTH_SOFT_FAILURES` | `3` | 启动宽限期后，健康守护重启实例前允许的连续失败次数。 |
| `HEALTH_START_PERIOD` | `90` | 启动宽限期秒数；此期间失败不会触发重启，已就绪的实例仍会立即加入池。 |
| `HEALTH_STARTUP_RETRY_INTERVAL` | `3` | 实例未就绪时的启动探测间隔秒数。 |
| `STATUS_EVENT_LOG` | `1` | `1` 在首次观测及实例就绪状态、出口 IP/地理信息（`loc` / `colo`）、后端池或维护状态变化时输出完整图标状态表。已就绪行会并列显示 IPv4 / IPv6 出口及内置 LB 当前转发到该后端的活跃连接数；单实例轻量直连路径会显示 `活跃连接=—`，因为 microsocks/usque 不向控制面提供连接计数。`0` 仅关闭该表格。 |
| `ROTATE_RESTART_ENABLED` | `auto` | `auto` 仅在实例数不少于 4 时启用滚动重启；`1` 在多实例部署中强制启用，`0` 关闭。 |
| `ROTATE_RESTART_INTERVAL` | `6h` | 滚动重启间隔；支持秒数或 `6h` 等时长。 |
| `ROTATE_RESTART_PROBE_TIMEOUT` | `90` | 重启后等待实例通过 WARP 探测的最大秒数。 |
| `ROTATE_RESTART_RETRIES` | `2` | 滚动重启后的实例未就绪时重试次数。 |
| `ROTATE_RESTART_CONCURRENCY` | `auto` | `auto` 按当前实例总数的 `max(1, floor(总数 / 5))` 确定并行数（100 个实例为 20 个）；可设正整数显式覆盖。空闲实例完成后会立刻补充队列中的下一个空闲实例；繁忙实例不占用该并行额度。 |
| `ROTATE_RESTART_DEFERRED_CHECK_INTERVAL` | `60` | 延后队列复查繁忙实例的间隔；支持秒数或 `1m` 等时长，默认每分钟一次。该配置同时用于定时滚动重启和手工优雅操作。 |
| `ROTATE_RESTART_HISTORY_LIMIT` | `20` | 管理页面保留的最近定时滚动重启轮次数；每轮包含摘要、失败原因、阶段、尝试次数和跳过诊断，均随运行时目录在容器重启时清理。 |

#### 通过上游 SOCKS5 建立 WARP 注册与外层连接

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `UPSTREAM_SOCKS5` | 空 | WARP 建立前使用的上游 URI，例如 `socks5://user:pass@192.168.1.15:20122`。仅 `UPSTREAM_SOCKS5_TRANSPORT=tun` 需要挂载 `/dev/net/tun`。 |
| `UPSTREAM_SOCKS5_TRANSPORT` | `tun` | `tun` 由 `hev-socks5-tunnel` 承载完整 IP 流量，要求上游 UDP 可用。`tcp` 使用普通 SOCKS5 `CONNECT`，不需要 TUN 或 UDP Associate，但**仅**允许 `TUNNEL_PROTOCOL=masque`、`MASQUE_PROXY_MODE=socks`、`MASQUE_HTTP2=1`。 |
| `UPSTREAM_SOCKS5_UDP_MODE` | `udp` | `udp` 使用标准 SOCKS5 UDP ASSOCIATE；`tcp` 是 **UDP-in-TCP 扩展**，不是普通 TCP CONNECT，上游服务端必须明确支持。 |
| `UPSTREAM_MTU` | `1280` | 内置 `hev-socks5-tunnel` TUN 接口的 MTU；`UPSTREAM_SOCKS5_TRANSPORT=tcp` 时忽略。 |
| `UPSTREAM_VERIFY` | `1` | `tun` 在 WARP 注册前探测数值 HTTPS TCP 与 `1.1.1.1:53` UDP；`tcp` 只经 SOCKS5 `CONNECT` 探测数值 HTTPS。 |
| `UPSTREAM_PROBE_TIMEOUT` | `8` | 当前上游承载路径每次连通性探测的超时秒数。 |
| `UPSTREAM_REQUIRED` | `1` | `1` 时所选上游路径失败即停止实例，防止静默回退直连 WARP；只有明确要直连回退时才设 `0`。 |
| `UPSTREAM_SOCKS5_UDP` / `UPSTREAM_TRANSPORT` | 旧别名 | 已废弃的 `UPSTREAM_SOCKS5_UDP_MODE` 兼容别名；新部署请只使用新变量名。 |

#### 高级运行路径

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `WG_CONF` | `/etc/wireguard/wg0.conf` | **高级。** 直接单实例的 WireGuard 身份/配置路径；多实例会自行管理每个实例的路径。 |
| `WG_IFACE` | `wg0` | **高级。** 直接单实例的 WireGuard 接口名。 |
| `MICROWARP_RUNTIME_ROOT` | `/run/microwarp` | **高级。** 控制面的临时状态目录（PID、健康状态和后端文件）；通常无需修改。 |
| `MICROWARP_TEST_MODE` | `0` | `1` 跳过全部初始化，仅用于 CI / dry-run。 |

> **控制台日志：** 内置组件统一使用 `[MicroWARP][组件][级别]` 前缀；时间戳交由 Docker / 编排平台附加，避免重复时间。健康守护会在首次观测及任一实例状态变化时输出一张完整图标状态表：`🆕` 首次观测、`🔄` 本轮变化、`✅` 已就绪、`⏳` 探测中、`❌` 异常、`⏸️` 维护；每个就绪行并列显示 `IPv4=… | IPv6=…`、内置 LB 当前转发到该后端的活跃连接数，以及 Cloudflare trace 的国家代码 `loc` 与 PoP 节点 `colo`，例如 `IPv4=104.28.238.182 | IPv6=2a09:… | 活跃连接=7 | 国家=US | 节点=SJC`。`LB_ACCESS_LOG=1` 时，每条成功代理访问日志还会输出实际 `出口=IPv4` 或 `出口=IPv6`。单实例轻量直连路径会显示 `活跃连接=—`，因为 microsocks/usque 不向控制面提供连接计数。单独的连接数变化不会刷新整张表，在下一次实例状态表输出时会采样显示最新值。稳定状态不会重复刷屏。可用 `STATUS_EVENT_LOG=0` 关闭该表格。

> **MASQUE 网络说明：** 只有端到端 UDP 443 / QUIC 可达时才使用 `l4-socks`。若 QUIC 被过滤，请改用 `MASQUE_PROXY_MODE=socks` 和 `MASQUE_HTTP2=1`；该 TCP 443 回退路径已通过测试。


进阶示例（WireGuard）：

```yaml
    environment:
      - TUNNEL_PROTOCOL=wireguard
      - BIND_ADDR=0.0.0.0
      - BIND_PORT=1080
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
      - ENABLE_IPV6=1
      # 部分机房对 UDP 2408 有 QoS，可改 4500 提升连通率
      - ENDPOINT_IP=162.159.192.1:4500
      - GH_PROXY=https://github.ednovas.xyz
```

MASQUE 示例（抗封锁 / UDP 被 QoS）：

```yaml
    environment:
      - TUNNEL_PROTOCOL=masque
      - MASQUE_PROXY_MODE=l4-socks
      # 若 UDP/QUIC 被拦：改 full socks + HTTP/2 TCP 回退
      # - MASQUE_PROXY_MODE=socks
      # - MASQUE_HTTP2=1
      - GOMEMLIMIT=512MiB
      - SOCKS_USER=admin
      - SOCKS_PASS=123456
```

### 🔀 WireGuard 与 MASQUE 怎么选

| | **WireGuard（默认）** | **MASQUE** |
| :--- | :--- | :--- |
| 引擎 | 内核 `wg0` + `microsocks` | [usque](https://github.com/Diniboy1123/usque) 用户态 |
| 流量特征 | UDP 2408 / 4500 | HTTP/3 **UDP 443**（可选 HTTP/2 **TCP 443**） |
| 内存 | **约 800 KB** | 数十～上百 MB（请设 `GOMEMLIMIT`） |
| 适用 | 1C1G、极致省资源 | WG 被封/QoS、需要更像 HTTPS |
| 能力 | 完整 IP 隧道 + 双栈策略路由 | `l4-socks` 仅 TCP；`socks` 经 gVisor 支持 TCP+UDP |


> **务必挂载 volume**：`wg0.conf` 与 `masque-config.json` 都在 `/etc/wireguard`。每次重启重新注册会触发 Cloudflare 限流。


### 🌐 IPv6 说明

* 默认开启双栈（`ENABLE_IPV6=1`），保留 wgcf 配置中的 IPv6 地址，并写入 `AllowedIPs = 0.0.0.0/0, ::/0`。
* 若要让 SOCKS 客户端通过 IPv6 连入，请设置 `BIND_ADDR=::`，并确保 Docker / 宿主机已启用 IPv6。
* 若宿主环境 IPv6 异常导致 `wg-quick` 失败，可设 `ENABLE_IPV6=0` 回退纯 IPv4。
* 入站发布端口的回包路径会通过 IPv4 table 128 / IPv6 table 129 策略路由修复，避免非对称黑洞。

### 🚀 混合代理：同端口 SOCKS5 + HTTP

设置 `PROXY_MODE=mixed` 后，同一个公开端口会自动识别 **SOCKS5** 和 **HTTP Proxy** 请求。内置前端会把请求转发到内部 WARP SOCKS 后端，因此目标域名仍由对应 WARP 实例解析和连接。

```yaml
environment:
  - PROXY_MODE=mixed
  - BIND_PORT=1080
  - SOCKS_USER=admin      # 可选认证；两个变量必须同时设置
  - SOCKS_PASS=123456
```

默认 `PROXY_MODE=socks5` 仍走最低资源的 microsocks 路径。多实例模式下，LB 的同一个公开端口也是唯一入口，不会公开任何实例直连端口。

---

### 🧩 单容器控制面：Mixed、多实例与上游 SOCKS5

MicroWARP 可以在**一个容器**中运行多个相互隔离的 WARP 实例。多实例采用 network namespace + VETH，每个实例独立保存 WireGuard / MASQUE 身份；公网仅暴露一个 LB 入口，绝不暴露实例直连端口。

#### 运行模式

| 场景 | 必填配置 | 对外能力 | 常驻额外进程 |
|---|---|---|---|
| 极简单实例 | `INSTANCE_COUNT=1`、`PROXY_MODE=socks5` | SOCKS5 | 无控制面；保留最低资源路径 |
| 单实例 Mixed | `PROXY_MODE=mixed` | 同端口 SOCKS5 + HTTP | 内置 Mixed 前端与健康守护 |
| 多实例 | `INSTANCE_COUNT=2+` | 唯一 LB 入口 | 实例控制、LB、健康守护 |
| 多实例滚动换出口 | 同上 + `ROTATE_RESTART_ENABLED=1` | 不新开端口 | 空闲优先、繁忙延后的限并发滚动重启调度器（`auto` 默认总数的 1/5） |

多实例示例：

```yaml
services:
  microwarp:
    image: ghcr.io/lazzman/microwarp:latest
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
      - SYS_ADMIN
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    security_opt:
      - seccomp:unconfined
    environment:
      - INSTANCE_COUNT=3
      - BIND_PORT=1080
      - PROXY_MODE=mixed
      - LB_STRATEGY=round
      - LB_STICKY_MODE=username-round
      - HEALTH_CHECK_INTERVAL=60
    volumes:
      - warp-data:/etc/wireguard
```

> 多实例只开放 `BIND_PORT` 对应的唯一入口；实例内部端口仅在容器 network namespace 内可见。启动时会自动为每个 `microwarpN` 命名空间写入独立的 `resolv.conf`，默认使用 `1.1.1.1,1.0.0.1`；Docker 内置 DNS `127.0.0.11` 只在默认命名空间监听，不能用于子实例的 WARP 注册。

#### 负载均衡与粘性

| `LB_STRATEGY` | 无粘性会话时 | 适用场景 |
|---|---|---|
| `round` | 新连接轮询 | 默认通用场景 |
| `random` | 随机选择健康实例 | 无状态请求分散 |
| `hash` | 按客户端 IP 做 Rendezvous Hash | 同一来源需要稳定出口 |
| `rotate` | 未提供 username 时，一个时间窗口内统一出口 | 定时切换匿名新连接出口 |

默认 `LB_STICKY_MODE=username-round` 将 SOCKS 用户名或 HTTP Basic 用户名作为会话 ID，首次出现的 username 按健康后端严格轮询并在内存中保存映射，后续连接继续命中原节点；因此在健康节点集合不变时，连续的新 username 会绝对均匀分配。该规则优先于 `LB_STRATEGY` 的 `round`、`random`、`hash` 和 `rotate`，未提供 username 的客户端仍按 `LB_STRATEGY` 分发。`LB_STICKY_MODE=username-hash` 按 username 做 Rendezvous Hash，`client-ip-hash` 按来源 IP 做 Rendezvous Hash，`disabled` 关闭粘性。健康检查摘流或滚动重启会将故障实例从后端池原子移除，并删除映射到该实例的 username；既有连接继续排空，新连接重新参加剩余健康实例的轮询。实例恢复后不会恢复旧映射，而是作为新的轮询候选加入（策略 B），适合出口 IP 已变化的场景。若设置 `SOCKS_USER` / `SOCKS_PASS`，客户端仍必须通过固定认证。

#### 单端口管理面板

设置 `MANAGEMENT_UI_ENABLED=1` 后，访问 `http://<宿主机>:<BIND_PORT>/__microwarp/` 即可打开匿名管理面板。页面复用代理唯一监听端口；即使原先是单实例直接 SOCKS5，也会启动 LB 与控制面。实例表完整展示实例号、进程、人工状态、健康状态、WARP、IPv4 出口、IPv6 出口、国家、PoP、后端池、活跃连接数、**在线时长**和当前管理操作；在线时长按工作进程最近一次启动（包括自动或手工重启）计算，鼠标悬浮可查看本地时区的具体启动时间。点击任一实例的活跃连接数会弹出该节点当前仍在转发的会话列表，包含请求 ID、协议、目标、客户端、出口、时长、空闲时间和双向流量。窄屏保留所有字段并支持横向滚动。每轮健康探测会分别记录 IPv4 / IPv6 出口；管理页面和控制台实例状态表都会并列显示两类出口。双栈出口探测会通过 IPv4 内部 SOCKS 后端转发指定协议族的数值目标，避免 `curl -6` 错误限制内部 IPv4 后端连接。单个协议族探测失败时显示 `—`，不影响另一协议族或既有 WARP 健康判定。

当前 PC 端采用“克制画布”布局并默认使用浅色主题：顶部导航聚焦总览、实例、连接和日志；运行概览以高留白指标区展示可用实例、连接数与上下行流量，实例与连接使用完整字段表呈现，控制台日志采用全宽时间线面板展示。自动滚动重启中的实例也会进入“进行中的任务”与“操作中”筛选，并在当前操作栏实时显示空闲复核、摘流、重启实例、WARP 健康探测等阶段、剩余连接数和已耗时；完成后该临时状态会自动清除。

管理面板还会在实例表前展示“**定时重启计划**”：它区分尚未触发的计划与正在执行的任务，显示启用/暂停状态、`ROTATE_RESTART_INTERVAL` 对应的周期、下次执行的绝对时间与倒计时、实例范围、有效并行额度、空闲优先策略，以及最近一轮的完成时间、耗时、成功、延后和失败数量。时间按访问者浏览器的本地时区显示；下次执行时间由容器内调度器写入状态文件，避免浏览器自行推导间隔。点击“管理计划”可查看完整策略，并可暂停或恢复**后续**轮次：暂停不会中断已经开始的滚动重启，也不会改写 `ROTATE_RESTART_*` 环境变量；容器重启后该运行时暂停标记会自动清除，恢复为环境变量配置。定时滚动重启仅在多实例部署中可用，单实例面板会明确显示“仅多实例”。滚动重启实际执行时，计划卡显示整体进度；尚未轮到的空闲节点会在实例表“当前操作”中显示“等待定时重启”和队列位置，仍有活跃连接的节点会显示“等待自然空闲”，且继续留在后端池提供服务；正在处理的节点则继续在“进行中的任务”与实例行中展示摘流、重启及健康探测阶段。

“当前活跃连接”只保留仍在转发的会话，显示请求 ID、协议、客户端、已提供的用户 ID、目标、**实际出口地址族（IPv4 / IPv6）**、后端实例、持续时间、空闲时间及双向字节数；双向流量统一按 **KB** 显示，连接关闭后立即从列表移除，不保留历史。每个实例可执行优雅重连、**强制重连**、停用或启用：优雅重连和停用会先进入空闲优先队列；有活跃连接时保持在后端池继续服务，**不设排空超时**，仅每 `ROTATE_RESTART_DEFERRED_CHECK_INTERVAL` 检查一次是否已自然空闲；连接归零后才摘流并执行操作。**强制重连**会立即摘流并停止实例，因此会中断该实例上的现有代理连接。启用或任一种重连后均等待 WARP 探测成功才入池。手工停用仅在当前容器运行期有效，容器重启后自动恢复启用；停用状态下两种重连都会被拒绝，需先启用。

页面工具栏提供“临时添加”和“批量移除”。临时实例会使用与基础多实例相同的网络命名空间、健康探测和后端池机制，只写入 `/run/microwarp/instances.dynamic`；**容器重启后会自动恢复为 `INSTANCE_COUNT` 配置的基础实例数量**。因此仅支持 `INSTANCE_COUNT>=2` 的多实例部署，且基础实例与临时实例的总数最多为 `255`（实例 ID `0`~`254`）；临时实例同样支持启用、停用、优雅重连和强制重连，批量移除只允许选择临时实例。首次添加会异步触发健康探测，不会因可选双栈出口观测拖慢后续添加请求。顶部导航会固定在页面顶部，并提供自动刷新下拉选项：`1 秒`、`3 秒`、`5 秒`、`10 秒`、`15 秒`、`30 秒`，默认 `5 秒`。控制台日志面板默认显示 `/run/microwarp/console.log` 的最近 300 行，可用 `MANAGEMENT_LOG_LINES` 调整范围；提供“回到底部”以重新跟随实时输出，以及“复制日志”以复制当前显示内容。自动化调用：`POST /__microwarp/api/v1/instances/<实例号>/force-reconnect` 用于强制重连；`POST /__microwarp/api/v1/instances` 并传入 `{"action":"add","count":2}` 可临时添加 2 个实例，或传入 `{"action":"remove","ids":[2,3]}` 批量移除临时实例；接口立即返回 `202`，随后通过状态接口轮询结果。

定时计划自动化接口为 `POST /__microwarp/api/v1/restart-schedule`：传入 `{"action":"pause"}` 暂停后续定时滚动重启，传入 `{"action":"resume"}` 恢复；接口返回当前计划快照。计划详情与执行结果同时包含在 `GET /__microwarp/api/v1/status` 的 `restart_schedule` 字段中。该接口仅接受 `pause` / `resume`，不在运行时修改周期、并发或延后队列复查配置；如需调整这些策略，请修改对应的 `ROTATE_RESTART_*` 环境变量后重建容器。

管理操作采用可追踪任务闭环：接口的 `202` 响应会返回 `operation.operation_id`、动作、排队状态和开始时间；`GET /__microwarp/api/v1/status` 中的实例操作会持续返回阶段、消息、开始时间、已耗时和终态标记，繁忙的优雅重连、停用或临时实例移除会显示“等待自然空闲”、当前连接数与下次复查时间；批量增减还会返回总数、已处理、成功与失败数量。页面在存在任务时自动以 `1 秒` 刷新，完成或失败后给出明确结果；失败实例可直接重试或跳转到该实例的管理日志。若 WARP 探测达到 `MANAGEMENT_ACTION_PROBE_TIMEOUT`，会先记录 `warp-probe-timeout`；健康守护在后续探测中确认实例恢复并重新入池后，会将终态更新为 `recovered`（超时后已恢复），同时保留首次超时的时间、原因码、原因和超时后恢复等待时间，避免实际已健康但页面仍显示失败。优雅重连与停用的确认框会展示活跃连接数和队列策略；存在活跃连接时，强制重连必须勾选“我知道这会立即中断当前实例上的连接”才能提交。实例区支持按需要关注、操作中、健康、已停用和临时实例筛选；页面会展示数据新鲜度与刷新错误。日志区支持警告/错误筛选、暂停跟随时的新日志计数，并可从失败实例跳转到相关管理日志。

> **匿名访问：** 管理页面与 API 会刻意绕过 SOCKS / HTTP Proxy 认证。启用前应仅通过可信宿主机绑定、私有网络、防火墙或反向代理 ACL 开放 `BIND_PORT`。

#### 健康、自愈与滚动重启

每个实例通过其内部 SOCKS 请求 `https://www.cloudflare.com/cdn-cgi/trace`。只有返回 `warp=on` 或 `warp=plus` 时才加入后端池。每轮健康检查采用动态并发窗口：已经完成的实例会立即让出位置给下一个实例。单个工作流中的 WARP 主探测、IPv4 出口探测和启用后的 IPv6 出口探测会并行启动；**WARP 主探测成功后会立即写入 `ready` 并登记入池请求**，不等待出口观测完成。为避免单实例三类探测把资源消耗放大，健康守护、Docker 健康检查、手工 `probe` 和管理面强制探测共享一个令牌池，默认同时最多运行 `HEALTH_PROBE_CONCURRENCY=32` 个实际 HTTP 探测请求。大量实例同时就绪时，后端池状态会先写入待处理目录，并由一个提交者在 `BACKEND_POOL_BATCH_WINDOW_MS`（默认 100ms）内合并、原子更新 `backends.meta` 与 `backends.txt`；这避免了每个实例依次持锁重建整个后端池，也不会因旧版 5 秒锁等待而丢失 `up` 状态。IPv4/IPv6 结果随后补写至状态文件；它们失败或超时只会显示为 `—`，不会让已就绪实例摘流。健康守护从启动起每 `HEALTH_STARTUP_RETRY_INTERVAL`（默认 3 秒）尝试入池；`HEALTH_START_PERIOD`（默认 90 秒）只用于抑制这段时间内的失败重启，不会让已经就绪的后端空等 90 秒。宽限期后连续失败达到 `HEALTH_SOFT_FAILURES` 时才重启该实例，且默认**不会删除持久化身份**。

滚动重启会在每轮开始时快照当前基础实例和临时实例，并逐一判断是否可处理：仅健康状态为 `ready`、仍在后端池中，且未被手工停用、未执行管理操作、未处于其他重启流程的实例才会参与本轮分类。默认 `ROTATE_RESTART_CONCURRENCY=auto` 时，并行额度为 `max(1, floor(当前实例总数 / 5))`；例如 100 个实例会同时最多处理 20 个。可设置正整数显式覆盖，例如 `ROTATE_RESTART_CONCURRENCY=5`。

调度器使用空闲优先的连续双队列：活跃连接数为 `0` 的实例进入就绪队列；仍有活跃连接的实例进入延后队列，保持在后端池中继续服务。延后队列按 `ROTATE_RESTART_DEFERRED_CHECK_INTERVAL`（默认 `60` 秒）在**同一轮滚动重启内**复查，连接自然归零后立即转入就绪队列；延后不是失败，也不会占用重启并行额度。调度器不是按固定分组等待：任一空闲实例完成或失败后，会立即从就绪队列补充下一个空闲实例，因此整个过程中在有待处理实例时始终尽量维持该并行数。真正回收前，实例会先从后端池摘流并再次确认活跃连接数仍为 `0`；若复核发现新连接，则立即恢复流量并转入延后队列。确认空闲后才执行重启、trace 验证 WARP 就绪和重新入池。定时滚动重启不会因连接排空超时而强制中断代理会话。

管理页的定时重启卡会**持续显示**就绪队列数量、延后队列数量及延后队列下一次复查时间（没有待复查实例时明确显示 `0` 与“当前无待复查实例”）。可点击两个队列查看实例列表。最近执行存在失败时，可查看每个失败实例的阶段、原因码、可读原因、重试次数、活跃连接数和时间，并可复制诊断或跳转实例日志。最近 `ROTATE_RESTART_HISTORY_LIMIT`（默认 `20`）轮会保留成功/失败/跳过/延后数量、队列峰值、平均延后等待时间，以及成功率、失败数、延后数趋势；运行时目录会随容器重启清理。

查看状态：

```bash
docker exec -it microwarp /app/instance-ctl.sh status
docker exec -it microwarp /app/rotate-restart.sh status
```

#### 通过 SOCKS5 上游建立 WARP

`UPSTREAM_SOCKS5` 有两条不同的承载路径。最终业务出口仍是 Cloudflare WARP，而不是上游 SOCKS5 节点。

| `UPSTREAM_SOCKS5_TRANSPORT` | 适用隧道 | 上游要求 | `/dev/net/tun` |
|---|---|---|---|
| `tun`（默认） | WireGuard、MASQUE HTTP/3/QUIC，或任何需要完整 IP 转发的情形 | `UPSTREAM_SOCKS5_UDP_MODE=udp` 的标准 UDP ASSOCIATE，或 `udp_mode=tcp` 的 UDP-in-TCP 扩展 | 需要 |
| `tcp` | **仅** `TUNNEL_PROTOCOL=masque` + `MASQUE_PROXY_MODE=socks` + `MASQUE_HTTP2=1` | 普通 SOCKS5 `CONNECT` 即可；无需 UDP Associate | 不需要 |

`UPSTREAM_SOCKS5_UDP_MODE=tcp` 的含义始终是 **UDP-in-TCP 扩展**，不是普通 SOCKS5 TCP CONNECT。要让只支持 TCP CONNECT 的 SOCKS5 服务承载 MASQUE HTTP/2，请使用新的 `UPSTREAM_SOCKS5_TRANSPORT=tcp`。

##### 默认 TUN 上游：需要 UDP

`tun` 模式会启动内置 `hev-socks5-tunnel`，将实例默认路由交给 TUN，再经上游执行 `wgcf` 注册、WireGuard 外层 UDP 或 MASQUE QUIC 连接：

```yaml
environment:
  - UPSTREAM_SOCKS5=socks5://192.168.1.15:20122 # 已验证的 LAN SOCKS5 示例
  - UPSTREAM_SOCKS5_TRANSPORT=tun # 默认，可省略
  - UPSTREAM_SOCKS5_UDP_MODE=udp # udp（UDP Associate） | tcp（UDP-in-TCP）
  - UPSTREAM_MTU=1280
  - UPSTREAM_VERIFY=1 # 启动时验证上游 TUN 的 TCP + UDP
  - UPSTREAM_REQUIRED=1
```

使用 TUN 上游时，需要额外挂载 `/dev/net/tun`。`UPSTREAM_SOCKS5_UDP_MODE=udp`（默认）使用标准 SOCKS5 UDP Associate；`UPSTREAM_SOCKS5_UDP_MODE=tcp` 使用 **UDP-in-TCP 扩展**。后者不是普通 SOCKS5 TCP CONNECT：上游 SOCKS5 服务端必须明确支持该扩展（例如 `hev-socks5-server`），否则不能使用。`UPSTREAM_REQUIRED=1` 是默认值：上游 TUN 启动失败时实例停止，而不会悄悄回退为直连。

兼容旧部署时仍读取 `UPSTREAM_SOCKS5_UDP`（以及开发期使用过的 `UPSTREAM_TRANSPORT`），但它们已废弃；请改用含义准确的 `UPSTREAM_SOCKS5_UDP_MODE`。

启动时默认会经 TUN 对数值 HTTPS 与 `1.1.1.1:53` UDP DNS 做验证（`UPSTREAM_VERIFY=1`）。这样“SOCKS5 TCP CONNECT 可用、但 UDP relay 不可用”的节点会在注册前明确失败；可用 `UPSTREAM_PROBE_TIMEOUT` 调整探测超时。

`192.168.1.15:20122` 已完成 WireGuard 经上游的注册、握手与 `warp=on` 实测。其 MASQUE HTTP/3 / QUIC 到 Cloudflare UDP 443 数据面在当前出站策略下超时；改用 `MASQUE_PROXY_MODE=socks` 与 `MASQUE_HTTP2=1` 的 TCP 回退可通过。

##### 标准 TCP SOCKS5 上游：仅 MASQUE HTTP/2

对于只支持 SOCKS5 `CONNECT`、不支持 UDP ASSOCIATE 的代理服务，使用下面的专用组合：

```yaml
environment:
  - TUNNEL_PROTOCOL=masque
  - MASQUE_PROXY_MODE=socks
  - MASQUE_HTTP2=1
  - UPSTREAM_SOCKS5=socks5://user:pass@192.168.1.2:1085
  - UPSTREAM_SOCKS5_TRANSPORT=tcp
  - UPSTREAM_VERIFY=1 # 验证标准 SOCKS5 CONNECT 数值 HTTPS；不做 UDP 探测
  - UPSTREAM_REQUIRED=1
```

此模式把 `UPSTREAM_SOCKS5` 规范为 `socks5://`。注册阶段的 HTTPS 请求经标准 SOCKS5 CONNECT 发出；数据面则启动仅监听 `127.0.0.1:443` 的本地中继，将 usque 固定的 HTTP/2 endpoint 再经 SOCKS5 CONNECT 转发。这样既能使用普通 TCP-only SOCKS5，又不会因按域名重新拨号而破坏 usque 的 endpoint 公钥钉扎。它不创建 `hev-socks5-tunnel`、不接管默认路由、也不需要 `/dev/net/tun`。为防止误用，以下任一配置都会在启动时被拒绝，而不会静默直连：

- `TUNNEL_PROTOCOL=wireguard`；
- `MASQUE_PROXY_MODE=l4-socks`（HTTP/3 / QUIC）；
- `MASQUE_HTTP2=0`。

`UPSTREAM_VERIFY=1` 在该模式仅验证 SOCKS5 TCP CONNECT 能否访问数值 HTTPS；随后健康检查仍须实际返回 `warp=on`/`warp=plus` 才会将实例加入后端池。

Linux Docker 使用宿主代理时可配置 `UPSTREAM_SOCKS5=socks5://host.docker.internal:20122`；示例 Compose 已添加 `host.docker.internal:host-gateway` 映射。

> **宿主机 `127.0.0.1` 的限制：** 在 Docker bridge 网络中，容器通过 `host.docker.internal` 访问宿主 SOCKS5 时，TUN 模式的 UDP ASSOCIATE 若返回 `127.0.0.1:动态端口`，该地址会指向**容器自身**，UDP 仍不可达。应让 SOCKS5 服务返回容器可路由的 relay 地址；在原生 Linux 上也可使用 `network_mode: host` 使容器与宿主共享网络命名空间。该限制不适用于上述 `transport=tcp` 专用分支：它只使用普通 TCP CONNECT。

#### 目标域名地址族偏好

`ENABLE_IPV6=1` 只为 WireGuard 启用 IPv6 地址与路由，**不会**使域名请求自动优先 IPv6；目标地址族选择由下面的 `RESOLVE_PREFERENCE` 决定。

```text
RESOLVE_PREFERENCE=auto          # 默认，由系统地址排序决定
RESOLVE_PREFERENCE=ipv4_prefer   # 优先 IPv4；不可达时尝试 IPv6
RESOLVE_PREFERENCE=ipv6_prefer   # 优先 IPv6；不可达时尝试 IPv4
RESOLVE_PREFERENCE=ipv4_only     # SOCKS 域名请求仅解析 A
RESOLVE_PREFERENCE=ipv6_only     # SOCKS 域名请求仅解析 AAAA
# 旧 ipv4 / ipv6 仍兼容，分别等价于 ipv4_only / ipv6_only
```

该选项只影响 **WireGuard MicroSOCKS** 由代理服务端解析的域名请求；客户端若已把域名解析为数值 IPv4 / IPv6 并以该地址发起 SOCKS 请求，代理不会再执行 DNS，也不能将 IPv4 改成 IPv6（或反向改写）。`prefer` 会先尝试优先地址族，连接失败后继续尝试同一域名的其余候选地址。使用 `socks5h://` 或让客户端把域名交给代理时，才会受此项影响；MASQUE 的解析由 usque 与 `MASQUE_DNS_SERVERS` 决定。

### 🧪 测试结果

完整的执行环境、命令、通过项与已定位失败项见 [TEST_RESULTS.md](TEST_RESULTS.md)。

### 🔧 相对旧版的主要修复（重构摘要）

* **IPv6 不再被强行剥离**：旧版会删除全部 `Address`/`AllowedIPs` 后只写回 IPv4。
* **错误处理**：`set -eu`、下载重试、GitHub API 失败回退版本、`wg-quick` 失败时打印诊断而非静默成功。
* **配置清洗更安全**：按字段精确删除并重建，避免 BusyBox `sed` 误伤。
* **策略路由双栈**：IPv4 table 128 + IPv6 table 129；Tailscale IPv6 ULA 回程同步恢复。
* **注册流程隔离**：`wgcf` 在临时目录执行，阅后即焚，避免污染工作目录。
* **镜像依赖补齐**：`ip6tables`、`ca-certificates`、`openresolv`；基础镜像固定 `alpine:3.21`。
* **可选 MASQUE**：镜像内置 [usque](https://github.com/Diniboy1123/usque)；`TUNNEL_PROTOCOL=masque` 走 CONNECT-IP，默认仍为内核 WireGuard。

### 🙏 致谢

* [ViRb3/wgcf](https://github.com/ViRb3/wgcf) — WireGuard 账号注册
* [rofl0r/microsocks](https://github.com/rofl0r/microsocks) — 极简 SOCKS5
* [Diniboy1123/usque](https://github.com/Diniboy1123/usque) — 开源 WARP MASQUE / CONNECT-IP 客户端


---

*特别鸣谢 __LinuxDo__ 社区* ❤️

---

## 🔄 Upstream / Fork Maintenance

This repository is maintained by **lazzman** as a derivative of [ccbkkb/MicroWARP](https://github.com/ccbkkb/MicroWARP). The original repository is configured as the default pull/rebase source; this repository is the default push target. See the project-level [upstream rebase skill](.agents/skills/microwarp-rebase-upstream/SKILL.md) for the safe synchronization workflow.

### 🔄 上游同步与派生维护

本仓库由 **lazzman** 基于 [ccbkkb/MicroWARP](https://github.com/ccbkkb/MicroWARP) 持续维护。作者仓库是默认拉取与 rebase 基线，当前仓库是默认推送目标；安全同步操作见项目级 [上游 rebase skill](.agents/skills/microwarp-rebase-upstream/SKILL.md)。
