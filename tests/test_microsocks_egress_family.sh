#!/usr/bin/env bash
# 在已构建镜像中运行双栈 loopback 目标，验证 MicroSOCKS 返回真实出站地址族。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-microwarp-test:local}"
TEST_FILE="${ROOT}/tests/test_microsocks_egress_family.py"

docker image inspect "$IMAGE" >/dev/null

docker run --rm \
    -v "${TEST_FILE}:/tmp/test-microsocks-egress-family.py:ro" \
    --entrypoint /bin/bash "$IMAGE" -ec '
        microsocks -i 127.0.0.1 -p 1080 >/tmp/microsocks.log 2>&1 &
        microsocks_pid=$!
        trap "kill ${microsocks_pid} 2>/dev/null || true" EXIT
        for _ in $(seq 1 30); do
            if python3 - <<"PY" >/dev/null 2>&1
import socket
sock = socket.create_connection(("127.0.0.1", 1080), timeout=0.1)
sock.close()
PY
            then
                break
            fi
            sleep 0.05
        done
        python3 /tmp/test-microsocks-egress-family.py
    '
