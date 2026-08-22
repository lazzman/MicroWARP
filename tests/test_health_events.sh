#!/usr/bin/env bash
# 验证健康状态变化时的图标状态表、去重和关闭开关。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

export INSTANCE_COUNT=2
export MICROWARP_RUNTIME_ROOT="$workdir/runtime"
export LB_BACKENDS_FILE="$MICROWARP_RUNTIME_ROOT/backends.txt"
export BACKENDS_META_FILE="$MICROWARP_RUNTIME_ROOT/backends.meta"
export LB_CONNECTION_STATE_FILE="$MICROWARP_RUNTIME_ROOT/lb-connections.txt"
export HEALTH_CHECK_LIB_ONLY=1
export STATUS_EVENT_LOG=1
# shellcheck source=../health-check.sh
source "${ROOT}/health-check.sh"

assert_contains() {
    local title="$1" text="$2" expected="$3"
    [[ "$text" == *"$expected"* ]] || {
        printf '断言失败：%s\n期望包含：%s\n实际：%s\n' "$title" "$expected" "$text" >&2
        exit 1
    }
}

assert_empty() {
    local title="$1" text="$2"
    [[ -z "$text" ]] || {
        printf '断言失败：%s\n实际：%s\n' "$title" "$text" >&2
        exit 1
    }
}

mkdir -p "$MICROWARP_RUNTIME_ROOT/instances/0" "$MICROWARP_RUNTIME_ROOT/instances/1"
: > "$MICROWARP_RUNTIME_ROOT/instances.dynamic"
printf '0=up\n1=down\n' > "$BACKENDS_META_FILE"
# 该文件由 LB 原子写入。状态表应展示每个 WARP 后端真实承载的代理连接，健康探测
# 不经 LB，故不会污染这个计数。
printf '10.64.0.2:1080\t7\n10.64.1.2:1080\t2\n' > "$LB_CONNECTION_STATE_FILE"
printf 'ready ip=2a09:bac5::1 ip4=198.51.100.1 ip6=2a09:bac5::1 warp=on loc=US colo=SJC checked_at=100\n' > "$(state_file 0)"
printf 'waiting checked_at=100\n' > "$(state_file 1)"

begin_status_round
record_status_snapshot 0 "$(instance_status_snapshot 0)"
record_status_snapshot 1 "$(instance_status_snapshot 1)"
table="$(emit_status_table_if_changed)"
assert_contains '首次状态表标题' "$table" '实例状态变化 · 第 1 轮'
assert_contains '首次就绪标记' "$table" '🆕'
assert_contains '就绪实例图标' "$table" '✅ 实例=0'
assert_contains 'IPv4 出口' "$table" 'IPv4=198.51.100.1'
assert_contains 'IPv6 出口' "$table" 'IPv6=2a09:bac5::1'
assert_contains '出口国家' "$table" '国家=US'
assert_contains 'Cloudflare 节点' "$table" '节点=SJC'
assert_contains '实例 0 活跃连接' "$table" '活跃连接=7'
assert_contains '等待实例图标' "$table" '⏳ 实例=1'
assert_contains '实例 1 活跃连接' "$table" '活跃连接=2'
assert_contains '已入池状态' "$table" '🟢 已入池'
assert_contains '摘流状态' "$table" '⚪ 摘流'
assert_contains '汇总图标' "$table" '📦 汇总 | ✅ 就绪=1 ⏳ 等待=1'

# 手工与计划重启共用 ready 完成条件：即使检查函数刚写入 ready，也必须通过
# 同步确认的 up 提交后才返回成功，不能把旧状态或异步请求误报为已恢复。
ready_confirmation_log="$workdir/ready-confirmations.log"
(
    check_one() {
        printf 'ready checked_at=200\n' > "$(state_file 0)"
    }
    update_backend() {
        printf 'id=%s state=%s mode=%s\n' "$1" "$2" "${3:-async}" >> "$ready_confirmation_log"
        [[ "$1" = 0 && "$2" = up && "${3:-async}" = confirmed ]]
    }
    confirm_warp_ready 0
)
assert_contains 'ready 完成条件同步确认后端池' "$(cat "$ready_confirmation_log")" 'id=0 state=up mode=confirmed'

# checked_at 改变不属于可见状态变化，不能重复输出表格。
printf 'ready ip=2a09:bac5::1 ip4=198.51.100.1 ip6=2a09:bac5::1 warp=on loc=US colo=SJC checked_at=101\n' > "$(state_file 0)"
printf 'waiting checked_at=101\n' > "$(state_file 1)"
begin_status_round
record_status_snapshot 0 "$(instance_status_snapshot 0)"
record_status_snapshot 1 "$(instance_status_snapshot 1)"
assert_empty '无状态变化不输出表格' "$(emit_status_table_if_changed)"

