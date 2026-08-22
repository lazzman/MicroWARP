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
LOCK_DIR="${RUNTIME_ROOT}/rotate-restart.lock"
SCHEDULE_STATE_FILE="${RUNTIME_ROOT}/rotate-restart.schedule.state"
SCHEDULE_PAUSE_FILE="${RUNTIME_ROOT}/rotate-restart.paused"
# 管理 API 写入一次性请求；守护进程在下一次短轮询中消费并立即启动一轮。
SCHEDULE_RUN_NOW_FILE="${RUNTIME_ROOT}/rotate-restart.run-now"
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
# 后端池同步确认暂时失败时，不把空闲实例误归为“连接延后”，而是在本轮内走
# 独立的控制面重试队列。该值表示首次失败后的额外重试次数。
BACKEND_RETRY_LIMIT="${BACKEND_POOL_OPERATION_RETRY_LIMIT:-6}"
# 退避从 1 秒开始，随后 2、5 秒并封顶为该值；避免大量实例再次同时抢锁。
BACKEND_RETRY_MAX_DELAY="${BACKEND_POOL_OPERATION_RETRY_MAX_DELAY:-10}"
# 每轮结果和失败明细仅保留最近若干轮，避免运行时目录无限增长。
HISTORY_LIMIT="${ROTATE_RESTART_HISTORY_LIMIT:-20}"
[[ "$HISTORY_LIMIT" =~ ^[0-9]+$ ]] && [[ "$HISTORY_LIMIT" -ge 1 ]] || HISTORY_LIMIT=20
[[ "$BACKEND_RETRY_LIMIT" =~ ^[0-9]+$ ]] || BACKEND_RETRY_LIMIT=6
[[ "$BACKEND_RETRY_MAX_DELAY" =~ ^[0-9]+$ ]] && [[ "$BACKEND_RETRY_MAX_DELAY" -ge 1 ]] || BACKEND_RETRY_MAX_DELAY=10
# 以下两个覆盖项仅供隔离测试使用；正常容器保持默认的应用脚本路径。
INSTANCE_CTL="${MICROWARP_INSTANCE_CTL:-${APP_DIR}/instance-ctl.sh}"
HEALTH_CHECK="${MICROWARP_HEALTH_CHECK:-${APP_DIR}/health-check.sh}"
# 后端池更新始终由健康脚本统一完成；探测覆写不应重新引入独立的摘流实现。
BACKEND_POOL_COMMAND="${MICROWARP_BACKEND_POOL_COMMAND:-${APP_DIR}/health-check.sh}"

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
SCHEDULE_NEXT_BACKEND_RETRY_AT=0
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
SCHEDULE_CURRENT_BACKEND_RETRY=0
SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL=0
SCHEDULE_CURRENT_MAX_BACKEND_RETRY=0
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
SCHEDULE_LAST_BACKEND_RETRY=0
SCHEDULE_LAST_MAX_BACKEND_RETRY=0
SCHEDULE_LAST_RUN_ID=""
SCHEDULE_LAST_WORKER_RESULT="success"
SCHEDULE_LAST_WORKER_ID=""
SCHEDULE_QUEUE_IDS=()
# 本轮两个队列使用全局数组，避免 Bash 3 在 set -u 下跨函数访问局部空数组时触发未绑定变量。
ROUND_READY=()
ROUND_DEFERRED=()
ROUND_BACKEND_RETRY=()
ROUND_NEXT=0
RESTART_INELIGIBLE_CODE=""
RESTART_INELIGIBLE_MESSAGE=""
BACKEND_UPDATE_FAILURE_CODE=""

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

schedule_run_now_requested() {
    [[ -f "$SCHEDULE_RUN_NOW_FILE" ]]
}

