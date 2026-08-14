#!/usr/bin/env bash
# MicroWARP entrypoint — dual-stack Cloudflare WARP SOCKS5 proxy
# Protocols: WireGuard (kernel, default) | MASQUE (usque userspace)
# shellcheck shell=bash
set -eo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log-utils.sh
source "${APP_DIR}/log-utils.sh"
# shellcheck source=netns-utils.sh
source "${APP_DIR}/netns-utils.sh"

# ==========================================
# Defaults
# ==========================================
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_DIR="$(dirname "$WG_CONF")"
WG_IFACE="${WG_IFACE:-wg0}"
WG_MTU="${MTU:-1280}"
LISTEN_ADDR="${BIND_ADDR:-0.0.0.0}"
LISTEN_PORT="${BIND_PORT:-1080}"
# 后续控制面统一使用标准化后的公开监听变量。
BIND_ADDR="${BIND_ADDR:-$LISTEN_ADDR}"
BIND_PORT="${BIND_PORT:-$LISTEN_PORT}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
TAILSCALE_CIDR="${TAILSCALE_CIDR:-100.64.0.0/10}"
TAILSCALE_CIDR_V6="${TAILSCALE_CIDR_V6:-fd7a:115c:a1e0::/48}"
KEEPALIVE="${KEEPALIVE:-15}"
# Fallback when GitHub API is unavailable / rate-limited
WGCF_FALLBACK_VER="${WGCF_FALLBACK_VER:-2.2.29}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
# Keep egress probe short so it never delays SOCKS readiness
TRACE_TIMEOUT="${TRACE_TIMEOUT:-3}"
TRACE_CONNECT_TIMEOUT="${TRACE_CONNECT_TIMEOUT:-2}"

# Tunnel protocol: wireguard (default) | masque
# Aliases: wg → wireguard; usque → masque
TUNNEL_PROTOCOL="${TUNNEL_PROTOCOL:-wireguard}"

# 单容器控制面。默认单实例 SOCKS5 路径不启动 LB、健康守护或滚动重启。
INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
# 单个容器启动多实例时的错峰间隔。保留短暂错峰以平滑首次注册压力，同时
# 避免旧版每实例固定等待 1 秒导致大规模部署的可用后端长时间为空。
INSTANCE_START_STAGGER="${INSTANCE_START_STAGGER:-0.2}"
[[ "$INSTANCE_START_STAGGER" =~ ^[0-9]+([.][0-9]+)?$ ]] || INSTANCE_START_STAGGER=0.2
PROXY_MODE="${PROXY_MODE:-socks5}"                 # socks5 | mixed
LB_ENABLED="${LB_ENABLED:-auto}"                   # auto | 1 | 0
LB_STRATEGY="${LB_STRATEGY:-round}"                 # round | random | hash | rotate
LB_STICKY_MODE="${LB_STICKY_MODE:-username-round}" # username-round | username-hash | client-ip-hash | disabled
LB_ROTATE_INTERVAL="${LB_ROTATE_INTERVAL:-5m}"
LB_MAX_CONN="${LB_MAX_CONN:-512}"
# 双向无流量超时而非连接总时长；默认 600 秒兼顾 LLM 流式的首 token 等待与资源回收。
LB_IDLE_TIMEOUT="${LB_IDLE_TIMEOUT:-600}"
LB_HANDSHAKE_TIMEOUT="${LB_HANDSHAKE_TIMEOUT:-30}"
# 详细记录每个客户端目标会暴露访问元数据，默认仅记录生命周期与异常。
# 开启后默认记录已解析的 HTTP 请求头；认证/Cookie/Token 等敏感字段由 LB 脱敏。
LB_ACCESS_LOG="${LB_ACCESS_LOG:-0}"
LB_ACCESS_LOG_HEADERS="${LB_ACCESS_LOG_HEADERS:-1}"
LB_ACCESS_LOG_HEADER_MAX_CHARS="${LB_ACCESS_LOG_HEADER_MAX_CHARS:-8192}"
# 管理面板默认关闭；启用后复用 BIND_PORT，并强制启动控制面与内置 LB。
MANAGEMENT_UI_ENABLED="${MANAGEMENT_UI_ENABLED:-0}"
MANAGEMENT_ACTION_PROBE_TIMEOUT="${MANAGEMENT_ACTION_PROBE_TIMEOUT:-180}"
INTERNAL_PROXY_PORT="${INTERNAL_PROXY_PORT:-1081}"
MICROWARP_RUNTIME_ROOT="${MICROWARP_RUNTIME_ROOT:-/run/microwarp}"
MICROWARP_LOG_FILE="${MICROWARP_LOG_FILE:-${MICROWARP_RUNTIME_ROOT}/console.log}"
MICROWARP_DYNAMIC_INSTANCES_FILE="${MICROWARP_DYNAMIC_INSTANCES_FILE:-${MICROWARP_RUNTIME_ROOT}/instances.dynamic}"
# 多实例中的 Docker 内置 DNS（127.0.0.11）不在子网络命名空间内监听；
# 通过 /etc/netns/<名称>/resolv.conf 为注册和隧道进程提供可路由 DNS。
NETNS_DNS_SERVERS="${NETNS_DNS_SERVERS:-1.1.1.1,1.0.0.1}"
# 统一使用 SOCKS_USER/SOCKS_PASS 配置公开入口认证。保留 PROXY_USER/PASS
# 仅作旧部署兼容回退；多实例内部后端始终无认证。
SOCKS_USER="${SOCKS_USER:-${PROXY_USER:-}}"
SOCKS_PASS="${SOCKS_PASS:-${PROXY_PASS:-}}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_PROBE_TIMEOUT="${HEALTH_PROBE_TIMEOUT:-10}"
# 全局最多同时运行的实际 HTTP 探测数量，避免大规模实例瞬间耗尽网络与进程资源。
HEALTH_PROBE_CONCURRENCY="${HEALTH_PROBE_CONCURRENCY:-32}"
[[ "$HEALTH_PROBE_CONCURRENCY" =~ ^[0-9]+$ ]] && [ "$HEALTH_PROBE_CONCURRENCY" -gt 0 ] || HEALTH_PROBE_CONCURRENCY=32
HEALTH_SOFT_FAILURES="${HEALTH_SOFT_FAILURES:-3}"
HEALTH_START_PERIOD="${HEALTH_START_PERIOD:-90}"
HEALTH_STARTUP_RETRY_INTERVAL="${HEALTH_STARTUP_RETRY_INTERVAL:-3}"
# 健康守护首次观测或实例状态变化时输出图标状态表；0 可关闭。
STATUS_EVENT_LOG="${STATUS_EVENT_LOG:-1}"
# auto：多实例、Mixed 或显式 LB 时启用；1：单实例也常驻健康与自愈。
CONTROL_PLANE_ENABLED="${CONTROL_PLANE_ENABLED:-auto}"
ROTATE_RESTART_ENABLED="${ROTATE_RESTART_ENABLED:-auto}"
ROTATE_RESTART_INTERVAL="${ROTATE_RESTART_INTERVAL:-6h}"
ROTATE_RESTART_PROBE_TIMEOUT="${ROTATE_RESTART_PROBE_TIMEOUT:-90}"
ROTATE_RESTART_RETRIES="${ROTATE_RESTART_RETRIES:-2}"
# auto：按当前实例总数的 1/5 并行滚动；正整数可显式指定并发数量。
ROTATE_RESTART_CONCURRENCY="${ROTATE_RESTART_CONCURRENCY:-auto}"
# 空闲优先队列中繁忙实例的复查间隔；支持秒数或 1m 等时长。
ROTATE_RESTART_DEFERRED_CHECK_INTERVAL="${ROTATE_RESTART_DEFERRED_CHECK_INTERVAL:-60}"
# 仅保留有限轮的定时重启诊断，运行时目录不会跨容器重启。
ROTATE_RESTART_HISTORY_LIMIT="${ROTATE_RESTART_HISTORY_LIMIT:-20}"
[[ "$ROTATE_RESTART_HISTORY_LIMIT" =~ ^[0-9]+$ ]] && [ "$ROTATE_RESTART_HISTORY_LIMIT" -gt 0 ] || ROTATE_RESTART_HISTORY_LIMIT=20
# 上游 SOCKS5 TUN。启用后失败即终止该实例，避免静默退回直连。
UPSTREAM_SOCKS5="${UPSTREAM_SOCKS5:-}"
# udp=标准 SOCKS5 UDP Associate；tcp=UDP-in-TCP 扩展。
# UPSTREAM_SOCKS5_UDP / UPSTREAM_TRANSPORT 是兼容别名，不建议继续使用。
UPSTREAM_SOCKS5_UDP_MODE="${UPSTREAM_SOCKS5_UDP_MODE:-${UPSTREAM_TRANSPORT:-${UPSTREAM_SOCKS5_UDP:-udp}}}"
# tun：由 hev-socks5-tunnel 承载完整 IP 流量，要求上游可转发 UDP；
# tcp：仅让 MASQUE HTTP/2 数据面使用标准 SOCKS5 CONNECT，无需 UDP Associate。
# 注意它不同于 UPSTREAM_SOCKS5_UDP_MODE=tcp（后者是 UDP-in-TCP 扩展）。
UPSTREAM_SOCKS5_TRANSPORT="${UPSTREAM_SOCKS5_TRANSPORT:-tun}"
UPSTREAM_MTU="${UPSTREAM_MTU:-1280}"
UPSTREAM_VERIFY="${UPSTREAM_VERIFY:-1}"
UPSTREAM_PROBE_TIMEOUT="${UPSTREAM_PROBE_TIMEOUT:-8}"
UPSTREAM_REQUIRED="${UPSTREAM_REQUIRED:-1}"
RESOLVE_PREFERENCE="${RESOLVE_PREFERENCE:-auto}"   # auto | ipv4_prefer | ipv6_prefer | ipv4_only | ipv6_only

