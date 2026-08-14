#!/usr/bin/env bash
# 多实例滚动重启：空闲优先、繁忙延后、限并发调度与单飞锁。
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log-utils.sh
source "${APP_DIR}/log-utils.sh"

INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
RUNTIME_ROOT="${MICROWARP_RUNTIME_ROOT:-/run/microwarp}"
MICROWARP_DYNAMIC_INSTANCES_FILE="${MICROWARP_DYNAMIC_INSTANCES_FILE:-${RUNTIME_ROOT}/instances.dynamic}"
BACKENDS_META_FILE="${BACKENDS_META_FILE:-${RUNTIME_ROOT}/backends.meta}"
CONNECTION_FILE="${LB_CONNECTION_STATE_FILE:-${RUNTIME_ROOT}/lb-connections.txt}"
BACKEND_LOCK_DIR="${RUNTIME_ROOT}/backends.lock"
LOCK_DIR="${RUNTIME_ROOT}/rotate-restart.lock"
SCHEDULE_STATE_FILE="${RUNTIME_ROOT}/rotate-restart.schedule.state"
SCHEDULE_PAUSE_FILE="${RUNTIME_ROOT}/rotate-restart.paused"
HISTORY_ROOT="${RUNTIME_ROOT}/rotate-restart.history"
HISTORY_RUNS_DIR="${HISTORY_ROOT}/runs"
ENABLED="${ROTATE_RESTART_ENABLED:-auto}"
INTERVAL="${ROTATE_RESTART_INTERVAL:-6h}"
PROBE_TIMEOUT="${ROTATE_RESTART_PROBE_TIMEOUT:-90}"
RETRIES="${ROTATE_RESTART_RETRIES:-2}"
# auto 表示按当前实例总数的 1/5 并行，至少一个；可设置正整数显式覆盖。
CONCURRENCY="${ROTATE_RESTART_CONCURRENCY:-auto}"
# 繁忙实例保留服务并进入延后队列；默认每分钟重新检查一次连接数。
DEFERRED_CHECK_INTERVAL="${ROTATE_RESTART_DEFERRED_CHECK_INTERVAL:-60}"
# 每轮结果和失败明细仅保留最近若干轮，避免运行时目录无限增长。
HISTORY_LIMIT="${ROTATE_RESTART_HISTORY_LIMIT:-20}"
[[ "$HISTORY_LIMIT" =~ ^[0-9]+$ ]] && [[ "$HISTORY_LIMIT" -ge 1 ]] || HISTORY_LIMIT=20
# 以下两个覆盖项仅供隔离测试使用；正常容器保持默认的应用脚本路径。
INSTANCE_CTL="${MICROWARP_INSTANCE_CTL:-${APP_DIR}/instance-ctl.sh}"
HEALTH_CHECK="${MICROWARP_HEALTH_CHECK:-${APP_DIR}/health-check.sh}"

# Bash 3 兼容：不能使用 wait -n，因此由调度器轮询已完成的子进程并立即补位。
ROTATE_WORKER_PIDS=()
ROTATE_WORKER_IDS=()
LOCK_HELD=0
# 调度状态是管理页面的只读数据源。运行时目录会随容器生命周期清理，因此
# “暂停”与最近一轮结果也遵循同一生命周期，不会意外修改用户的环境变量配置。
SCHEDULE_INTERVAL_SECONDS=0
SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS=60
SCHEDULE_NEXT_RUN_AT=0
SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
SCHEDULE_STATUS="starting"
SCHEDULE_RUNNING="no"
SCHEDULE_ROUND_STARTED_AT=0
SCHEDULE_SCOPE_COUNT=0
SCHEDULE_ELIGIBLE_COUNT=0
SCHEDULE_CURRENT_TOTAL=0
SCHEDULE_CURRENT_QUEUED=0
SCHEDULE_CURRENT_RUNNING=0
SCHEDULE_CURRENT_COMPLETED=0
SCHEDULE_CURRENT_SUCCEEDED=0
SCHEDULE_CURRENT_FAILED=0
SCHEDULE_CURRENT_SKIPPED=0
SCHEDULE_CURRENT_DEFERRED=0
SCHEDULE_CURRENT_DEFERRED_TOTAL=0
SCHEDULE_CURRENT_DEFERRED_CONNECTIONS=0
SCHEDULE_CURRENT_MAX_QUEUED=0
SCHEDULE_CURRENT_MAX_DEFERRED=0
SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS=0
SCHEDULE_CURRENT_DEFERRED_COMPLETED=0
SCHEDULE_CURRENT_RUN_ID=""
SCHEDULE_LAST_RUN_AT=0
SCHEDULE_LAST_COMPLETED_AT=0
SCHEDULE_LAST_DURATION_SECONDS=0
SCHEDULE_LAST_STATUS=""
SCHEDULE_LAST_TOTAL=0
SCHEDULE_LAST_SUCCEEDED=0
SCHEDULE_LAST_FAILED=0
SCHEDULE_LAST_SKIPPED=0
# 繁忙实例不属于失败；它们在本轮的后续复查中保留在延后队列。
SCHEDULE_LAST_DEFERRED=0
SCHEDULE_LAST_MAX_QUEUED=0
SCHEDULE_LAST_MAX_DEFERRED=0
SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=0
SCHEDULE_LAST_RUN_ID=""
SCHEDULE_LAST_WORKER_RESULT="success"
SCHEDULE_LAST_WORKER_ID=""
SCHEDULE_QUEUE_IDS=()
# 本轮两个队列使用全局数组，避免 Bash 3 在 set -u 下跨函数访问局部空数组时触发未绑定变量。
ROUND_READY=()
ROUND_DEFERRED=()
ROUND_NEXT=0
RESTART_INELIGIBLE_CODE=""
RESTART_INELIGIBLE_MESSAGE=""

log() { mw_info "滚动重启" "$*"; }
ok() { mw_ok "滚动重启" "$*"; }
warn() { mw_warn "滚动重启" "$*"; }

runtime_instance_ids() {
    local id
    seq 0 $((INSTANCE_COUNT - 1))
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [ "$id" -ge "$INSTANCE_COUNT" ] && printf '%s\n' "$id"
    done < "$MICROWARP_DYNAMIC_INSTANCES_FILE" 2>/dev/null | sort -n -u
}

parse_duration() {
    local raw="${1// /}" number unit
    if [[ "$raw" =~ ^[0-9]+$ ]]; then printf '%s\n' "$raw"; return 0; fi
    if [[ "$raw" =~ ^([0-9]+)([smhdSMHD])$ ]]; then
        number="${BASH_REMATCH[1]}"; unit="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')"
        case "$unit" in s) echo "$number";; m) echo $((number*60));; h) echo $((number*3600));; d) echo $((number*86400));; esac
        return 0
    fi
    return 1
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

enabled() {
    case "$(lowercase "$ENABLED")" in
        1|true|yes|on) return 0 ;;
        0|false|no|off) return 1 ;;
        *) [[ "$INSTANCE_COUNT" -ge 4 ]] ;;
    esac
}