clear_schedule_run_now_request() {
    rm -f "$SCHEDULE_RUN_NOW_FILE"
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
    local id active total_connections=0 retry_at
    SCHEDULE_CURRENT_QUEUED=$(( ${#ROUND_READY[@]} - ROUND_NEXT ))
    SCHEDULE_CURRENT_DEFERRED="${#ROUND_DEFERRED[@]}"
    SCHEDULE_CURRENT_BACKEND_RETRY="${#ROUND_BACKEND_RETRY[@]}"
    for id in "${ROUND_DEFERRED[@]-}"; do
        [[ -n "$id" ]] || continue
        active="$(active_connections "$id")"
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
        total_connections=$((total_connections + active))
    done
    SCHEDULE_CURRENT_DEFERRED_CONNECTIONS="$total_connections"
    [[ "$SCHEDULE_CURRENT_QUEUED" -le "$SCHEDULE_CURRENT_MAX_QUEUED" ]] || SCHEDULE_CURRENT_MAX_QUEUED="$SCHEDULE_CURRENT_QUEUED"
    [[ "$SCHEDULE_CURRENT_DEFERRED" -le "$SCHEDULE_CURRENT_MAX_DEFERRED" ]] || SCHEDULE_CURRENT_MAX_DEFERRED="$SCHEDULE_CURRENT_DEFERRED"
    [[ "$SCHEDULE_CURRENT_BACKEND_RETRY" -le "$SCHEDULE_CURRENT_MAX_BACKEND_RETRY" ]] || SCHEDULE_CURRENT_MAX_BACKEND_RETRY="$SCHEDULE_CURRENT_BACKEND_RETRY"
    SCHEDULE_NEXT_BACKEND_RETRY_AT=0
    for id in "${ROUND_BACKEND_RETRY[@]-}"; do
        [[ -n "$id" ]] || continue
        retry_at="$(scheduled_restart_value "$id" next_check_at)"
        [[ "$retry_at" =~ ^[0-9]+$ ]] || retry_at="$(date +%s)"
        if [[ "$SCHEDULE_NEXT_BACKEND_RETRY_AT" -eq 0 || "$retry_at" -lt "$SCHEDULE_NEXT_BACKEND_RETRY_AT" ]]; then
            SCHEDULE_NEXT_BACKEND_RETRY_AT="$retry_at"
        fi
    done
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
    SCHEDULE_LAST_BACKEND_RETRY="$(schedule_integer "$(schedule_value last_backend_retry)")"
    SCHEDULE_LAST_MAX_BACKEND_RETRY="$(schedule_integer "$(schedule_value last_max_backend_retry)")"
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
        printf 'version=4\n'
        printf 'configured_enabled=%s\n' "$configured"
        printf 'config_active=%s\n' "$active"
        printf 'paused=%s\n' "$paused"
        printf 'interval=%s\ninterval_seconds=%s\ndeferred_check_interval=%s\ndeferred_check_interval_seconds=%s\n' \
            "$INTERVAL" "$SCHEDULE_INTERVAL_SECONDS" "$DEFERRED_CHECK_INTERVAL" "$SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS"
        printf 'status=%s\nrunning=%s\ncurrent_run_id=%s\nnext_run_at=%s\nnext_deferred_check_at=%s\nnext_backend_retry_at=%s\n' \
            "$SCHEDULE_STATUS" "$SCHEDULE_RUNNING" "$SCHEDULE_CURRENT_RUN_ID" "$SCHEDULE_NEXT_RUN_AT" "$SCHEDULE_NEXT_DEFERRED_CHECK_AT" "$SCHEDULE_NEXT_BACKEND_RETRY_AT"
        printf 'round_started_at=%s\nscope_count=%s\neligible_count=%s\n' \
            "$SCHEDULE_ROUND_STARTED_AT" "$SCHEDULE_SCOPE_COUNT" "$SCHEDULE_ELIGIBLE_COUNT"
        printf 'current_total=%s\ncurrent_queued=%s\ncurrent_running=%s\ncurrent_completed=%s\ncurrent_succeeded=%s\ncurrent_failed=%s\ncurrent_skipped=%s\ncurrent_deferred=%s\ncurrent_deferred_connections=%s\ncurrent_backend_retry=%s\ncurrent_backend_retry_total=%s\ncurrent_max_queued=%s\ncurrent_max_deferred=%s\ncurrent_max_backend_retry=%s\n' \
            "$SCHEDULE_CURRENT_TOTAL" "$SCHEDULE_CURRENT_QUEUED" "$SCHEDULE_CURRENT_RUNNING" "$SCHEDULE_CURRENT_COMPLETED" \
            "$SCHEDULE_CURRENT_SUCCEEDED" "$SCHEDULE_CURRENT_FAILED" "$SCHEDULE_CURRENT_SKIPPED" \
            "$SCHEDULE_CURRENT_DEFERRED" "$SCHEDULE_CURRENT_DEFERRED_CONNECTIONS" "$SCHEDULE_CURRENT_BACKEND_RETRY" "$SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL" \
            "$SCHEDULE_CURRENT_MAX_QUEUED" "$SCHEDULE_CURRENT_MAX_DEFERRED" "$SCHEDULE_CURRENT_MAX_BACKEND_RETRY"
        printf 'last_run_id=%s\nlast_run_at=%s\nlast_completed_at=%s\nlast_duration_seconds=%s\nlast_status=%s\nlast_total=%s\nlast_succeeded=%s\nlast_failed=%s\nlast_skipped=%s\nlast_deferred=%s\nlast_backend_retry=%s\nlast_max_queued=%s\nlast_max_deferred=%s\nlast_max_backend_retry=%s\nlast_avg_deferred_wait_seconds=%s\n' \
            "$SCHEDULE_LAST_RUN_ID" \
            "$SCHEDULE_LAST_RUN_AT" "$SCHEDULE_LAST_COMPLETED_AT" "$SCHEDULE_LAST_DURATION_SECONDS" "$SCHEDULE_LAST_STATUS" \
            "$SCHEDULE_LAST_TOTAL" "$SCHEDULE_LAST_SUCCEEDED" "$SCHEDULE_LAST_FAILED" "$SCHEDULE_LAST_SKIPPED" \
            "$SCHEDULE_LAST_DEFERRED" "$SCHEDULE_LAST_BACKEND_RETRY" "$SCHEDULE_LAST_MAX_QUEUED" "$SCHEDULE_LAST_MAX_DEFERRED" "$SCHEDULE_LAST_MAX_BACKEND_RETRY" "$SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS"
        printf 'configured_concurrency=%s\nhistory_limit=%s\nupdated_at=%s\n' "$CONCURRENCY" "$HISTORY_LIMIT" "$(date +%s)"
    } > "$temporary"
    mv "$temporary" "$SCHEDULE_STATE_FILE"
}

set_schedule_waiting() {
    SCHEDULE_STATUS="waiting"
    SCHEDULE_RUNNING="no"
    SCHEDULE_ROUND_STARTED_AT=0
    SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
    SCHEDULE_NEXT_BACKEND_RETRY_AT=0
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
    SCHEDULE_CURRENT_BACKEND_RETRY=0
    SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL=0
    SCHEDULE_CURRENT_MAX_BACKEND_RETRY=0
    SCHEDULE_CURRENT_RUN_ID=""
    write_schedule_state
}

backend_for() { printf '10.64.%s.2:1080\n' "$1"; }

set_backend() {
    local id="$1" status="$2" exit_status
    BACKEND_UPDATE_FAILURE_CODE=""
    # 健康守护、管理操作与滚动重启必须经过同一个“请求落盘→批量提交→状态确认”
    # 通道。不能再在这里直接抢锁重建，否则高并发摘流会形成另一套 5 秒超时语义。
    if "$BACKEND_POOL_COMMAND" pool "$id" "$status"; then
        return 0
    else
        exit_status=$?
    fi
    case "$exit_status" in
        75) BACKEND_UPDATE_FAILURE_CODE="backend-pool-confirm-timeout" ;;
        76) BACKEND_UPDATE_FAILURE_CODE="backend-pool-state-conflict" ;;
        *) BACKEND_UPDATE_FAILURE_CODE="backend-pool-update-failed" ;;
    esac
    warn "后端池更新未确认 | 实例=${id} | 状态=${status} | 原因=${BACKEND_UPDATE_FAILURE_CODE} | 返回码=${exit_status}"
    return "$exit_status"
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
    local id="$1" position="$2" total="$3" started_at="$4" queued_at="${5:-$(date +%s)}"
    local backend_retry_attempt="${6:-}" target temporary
    target="$(scheduled_restart_state_file "$id")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'action=scheduled-rolling-restart\nstatus=queued\n'
        printf 'message=等待本轮定时滚动重启\n'
        printf 'queue=ready\nqueue_position=%s\nqueue_total=%s\nstarted_at=%s\nqueue_entered_at=%s\nupdated_at=%s\n' \
            "$position" "$total" "$started_at" "$queued_at" "$(date +%s)"
        [[ "$backend_retry_attempt" =~ ^[0-9]+$ ]] && printf 'backend_retry_attempt=%s\n' "$backend_retry_attempt"
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

