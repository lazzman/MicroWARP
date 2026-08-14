#!/usr/bin/env bash
# 通过上游 SOCKS5 建立 WARP 外层连接。
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log-utils.sh
source "${APP_DIR}/log-utils.sh"

COMMAND="${1:-status}"
INSTANCE_ID="${2:-${INSTANCE_ID:-0}}"
UPSTREAM_SOCKS5="${UPSTREAM_SOCKS5:-}"
# 上游 SOCKS5 转发 UDP 的方式：udp=标准 UDP Associate，tcp=UDP-in-TCP 扩展。
# 保留旧变量和早期候选名称仅作兼容，新的配置请使用 UPSTREAM_SOCKS5_UDP_MODE。
UPSTREAM_SOCKS5_UDP_MODE="${UPSTREAM_SOCKS5_UDP_MODE:-${UPSTREAM_TRANSPORT:-${UPSTREAM_SOCKS5_UDP:-udp}}}"
UPSTREAM_MTU="${UPSTREAM_MTU:-1280}"
UPSTREAM_VERIFY="${UPSTREAM_VERIFY:-1}"
UPSTREAM_PROBE_TIMEOUT="${UPSTREAM_PROBE_TIMEOUT:-8}"
RUNTIME_DIR="${INSTANCE_RUNTIME_DIR:-/run/microwarp/instances/${INSTANCE_ID}}"
LOG_COMPONENT="上游:${INSTANCE_ID}"

log() { mw_info "$LOG_COMPONENT" "$*"; }
ok() { mw_ok "$LOG_COMPONENT" "$*"; }
step() { mw_step "$LOG_COMPONENT" "$*"; }
warn() { mw_warn "$LOG_COMPONENT" "$*"; }
error() { mw_error "$LOG_COMPONENT" "$*"; }

is_truthy() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

pid_file() { printf '%s/upstream.pid' "$RUNTIME_DIR"; }
meta_file() { printf '%s/upstream.env' "$RUNTIME_DIR"; }
config_file() { printf '%s/upstream-hev.yml' "$RUNTIME_DIR"; }
tun_name() { printf 'ups%s' "$INSTANCE_ID"; }

configured() {
    [[ -n "${UPSTREAM_SOCKS5//[[:space:]]/}" ]]
}