effective_concurrency() {
    local total="$1" requested value
    requested="$(lowercase "$CONCURRENCY")"
    [[ "$total" =~ ^[0-9]+$ ]] && [[ "$total" -gt 0 ]] || { printf '1\n'; return; }
    case "$requested" in
        auto|'')
            # 100 个实例时为 20；小于 5 个实例时仍保证有一个实例可滚动重启。
            value=$((total / 5))
            [[ "$value" -ge 1 ]] || value=1
            ;;
        *)
            if [[ "$requested" =~ ^[0-9]+$ ]] && [[ "$requested" -ge 1 ]]; then
                value="$requested"
            else
                warn "并行数量配置无效，回退为 auto | 配置=${CONCURRENCY}" >&2
                value=$((total / 5))
                [[ "$value" -ge 1 ]] || value=1
            fi
            ;;
    esac
    [[ "$value" -le "$total" ]] || value="$total"
    printf '%s\n' "$value"
}

schedule_paused() {
    [[ -f "$SCHEDULE_PAUSE_FILE" ]]
}

schedule_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { value=substr($0, index($0, "=") + 1) } END { print value }' \
        "$SCHEDULE_STATE_FILE" 2>/dev/null || true
}

schedule_integer() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf '0\n'
}

schedule_text() {
    # 状态文件是 key=value 格式；诊断文本只保留单行，避免破坏其解析边界。
    printf '%s' "$1" | tr '\r\n=' '   '
}

run_history_dir() {
    printf '%s/%s\n' "$HISTORY_RUNS_DIR" "$1"
}

run_history_summary_file() {
    printf '%s/summary.state\n' "$(run_history_dir "$1")"
}

prepare_run_history() {
    local run_id="$1"
    mkdir -p "$(run_history_dir "$run_id")/failures" "$(run_history_dir "$run_id")/skipped"
}

write_run_failure() {
    local id="$1" phase="$2" reason_code="$3" message="$4" attempt="$5" total_attempts="$6"
    local active="$7" started_at="$8" finished_at="$9" target temporary
    [[ -n "$SCHEDULE_CURRENT_RUN_ID" ]] || return 0
    target="$(run_history_dir "$SCHEDULE_CURRENT_RUN_ID")/failures/${id}.state"
    mkdir -p "$(dirname "$target")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'run_id=%s\ninstance_id=%s\nstatus=failed\nphase=%s\nreason_code=%s\n' \
            "$SCHEDULE_CURRENT_RUN_ID" "$id" "$phase" "$reason_code"
        printf 'reason=%s\nattempt=%s\nmax_attempts=%s\nactive_connections=%s\nstarted_at=%s\nfinished_at=%s\n' \
            "$(schedule_text "$message")" "$attempt" "$total_attempts" "$active" "$started_at" "$finished_at"
        printf 'log_reference=rotate.log\n'
    } > "$temporary"
    mv "$temporary" "$target"
}

write_run_skipped() {
    local id="$1" reason_code="$2" message="$3" active="$4" target temporary
    [[ -n "$SCHEDULE_CURRENT_RUN_ID" ]] || return 0
    target="$(run_history_dir "$SCHEDULE_CURRENT_RUN_ID")/skipped/${id}.state"
    mkdir -p "$(dirname "$target")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'run_id=%s\ninstance_id=%s\nstatus=skipped\nreason_code=%s\nreason=%s\n' \
            "$SCHEDULE_CURRENT_RUN_ID" "$id" "$reason_code" "$(schedule_text "$message")"
        printf 'active_connections=%s\nfinished_at=%s\n' "$active" "$(date +%s)"
    } > "$temporary"
    mv "$temporary" "$target"
}

write_run_history_summary() {
    local run_id="$1" target temporary
    [[ -n "$run_id" ]] || return 0
    target="$(run_history_summary_file "$run_id")"
    mkdir -p "$(dirname "$target")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'version=1\nrun_id=%s\nstatus=%s\n' "$run_id" "$SCHEDULE_LAST_STATUS"
        printf 'started_at=%s\ncompleted_at=%s\nduration_seconds=%s\n' \
            "$SCHEDULE_LAST_RUN_AT" "$SCHEDULE_LAST_COMPLETED_AT" "$SCHEDULE_LAST_DURATION_SECONDS"
        printf 'total=%s\nsucceeded=%s\nfailed=%s\nskipped=%s\ndeferred=%s\n' \
            "$SCHEDULE_LAST_TOTAL" "$SCHEDULE_LAST_SUCCEEDED" "$SCHEDULE_LAST_FAILED" \
            "$SCHEDULE_LAST_SKIPPED" "$SCHEDULE_LAST_DEFERRED"
        printf 'max_queued=%s\nmax_deferred=%s\navg_deferred_wait_seconds=%s\n' \
            "$SCHEDULE_LAST_MAX_QUEUED" "$SCHEDULE_LAST_MAX_DEFERRED" "$SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS"
        printf 'configured_concurrency=%s\ndeferred_check_interval_seconds=%s\n' \
            "$CONCURRENCY" "$SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS"
    } > "$temporary"
    mv "$temporary" "$target"
}

