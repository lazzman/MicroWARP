#!/usr/bin/env bash
# 管理面板的异步实例操作执行器：空闲优先队列、启停与 WARP 就绪验证。
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 复用 entrypoint 的实例网络、隧道与生命周期函数，但不进入 PID 1 主循环。
export MICROWARP_LIB_ONLY=1
# shellcheck source=entrypoint.sh
source "${APP_DIR}/entrypoint.sh"

ACTION="${1:-}"
INSTANCE_ID="${2:-}"
RUNTIME_ROOT="${MICROWARP_RUNTIME_ROOT:-/run/microwarp}"
MICROWARP_DYNAMIC_INSTANCES_FILE="${MICROWARP_DYNAMIC_INSTANCES_FILE:-${RUNTIME_ROOT}/instances.dynamic}"
CONNECTION_FILE="${LB_CONNECTION_STATE_FILE:-${RUNTIME_ROOT}/lb-connections.txt}"
# 默认与计划重启采用同一个恢复确认窗口；只把“等待多久”对齐，不用超时值
# 伪装 WARP 已恢复。真正的完成条件由 health-check ready 同步确认。
PROBE_TIMEOUT="${MANAGEMENT_ACTION_PROBE_TIMEOUT:-${ROTATE_RESTART_PROBE_TIMEOUT:-90}}"
# 手工优雅操作不能因为计划队列的 60 秒复查节奏而额外多等近一分钟。该周期
# 仅影响手工停用/优雅重连，仍然绝不主动中断现有连接。
DEFERRED_CHECK_INTERVAL="${MANAGEMENT_IDLE_CHECK_INTERVAL:-3}"
# 手工重连与计划重启共享 WARP 就绪探测间隔，确保两条恢复路径的节奏一致。
RECOVERY_PROBE_INTERVAL="${RESTART_RECOVERY_PROBE_INTERVAL:-3}"
HEALTH_CHECK_COMMAND="${MICROWARP_HEALTH_CHECK:-${APP_DIR}/health-check.sh}"
# 摘流/恢复是破坏性操作的前置条件：若统一后端池提交通道暂未确认，管理操作
# 保持实例运行并进行有界退避重试，而不是把“控制面暂忙”误报为最终失败。
BACKEND_RETRY_LIMIT="${BACKEND_POOL_OPERATION_RETRY_LIMIT:-6}"
BACKEND_RETRY_MAX_DELAY="${BACKEND_POOL_OPERATION_RETRY_MAX_DELAY:-10}"
# 由控制面为一次异步请求生成；同一批扩缩容子操作会共享该 ID，便于页面追踪。
OPERATION_ID="${MANAGEMENT_OPERATION_ID:-}"
OPERATION_STARTED_AT="${MANAGEMENT_OPERATION_STARTED_AT:-$(date +%s)}"
OPERATION_FAILURE_RECORDED=0
BACKEND_POOL_LAST_FAILURE_CODE=""

[[ "$BACKEND_RETRY_LIMIT" =~ ^[0-9]+$ ]] || BACKEND_RETRY_LIMIT=6
[[ "$BACKEND_RETRY_MAX_DELAY" =~ ^[0-9]+$ ]] && [[ "$BACKEND_RETRY_MAX_DELAY" -ge 1 ]] || BACKEND_RETRY_MAX_DELAY=10
[[ "$PROBE_TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$PROBE_TIMEOUT" -ge 1 ]] || PROBE_TIMEOUT=90
[[ "$DEFERRED_CHECK_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$DEFERRED_CHECK_INTERVAL" -ge 1 ]] || DEFERRED_CHECK_INTERVAL=3
[[ "$RECOVERY_PROBE_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$RECOVERY_PROBE_INTERVAL" -ge 1 ]] || RECOVERY_PROBE_INTERVAL=3

log() { mw_info "管理" "$*"; }
ok() { mw_ok "管理" "$*"; }
warn() { mw_warn "管理" "$*"; }

