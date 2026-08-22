#!/usr/bin/env bash
# 使用实际 SOCKS 请求验证 WARP 状态，并原子更新 LB 后端池。
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log-utils.sh
source "${APP_DIR}/log-utils.sh"

INSTANCE_COUNT="${INSTANCE_COUNT:-1}"
RUNTIME_ROOT="${MICROWARP_RUNTIME_ROOT:-/run/microwarp}"
ALL_BACKENDS_FILE="${ALL_BACKENDS_FILE:-${RUNTIME_ROOT}/backends-all.txt}"
BACKENDS_FILE="${LB_BACKENDS_FILE:-${RUNTIME_ROOT}/backends.txt}"
BACKENDS_META_FILE="${BACKENDS_META_FILE:-${RUNTIME_ROOT}/backends.meta}"
MICROWARP_DYNAMIC_INSTANCES_FILE="${MICROWARP_DYNAMIC_INSTANCES_FILE:-${RUNTIME_ROOT}/instances.dynamic}"
# 内置 LB 会原子写入每个后端的活跃转发连接数；直连 microsocks/usque 路径没有
# 这一层观测点，因此状态表必须明确显示不可用，而不是误报为 0。
CONNECTION_FILE="${LB_CONNECTION_STATE_FILE:-${RUNTIME_ROOT}/lb-connections.txt}"
HEALTH_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_TIMEOUT="${HEALTH_PROBE_TIMEOUT:-10}"
SOFT_FAILURES="${HEALTH_SOFT_FAILURES:-3}"
START_PERIOD="${HEALTH_START_PERIOD:-90}"
STARTUP_RETRY_INTERVAL="${HEALTH_STARTUP_RETRY_INTERVAL:-3}"
# 全局最多同时运行多少个实际 HTTP 探测；默认 32，避免实例数较大时瞬间打满网络和 CPU。
HEALTH_PROBE_CONCURRENCY="${HEALTH_PROBE_CONCURRENCY:-32}"
[[ "$HEALTH_PROBE_CONCURRENCY" =~ ^[0-9]+$ ]] && [[ "$HEALTH_PROBE_CONCURRENCY" -gt 0 ]] || HEALTH_PROBE_CONCURRENCY=32
# 1：首次观测或实例状态/出口/后端池变化时，在控制台输出完整实例状态表；0：关闭表格。
STATUS_EVENT_LOG="${STATUS_EVENT_LOG:-1}"
# 后端池采用单锁原子批量提交。实例启动时会同时完成探测，锁竞争等待必须覆盖
# 整个启动收敛窗口；0 表示持续等待。默认 90 秒，远高于旧版固定 5 秒。
BACKEND_POOL_LOCK_TIMEOUT="${BACKEND_POOL_LOCK_TIMEOUT:-90}"
# 创建锁目录后、写入 owner 前进程可能异常退出。没有 owner 或 owner 已失效的锁在
# 该时限后会被安全回收，避免所有入池/摘流请求永久积压。
BACKEND_POOL_STALE_LOCK_TIMEOUT="${BACKEND_POOL_STALE_LOCK_TIMEOUT:-30}"
# 同一健康轮次中，先把每个实例的目标状态写入请求文件，再由唯一提交者合并写入
# backends.meta/backends.txt。短暂合并窗口可把数百次“逐实例重建”降为少量批次。
BACKEND_POOL_BATCH_WINDOW_MS="${BACKEND_POOL_BATCH_WINDOW_MS:-100}"
PROXY_MODE="${PROXY_MODE:-socks5}"
LB_ACTIVE="${LB_ACTIVE:-0}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
BIND_PORT="${BIND_PORT:-1080}"
INTERNAL_PROXY_PORT="${INTERNAL_PROXY_PORT:-1081}"
SOCKS_USER="${SOCKS_USER:-${PROXY_USER:-}}"
SOCKS_PASS="${SOCKS_PASS:-${PROXY_PASS:-}}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"