prune_run_history() {
    local path index=0
    local -a runs=()
    [[ -d "$HISTORY_RUNS_DIR" ]] || return 0
    while read -r path; do
        [[ -n "$path" ]] && runs+=("$path")
    done < <(find "$HISTORY_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
    while [[ "${#runs[@]}" -gt "$HISTORY_LIMIT" ]]; do
        rm -rf "${runs[$index]}"
        index=$((index + 1))
        if [[ "$index" -ge "${#runs[@]}" ]]; then
            break
        fi
        runs=("${runs[@]:$index}")
        index=0
    done
}

update_queue_metrics() {
    local id active total_connections=0
    SCHEDULE_CURRENT_QUEUED=$(( ${#ROUND_READY[@]} - ROUND_NEXT ))
    SCHEDULE_CURRENT_DEFERRED="${#ROUND_DEFERRED[@]}"
    for id in "${ROUND_DEFERRED[@]-}"; do
        [[ -n "$id" ]] || continue
        active="$(active_connections "$id")"
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
        total_connections=$((total_connections + active))
    done
    SCHEDULE_CURRENT_DEFERRED_CONNECTIONS="$total_connections"
    [[ "$SCHEDULE_CURRENT_QUEUED" -le "$SCHEDULE_CURRENT_MAX_QUEUED" ]] || SCHEDULE_CURRENT_MAX_QUEUED="$SCHEDULE_CURRENT_QUEUED"
    [[ "$SCHEDULE_CURRENT_DEFERRED" -le "$SCHEDULE_CURRENT_MAX_DEFERRED" ]] || SCHEDULE_CURRENT_MAX_DEFERRED="$SCHEDULE_CURRENT_DEFERRED"
}

load_schedule_history() {
    # 单次执行也应保留上一轮结果；守护进程内后续写入则沿用全局变量。
    SCHEDULE_LAST_RUN_AT="$(schedule_integer "$(schedule_value last_run_at)")"
    SCHEDULE_LAST_COMPLETED_AT="$(schedule_integer "$(schedule_value last_completed_at)")"
    SCHEDULE_LAST_DURATION_SECONDS="$(schedule_integer "$(schedule_value last_duration_seconds)")"
    SCHEDULE_LAST_STATUS="$(schedule_value last_status)"
    SCHEDULE_LAST_TOTAL="$(schedule_integer "$(schedule_value last_total)")"
    SCHEDULE_LAST_SUCCEEDED="$(schedule_integer "$(schedule_value last_succeeded)")"
    SCHEDULE_LAST_FAILED="$(schedule_integer "$(schedule_value last_failed)")"
    SCHEDULE_LAST_SKIPPED="$(schedule_integer "$(schedule_value last_skipped)")"
    SCHEDULE_LAST_DEFERRED="$(schedule_integer "$(schedule_value last_deferred)")"
    SCHEDULE_LAST_MAX_QUEUED="$(schedule_integer "$(schedule_value last_max_queued)")"
    SCHEDULE_LAST_MAX_DEFERRED="$(schedule_integer "$(schedule_value last_max_deferred)")"
    SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS="$(schedule_integer "$(schedule_value last_avg_deferred_wait_seconds)")"
    SCHEDULE_LAST_RUN_ID="$(schedule_value last_run_id)"
}

write_schedule_state() {
    local configured active paused temporary
    mkdir -p "$RUNTIME_ROOT"
    configured="$(lowercase "$ENABLED")"
    active=no
    enabled && active=yes
    paused=no
    schedule_paused && paused=yes
    temporary="${SCHEDULE_STATE_FILE}.${BASHPID:-$$}"
    {
        printf 'version=3\n'
        printf 'configured_enabled=%s\n' "$configured"
        printf 'config_active=%s\n' "$active"
        printf 'paused=%s\n' "$paused"
        printf 'interval=%s\ninterval_seconds=%s\ndeferred_check_interval=%s\ndeferred_check_interval_seconds=%s\n' \
            "$INTERVAL" "$SCHEDULE_INTERVAL_SECONDS" "$DEFERRED_CHECK_INTERVAL" "$SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS"
        printf 'status=%s\nrunning=%s\ncurrent_run_id=%s\nnext_run_at=%s\nnext_deferred_check_at=%s\n' \
            "$SCHEDULE_STATUS" "$SCHEDULE_RUNNING" "$SCHEDULE_CURRENT_RUN_ID" "$SCHEDULE_NEXT_RUN_AT" "$SCHEDULE_NEXT_DEFERRED_CHECK_AT"
        printf 'round_started_at=%s\nscope_count=%s\neligible_count=%s\n' \
            "$SCHEDULE_ROUND_STARTED_AT" "$SCHEDULE_SCOPE_COUNT" "$SCHEDULE_ELIGIBLE_COUNT"
        printf 'current_total=%s\ncurrent_queued=%s\ncurrent_running=%s\ncurrent_completed=%s\ncurrent_succeeded=%s\ncurrent_failed=%s\ncurrent_skipped=%s\ncurrent_deferred=%s\ncurrent_deferred_connections=%s\ncurrent_max_queued=%s\ncurrent_max_deferred=%s\n' \
            "$SCHEDULE_CURRENT_TOTAL" "$SCHEDULE_CURRENT_QUEUED" "$SCHEDULE_CURRENT_RUNNING" "$SCHEDULE_CURRENT_COMPLETED" \
            "$SCHEDULE_CURRENT_SUCCEEDED" "$SCHEDULE_CURRENT_FAILED" "$SCHEDULE_CURRENT_SKIPPED" \
            "$SCHEDULE_CURRENT_DEFERRED" "$SCHEDULE_CURRENT_DEFERRED_CONNECTIONS" \
            "$SCHEDULE_CURRENT_MAX_QUEUED" "$SCHEDULE_CURRENT_MAX_DEFERRED"
        printf 'last_run_id=%s\nlast_run_at=%s\nlast_completed_at=%s\nlast_duration_seconds=%s\nlast_status=%s\nlast_total=%s\nlast_succeeded=%s\nlast_failed=%s\nlast_skipped=%s\nlast_deferred=%s\nlast_max_queued=%s\nlast_max_deferred=%s\nlast_avg_deferred_wait_seconds=%s\n' \
            "$SCHEDULE_LAST_RUN_ID" \
            "$SCHEDULE_LAST_RUN_AT" "$SCHEDULE_LAST_COMPLETED_AT" "$SCHEDULE_LAST_DURATION_SECONDS" "$SCHEDULE_LAST_STATUS" \
            "$SCHEDULE_LAST_TOTAL" "$SCHEDULE_LAST_SUCCEEDED" "$SCHEDULE_LAST_FAILED" "$SCHEDULE_LAST_SKIPPED" \
            "$SCHEDULE_LAST_DEFERRED" "$SCHEDULE_LAST_MAX_QUEUED" "$SCHEDULE_LAST_MAX_DEFERRED" "$SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS"
        printf 'configured_concurrency=%s\nhistory_limit=%s\nupdated_at=%s\n' "$CONCURRENCY" "$HISTORY_LIMIT" "$(date +%s)"
    } > "$temporary"
    mv "$temporary" "$SCHEDULE_STATE_FILE"
}

set_schedule_waiting() {
    SCHEDULE_STATUS="waiting"
    SCHEDULE_RUNNING="no"
    SCHEDULE_ROUND_STARTED_AT=0
    SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
    SCHEDULE_CURRENT_TOTAL=0
    SCHEDULE_CURRENT_QUEUED=0
    SCHEDULE_CURRENT_RUNNING=0
    SCHEDULE_CURRENT_COMPLETED=0
    SCHEDULE_CURRENT_SUCCEEDED=0
    SCHEDULE_CURRENT_FAILED=0
    SCHEDULE_CURRENT_SKIPPED=0
    SCHEDULE_CURRENT_DEFERRED=0
    SCHEDULE_CURRENT_DEFERRED_TOTAL=0
    SCHEDULE_CURRENT_DEFERRED_CONNECTIONS=0
    SCHEDULE_CURRENT_MAX_QUEUED=0
    SCHEDULE_CURRENT_MAX_DEFERRED=0
    SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS=0
    SCHEDULE_CURRENT_DEFERRED_COMPLETED=0
    SCHEDULE_CURRENT_RUN_ID=""
    write_schedule_state
}

backend_for() { printf '10.64.%s.2:1080\n' "$1"; }

rebuild_backends() {
    local id temporary
    temporary="${RUNTIME_ROOT}/backends.txt.$$"
    : > "$temporary"
    # 单次扫描元数据，缩短滚动重启摘流时持有全局后端锁的时间。
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        backend_for "$id" >> "$temporary"
    done < <(awk -F= '$1 ~ /^[0-9]+$/ && $2 == "up" { print $1 }' "$BACKENDS_META_FILE" 2>/dev/null | sort -n -u)
    mv "$temporary" "${RUNTIME_ROOT}/backends.txt"
}

set_backend() {
    local id="$1" status="$2" temporary attempt=0
    while ! mkdir "$BACKEND_LOCK_DIR" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ "$attempt" -ge 100 ]]; then
            warn "更新后端池锁超时 | 实例=${id} | 状态=${status}"
            return 1
        fi
        sleep 0.05
    done
    touch "$BACKENDS_META_FILE"
    temporary="${BACKENDS_META_FILE}.$$"
    grep -v "^${id}=" "$BACKENDS_META_FILE" > "$temporary" 2>/dev/null || true
    printf '%s=%s\n' "$id" "$status" >> "$temporary"
    mv "$temporary" "$BACKENDS_META_FILE"
    rebuild_backends
    rmdir "$BACKEND_LOCK_DIR" 2>/dev/null || true
}

active_connections() {
    local backend
    backend="$(backend_for "$1")"
    awk -F '\t' -v backend="$backend" '$1 == backend {print $2; exit}' "$CONNECTION_FILE" 2>/dev/null || echo 0
}

rotation_state_file() {
    printf '%s/instances/%s/rotation.state\n' "$RUNTIME_ROOT" "$1"
}

scheduled_restart_state_file() {
    printf '%s/instances/%s/scheduled-restart.state\n' "$RUNTIME_ROOT" "$1"
}

write_scheduled_restart_state() {
    local id="$1" position="$2" total="$3" started_at="$4" queued_at="${5:-$(date +%s)}" target temporary
    target="$(scheduled_restart_state_file "$id")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'action=scheduled-rolling-restart\nstatus=queued\n'
        printf 'message=等待本轮定时滚动重启\n'
        printf 'queue=ready\nqueue_position=%s\nqueue_total=%s\nstarted_at=%s\nqueue_entered_at=%s\nupdated_at=%s\n' \
            "$position" "$total" "$started_at" "$queued_at" "$(date +%s)"
    } > "$temporary"
    mv "$temporary" "$target"
}

scheduled_restart_value() {
    local id="$1" key="$2"
    awk -F= -v key="$key" '$1 == key { value=substr($0, index($0, "=") + 1) } END { print value }' \
        "$(scheduled_restart_state_file "$id")" 2>/dev/null || true
}

write_deferred_restart_state() {
    local id="$1" active="$2" started_at="$3" next_check_at="$4" deferred_at="${5:-}" target temporary
    [[ "$deferred_at" =~ ^[0-9]+$ ]] || deferred_at="$(scheduled_restart_value "$id" deferred_at)"
    [[ "$deferred_at" =~ ^[0-9]+$ ]] || deferred_at="$(date +%s)"
    target="$(scheduled_restart_state_file "$id")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'action=scheduled-rolling-restart\nstatus=deferred\n'
        printf 'message=当前有 %s 条活跃连接，保留服务并等待自然空闲\n' "$active"
        printf 'queue=deferred\nactive_connections=%s\nstarted_at=%s\ndeferred_at=%s\nnext_check_at=%s\nupdated_at=%s\n' \
            "$active" "$started_at" "$deferred_at" "$next_check_at" "$(date +%s)"
    } > "$temporary"
    mv "$temporary" "$target"
}

