#!/usr/bin/env bash
# 验证控制台日志的统一前缀、级别和上游 URI 脱敏规则。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../log-utils.sh
source "${ROOT}/log-utils.sh"

assert_eq() {
    local actual="$1" expected="$2" context="$3"
    if [ "$actual" != "$expected" ]; then
        printf '断言失败：%s\n期望：%s\n实际：%s\n' "$context" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_eq \
    "$(mw_info '控制面' '入口 | 地址=0.0.0.0:1080')" \
    '[MicroWARP][控制面][INFO] ℹ 入口 | 地址=0.0.0.0:1080' \
    'INFO 格式'
assert_eq \
    "$(mw_warn '上游:0' 'UDP 连通性探测失败' 2>&1 >/dev/null)" \
    '[MicroWARP][上游:0][WARN] ⚠ UDP 连通性探测失败' \
    'WARN 格式'
assert_eq \
    "$(mw_error '实例:2' '启动失败' 2>&1 >/dev/null)" \
    '[MicroWARP][实例:2][ERROR] ✗ 启动失败' \
    'ERROR 格式'
assert_eq \
    "$(mw_redact_uri 'socks5://alice:secret@192.168.1.2:1085')" \
    'socks5://***@192.168.1.2:1085' \
    '上游 SOCKS5 URI 脱敏'
assert_eq \
    "$(mw_redact_uri 'socks5://192.168.1.2:1085')" \
    'socks5://192.168.1.2:1085' \
    '无凭据上游地址'
assert_eq "$(mw_redact_uri '')" '(未配置)' '空上游地址'
printf '日志工具测试通过\n'