runtime_dir() { printf '%s/instances/%s' "$RUNTIME_ROOT" "$INSTANCE_ID"; }
disabled_file() { printf '%s/manual.disabled' "$(runtime_dir)"; }
lock_dir() { printf '%s/management.lock' "$(runtime_dir)"; }
operation_file() { printf '%s/management.state' "$(runtime_dir)"; }
restarting_file() { printf '%s/restarting' "$(runtime_dir)"; }
management_log_file() { printf '%s/management.log' "$(runtime_dir)"; }

# 管理状态文件会在每个阶段原子覆盖；以下字段必须跨阶段保留，才能解释一次
# 重连到底慢在连接排空、后端池确认、进程启动还是 WARP 就绪。
OPERATION_TRACKED_FIELDS="idle_wait_started_at idle_confirmed_at backend_drained_at backend_restored_at instance_stop_started_at instance_stopped_at instance_start_started_at instance_started_at warp_probe_started_at warp_ready_at pool_rejoined_at probe_timed_out_at health_recovered_at"

operation_value() {
    local key="$1" target="${2:-$(operation_file)}"
    # 阶段状态在首次写入前可能不存在；读取空值不是失败，避免 set -e 中断
    # 新建实例或刚受理的管理操作。
    [[ -f "$target" ]] || return 0
    awk -F= -v key="$key" '$1 == key { value=substr($0, length(key) + 2) } END { print value }' "$target" 2>/dev/null || true
}

reset_operation_milestones() {
    local target temporary key
    target="$(operation_file)"
    [[ -f "$target" ]] || return 0
    temporary="${target}.${BASHPID:-$$}.reset"
    cp "$target" "$temporary"
    for key in $OPERATION_TRACKED_FIELDS; do
        awk -F= -v key="$key" '$1 != key { print }' "$temporary" > "${temporary}.next"
        mv "${temporary}.next" "$temporary"
    done
    mv "$temporary" "$target"
}

mark_operation_milestone() {
    local key="$1" value="${2:-$(date +%s)}" target temporary
    case " $OPERATION_TRACKED_FIELDS " in
        *" ${key} "*) ;;
        *) return 2 ;;
    esac
    [[ "$value" =~ ^[0-9]+$ ]] || return 2
    target="$(operation_file)"
    [[ -f "$target" ]] || return 0
    temporary="${target}.${BASHPID:-$$}.${RANDOM}.tmp"
    awk -F= -v key="$key" '$1 != key { print }' "$target" > "$temporary"
    printf '%s=%s\n' "$key" "$value" >> "$temporary"
    mv "$temporary" "$target"
}

mark_operation_milestone_once() {
    local key="$1"
    [[ -n "$(operation_value "$key")" ]] || mark_operation_milestone "$key"
}

write_operation() {
    local status="$1" message="$2" active="${3:-}" next_check_at="${4:-}" \
        phase="${5:-}" reason_code="${6:-}" temporary now duration_seconds field value
    mkdir -p "$(runtime_dir)"
    temporary="$(operation_file).$$"
    now="$(date +%s)"
    [[ "$OPERATION_STARTED_AT" =~ ^[0-9]+$ ]] || OPERATION_STARTED_AT="$now"
    duration_seconds=$(( now - OPERATION_STARTED_AT ))
    [[ "$duration_seconds" -ge 0 ]] || duration_seconds=0
    {
        printf 'action=%s\nstatus=%s\nmessage=%s\n' "$ACTION" "$status" "$message"
        [[ -n "$OPERATION_ID" ]] && printf 'operation_id=%s\n' "$OPERATION_ID"
        printf 'started_at=%s\nupdated_at=%s\n' "$OPERATION_STARTED_AT" "$now"
        [[ -n "$active" ]] && printf 'active_connections=%s\n' "$active"
        [[ -n "$next_check_at" ]] && printf 'next_check_at=%s\n' "$next_check_at"
        [[ -n "$phase" ]] && printf 'phase=%s\n' "$phase"
        [[ -n "$reason_code" ]] && printf 'reason_code=%s\n' "$reason_code"
        # received 是一次新管理操作的起点，绝不能携带上一次操作的阶段时间。
        if [[ "$phase" != "received" ]]; then
            for field in $OPERATION_TRACKED_FIELDS; do
                value="$(operation_value "$field" "$(operation_file)")"
                if [[ "$value" =~ ^[0-9]+$ ]]; then
                    printf '%s=%s\n' "$field" "$value"
                fi
            done
        fi
        case "$status" in
            success|failed|partial|cancelled)
                printf 'finished_at=%s\nduration_seconds=%s\n' "$now" "$duration_seconds"
                ;;
        esac
    } > "$temporary"
    mv "$temporary" "$(operation_file)"
}