# 实例 1 从等待变为就绪，必须输出完整表并以 🔄 标记该行。
printf '1=up\n' >> "$BACKENDS_META_FILE"
printf 'ready ip=2a09:bac5::2 ip4=198.51.100.2 ip6=2a09:bac5::2 warp=plus loc=DE colo=FRA checked_at=102\n' > "$(state_file 1)"
begin_status_round
record_status_snapshot 0 "$(instance_status_snapshot 0)"
record_status_snapshot 1 "$(instance_status_snapshot 1)"
table="$(emit_status_table_if_changed)"
assert_contains '变化实例标记' "$table" '🔄'
assert_contains '恢复实例 IPv4 出口' "$table" 'IPv4=198.51.100.2'
assert_contains '恢复实例 IPv6 出口' "$table" 'IPv6=2a09:bac5::2'
assert_contains '恢复实例国家' "$table" '国家=DE'
assert_contains '恢复实例节点' "$table" '节点=FRA'
assert_contains '恢复后汇总' "$table" '📦 汇总 | ✅ 就绪=2 ⏳ 等待=0'

# 管理面板停用标记优先于旧健康状态，状态表必须展示停用并保持摘流。
touch "$(manual_disabled_file 1)"
printf '1=down\n' >> "$BACKENDS_META_FILE"
begin_status_round
record_status_snapshot 0 "$(instance_status_snapshot 0)"
record_status_snapshot 1 "$(instance_status_snapshot 1)"
table="$(emit_status_table_if_changed)"
assert_contains '手工停用图标' "$table" '⏹️  实例=1'
assert_contains '手工停用说明' "$table" '已由管理面板手动停用'
assert_contains '手工停用摘流' "$table" '⚪ 摘流'
rm -f "$(manual_disabled_file 1)"

# 不经内置 LB 的单实例轻量直连路径无法观测 microsocks/usque 的真实连接数，必须
# 明确显示不可用，不能将其误报为 0。
[[ "$(LB_ACTIVE=0 active_connections_for 0)" = '—' ]] || {
    printf '断言失败：直连路径活跃连接应显示不可用\n' >&2
    exit 1
}

# 双栈出口探测必须由 curl 本地应用 --resolve 后转发数值地址；若仍用 socks5h，
# 域名会被后端重新解析，无法保证本轮观测的目标地址族。
assert_contains '双栈观测使用本地解析 SOCKS URL' "$(proxy_url_for '10.64.0.2:1080' local)" 'socks5://'
assert_contains '常规健康探测仍使用远端解析 SOCKS URL' "$(proxy_url_for '10.64.0.2:1080')" 'socks5h://'
# 多实例的内部 SOCKS 后端是 IPv4 地址；curl -6 会拒绝先连接这个代理。
# --resolve 已保证 SOCKS CONNECT 目标使用指定的 IPv6 数值地址，因此不得添加 -6。
family_curl_args="${workdir}/family-curl.args"
curl() {
    printf '%s\n' "$@" > "$family_curl_args"
    printf 'ip=2001:db8::10\nwarp=on\nloc=DE\ncolo=FRA\n'
}
probe_instance_family 0 6 >/dev/null
family_curl_text="$(cat "$family_curl_args")"
assert_contains '双栈观测固定 IPv6 数值地址' "$family_curl_text" 'www.cloudflare.com:443:2606:4700::0011'
assert_contains '双栈观测经内部 IPv4 SOCKS 后端' "$family_curl_text" 'socks5://10.64.0.2:1080'
if grep -qx -- '-6' "$family_curl_args" || grep -qx -- '-4' "$family_curl_args"; then
    echo '断言失败：双栈出口观测不能用 curl -4/-6 限制内部 IPv4 SOCKS 连接' >&2
    exit 1
fi

# 双栈出口单独探测并持久化，管理面板可同时展示 IPv4 与 IPv6 出口。
ENABLE_IPV6=1
probe_instance() {
    printf 'ip=2001:db8::10\nwarp=on\nloc=DE\ncolo=FRA\n'
}
probe_instance_family() {
    case "$2" in
        4) printf 'ip=198.51.100.10\nwarp=on\nloc=US\ncolo=SJC\n' ;;
        6) printf 'ip=2001:db8::10\nwarp=on\nloc=DE\ncolo=FRA\n' ;;
        *) return 1 ;;
    esac
}
check_one 0
state="$(cat "$(state_file 0)")"
assert_contains '双栈状态 IPv4 出口' "$state" 'ip4=198.51.100.10'
assert_contains '双栈状态 IPv6 出口' "$state" 'ip6=2001:db8::10'
assert_contains '双栈状态 IPv4 位置' "$state" 'loc4=US'
assert_contains '双栈状态 IPv6 节点' "$state" 'colo6=FRA'