parse_upstream() {
    local raw="$UPSTREAM_SOCKS5" credentials
    raw="${raw#socks5h://}"
    raw="${raw#socks5://}"
    raw="${raw#socks://}"
    UPSTREAM_USER=""
    UPSTREAM_PASS=""
    UPSTREAM_HOST=""
    UPSTREAM_PORT=""

    if [[ "$raw" == *'@'* ]]; then
        credentials="${raw%%@*}"
        raw="${raw#*@}"
        UPSTREAM_USER="${credentials%%:*}"
        if [[ "$credentials" == *:* ]]; then
            UPSTREAM_PASS="${credentials#*:}"
        fi
    fi
    if [[ "$raw" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        UPSTREAM_HOST="${BASH_REMATCH[1]}"
        UPSTREAM_PORT="${BASH_REMATCH[2]}"
    elif [[ "$raw" == *:* ]]; then
        UPSTREAM_HOST="${raw%:*}"
        UPSTREAM_PORT="${raw##*:}"
    else
        error "UPSTREAM_SOCKS5 格式错误 | 期望=socks5://user:pass@host:port"
        return 1
    fi
    [[ "$UPSTREAM_PORT" =~ ^[0-9]+$ ]] && ((UPSTREAM_PORT > 0 && UPSTREAM_PORT < 65536)) || {
        error "上游端口非法 | 端口=${UPSTREAM_PORT:-空}"
        return 1
    }
    [[ -n "$UPSTREAM_HOST" ]] || return 1
}

resolve_host() {
    local host="$1" ip
    if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ || "$host" == *:* ]]; then
        printf '%s\n' "$host"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')"
        if [[ -n "$ip" ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi
    python3 - "$host" <<'PY'
import socket
import sys
for row in socket.getaddrinfo(sys.argv[1], None, socket.AF_UNSPEC, socket.SOCK_STREAM):
    if row[0] == socket.AF_INET:
        print(row[4][0])
        break
else:
    print(socket.getaddrinfo(sys.argv[1], None, socket.AF_UNSPEC, socket.SOCK_STREAM)[0][4][0])
PY
}

capture_original_route() {
    local route
    route="$(ip -4 route show default 2>/dev/null | head -n 1 || true)"
    ORIG_GW="$(awk '{for (i=1; i<=NF; i++) if ($i == "via") {print $(i+1); exit}}' <<<"$route")"
    ORIG_DEV="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<<"$route")"
    [[ -n "$ORIG_GW" && -n "$ORIG_DEV" ]] || {
        error "无法读取原始 IPv4 默认路由，不能安全切换上游 TUN"
        return 1
    }
}

save_meta() {
    mkdir -p "$RUNTIME_DIR"
    cat > "$(meta_file)" <<EOF
NODE_IP=${NODE_IP}
ORIG_GW=${ORIG_GW}
ORIG_DEV=${ORIG_DEV}
UPSTREAM_HOST=${UPSTREAM_HOST}
UPSTREAM_PORT=${UPSTREAM_PORT}
TUN_NAME=$(tun_name)
EOF
}

load_meta() {
    if [[ -f "$(meta_file)" ]]; then
        # shellcheck disable=SC1090
        source "$(meta_file)"
    fi
}

is_running() {
    [[ -f "$(pid_file)" ]] && kill -0 "$(cat "$(pid_file)")" 2>/dev/null
}

pin_route() {
    load_meta
    [[ -n "${NODE_IP:-}" && -n "${ORIG_GW:-}" && -n "${ORIG_DEV:-}" ]] || return 1
    ip route replace "${NODE_IP}/32" via "$ORIG_GW" dev "$ORIG_DEV" 2>/dev/null || true
    log "已固定上游节点回程路由 | 节点=${NODE_IP} | 网关=${ORIG_GW} | 接口=${ORIG_DEV}"
}

# WARP 注册会先进行 DNS 查询，WireGuard / MASQUE 本身也依赖 UDP。
# 仅凭 TUN 接口出现不能证明上游 SOCKS5 的 UDP relay 实际可用，因此在
# 切换默认路由后做一次数值 TCP 与 UDP DNS 探测，失败时立即终止而非卡在注册。
verify_tun_connectivity() {
    local tcp_output
    if ! tcp_output="$(curl -4 -fsS --connect-timeout "$UPSTREAM_PROBE_TIMEOUT" \
        --max-time "$UPSTREAM_PROBE_TIMEOUT" \
        --resolve www.cloudflare.com:443:104.16.124.96 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" \
        || ! grep -q '^ip=' <<<"$tcp_output"; then
        error "TCP 连通性探测失败 | 经上游 TUN 无法访问数值 HTTPS"
        return 1
    fi
    ok "TCP 连通性探测通过"

    if ! python3 - "$UPSTREAM_PROBE_TIMEOUT" <<'PY'
import socket
import struct
import sys

timeout = float(sys.argv[1])
# cloudflare.com A 查询；使用数值 DNS 服务器，避免探测自身依赖本地 DNS。
query = (
    b"\x6a\x2b\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    b"\x0acloudflare\x03com\x00\x00\x01\x00\x01"
)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout)
try:
    sock.sendto(query, ("1.1.1.1", 53))
    response, _ = sock.recvfrom(4096)
except OSError:
    raise SystemExit(1)
finally:
    sock.close()

if len(response) < 12 or response[:2] != query[:2] or response[2] & 0x80 == 0:
    raise SystemExit(1)
PY
    then
        error "UDP 连通性探测失败 | 模式=${UPSTREAM_SOCKS5_UDP_MODE} | SOCKS5 UDP Associate / UDP-in-TCP 未返回有效响应"
        return 1
    fi
    ok "上游 TUN 连通性验证通过 | TCP=通过 | UDP=通过"
}

start() {
    configured || { return 0; }
    command -v hev-socks5-tunnel >/dev/null 2>&1 || {
        error "镜像内未找到 hev-socks5-tunnel"
        return 1
    }
    parse_upstream
    mkdir -p "$RUNTIME_DIR"
    if is_running; then
        pin_route || true
        ok "上游 SOCKS5 TUN 已在运行"
        return 0
    fi

    capture_original_route
    NODE_IP="$(resolve_host "$UPSTREAM_HOST")"
    [[ -n "$NODE_IP" ]] || { error "无法解析上游主机 | 主机=${UPSTREAM_HOST}"; return 1; }
    [[ "$NODE_IP" != *:* ]] || { error "当前上游路由固定仅支持 IPv4 节点 | 节点=${NODE_IP}"; return 1; }
    save_meta

    local tun udp_mode escaped_user escaped_pass
    tun="$(tun_name)"
    case "${UPSTREAM_SOCKS5_UDP_MODE,,}" in
        udp|tcp) udp_mode="${UPSTREAM_SOCKS5_UDP_MODE,,}" ;;
        *) error "UPSTREAM_SOCKS5_UDP_MODE 仅支持 udp 或 tcp"; return 1 ;;
    esac
    ip link del "$tun" 2>/dev/null || true
    escaped_user="${UPSTREAM_USER//\'/\'\'}"
    escaped_pass="${UPSTREAM_PASS//\'/\'\'}"
    cat > "$(config_file)" <<EOF