[[ "$STARTUP_RETRY_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$STARTUP_RETRY_INTERVAL" -gt 0 ]] || STARTUP_RETRY_INTERVAL=3
[[ "$BACKEND_POOL_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || BACKEND_POOL_LOCK_TIMEOUT=90
[[ "$BACKEND_POOL_STALE_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || BACKEND_POOL_STALE_LOCK_TIMEOUT=30
[[ "$BACKEND_POOL_STALE_LOCK_TIMEOUT" -ge 1 ]] || BACKEND_POOL_STALE_LOCK_TIMEOUT=30
[[ "$BACKEND_POOL_BATCH_WINDOW_MS" =~ ^[0-9]+$ ]] || BACKEND_POOL_BATCH_WINDOW_MS=100
BACKEND_POOL_BATCH_WINDOW_MS=$(( BACKEND_POOL_BATCH_WINDOW_MS < 5 ? 5 : BACKEND_POOL_BATCH_WINDOW_MS ))

# 该脚本既可由 PID 1 启动，也可被 docker exec 单独调用，不能依赖父进程导出。
if [[ "$INSTANCE_COUNT" -gt 1 || "$PROXY_MODE" = "mixed" || "${LB_ENABLED:-auto}" =~ ^(1|true|yes|on)$ || "${MANAGEMENT_UI_ENABLED:-0}" =~ ^(1|true|yes|on)$ ]]; then
    LB_ACTIVE=1
else
    LB_ACTIVE=0
fi

log() { mw_info "健康" "$*"; }
ok() { mw_ok "健康" "$*"; }
warn() { mw_warn "健康" "$*"; }

status_event_log_enabled() {
    case "$(printf '%s' "$STATUS_EVENT_LOG" | tr '[:upper:]' '[:lower:]')" in
        0|false|no|off) return 1 ;;
        *) return 0 ;;
    esac
}

backend_for() {
    local id="$1"
    if [[ "$INSTANCE_COUNT" -gt 1 ]]; then
        printf '10.64.%s.2:1080\n' "$id"
    elif [[ "$LB_ACTIVE" = "1" ]]; then
        printf '127.0.0.1:%s\n' "$INTERNAL_PROXY_PORT"
    else
        printf '127.0.0.1:%s\n' "$BIND_PORT"
    fi
}

proxy_url_for() {
    # remote：SOCKS 服务端解析域名（常规健康探测）；local：curl 使用 --resolve
    # 得到数值目标后再经 SOCKS 转发，用于强制 IPv4 / IPv6 出口观测。
    local backend="$1" resolution="${2:-remote}" scheme='socks5h'
    [[ "$resolution" = 'local' ]] && scheme='socks5'
    if [[ "$INSTANCE_COUNT" -gt 1 || "$LB_ACTIVE" = "1" ]]; then
        printf '%s://%s\n' "$scheme" "$backend"
    elif [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
        printf '%s://%s:%s@%s\n' "$scheme" "$SOCKS_USER" "$SOCKS_PASS" "$backend"
    else
        printf '%s://%s\n' "$scheme" "$backend"
    fi
}

state_file() { printf '%s/instances/%s/health.state' "$RUNTIME_ROOT" "$1"; }
fail_file() { printf '%s/instances/%s/failures' "$RUNTIME_ROOT" "$1"; }
started_at_file() { printf '%s/health.started_at' "$RUNTIME_ROOT"; }
status_signature_file() { printf '%s/instances/%s/status.signature' "$RUNTIME_ROOT" "$1"; }
manual_disabled_file() { printf '%s/instances/%s/manual.disabled' "$RUNTIME_ROOT" "$1"; }
management_lock_dir() { printf '%s/instances/%s/management.lock' "$RUNTIME_ROOT" "$1"; }
management_operation_file() { printf '%s/instances/%s/management.state' "$RUNTIME_ROOT" "$1"; }
backend_lock_dir() { printf '%s/backends.lock' "$RUNTIME_ROOT"; }
backend_pending_dir() { printf '%s/backends.pending' "$RUNTIME_ROOT"; }

operation_value() {
    local file="$1" key="$2"
    awk -F= -v key="$key" '$1 == key { value=substr($0, length(key) + 2) } END { print value }' "$file" 2>/dev/null
}

# 管理控制器会逐阶段记录这些时间。健康守护把超时操作改写为 recovered 时也
# 必须保留它们，否则最需要排障的“超时后恢复”恰好丢失启动与探测时间线。
MANAGEMENT_OPERATION_MILESTONES="idle_wait_started_at idle_confirmed_at backend_drained_at backend_restored_at instance_stop_started_at instance_stopped_at instance_start_started_at instance_started_at warp_probe_started_at warp_ready_at pool_rejoined_at probe_timed_out_at health_recovered_at"

reconcile_timed_out_management_operation() {
    # 管理操作达到探测上限后，健康守护可能在后续轮次才发现 WARP 已恢复。
    # 此时把终态从 failed 更新为 recovered，并保留首次超时的时间和原因，避免
    # 面板长期显示“失败”而实际节点已健康入池的状态分叉。
    local id="$1" target lock action status reason operation_id started_at timed_out_at timeout_duration
    local timeout_message now recovered_delay total_duration temporary milestone milestone_at
    target="$(management_operation_file "$id")"
    [[ -f "$target" ]] || return 0
    # 与管理控制器共用同一把实例锁：取得锁后才读取并改写状态文件，避免一个新
    # 操作刚开始时被本次较晚完成的健康探测覆盖为“超时后已恢复”。
    lock="$(management_lock_dir "$id")"
    mkdir "$lock" 2>/dev/null || return 0

    action="$(operation_value "$target" action)"
    status="$(operation_value "$target" status)"
    reason="$(operation_value "$target" reason_code)"
    if [[ "$status" != "failed" || "$reason" != "warp-probe-timeout" ]]; then
        rmdir "$lock" 2>/dev/null || true
        return 0
    fi
    case "$action" in
        enable|reconnect|force-reconnect) ;;
        *) rmdir "$lock" 2>/dev/null || true; return 0 ;;
    esac

    operation_id="$(operation_value "$target" operation_id)"
    started_at="$(operation_value "$target" started_at)"
    timed_out_at="$(operation_value "$target" finished_at)"
    [[ "$timed_out_at" =~ ^[0-9]+$ ]] || timed_out_at="$(operation_value "$target" updated_at)"
    [[ "$started_at" =~ ^[0-9]+$ ]] || started_at="$timed_out_at"
    if [[ ! "$timed_out_at" =~ ^[0-9]+$ ]]; then
        rmdir "$lock" 2>/dev/null || true
        return 0
    fi
    timeout_duration="$(operation_value "$target" duration_seconds)"
    [[ "$timeout_duration" =~ ^[0-9]+$ ]] || timeout_duration=$(( timed_out_at - started_at ))
    timeout_message="$(operation_value "$target" message)"
    now="$(date +%s)"
    recovered_delay=$(( now - timed_out_at ))
    [[ "$recovered_delay" -ge 0 ]] || recovered_delay=0
    total_duration=$(( now - started_at ))
    [[ "$total_duration" -ge 0 ]] || total_duration="$timeout_duration"
    temporary="${target}.${BASHPID:-$$}.${RANDOM}.tmp"
    {
        printf 'action=%s\n' "$action"
        printf 'status=recovered\n'
        printf 'message=WARP 已在超时后的健康探测中恢复并重新加入后端池\n'
        [[ -n "$operation_id" ]] && printf 'operation_id=%s\n' "$operation_id"
        printf 'started_at=%s\nupdated_at=%s\nfinished_at=%s\n' "$started_at" "$now" "$now"
        printf 'duration_seconds=%s\nphase=recovered\n' "$total_duration"
        printf 'timed_out_at=%s\ntimeout_duration_seconds=%s\n' "$timed_out_at" "$timeout_duration"
        printf 'timeout_reason_code=warp-probe-timeout\n'
        [[ -n "$timeout_message" ]] && printf 'timeout_message=%s\n' "${timeout_message//$'\n'/ }"
        for milestone in $MANAGEMENT_OPERATION_MILESTONES; do
            [[ "$milestone" = "health_recovered_at" ]] && continue
            milestone_at="$(operation_value "$target" "$milestone")"
            [[ "$milestone_at" =~ ^[0-9]+$ ]] && printf '%s=%s\n' "$milestone" "$milestone_at"
        done
        printf 'health_recovered_at=%s\n' "$now"
        printf 'recovered_at=%s\nrecovery_delay_seconds=%s\nrecovered_after_timeout=yes\n' "$now" "$recovered_delay"
    } > "$temporary"
    mv "$temporary" "$target"
    rmdir "$lock" 2>/dev/null || true
    ok "实例=${id} 超时后的 WARP 已恢复 | 操作状态=已恢复 | 等待=${recovered_delay}s"
}

sleep_milliseconds() {
    local milliseconds="$1" seconds
    # Alpine 的 sleep 支持小数秒；保留整数回退以兼容精简/旧环境。
    printf -v seconds '%d.%03d' "$((milliseconds / 1000))" "$((milliseconds % 1000))"
    sleep "$seconds" 2>/dev/null || sleep 1
}
runtime_instance_ids() {
    local id
    seq 0 $((INSTANCE_COUNT - 1))
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [ "$id" -ge "$INSTANCE_COUNT" ] && printf '%s\n' "$id"
    done < "$MICROWARP_DYNAMIC_INSTANCES_FILE" 2>/dev/null | sort -n -u
}

# 基础实例和当前容器生命周期内的临时实例都可被手工探测、摘流和恢复。
# 不要只比较 INSTANCE_COUNT：临时实例的 ID 从该值开始，若忽略动态文件，
# 管理面刚添加的实例会在首次主动探测时被错误拒绝，直到下一轮守护探测。
runtime_instance_exists() {
    local target="$1" id
    [[ "$target" =~ ^[0-9]+$ ]] || return 1
    while read -r id; do
        [[ "$id" = "$target" ]] && return 0
    done < <(runtime_instance_ids)
    return 1
}

# 状态表使用独立签名，刻意排除 checked_at，避免每轮健康探测都重复刷屏。
declare -a STATUS_ROUND_SNAPSHOTS
declare -a STATUS_ROUND_MARKS
STATUS_ROUND_NUMBER=0
STATUS_ROUND_CHANGED=0

begin_status_round() {
    STATUS_ROUND_SNAPSHOTS=()
    STATUS_ROUND_MARKS=()
    STATUS_ROUND_CHANGED=0
}

state_token_value() {
    local state="$1" key="$2" token
    for token in $state; do
        case "$token" in
            "${key}"=*) printf '%s\n' "${token#*=}"; return 0 ;;
        esac
    done
    printf '?\n'
}

