#!/usr/bin/env bash
# 验证多实例网络命名空间的独立 resolv.conf 生成与清理逻辑。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../netns-utils.sh
source "${ROOT}/netns-utils.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
NETNS_CONFIG_ROOT="$workdir/etc-netns"
NETNS_DNS_SERVERS=' 1.1.1.1, 1.0.0.1 '

netns_write_resolv_conf microwarp7
expected=$'# 由 MicroWARP 为此网络命名空间生成；请勿手工修改。\nnameserver 1.1.1.1\nnameserver 1.0.0.1'
actual="$(cat "${NETNS_CONFIG_ROOT}/microwarp7/resolv.conf")"
if [ "$actual" != "$expected" ]; then
    printf 'DNS 配置内容错误\n期望：%s\n实际：%s\n' "$expected" "$actual" >&2
    exit 1
fi

netns_remove_resolv_conf microwarp7
if [ -e "${NETNS_CONFIG_ROOT}/microwarp7/resolv.conf" ] || [ -d "${NETNS_CONFIG_ROOT}/microwarp7" ]; then
    echo 'DNS 配置清理失败' >&2
    exit 1
fi

NETNS_DNS_SERVERS=' , '
if netns_write_resolv_conf microwarp8; then
    echo '空 DNS 列表不应被接受' >&2
    exit 1
fi

echo '网络命名空间 DNS 工具测试通过'