clear_scheduled_restart_state() {
    rm -f "$(scheduled_restart_state_file "$1")"
}

clear_scheduled_restart_queue() {
    local id
    if [[ "${#SCHEDULE_QUEUE_IDS[@]}" -gt 0 ]]; then
        for id in "${SCHEDULE_QUEUE_IDS[@]}"; do
            clear_scheduled_restart_state "$id"
        done
    fi
    SCHEDULE_QUEUE_IDS=()
}

remove_scheduled_restart_queue_id() {
    local id="$1" queued index
    local -a remaining=()
    for index in "${!SCHEDULE_QUEUE_IDS[@]}"; do
        queued="${SCHEDULE_QUEUE_IDS[$index]}"
        [[ "$queued" = "$id" ]] || remaining+=("$queued")
    done
    if [[ "${#remaining[@]}" -gt 0 ]]; then
        SCHEDULE_QUEUE_IDS=("${remaining[@]}")
    else
        SCHEDULE_QUEUE_IDS=()
    fi
}

write_rotation_state() {
    local id="$1" status="$2" message="$3" started_at="$4" active="${5:-}"
    local attempt="${6:-}" total_attempts="${7:-}" target temporary
    target="$(rotation_state_file "$id")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'action=rolling-restart\nstatus=%s\nmessage=%s\nstarted_at=%s\nupdated_at=%s\n' \
            "$status" "$message" "$started_at" "$(date +%s)"
        [[ -n "$active" ]] && printf 'active_connections=%s\n' "$active"
        [[ -n "$attempt" ]] && printf 'attempt=%s\n' "$attempt"
        [[ -n "$total_attempts" ]] && printf 'total_attempts=%s\n' "$total_attempts"
    } > "$temporary"
    mv "$temporary" "$target"
}

clear_rotation_state() {
    local id="$1"
    rm -f "${RUNTIME_ROOT}/instances/${id}/rotating" "$(rotation_state_file "$id")"
}