record_failure() {
    local phase="$1" reason_code="$2" message="$3"
    OPERATION_FAILURE_RECORDED=1
    write_operation "failed" "$message" "" "" "$phase" "$reason_code"
}

parse_duration() {
    local raw="${1// /}" number unit
    if [[ "$raw" =~ ^[0-9]+$ ]]; then printf '%s\n' "$raw"; return 0; fi
    if [[ "$raw" =~ ^([0-9]+)([smhdSMHD])$ ]]; then
        number="${BASH_REMATCH[1]}"; unit="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
        case "$unit" in s) echo "$number";; m) echo $((number * 60));; h) echo $((number * 3600));; d) echo $((number * 86400));; esac
        return 0
    fi
    return 1
}

active_connections() {
    local backend count
    backend="$(instance_backend_addr "$INSTANCE_ID")"
    count="$(awk -F '\t' -v backend="$backend" '$1 == backend && $2 ~ /^[0-9]+$/ { total += $2 } END { print total + 0 }' "$CONNECTION_FILE" 2>/dev/null || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$count"
}

instance_running() {
    local pid
    pid="$(cat "$(instance_pid_file "$INSTANCE_ID")" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

deferred_check_seconds() {
    local seconds
    seconds="$(parse_duration "$DEFERRED_CHECK_INTERVAL" || echo 3)"
    [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$seconds" -ge 1 ]] || seconds=3
    printf '%s\n' "$seconds"
}

backend_retry_delay_seconds() {
    local attempt="$1" delay
    case "$attempt" in
        1) delay=1 ;;
        2) delay=2 ;;
        3) delay=5 ;;
        *) delay=10 ;;
    esac
    [[ "$delay" -le "$BACKEND_RETRY_MAX_DELAY" ]] || delay="$BACKEND_RETRY_MAX_DELAY"
    printf '%s\n' "$delay"
}

set_pool_with_retry() {
    local target_state="$1" purpose="$2" phase="$3" attempt=0 delay active exit_status
    BACKEND_POOL_LAST_FAILURE_CODE=""
    while true; do
        if set_pool "$target_state"; then
            return 0
        else
            exit_status=$?
        fi
        case "$exit_status" in
            75) BACKEND_POOL_LAST_FAILURE_CODE="backend-pool-confirm-timeout" ;;
            76) BACKEND_POOL_LAST_FAILURE_CODE="backend-pool-state-conflict" ;;
            *) BACKEND_POOL_LAST_FAILURE_CODE="backend-pool-update-failed" ;;
        esac
        attempt=$((attempt + 1))
        if [[ "$attempt" -gt "$BACKEND_RETRY_LIMIT" ]]; then
            warn "实例=${INSTANCE_ID} ${purpose}后端池更新重试预算耗尽 | 状态=${target_state} | 原因=${BACKEND_POOL_LAST_FAILURE_CODE}"
            return "$exit_status"
        fi
        delay="$(backend_retry_delay_seconds "$attempt")"
        active="$(active_connections)"
        write_operation "backend-retry" "后端池${target_state} 状态暂未确认，保持实例运行（既有连接不主动中断）并在 ${delay} 秒后重试（第 ${attempt}/${BACKEND_RETRY_LIMIT} 次）" "$active" "$(( $(date +%s) + delay ))" "$phase" "$BACKEND_POOL_LAST_FAILURE_CODE"
        warn "实例=${INSTANCE_ID} ${purpose}后端池更新未确认，${delay}s 后重试 | 次数=${attempt}/${BACKEND_RETRY_LIMIT} | 原因=${BACKEND_POOL_LAST_FAILURE_CODE}"
        sleep "$delay"
    done
}

