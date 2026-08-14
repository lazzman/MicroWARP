#!/usr/bin/env bash
# MicroWARP 实例控制入口，实际生命周期由 PID 1 的 entrypoint 管理。
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$APP_DIR/entrypoint.sh" --manage "$@"