probe_ready() {
    local id="$1" started_at="$2" attempt="$3" total_attempts="$4" deadline
    deadline=$(( $(date +%s) + PROBE_TIMEOUT ))
    write_rotation_state "$id" "probing" "正在等待 WARP 健康探测（第 ${attempt}/${total_attempts} 次）" "$started_at" "" "$attempt" "$total_attempts"
    while [[ "$(date +%s)" -lt "$deadline" ]]; do
        # 复用健康守护的双栈探测与状态写入，避免滚动重启覆盖 ip4/ip6 元数据。
        if MANAGEMENT_FORCE_PROBE=1 "$HEALTH_CHECK" probe "$id" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

restart_eligible() {
    local id="$1" state pool
    RESTART_INELIGIBLE_CODE=""
    RESTART_INELIGIBLE_MESSAGE=""
    if [[ -f "${RUNTIME_ROOT}/instances/${id}/manual.disabled" ]]; then
        RESTART_INELIGIBLE_CODE="manual-disabled"
        RESTART_INELIGIBLE_MESSAGE="实例已被手工停用"
        log "实例=${id} 已由管理面板停用，跳过滚动重启"
        return 1
    fi
    if [[ -d "${RUNTIME_ROOT}/instances/${id}/management.lock" ]]; then
        RESTART_INELIGIBLE_CODE="manual-operation"
        RESTART_INELIGIBLE_MESSAGE="实例正在执行手工管理操作"
        log "实例=${id} 正在执行管理操作，跳过滚动重启"
        return 1
    fi
    if [[ -f "${RUNTIME_ROOT}/instances/${id}/rotating" || -f "${RUNTIME_ROOT}/instances/${id}/restarting" ]]; then
        RESTART_INELIGIBLE_CODE="already-restarting"
        RESTART_INELIGIBLE_MESSAGE="实例已处于其他重启流程"
        log "实例=${id} 已在重启流程中，跳过滚动重启"
        return 1
    fi
    state="$(cat "${RUNTIME_ROOT}/instances/${id}/health.state" 2>/dev/null || true)"
    if [[ "$state" != ready\ * ]]; then
        RESTART_INELIGIBLE_CODE="not-ready"
        RESTART_INELIGIBLE_MESSAGE="实例当前未就绪"
        log "实例=${id} 当前未就绪，跳过滚动重启 | 状态=${state:-unknown}"
        return 1
    fi
    pool="$(awk -F= -v id="$id" '$1 == id { value=$2 } END { print value }' "$BACKENDS_META_FILE" 2>/dev/null)"
    if [[ "$pool" != "up" ]]; then
        RESTART_INELIGIBLE_CODE="not-in-pool"
        RESTART_INELIGIBLE_MESSAGE="实例当前未在健康后端池"
        log "实例=${id} 当前未在后端池，跳过滚动重启 | 后端=${pool:-unknown}"
        return 1
    fi
    return 0
}

next_deferred_check_at() {
    printf '%s\n' "$(( $(date +%s) + SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS ))"
}

rotate_one() {
    local id="$1" attempt total_attempts active next_check_at recovered=0 started_at restart_exit=0 last_restart_exit=0
    # 任务从队列取出到真正执行之间，管理面可能改变了实例状态；在此再次确认。
    if ! restart_eligible "$id"; then
        active="$(active_connections "$id")"
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
        write_run_skipped "$id" "${RESTART_INELIGIBLE_CODE:-ineligible}" "${RESTART_INELIGIBLE_MESSAGE:-实例不满足本轮处理条件}" "$active"
        return 3
    fi
    active="$(active_connections "$id")"
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    if [[ "$active" -gt 0 ]]; then
        next_check_at="$(next_deferred_check_at)"
        write_deferred_restart_state "$id" "$active" "$(date +%s)" "$next_check_at"
        log "实例=${id} 当前仍有 ${active} 条活跃连接，延后至 ${next_check_at} 复查"
        return 2
    fi
    total_attempts=$((RETRIES + 1))
    started_at="$(date +%s)"
    mkdir -p "${RUNTIME_ROOT}/instances/${id}"
    printf '%s\n' "$$" > "${RUNTIME_ROOT}/instances/${id}/rotating"
    write_rotation_state "$id" "restarting" "已确认空闲，正在从后端池摘流并复核连接" "$started_at" "0"
    log "实例=${id} 已确认空闲，开始从后端池摘流"
    if ! set_backend "$id" down; then
        warn "实例=${id} 摘流失败，取消本次滚动重启"
        write_run_failure "$id" "backend-pool" "backend-drain-failed" "无法将实例从后端池摘流" "0" "0" "$active" "$started_at" "$(date +%s)"
        clear_rotation_state "$id"
        return 1
    fi
    # 摘流与首次检查之间可能有新连接到达；摘流后再次确认，避免中断在途会话。
    active="$(active_connections "$id")"
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    if [[ "$active" -gt 0 ]]; then
        warn "实例=${id} 摘流复核发现 ${active} 条活跃连接，恢复流量并延后"
        if ! set_backend "$id" up; then
            warn "实例=${id} 恢复后端池失败，保持摘流"
            write_run_failure "$id" "backend-pool" "backend-restore-failed" "摘流复核发现新连接后，无法恢复实例到后端池" "0" "0" "$active" "$started_at" "$(date +%s)"
            clear_rotation_state "$id"
            return 1
        fi
        clear_rotation_state "$id"
        next_check_at="$(next_deferred_check_at)"
        write_deferred_restart_state "$id" "$active" "$started_at" "$next_check_at"
        return 2
    fi
    for attempt in $(seq 1 "$total_attempts"); do
        write_rotation_state "$id" "restarting" "正在重启 WARP 实例（第 ${attempt}/${total_attempts} 次）" "$started_at" "" "$attempt" "$total_attempts"
        log "实例=${id} 重启尝试 | 次数=${attempt}/${total_attempts}"
        if "$INSTANCE_CTL" restart "$id" >>"${RUNTIME_ROOT}/rotate.log" 2>&1; then
            restart_exit=0
        else
            restart_exit=$?
            warn "实例=${id} 重启命令返回非零 | 返回码=${restart_exit}"
        fi
        last_restart_exit="$restart_exit"
        if probe_ready "$id" "$started_at" "$attempt" "$total_attempts"; then
            ok "实例=${id} 已通过 WARP 探测并重新加入后端池"
            recovered=1
            break
        fi
        warn "实例=${id} 重启后仍未就绪"
    done
    if [[ "$recovered" -ne 1 ]]; then
        warn "实例=${id} 本轮恢复失败，保持摘流"
        if [[ "$last_restart_exit" -ne 0 ]]; then
            write_run_failure "$id" "restart-command" "restart-command-failed" "重启命令最后一次返回非零（退出码 ${last_restart_exit}）" "$attempt" "$total_attempts" "$active" "$started_at" "$(date +%s)"
        else
            write_run_failure "$id" "warp-probe" "warp-probe-timeout" "在 ${PROBE_TIMEOUT} 秒内未确认 WARP 已就绪" "$attempt" "$total_attempts" "$active" "$started_at" "$(date +%s)"
        fi
    fi
    clear_rotation_state "$id"
    [[ "$recovered" -eq 1 ]]
}

start_rotation_worker() {
    local id="$1"
    # 子任务不能继承主调度器的退出清理 trap；否则单个任务结束会误清理整轮任务。
    remove_scheduled_restart_queue_id "$id"
    clear_scheduled_restart_state "$id"
    (trap - EXIT INT TERM; rotate_one "$id") &
    ROTATE_WORKER_PIDS+=("$!")
    ROTATE_WORKER_IDS+=("$id")
}

remove_worker() {
    local target="$1" index
    local -a pids=() ids=()
    for index in "${!ROTATE_WORKER_PIDS[@]}"; do
        [[ "$index" = "$target" ]] && continue
        pids+=("${ROTATE_WORKER_PIDS[$index]}")
        ids+=("${ROTATE_WORKER_IDS[$index]}")
    done
    if [[ "${#pids[@]}" -gt 0 ]]; then
        ROTATE_WORKER_PIDS=("${pids[@]}")
        ROTATE_WORKER_IDS=("${ids[@]}")
    else
        ROTATE_WORKER_PIDS=()
        ROTATE_WORKER_IDS=()
    fi
}

collect_one_finished_worker() {
    local index pid exit_status
    for index in "${!ROTATE_WORKER_PIDS[@]}"; do
        pid="${ROTATE_WORKER_PIDS[$index]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            if wait "$pid"; then
                SCHEDULE_LAST_WORKER_RESULT="success"
            else
                exit_status=$?
                case "$exit_status" in
                    2) SCHEDULE_LAST_WORKER_RESULT="deferred" ;;
                    3) SCHEDULE_LAST_WORKER_RESULT="skipped" ;;
                    *) SCHEDULE_LAST_WORKER_RESULT="failed" ;;
                esac
            fi
            SCHEDULE_LAST_WORKER_ID="${ROTATE_WORKER_IDS[$index]}"
            remove_worker "$index"
            return 0
        fi
    done
    return 1
}