wait_until_idle() {
    local purpose="$1" active seconds next_check_at
    seconds="$(deferred_check_seconds)"
    while true; do
        active="$(active_connections)"
        if [[ "$active" -eq 0 ]]; then
            mark_operation_milestone_once "idle_confirmed_at"
            return 0
        fi
        mark_operation_milestone_once "idle_wait_started_at"
        next_check_at=$(( $(date +%s) + seconds ))
        write_operation "deferred" "当前有 ${active} 条活跃连接，保持服务并等待自然空闲；${seconds} 秒后复查" "$active" "$next_check_at" "wait-idle"
        log "实例=${INSTANCE_ID} ${purpose}已延后 | 活跃连接=${active} | 下次复查=${next_check_at}"
        sleep "$seconds"
    done
}

claim_idle_backend() {
    local purpose="$1" active
    while true; do
        wait_until_idle "$purpose"
        write_operation "claiming" "已确认空闲，正在摘流并复核连接" "" "" "backend-drain"
        if ! set_pool_with_retry down "$purpose" "backend-drain"; then
            record_failure "backend-drain" "${BACKEND_POOL_LAST_FAILURE_CODE:-backend-pool-update-failed}" "无法确认实例已从后端池摘流"
            return 1
        fi
        mark_operation_milestone "backend_drained_at"
        write_operation "claiming" "后端池已确认摘流，正在复核连接" "" "" "backend-drain"
        # 摘流与首次检查之间可能刚好建立新连接；恢复流量后重新进入延后队列。
        active="$(active_connections)"
        if [[ "$active" -eq 0 ]]; then
            return 0
        fi
        warn "实例=${INSTANCE_ID} ${purpose}摘流复核发现 ${active} 条活跃连接，恢复流量并延后"
        if ! set_pool_with_retry up "$purpose" "backend-restore"; then
            record_failure "backend-restore" "${BACKEND_POOL_LAST_FAILURE_CODE:-backend-pool-update-failed}" "摘流复核发现新连接后，无法确认实例已恢复后端池流量"
            return 1
        fi
        mark_operation_milestone "backend_restored_at"
    done
}

set_pool() {
    "$HEALTH_CHECK_COMMAND" pool "$INSTANCE_ID" "$1"
}

wait_ready() {
    local deadline attempt=0 now remaining next_check_at
    [[ "$PROBE_TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$PROBE_TIMEOUT" -gt 0 ]] || PROBE_TIMEOUT=90
    deadline=$(( $(date +%s) + PROBE_TIMEOUT ))
    mark_operation_milestone_once "warp_probe_started_at"
    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        attempt=$((attempt + 1))
        now="$(date +%s)"
        next_check_at=$((now + RECOVERY_PROBE_INTERVAL))
        write_operation "probing" "正在确认 WARP 已就绪并重新入池（第 ${attempt} 次）" "" "$next_check_at" "warp-probe"
        # ready 是计划重启和手工操作共用的完成条件：主 WARP 探测通过后，还要
        # 同步确认 up 已提交。输出写入实例管理日志，避免过去无法解释的“已恢复”。
        if MANAGEMENT_FORCE_PROBE=1 "$HEALTH_CHECK_COMMAND" ready "$INSTANCE_ID" >>"$(management_log_file)" 2>&1; then
            mark_operation_milestone "warp_ready_at"
            mark_operation_milestone "pool_rejoined_at"
            write_operation "probing" "WARP 已就绪且已确认重新入池（探测 ${attempt} 次）" "" "" "pool-rejoin"
            return 0
        fi
        now="$(date +%s)"
        remaining=$((deadline - now))
        [[ "$remaining" -gt 0 ]] || break
        [[ "$remaining" -le "$RECOVERY_PROBE_INTERVAL" ]] && sleep "$remaining" || sleep "$RECOVERY_PROBE_INTERVAL"
    done
    mark_operation_milestone "probe_timed_out_at"
    record_failure "warp-probe" "warp-probe-timeout" "在 ${PROBE_TIMEOUT} 秒内未确认 WARP 已就绪并重新入池（已探测 ${attempt} 次）"
    return 1
}

