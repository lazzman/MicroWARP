#!/usr/bin/env bash
# 验证实例工作进程会记录启动时间，并在停止后清理运行时元数据。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
worker_pid=""

cleanup() {
    if [[ -n "$worker_pid" ]]; then
        kill "$worker_pid" 2>/dev/null || true
    fi
    python3 - "$workdir" <<'PY'
from pathlib import Path
import shutil
import sys

shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT

cat > "${workdir}/worker.sh" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
while true; do
    sleep 30 &
    wait "$!"
done
EOF
chmod +x "${workdir}/worker.sh"

export MICROWARP_LIB_ONLY=1
export MICROWARP_RUNTIME_ROOT="${workdir}/runtime"
export MICROWARP_LOG_FILE="${workdir}/runtime/console.log"
export WG_CONF="${workdir}/wg0.conf"
export USQUE_CONFIG="${workdir}/masque-config.json"
export INSTANCE_COUNT=1
export PROXY_MODE=mixed
# shellcheck source=../entrypoint.sh
source "${ROOT}/entrypoint.sh"

# 使用睡眠脚本替代真实隧道工作进程，仅验证实例生命周期元数据。
SELF_PATH="${workdir}/worker.sh"
LB_ACTIVE=1
start_instance 0 >/dev/null

pid_file="$(instance_pid_file 0)"
started_at_file="$(instance_started_at_file 0)"
worker_pid="$(cat "$pid_file")"
started_at="$(cat "$started_at_file")"

kill -0 "$worker_pid"
[[ "$started_at" =~ ^[0-9]+$ ]] || {
    echo "断言失败：实例启动时间必须是 Unix 时间戳" >&2
    exit 1
}
[[ "$started_at" -le "$(date +%s)" ]] || {
    echo "断言失败：实例启动时间不能晚于当前时间" >&2
    exit 1
}

stop_instance 0 >/dev/null
[[ ! -e "$started_at_file" ]] || {
    echo "断言失败：停止实例后应清理启动时间元数据" >&2
    exit 1
}
worker_pid=""

echo "实例运行时启动时间测试通过"