record_finished_worker() {
    [[ "$SCHEDULE_CURRENT_RUNNING" -gt 0 ]] && SCHEDULE_CURRENT_RUNNING=$((SCHEDULE_CURRENT_RUNNING - 1))
    case "$SCHEDULE_LAST_WORKER_RESULT" in
        success)
            SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
            SCHEDULE_CURRENT_SUCCEEDED=$((SCHEDULE_CURRENT_SUCCEEDED + 1))
            ;;
        deferred)
            ROUND_DEFERRED+=("$SCHEDULE_LAST_WORKER_ID")
            SCHEDULE_CURRENT_DEFERRED_TOTAL=$((SCHEDULE_CURRENT_DEFERRED_TOTAL + 1))
            # 不能把已经到期的延后检查推迟到新任务的下一次检查时间。
            if [[ "$SCHEDULE_NEXT_DEFERRED_CHECK_AT" -le "$(date +%s)" ]]; then
                SCHEDULE_NEXT_DEFERRED_CHECK_AT="$(next_deferred_check_at)"
            fi
            ;;
        skipped)
            SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
            SCHEDULE_CURRENT_SKIPPED=$((SCHEDULE_CURRENT_SKIPPED + 1))
            ;;
        *)
            SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
            SCHEDULE_CURRENT_FAILED=$((SCHEDULE_CURRENT_FAILED + 1))
            ;;
    esac
    update_queue_metrics
    write_schedule_state
}

recheck_deferred_queue() {
    local id active now next_check_at deferred_at deferred_wait
    local -a still_deferred=()
    [[ "${#ROUND_DEFERRED[@]}" -gt 0 ]] || return 0
    now="$(date +%s)"
    [[ "$SCHEDULE_NEXT_DEFERRED_CHECK_AT" -le "$now" ]] || return 0

    next_check_at="$(next_deferred_check_at)"
    for id in "${ROUND_DEFERRED[@]}"; do
        if ! restart_eligible "$id"; then
            warn "实例=${id} 已不满足延后队列条件，标记为跳过"
            active="$(active_connections "$id")"
            [[ "$active" =~ ^[0-9]+$ ]] || active=0
            deferred_at="$(scheduled_restart_value "$id" deferred_at)"
            if [[ "$deferred_at" =~ ^[0-9]+$ ]]; then
                deferred_wait=$((now - deferred_at))
                [[ "$deferred_wait" -ge 0 ]] || deferred_wait=0
                SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS=$((SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS + deferred_wait))
                SCHEDULE_CURRENT_DEFERRED_COMPLETED=$((SCHEDULE_CURRENT_DEFERRED_COMPLETED + 1))
            fi
            write_run_skipped "$id" "${RESTART_INELIGIBLE_CODE:-ineligible}" "${RESTART_INELIGIBLE_MESSAGE:-实例不再满足本轮处理条件}" "$active"
            clear_scheduled_restart_state "$id"
            SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
            SCHEDULE_CURRENT_SKIPPED=$((SCHEDULE_CURRENT_SKIPPED + 1))
            continue
        fi
        active="$(active_connections "$id")"
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
        if [[ "$active" -eq 0 ]]; then
            deferred_at="$(scheduled_restart_value "$id" deferred_at)"
            if [[ "$deferred_at" =~ ^[0-9]+$ ]]; then
                deferred_wait=$((now - deferred_at))
                [[ "$deferred_wait" -ge 0 ]] || deferred_wait=0
                SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS=$((SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS + deferred_wait))
                SCHEDULE_CURRENT_DEFERRED_COMPLETED=$((SCHEDULE_CURRENT_DEFERRED_COMPLETED + 1))
            fi
            ROUND_READY+=("$id")
            SCHEDULE_QUEUE_IDS+=("$id")
            write_scheduled_restart_state "$id" "${#SCHEDULE_QUEUE_IDS[@]}" "${#SCHEDULE_QUEUE_IDS[@]}" "$SCHEDULE_ROUND_STARTED_AT" "$now"
            log "实例=${id} 已自然空闲，已从延后队列转入就绪队列"
        else
            still_deferred+=("$id")
            write_deferred_restart_state "$id" "$active" "$SCHEDULE_ROUND_STARTED_AT" "$next_check_at"
        fi
    done
    if [[ "${#still_deferred[@]}" -gt 0 ]]; then
        ROUND_DEFERRED=("${still_deferred[@]}")
        SCHEDULE_NEXT_DEFERRED_CHECK_AT="$next_check_at"
    else
        ROUND_DEFERRED=()
        SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
    fi
    update_queue_metrics
    write_schedule_state
}

cleanup_workers() {
    local index pid id
    for index in "${!ROTATE_WORKER_PIDS[@]}"; do
        pid="${ROTATE_WORKER_PIDS[$index]}"
        kill "$pid" 2>/dev/null || true
    done
    for index in "${!ROTATE_WORKER_PIDS[@]}"; do
        pid="${ROTATE_WORKER_PIDS[$index]}"
        wait "$pid" 2>/dev/null || true
        id="${ROTATE_WORKER_IDS[$index]}"
        clear_rotation_state "$id"
    done
    ROTATE_WORKER_PIDS=()
    ROTATE_WORKER_IDS=()
    clear_scheduled_restart_queue
}

