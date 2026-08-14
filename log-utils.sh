#!/usr/bin/env bash
# MicroWARP 控制台日志工具：统一组件、级别和事件标识，避免各进程重复打印时间戳。
# Docker 或编排平台负责附加时间戳；这里仅输出可检索的结构化前缀。

mw_log() {
    local level="${1:-INFO}" component="${2:-主进程}" normalized icon stream message
    shift 2 || true
    message="$*"
    message="${message//$'\n'/ }"
    normalized="$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')"

    case "$normalized" in
        OK|SUCCESS) level="OK"; icon="✓"; stream="/dev/stdout" ;;
        STEP)       level="INFO"; icon="▶"; stream="/dev/stdout" ;;
        WARN|WARNING) level="WARN"; icon="⚠"; stream="/dev/stderr" ;;
        ERROR|ERR)  level="ERROR"; icon="✗"; stream="/dev/stderr" ;;
        *)          level="INFO"; icon="ℹ"; stream="/dev/stdout" ;;
    esac

    # 每条消息保持单行，避免外部输入或命令输出破坏控制台日志结构。
    local line
    line="[MicroWARP][${component}][${level}] ${icon} ${message}"
    printf '%s\n' "$line" >"$stream"
    # 同步写入运行时日志文件，供管理面板实时展示；未配置时保持原有行为。
    if [ -n "${MICROWARP_LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$MICROWARP_LOG_FILE")" 2>/dev/null || true
        printf '%s\n' "$line" >>"$MICROWARP_LOG_FILE" 2>/dev/null || true
    fi
}

mw_info() { mw_log INFO "$@"; }
mw_ok() { mw_log OK "$@"; }
mw_step() { mw_log STEP "$@"; }
mw_warn() { mw_log WARN "$@"; }
mw_error() { mw_log ERROR "$@"; }

mw_section() {
    local component="${1:-主进程}" title="${2:-状态}"
    local line="[MicroWARP][${component}][INFO] ━━━ ${title} ━━━"
    printf '%s\n' "$line"
    if [ -n "${MICROWARP_LOG_FILE:-}" ]; then
        mkdir -p "$(dirname "$MICROWARP_LOG_FILE")" 2>/dev/null || true
        printf '%s\n' "$line" >>"$MICROWARP_LOG_FILE" 2>/dev/null || true
    fi
}

# 日志中不暴露上游 SOCKS5 URI 的用户名或密码。
mw_redact_uri() {
    local value="${1:-}" scheme host
    [ -n "$value" ] || { printf '%s\n' '(未配置)'; return 0; }
    if [[ "$value" == *://* ]]; then
        scheme="${value%%://*}"
        if [[ "$value" == *'@'* ]]; then
            host="${value##*@}"
            printf '%s://***@%s\n' "$scheme" "$host"
        else
            host="${value#*://}"
            printf '%s://%s\n' "$scheme" "$host"
        fi
    elif [[ "$value" == *'@'* ]]; then
        printf '***@%s\n' "${value##*@}"
    else
        printf '%s\n' "$value"
    fi
}
