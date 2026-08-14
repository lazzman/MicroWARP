#!/usr/bin/env bash
# 验证域名解析偏好四种正式模式、旧值兼容与 MicroSOCKS 补丁关键语义。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MICROWARP_LIB_ONLY=1
# shellcheck source=../entrypoint.sh
source "${ROOT}/entrypoint.sh"

assert_eq() {
    local actual="$1" expected="$2" title="$3"
    [[ "$actual" = "$expected" ]] || {
        printf '断言失败：%s\n期望：%s\n实际：%s\n' "$title" "$expected" "$actual" >&2
        exit 1
    }
}

assert_eq "$(normalize_resolve_preference auto)" 'auto' '自动模式'
assert_eq "$(normalize_resolve_preference ipv4_prefer)" 'ipv4_prefer' 'IPv4 优先'
assert_eq "$(normalize_resolve_preference ipv6_prefer)" 'ipv6_prefer' 'IPv6 优先'
assert_eq "$(normalize_resolve_preference ipv4_only)" 'ipv4_only' '仅 IPv4'
assert_eq "$(normalize_resolve_preference ipv6_only)" 'ipv6_only' '仅 IPv6'
assert_eq "$(normalize_resolve_preference ipv4 2>/dev/null)" 'ipv4_only' '旧 IPv4 值兼容'
assert_eq "$(normalize_resolve_preference ipv6 2>/dev/null)" 'ipv6_only' '旧 IPv6 值兼容'

if (normalize_resolve_preference unsupported >/dev/null 2>&1); then
    echo '断言失败：未知解析偏好不应被接受' >&2
    exit 1
fi

patch="${ROOT}/patches/microsocks-resolve-preference.patch"
grep -q 'TARGET_FAMILY_IPV4_PREFER' "$patch" || { echo '断言失败：补丁缺少 IPv4 优先模式' >&2; exit 1; }
grep -q 'TARGET_FAMILY_IPV6_PREFER' "$patch" || { echo '断言失败：补丁缺少 IPv6 优先模式' >&2; exit 1; }
grep -q '仅域名请求应用解析偏好' "$patch" || { echo '断言失败：补丁未保证数值地址不改写' >&2; exit 1; }
grep -q '继续尝试其余候选地址族' "$patch" || { echo '断言失败：补丁缺少优先失败回退' >&2; exit 1; }
grep -q 'send_success' "$patch" || { echo '断言失败：补丁缺少成功响应地址族回传' >&2; exit 1; }
grep -q 'getsockname(remote_fd' "$patch" || { echo '断言失败：补丁未读取实际出站 socket 绑定地址' >&2; exit 1; }

echo '域名解析偏好测试通过'