# MASQUE / usque
# Config co-located under /etc/wireguard so existing warp-data volume persists it.
USQUE_CONFIG="${USQUE_CONFIG:-/etc/wireguard/masque-config.json}"
# l4-socks = lighter TCP-only (recommended); socks = full gVisor L3 (TCP+UDP, heavier)
MASQUE_PROXY_MODE="${MASQUE_PROXY_MODE:-l4-socks}"
MASQUE_HTTP2="${MASQUE_HTTP2:-0}"
MASQUE_SNI="${MASQUE_SNI:-}"
MASQUE_MTU="${MASQUE_MTU:-}"
# 逗号分隔；IPv6 关闭时默认只使用 IPv4 DNS，避免 usque 默认 IPv6 DNS 无路由。
MASQUE_DNS_SERVERS="${MASQUE_DNS_SERVERS:-}"
# Optional identity extras
WARP_JWT="${WARP_JWT:-}"
WARP_LICENSE="${WARP_LICENSE:-}"
USQUE_DEVICE_NAME="${USQUE_DEVICE_NAME:-MicroWARP}"
# Cap Go runtime RSS on small VPS (MASQUE path only; ignored by WireGuard path)
GOMEMLIMIT="${GOMEMLIMIT:-512MiB}"

# ==========================================
# Logging helpers
# ==========================================
log_scope() {
    if [ -n "${INSTANCE_ID:-}" ]; then
        printf '实例:%s' "$INSTANCE_ID"
    else
        printf '主进程'
    fi
}
log()  { mw_info "$(log_scope)" "$*"; }
ok()   { mw_ok "$(log_scope)" "$*"; }
step() { mw_step "$(log_scope)" "$*"; }
warn() { mw_warn "$(log_scope)" "$*"; }
die()  { mw_error "$(log_scope)" "$*"; exit 1; }

# ==========================================
# Test mode (CI / dry-run)
# ==========================================
if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    log "测试模式已启用，跳过全部初始化。"
    exit 0
fi

# ==========================================
# Utility
# ==========================================
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Run a command with a hard wall-clock limit when possible.
# Usage: run_with_timeout SECONDS command [args...]
run_with_timeout() {
    secs="$1"
    shift
    if command_exists timeout; then
        timeout "$secs" "$@" 2>/dev/null && return 0
        timeout -t "$secs" "$@" 2>/dev/null && return 0
        return 1
    fi
    "$@"
}

github_auth_header() {
    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
        printf 'Authorization: Bearer %s' "$token"
    fi
}

detect_arch() {
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armhf)  printf 'armv7' ;;
        *) die "不支持的架构: $arch" ;;
    esac
}

build_wgcf_download_url() {
    ver="$1"
    arch="$2"
    raw="https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
    if [ -n "${GH_PROXY:-}" ]; then
        printf '%s/%s' "${GH_PROXY%/}" "$raw"
    else
        printf '%s' "$raw"
    fi
}

fetch_latest_wgcf_version() {
    api="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    auth="$(github_auth_header)"
    body=""

    if [ -n "$auth" ]; then
        body="$(curl -fsSL -m "$CURL_TIMEOUT" -H "$auth" "$api" 2>/dev/null || true)"
    else
        body="$(curl -fsSL -m "$CURL_TIMEOUT" "$api" 2>/dev/null || true)"
    fi

    ver="$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n 1 || true)"
    if [ -z "$ver" ]; then
        warn "无法从 GitHub API 获取 wgcf 版本，使用回退版本 v${WGCF_FALLBACK_VER}"
        printf '%s' "$WGCF_FALLBACK_VER"
        return 0
    fi
    printf '%s' "$ver"
}

download_file() {
    url="$1"
    dest="$2"
    tries=0
    max_tries=3

    while [ "$tries" -lt "$max_tries" ]; do
        tries=$((tries + 1))
        if command_exists wget; then
            if wget --timeout=30 -qO "$dest" "$url" 2>/dev/null; then
                [ -s "$dest" ] && return 0
            fi
        fi
        if command_exists curl; then
            if curl -fsSL -m 30 -o "$dest" "$url" 2>/dev/null; then
                [ -s "$dest" ] && return 0
            fi
        fi
        warn "下载失败 (尝试 ${tries}/${max_tries}): $url"
        sleep $((tries * 2))
    done
    return 1
}

# Extract first IPv4 CIDR from text
extract_ipv4_cidr() {
    # 在 pipefail 下，没有匹配项也必须让调用方获得空字符串后自行报错。
    printf '%s' "$1" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1 || true
}

# Extract first IPv6 CIDR (comma/space separated tokens with ':')
extract_ipv6_cidr() {
    printf '%s' "$1" \
        | tr ',' '\n' \
        | tr ' ' '\n' \
        | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' \
        | grep -E ':' \
        | head -n 1 || true
}

is_truthy() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

iface_has_global_ipv6() {
    dev="$1"
    ip -6 addr show dev "$dev" scope global 2>/dev/null | grep -q 'inet6 '
}

normalize_tunnel_protocol() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        wireguard|wg|wg0|kernel) printf 'wireguard' ;;
        masque|usque|h3|http3|quic) printf 'masque' ;;
        *) die "未知 TUNNEL_PROTOCOL='$1'（支持: wireguard | masque）" ;;
    esac
}

normalize_masque_proxy_mode() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        l4|l4-socks|l4_socks|l4socks) printf 'l4-socks' ;;
        socks|full|gvisor|l3) printf 'socks' ;;
        *) die "未知 MASQUE_PROXY_MODE='$1'（支持: l4-socks | socks）" ;;
    esac
}

# WireGuard 的 MicroSOCKS 目标域名解析策略。仅限模式只保留一种地址族；优先
# 模式保留 A 和 AAAA，若优先地址族存在则优先使用，失败时仍可回退另一种地址族。
# 保留 ipv4/ipv6 旧值兼容，并在启动日志中说明已标准化为 *_only。
normalize_resolve_preference() {
    local raw
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        auto|default) printf 'auto' ;;
        ipv4_prefer|ipv4-prefer|prefer_ipv4|prefer-ipv4|v4_prefer|v4-prefer) printf 'ipv4_prefer' ;;
        ipv6_prefer|ipv6-prefer|prefer_ipv6|prefer-ipv6|v6_prefer|v6-prefer) printf 'ipv6_prefer' ;;
        ipv4_only|ipv4-only|v4_only|v4-only) printf 'ipv4_only' ;;
        ipv6_only|ipv6-only|v6_only|v6-only) printf 'ipv6_only' ;;
        ipv4|v4) warn "RESOLVE_PREFERENCE=${1} 已废弃，已按 ipv4_only 兼容"; printf 'ipv4_only' ;;
        ipv6|v6) warn "RESOLVE_PREFERENCE=${1} 已废弃，已按 ipv6_only 兼容"; printf 'ipv6_only' ;;
        *) die "未知 RESOLVE_PREFERENCE='$1'（支持: auto | ipv4_prefer | ipv6_prefer | ipv4_only | ipv6_only）" ;;
    esac
}

# 上游分两条实现路径：
# - tun：hev-socks5-tunnel 接管默认路由，可承载 WireGuard / QUIC 等 UDP 流量；
# - tcp：仅将 usque 的 HTTP/2 CONNECT-IP 连接交给标准 SOCKS5 CONNECT。
# 为避免与 UPSTREAM_SOCKS5_UDP_MODE=tcp（UDP-in-TCP 扩展）混淆，这里单独使用
# UPSTREAM_SOCKS5_TRANSPORT 表示整体承载路径。
normalize_upstream_socks5_transport() {
    raw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        tun|full|tunnel) printf 'tun' ;;
        tcp|tcp-proxy|tcp_proxy|connect) printf 'tcp' ;;
        *) die "未知 UPSTREAM_SOCKS5_TRANSPORT='$1'（支持: tun | tcp）" ;;
    esac
}

# Go 的 http.ProxyFromEnvironment / Transport 使用 socks5:// URI；用户配置中
# 允许沿用 socks://、socks5h:// 或无 scheme 的写法，启动前统一规范化。
normalize_standard_socks5_uri() {
    local raw
    raw="${1//[[:space:]]/}"
    case "$raw" in
        socks5://*) printf '%s\n' "$raw" ;;
        socks5h://*) printf 'socks5://%s\n' "${raw#socks5h://}" ;;
        socks://*) printf 'socks5://%s\n' "${raw#socks://}" ;;
        *://*) return 1 ;;
        *:*) printf 'socks5://%s\n' "$raw" ;;
        *) return 1 ;;
    esac
}

tcp_socks5_transport_is_compatible() {
    local proto proxy_mode
    proto="$(normalize_tunnel_protocol "$TUNNEL_PROTOCOL")"
    proxy_mode="$(normalize_masque_proxy_mode "$MASQUE_PROXY_MODE")"
    [ "$proto" = "masque" ] && [ "$proxy_mode" = "socks" ] && is_truthy "$MASQUE_HTTP2"
}

clear_standard_tcp_socks5_proxy() {
    unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy
}

# tcp 上游只验证标准 SOCKS5 CONNECT 下的数值 HTTPS。它刻意不验证 UDP DNS：
# 此分支只允许 MASQUE HTTP/2（TCP 443），而 UDP 验证属于 TUN 路径的职责。
verify_standard_tcp_socks5_proxy() {
    local proxy_uri="$1" output
    if ! output="$(curl -4 -fsS --connect-timeout "$UPSTREAM_PROBE_TIMEOUT" \
        --max-time "$UPSTREAM_PROBE_TIMEOUT" --proxy "$proxy_uri" \
        --resolve www.cloudflare.com:443:104.16.124.96 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" \
        || ! grep -q '^ip=' <<<"$output"; then
        return 1
    fi
    return 0
}

