#!/usr/bin/env bash
# 回归测试：空闲优先的限并发滚动重启会延后繁忙实例，并保持连续补位。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_ROOT="$(mktemp -d)"
RUNTIME_ROOT="${TMPDIR_ROOT}/run"
EVENTS_FILE="${TMPDIR_ROOT}/events.log"
ACTIVE_ROOT="${TMPDIR_ROOT}/active"
DAEMON_PID=""
ROUND_PID=""
cleanup() {
    if [[ -n "$DAEMON_PID" ]]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    if [[ -n "$ROUND_PID" ]]; then
        kill "$ROUND_PID" 2>/dev/null || true
        wait "$ROUND_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

fail() { echo "测试失败：$*" >&2; exit 1; }
assert_eq() { [[ "$1" = "$2" ]] || fail "期望=$1，实际=$2：${3:-}"; }
assert_file_missing() { [[ ! -e "$1" ]] || fail "文件不应存在：$1"; }

prepare_instances() {
    local id
    mkdir -p "${RUNTIME_ROOT}/instances"
    : > "${RUNTIME_ROOT}/instances.dynamic"
    : > "${RUNTIME_ROOT}/backends.meta"
    for id in $(seq 0 39); do
        mkdir -p "${RUNTIME_ROOT}/instances/${id}"
        printf 'ready checked_at=1\n' > "${RUNTIME_ROOT}/instances/${id}/health.state"
        printf '%s=up\n' "$id" >> "${RUNTIME_ROOT}/backends.meta"
    done
    # 已停用和未就绪实例不会占用本轮滚动并行槽位。
    : > "${RUNTIME_ROOT}/instances/37/manual.disabled"
    printf 'failed checked_at=1\n' > "${RUNTIME_ROOT}/instances/38/health.state"
    sed -i.bak 's/^38=up$/38=down/' "${RUNTIME_ROOT}/backends.meta"
    rmdir "${RUNTIME_ROOT}/instances/39" 2>/dev/null || true
    mkdir -p "${RUNTIME_ROOT}/instances/39/management.lock"
}

cat > "${TMPDIR_ROOT}/instance-ctl.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
id="$2"
state="${MICROWARP_RUNTIME_ROOT:?}/instances/${id}/rotation.state"
grep -qx 'action=rolling-restart' "$state"
grep -qx 'status=restarting' "$state"
grep -qx 'attempt=1' "$state"
grep -qx 'total_attempts=1' "$state"
mkdir -p "${TEST_ACTIVE_ROOT:?}/${id}"
active="$(find "${TEST_ACTIVE_ROOT}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
printf 'start %s active=%s\n' "$id" "$active" >> "${TEST_EVENTS_FILE:?}"
# 0 较快完成；1 很慢。其余任务足够长，以稳定观测 1/5 的并行额度。
# 若连续补位正确，8 会在 1 完成前启动。
if [[ "$id" = 0 ]]; then sleep 0.50; elif [[ "$id" = 1 ]]; then sleep 1.20; else sleep 0.50; fi
rmdir "${TEST_ACTIVE_ROOT}/${id}"
printf 'finish %s\n' "$id" >> "$TEST_EVENTS_FILE"
SH
cat > "${TMPDIR_ROOT}/health-check.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    # 滚动重启必须通过健康脚本的统一后端池入口，不再直接争抢 backends.lock。
    pool) exit 0 ;;
    probe|ready)
        id="$2"
        state="${MICROWARP_RUNTIME_ROOT:?}/instances/${id}/rotation.state"
        grep -qx 'action=rolling-restart' "$state"
        grep -qx 'status=probing' "$state"
        if [[ "${TEST_PROBE_FAIL_ID:-}" = "$id" ]]; then
            exit 1
        fi
        exit 0
        ;;
    *) exit 2 ;;
esac
SH
chmod +x "${TMPDIR_ROOT}/instance-ctl.sh" "${TMPDIR_ROOT}/health-check.sh"