tunnel:
  name: ${tun}
  mtu: ${UPSTREAM_MTU}
  ipv4: 198.18.${INSTANCE_ID}.1
socks5:
  address: ${NODE_IP}
  port: ${UPSTREAM_PORT}
  udp: '${udp_mode}'
EOF
    if [[ -n "$UPSTREAM_USER" ]]; then
        cat >> "$(config_file)" <<EOF
  username: '${escaped_user}'
  password: '${escaped_pass}'
EOF
    fi

    step "启动 SOCKS5 TUN | 节点=${UPSTREAM_HOST}:${UPSTREAM_PORT} | UDP模式=${udp_mode} | 接口=${tun}"
    hev-socks5-tunnel "$(config_file)" >>"${RUNTIME_DIR}/upstream.log" 2>&1 &
    echo $! > "$(pid_file)"
    for _ in $(seq 1 50); do
        ip link show "$tun" >/dev/null 2>&1 && break
        sleep 0.2
    done
    ip link show "$tun" >/dev/null 2>&1 || {
        error "上游 TUN 未创建 | 诊断日志=${RUNTIME_DIR}/upstream.log"
        return 1
    }
    ip link set "$tun" up 2>/dev/null || true
    pin_route
    ip route replace default dev "$tun"
    if is_truthy "$UPSTREAM_VERIFY" && ! verify_tun_connectivity; then
        warn "上游无法承载 WARP 所需 UDP 流量，已恢复原始路由"
        stop
        return 1
    fi
    ok "上游 SOCKS5 TUN 已就绪 | WARP 注册与外层连接经=${tun}"
}

stop() {
    local tun pid
    tun="$(tun_name)"
    load_meta
    if [[ -f "$(pid_file)" ]]; then
        pid="$(cat "$(pid_file)")"
        kill "$pid" 2>/dev/null || true
        sleep 0.2
        kill -9 "$pid" 2>/dev/null || true
        rm -f "$(pid_file)"
    fi
    ip link del "$tun" 2>/dev/null || true
    if [[ -n "${ORIG_GW:-}" && -n "${ORIG_DEV:-}" ]]; then
        ip route replace default via "$ORIG_GW" dev "$ORIG_DEV" 2>/dev/null || true
    fi
    if [[ -n "${NODE_IP:-}" ]]; then
        ip route del "${NODE_IP}/32" 2>/dev/null || true
    fi
    ok "上游 SOCKS5 TUN 已停止"
}

status() {
    if ! configured; then
        echo "upstream=disabled"
        return 0
    fi
    load_meta
    if is_running; then
        echo "upstream=running host=${UPSTREAM_HOST:-?}:${UPSTREAM_PORT:-?} tun=$(tun_name) node=${NODE_IP:-?}"
    else
        echo "upstream=stopped host=${UPSTREAM_HOST:-?}:${UPSTREAM_PORT:-?}"
        return 1
    fi
}

case "$COMMAND" in
    start) start ;;
    stop) stop ;;
    pin) pin_route ;;
    status) status ;;
    *) echo "用法: $0 {start|stop|pin|status} [实例ID]"; exit 1 ;;
esac