start_standard_tcp_socks5_proxy() {
    local proxy_uri error_message
    if ! tcp_socks5_transport_is_compatible; then
        error_message="UPSTREAM_SOCKS5_TRANSPORT=tcp 仅支持 TUNNEL_PROTOCOL=masque、MASQUE_PROXY_MODE=socks、MASQUE_HTTP2=1；WireGuard 和 MASQUE HTTP/3/QUIC 必须使用 transport=tun 且上游支持 UDP"
        mw_error "上游:${INSTANCE_ID:-0}" "$error_message"
        return 2
    fi
    if ! proxy_uri="$(normalize_standard_socks5_uri "$UPSTREAM_SOCKS5")"; then
        mw_error "上游:${INSTANCE_ID:-0}" "TCP 上游地址无效 | 仅接受 socks5://、socks5h://、socks:// 或 host:port"
        return 2
    fi

    # 注册与许可证 HTTPS 请求可直接读取标准代理环境变量。启动 usque 数据面前
    # 会清除这些变量并改用本地固定 endpoint 中继，避免 HTTP Transport 通过
    # SOCKS5 按域名拨号，破坏 usque 对 endpoint 公钥的钉扎。
    export HTTPS_PROXY="$proxy_uri"
    export https_proxy="$proxy_uri"
    export HTTP_PROXY="$proxy_uri"
    export http_proxy="$proxy_uri"

    step "启用标准 TCP SOCKS5 上游 | 地址=$(mw_redact_uri "$UPSTREAM_SOCKS5") | 用途=MASQUE HTTP/2 CONNECT-IP"
    if is_truthy "$UPSTREAM_VERIFY" && ! verify_standard_tcp_socks5_proxy "$proxy_uri"; then
        clear_standard_tcp_socks5_proxy
        mw_error "上游:${INSTANCE_ID:-0}" "TCP SOCKS5 CONNECT 探测失败 | 无法经上游访问数值 HTTPS"
        return 1
    fi
    if is_truthy "$UPSTREAM_VERIFY"; then
        ok "标准 TCP SOCKS5 上游验证通过 | TCP CONNECT=通过 | UDP 探测=不适用"
    else
        log "已跳过标准 TCP SOCKS5 上游预检 | UPSTREAM_VERIFY=0"
    fi
    STANDARD_TCP_SOCKS5_PROXY_URI="$proxy_uri"
    ok "标准 TCP SOCKS5 上游已就绪 | 注册经 SOCKS5；数据面将经固定 endpoint 中继 | 无需 /dev/net/tun 与 UDP Associate"
}

standard_tcp_relay_pid_file() {
    printf '%s/tcp-socks5-relay.pid' "${INSTANCE_RUNTIME_DIR:-${MICROWARP_RUNTIME_ROOT}/instances/${INSTANCE_ID:-0}}"
}

stop_standard_tcp_socks5_relay() {
    local relay_pid_file relay_pid
    relay_pid_file="$(standard_tcp_relay_pid_file)"
    if [ -f "$relay_pid_file" ]; then
        relay_pid="$(cat "$relay_pid_file" 2>/dev/null || true)"
        [ -n "$relay_pid" ] && kill "$relay_pid" 2>/dev/null || true
        rm -f "$relay_pid_file"
    fi
}

# 在运行时生成 usque 配置副本，将 HTTP/2 endpoint 指向 127.0.0.1:443；本地
# relay 再使用标准 SOCKS5 CONNECT 到原 endpoint。原持久化身份配置不被修改，
# 避免下次重启把 127.0.0.1 误认为 Cloudflare endpoint。
prepare_standard_tcp_socks5_relay() {
    local source_config runtime_config target_endpoint relay_pid_file relay_log relay_pid
    [ -n "${STANDARD_TCP_SOCKS5_PROXY_URI:-}" ] || return 0
    [ -x /app/tcp-socks5-relay.py ] || die "镜像内缺少 tcp-socks5-relay.py"
    source_config="$USQUE_CONFIG"
    [ -s "$source_config" ] || die "标准 TCP SOCKS5 中继缺少 MASQUE 配置: ${source_config}"
    mkdir -p "$INSTANCE_RUNTIME_DIR"
    runtime_config="${INSTANCE_RUNTIME_DIR}/masque-http2-tcp-proxy.json"

    if ! target_endpoint="$(python3 - "$source_config" "$runtime_config" <<'PY'
import ipaddress
import json
import sys

source, destination = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    config = json.load(handle)
endpoint = config.get("endpoint_h2_v4") or "162.159.198.2"
try:
    parsed = ipaddress.ip_address(endpoint)
except ValueError as exc:
    raise SystemExit(f"endpoint_h2_v4 不是数值 IP: {endpoint}: {exc}")
if parsed.version != 4:
    raise SystemExit(f"endpoint_h2_v4 必须是 IPv4: {endpoint}")
config["endpoint_h2_v4"] = "127.0.0.1"
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
print(endpoint)
PY
    )"; then
        die "无法为标准 TCP SOCKS5 创建 MASQUE HTTP/2 运行时配置"
    fi
    chmod 600 "$runtime_config" 2>/dev/null || true

    # usque 的 HTTP/2 proxy 分支会按 cloudflareaccess.com 域名执行 SOCKS5
    # CONNECT，绕过其 endpoint 公钥钉扎。数据面改由本地 relay 直拨 127.0.0.1。
    clear_standard_tcp_socks5_proxy
    stop_standard_tcp_socks5_relay
    relay_pid_file="$(standard_tcp_relay_pid_file)"
    relay_log="${INSTANCE_RUNTIME_DIR}/tcp-socks5-relay.log"
    step "启动标准 TCP SOCKS5 本地中继 | 本地=127.0.0.1:443 | Cloudflare=${target_endpoint}:443"
    /app/tcp-socks5-relay.py \
        --listen-host 127.0.0.1 --listen-port 443 \
        --proxy-uri "$STANDARD_TCP_SOCKS5_PROXY_URI" \
        --target-host "$target_endpoint" --target-port 443 \
        >>"$relay_log" 2>&1 &
    relay_pid=$!
    printf '%s\n' "$relay_pid" > "$relay_pid_file"
    for _ in $(seq 1 25); do
        if ! kill -0 "$relay_pid" 2>/dev/null; then
            break
        fi
        if ss -lnt 2>/dev/null | grep -q '127.0.0.1:443'; then
            USQUE_CONFIG="$runtime_config"
            ok "标准 TCP SOCKS5 本地中继已就绪 | 数据面经 SOCKS5 CONNECT"
            return 0
        fi
        sleep 0.1
    done
    cat "$relay_log" >&2 2>/dev/null || true
    stop_standard_tcp_socks5_relay
    die "标准 TCP SOCKS5 本地中继未能监听 127.0.0.1:443"
}

# ==========================================
# 1. Account registration / config bootstrap (WireGuard / wgcf)
# ==========================================
register_warp() {
    step "未检测到 WireGuard 身份，开始自动注册 Cloudflare WARP"

    arch="$(detect_arch)"
    ver="$(fetch_latest_wgcf_version)"
    log "检测到 wgcf 版本: v${ver} (${arch})"

    url="$(build_wgcf_download_url "$ver" "$arch")"
    workdir="$(mktemp -d /tmp/microwarp.XXXXXX)" || die "无法创建临时目录"
    # shellcheck disable=SC2064
    trap 'rm -rf "$workdir"' EXIT INT TERM

    if ! download_file "$url" "$workdir/wgcf"; then
        die "wgcf 二进制下载失败: $url"
    fi
    chmod +x "$workdir/wgcf"

    step "向 Cloudflare 注册 WireGuard 设备"
    # wgcf writes account next to CWD; silence both stdout and stderr noise
    if ! (
        cd "$workdir"
        ./wgcf register --accept-tos >/dev/null 2>&1
        step "生成 WireGuard 配置"
        ./wgcf generate >/dev/null 2>&1
    ); then
        die "wgcf 注册或配置生成失败"
    fi

    if [ ! -f "$workdir/wgcf-profile.conf" ]; then
        die "未找到 wgcf-profile.conf，注册可能失败"
    fi

    mv "$workdir/wgcf-profile.conf" "$WG_CONF"
    # Burn-after-read: drop account material & binary
    rm -rf "$workdir"
    trap - EXIT INT TERM
    ok "WireGuard 身份与配置已生成"
}