backend_retry_delay_seconds() {
    local attempt="$1" delay
    # 1、2、5、10… 秒：前几次快速恢复短暂锁竞争，随后保持上限避免重试风暴。
    case "$attempt" in
        1) delay=1 ;;
        2) delay=2 ;;
        3) delay=5 ;;
        *) delay=10 ;;
    esac
    [[ "$delay" -le "$BACKEND_RETRY_MAX_DELAY" ]] || delay="$BACKEND_RETRY_MAX_DELAY"
    printf '%s\n' "$delay"
}

next_backend_retry_at() {
    local attempt="$1" delay
    delay="$(backend_retry_delay_seconds "$attempt")"
    printf '%s\n' "$(( $(date +%s) + delay ))"
}

write_backend_retry_restart_state() {
    local id="$1" active="$2" started_at="$3" retry_attempt="$4" next_check_at="$5"
    local reason_code="$6" target_state="${7:-down}" retry_at="${8:-}" target temporary message
    [[ "$retry_at" =~ ^[0-9]+$ ]] || retry_at="$(scheduled_restart_value "$id" backend_retry_at)"
    [[ "$retry_at" =~ ^[0-9]+$ ]] || retry_at="$(date +%s)"
    [[ "$target_state" = up || "$target_state" = down ]] || target_state=down
    if [[ "$target_state" = up ]]; then
        message="后端池恢复暂未确认，保留现有连接并等待控制面重试（第 ${retry_attempt}/${BACKEND_RETRY_LIMIT} 次）"
    else
        message="后端池摘流暂未确认，保持实例运行并等待控制面重试（第 ${retry_attempt}/${BACKEND_RETRY_LIMIT} 次）"
    fi
    target="$(scheduled_restart_state_file "$id")"
    temporary="${target}.${BASHPID:-$$}"
    {
        printf 'action=scheduled-rolling-restart\nstatus=backend-retry\n'
        printf 'message=%s\n' "$message"
        printf 'queue=backend-retry\nactive_connections=%s\nstarted_at=%s\nbackend_retry_at=%s\nbackend_retry_attempt=%s\nbackend_retry_limit=%s\nbackend_target_state=%s\nnext_check_at=%s\nreason_code=%s\nupdated_at=%s\n' \
            "$active" "$started_at" "$retry_at" "$retry_attempt" "$BACKEND_RETRY_LIMIT" "$target_state" "$next_check_at" "$reason_code" "$(date +%s)"
    } > "$temporary"
    mv "$temporary" "$target"
}