backend_pool_state() {
    local id="$1" state
    state="$(awk -F= -v id="$id" '$1 == id {value=$2} END {print value}' "$BACKENDS_META_FILE" 2>/dev/null)"
    case "$state" in
        up) printf 'up\n' ;;
        *) printf 'down\n' ;;
    esac
}

active_connections_for() {
    local id="$1" backend count
    # 仅 Mixed/LB 前端会维护 CONNECTION_FILE。单实例轻量直连路径中的连接由
    # microsocks/usque 直接处理，不能可靠地从控制面统计。
    if [[ "$LB_ACTIVE" != "1" ]]; then
        printf '—\n'
        return 0
    fi

    backend="$(backend_for "$id")"
    # 文件由 lb-proxy.py 以 rename 原子替换；即使刚好尚未创建，也按 0 条 LB
    # 活跃连接处理。按行累计可兼容手工排障时留下的重复地址记录。
    count="$(awk -F '\t' -v backend="$backend" '
        $1 == backend && $2 ~ /^[0-9]+$/ { total += $2 }
        END { print total + 0 }
    ' "$CONNECTION_FILE" 2>/dev/null || true)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$count"
}

instance_status_snapshot() {
    # 快照字段顺序：状态 | IPv4 出口 | IPv6 出口 | WARP | 国家 | PoP | 后端池 | 连续失败。
    # 保留旧 health.state 中单一 ip= 字段的兼容回退，避免升级瞬间状态表丢失出口信息。
    local id="$1" state pool ip ip4 ip6 warp loc colo failures
    pool="$(backend_pool_state "$id")"
    if [[ -f "$(manual_disabled_file "$id")" ]]; then
        printf 'disabled|?|?|?|?|?|%s|0\n' "$pool"
        return 0
    fi
    if [[ -f "${RUNTIME_ROOT}/instances/${id}/rotating" ]]; then
        printf 'rotating|?|?|?|?|?|%s|0\n' "$pool"
        return 0
    fi
    if [[ -f "${RUNTIME_ROOT}/instances/${id}/restarting" ]]; then
        printf 'restarting|?|?|?|?|?|%s|0\n' "$pool"
        return 0
    fi

    state="$(cat "$(state_file "$id")" 2>/dev/null || true)"
    case "$state" in
        ready*)
            ip="$(state_token_value "$state" ip)"
            ip4="$(state_token_value "$state" ip4)"
            ip6="$(state_token_value "$state" ip6)"
            # 兼容尚未写入 ip4/ip6 的旧状态文件：按字面地址族填入对应列。
            if [[ "$ip4" = '?' && "$ip" != '?' && "$ip" != *:* ]]; then ip4="$ip"; fi
            if [[ "$ip6" = '?' && "$ip" != '?' && "$ip" = *:* ]]; then ip6="$ip"; fi
            warp="$(state_token_value "$state" warp)"
            loc="$(state_token_value "$state" loc)"
            colo="$(state_token_value "$state" colo)"
            printf 'ready|%s|%s|%s|%s|%s|%s|0\n' "$ip4" "$ip6" "$warp" "$loc" "$colo" "$pool"
            ;;
        waiting*)
            printf 'waiting|?|?|?|?|?|%s|0\n' "$pool"
            ;;
        failed*)
            failures="$(state_token_value "$state" failures)"
            printf 'failed|?|?|?|?|?|%s|%s\n' "$pool" "$failures"
            ;;
        *)
            printf 'unknown|?|?|?|?|?|%s|0\n' "$pool"
            ;;
    esac
}

