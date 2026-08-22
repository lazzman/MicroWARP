#!/usr/bin/env bash
# 验证管理面板实例操作的空闲优先队列、停用、启用、优雅重连与强制重连状态机。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

export MICROWARP_RUNTIME_ROOT="$workdir/runtime"
export INSTANCE_COUNT=1
export PROXY_MODE=socks5
export MANAGEMENT_UI_ENABLED=1
export MANAGEMENT_CONTROL_LIB_ONLY=1
export ROTATE_RESTART_DEFERRED_CHECK_INTERVAL=1

# shellcheck source=../management-control.sh
source "${ROOT}/management-control.sh"

management_ui_enabled || { echo '断言失败：管理面板应识别为启用' >&2; exit 1; }
lb_should_run || { echo '断言失败：管理面板应强制启用 LB' >&2; exit 1; }
control_plane_should_run || { echo '断言失败：管理面板应强制启用控制面' >&2; exit 1; }

calls="${workdir}/calls.log"
start_instance() { printf 'start:%s\n' "$1" >> "$calls"; }
stop_instance() { printf 'stop:%s\n' "$1" >> "$calls"; }
set_pool() { printf 'pool:%s\n' "$1" >> "$calls"; }
wait_until_idle() { printf 'idle:%s\n' "$1" >> "$calls"; }

assert_contains() {
    local title="$1" text="$2" expected="$3"
    [[ "$text" == *"$expected"* ]] || {
        printf '断言失败：%s\n期望包含：%s\n实际：%s\n' "$title" "$expected" "$text" >&2
        exit 1
    }
}

assert_not_contains() {
    local title="$1" text="$2" unexpected="$3"
    [[ "$text" != *"$unexpected"* ]] || {
        printf '断言失败：%s\n不应包含：%s\n实际：%s\n' "$title" "$unexpected" "$text" >&2
        exit 1
    }
}

INSTANCE_ID=0
mkdir -p "$(runtime_dir)"

# 管理操作必须调用 ready，而不是只读旧的 probe 状态；ready 是“重新探测 WARP
# 并同步确认后端池 up”的统一完成条件。这样手工与计划重启才能比较恢复耗时。
recovery_calls="${workdir}/recovery-calls.log"
cat > "${workdir}/health-ready.sh" <<'SH'
#!/usr/bin/env bash
printf '%s id=%s force=%s\n' "$1" "$2" "${MANAGEMENT_FORCE_PROBE:-0}" >> "${RECOVERY_CALLS:?}"
[[ "$1" = ready && "$2" = 0 && "${MANAGEMENT_FORCE_PROBE:-0}" = 1 ]]
SH
chmod +x "${workdir}/health-ready.sh"
HEALTH_CHECK_COMMAND="${workdir}/health-ready.sh"
RECOVERY_CALLS="$recovery_calls"
export RECOVERY_CALLS
PROBE_TIMEOUT=2
RECOVERY_PROBE_INTERVAL=1
ACTION=reconnect
write_operation "running" "测试恢复确认" "" "" "received"
wait_ready
assert_contains '恢复确认调用 ready' "$(cat "$recovery_calls")" 'ready id=0 force=1'
operation_state="$(cat "$(operation_file)")"
assert_contains '恢复确认写入重新入池阶段' "$operation_state" 'phase=pool-rejoin'
assert_contains '恢复确认记录 WARP 就绪时间' "$operation_state" 'warp_ready_at='
assert_contains '恢复确认记录重新入池时间' "$operation_state" 'pool_rejoined_at='
rm -f "$(operation_file)"

# 后续状态机用桩函数隔离生命周期命令；上面的用例已覆盖真实 wait_ready 路径。
wait_ready() { printf 'probe\n' >> "$calls"; return 0; }

ACTION=disable
disable_instance
[[ -f "$(disabled_file)" ]] || { echo '断言失败：停用未写入标记' >&2; exit 1; }
assert_contains '停用摘流' "$(cat "$calls")" 'pool:down'
assert_contains '停用进入空闲队列' "$(cat "$calls")" 'idle:停用实例'
assert_contains '停用停止实例' "$(cat "$calls")" 'stop:0'
assert_contains '停用健康状态' "$(cat "$(runtime_dir)/health.state")" 'disabled'

: > "$calls"
ACTION=enable
enable_instance
[[ ! -f "$(disabled_file)" ]] || { echo '断言失败：启用未清除停用标记' >&2; exit 1; }
assert_contains '启用启动实例' "$(cat "$calls")" 'start:0'
assert_contains '启用探测' "$(cat "$calls")" 'probe'

: > "$calls"
ACTION=reconnect
reconnect_instance
assert_contains '重连摘流' "$(cat "$calls")" 'pool:down'
assert_contains '重连进入空闲队列' "$(cat "$calls")" 'idle:优雅重连'
assert_contains '重连停止实例' "$(cat "$calls")" 'stop:0'
assert_contains '重连启动实例' "$(cat "$calls")" 'start:0'
assert_contains '重连探测' "$(cat "$calls")" 'probe'

: > "$calls"
ACTION=force-reconnect
force_reconnect_instance
assert_contains '强制重连摘流' "$(cat "$calls")" 'pool:down'
assert_not_contains '强制重连不得进入空闲队列' "$(cat "$calls")" 'idle:'
assert_contains '强制重连停止实例' "$(cat "$calls")" 'stop:0'
assert_contains '强制重连启动实例' "$(cat "$calls")" 'start:0'
assert_contains '强制重连探测' "$(cat "$calls")" 'probe'