prepare_instances
MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" \
INSTANCE_COUNT=40 \
ROTATE_RESTART_ENABLED=1 \
ROTATE_RESTART_CONCURRENCY=auto \
ROTATE_RESTART_RETRIES=0 \
ROTATE_RESTART_PROBE_TIMEOUT=5 \
MICROWARP_INSTANCE_CTL="${TMPDIR_ROOT}/instance-ctl.sh" \
MICROWARP_HEALTH_CHECK="${TMPDIR_ROOT}/health-check.sh" \
TEST_EVENTS_FILE="$EVENTS_FILE" \
TEST_ACTIVE_ROOT="$ACTIVE_ROOT" \
"${ROOT}/rotate-restart.sh" once >/dev/null

# 40 个总实例的 auto 为 8；37、38、39 被跳过，因此仅处理 37 个。
assert_eq 37 "$(grep -c '^start ' "$EVENTS_FILE")" "应只重启可用实例"
max_parallel="$(awk -F'active=' '/^start / { split($2, fields, " "); if (fields[1] > maximum) maximum=fields[1] } END { print maximum + 0 }' "$EVENTS_FILE")"
assert_eq 8 "$max_parallel" "auto 并行数应为实例总数的 1/5"
line_start_8="$(grep -n '^start 8 ' "$EVENTS_FILE" | cut -d: -f1)"
line_finish_1="$(grep -n '^finish 1$' "$EVENTS_FILE" | cut -d: -f1)"
[[ "$line_start_8" -lt "$line_finish_1" ]] || fail "完成的实例应立即补位，不能等待同组全部结束"
assert_file_missing "${RUNTIME_ROOT}/rotate-restart.lock"
assert_file_missing "${RUNTIME_ROOT}/instances/0/rotating"
assert_file_missing "${RUNTIME_ROOT}/instances/1/rotating"
assert_file_missing "${RUNTIME_ROOT}/instances/0/rotation.state"
assert_file_missing "${RUNTIME_ROOT}/instances/1/rotation.state"
assert_file_missing "${RUNTIME_ROOT}/instances/0/scheduled-restart.state"
assert_file_missing "${RUNTIME_ROOT}/instances/1/scheduled-restart.state"
schedule_state="${RUNTIME_ROOT}/rotate-restart.schedule.state"
[[ -f "$schedule_state" ]] || fail "应写入供管理页面读取的滚动重启计划状态"
assert_eq "success" "$(awk -F= '$1 == "last_status" { print $2 }' "$schedule_state")" "本轮结果应记录为成功"
assert_eq "37" "$(awk -F= '$1 == "last_total" { print $2 }' "$schedule_state")" "计划状态应记录本轮实例数"
assert_eq "37" "$(awk -F= '$1 == "last_succeeded" { print $2 }' "$schedule_state")" "计划状态应记录成功数量"
assert_eq "4" "$(awk -F= '$1 == "version" { print $2 }' "$schedule_state")" "计划状态应升级为可展示后端池重试队列和诊断的版本"

# 有活跃连接的实例不会被摘流或强制排空，而是保留在后端池；延后队列按配置复查。
prepare_instances
: > "$EVENTS_FILE"
printf '10.64.0.2:1080\t2\n' > "${RUNTIME_ROOT}/lb-connections.txt"
MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" \
INSTANCE_COUNT=40 \
ROTATE_RESTART_ENABLED=1 \
ROTATE_RESTART_CONCURRENCY=auto \
ROTATE_RESTART_DEFERRED_CHECK_INTERVAL=1 \
ROTATE_RESTART_RETRIES=0 \
ROTATE_RESTART_PROBE_TIMEOUT=5 \
MICROWARP_INSTANCE_CTL="${TMPDIR_ROOT}/instance-ctl.sh" \
MICROWARP_HEALTH_CHECK="${TMPDIR_ROOT}/health-check.sh" \
TEST_EVENTS_FILE="$EVENTS_FILE" \
TEST_ACTIVE_ROOT="$ACTIVE_ROOT" \
"${ROOT}/rotate-restart.sh" once >"${TMPDIR_ROOT}/deferred-round.log" 2>&1 &
ROUND_PID="$!"
for _ in $(seq 1 30); do
    deferred_state="${RUNTIME_ROOT}/instances/0/scheduled-restart.state"
    [[ -f "$deferred_state" ]] && [[ "$(awk -F= '$1 == "status" { print $2 }' "$deferred_state")" = "deferred" ]] && break
    sleep 0.1