record_status_snapshot() {
    local id="$1" snapshot="$2" signature_file previous mark="·"
    signature_file="$(status_signature_file "$id")"
    previous="$(cat "$signature_file" 2>/dev/null || true)"
    if [[ -z "$previous" ]]; then
        mark="🆕"
        STATUS_ROUND_CHANGED=1
    elif [[ "$previous" != "$snapshot" ]]; then
        mark="🔄"
        STATUS_ROUND_CHANGED=1
    fi
    printf '%s\n' "$snapshot" > "$signature_file"
    STATUS_ROUND_SNAPSHOTS[$id]="$snapshot"
    STATUS_ROUND_MARKS[$id]="$mark"
}

format_status_row() {
    local id="$1" snapshot="$2" kind ip4 ip6 warp loc colo pool failures pool_label active
    IFS='|' read -r kind ip4 ip6 warp loc colo pool failures <<< "$snapshot"
    active="$(active_connections_for "$id")"
    # 管理页与控制台都统一以破折号表达未观测到的某一地址族出口。
    [[ "$ip4" = '?' || -z "$ip4" ]] && ip4='—'
    [[ "$ip6" = '?' || -z "$ip6" ]] && ip6='—'
    if [[ "$pool" = up ]]; then pool_label="🟢 已入池"; else pool_label="⚪ 摘流"; fi
    case "$kind" in
        ready)
            printf '✅ 实例=%-2s | WARP=%-4s | IPv4=%-15s | IPv6=%-39s | 国家=%-2s | 节点=%-3s | 活跃连接=%-3s | %s' \
                "$id" "$warp" "$ip4" "$ip6" "$loc" "$colo" "$active" "$pool_label"
            ;;
        waiting)
            printf '⏳ 实例=%-2s | 启动探测中                       | 活跃连接=%-3s | %s' "$id" "$active" "$pool_label"
            ;;
        failed)
            printf '❌ 实例=%-2s | WARP 探测失败 | 连续失败=%-3s | 活跃连接=%-3s | %s' "$id" "$failures" "$active" "$pool_label"
            ;;
        rotating)
            printf '⏸️  实例=%-2s | 正在滚动重启，暂不探测          | 活跃连接=%-3s | %s' "$id" "$active" "$pool_label"
            ;;
        restarting)
            printf '🔧 实例=%-2s | 正在手动/自愈重启，暂不探测      | 活跃连接=%-3s | %s' "$id" "$active" "$pool_label"
            ;;
        disabled)
            printf '⏹️  实例=%-2s | 已由管理面板手动停用            | 活跃连接=%-3s | %s' "$id" "$active" "$pool_label"
            ;;
        *)
            printf '❔ 实例=%-2s | 尚未取得健康状态                 | 活跃连接=%-3s | %s' "$id" "$active" "$pool_label"
            ;;
    esac
}

emit_status_table_if_changed() {
    # 双出口列比旧版更宽，边框同步加宽以保持控制台表格对齐。
    local id snapshot mark kind border ready=0 waiting=0 failed=0 maintenance=0 unknown=0
    [[ "$STATUS_ROUND_CHANGED" -eq 1 ]] || return 0
    STATUS_ROUND_NUMBER=$((STATUS_ROUND_NUMBER + 1))
    status_event_log_enabled || return 0

    border="$(printf '─%.0s' {1..172})"
    mw_section "状态" "实例状态变化 · 第 ${STATUS_ROUND_NUMBER} 轮"
    mw_info "状态" "图例 | 🆕 首次观测 · 🔄 本轮变化 · · 未变化"
    mw_info "状态" "┌────┬${border}┐"
    for id in $(runtime_instance_ids); do
        snapshot="${STATUS_ROUND_SNAPSHOTS[$id]:-unknown|?|?|?|?|?|down|0}"
        mark="${STATUS_ROUND_MARKS[$id]:-·}"
        mw_info "状态" "│ ${mark} │ $(format_status_row "$id" "$snapshot") │"
        kind="${snapshot%%|*}"
        case "$kind" in
            ready) ready=$((ready + 1)) ;;
            waiting) waiting=$((waiting + 1)) ;;
            failed) failed=$((failed + 1)) ;;
            rotating|restarting|disabled) maintenance=$((maintenance + 1)) ;;
            *) unknown=$((unknown + 1)) ;;
        esac
    done
    mw_info "状态" "└────┴${border}┘"
    mw_info "状态" "📦 汇总 | ✅ 就绪=${ready} ⏳ 等待=${waiting} ❌ 异常=${failed} ⏸️ 维护=${maintenance} ❔ 未知=${unknown}"
}