# ==========================================
# 2. Sanitize & rebuild WireGuard profile
# ==========================================
sanitize_config() {
    [ -f "$WG_CONF" ] || die "配置文件不存在: $WG_CONF"

    # Snapshot raw Address lines before mutation
    raw_address="$(grep -E '^[[:space:]]*Address[[:space:]]*=' "$WG_CONF" || true)"
    ipv4_addr="$(extract_ipv4_cidr "$raw_address")"
    ipv6_addr="$(extract_ipv6_cidr "$raw_address")"

    if [ -z "$ipv4_addr" ]; then
        ipv4_addr="$(extract_ipv4_cidr "$(cat "$WG_CONF")")"
    fi
    if [ -z "$ipv6_addr" ]; then
        ipv6_addr="$(extract_ipv6_cidr "$(cat "$WG_CONF")")"
    fi

    if [ -z "$ipv4_addr" ]; then
        die "无法从配置中解析 IPv4 Address，配置可能已损坏"
    fi

    # Drop fields we will rewrite (BusyBox-safe patterns)
    sed -i \
        -e '/^[[:space:]]*Address[[:space:]]*=/d' \
        -e '/^[[:space:]]*AllowedIPs[[:space:]]*=/d' \
        -e '/^[[:space:]]*DNS[[:space:]]*=/d' \
        -e '/^[[:space:]]*[Mm][Tt][Uu][[:space:]]*=/d' \
        "$WG_CONF"

    # Build Address value (dual-stack when available)
    if is_truthy "$ENABLE_IPV6" && [ -n "$ipv6_addr" ]; then
        address_value="${ipv4_addr},${ipv6_addr}"
        log "双栈地址: IPv4=${ipv4_addr}  IPv6=${ipv6_addr}"
    else
        address_value="$ipv4_addr"
        if is_truthy "$ENABLE_IPV6" && [ -z "$ipv6_addr" ]; then
            warn "ENABLE_IPV6=1 但配置中无 IPv6 地址，仅启用 IPv4"
        else
            log "IPv4 地址: ${ipv4_addr}"
        fi
    fi

    if ! grep -q '^\[Interface\]' "$WG_CONF"; then
        die "配置缺少 [Interface] 段"
    fi
    sed -i "/^\[Interface\]/a Address = ${address_value}" "$WG_CONF"
    sed -i "/^\[Interface\]/a MTU = ${WG_MTU}" "$WG_CONF"
    log "MTU = ${WG_MTU}"

    # AllowedIPs under [Peer]
    if is_truthy "$ENABLE_IPV6" && [ -n "$ipv6_addr" ]; then
        allowed_ips="0.0.0.0/0, ::/0"
    else
        allowed_ips="0.0.0.0/0"
    fi

    if ! grep -q '^\[Peer\]' "$WG_CONF"; then
        die "配置缺少 [Peer] 段"
    fi
    sed -i "/^\[Peer\]/a AllowedIPs = ${allowed_ips}" "$WG_CONF"

    # PersistentKeepalive — defeat NAT/QoS idle drops
    if grep -qi '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$WG_CONF"; then
        sed -i "s/^[[:space:]]*PersistentKeepalive[[:space:]]*=.*/PersistentKeepalive = ${KEEPALIVE}/g" "$WG_CONF"
    else
        sed -i "/^\[Peer\]/a PersistentKeepalive = ${KEEPALIVE}" "$WG_CONF"
    fi

    # Optional custom endpoint (IPv4 host:port or [IPv6]:port)
    if [ -n "${ENDPOINT_IP:-}" ]; then
        log "使用自定义 WireGuard Endpoint | 地址=${ENDPOINT_IP}"
        if grep -qi '^[[:space:]]*Endpoint[[:space:]]*=' "$WG_CONF"; then
            sed -i "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${ENDPOINT_IP}|g" "$WG_CONF"
        else
            sed -i "/^\[Peer\]/a Endpoint = ${ENDPOINT_IP}" "$WG_CONF"
        fi
    fi
}

# Alpine wg-quick may hard-fail on src_valid_mark; neutralize safely.
patch_wg_quick() {
    wg_quick_bin="$(command -v wg-quick || true)"
    if [ -n "$wg_quick_bin" ] && [ -f "$wg_quick_bin" ] && [ -w "$wg_quick_bin" ]; then
        # Pre-set the sysctl ourselves so semantics are preserved when possible
        sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null 2>&1 || true
        if is_truthy "$ENABLE_IPV6"; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1 || true
        fi
        # Remove the hard-failing line from wg-quick (idempotent)
        sed -i '/src_valid_mark/d' "$wg_quick_bin" 2>/dev/null || true
    fi
}

# ==========================================
# 3. Bring up interface & fix asymmetric routes
# ==========================================
capture_pre_warp_routes() {
    # Tailscale / CGNAT v4 path before default route is hijacked
    PRE_WARP_ROUTE_V4="$(ip -4 route get 100.64.0.1 2>/dev/null | head -n 1 || true)"
    PRE_WARP_GW_V4="$(printf '%s\n' "$PRE_WARP_ROUTE_V4" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
    PRE_WARP_DEV_V4="$(printf '%s\n' "$PRE_WARP_ROUTE_V4" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"

    PRE_WARP_GW_V6=""
    PRE_WARP_DEV_V6=""
    if is_truthy "$ENABLE_IPV6" && command_exists ip; then
        PRE_WARP_ROUTE_V6="$(ip -6 route get fd7a:115c:a1e0::1 2>/dev/null | head -n 1 || true)"
        PRE_WARP_GW_V6="$(printf '%s\n' "$PRE_WARP_ROUTE_V6" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
        PRE_WARP_DEV_V6="$(printf '%s\n' "$PRE_WARP_ROUTE_V6" | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    fi

    # Host/container primary path (for inbound reply policy routing)
    ORIG_GW_V4="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    ORIG_DEV_V4="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    ORIG_IP_V4=""
    if [ -n "${ORIG_DEV_V4:-}" ]; then
        ORIG_IP_V4="$(ip -4 addr show dev "$ORIG_DEV_V4" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1)"
    fi

    ORIG_GW_V6=""
    ORIG_DEV_V6=""
    ORIG_IP_V6=""
    if is_truthy "$ENABLE_IPV6"; then
        ORIG_GW_V6="$(ip -6 route show default 2>/dev/null | awk '{print $3; exit}')"
        ORIG_DEV_V6="$(ip -6 route show default 2>/dev/null | awk '{print $5; exit}')"
        if [ -n "${ORIG_DEV_V6:-}" ]; then
            # Prefer global unicast, skip link-local fe80::
            ORIG_IP_V6="$(ip -6 addr show dev "$ORIG_DEV_V6" scope global 2>/dev/null | awk '/inet6 / {print $2; exit}' | cut -d/ -f1)"
        fi
    fi
}

bring_up_wg() {
    step "启动 WireGuard 接口 | 名称=${WG_IFACE}"
    # Capture stderr; do not claim success when wg-quick fails
    if ! wg_out="$(wg-quick up "$WG_CONF" 2>&1)"; then
        printf '%s\n' "$wg_out" >&2
        warn "尝试清理半初始化接口..."
        wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
        die "wg-quick up ${WG_IFACE} 失败，请检查 NET_ADMIN / 内核 WireGuard 模块；若 IPv6 异常可设 ENABLE_IPV6=0"
    fi
}

install_policy_routes() {
    # IPv4: traffic sourced from container IP must leave via original gateway
    # (fixes published-port asymmetric routing / blackhole)
    if [ -n "${ORIG_IP_V4:-}" ] && [ -n "${ORIG_GW_V4:-}" ] && [ -n "${ORIG_DEV_V4:-}" ]; then
        log "注入 IPv4 策略路由 (from ${ORIG_IP_V4} via ${ORIG_GW_V4} dev ${ORIG_DEV_V4})"
        ip rule del from "$ORIG_IP_V4" table 128 2>/dev/null || true
        ip rule add from "$ORIG_IP_V4" table 128 priority 100 2>/dev/null || \
            warn "IPv4 ip rule 添加失败（内核可能不支持多路由表）"
        ip route replace table 128 default via "$ORIG_GW_V4" dev "$ORIG_DEV_V4" 2>/dev/null || \
            warn "IPv4 策略路由表 128 写入失败"
    fi

    # IPv6 policy routing (table 129) for container global address
    if is_truthy "$ENABLE_IPV6" && [ -n "${ORIG_IP_V6:-}" ] && [ -n "${ORIG_GW_V6:-}" ] && [ -n "${ORIG_DEV_V6:-}" ]; then
        log "注入 IPv6 策略路由 (from ${ORIG_IP_V6} via ${ORIG_GW_V6} dev ${ORIG_DEV_V6})"
        ip -6 rule del from "$ORIG_IP_V6" table 129 2>/dev/null || true
        ip -6 rule add from "$ORIG_IP_V6" table 129 priority 100 2>/dev/null || \
            warn "IPv6 ip rule 添加失败"
        ip -6 route replace table 129 default via "$ORIG_GW_V6" dev "$ORIG_DEV_V6" 2>/dev/null || \
            warn "IPv6 策略路由表 129 写入失败"
    fi

    # Restore Tailscale (and similar) return paths so mesh stays reachable
    if [ -n "${PRE_WARP_GW_V4:-}" ] && [ -n "${PRE_WARP_DEV_V4:-}" ]; then
        if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW_V4" dev "$PRE_WARP_DEV_V4" 2>/dev/null; then
            log "已恢复 ${TAILSCALE_CIDR} 回程路由 via ${PRE_WARP_GW_V4} dev ${PRE_WARP_DEV_V4}"
        fi
    fi

    if is_truthy "$ENABLE_IPV6" && [ -n "${PRE_WARP_GW_V6:-}" ] && [ -n "${PRE_WARP_DEV_V6:-}" ]; then
        if ip -6 route replace "$TAILSCALE_CIDR_V6" via "$PRE_WARP_GW_V6" dev "$PRE_WARP_DEV_V6" 2>/dev/null; then
            log "已恢复 ${TAILSCALE_CIDR_V6} 回程路由 via ${PRE_WARP_GW_V6} dev ${PRE_WARP_DEV_V6}"
        fi
    fi
}