restart_instance_and_confirm_ready() {
    local purpose="$1"
    write_operation "reconnecting" "正在停止实例并重建 WARP 连接" "" "" "instance-stop"
    mark_operation_milestone "instance_stop_started_at"
    if ! stop_instance "$INSTANCE_ID"; then
        record_failure "instance-stop" "instance-stop-failed" "${purpose}前停止实例失败"
        return 1
    fi
    mark_operation_milestone "instance_stopped_at"
    write_operation "starting" "实例已停止，正在启动新的 WARP 工作进程" "" "" "instance-start"
    mark_operation_milestone "instance_start_started_at"
    if ! start_instance "$INSTANCE_ID"; then
        record_failure "instance-start" "instance-start-failed" "${purpose}后启动实例失败"
        return 1
    fi
    mark_operation_milestone "instance_started_at"
    wait_ready
}

acquire_lock() {
    mkdir -p "$(runtime_dir)"
    if [[ "${MANAGEMENT_LOCK_HELD:-0}" =~ ^(1|true|yes|on)$ ]]; then
        [[ -d "$(lock_dir)" ]] || mkdir "$(lock_dir)"
        return 0
    fi
    mkdir "$(lock_dir)" 2>/dev/null
}

release_lock() {
    rm -rf "$(lock_dir)"
    rm -f "$(restarting_file)"
}

validate_request() {
    normalize_instance_count
    normalize_proxy_mode
    management_ui_enabled || { echo "管理面板未启用" >&2; return 1; }
    if lb_should_run; then LB_ACTIVE=1; else LB_ACTIVE=0; fi
    export_control_environment
    export LB_ACTIVE
    [[ "$ACTION" = "add" ]] && return 0
    if [[ "$ACTION" = "remove" ]] && [[ "$INSTANCE_ID" =~ ^[0-9]+$ ]] && grep -qx "$INSTANCE_ID" "$MICROWARP_DYNAMIC_INSTANCES_FILE" 2>/dev/null; then
        return 0
    fi
    runtime_instance_exists "$INSTANCE_ID" || {
        echo "实例 ID 非法：${INSTANCE_ID}" >&2
        return 1
    }
    [[ ! -d "${RUNTIME_ROOT}/rotate-restart.lock" ]] || {
        echo "滚动重启正在执行，请稍后再试" >&2
        return 1
    }
}

dynamic_lock_dir() { printf '%s/instances.dynamic.lock' "$RUNTIME_ROOT"; }

dynamic_ids() {
    [ -f "$MICROWARP_DYNAMIC_INSTANCES_FILE" ] || return 0
    awk '/^[0-9]+$/ { print }' "$MICROWARP_DYNAMIC_INSTANCES_FILE" | sort -n -u
}

rebuild_active_backends() {
    local id temporary
    temporary="${RUNTIME_ROOT}/backends.txt.$$"
    : > "$temporary"
    # 与健康守护保持相同的单次扫描策略，避免大量后端状态更新时反复启动 awk。
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        instance_backend_addr "$id" >> "$temporary"
    done < <(awk -F= '$1 ~ /^[0-9]+$/ && $2 == "up" { print $1 }' "${BACKENDS_META_FILE:-${RUNTIME_ROOT}/backends.meta}" 2>/dev/null | sort -n -u)
    mv "$temporary" "${LB_BACKENDS_FILE:-${RUNTIME_ROOT}/backends.txt}"
}

start_initial_probe() {
    local id="$1"
    # 动态实例已登记到运行时清单后即可被健康脚本识别。探测在后台执行，不能
    # 因可选双栈观测的超时阻塞“批量添加”队列；最终结果采用与其他重连一致的
    # ready 条件：新鲜 WARP 主探测通过且后端池同步确认 up。
    (
        INSTANCE_ID="$id"
        write_operation "probing" "临时实例已启动，正在确认 WARP 就绪并重新入池" "" "" "warp-probe"
        mark_operation_milestone_once "warp_probe_started_at"
        if MANAGEMENT_FORCE_PROBE=1 "$HEALTH_CHECK_COMMAND" ready "$id" \
            >>"$(management_log_file)" 2>&1; then
            mark_operation_milestone "warp_ready_at"
            mark_operation_milestone "pool_rejoined_at"
            write_operation "success" "临时实例已通过 WARP 探测并确认加入后端池" "" "" "completed"
        else
            mark_operation_milestone "probe_timed_out_at"
            record_failure "warp-probe" "warp-probe-failed" "临时实例 WARP 健康探测或后端池确认失败，已保持摘流"
        fi
    ) &
}