# 一个实例内的 WARP 主探测与双栈出口观测应并发，避免原先三段串行超时。
probe_instance() {
    sleep 1
    printf 'ip=198.51.100.20\nwarp=on\nloc=US\ncolo=SJC\n'
}
probe_instance_family() {
    sleep 1
    case "$2" in
        4) printf 'ip=198.51.100.20\nwarp=on\nloc=US\ncolo=SJC\n' ;;
        6) printf 'ip=2001:db8::20\nwarp=on\nloc=DE\ncolo=FRA\n' ;;
    esac
}
SECONDS=0
check_one 0
single_instance_probe_elapsed="$SECONDS"
[[ "$single_instance_probe_elapsed" -lt 3 ]] || {
    printf '断言失败：单实例三类探测应并行，实际耗时=%ss\n' "$single_instance_probe_elapsed" >&2
    exit 1
}

# WARP 主探测成功后必须先入池，不能等待较慢的双栈出口观测完成。
printf '0=down\n1=down\n' > "$BACKENDS_META_FILE"
probe_instance() {
    printf 'ip=198.51.100.30\nwarp=on\nloc=US\ncolo=SJC\n'
}
probe_instance_family() {
    sleep 2
    case "$2" in
        4) printf 'ip=198.51.100.30\nwarp=on\nloc=US\ncolo=SJC\n' ;;
        6) printf 'ip=2001:db8::30\nwarp=on\nloc=DE\ncolo=FRA\n' ;;
    esac
}
check_one 0 &
early_ready_pid="$!"
early_ready_seen=0
for _ in $(seq 1 10); do
    if [[ "$(backend_pool_state 0)" = up ]]; then
        early_ready_seen=1
        break
    fi
    sleep 0.1
done
[[ "$early_ready_seen" = 1 ]] || {
    echo '断言失败：WARP 主探测通过后未在双栈观测完成前加入后端池' >&2
    exit 1
}
assert_contains '提前入池时先写入最小就绪状态' "$(cat "$(state_file 0)")" 'ip4=?'
wait "$early_ready_pid"
assert_contains '双栈观测完成后补齐 IPv4 出口' "$(cat "$(state_file 0)")" 'ip4=198.51.100.30'

# 并发上限约束实际 HTTP 探测而不是实例工作流；两个实例各自会发起三类探测，
# 但 HEALTH_PROBE_CONCURRENCY=2 时任意时刻最多只能有两个在运行。
HEALTH_PROBE_CONCURRENCY=2
probe_counter_dir="$workdir/probe-counter"
mkdir -p "$probe_counter_dir"
printf '0\n' > "$probe_counter_dir/active"
printf '0\n' > "$probe_counter_dir/max"
record_probe_parallelism() {
    local active maximum
    while ! mkdir "$probe_counter_dir/lock" 2>/dev/null; do sleep 0.01; done
    active="$(cat "$probe_counter_dir/active")"
    active=$((active + 1))
    maximum="$(cat "$probe_counter_dir/max")"
    [[ "$active" -gt "$maximum" ]] && maximum="$active"
    printf '%s\n' "$active" > "$probe_counter_dir/active"
    printf '%s\n' "$maximum" > "$probe_counter_dir/max"
    rmdir "$probe_counter_dir/lock"
    sleep 0.3
    while ! mkdir "$probe_counter_dir/lock" 2>/dev/null; do sleep 0.01; done
    active="$(cat "$probe_counter_dir/active")"
    printf '%s\n' "$((active - 1))" > "$probe_counter_dir/active"
    rmdir "$probe_counter_dir/lock"
}
probe_instance() {
    record_probe_parallelism
    printf 'ip=198.51.100.40\nwarp=on\nloc=US\ncolo=SJC\n'
}
probe_instance_family() {
    record_probe_parallelism
    case "$2" in
        4) printf 'ip=198.51.100.40\nwarp=on\nloc=US\ncolo=SJC\n' ;;
        6) printf 'ip=2001:db8::40\nwarp=on\nloc=DE\ncolo=FRA\n' ;;
    esac
}
printf '0=down\n1=down\n' > "$BACKENDS_META_FILE"
check_one 0 &
probe_limit_pid0="$!"
check_one 1 &
probe_limit_pid1="$!"
wait "$probe_limit_pid0"
wait "$probe_limit_pid1"
[[ "$(cat "$probe_counter_dir/max")" = 2 ]] || {
    printf '断言失败：实际 HTTP 探测并发上限未生效，峰值=%s\n' "$(cat "$probe_counter_dir/max")" >&2
    exit 1
}