queue_backend_retry_or_fail() {
    local id="$1" active="$2" started_at="$3" previous_attempt="$4" target_state="$5"
    local retry_attempt next_check_at reason_code
    retry_attempt=$((previous_attempt + 1))
    reason_code="${BACKEND_UPDATE_FAILURE_CODE:-backend-pool-update-failed}"
    if [[ "$retry_attempt" -le "$BACKEND_RETRY_LIMIT" ]]; then
        next_check_at="$(next_backend_retry_at "$retry_attempt")"
        warn "实例=${id} 后端池${target_state} 未确认，进入控制面重试队列 | 次数=${retry_attempt}/${BACKEND_RETRY_LIMIT} | 下次复查=${next_check_at}"
        write_backend_retry_restart_state "$id" "$active" "$started_at" "$retry_attempt" "$next_check_at" "$reason_code" "$target_state"
        return 0
    fi
    warn "实例=${id} 后端池${target_state} 重试预算耗尽，取消本次滚动重启"
    write_run_failure "$id" "backend-pool" "$reason_code" "后端池 ${target_state} 状态在 ${BACKEND_RETRY_LIMIT} 次控制面重试后仍未确认" "$retry_attempt" "$BACKEND_RETRY_LIMIT" "$active" "$started_at" "$(date +%s)"
    clear_scheduled_restart_state "$id"
    return 1
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
    local id="$1" allow_drained="${2:-0}" state pool
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
    if [[ "$pool" != "up" ]] && ! { [[ "$allow_drained" = "1" ]] && [[ "$pool" = "down" ]]; }; then
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
    local id="$1" backend_retry_attempt="${2:-0}" allow_drained=0 attempt total_attempts active next_check_at
    local recovered=0 started_at restart_exit=0 last_restart_exit=0
    [[ "$backend_retry_attempt" =~ ^[0-9]+$ ]] || backend_retry_attempt=0
    [[ "$backend_retry_attempt" -gt 0 ]] && allow_drained=1
    # 任务从队列取出到真正执行之间，管理面可能改变了实例状态；在此再次确认。
    if ! restart_eligible "$id" "$allow_drained"; then
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
        if queue_backend_retry_or_fail "$id" "$active" "$started_at" "$backend_retry_attempt" down; then
            clear_rotation_state "$id"
            return 4
        fi
        clear_rotation_state "$id"
        return 1
    fi
    # 摘流与首次检查之间可能有新连接到达；摘流后再次确认，避免中断在途会话。
    active="$(active_connections "$id")"
    [[ "$active" =~ ^[0-9]+$ ]] || active=0
    if [[ "$active" -gt 0 ]]; then
        warn "实例=${id} 摘流复核发现 ${active} 条活跃连接，恢复流量并延后"
        if ! set_backend "$id" up; then
            if queue_backend_retry_or_fail "$id" "$active" "$started_at" "$backend_retry_attempt" up; then
                clear_rotation_state "$id"
                return 4
            fi
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
    local id="$1" backend_retry_attempt
    backend_retry_attempt="$(scheduled_restart_value "$id" backend_retry_attempt)"
    [[ "$backend_retry_attempt" =~ ^[0-9]+$ ]] || backend_retry_attempt=0
    # 子任务不能继承主调度器的退出清理 trap；否则单个任务结束会误清理整轮任务。
    remove_scheduled_restart_queue_id "$id"
    clear_scheduled_restart_state "$id"
    (trap - EXIT INT TERM; rotate_one "$id" "$backend_retry_attempt") &
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
                    4) SCHEDULE_LAST_WORKER_RESULT="backend-retry" ;;
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
        backend-retry)
            ROUND_BACKEND_RETRY+=("$SCHEDULE_LAST_WORKER_ID")
            SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL=$((SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL + 1))
            # 单个实例状态中已经写入指数退避后的精确时间；汇总状态取最早的一项。
            SCHEDULE_NEXT_BACKEND_RETRY_AT=0
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