add_instance() {
    local id current_count
    [[ "$INSTANCE_COUNT" -gt 1 ]] || {
        echo "临时实例需要先以 INSTANCE_COUNT>=2 启动容器" >&2
        return 1
    }
    [[ "$INSTANCE_COUNT" -lt 255 ]] || {
        echo "实例数量已达 255 上限，无法再添加临时实例" >&2
        return 1
    }
    mkdir -p "$RUNTIME_ROOT"
    if ! mkdir "$(dynamic_lock_dir)" 2>/dev/null; then
        echo "已有实例增减操作正在执行" >&2
        return 1
    fi
    id="$INSTANCE_COUNT"
    while grep -qx "$id" "$MICROWARP_DYNAMIC_INSTANCES_FILE" 2>/dev/null; do
        id=$((id + 1))
    done
    [[ "$id" -le 254 ]] || {
        rm -rf "$(dynamic_lock_dir)"
        echo "实例数量已达 255 上限，无法再添加临时实例" >&2
        return 1
    }
    printf '%s\n' "$id" >> "$MICROWARP_DYNAMIC_INSTANCES_FILE"
    INSTANCE_ID="$id"
    # 已移除后重新使用的临时编号不能携带上一次实例生命周期的阶段时间。
    reset_operation_milestones
    write_operation "starting" "正在创建并启动临时实例" "" "" "instance-start"
    mark_operation_milestone "instance_start_started_at"
    # 动态实例使用与多实例相同的网络命名空间和内部端口布局。
    current_count="$INSTANCE_COUNT"
    INSTANCE_COUNT=$((id + 1))
    export INSTANCE_COUNT
    if ! start_instance "$id"; then
        record_failure "instance-start" "instance-start-failed" "临时实例启动失败"
        return 1
    fi
    mark_operation_milestone "instance_started_at"
    INSTANCE_COUNT="$current_count"
    export INSTANCE_COUNT
    write_all_backends
    start_initial_probe "$id"
    rm -rf "$(dynamic_lock_dir)"
    printf '%s\n' "$id"
}

remove_instance() {
    local id="$1" current_count
    [[ "$id" =~ ^[0-9]+$ ]] || { echo "实例 ID 非法" >&2; return 1; }
    grep -qx "$id" "$MICROWARP_DYNAMIC_INSTANCES_FILE" 2>/dev/null || {
        echo "仅支持移除临时实例，基础实例不可移除" >&2
        return 1
    }
    current_count="$INSTANCE_COUNT"
    INSTANCE_COUNT=$((id + 1))
    INSTANCE_ID="$id"
    # 仅在确认空闲后才摘流，繁忙临时实例会继续服务并进入延后队列。
    claim_idle_backend "移除临时实例" || return 1
    write_operation "stopping" "正在停止并移除临时实例" "" "" "instance-stop"
    mark_operation_milestone "instance_stop_started_at"
    if ! stop_instance "$id"; then
        record_failure "instance-stop" "instance-stop-failed" "临时实例停止失败"
        return 1
    fi
    mark_operation_milestone "instance_stopped_at"
    INSTANCE_COUNT="$current_count"
    grep -vx "$id" "$MICROWARP_DYNAMIC_INSTANCES_FILE" > "${MICROWARP_DYNAMIC_INSTANCES_FILE}.tmp" || true
    mv "${MICROWARP_DYNAMIC_INSTANCES_FILE}.tmp" "$MICROWARP_DYNAMIC_INSTANCES_FILE"
    sed -i "\|^${id}=|d" "${BACKENDS_META_FILE:-${RUNTIME_ROOT}/backends.meta}" 2>/dev/null || true
    write_all_backends
    rebuild_active_backends
    write_operation "success" "临时实例已移除" "" "" "completed"
}

