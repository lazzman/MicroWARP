#!/usr/bin/env bash
# 验证标准 TCP SOCKS5 上游的模式判定与 URI 规范化。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MICROWARP_LIB_ONLY=1
export TUNNEL_PROTOCOL=masque
export MASQUE_PROXY_MODE=socks
export MASQUE_HTTP2=1
export UPSTREAM_SOCKS5_TRANSPORT=tcp
export UPSTREAM_SOCKS5='socks5h://user:pass@127.0.0.1:1085'
export UPSTREAM_PROBE_TIMEOUT=1
export UPSTREAM_VERIFY=1

# shellcheck source=../entrypoint.sh
source "${ROOT}/entrypoint.sh"

assert_equals() {
    local title="$1" actual="$2" expected="$3"
    [[ "$actual" = "$expected" ]] || {
        printf '断言失败：%s\n期望：%s\n实际：%s\n' "$title" "$expected" "$actual" >&2
        exit 1
    }
}

assert_true() {
    local title="$1"
    shift
    "$@" || {
        printf '断言失败：%s\n' "$title" >&2
        exit 1
    }
}

assert_false() {
    local title="$1"
    shift
    if "$@"; then
        printf '断言失败：%s\n' "$title" >&2
        exit 1
    fi
}

assert_equals '标准传输模式' "$(normalize_upstream_socks5_transport tun)" 'tun'
assert_equals 'TCP 传输模式别名' "$(normalize_upstream_socks5_transport tcp-proxy)" 'tcp'
assert_equals '无 scheme 地址' "$(normalize_standard_socks5_uri '127.0.0.1:1080')" 'socks5://127.0.0.1:1080'
assert_equals 'socks5h 地址' "$(normalize_standard_socks5_uri 'socks5h://user:pass@proxy.example:1080')" 'socks5://user:pass@proxy.example:1080'
assert_equals 'socks 地址' "$(normalize_standard_socks5_uri 'socks://proxy.example:1080')" 'socks5://proxy.example:1080'

assert_true 'MASQUE socks + HTTP/2 允许标准 TCP SOCKS5' tcp_socks5_transport_is_compatible

# 以 shell 函数替代 curl，验证 TCP 专用分支只做 SOCKS5 CONNECT 的 HTTPS 探测，
# 并会把规范化后的地址交给 usque 所读取的 HTTPS_PROXY 环境变量。
curl() {
    [[ " $* " == *' --proxy socks5://user:pass@127.0.0.1:1085 '* ]] || return 1
    printf 'ip=198.51.100.10\nwarp=off\n'
}
assert_true 'TCP 专用上游启动成功' start_standard_tcp_socks5_proxy
assert_equals 'HTTPS_PROXY 使用标准 socks5 scheme' "$HTTPS_PROXY" 'socks5://user:pass@127.0.0.1:1085'
assert_equals 'https_proxy 使用标准 socks5 scheme' "$https_proxy" 'socks5://user:pass@127.0.0.1:1085'
clear_standard_tcp_socks5_proxy
[[ -z "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]] || {
    echo '清理 TCP 上游代理环境变量失败' >&2
    exit 1
}
unset -f curl

TUNNEL_PROTOCOL=wireguard
assert_false 'WireGuard 不允许标准 TCP SOCKS5' tcp_socks5_transport_is_compatible

TUNNEL_PROTOCOL=masque
MASQUE_PROXY_MODE=l4-socks
assert_false 'MASQUE HTTP/3/QUIC 不允许标准 TCP SOCKS5' tcp_socks5_transport_is_compatible

MASQUE_PROXY_MODE=socks
MASQUE_HTTP2=0
assert_false '未启用 HTTP/2 不允许标准 TCP SOCKS5' tcp_socks5_transport_is_compatible

echo '标准 TCP SOCKS5 上游模式测试通过'