within_start_period() {
    local started now
    [[ "$START_PERIOD" =~ ^[0-9]+$ ]] && [[ "$START_PERIOD" -gt 0 ]] || return 1
    started="$(cat "$(started_at_file)" 2>/dev/null || echo 0)"
    [[ "$started" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    ((now - started < START_PERIOD))
}

rebuild_backends() {
    local temporary id backend
    temporary="${BACKENDS_FILE}.$$"
    : > "$temporary"
    # 这里处于后端池全局锁内。旧实现每处理一个实例都启动一次 awk；大规模
    # 并发就绪时，锁持有时间会随实例数平方增长，后续实例甚至会在 5 秒锁
    # 等待上限前超时。一次扫描元数据后按 ID 输出，能让每个就绪实例快速入池。
    while read -r id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        backend="$(backend_for "$id")"
        printf '%s\n' "$backend" >> "$temporary"
    done < <(awk -F= '$1 ~ /^[0-9]+$/ && $2 == "up" { print $1 }' "$BACKENDS_META_FILE" 2>/dev/null | sort -n -u)
    mv "$temporary" "$BACKENDS_FILE"
}

backend_pending_updates_exist() {
    find "$(backend_pending_dir)" -mindepth 1 -maxdepth 1 -type f -name '[0-9]*' -print -quit 2>/dev/null | grep -q .
}

file_mtime_seconds() {
    local path="$1"
    # Alpine/GNU 使用 -c，macOS/BSD 使用 -f；测试与容器两端都要可用。
    stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null || echo 0
}

recover_stale_backend_lock() {
    local lock="$1" owner modified now age
    owner="$(cat "${lock}/owner" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        warn "回收遗留后端池锁 | 进程=${owner}"
        rm -rf "$lock"
        return 0
    fi
    # 有存活 owner 的提交者仍在工作，绝不能抢占它。只有 owner 缺失/损坏时，
    # 才根据目录年龄回收创建窗口中遗留的锁。
    [[ -n "$owner" ]] && return 0
    modified="$(file_mtime_seconds "$lock")"
    [[ "$modified" =~ ^[0-9]+$ ]] || modified=0
    now="$(date +%s)"
    age=$((now - modified))
    [[ "$age" -ge 0 ]] || age=0
    if [[ "$age" -ge "$BACKEND_POOL_STALE_LOCK_TIMEOUT" ]]; then
        warn "回收无 owner 的遗留后端池锁 | 存在=${age}s"
        rm -rf "$lock"
    fi
}

commit_pending_backend_updates() {
    local pending temporary manifest request
    pending="$(backend_pending_dir)"
    touch "$BACKENDS_META_FILE"
    temporary="${BACKENDS_META_FILE}.$$.$RANDOM"
    manifest="${pending}/.batch.${BASHPID:-$$}.${RANDOM}"
    # 每个请求使用唯一文件名。先固定本批次清单，再处理清单内请求并仅删除
    # 这些文件；合并期间新到的请求会留给下一小批，绝不会被误删。
    find "$pending" -mindepth 1 -maxdepth 1 -type f -name '[0-9]*' -print > "$manifest" 2>/dev/null || true
    [[ -s "$manifest" ]] || { rm -f "$manifest"; return 0; }
    # 合并时一次性重建元数据和可用后端列表。这样 200 个实例同时 ready 只需
    # 极少次数的全量扫描，不再让每个实例依次持锁重建整个池。
    {
        cat "$BACKENDS_META_FILE" 2>/dev/null || true
        while read -r request; do cat "$request" 2>/dev/null || true; done < "$manifest"
    } | awk -F= '$1 ~ /^[0-9]+$/ && ($2 == "up" || $2 == "down") { state[$1] = $2 } END { for (id in state) print id "=" state[id] }' \
        | sort -t= -k1,1n > "$temporary"
    mv "$temporary" "$BACKENDS_META_FILE"
    while read -r request; do rm -f "$request"; done < "$manifest"
    rm -f "$manifest"
    rebuild_backends
}

flush_pending_backend_updates() {
    local lock="$1"
    # 短暂聚合同时完成的探测结果；处理期间新到的请求仍会进入 pending 目录，
    # 由下面的循环继续合并，直到当前批次真正排空。
    while backend_pending_updates_exist; do
        sleep_milliseconds "$BACKEND_POOL_BATCH_WINDOW_MS"
        commit_pending_backend_updates
    done
    rm -f "${lock}/owner" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
}

update_backend() {
    local id="$1" target_state="$2" completion_mode="${3:-async}"
    local lock pending request temporary_request started elapsed observed
    [[ "$id" =~ ^[0-9]+$ ]] || return 2
    [[ "$target_state" = up || "$target_state" = down ]] || return 2
    [[ "$completion_mode" = async || "$completion_mode" = confirmed ]] || return 2
    mkdir -p "$RUNTIME_ROOT"
    pending="$(backend_pending_dir)"
    mkdir -p "$pending"
    request="${pending}/${id}.${BASHPID:-$$}.${RANDOM}"
    # 先原子登记请求再争抢提交者角色；抢锁失败也不会丢失本次更新。
    temporary_request="${request}.tmp"
    printf '%s=%s\n' "$id" "$target_state" > "$temporary_request"
    mv "$temporary_request" "$request"
    lock="$(backend_lock_dir)"
    started="$(date +%s)"

    while true; do
        if mkdir "$lock" 2>/dev/null; then
            printf '%s\n' "${BASHPID:-$$}" > "${lock}/owner"
            flush_pending_backend_updates "$lock"
            if [[ "$completion_mode" = async ]]; then
                return 0
            fi
            observed="$(backend_pool_state "$id")"
            if [[ "$observed" = "$target_state" ]]; then
                return 0
            fi
            warn "后端池状态被并发更新覆盖 | 实例=${id} | 期望=${target_state} | 实际=${observed}"
            return 76
        fi
        # 本请求已经被当前提交者合并。显式摘流/恢复必须再确认最终元数据，
        # 否则并发更新覆盖 down 后仍可能重启一个仍在后端池中的实例。
        if [[ ! -e "$request" ]]; then
            if [[ "$completion_mode" = async ]]; then
                return 0
            fi
            observed="$(backend_pool_state "$id")"
            if [[ "$observed" = "$target_state" ]]; then
                return 0
            fi
            warn "后端池状态被并发更新覆盖 | 实例=${id} | 期望=${target_state} | 实际=${observed}"
            return 76
        fi
        recover_stale_backend_lock "$lock"
        elapsed=$(( $(date +%s) - started ))
        # 异步健康结果即使超时也要保留请求，供下一位提交者合并；但摘流、恢复
        # 等破坏性操作必须拿到“已写入目标状态”的确认才能继续。
        if [[ "$BACKEND_POOL_LOCK_TIMEOUT" -ne 0 && "$elapsed" -ge "$BACKEND_POOL_LOCK_TIMEOUT" ]]; then
            if [[ "$completion_mode" = confirmed ]]; then
                warn "后端池状态确认超时 | 实例=${id} | 目标=${target_state} | 等待=${elapsed}s | 请求已保留"
                return 75
            fi
            return 0
        fi
        sleep_milliseconds 20
    done
}

confirm_warp_ready() {
    local id="$1"
    [[ "$id" =~ ^[0-9]+$ ]] || return 2
    # 已手工停用的实例不能因旧 ready 状态或外部 ready 调用被重新入池。
    [[ ! -f "$(manual_disabled_file "$id")" ]] || return 1
    # 每次恢复确认都强制重新运行主 WARP 探测，不能因管理锁或重启前残留的
    # ready 状态误判新进程已经可用。主探测成功后再同步确认 up 已提交到后端池。
    MANAGEMENT_FORCE_PROBE=1 check_one "$id" || true
    grep -q '^ready ' "$(state_file "$id")" 2>/dev/null || return 1
    update_backend "$id" up confirmed
}

probe_instance() {
    local id="$1" backend proxy output
    backend="$(backend_for "$id")"
    proxy="$(proxy_url_for "$backend")"
    output="$(curl -fsS --max-time "$HEALTH_TIMEOUT" --connect-timeout "$((HEALTH_TIMEOUT > 2 ? HEALTH_TIMEOUT - 1 : 1))" \
        --proxy "$proxy" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if grep -qE '^warp=(on|plus)$' <<<"$output"; then
        printf '%s\n' "$output"
        return 0
    fi
    return 1
}

# 使用数值 Cloudflare 地址固定目标协议族，同时保留 www.cloudflare.com 的 TLS SNI。
# 此探测仅用于记录双栈出口，不影响既有主健康探测的入池判定。
probe_instance_family() {
    local id="$1" family="$2" backend proxy output resolved
    backend="$(backend_for "$id")"
    # socks5:// 让 curl 在本地应用 --resolve；socks5h:// 会把域名原样交给
    # 后端解析，从而忽略本次为双栈观测指定的数值地址。
    proxy="$(proxy_url_for "$backend" local)"
    case "$family" in
        4) resolved='104.16.124.96' ;;
        6) resolved='2606:4700::0011' ;;
        *) return 2 ;;
    esac
    # 不能给 curl 传 -4 / -6：多实例后端 SOCKS 始终是 10.64.x.2 的 IPv4
    # 地址，Alpine curl 在 -6 下会先拒绝连接这个 IPv4 代理。--resolve 已把
    # 最终 SOCKS CONNECT 目标固定成对应协议族的数值地址，足以完成双栈观测。
    output="$(curl -fsS --max-time "$HEALTH_TIMEOUT" --connect-timeout "$((HEALTH_TIMEOUT > 2 ? HEALTH_TIMEOUT - 1 : 1))" \
        --proxy "$proxy" --resolve "www.cloudflare.com:443:${resolved}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    if grep -qE '^warp=(on|plus)$' <<<"$output"; then
        printf '%s\n' "$output"
        return 0
    fi
    return 1
}