# Best-effort egress IP print. Must never block SOCKS startup for long.
# Prefer numeric Cloudflare endpoints to avoid DNS hangs on broken stacks.
show_egress_ip() {
    step "开始出口连通性探测"

    v4_ok=0
    # 1.1.1.1 is numeric — no DNS required
    if out="$(run_with_timeout "$((TRACE_TIMEOUT + 1))" \
        curl -4 -sS --connect-timeout "$TRACE_CONNECT_TIMEOUT" -m "$TRACE_TIMEOUT" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"; then
        ip_line="$(printf '%s\n' "$out" | grep '^ip=' || true)"
        if [ -n "$ip_line" ]; then
            log "  IPv4 ${ip_line}"
            v4_ok=1
        fi
    fi
    if [ "$v4_ok" -eq 0 ]; then
        if out="$(run_with_timeout "$((TRACE_TIMEOUT + 1))" \
            curl -4 -sS --connect-timeout "$TRACE_CONNECT_TIMEOUT" -m "$TRACE_TIMEOUT" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"; then
            ip_line="$(printf '%s\n' "$out" | grep '^ip=' || true)"
            if [ -n "$ip_line" ]; then
                log "  IPv4 ${ip_line}"
                v4_ok=1
            fi
        fi
    fi
    if [ "$v4_ok" -eq 0 ]; then
        warn "IPv4 出口探测超时（握手延迟或节点被阻断）"
    fi

    if is_truthy "$ENABLE_IPV6"; then
        if ! iface_has_global_ipv6 "$WG_IFACE"; then
            warn "IPv6：${WG_IFACE} 无全局地址，跳过探测"
            return 0
        fi
        v6_ok=0
        # Prefer numeric IPv6 trace endpoint when possible
        if out="$(run_with_timeout "$((TRACE_TIMEOUT + 1))" \
            curl -6 -sS --connect-timeout "$TRACE_CONNECT_TIMEOUT" -m "$TRACE_TIMEOUT" \
            --resolve www.cloudflare.com:443:2606:4700::0011 \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"; then
            ip_line="$(printf '%s\n' "$out" | grep '^ip=' || true)"
            if [ -n "$ip_line" ]; then
                log "  IPv6 ${ip_line}"
                v6_ok=1
            fi
        fi
        if [ "$v6_ok" -eq 0 ]; then
            warn "IPv6 出口探测失败（隧道未就绪或目标不可达，SOCKS 仍可使用）"
        fi
    fi
}

# ==========================================
# 4. Launch microsocks (WireGuard path)
# ==========================================
start_socks() {
    # Default 0.0.0.0 keeps legacy IPv4-only listen.
    # Set BIND_ADDR=:: for IPv6 (and typically dual-stack) listen.
    set -- microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"

    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        ok "代理认证已启用"
        set -- "$@" -u "$SOCKS_USER" -P "$SOCKS_PASS"
    elif [ "${INTERNAL_PROXY:-0}" = "1" ]; then
        log "内部 SOCKS 后端不启用认证（认证由公开 Mixed/LB 入口统一处理）"
    else
        log "未启用代理认证（公开访问模式）"
    fi

    ok "MicroSOCKS 已监听 | 地址=${LISTEN_ADDR}:${LISTEN_PORT}"
    exec "$@"
}

# ==========================================
# 5. MASQUE path (usque)
# ==========================================
register_masque() {
    command_exists usque || die "镜像内未找到 usque，无法使用 MASQUE 模式"

    conf_dir="$(dirname "$USQUE_CONFIG")"
    mkdir -p "$conf_dir"

    if [ -f "$USQUE_CONFIG" ] && [ -s "$USQUE_CONFIG" ]; then
        log "检测到已有 MASQUE 配置: ${USQUE_CONFIG}"
        return 0
    fi

    # Drop zero-byte leftovers that confuse usque
    if [ -f "$USQUE_CONFIG" ] && [ ! -s "$USQUE_CONFIG" ]; then
        rm -f "$USQUE_CONFIG"
    fi

    log "未检测到 MASQUE 配置，正在通过 usque 注册 Cloudflare WARP 设备..."
    log "（注册完成前 SOCKS 不会监听；请勿在此阶段探测端口）"

    # Absolute path for -c; run from conf_dir so any relative side files land here.
    # -a accepts ToS non-interactively.
    set -- usque -c "$USQUE_CONFIG" register -a
    if [ -n "$USQUE_DEVICE_NAME" ]; then
        set -- "$@" -n "$USQUE_DEVICE_NAME"
    fi
    if [ -n "$WARP_JWT" ]; then
        log "使用 Zero Trust JWT 注册"
        set -- "$@" --jwt "$WARP_JWT"
    fi

    reg_log="$(mktemp /tmp/usque-register.XXXXXX 2>/dev/null || echo /tmp/usque-register.log)"
    # Capture output for diagnosis; usque often logs "Config file not found" before creating one.
    if ! (
        cd "$conf_dir" || exit 1
        "$@" >"$reg_log" 2>&1
    ); then
        warn "usque register 输出："
        cat "$reg_log" 2>/dev/null || true
        rm -f "$reg_log"
        die "usque register 失败（可能触发 Cloudflare 限流，请稍后重试并确保 volume 持久化配置）"
    fi
    # Show last lines even on success (helps CI)
    if [ -s "$reg_log" ]; then
        tail -n 15 "$reg_log" 2>/dev/null || true
    fi
    rm -f "$reg_log"

    # usque may write config.json next to CWD if -c path is awkward — normalize.
    if [ ! -f "$USQUE_CONFIG" ] || [ ! -s "$USQUE_CONFIG" ]; then
        if [ -f "$conf_dir/config.json" ] && [ -s "$conf_dir/config.json" ]; then
            mv -f "$conf_dir/config.json" "$USQUE_CONFIG"
            log "已将 config.json 规范为 ${USQUE_CONFIG}"
        fi
    fi

    [ -f "$USQUE_CONFIG" ] && [ -s "$USQUE_CONFIG" ] || \
        die "usque register 后未生成配置: $USQUE_CONFIG"

    ok "MASQUE 身份注册完成 | 配置=${USQUE_CONFIG}"
}


# Best-effort license bind (WARP+). Failures are non-fatal.
maybe_apply_warp_license() {
    [ -n "$WARP_LICENSE" ] || return 0
    command_exists usque || return 0

    log "尝试绑定 WARP+ license..."
    # usque CLI evolves; try a few known shapes, never abort the proxy.
    if usque -c "$USQUE_CONFIG" license "$WARP_LICENSE" >/dev/null 2>&1; then
        log "WARP+ license 已应用 (license 子命令)"
        return 0
    fi
    if usque -c "$USQUE_CONFIG" account license "$WARP_LICENSE" >/dev/null 2>&1; then
        log "WARP+ license 已应用 (account license)"
        return 0
    fi
    # Some builds expose --license on register/enroll only; document for re-register.
    warn "当前 usque 构建可能不支持运行时 license 绑定；若需 WARP+ 请查阅 usque 文档或重新注册"
}

start_masque_socks() {
    local proxy_mode masque_dns_servers dns_server usque_pid usque_status
    local -a masque_dns_list
    command_exists usque || die "镜像内未找到 usque"

    proxy_mode="$(normalize_masque_proxy_mode "$MASQUE_PROXY_MODE")"
    log "协议: MASQUE (usque)  代理模式: ${proxy_mode}"

    # Soft-cap Go heap on small hosts (no effect if runtime ignores it)
    if [ -n "${GOMEMLIMIT:-}" ]; then
        export GOMEMLIMIT
        log "GOMEMLIMIT=${GOMEMLIMIT}"
    fi

    # Global -c must precede subcommand
    set -- usque -c "$USQUE_CONFIG" "$proxy_mode" -b "$LISTEN_ADDR" -p "$LISTEN_PORT"

    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        ok "代理认证已启用"
        set -- "$@" -u "$SOCKS_USER" -w "$SOCKS_PASS"
    elif [ "${INTERNAL_PROXY:-0}" = "1" ]; then
        log "内部 SOCKS 后端不启用认证（认证由公开 Mixed/LB 入口统一处理）"
    else
        log "未启用代理认证（公开访问模式）"
    fi

    # HTTP/2 (TCP:443) fallback — only on full socks / modes that support it.
    # L4 modes currently do not support --http2 (usque limitation).
    if is_truthy "$MASQUE_HTTP2"; then
        if [ "$proxy_mode" = "l4-socks" ]; then
            warn "MASQUE_HTTP2=1 但 l4-socks 不支持 --http2；请改 MASQUE_PROXY_MODE=socks，或关闭 HTTP2"
        else
            log "启用 MASQUE HTTP/2 (TCP) 回退"
            set -- "$@" --http2
        fi
    fi

    # SNI override (full socks); L4 rejects custom SNI on CF side
    if [ -n "$MASQUE_SNI" ]; then
        if [ "$proxy_mode" = "l4-socks" ]; then
            warn "MASQUE_SNI 在 l4-socks 下无效，已忽略"
        else
            log "MASQUE SNI=${MASQUE_SNI}"
            set -- "$@" -s "$MASQUE_SNI"
        fi
    fi

    if [ -n "$MASQUE_MTU" ]; then
        if [ "$proxy_mode" = "l4-socks" ]; then
            warn "MASQUE_MTU 在 l4-socks 下无效，已忽略"
        else
            set -- "$@" -m "$MASQUE_MTU"
        fi
    fi

    # usque 默认 DNS 列表包含 IPv6 地址。即使关闭隧道 IPv6，默认 SOCKS
    # 域名请求仍可能优先向 IPv6 DNS 发包而立即失败；显式改为 IPv4 DNS。
    masque_dns_servers="$MASQUE_DNS_SERVERS"
    if [ -z "$masque_dns_servers" ] && ! is_truthy "$ENABLE_IPV6"; then
        masque_dns_servers="1.1.1.1,1.0.0.1"
    fi
    if [ -n "$masque_dns_servers" ]; then
        IFS=',' read -r -a masque_dns_list <<< "$masque_dns_servers"
        for dns_server in "${masque_dns_list[@]}"; do
            dns_server="${dns_server//[[:space:]]/}"
            [ -n "$dns_server" ] && set -- "$@" --dns "$dns_server"
        done
        log "MASQUE DNS=${masque_dns_servers}"
    fi

    # Optional IPv4/IPv6 tunnel toggles via usque flags when full socks
    if [ "$proxy_mode" = "socks" ]; then
        if ! is_truthy "$ENABLE_IPV6"; then
            # usque socks: -S often means IPv6 off / family select — keep portable:
            # Prefer documented no-tunnel-ipv6 style if present; otherwise leave default.
            if usque socks --help 2>&1 | grep -q 'no-tunnel-ipv6'; then
                set -- "$@" --no-tunnel-ipv6
            fi
        fi
    fi

    ok "usque 已监听 | 模式=${proxy_mode} | 地址=${LISTEN_ADDR}:${LISTEN_PORT}"
    if is_truthy "$MASQUE_HTTP2" && [ "$proxy_mode" = "socks" ]; then
        log "   流量经 Cloudflare MASQUE (HTTP/2 TCP :443)"
    else
        log "   流量经 Cloudflare MASQUE (HTTP/3 QUIC :443)"
    fi
    # TCP-only 上游分支额外持有本地 SOCKS5 relay。不能 exec 覆盖当前 shell，
    # 否则 relay 无法随 usque 一起收到停止信号并被回收。
    if [ -n "${STANDARD_TCP_SOCKS5_PROXY_URI:-}" ]; then
        "$@" &
        usque_pid=$!
        trap 'kill "$usque_pid" 2>/dev/null || true; stop_standard_tcp_socks5_relay' EXIT INT TERM
        if wait "$usque_pid"; then
            usque_status=0
        else
            usque_status=$?
        fi
        trap - EXIT INT TERM
        stop_standard_tcp_socks5_relay
        return "$usque_status"
    fi
    exec "$@"

}

