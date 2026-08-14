#!/usr/bin/env bash
# 验证临时实例只记录在运行时文件中，并支持增加、移除和容器重启自动失效。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

export MICROWARP_RUNTIME_ROOT="$workdir/runtime"
export MICROWARP_DYNAMIC_INSTANCES_FILE="$workdir/runtime/instances.dynamic"
export INSTANCE_COUNT=2
export PROXY_MODE=mixed
export MANAGEMENT_UI_ENABLED=1
export MANAGEMENT_CONTROL_LIB_ONLY=1
# shellcheck source=../management-control.sh
source "${ROOT}/management-control.sh"

calls="$workdir/calls"
start_instance() { printf 'start:%s\n' "$1" >> "$calls"; }
stop_instance() { printf 'stop:%s\n' "$1" >> "$calls"; }
write_all_backends() { printf 'backends\n' >> "$calls"; }
start_initial_probe() { printf 'probe:%s\n' "$1" >> "$calls"; }

mkdir -p "$MICROWARP_RUNTIME_ROOT"
add_instance >/dev/null
[[ "$(cat "$MICROWARP_DYNAMIC_INSTANCES_FILE")" = 2 ]] || { echo '断言失败：应记录临时实例 2' >&2; exit 1; }
grep -qx 'start:2' "$calls" || { echo '断言失败：应启动临时实例 2' >&2; exit 1; }
grep -qx 'probe:2' "$calls" || { echo '断言失败：应异步触发临时实例 2 的健康探测' >&2; exit 1; }

# 动态实例与基础实例一样应能进入管理操作；旧实现只允许 ID < INSTANCE_COUNT，
# 会让刚添加的实例无法重连或启停。
ACTION=reconnect
INSTANCE_ID=2
validate_request || { echo '断言失败：动态实例应通过重连操作预检' >&2; exit 1; }

remove_instance 2
grep -qx 'stop:2' "$calls" || { echo '断言失败：应停止临时实例 2' >&2; exit 1; }
[[ ! -s "$MICROWARP_DYNAMIC_INSTANCES_FILE" ]] || { echo '断言失败：移除后动态实例文件应为空' >&2; exit 1; }

# 10.64.<ID>.x 地址布局最多支持 ID=254，不能产生无效的第三个 IPv4 八位组。
INSTANCE_COUNT=255
if add_instance >/dev/null 2>&1; then
    echo '断言失败：达到 255 个实例时不应继续添加临时实例' >&2
    exit 1
fi

echo '临时实例管理测试通过'