run_round() {
    local id total concurrency active now remaining completed_run_id
    local -a all_ids candidates
    # 本轮队列显式初始化，确保 Bash 3 与 set -u 组合下也可安全读取空队列。
    all_ids=()
    candidates=()
    ROUND_READY=()
    ROUND_DEFERRED=()
    ROUND_NEXT=0
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        all_ids+=("$id")
    done < <(runtime_instance_ids)
    total="${#all_ids[@]}"
    SCHEDULE_SCOPE_COUNT="$total"
    SCHEDULE_ROUND_STARTED_AT="$(date +%s)"
    SCHEDULE_LAST_RUN_AT="$SCHEDULE_ROUND_STARTED_AT"
    SCHEDULE_CURRENT_RUN_ID="restart-$(date '+%Y%m%d-%H%M%S')-$$"
    # 每轮都先清空实时统计，避免无可处理实例时遗留上一轮的队列数据。
    SCHEDULE_CURRENT_TOTAL=0
    SCHEDULE_CURRENT_QUEUED=0
    SCHEDULE_CURRENT_RUNNING=0
    SCHEDULE_CURRENT_COMPLETED=0
    SCHEDULE_CURRENT_SUCCEEDED=0
    SCHEDULE_CURRENT_FAILED=0
    SCHEDULE_CURRENT_SKIPPED=0
    SCHEDULE_CURRENT_DEFERRED=0
    SCHEDULE_CURRENT_DEFERRED_TOTAL=0
    SCHEDULE_CURRENT_DEFERRED_CONNECTIONS=0
    SCHEDULE_CURRENT_MAX_QUEUED=0
    SCHEDULE_CURRENT_MAX_DEFERRED=0
    SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS=0
    SCHEDULE_CURRENT_DEFERRED_COMPLETED=0
    SCHEDULE_QUEUE_IDS=()
    prepare_run_history "$SCHEDULE_CURRENT_RUN_ID"
    [[ "$total" -gt 0 ]] || {
        warn "未发现可管理实例，跳过本轮滚动重启"
        SCHEDULE_STATUS="waiting"
        SCHEDULE_RUNNING="no"
        SCHEDULE_LAST_COMPLETED_AT="$(date +%s)"
        SCHEDULE_LAST_DURATION_SECONDS=$((SCHEDULE_LAST_COMPLETED_AT - SCHEDULE_ROUND_STARTED_AT))
        SCHEDULE_LAST_STATUS="skipped"
        SCHEDULE_LAST_TOTAL=0
        SCHEDULE_LAST_SUCCEEDED=0
        SCHEDULE_LAST_FAILED=0
        SCHEDULE_LAST_SKIPPED=0
        SCHEDULE_LAST_DEFERRED=0
        SCHEDULE_LAST_MAX_QUEUED=0
        SCHEDULE_LAST_MAX_DEFERRED=0
        SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=0
        SCHEDULE_LAST_RUN_ID="$SCHEDULE_CURRENT_RUN_ID"
        write_run_history_summary "$SCHEDULE_CURRENT_RUN_ID"
        prune_run_history
        SCHEDULE_CURRENT_RUN_ID=""
        write_schedule_state
        return 0
    }
    concurrency="$(effective_concurrency "$total")"
    for id in "${all_ids[@]}"; do
        # 上一轮遗留的“延后”仅是展示状态；本轮会重新依据实时连接数分类。
        clear_scheduled_restart_state "$id"
        restart_eligible "$id" && candidates+=("$id")
    done
    SCHEDULE_ELIGIBLE_COUNT="${#candidates[@]}"
    SCHEDULE_CURRENT_TOTAL="${#candidates[@]}"
    if [[ "${#candidates[@]}" -gt 0 ]]; then
        for id in "${candidates[@]}"; do
            active="$(active_connections "$id")"
            [[ "$active" =~ ^[0-9]+$ ]] || active=0
            if [[ "$active" -gt 0 ]]; then
                ROUND_DEFERRED+=("$id")
            else
                ROUND_READY+=("$id")
            fi
        done
    fi
    SCHEDULE_CURRENT_QUEUED="${#ROUND_READY[@]}"
    SCHEDULE_CURRENT_RUNNING=0
    SCHEDULE_CURRENT_COMPLETED=0
    SCHEDULE_CURRENT_SUCCEEDED=0
    SCHEDULE_CURRENT_FAILED=0
    SCHEDULE_CURRENT_SKIPPED=0
    SCHEDULE_CURRENT_DEFERRED="${#ROUND_DEFERRED[@]}"
    SCHEDULE_CURRENT_DEFERRED_TOTAL="${#ROUND_DEFERRED[@]}"
    SCHEDULE_CURRENT_DEFERRED_CONNECTIONS=0
    SCHEDULE_CURRENT_MAX_QUEUED="${#ROUND_READY[@]}"
    SCHEDULE_CURRENT_MAX_DEFERRED="${#ROUND_DEFERRED[@]}"
    SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS=0
    SCHEDULE_CURRENT_DEFERRED_COMPLETED=0
    SCHEDULE_QUEUE_IDS=()
    if [[ "${#candidates[@]}" -eq 0 ]]; then
        log "本轮没有满足重启条件的实例 | 总数=${total}"
        SCHEDULE_STATUS="waiting"
        SCHEDULE_RUNNING="no"
        SCHEDULE_LAST_COMPLETED_AT="$(date +%s)"
        SCHEDULE_LAST_DURATION_SECONDS=$((SCHEDULE_LAST_COMPLETED_AT - SCHEDULE_ROUND_STARTED_AT))
        SCHEDULE_LAST_STATUS="skipped"
        SCHEDULE_LAST_TOTAL=0
        SCHEDULE_LAST_SUCCEEDED=0
        SCHEDULE_LAST_FAILED=0
        SCHEDULE_LAST_SKIPPED=0
        SCHEDULE_LAST_DEFERRED=0
        SCHEDULE_LAST_MAX_QUEUED=0
        SCHEDULE_LAST_MAX_DEFERRED=0
        SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=0
        SCHEDULE_LAST_RUN_ID="$SCHEDULE_CURRENT_RUN_ID"
        write_run_history_summary "$SCHEDULE_CURRENT_RUN_ID"
        prune_run_history
        SCHEDULE_CURRENT_RUN_ID=""
        write_schedule_state
        return 0
    fi
    SCHEDULE_STATUS="running"
    SCHEDULE_RUNNING="yes"
    SCHEDULE_NEXT_RUN_AT=0
    if [[ "${#ROUND_DEFERRED[@]}" -gt 0 ]]; then
        SCHEDULE_NEXT_DEFERRED_CHECK_AT="$(next_deferred_check_at)"
    else
        SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
    fi
    if [[ "${#ROUND_READY[@]}" -gt 0 ]]; then
        for id in "${ROUND_READY[@]}"; do
            SCHEDULE_QUEUE_IDS+=("$id")
            write_scheduled_restart_state "$id" "${#SCHEDULE_QUEUE_IDS[@]}" "${#ROUND_READY[@]}" "$SCHEDULE_ROUND_STARTED_AT"
        done
    fi
    if [[ "${#ROUND_DEFERRED[@]}" -gt 0 ]]; then
        for id in "${ROUND_DEFERRED[@]}"; do
            active="$(active_connections "$id")"
            [[ "$active" =~ ^[0-9]+$ ]] || active=0
            write_deferred_restart_state "$id" "$active" "$SCHEDULE_ROUND_STARTED_AT" "$SCHEDULE_NEXT_DEFERRED_CHECK_AT"
        done
    fi
    update_queue_metrics
    write_schedule_state
    log "本轮调度已开始 | 总数=${total} | 可处理=${#candidates[@]} | 空闲就绪=${#ROUND_READY[@]} | 繁忙延后=${#ROUND_DEFERRED[@]} | 延后复查=${SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS}s | 最大并行=${concurrency} | 配置=${CONCURRENCY}"
    while [[ "$ROUND_NEXT" -lt "${#ROUND_READY[@]}" || "${#ROTATE_WORKER_PIDS[@]}" -gt 0 || "${#ROUND_DEFERRED[@]}" -gt 0 ]]; do
        while [[ "${#ROTATE_WORKER_PIDS[@]}" -lt "$concurrency" && "$ROUND_NEXT" -lt "${#ROUND_READY[@]}" ]]; do
            id="${ROUND_READY[$ROUND_NEXT]}"
            start_rotation_worker "$id"
            ROUND_NEXT=$((ROUND_NEXT + 1))
            SCHEDULE_CURRENT_RUNNING=$((SCHEDULE_CURRENT_RUNNING + 1))
            update_queue_metrics
            write_schedule_state
        done
        if [[ "${#ROTATE_WORKER_PIDS[@]}" -gt 0 ]]; then
            # 不等待任一工作进程结束：延后队列必须按配置时钟持续复查，哪怕已有
            # 重启任务的 WARP 探测耗时较长。
            if collect_one_finished_worker; then
                record_finished_worker
                continue
            fi
            if [[ "${#ROUND_DEFERRED[@]}" -gt 0 ]]; then
                recheck_deferred_queue
            fi
            # Bash 3 不支持 wait -n；短轮询同时保证完成实例能立即补位。
            sleep 0.1
        elif [[ "${#ROUND_DEFERRED[@]}" -gt 0 ]]; then
            now="$(date +%s)"
            remaining=$((SCHEDULE_NEXT_DEFERRED_CHECK_AT - now))
            if [[ "$remaining" -gt 0 ]]; then
                sleep "$remaining"
                continue
            fi
            recheck_deferred_queue
        fi
    done
    SCHEDULE_RUNNING="no"
    SCHEDULE_STATUS="waiting"
    SCHEDULE_LAST_COMPLETED_AT="$(date +%s)"
    SCHEDULE_LAST_DURATION_SECONDS=$((SCHEDULE_LAST_COMPLETED_AT - SCHEDULE_ROUND_STARTED_AT))
    SCHEDULE_LAST_TOTAL="$SCHEDULE_CURRENT_TOTAL"
    SCHEDULE_LAST_SUCCEEDED="$SCHEDULE_CURRENT_SUCCEEDED"
    SCHEDULE_LAST_FAILED="$SCHEDULE_CURRENT_FAILED"
    SCHEDULE_LAST_SKIPPED="$SCHEDULE_CURRENT_SKIPPED"
    SCHEDULE_LAST_DEFERRED="$SCHEDULE_CURRENT_DEFERRED_TOTAL"
    SCHEDULE_LAST_MAX_QUEUED="$SCHEDULE_CURRENT_MAX_QUEUED"
    SCHEDULE_LAST_MAX_DEFERRED="$SCHEDULE_CURRENT_MAX_DEFERRED"
    if [[ "$SCHEDULE_CURRENT_DEFERRED_COMPLETED" -gt 0 ]]; then
        SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=$((SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS / SCHEDULE_CURRENT_DEFERRED_COMPLETED))
    else
        SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=0
    fi
    completed_run_id="$SCHEDULE_CURRENT_RUN_ID"
    SCHEDULE_LAST_RUN_ID="$completed_run_id"
    SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
    if [[ "$SCHEDULE_CURRENT_FAILED" -eq 0 ]]; then
        SCHEDULE_LAST_STATUS="success"
    elif [[ "$SCHEDULE_CURRENT_SUCCEEDED" -gt 0 ]]; then
        SCHEDULE_LAST_STATUS="partial"
    else
        SCHEDULE_LAST_STATUS="failed"
    fi
    write_run_history_summary "$completed_run_id"
    prune_run_history
    clear_scheduled_restart_queue
    SCHEDULE_CURRENT_RUN_ID=""
    SCHEDULE_CURRENT_RUNNING=0
    SCHEDULE_CURRENT_DEFERRED_CONNECTIONS=0
    write_schedule_state
}