# 轮次使用动态工作流窗口：等待令牌或收集出口观测的实例数量同样受配置限制，
# 但一个任务结束后必须立即补充下一任务，而不应等待整轮结束。
INSTANCE_COUNT=3
HEALTH_PROBE_CONCURRENCY=2
mkdir -p "$MICROWARP_RUNTIME_ROOT/instances/2"
printf '0=down\n1=down\n2=down\n' > "$BACKENDS_META_FILE"
check_one() {
    local id="$1"
    sleep 2
    printf 'ready ip=198.51.100.%s ip4=198.51.100.%s ip6=? warp=on loc=US colo=SJC checked_at=200\n' \
        "$((id + 20))" "$((id + 20))" > "$(state_file "$id")"
    printf '0\n' > "$(fail_file "$id")"
    update_backend "$id" up
}
SECONDS=0
once >/dev/null
round_probe_elapsed="$SECONDS"
[[ "$round_probe_elapsed" -ge 3 && "$round_probe_elapsed" -lt 7 ]] || {
    printf '断言失败：轮次探测并发上限未生效，实际耗时=%ss\n' "$round_probe_elapsed" >&2
    exit 1
}

# 大批实例会在首轮同时就绪。后端状态更新必须先落盘、由单一提交者短暂合并，
# 不能像旧实现那样让每个实例持锁重建全量池并在 5 秒后丢弃部分 up 状态。
INSTANCE_COUNT=48
HEALTH_PROBE_CONCURRENCY=48
BACKEND_POOL_BATCH_WINDOW_MS=10
mkdir -p "$MICROWARP_RUNTIME_ROOT/instances"
for id in $(seq 0 47); do mkdir -p "$MICROWARP_RUNTIME_ROOT/instances/$id"; done
: > "$BACKENDS_META_FILE"
: > "$BACKENDS_FILE"
for id in $(seq 0 47); do update_backend "$id" up & done
wait
backend_up_count="$(awk -F= '$2 == "up" { count++ } END { print count + 0 }' "$BACKENDS_META_FILE")"
backend_list_count="$(wc -l < "$BACKENDS_FILE" | tr -d ' ')"
pending_update_count="$(find "$(backend_pending_dir)" -type f -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$backend_up_count" = 48 ]] || {
    printf '断言失败：批量后端池应保留全部 up 状态，实际=%s\n' "$backend_up_count" >&2
    exit 1
}
[[ "$backend_list_count" = 48 ]] || {
    printf '断言失败：批量后端列表应含全部实例，实际=%s\n' "$backend_list_count" >&2
    exit 1
}
[[ "$pending_update_count" = 0 ]] || {
    printf '断言失败：批量提交后不应残留待处理请求，实际=%s\n' "$pending_update_count" >&2
    exit 1
}
[[ ! -d "$(backend_lock_dir)" ]] || {
    printf '断言失败：批量提交后不应遗留后端池锁\n' >&2
    exit 1
}

# 破坏性操作通过 pool 同步入口时，不能仅因请求已经落盘就返回成功；必须等到
# backends.meta 确认目标状态。超时请求保留，后续提交者可继续合并并完成确认。
INSTANCE_COUNT=2
printf '0=up\n1=up\n' > "$BACKENDS_META_FILE"
mkdir "$(backend_lock_dir)"
printf '%s\n' "$$" > "$(backend_lock_dir)/owner"
BACKEND_POOL_LOCK_TIMEOUT=1
if update_backend 0 down confirmed; then
    printf '断言失败：持有后端池锁时同步确认不应提前成功\n' >&2
    exit 1
else
    update_exit="$?"
fi
[[ "$update_exit" = 75 ]] || {
    printf '断言失败：同步确认超时应返回 75，实际=%s\n' "$update_exit" >&2
    exit 1
}
pending_update_count="$(find "$(backend_pending_dir)" -type f -name '[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$pending_update_count" -ge 1 ]] || {
    printf '断言失败：同步确认超时后必须保留后端池请求\n' >&2
    exit 1
}
rm -rf "$(backend_lock_dir)"
update_backend 0 down confirmed
[[ "$(backend_pool_state 0)" = down ]] || {
    printf '断言失败：后续提交者应合并保留的摘流请求\n' >&2
    exit 1
}

STATUS_EVENT_LOG=0
printf 'failed failures=3 checked_at=103\n' > "$(state_file 1)"
printf '1=down\n' >> "$BACKENDS_META_FILE"
begin_status_round
record_status_snapshot 0 "$(instance_status_snapshot 0)"
record_status_snapshot 1 "$(instance_status_snapshot 1)"
assert_empty '关闭状态表后不输出控制台' "$(emit_status_table_if_changed)"

echo '健康状态事件表格测试通过'