done
assert_file_missing "${RUNTIME_ROOT}/instances/0/rotating"
assert_eq "up" "$(awk -F= '$1 == "0" { print $2 }' "${RUNTIME_ROOT}/backends.meta")" "延后实例必须继续留在后端池"
[[ -f "$deferred_state" ]] || fail "繁忙实例应写入延后状态"
assert_eq "deferred" "$(awk -F= '$1 == "status" { print $2 }' "$deferred_state")" "繁忙实例状态应为延后"
assert_eq "2" "$(awk -F= '$1 == "active_connections" { print $2 }' "$deferred_state")" "延后状态应记录当前连接数"
next_deferred_check="$(awk -F= '$1 == "next_check_at" { print $2 }' "$deferred_state")"
[[ "$next_deferred_check" =~ ^[0-9]+$ ]] || fail "延后状态应记录下次复查时间"
assert_eq 0 "$(grep -c '^start 0 ' "$EVENTS_FILE" || true)" "繁忙实例在复查前不得重启"
: > "${RUNTIME_ROOT}/lb-connections.txt"
wait "$ROUND_PID"
ROUND_PID=""
assert_eq 37 "$(grep -c '^start ' "$EVENTS_FILE")" "自然空闲后应在同一轮继续重启延后实例"
assert_eq "37" "$(awk -F= '$1 == "last_succeeded" { print $2 }' "$schedule_state")" "计划状态应统计延后实例最终成功"
assert_eq "1" "$(awk -F= '$1 == "last_deferred" { print $2 }' "$schedule_state")" "计划状态应单独统计延后实例"
assert_eq "0" "$(awk -F= '$1 == "last_failed" { print $2 }' "$schedule_state")" "繁忙实例不能被记为失败"