acquire_lock() {
    mkdir -p "$RUNTIME_ROOT"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "${LOCK_DIR}/pid"
        LOCK_HELD=1
        return 0
    fi
    return 1
}

release_lock() {
    [[ "$LOCK_HELD" -eq 1 ]] || return 0
    # 不删除其他调度器持有的锁，status 等只读调用也不会影响正在执行的任务。
    if [[ "$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)" = "$$" ]]; then
        rm -rf "$LOCK_DIR"
    fi
    LOCK_HELD=0
}

once() {
    if ! enabled; then
        log "当前配置未启用滚动重启"
        SCHEDULE_STATUS="disabled"
        SCHEDULE_RUNNING="no"
        SCHEDULE_NEXT_RUN_AT=0
        write_schedule_state
        return 1
    fi
    if schedule_paused; then
        log "滚动重启计划已暂停，跳过本轮"
        SCHEDULE_STATUS="paused"
        SCHEDULE_RUNNING="no"
        SCHEDULE_NEXT_RUN_AT=0
        write_schedule_state
        return 0
    fi
    acquire_lock || { warn "已有滚动重启任务在执行，忽略本轮"; return 0; }
    run_round
    release_lock
}

daemon() {
    local seconds now next_run remaining
    seconds="$SCHEDULE_INTERVAL_SECONDS"
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=21600
    [[ "$seconds" -ge 60 ]] || seconds=60
    SCHEDULE_INTERVAL_SECONDS="$seconds"
    mw_section "滚动重启" "滚动重启守护已启动"
    mw_info "滚动重启" "配置 | 实例=${INSTANCE_COUNT} | 间隔=${seconds}s | 策略=空闲优先、繁忙延后 | 探测=${PROBE_TIMEOUT}s | 重试=${RETRIES} | 并行=${CONCURRENCY}"
    while true; do
        if ! enabled; then
            SCHEDULE_STATUS="disabled"
            SCHEDULE_RUNNING="no"
            SCHEDULE_NEXT_RUN_AT=0
            write_schedule_state
            # 配置只会随容器重建改变，无需高频轮询。
            sleep 60
            continue
        fi
        if schedule_paused; then
            SCHEDULE_STATUS="paused"
            SCHEDULE_RUNNING="no"
            SCHEDULE_NEXT_RUN_AT=0
            write_schedule_state
            # 暂停标记可由管理页面移除；短轮询确保恢复后立即重新计算下一次执行时间。
            sleep 5
            continue
        fi
        now="$(date +%s)"
        next_run=$((now + seconds))
        SCHEDULE_NEXT_RUN_AT="$next_run"
        set_schedule_waiting
        while true; do
            now="$(date +%s)"
            [[ "$now" -lt "$next_run" ]] || break
            if ! enabled || schedule_paused; then
                break
            fi
            remaining=$((next_run - now))
            # 既避免长时间 sleep 导致暂停不生效，又不需要每秒落盘刷新状态。
            if [[ "$remaining" -gt 5 ]]; then sleep 5; else sleep "$remaining"; fi
        done
        if ! enabled || schedule_paused; then
            continue
        fi
        once || true
    done
}

status() {
    local id total=0 concurrency
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] && total=$((total + 1))
    done < <(runtime_instance_ids)
    concurrency="$(effective_concurrency "$total")"
    echo "enabled=${ENABLED} instances=${total} interval=${INTERVAL} concurrency=${concurrency} configured_concurrency=${CONCURRENCY}"
    [[ -d "$LOCK_DIR" ]] && echo "running=yes" || echo "running=no"
    schedule_paused && echo "paused=yes" || echo "paused=no"
}

on_exit() {
    cleanup_workers
    release_lock
}

trap on_exit EXIT
trap 'exit 0' INT TERM

SCHEDULE_INTERVAL_SECONDS="$(parse_duration "$INTERVAL" || echo 21600)"
[[ "$SCHEDULE_INTERVAL_SECONDS" -ge 60 ]] || SCHEDULE_INTERVAL_SECONDS=60
SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS="$(parse_duration "$DEFERRED_CHECK_INTERVAL" || echo 60)"
[[ "$SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS" -ge 1 ]] || SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS=60
[[ "$HISTORY_LIMIT" =~ ^[0-9]+$ ]] || HISTORY_LIMIT=20
[[ "$HISTORY_LIMIT" -ge 1 ]] || HISTORY_LIMIT=20
[[ "$HISTORY_LIMIT" -le 100 ]] || HISTORY_LIMIT=100
load_schedule_history

case "${1:-daemon}" in
    daemon) daemon ;;
    once) once ;;
    status) status ;;
    *) echo "用法: $0 {daemon|once|status}"; exit 1 ;;
esac