maybe_start_upstream() {
    local transport
    [ -n "${UPSTREAM_SOCKS5:-}" ] || return 0
    transport="$(normalize_upstream_socks5_transport "$UPSTREAM_SOCKS5_TRANSPORT")"
    export INSTANCE_ID="${INSTANCE_ID:-0}"
    export INSTANCE_RUNTIME_DIR="${INSTANCE_RUNTIME_DIR:-${MICROWARP_RUNTIME_ROOT}/instances/${INSTANCE_ID}}"
    mkdir -p "$INSTANCE_RUNTIME_DIR"
    case "$transport" in
        tcp)
            if start_standard_tcp_socks5_proxy; then
                return 0
            fi
            # 参数组合错误时不能悄悄直连，否则会把“必须经过 TCP 上游”的
            # 显式配置降级为真实出口直连。
            if ! tcp_socks5_transport_is_compatible; then
                die "标准 TCP SOCKS5 上游与当前隧道模式不兼容"
            fi
            if is_truthy "$UPSTREAM_REQUIRED"; then
                die "标准 TCP SOCKS5 上游启动失败，已按 UPSTREAM_REQUIRED=1 阻止直连回退；请检查 SOCKS5 CONNECT 与 HTTPS_PROXY 支持"
            fi
            clear_standard_tcp_socks5_proxy
            warn "标准 TCP SOCKS5 上游启动失败，按 UPSTREAM_REQUIRED=0 继续直连"
            ;;
        tun)
            [ -x /app/upstream-setup.sh ] || die "镜像内缺少 upstream-setup.sh"
            step "启用上游 SOCKS5 TUN（WARP 注册与外层连接经此代理）"
            if /app/upstream-setup.sh start "$INSTANCE_ID"; then
                return 0
            fi
            if is_truthy "$UPSTREAM_REQUIRED"; then
                die "上游 SOCKS5 TUN 启动失败，已按 UPSTREAM_REQUIRED=1 阻止直连回退；请检查 UDP relay，若 UPSTREAM_SOCKS5_UDP_MODE=tcp 则上游必须支持 UDP-in-TCP"
            fi
            warn "上游 SOCKS5 TUN 启动失败，按 UPSTREAM_REQUIRED=0 继续直连"
            ;;
        *) die "内部错误：未处理的上游传输模式 ${transport}" ;;
    esac
}

run_wireguard_path() {
    step "使用 WireGuard 内核隧道（轻量路径）"

    mkdir -p "$WG_DIR"
    # 必须在切换到上游 TUN 前记录真实回程，避免发布端口响应走入 WARP。
    capture_pre_warp_routes
    maybe_start_upstream

    if [ ! -f "$WG_CONF" ]; then
        register_warp
    else
        ok "检测到持久化 WireGuard 身份，跳过注册"
    fi

    sanitize_config
    patch_wg_quick
    bring_up_wg
    install_policy_routes
    if [ -n "${UPSTREAM_SOCKS5:-}" ] && [ "$(normalize_upstream_socks5_transport "$UPSTREAM_SOCKS5_TRANSPORT")" = tun ]; then
        /app/upstream-setup.sh pin "${INSTANCE_ID:-0}" >/dev/null 2>&1 || true
    fi

    # 代理先就绪，出口探测只作日志用途。
    show_egress_ip &
    start_socks
}

run_masque_path() {
    step "使用 MASQUE 用户态隧道（适用于 WireGuard UDP 被 QoS/阻断）"
    warn "MASQUE 为用户态 QUIC，内存远高于内核 WireGuard（建议 GOMEMLIMIT，默认可 512MiB）"

    conf_dir="$(dirname "$USQUE_CONFIG")"
    mkdir -p "$conf_dir"
    maybe_start_upstream

    register_masque
    maybe_apply_warp_license
    prepare_standard_tcp_socks5_relay
    start_masque_socks
}

# ==========================================
# 单实例工作进程
# ==========================================
run_instance_main() {
    INSTANCE_ID="${INSTANCE_ID:-0}"
    RESOLVE_PREFERENCE="$(normalize_resolve_preference "$RESOLVE_PREFERENCE")"
    # 直接单实例路径也要把标准化后的值传给 microsocks 进程。
    export RESOLVE_PREFERENCE
    proto="$(normalize_tunnel_protocol "$TUNNEL_PROTOCOL")"
    mw_section "实例:${INSTANCE_ID}" "实例初始化"
    step "启动实例 | 隧道=${proto} | 监听=${LISTEN_ADDR}:${LISTEN_PORT}"

    case "$proto" in
        wireguard) run_wireguard_path ;;
        masque)    run_masque_path ;;
        *)         die "内部错误: 未处理的协议 $proto" ;;
    esac
}

# ==========================================
# 单容器控制面
# ==========================================
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ALL_BACKENDS_FILE="${ALL_BACKENDS_FILE:-${MICROWARP_RUNTIME_ROOT}/backends-all.txt}"
LB_BACKENDS_FILE="${LB_BACKENDS_FILE:-${MICROWARP_RUNTIME_ROOT}/backends.txt}"
BACKENDS_META_FILE="${BACKENDS_META_FILE:-${MICROWARP_RUNTIME_ROOT}/backends.meta}"
LB_CONNECTION_STATE_FILE="${LB_CONNECTION_STATE_FILE:-${MICROWARP_RUNTIME_ROOT}/lb-connections.txt}"

normalize_instance_count() {
    # 实例地址使用 10.64.<实例 ID>.x，第三个 IPv4 八位组最多为 255。
    # 因此将实例数量限制为 1~255（实例 ID 0~254），其余限制由宿主机资源决定。
    if ! [[ "$INSTANCE_COUNT" =~ ^[0-9]+$ ]] || [ "$INSTANCE_COUNT" -lt 1 ]; then
        warn "INSTANCE_COUNT=${INSTANCE_COUNT} 非法，回退为 1"
        INSTANCE_COUNT=1
    fi
    if [ "$INSTANCE_COUNT" -gt 255 ]; then
        warn "INSTANCE_COUNT 超过 255，限制为 255"
        INSTANCE_COUNT=255
    fi
}

normalize_proxy_mode() {
    PROXY_MODE="$(printf '%s' "$PROXY_MODE" | tr '[:upper:]' '[:lower:]')"
    case "$PROXY_MODE" in
        socks5|socks) PROXY_MODE=socks5 ;;
        mixed|http) PROXY_MODE=mixed ;;
        *) die "未知 PROXY_MODE=${PROXY_MODE}（支持 socks5 | mixed）" ;;
    esac
}

lb_should_run() {
    management_ui_enabled && return 0
    case "$(printf '%s' "$LB_ENABLED" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        0|false|no|off) [ "$INSTANCE_COUNT" -gt 1 ] && die "多实例必须启用内置 LB，实例不会暴露直连端口"; return 1 ;;
        *) [ "$INSTANCE_COUNT" -gt 1 ] || [ "$PROXY_MODE" = mixed ] ;;
    esac
}

control_plane_should_run() {
    management_ui_enabled && return 0
    case "$(printf '%s' "$CONTROL_PLANE_ENABLED" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        0|false|no|off) return 1 ;;
        *)
            [ "$INSTANCE_COUNT" -gt 1 ] || [ "$PROXY_MODE" = mixed ] ||
                [[ "$(printf '%s' "$LB_ENABLED" | tr '[:upper:]' '[:lower:]')" =~ ^(1|true|yes|on)$ ]]
            ;;
    esac
}