# 后端池同步确认暂时失败时，管理操作应保留实例并退避重试；短暂竞争不能直接
# 变成 backend-drain-failed，更不能在未确认摘流时提前停止实例。
: > "$calls"
pool_attempt=0
set_pool() {
    pool_attempt=$((pool_attempt + 1))
    printf 'pool:%s:%s\n' "$1" "$pool_attempt" >> "$calls"
    [[ "$pool_attempt" -gt 1 ]]
}
BACKEND_RETRY_LIMIT=1
BACKEND_RETRY_MAX_DELAY=1
ACTION=force-reconnect
force_reconnect_instance
assert_contains '强制重连摘流确认重试' "$(cat "$calls")" 'pool:down:2'
assert_contains '强制重连确认后才停止实例' "$(cat "$calls")" 'stop:0'
assert_not_contains '短暂后端池竞争不得记录最终失败' "$(cat "$(operation_file)")" 'status=failed'

# 手工停用实例不允许两种重连，必须先显式启用。
touch "$(disabled_file)"
if reconnect_instance >/dev/null 2>&1; then
    echo '断言失败：停用实例不应允许优雅重连' >&2
    exit 1
fi
if force_reconnect_instance >/dev/null 2>&1; then
    echo '断言失败：停用实例不应允许强制重连' >&2
    exit 1
fi

# 终态必须固化结束时间、真实耗时和可读的失败阶段，页面不能把历史记录的年龄当成耗时。
rm -f "$(disabled_file)"
ACTION=reconnect
OPERATION_STARTED_AT=$(( $(date +%s) - 5 ))
write_operation "failed" "在 180 秒内未确认 WARP 已就绪" "" "" "warp-probe" "warp-probe-timeout"
operation_state="$(cat "$(operation_file)")"
assert_contains '失败阶段' "$operation_state" 'phase=warp-probe'
assert_contains '失败原因码' "$operation_state" 'reason_code=warp-probe-timeout'
assert_contains '终态结束时间' "$operation_state" 'finished_at='
assert_contains '终态固定耗时' "$operation_state" 'duration_seconds='

# 主流程不得再用“操作未能在限定时间内完成”覆盖已记录的具体失败原因。
validate_request() { :; }
acquire_lock() { :; }
release_lock() { :; }
reconnect_instance() {
    record_failure 'warp-probe' 'warp-probe-timeout' '在 180 秒内未确认 WARP 已就绪'
    return 1
}
OPERATION_FAILURE_RECORDED=0
if (main); then
    echo '断言失败：模拟的失败管理操作不应返回成功' >&2
    exit 1
fi
operation_state="$(cat "$(operation_file)")"
assert_contains '主流程保留具体失败原因' "$operation_state" '在 180 秒内未确认 WARP 已就绪'
assert_not_contains '主流程不得覆盖为泛化超时' "$operation_state" '操作未能在限定时间内完成'

# 探测超时不代表最终不可用。健康守护后续探测成功并重新入池时，必须将管理
# 操作更新为 recovered，同时保留首次超时诊断，避免页面长期展示过期失败状态。
cat > "$(operation_file)" <<STATE
action=reconnect
status=failed
message=在 180 秒内未确认 WARP 已就绪
operation_id=instance-0-late-recovery
started_at=$(( $(date +%s) - 190 ))
updated_at=$(( $(date +%s) - 10 ))
finished_at=$(( $(date +%s) - 10 ))
duration_seconds=180
phase=warp-probe
reason_code=warp-probe-timeout
backend_drained_at=$(( $(date +%s) - 185 ))
instance_stop_started_at=$(( $(date +%s) - 184 ))
instance_stopped_at=$(( $(date +%s) - 183 ))
instance_start_started_at=$(( $(date +%s) - 182 ))
instance_started_at=$(( $(date +%s) - 181 ))
warp_probe_started_at=$(( $(date +%s) - 180 ))
probe_timed_out_at=$(( $(date +%s) - 10 ))
STATE
export HEALTH_CHECK_LIB_ONLY=1
# shellcheck source=../health-check.sh
source "${ROOT}/health-check.sh"
# 健康探测的延迟恢复写回必须和新的管理操作互斥，不能覆盖刚开始的新操作。
mkdir "$(management_lock_dir 0)"
reconcile_timed_out_management_operation 0
operation_state="$(cat "$(operation_file)")"
assert_contains '管理锁存在时不覆盖超时状态' "$operation_state" 'status=failed'
rmdir "$(management_lock_dir 0)"
reconcile_timed_out_management_operation 0
operation_state="$(cat "$(operation_file)")"
assert_contains '延迟恢复状态' "$operation_state" 'status=recovered'
assert_contains '延迟恢复阶段' "$operation_state" 'phase=recovered'
assert_contains '保留首次超时原因码' "$operation_state" 'timeout_reason_code=warp-probe-timeout'
assert_contains '保留首次超时原因' "$operation_state" 'timeout_message=在 180 秒内未确认 WARP 已就绪'
assert_contains '记录最终恢复时间' "$operation_state" 'recovered_at='
assert_contains '保留摘流阶段时间' "$operation_state" 'backend_drained_at='
assert_contains '保留停止阶段时间' "$operation_state" 'instance_stopped_at='
assert_contains '保留启动阶段时间' "$operation_state" 'instance_started_at='
assert_contains '保留主动确认超时时间' "$operation_state" 'probe_timed_out_at='
assert_contains '记录健康守护恢复时间' "$operation_state" 'health_recovered_at='
assert_not_contains '恢复状态不再保留当前失败原因码' "$operation_state" $'\nreason_code='

echo '管理实例控制测试通过'