# HEALTH_PROBE_CONCURRENCY 约束的是实际 curl 探测，而非实例工作流数量。
# 一个实例会同时请求 WARP 主探测和最多两类出口观测；若只限制外层实例数，
# 实际网络并发会放大为 2～3 倍。因此使用运行时目录中的跨子进程令牌池，
# 让健康守护、手工 probe 以及管理面强制 probe 共享同一上限。
probe_slot_root() { printf '%s/probe-slots' "$RUNTIME_ROOT"; }

acquire_probe_slot() {
    local root slot id owner
    root="$(probe_slot_root)"
    mkdir -p "$root"
    while true; do
        for id in $(seq 1 "$HEALTH_PROBE_CONCURRENCY"); do
            slot="${root}/${id}"
            if mkdir "$slot" 2>/dev/null; then
                # Bash 4+ 的 BASHPID 可识别后台子 shell；Alpine 旧环境回退
                # 到 $$，仍能在整个健康守护退出后回收遗留令牌。
                printf '%s\n' "${BASHPID:-$$}" > "${slot}/owner"
                HEALTH_PROBE_SLOT="$slot"
                return 0
            fi
            # 容器内旧健康进程异常退出时，回收其遗留令牌。owner 尚未写入
            # 的极短初始化窗口不可回收，避免与正在成功获取令牌的进程竞争。
            owner="$(cat "${slot}/owner" 2>/dev/null || true)"
            if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
                rm -rf "$slot" 2>/dev/null || true
            fi
        done
        sleep 0.05
    done
}

release_probe_slot() {
    local slot="${1:-}"
    [[ -n "$slot" ]] || return 0
    rm -f "${slot}/owner" 2>/dev/null || true
    rmdir "$slot" 2>/dev/null || true
}

run_with_probe_slot() {
    local slot status
    acquire_probe_slot
    slot="$HEALTH_PROBE_SLOT"
    trap 'release_probe_slot "$slot"' EXIT INT TERM
    if "$@"; then status=0; else status=$?; fi
    release_probe_slot "$slot"
    trap - EXIT INT TERM
    return "$status"
}

trace_value() {
    local output="$1" key="$2"
    sed -n "s/^${key}=//p" <<<"$output" | head -n 1
}