recheck_backend_retry_queue() {
    local id active now retry_at retry_started_at retry_attempt target_state
    local -a still_retry=()
    [[ "${#ROUND_BACKEND_RETRY[@]}" -gt 0 ]] || return 0
    now="$(date +%s)"
    [[ "$SCHEDULE_NEXT_BACKEND_RETRY_AT" -le "$now" ]] || return 0

    for id in "${ROUND_BACKEND_RETRY[@]}"; do
        retry_at="$(scheduled_restart_value "$id" next_check_at)"
        [[ "$retry_at" =~ ^[0-9]+$ ]] || retry_at="$now"
        if [[ "$retry_at" -gt "$now" ]]; then
            still_retry+=("$id")
            continue
        fi
        # 摘流请求在上一次确认超时后可能已经由另一提交者落盘为 down；这是
        # 本流程自己的安全中间状态，允许继续复核，不能误判为“不在池中”跳过。
        if ! restart_eligible "$id" 1; then
            warn "实例=${id} 已不满足后端池重试条件，标记为跳过"
            active="$(active_connections "$id")"
            [[ "$active" =~ ^[0-9]+$ ]] || active=0
            write_run_skipped "$id" "${RESTART_INELIGIBLE_CODE:-ineligible}" "${RESTART_INELIGIBLE_MESSAGE:-实例不再满足本轮处理条件}" "$active"
            clear_scheduled_restart_state "$id"
            SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
            SCHEDULE_CURRENT_SKIPPED=$((SCHEDULE_CURRENT_SKIPPED + 1))
            continue
        fi
        active="$(active_connections "$id")"
        [[ "$active" =~ ^[0-9]+$ ]] || active=0
        retry_started_at="$(scheduled_restart_value "$id" started_at)"
        [[ "$retry_started_at" =~ ^[0-9]+$ ]] || retry_started_at="$now"
        retry_attempt="$(scheduled_restart_value "$id" backend_retry_attempt)"
        [[ "$retry_attempt" =~ ^[0-9]+$ ]] || retry_attempt=0
        target_state="$(scheduled_restart_value "$id" backend_target_state)"
        [[ "$target_state" = up || "$target_state" = down ]] || target_state=down

        # 当恢复请求尚未确认时，必须优先恢复入池；若连接已经结束，恢复成功后
        # 再回到就绪队列重新走一次确认摘流，避免在状态不明时直接重启。
        if [[ "$target_state" = up ]]; then
            if ! set_backend "$id" up; then
                if queue_backend_retry_or_fail "$id" "$active" "$retry_started_at" "$retry_attempt" up; then
                    still_retry+=("$id")
                else
                    SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
                    SCHEDULE_CURRENT_FAILED=$((SCHEDULE_CURRENT_FAILED + 1))
                fi
                continue
            fi
            if [[ "$active" -gt 0 ]]; then
                ROUND_DEFERRED+=("$id")
                SCHEDULE_CURRENT_DEFERRED_TOTAL=$((SCHEDULE_CURRENT_DEFERRED_TOTAL + 1))
                write_deferred_restart_state "$id" "$active" "$retry_started_at" "$(next_deferred_check_at)"
                log "实例=${id} 后端池已恢复，仍有 ${active} 条连接，转入延后队列"
                continue
            fi
        fi
        if [[ "$active" -gt 0 ]]; then
            # 控制面等待期间若出现新会话，必须回到连接延后队列，不能继续尝试
            # 摘流；先同步确认恢复入池，再进入连接延后队列。
            if ! set_backend "$id" up; then
                if queue_backend_retry_or_fail "$id" "$active" "$retry_started_at" "$retry_attempt" up; then
                    still_retry+=("$id")
                else
                    SCHEDULE_CURRENT_COMPLETED=$((SCHEDULE_CURRENT_COMPLETED + 1))
                    SCHEDULE_CURRENT_FAILED=$((SCHEDULE_CURRENT_FAILED + 1))
                fi
                continue
            fi
            ROUND_DEFERRED+=("$id")
            SCHEDULE_CURRENT_DEFERRED_TOTAL=$((SCHEDULE_CURRENT_DEFERRED_TOTAL + 1))
            write_deferred_restart_state "$id" "$active" "$retry_started_at" "$(next_deferred_check_at)"
            log "实例=${id} 后端池重试期间出现 ${active} 条连接，转入延后队列"
            continue
        fi
        ROUND_READY+=("$id")
        SCHEDULE_QUEUE_IDS+=("$id")
        # 保留 retry attempt，让下一次工作任务允许处理已被异步提交为 down 的实例。
        write_scheduled_restart_state "$id" "${#SCHEDULE_QUEUE_IDS[@]}" "${#SCHEDULE_QUEUE_IDS[@]}" "$SCHEDULE_ROUND_STARTED_AT" "$now" "$retry_attempt"
        log "实例=${id} 后端池重试时间已到，已转入就绪队列再次摘流"
    done
    # Bash 3 在 set -u 下读取从未写入过的局部空数组会报错；与连接延后
    # 队列保持相同写法，显式重置为空数组。
    if [[ "${#still_retry[@]}" -gt 0 ]]; then
        ROUND_BACKEND_RETRY=("${still_retry[@]}")
    else
        ROUND_BACKEND_RETRY=()
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
    for id in "${ROUND_DEFERRED[@]-}" "${ROUND_BACKEND_RETRY[@]-}"; do
        [[ -n "$id" ]] && clear_scheduled_restart_state "$id"
    done
    ROUND_DEFERRED=()
    ROUND_BACKEND_RETRY=()
    clear_scheduled_restart_queue
}