management_ui_enabled() {
    case "$(printf '%s' "$MANAGEMENT_UI_ENABLED" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

instance_runtime_dir() { printf '%s/instances/%s' "$MICROWARP_RUNTIME_ROOT" "$1"; }
instance_pid_file() { printf '%s/worker.pid' "$(instance_runtime_dir "$1")"; }
instance_started_at_file() { printf '%s/worker.started_at' "$(instance_runtime_dir "$1")"; }
instance_disabled_file() { printf '%s/manual.disabled' "$(instance_runtime_dir "$1")"; }
instance_management_lock_dir() { printf '%s/management.lock' "$(instance_runtime_dir "$1")"; }
instance_management_state_file() { printf '%s/management.state' "$(instance_runtime_dir "$1")"; }
instance_netns() { printf 'microwarp%s' "$1"; }
instance_host_veth() { printf 'mwh%s' "$1"; }
instance_ns_veth() { printf 'mwn%s' "$1"; }
instance_host_ip() { printf '10.64.%s.1' "$1"; }
instance_ns_ip() { printf '10.64.%s.2' "$1"; }
instance_backend_addr() {
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        printf '%s:1080' "$(instance_ns_ip "$1")"
    else
        printf '127.0.0.1:%s' "$INTERNAL_PROXY_PORT"
    fi
}

# 返回当前容器生命周期内的实例 ID。动态实例写入运行时文件，容器重启时
# supervisor 会清空该文件，因此临时实例不会跨重启保留。
runtime_instance_ids() {
    local id
    seq 0 $((INSTANCE_COUNT - 1))
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [ "$id" -ge "$INSTANCE_COUNT" ] && printf '%s\n' "$id"
    done < "${MICROWARP_DYNAMIC_INSTANCES_FILE}" 2>/dev/null | sort -n -u
}

# 除基础实例外，当前运行期由管理面添加的实例同样是有效生命周期目标。
# 此函数供管理控制脚本复用，避免动态实例无法执行启用、重连或摘流操作。
runtime_instance_exists() {
    local target="$1" id
    [[ "$target" =~ ^[0-9]+$ ]] || return 1
    while read -r id; do
        [[ "$id" = "$target" ]] && return 0
    done < <(runtime_instance_ids)
    return 1
}

runtime_instance_count() {
    runtime_instance_ids | awk 'END { print (NR ? $1 + 1 : 1) }'
}
instance_wg_conf() {
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        printf '/etc/wireguard/instances/%s/wg0.conf' "$1"
    else
        printf '%s' "$WG_CONF"
    fi
}
instance_usque_config() {
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        printf '/etc/wireguard/instances/%s/masque-config.json' "$1"
    else
        printf '%s' "$USQUE_CONFIG"
    fi
}

prepare_netns() {
    local id="$1" ns host_veth ns_veth host_ip ns_ip cidr
    ns="$(instance_netns "$id")"
    host_veth="$(instance_host_veth "$id")"
    ns_veth="$(instance_ns_veth "$id")"
    host_ip="$(instance_host_ip "$id")"
    ns_ip="$(instance_ns_ip "$id")"
    cidr="10.64.${id}.0/30"

    ip netns del "$ns" 2>/dev/null || true
    ip link del "$host_veth" 2>/dev/null || true
    ip netns add "$ns"
    if ! netns_write_resolv_conf "$ns"; then
        die "无法写入网络命名空间 DNS 配置 | 名称=${ns} | NETNS_DNS_SERVERS=${NETNS_DNS_SERVERS}"
    fi
    mw_info "实例:${id}" "命名空间 DNS 已配置 | 服务器=${NETNS_DNS_SERVERS}"
    ip link add "$host_veth" type veth peer name "$ns_veth"
    ip link set "$ns_veth" netns "$ns"
    ip addr add "${host_ip}/30" dev "$host_veth"
    ip link set "$host_veth" up
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip addr add "${ns_ip}/30" dev "$ns_veth"
    ip netns exec "$ns" ip link set "$ns_veth" up
    ip netns exec "$ns" ip route replace default via "$host_ip"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if ! iptables -t nat -C POSTROUTING -s "$cidr" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$cidr" -j MASQUERADE
    fi
    mw_ok "实例:${id}" "网络命名空间已就绪 | VETH=${host_ip} ↔ ${ns_ip}"
}

remove_netns() {
    local id="$1" ns host_veth cidr
    ns="$(instance_netns "$id")"
    host_veth="$(instance_host_veth "$id")"
    cidr="10.64.${id}.0/30"
    while iptables -t nat -C POSTROUTING -s "$cidr" -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -s "$cidr" -j MASQUERADE 2>/dev/null || true
    done
    ip netns del "$ns" 2>/dev/null || true
    ip link del "$host_veth" 2>/dev/null || true
    netns_remove_resolv_conf "$ns"
}

export_control_environment() {
    export INSTANCE_COUNT INSTANCE_START_STAGGER PROXY_MODE BIND_ADDR BIND_PORT ENABLE_IPV6 LB_STRATEGY LB_STICKY_MODE LB_ROTATE_INTERVAL
    export LB_MAX_CONN LB_IDLE_TIMEOUT LB_HANDSHAKE_TIMEOUT LB_ACCESS_LOG LB_ACCESS_LOG_HEADERS
    export LB_ACCESS_LOG_HEADER_MAX_CHARS MANAGEMENT_UI_ENABLED MANAGEMENT_ACTION_PROBE_TIMEOUT INTERNAL_PROXY_PORT
    export MICROWARP_RUNTIME_ROOT ALL_BACKENDS_FILE LB_BACKENDS_FILE BACKENDS_META_FILE
    export LB_CONNECTION_STATE_FILE SOCKS_USER SOCKS_PASS HEALTH_CHECK_INTERVAL
    export HEALTH_PROBE_TIMEOUT HEALTH_PROBE_CONCURRENCY HEALTH_SOFT_FAILURES HEALTH_START_PERIOD HEALTH_STARTUP_RETRY_INTERVAL STATUS_EVENT_LOG CONTROL_PLANE_ENABLED ROTATE_RESTART_ENABLED
    export ROTATE_RESTART_INTERVAL ROTATE_RESTART_PROBE_TIMEOUT ROTATE_RESTART_RETRIES
    export ROTATE_RESTART_CONCURRENCY ROTATE_RESTART_DEFERRED_CHECK_INTERVAL ROTATE_RESTART_HISTORY_LIMIT RESOLVE_PREFERENCE UPSTREAM_SOCKS5
    export UPSTREAM_SOCKS5_UDP_MODE UPSTREAM_SOCKS5_TRANSPORT UPSTREAM_MTU UPSTREAM_VERIFY UPSTREAM_PROBE_TIMEOUT UPSTREAM_REQUIRED
    export NETNS_DNS_SERVERS MICROWARP_LOG_FILE MICROWARP_DYNAMIC_INSTANCES_FILE
}

start_instance() {
    local id="$1" runtime conf masque bind_addr bind_port internal
    runtime="$(instance_runtime_dir "$id")"
    conf="$(instance_wg_conf "$id")"
    masque="$(instance_usque_config "$id")"
    mkdir -p "$runtime" "$(dirname "$conf")" "$(dirname "$masque")"

    internal=0
    if [ "${LB_ACTIVE:-0}" = 1 ]; then
        internal=1
        if [ "$INSTANCE_COUNT" -eq 1 ]; then
            bind_addr=127.0.0.1
            bind_port="$INTERNAL_PROXY_PORT"
        else
            bind_addr=0.0.0.0
            bind_port=1080
        fi
    else
        bind_addr="$BIND_ADDR"
        bind_port="$BIND_PORT"
    fi

    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        prepare_netns "$id"
        ip netns exec "$(instance_netns "$id")" env \
            INSTANCE_ID="$id" INSTANCE_RUNTIME_DIR="$runtime" MULTI_INSTANCE=1 \
            WG_CONF="$conf" WG_IFACE=wg0 USQUE_CONFIG="$masque" \
            BIND_ADDR="$bind_addr" BIND_PORT="$bind_port" INTERNAL_PROXY="$internal" \
            SOCKS_USER= SOCKS_PASS= PROXY_USER= PROXY_PASS= \
            RESOLVE_PREFERENCE="$RESOLVE_PREFERENCE" \
            "$SELF_PATH" --instance "$id" &
    else
        if [ "$internal" = 1 ]; then
            env INSTANCE_ID="$id" INSTANCE_RUNTIME_DIR="$runtime" MULTI_INSTANCE=0 \
                WG_CONF="$conf" WG_IFACE=wg0 USQUE_CONFIG="$masque" \
                BIND_ADDR="$bind_addr" BIND_PORT="$bind_port" INTERNAL_PROXY=1 \
                SOCKS_USER= SOCKS_PASS= PROXY_USER= PROXY_PASS= \
                RESOLVE_PREFERENCE="$RESOLVE_PREFERENCE" \
                "$SELF_PATH" --instance "$id" &
        else
            env INSTANCE_ID="$id" INSTANCE_RUNTIME_DIR="$runtime" MULTI_INSTANCE=0 \
                WG_CONF="$conf" WG_IFACE=wg0 USQUE_CONFIG="$masque" \
                BIND_ADDR="$bind_addr" BIND_PORT="$bind_port" \
                RESOLVE_PREFERENCE="$RESOLVE_PREFERENCE" \
                "$SELF_PATH" --instance "$id" &
        fi
    fi
    echo $! > "$(instance_pid_file "$id")"
    date +%s > "$(instance_started_at_file "$id")"
    mw_step "实例:${id}" "工作进程已启动 | 内部监听=${bind_addr}:${bind_port}"
}

stop_instance() {
    local id="$1" pid runtime conf
    runtime="$(instance_runtime_dir "$id")"
    conf="$(instance_wg_conf "$id")"
    if [ -f "$(instance_pid_file "$id")" ]; then
        pid="$(cat "$(instance_pid_file "$id")" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        sleep 0.3
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
        rm -f "$(instance_pid_file "$id")"
    fi
    rm -f "$(instance_started_at_file "$id")"
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        ip netns pids "$(instance_netns "$id")" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
        remove_netns "$id"
    else
        wg-quick down "$conf" >/dev/null 2>&1 || true
        env INSTANCE_ID="$id" INSTANCE_RUNTIME_DIR="$runtime" UPSTREAM_SOCKS5="$UPSTREAM_SOCKS5" UPSTREAM_SOCKS5_UDP_MODE="$UPSTREAM_SOCKS5_UDP_MODE" UPSTREAM_VERIFY="$UPSTREAM_VERIFY" UPSTREAM_PROBE_TIMEOUT="$UPSTREAM_PROBE_TIMEOUT" \
            /app/upstream-setup.sh stop "$id" >/dev/null 2>&1 || true
    fi
    mw_ok "实例:${id}" "已停止"
}

write_all_backends() {
    local id temporary
    mkdir -p "$MICROWARP_RUNTIME_ROOT"
    temporary="${ALL_BACKENDS_FILE}.$$"
    : > "$temporary"
    for id in $(runtime_instance_ids); do
        instance_backend_addr "$id" >> "$temporary"
    done
    mv "$temporary" "$ALL_BACKENDS_FILE"
}

start_lb() {
    [ "${LB_ACTIVE:-0}" = 1 ] || return 0
    if [ -f "${MICROWARP_RUNTIME_ROOT}/lb.pid" ] && kill -0 "$(cat "${MICROWARP_RUNTIME_ROOT}/lb.pid")" 2>/dev/null; then
        return 0
    fi
    export_control_environment
    python3 /app/lb-proxy.py &
    echo $! > "${MICROWARP_RUNTIME_ROOT}/lb.pid"
    mw_ok "LB" "公开入口已监听 | 地址=${BIND_ADDR}:${BIND_PORT} | 模式=${PROXY_MODE}"
}

stop_lb() {
    local pid
    if [ -f "${MICROWARP_RUNTIME_ROOT}/lb.pid" ]; then
        pid="$(cat "${MICROWARP_RUNTIME_ROOT}/lb.pid" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "${MICROWARP_RUNTIME_ROOT}/lb.pid"
    fi
}

start_health_daemon() {
    export_control_environment
    export LB_ACTIVE
    /app/health-check.sh daemon &
    echo $! > "${MICROWARP_RUNTIME_ROOT}/health.pid"
}

start_rotate_daemon() {
    [ "$INSTANCE_COUNT" -gt 1 ] || return 0
    export_control_environment
    /app/rotate-restart.sh daemon &
    echo $! > "${MICROWARP_RUNTIME_ROOT}/rotate.pid"
}

manage_command() {
    local action="${1:-status}" id="${2:-0}"
    normalize_instance_count
    normalize_proxy_mode
    if lb_should_run; then LB_ACTIVE=1; else LB_ACTIVE=0; fi
    case "$action" in
        start) start_instance "$id" ;;
        stop) stop_instance "$id" ;;
        restart)
            mkdir -p "$(instance_runtime_dir "$id")"
            : > "$(instance_runtime_dir "$id")/restarting"
            stop_instance "$id"
            start_instance "$id"
            rm -f "$(instance_runtime_dir "$id")/restarting"
            ;;
        status)
            local current pid state
            echo "instances=${INSTANCE_COUNT} mode=${PROXY_MODE} lb_active=${LB_ACTIVE} bind_port=${BIND_PORT}"
            for current in $(seq 0 $((INSTANCE_COUNT - 1))); do
                pid="$(cat "$(instance_pid_file "$current")" 2>/dev/null || true)"
                state="$(cat "$(instance_runtime_dir "$current")/health.state" 2>/dev/null || echo waiting)"
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    echo "instance-${current} process=up ${state}"
                else
                    echo "instance-${current} process=down ${state}"
                fi
            done
            ;;
        *) echo "用法: $0 --manage {start|stop|restart|status} [实例ID]"; return 1 ;;
    esac
}