ipv6_enabled() {
    case "$(printf '%s' "$ENABLE_IPV6" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

check_one() {
    local id="$1" failures output ip warp loc colo output4 output6 ip4 ip6 warp4 warp6 loc4 loc6 colo4 colo6
    local probe_dir primary_file family4_file family6_file primary_pid family4_pid family6_pid
    if [[ -f "$(manual_disabled_file "$id")" ]]; then
        update_backend "$id" down || true
        return 0
    fi
    if [[ "${MANAGEMENT_FORCE_PROBE:-0}" != "1" && -d "$(management_lock_dir "$id")" ]]; then
        log "实例=${id} 正在执行管理操作，本轮跳过探测"
        return 0
    fi
    if [[ "${MANAGEMENT_FORCE_PROBE:-0}" != "1" && ( -f "${RUNTIME_ROOT}/instances/${id}/rotating" || -f "${RUNTIME_ROOT}/instances/${id}/restarting" ) ]]; then
        log "实例=${id} 正在滚动/手动重启，本轮跳过探测"
        return 0
    fi
    # 主 WARP、IPv4 出口和 IPv6 出口彼此独立，使用独立临时文件并行执行。
    # 主探测仍是唯一的入池判据；双栈探测失败只会留下对应的“未知”字段。
    probe_dir="$(mktemp -d "${RUNTIME_ROOT}/instances/${id}/probe.XXXXXX")"
    primary_file="${probe_dir}/primary"
    family4_file="${probe_dir}/ipv4"
    family6_file="${probe_dir}/ipv6"
    (run_with_probe_slot probe_instance "$id" || true) >"$primary_file" 2>/dev/null &
    primary_pid="$!"
    (run_with_probe_slot probe_instance_family "$id" 4 || true) >"$family4_file" 2>/dev/null &
    family4_pid="$!"
    family6_pid=''
    if ipv6_enabled; then
        (run_with_probe_slot probe_instance_family "$id" 6 || true) >"$family6_file" 2>/dev/null &
        family6_pid="$!"
    fi
    # WARP 主探测是入池唯一判据。优先等待它；一旦成功便立即入池，不能被
    # 仅用于展示的 IPv4 / IPv6 出口观测拖慢。
    wait "$primary_pid" || true
    output="$(cat "$primary_file" 2>/dev/null || true)"

    if grep -qE '^warp=(on|plus)$' <<<"$output"; then
        ip="$(trace_value "$output" ip)"
        warp="$(trace_value "$output" warp)"
        loc="$(trace_value "$output" loc)"
        colo="$(trace_value "$output" colo)"

        # 先写入最小 ready 状态并立即加入后端池。双栈观测完成后会覆盖
        # 该状态文件补齐出口字段，但绝不影响已经可用的代理后端。
        grep -q '^ready ' "$(state_file "$id")" 2>/dev/null || \
            ok "实例=${id} WARP 主探测已通过 | WARP=${warp:-?} | 已加入后端池 | 双栈出口观测继续"
        printf 'ready ip=%s ip4=? ip6=? warp=%s warp4=? warp6=? loc=%s colo=%s loc4=? colo4=? loc6=? colo6=? checked_at=%s\n' \
            "${ip:-?}" "${warp:-?}" "${loc:-?}" "${colo:-?}" "$(date +%s)" > "$(state_file "$id")"
        printf '0\n' > "$(fail_file "$id")"
        update_backend "$id" up
        reconcile_timed_out_management_operation "$id"

        # 入池后继续等待并收集可选的双栈出口观测。它们失败或超时只会使
        # 对应字段保持 ?，不会将已就绪实例从池中摘除。
        wait "$family4_pid" || true
        if [[ -n "$family6_pid" ]]; then
            wait "$family6_pid" || true
        fi
        output4="$(cat "$family4_file" 2>/dev/null || true)"
        output6="$(cat "$family6_file" 2>/dev/null || true)"
        ip4="$(trace_value "$output4" ip)"; warp4="$(trace_value "$output4" warp)"
        loc4="$(trace_value "$output4" loc)"; colo4="$(trace_value "$output4" colo)"
        ip6="$(trace_value "$output6" ip)"; warp6="$(trace_value "$output6" warp)"
        loc6="$(trace_value "$output6" loc)"; colo6="$(trace_value "$output6" colo)"
        printf 'ready ip=%s ip4=%s ip6=%s warp=%s warp4=%s warp6=%s loc=%s colo=%s loc4=%s colo4=%s loc6=%s colo6=%s checked_at=%s\n' \
            "${ip:-?}" "${ip4:-?}" "${ip6:-?}" "${warp:-?}" "${warp4:-?}" "${warp6:-?}" \
            "${loc:-?}" "${colo:-?}" "${loc4:-?}" "${colo4:-?}" "${loc6:-?}" "${colo6:-?}" "$(date +%s)" > "$(state_file "$id")"
        rm -rf "$probe_dir"
        return 0
    fi

    # 主探测失败时不读取双栈观测结果，但仍回收其子进程；避免 shell 函数内部
    # 的 curl 成为孤儿进程，从而确保并发窗口确实覆盖所有探测请求。
    wait "$family4_pid" || true
    if [[ -n "$family6_pid" ]]; then
        wait "$family6_pid" || true
    fi
    rm -rf "$probe_dir"

    # 启动宽限期只抑制自愈重启，不能延后首次成功探测入池；否则 Mixed/LB
    # 即使后端已就绪也会无后端可用长达 HEALTH_START_PERIOD。
    if within_start_period; then
        printf '0\n' > "$(fail_file "$id")"
        printf 'waiting checked_at=%s\n' "$(date +%s)" > "$(state_file "$id")"
        update_backend "$id" down
        return 0
    fi

    failures="$(cat "$(fail_file "$id")" 2>/dev/null || echo 0)"
    [[ "$failures" =~ ^[0-9]+$ ]] || failures=0
    failures=$((failures + 1))
    printf '%s\n' "$failures" > "$(fail_file "$id")"
    printf 'failed failures=%s checked_at=%s\n' "$failures" "$(date +%s)" > "$(state_file "$id")"
    update_backend "$id" down
    warn "实例=${id} WARP 探测失败 | 连续失败=${failures} | 操作=从后端池摘流"

    if [[ "$failures" -ge "$SOFT_FAILURES" ]]; then
        warn "实例=${id} 达到恢复阈值 | 操作=非破坏性重启"
        "$APP_DIR/instance-ctl.sh" restart "$id" >>"${RUNTIME_ROOT}/health.log" 2>&1 || \
            warn "实例=${id} 重启命令执行失败，等待下轮健康检查"
        printf '0\n' > "$(fail_file "$id")"
    fi
}

initialise() {
    mkdir -p "$RUNTIME_ROOT"
    date +%s > "$(started_at_file)"
    : > "$ALL_BACKENDS_FILE"
    : > "$BACKENDS_META_FILE"
    local id
    for id in $(runtime_instance_ids); do
        mkdir -p "${RUNTIME_ROOT}/instances/${id}"
        rm -f "$(status_signature_file "$id")"
        printf '%s\n' "$(backend_for "$id")" >> "$ALL_BACKENDS_FILE"
        printf '%s=down\n' "$id" >> "$BACKENDS_META_FILE"
    done
    : > "$BACKENDS_FILE"
}

once() {
    local id index pid active=0
    local -a probe_ids=() probe_pids=() probe_finished=()
    begin_status_round

    # 各实例之间相互独立，不能让某个慢实例的 curl 超时阻塞其余实例入池。
    # 采用动态并发窗口：有任务结束就立即补下一个，而不是分批等待整个批次，
    # 外层工作流和内部令牌池都使用 HEALTH_PROBE_CONCURRENCY：令牌池严格
    # 限制实际 HTTP 请求数，外层窗口则限制等待令牌的后台 shell 数量。
    # 全部任务结束后仍按实例 ID 顺序汇总，确保状态表和日志顺序稳定。
    for id in $(runtime_instance_ids); do
        while [[ "$active" -ge "$HEALTH_PROBE_CONCURRENCY" ]]; do
            for index in "${!probe_pids[@]}"; do
                [[ "${probe_finished[$index]:-0}" = 1 ]] && continue
                pid="${probe_pids[$index]}"
                if ! kill -0 "$pid" 2>/dev/null; then
                    wait "$pid" || true
                    probe_finished[$index]=1
                    active=$((active - 1))
                    break
                fi
            done
            # 尚无已完成任务时，短暂让出 CPU 后继续检查。Bash 3 不支持
            # wait -n，因此这里以兼容 Alpine 镜像的方式实现动态调度。
            [[ "$active" -lt "$HEALTH_PROBE_CONCURRENCY" ]] || sleep 0.05
        done
        # 用条件列表保留旧版 `check_one ... || true` 的 errexit 语义，避免
        # 后端池锁短暂竞争等单实例异常提前终止该实例的探测子进程。
        (check_one "$id" || true) &
        probe_ids+=("$id")
        probe_pids+=("$!")
        active=$((active + 1))
    done

    for index in "${!probe_ids[@]}"; do
        [[ "${probe_finished[$index]:-0}" = 1 ]] && continue
        # 单个实例探测失败由 check_one 自身负责记录；这里仅回收子进程，
        # 不让 set -e 因某个实例失败而终止健康守护进程。
        wait "${probe_pids[$index]}" || true
    done

    for id in "${probe_ids[@]}"; do
        record_status_snapshot "$id" "$(instance_status_snapshot "$id")"
    done
    emit_status_table_if_changed
}

docker_healthcheck() {
    local proxy output effective_lb="$LB_ACTIVE"
    if [[ "$INSTANCE_COUNT" -gt 1 || "$PROXY_MODE" = "mixed" || "${LB_ENABLED:-auto}" =~ ^(1|true|yes|on)$ || "${MANAGEMENT_UI_ENABLED:-0}" =~ ^(1|true|yes|on)$ ]]; then
        effective_lb=1
    fi
    if [[ "$effective_lb" = "1" ]]; then
        if [[ -n "$SOCKS_USER" && -n "$SOCKS_PASS" ]]; then
            proxy="socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${BIND_PORT}"
        else
            proxy="socks5h://127.0.0.1:${BIND_PORT}"
        fi
    else
        proxy="$(proxy_url_for "127.0.0.1:${BIND_PORT}")"
    fi
    output="$(run_with_probe_slot curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "$proxy" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    grep -qE '^warp=(on|plus)$' <<<"$output"
}

if [[ "${HEALTH_CHECK_LIB_ONLY:-0}" != "1" ]]; then
    case "${1:-daemon}" in
        daemon)
            initialise
            mw_section "健康" "健康守护已启动"
            mw_info "健康" "配置 | 实例=${INSTANCE_COUNT} | 启动宽限=${START_PERIOD}s | 启动探测=${STARTUP_RETRY_INTERVAL}s | HTTP并发=${HEALTH_PROBE_CONCURRENCY} | 常规间隔=${HEALTH_INTERVAL}s | 失败阈值=${SOFT_FAILURES} | 状态表=${STATUS_EVENT_LOG}"
            while true; do
                once
                if within_start_period; then
                    sleep "$STARTUP_RETRY_INTERVAL"
                else
                    sleep "$HEALTH_INTERVAL"
                fi
            done
            ;;
        once) once ;;
        pool)
            id="${2:-}"; status="${3:-}"
            runtime_instance_exists "$id" || { echo "实例 ID 非法" >&2; exit 1; }
            [[ "$status" = up || "$status" = down ]] || { echo "后端状态仅支持 up 或 down" >&2; exit 1; }
            # pool 是滚动重启和管理操作唯一的同步入口。仅在 backends.meta 已
            # 确认写入目标状态后返回成功，调用者据此决定是否可以停止实例。
            if update_backend "$id" "$status" confirmed; then
                exit 0
            else
                exit $?
            fi
            ;;
        probe)
            id="${2:-}"
            runtime_instance_exists "$id" || { echo "实例 ID 非法" >&2; exit 1; }
            check_one "$id" || true
            grep -q '^ready ' "$(state_file "$id")" 2>/dev/null
            ;;
        ready)
            id="${2:-}"
            runtime_instance_exists "$id" || { echo "实例 ID 非法" >&2; exit 1; }
            # 计划重启、优雅重连和强制重连共用的恢复完成条件：WARP 主探测通过，
            # 且后端池元数据已同步确认 up。调用方据此才能报告“实例已恢复”。
            confirm_warp_ready "$id"
            ;;
        docker) docker_healthcheck ;;
        *) echo "用法: $0 {daemon|once|pool|probe|ready|docker}"; exit 1 ;;
    esac
fi