disable_instance() {
    claim_idle_backend "停用实例" || return 1
    touch "$(disabled_file)"
    write_operation "stopping" "正在停止实例与隧道" "" "" "instance-stop"
    mark_operation_milestone "instance_stop_started_at"
    if ! stop_instance "$INSTANCE_ID"; then
        record_failure "instance-stop" "instance-stop-failed" "实例停止失败"
        return 1
    fi
    mark_operation_milestone "instance_stopped_at"
    printf 'disabled checked_at=%s\n' "$(date +%s)" > "$(runtime_dir)/health.state"
}

enable_instance() {
    rm -f "$(disabled_file)"
    if instance_running; then
        write_operation "starting" "实例已在运行，等待 WARP 健康探测" "" "" "instance-start"
    else
        write_operation "starting" "正在启动实例" "" "" "instance-start"
        mark_operation_milestone "instance_start_started_at"
        if ! start_instance "$INSTANCE_ID"; then
            record_failure "instance-start" "instance-start-failed" "实例启动失败"
            return 1
        fi
        mark_operation_milestone "instance_started_at"
    fi
    if ! wait_ready; then
        set_pool down || true
        return 1
    fi
}

reconnect_instance() {
    [[ ! -f "$(disabled_file)" ]] || {
        echo "实例已停用，请先启用" >&2
        return 1
    }
    touch "$(restarting_file)"
    claim_idle_backend "优雅重连" || return 1
    if ! restart_instance_and_confirm_ready "优雅重连"; then
        set_pool down || true
        return 1
    fi
}

force_reconnect_instance() {
    [[ ! -f "$(disabled_file)" ]] || {
        echo "实例已停用，请先启用" >&2
        return 1
    }
    touch "$(restarting_file)"
    # 先摘流以避免新会话继续进入该实例；随后立即停止，现有连接会被中断。
    write_operation "reconnecting" "正在从后端池摘流，随后强制重建 WARP 连接（现有连接将中断）" "" "" "backend-drain"
    if ! set_pool_with_retry down "强制重连" "backend-drain"; then
        record_failure "backend-drain" "${BACKEND_POOL_LAST_FAILURE_CODE:-backend-pool-update-failed}" "无法确认实例已从后端池摘流"
        return 1
    fi
    mark_operation_milestone "backend_drained_at"
    write_operation "reconnecting" "后端池已确认摘流，正在强制重建 WARP 连接" "" "" "backend-drain"
    if ! restart_instance_and_confirm_ready "强制重连"; then
        set_pool down || true
        return 1
    fi
}

main() {
    if [[ "$ACTION" = "add" ]]; then
        validate_request
        trap 'rm -rf "$(dynamic_lock_dir)"' EXIT
        add_instance
        trap - EXIT
        return 0
    fi
    if [[ "$ACTION" = "remove" ]]; then
        validate_request
        if ! mkdir "$(dynamic_lock_dir)" 2>/dev/null; then
            echo "已有实例增减操作正在执行" >&2
            return 1
        fi
        trap 'rm -rf "$(dynamic_lock_dir)"' EXIT
        reset_operation_milestones
        write_operation "running" "已接收管理操作" "" "" "received"
        remove_instance "$INSTANCE_ID"
        trap - EXIT
        rm -rf "$(dynamic_lock_dir)"
        return 0
    fi
    validate_request
    acquire_lock || { echo "实例正在执行其他管理操作" >&2; exit 75; }
    trap release_lock EXIT
    reset_operation_milestones
    write_operation "running" "已接收管理操作" "" "" "received"

    case "$ACTION" in
        disable) action_handler=disable_instance ;;
        enable) action_handler=enable_instance ;;
        reconnect) action_handler=reconnect_instance ;;
        force-reconnect) action_handler=force_reconnect_instance ;;
        *) echo "用法: $0 {add|remove|disable|enable|reconnect|force-reconnect} <实例ID>" >&2; exit 64 ;;
    esac
    if ! "$action_handler"; then
        if [[ "$OPERATION_FAILURE_RECORDED" -ne 1 ]]; then
            record_failure "unknown" "operation-failed" "管理操作异常结束，请查看本次日志"
        fi
        exit 1
    fi
    write_operation "success" "操作完成" "" "" "completed"
    ok "实例=${INSTANCE_ID} 管理操作完成 | 动作=${ACTION}"
}

if [[ "${MANAGEMENT_CONTROL_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