# 失败必须持久化为可供管理面读取的结构化诊断，而不是只有“失败数量”。
prepare_instances
: > "$EVENTS_FILE"
MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" \
INSTANCE_COUNT=40 \
ROTATE_RESTART_ENABLED=1 \
ROTATE_RESTART_CONCURRENCY=auto \
ROTATE_RESTART_RETRIES=0 \
ROTATE_RESTART_PROBE_TIMEOUT=5 \
MICROWARP_INSTANCE_CTL="${TMPDIR_ROOT}/instance-ctl.sh" \
MICROWARP_HEALTH_CHECK="${TMPDIR_ROOT}/health-check.sh" \
TEST_EVENTS_FILE="$EVENTS_FILE" \
TEST_ACTIVE_ROOT="$ACTIVE_ROOT" \
TEST_PROBE_FAIL_ID=0 \
"${ROOT}/rotate-restart.sh" once >/dev/null
assert_eq "partial" "$(awk -F= '$1 == "last_status" { print $2 }' "$schedule_state")" "存在单实例探测失败时本轮应标记为部分完成"
assert_eq "1" "$(awk -F= '$1 == "last_failed" { print $2 }' "$schedule_state")" "失败实例必须单独计数"
assert_eq "36" "$(awk -F= '$1 == "last_succeeded" { print $2 }' "$schedule_state")" "其他实例应继续完成，不被单个失败阻塞"
run_id="$(awk -F= '$1 == "last_run_id" { print $2 }' "$schedule_state")"
[[ "$run_id" =~ ^restart-[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "应记录可定位的执行轮次 ID"
history_dir="${RUNTIME_ROOT}/rotate-restart.history/runs/${run_id}"
[[ -f "${history_dir}/summary.state" ]] || fail "应保存本轮摘要"
[[ -f "${history_dir}/failures/0.state" ]] || fail "应保存失败实例诊断"
assert_eq "warp-probe-timeout" "$(awk -F= '$1 == "reason_code" { print $2 }' "${history_dir}/failures/0.state")" "探测失败必须写入原因码"
assert_eq "warp-probe" "$(awk -F= '$1 == "phase" { print $2 }' "${history_dir}/failures/0.state")" "探测失败必须写入失败阶段"

# 后端池摘流确认暂时失败不是“有连接延后”，应在同一轮进入独立的控制面
# 重试队列；确认成功后继续重启，不能把短暂锁竞争批量记为最终失败。
retry_runtime="${TMPDIR_ROOT}/backend-retry"
retry_events="${TMPDIR_ROOT}/backend-retry-events.log"
mkdir -p "${retry_runtime}/instances"
: > "${retry_runtime}/instances.dynamic"
: > "${retry_runtime}/backends.meta"
for id in 0 1; do
    mkdir -p "${retry_runtime}/instances/${id}"
    printf 'ready checked_at=1\n' > "${retry_runtime}/instances/${id}/health.state"
    printf '%s=up\n' "$id" >> "${retry_runtime}/backends.meta"
done
cat > "${TMPDIR_ROOT}/backend-pool-retry.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
id="${2:?}"
attempt_file="${MICROWARP_RUNTIME_ROOT:?}/pool-attempt-${id}"
attempt="$(cat "$attempt_file" 2>/dev/null || echo 0)"
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$attempt_file"
# 仅首个实例的首次摘流模拟“请求已被其他提交者落盘为 down、调用方仍未收到
# 确认”；重试必须识别这种安全中间状态，不能因它已摘流而错误跳过本轮。
if [[ "$id" = 0 && "$attempt" = 1 ]]; then
    sed -i.bak 's/^0=up$/0=down/' "${MICROWARP_RUNTIME_ROOT}/backends.meta"
    exit 75
fi
exit 0
SH
chmod +x "${TMPDIR_ROOT}/backend-pool-retry.sh"
: > "$retry_events"
MICROWARP_RUNTIME_ROOT="$retry_runtime" \
INSTANCE_COUNT=2 \
ROTATE_RESTART_ENABLED=1 \
ROTATE_RESTART_CONCURRENCY=1 \
ROTATE_RESTART_RETRIES=0 \
ROTATE_RESTART_PROBE_TIMEOUT=5 \
BACKEND_POOL_OPERATION_RETRY_LIMIT=2 \
BACKEND_POOL_OPERATION_RETRY_MAX_DELAY=1 \
MICROWARP_INSTANCE_CTL="${TMPDIR_ROOT}/instance-ctl.sh" \
MICROWARP_HEALTH_CHECK="${TMPDIR_ROOT}/health-check.sh" \
MICROWARP_BACKEND_POOL_COMMAND="${TMPDIR_ROOT}/backend-pool-retry.sh" \
TEST_EVENTS_FILE="$retry_events" \
TEST_ACTIVE_ROOT="$ACTIVE_ROOT" \
"${ROOT}/rotate-restart.sh" once >"${TMPDIR_ROOT}/backend-retry-round.log" 2>&1 &
ROUND_PID="$!"
for _ in $(seq 1 30); do
    retry_state="${retry_runtime}/instances/0/scheduled-restart.state"
    [[ -f "$retry_state" ]] && [[ "$(awk -F= '$1 == "status" { print $2 }' "$retry_state")" = "backend-retry" ]] && break
    sleep 0.1
done
[[ -f "$retry_state" ]] || fail "摘流未确认的实例应进入后端池重试队列"
assert_eq "backend-retry" "$(awk -F= '$1 == "queue" { print $2 }' "$retry_state")" "摘流未确认不得复用连接延后队列"
assert_eq "down" "$(awk -F= '$1 == "0" { print $2 }' "${retry_runtime}/backends.meta")" "未确认请求可由其他提交者先完成摘流，但实例不得在本轮直接重启"
wait "$ROUND_PID"
ROUND_PID=""
retry_schedule="${retry_runtime}/rotate-restart.schedule.state"
# 调用次数是实际退避重试的可靠断言：首个调用失败，第二个调用成功。
assert_eq "2" "$(cat "${retry_runtime}/pool-attempt-0")" "后端池确认失败应在同轮重试一次"
assert_eq "0" "$(awk -F= '$1 == "last_failed" { print $2 }' "$retry_schedule")" "短暂后端池竞争恢复后不得记为最终失败"
assert_eq "1" "$(awk -F= '$1 == "last_backend_retry" { print $2 }' "$retry_schedule")" "计划状态应统计控制面重试次数"

# 执行历史必须按配置裁剪，避免长时间运行的运行时目录无限增长。
prune_runtime="${TMPDIR_ROOT}/history-prune"
mkdir -p "${prune_runtime}/instances/0"
printf 'ready checked_at=1\n' > "${prune_runtime}/instances/0/health.state"
printf '0=up\n' > "${prune_runtime}/backends.meta"
: > "${prune_runtime}/instances.dynamic"
: > "${prune_runtime}/instances/0/manual.disabled"
for _ in 1 2 3; do
    MICROWARP_RUNTIME_ROOT="$prune_runtime" \
    INSTANCE_COUNT=1 \
    ROTATE_RESTART_ENABLED=1 \
    ROTATE_RESTART_HISTORY_LIMIT=2 \
    "${ROOT}/rotate-restart.sh" once >/dev/null
done
assert_eq "2" "$(find "${prune_runtime}/rotate-restart.history/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "执行历史应按保留轮数裁剪"

# 暂停标记由管理 API 写入；调度器必须跳过后续定时轮次而不影响已有历史记录。
touch "${RUNTIME_ROOT}/rotate-restart.paused"
starts_before_pause="$(grep -c '^start ' "$EVENTS_FILE")"
MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" \
INSTANCE_COUNT=40 \
ROTATE_RESTART_ENABLED=1 \
ROTATE_RESTART_CONCURRENCY=auto \
ROTATE_RESTART_RETRIES=0 \
ROTATE_RESTART_PROBE_TIMEOUT=5 \
MICROWARP_INSTANCE_CTL="${TMPDIR_ROOT}/instance-ctl.sh" \
MICROWARP_HEALTH_CHECK="${TMPDIR_ROOT}/health-check.sh" \
TEST_EVENTS_FILE="$EVENTS_FILE" \
TEST_ACTIVE_ROOT="$ACTIVE_ROOT" \
"${ROOT}/rotate-restart.sh" once >/dev/null
assert_eq "$starts_before_pause" "$(grep -c '^start ' "$EVENTS_FILE")" "暂停后不得开始新的滚动重启"
assert_eq "paused" "$(awk -F= '$1 == "status" { print $2 }' "$schedule_state")" "计划状态应明确显示已暂停"

# 守护进程在等待周期期间必须先写入下一次执行时间，管理页面才能显示倒计时。
rm -f "${RUNTIME_ROOT}/rotate-restart.paused"
# 前一轮故意制造过探测失败，先恢复独立的健康后端池，确保本用例只验证
# 守护进程对立即执行标记的响应时效，不受失败轮次的摘流结果影响。
prepare_instances
MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" \
INSTANCE_COUNT=40 \
ROTATE_RESTART_ENABLED=1 \
ROTATE_RESTART_INTERVAL=60s \
ROTATE_RESTART_CONCURRENCY=auto \
ROTATE_RESTART_RETRIES=0 \
ROTATE_RESTART_PROBE_TIMEOUT=5 \
MICROWARP_INSTANCE_CTL="${TMPDIR_ROOT}/instance-ctl.sh" \
MICROWARP_HEALTH_CHECK="${TMPDIR_ROOT}/health-check.sh" \
TEST_EVENTS_FILE="$EVENTS_FILE" \
TEST_ACTIVE_ROOT="$ACTIVE_ROOT" \
"${ROOT}/rotate-restart.sh" daemon >/dev/null 2>&1 &
DAEMON_PID="$!"
for _ in $(seq 1 20); do
    next_run_at="$(awk -F= '$1 == "next_run_at" { print $2 }' "$schedule_state")"
    [[ "$next_run_at" =~ ^[0-9]+$ ]] && [[ "$next_run_at" -gt "$(date +%s)" ]] && break
    sleep 0.1
done
[[ "$next_run_at" =~ ^[0-9]+$ ]] && [[ "$next_run_at" -gt "$(date +%s)" ]] || fail "守护进程应记录未来的下一次执行时间"
assert_eq "waiting" "$(awk -F= '$1 == "status" { print $2 }' "$schedule_state")" "等待周期时计划状态应为等待中"

# 管理 API 写入的立即执行标记不能等待完整周期；即使后续自动计划已经暂停，
# 守护进程仍应在短轮询内消费它，复用同一轮空闲优先、并发限制与调度锁，
# 而不是启动另一个并发调度器。
starts_before_run_now="$(grep -c '^start ' "$EVENTS_FILE" || true)"
touch "${RUNTIME_ROOT}/rotate-restart.paused"
printf 'requested_at=%s\n' "$(date +%s)" > "${RUNTIME_ROOT}/rotate-restart.run-now"
for _ in $(seq 1 40); do
    starts_after_run_now="$(grep -c '^start ' "$EVENTS_FILE" || true)"
    [[ "$starts_after_run_now" -gt "$starts_before_run_now" ]] && break
    sleep 0.1
done
[[ "$starts_after_run_now" -gt "$starts_before_run_now" ]] || fail "立即执行请求应在等待周期内启动滚动重启"
assert_file_missing "${RUNTIME_ROOT}/rotate-restart.run-now"
[[ -f "${RUNTIME_ROOT}/rotate-restart.paused" ]] || fail "立即执行不得恢复后续自动计划"

kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""

# auto 的 1/5 计算和用户显式请求都必须受硬上限约束；否则实例数很大时会
# 再次形成大批实例同时摘流、重启和探测的控制面尖峰。
auto_status="$(MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" INSTANCE_COUNT=100 ROTATE_RESTART_ENABLED=1 ROTATE_RESTART_CONCURRENCY=auto ROTATE_RESTART_MAX_CONCURRENCY=10 "${ROOT}/rotate-restart.sh" status)"
explicit_status="$(MICROWARP_RUNTIME_ROOT="$RUNTIME_ROOT" INSTANCE_COUNT=100 ROTATE_RESTART_ENABLED=1 ROTATE_RESTART_CONCURRENCY=50 ROTATE_RESTART_MAX_CONCURRENCY=10 "${ROOT}/rotate-restart.sh" status 2>/dev/null)"
auto_effective="$(printf '%s\n' "$auto_status" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^concurrency=/) { split($i, pair, "="); print pair[2] } }')"
explicit_effective="$(printf '%s\n' "$explicit_status" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^concurrency=/) { split($i, pair, "="); print pair[2] } }')"
assert_eq 10 "$auto_effective" "auto 的 1/5 并行数必须最多为 10"
assert_eq 10 "$explicit_effective" "显式请求的滚动重启并行数也必须最多为 10"

echo "通过：限并发滚动重启"