run_round() {
    local id total concurrency active now remaining next_check_at completed_run_id
    local -a all_ids candidates
    # 本轮队列显式初始化，确保 Bash 3 与 set -u 组合下也可安全读取空队列。
    all_ids=()
    candidates=()
    ROUND_READY=()
    ROUND_DEFERRED=()
    ROUND_BACKEND_RETRY=()
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
    SCHEDULE_CURRENT_BACKEND_RETRY=0
    SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL=0
    SCHEDULE_CURRENT_MAX_BACKEND_RETRY=0
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
        SCHEDULE_LAST_BACKEND_RETRY=0
        SCHEDULE_LAST_MAX_QUEUED=0
        SCHEDULE_LAST_MAX_DEFERRED=0
        SCHEDULE_LAST_MAX_BACKEND_RETRY=0
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
    SCHEDULE_CURRENT_BACKEND_RETRY=0
    SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL=0
    SCHEDULE_CURRENT_MAX_BACKEND_RETRY=0
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
        SCHEDULE_LAST_BACKEND_RETRY=0
        SCHEDULE_LAST_MAX_QUEUED=0
        SCHEDULE_LAST_MAX_DEFERRED=0
        SCHEDULE_LAST_MAX_BACKEND_RETRY=0
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
    SCHEDULE_NEXT_BACKEND_RETRY_AT=0
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
    log "本轮调度已开始 | 总数=${total} | 可处理=${#candidates[@]} | 空闲就绪=${#ROUND_READY[@]} | 繁忙延后=${#ROUND_DEFERRED[@]} | 后端池重试=${#ROUND_BACKEND_RETRY[@]} | 延后复查=${SCHEDULE_DEFERRED_CHECK_INTERVAL_SECONDS}s | 最大并行=${concurrency} | 配置=${CONCURRENCY}"
    while [[ "$ROUND_NEXT" -lt "${#ROUND_READY[@]}" || "${#ROTATE_WORKER_PIDS[@]}" -gt 0 || "${#ROUND_DEFERRED[@]}" -gt 0 || "${#ROUND_BACKEND_RETRY[@]}" -gt 0 ]]; do
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
            if [[ "${#ROUND_BACKEND_RETRY[@]}" -gt 0 ]]; then
                recheck_backend_retry_queue
            fi
            # Bash 3 不支持 wait -n；短轮询同时保证完成实例能立即补位。
            sleep 0.1
        elif [[ "${#ROUND_DEFERRED[@]}" -gt 0 || "${#ROUND_BACKEND_RETRY[@]}" -gt 0 ]]; then
            now="$(date +%s)"
            next_check_at=0
            if [[ "${#ROUND_DEFERRED[@]}" -gt 0 ]]; then
                next_check_at="$SCHEDULE_NEXT_DEFERRED_CHECK_AT"
            fi
            if [[ "${#ROUND_BACKEND_RETRY[@]}" -gt 0 ]]; then
                if [[ "$next_check_at" -eq 0 || "$SCHEDULE_NEXT_BACKEND_RETRY_AT" -lt "$next_check_at" ]]; then
                    next_check_at="$SCHEDULE_NEXT_BACKEND_RETRY_AT"
                fi
            fi
            remaining=$((next_check_at - now))
            if [[ "$remaining" -gt 0 ]]; then
                sleep "$remaining"
                continue
            fi
            [[ "${#ROUND_DEFERRED[@]}" -eq 0 ]] || recheck_deferred_queue
            [[ "${#ROUND_BACKEND_RETRY[@]}" -eq 0 ]] || recheck_backend_retry_queue
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
    SCHEDULE_LAST_BACKEND_RETRY="$SCHEDULE_CURRENT_BACKEND_RETRY_TOTAL"
    SCHEDULE_LAST_MAX_QUEUED="$SCHEDULE_CURRENT_MAX_QUEUED"
    SCHEDULE_LAST_MAX_DEFERRED="$SCHEDULE_CURRENT_MAX_DEFERRED"
    SCHEDULE_LAST_MAX_BACKEND_RETRY="$SCHEDULE_CURRENT_MAX_BACKEND_RETRY"
    if [[ "$SCHEDULE_CURRENT_DEFERRED_COMPLETED" -gt 0 ]]; then
        SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=$((SCHEDULE_CURRENT_DEFERRED_WAIT_TOTAL_SECONDS / SCHEDULE_CURRENT_DEFERRED_COMPLETED))
    else
        SCHEDULE_LAST_AVG_DEFERRED_WAIT_SECONDS=0
    fi
    completed_run_id="$SCHEDULE_CURRENT_RUN_ID"
    SCHEDULE_LAST_RUN_ID="$completed_run_id"
    SCHEDULE_NEXT_DEFERRED_CHECK_AT=0
    SCHEDULE_NEXT_BACKEND_RETRY_AT=0
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

# “立即执行”是用户显式发起的一轮任务：它遵循原有空闲优先、延后队列和单飞锁，
# 但不受仅暂停后续定时轮次的暂停标记影响。
run_requested_round() {
    if ! enabled; then
        clear_schedule_run_now_request
        SCHEDULE_STATUS="disabled"
        SCHEDULE_RUNNING="no"
        SCHEDULE_NEXT_RUN_AT=0
        write_schedule_state
        return 1
    fi
    acquire_lock || {
        # 自动轮次和立即执行请求恰好竞争时保留请求，待已有轮次完成后继续处理。
        warn "已有滚动重启任务在执行，保留立即执行请求等待当前轮次完成"
        return 1
    }
    clear_schedule_run_now_request
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
        # 先处理显式请求，保证暂停自动计划时仍可手工立即执行一轮。
        if schedule_run_now_requested; then
            run_requested_round || sleep 1
            continue
        fi
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
            # 暂停标记和立即执行请求都可由管理页面写入；短轮询确保两者快速生效。
            sleep 1
            continue
        fi
        now="$(date +%s)"
        next_run=$((now + seconds))
        SCHEDULE_NEXT_RUN_AT="$next_run"
        set_schedule_waiting
        while true; do
            now="$(date +%s)"
            [[ "$now" -lt "$next_run" ]] || break
            schedule_run_now_requested && break
            if ! enabled || schedule_paused; then
                break
            fi
            remaining=$((next_run - now))
            # 除暂停外，也要在一秒内响应“立即执行”标记；等待期间无需频繁落盘。
            if [[ "$remaining" -gt 1 ]]; then sleep 1; else sleep "$remaining"; fi
        done
        if schedule_run_now_requested; then
            run_requested_round || sleep 1
            continue
        fi
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