cleanup_supervisor() {
    local id pid_file pid
    mw_warn "控制面" "收到退出信号，开始停止控制面与全部实例"
    for pid_file in "${MICROWARP_RUNTIME_ROOT}"/{health,rotate}.pid; do
        [ -f "$pid_file" ] || continue
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    stop_lb
    for id in $(runtime_instance_ids); do stop_instance "$id"; done
    exit 0
}

monitor_instances() {
    local id pid rotating disabled management_lock
    while true; do
        for id in $(runtime_instance_ids); do
            disabled="$(instance_disabled_file "$id")"
            management_lock="$(instance_management_lock_dir "$id")"
            [ -f "$disabled" ] && continue
            [ -d "$management_lock" ] && continue
            rotating="$(instance_runtime_dir "$id")/rotating"
            [ -f "$rotating" ] && continue
            rotating="$(instance_runtime_dir "$id")/restarting"
            [ -f "$rotating" ] && continue
            pid="$(cat "$(instance_pid_file "$id")" 2>/dev/null || true)"
            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                mw_warn "实例:${id}" "工作进程已退出，准备重启"
                stop_instance "$id" || true
                start_instance "$id" || true
            fi
        done
        if [ "${LB_ACTIVE:-0}" = 1 ]; then
            pid="$(cat "${MICROWARP_RUNTIME_ROOT}/lb.pid" 2>/dev/null || true)"
            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                mw_warn "LB" "前端进程已退出，准备重启"
                start_lb
            fi
        fi
        sleep 5
    done
}

supervisor_main() {
    normalize_instance_count
    normalize_proxy_mode
    RESOLVE_PREFERENCE="$(normalize_resolve_preference "$RESOLVE_PREFERENCE")"
    mkdir -p "$MICROWARP_RUNTIME_ROOT"
    # 动态实例仅存在于当前容器生命周期。
    : > "$MICROWARP_DYNAMIC_INSTANCES_FILE"
    : > "$MICROWARP_LOG_FILE"
    if lb_should_run; then LB_ACTIVE=1; else LB_ACTIVE=0; fi
    export_control_environment
    export LB_ACTIVE

    mw_section "控制面" "启动配置"
    mw_info "控制面" "入口 | 地址=${BIND_ADDR}:${BIND_PORT} | 代理模式=${PROXY_MODE} | LB=${LB_ACTIVE}"
    mw_info "控制面" "实例 | 数量=${INSTANCE_COUNT} | 启动错峰=${INSTANCE_START_STAGGER}s | 策略=${LB_STRATEGY} | 粘性=${LB_STICKY_MODE}"
    mw_info "控制面" "域名解析 | WireGuard=${RESOLVE_PREFERENCE}"
    if management_ui_enabled; then
        mw_warn "控制面" "管理面板 | 已匿名启用 | 地址=http://${BIND_ADDR}:${BIND_PORT}/__microwarp/"
    fi
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
        mw_info "控制面" "认证 | 公开 Mixed/LB 入口=已启用 | 内部后端=无认证"
    elif [[ "$LB_STICKY_MODE" =~ ^(username-round|username-hash)$ ]]; then
        mw_info "控制面" "认证 | 固定认证=未启用；用户名粘性仅在客户端提供用户名时生效，匿名请求按 LB 策略分发"
    else
        mw_info "控制面" "认证 | 公开 Mixed/LB 入口=未启用"
    fi
    mw_info "控制面" "健康检查 | 间隔=${HEALTH_CHECK_INTERVAL}s | 启动探测=${HEALTH_STARTUP_RETRY_INTERVAL}s | HTTP并发=${HEALTH_PROBE_CONCURRENCY} | 宽限=${HEALTH_START_PERIOD}s"
    if [ -n "${UPSTREAM_SOCKS5:-}" ]; then
        mw_info "控制面" "上游 SOCKS5 | 地址=$(mw_redact_uri "$UPSTREAM_SOCKS5") | 传输=$(normalize_upstream_socks5_transport "$UPSTREAM_SOCKS5_TRANSPORT") | UDP模式=${UPSTREAM_SOCKS5_UDP_MODE} | 严格=${UPSTREAM_REQUIRED}"
    else
        mw_info "控制面" "上游 SOCKS5 | 未配置（WARP 外层连接直连）"
    fi
    if [ "$INSTANCE_COUNT" -gt 1 ]; then
        mw_info "控制面" "多实例只使用上述唯一公开入口；实例后端不会暴露端口"
    fi
    if [ "$LB_ACTIVE" = 1 ] && [ -n "$SOCKS_USER" ] && [ -z "$SOCKS_PASS" ]; then
        die "SOCKS_USER/SOCKS_PASS 必须同时设置"
    fi
    if [ "$LB_ACTIVE" = 1 ] && [ -n "$SOCKS_PASS" ] && [ -z "$SOCKS_USER" ]; then
        die "SOCKS_USER/SOCKS_PASS 必须同时设置"
    fi

    local id
    for id in $(runtime_instance_ids); do
        # 管理面板的手工停用状态只属于当前容器运行期；重启容器时自动恢复启用。
        rm -f "$(instance_disabled_file "$id")" "$(instance_management_state_file "$id")"
        rm -rf "$(instance_management_lock_dir "$id")"
        start_instance "$id"
        # 短暂错峰可平滑首次注册压力；默认 0.2 秒显著缩短多实例启动时间。
        [ "$INSTANCE_COUNT" -gt 1 ] && [ "$INSTANCE_START_STAGGER" != 0 ] && sleep "$INSTANCE_START_STAGGER"
    done
    write_all_backends
    : > "$LB_BACKENDS_FILE"
    : > "$BACKENDS_META_FILE"
    start_lb
    start_health_daemon
    start_rotate_daemon
    mw_ok "控制面" "全部服务已拉起，等待健康探测将可用实例加入后端池"

    trap cleanup_supervisor SIGTERM SIGINT
    monitor_instances
}

# 供 shell 单元测试加载函数；正常容器启动不会设置该变量。
if [ "${MICROWARP_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
elif [ "${1:-}" = "--instance" ]; then
    shift
    run_instance_main "$@"
elif [ "${1:-}" = "--manage" ]; then
    shift
    manage_command "$@"
else
    normalize_instance_count
    normalize_proxy_mode
    if control_plane_should_run; then
        supervisor_main "$@"
    else
        log "默认轻量模式：单实例 microsocks，不启动常驻控制面"
        run_instance_main "$@"
    fi
fi
