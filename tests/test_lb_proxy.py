#!/usr/bin/env python3
"""验证内置 Mixed LB 的 SOCKS5 与 HTTP 转发语义。"""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LB_SPEC = importlib.util.spec_from_file_location("microwarp_lb_proxy", ROOT / "lb-proxy.py")
assert LB_SPEC and LB_SPEC.loader
LB_MODULE = importlib.util.module_from_spec(LB_SPEC)
LB_SPEC.loader.exec_module(LB_MODULE)


def reserve_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def receive_exact(sock: socket.socket, size: int) -> bytes:
    received = bytearray()
    while len(received) < size:
        chunk = sock.recv(size - len(received))
        if not chunk:
            raise ConnectionError("连接提前关闭")
        received.extend(chunk)
    return bytes(received)


class SocksEchoBackend:
    """仅用于验证 LB 是否以 SOCKS5 连接内部后端并保留转发数据。"""

    def __init__(self, success_atyp: int = 0x01) -> None:
        if success_atyp not in {0x01, 0x04}:
            raise ValueError("测试后端仅支持 IPv4 或 IPv6 成功响应")
        self.success_atyp = success_atyp
        self.port = reserve_port()
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", self.port))
        self._listener.listen()
        self._stop = threading.Event()
        self._request_count = 0
        self._request_lock = threading.Lock()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    @property
    def request_count(self) -> int:
        with self._request_lock:
            return self._request_count

    def start(self) -> None:
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                pass
        except OSError:
            pass
        self._thread.join(timeout=2)
        self._listener.close()

    def _serve(self) -> None:
        self._listener.settimeout(0.2)
        while not self._stop.is_set():
            try:
                client, _ = self._listener.accept()
            except socket.timeout:
                continue
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _handle(self, client: socket.socket) -> None:
        try:
            if receive_exact(client, 3) != b"\x05\x01\x00":
                return
            client.sendall(b"\x05\x00")
            request = receive_exact(client, 4)
            if request[:3] != b"\x05\x01\x00":
                return
            if request[3] == 3:
                receive_exact(client, receive_exact(client, 1)[0])
            elif request[3] == 1:
                receive_exact(client, 4)
            elif request[3] == 4:
                receive_exact(client, 16)
            else:
                return
            receive_exact(client, 2)
            with self._request_lock:
                self._request_count += 1
            if self.success_atyp == 0x04:
                client.sendall(b"\x05\x00\x00\x04" + b"\x00" * 18)
            else:
                client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            while data := client.recv(4096):
                client.sendall(data)
        except ConnectionError:
            # close() 为唤醒 accept 创建的空连接，无需报告。
            pass
        finally:
            client.close()


class MixedLoadBalancerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.backend = SocksEchoBackend()
        self.backend.start()
        self.tempdir = tempfile.TemporaryDirectory(prefix="microwarp-lb-test-")
        self.runtime = Path(self.tempdir.name)
        self.port = reserve_port()
        (self.runtime / "backends.txt").write_text(
            f"127.0.0.1:{self.backend.port}\n", encoding="utf-8"
        )
        self.lb: subprocess.Popen[bytes] | None = None
        self._start_lb()

    def _start_lb(self, overrides: dict[str, str] | None = None) -> None:
        env = os.environ | {
            "BIND_ADDR": "127.0.0.1",
            "BIND_PORT": str(self.port),
            "PROXY_MODE": "mixed",
            "LB_BACKENDS_FILE": str(self.runtime / "backends.txt"),
            "LB_CONNECTION_STATE_FILE": str(self.runtime / "connections.txt"),
            "MICROWARP_RUNTIME_ROOT": str(self.runtime),
        }
        if overrides:
            env.update(overrides)
        self.lb = subprocess.Popen(
            [sys.executable, str(ROOT / "lb-proxy.py")],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            self.fail("LB 未在测试时限内监听")

    def _http_request(self, request: bytes) -> tuple[int, dict[str, str], bytes]:
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(request)
            chunks = bytearray()
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                chunks.extend(chunk)
        header, _, body = bytes(chunks).partition(b"\r\n\r\n")
        lines = header.decode("iso-8859-1").split("\r\n")
        status = int(lines[0].split()[1])
        headers = {
            name.lower(): value.strip()
            for line in lines[1:]
            if ":" in line
            for name, value in [line.split(":", 1)]
        }
        return status, headers, body

    def _stop_lb(self) -> None:
        if self.lb is None:
            return
        self.lb.terminate()
        try:
            self.lb.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.lb.kill()
            self.lb.wait(timeout=2)
        self.lb = None

    def tearDown(self) -> None:
        self._stop_lb()
        self.backend.close()
        self.tempdir.cleanup()

    def test_access_log_backend_instance_label(self) -> None:
        """访问日志应直接输出多实例序号，单实例和未知地址也要可读。"""
        self.assertEqual(
            LB_MODULE.backend_access_fields(("10.64.12.2", 1080)),
            "后端实例=12 | 后端=10.64.12.2:1080",
        )
        self.assertEqual(
            LB_MODULE.backend_access_fields(("10.64.254.2", 1080)),
            "后端实例=254 | 后端=10.64.254.2:1080",
        )
        self.assertEqual(
            LB_MODULE.backend_access_fields(("127.0.0.1", 1081)),
            "后端实例=0 | 后端=127.0.0.1:1081",
        )
        self.assertEqual(
            LB_MODULE.backend_access_fields(("192.0.2.10", 1080)),
            "后端实例=? | 后端=192.0.2.10:1080",
        )

    def test_http_access_log_includes_identity_and_redacted_headers(self) -> None:
        """HTTP 访问日志应保留排障头信息，但绝不能泄漏客户端凭据。"""
        original_headers_enabled = LB_MODULE.ACCESS_LOG_HEADERS
        original_header_limit = LB_MODULE.ACCESS_LOG_HEADER_MAX_CHARS
        try:
            LB_MODULE.ACCESS_LOG_HEADERS = True
            LB_MODULE.ACCESS_LOG_HEADER_MAX_CHARS = 8192
            lines = [
                "GET http://example.com/path?q=1 HTTP/1.1",
                "Host: example.com",
                "User-Agent: MicroWARP-Test/1.0",
                "X-Request-ID: req-123",
                "Authorization: Bearer very-secret-token",
                "Proxy-Authorization: Basic c2VjcmV0OnBhc3M=",
                "Cookie: sid=super-secret",
            ]
            details = LB_MODULE.http_access_fields(lines)
            prefix = LB_MODULE.access_prefix("HTTP GET", "2001:db8::10", 44321, "alice")

            self.assertIn("请求行=GET http://example.com/path?q=1 HTTP/1.1", details)
            self.assertIn("Host=example.com", details)
            self.assertIn("User-Agent=MicroWARP-Test/1.0", details)
            self.assertIn("X-Request-ID=req-123", details)
            self.assertIn("Authorization=<已脱敏>", details)
            self.assertIn("Proxy-Authorization=<已脱敏>", details)
            self.assertIn("Cookie=<已脱敏>", details)
            self.assertNotIn("very-secret-token", details)
            self.assertNotIn("c2VjcmV0OnBhc3M=", details)
            self.assertNotIn("super-secret", details)
            self.assertIn("客户端=[2001:db8::10]:44321", prefix)
            self.assertIn("用户ID=alice", prefix)
        finally:
            LB_MODULE.ACCESS_LOG_HEADERS = original_headers_enabled
            LB_MODULE.ACCESS_LOG_HEADER_MAX_CHARS = original_header_limit

    def test_http_access_log_header_block_is_bounded(self) -> None:
        """客户端可控的超长请求头必须在访问日志中明确截断。"""
        original_headers_enabled = LB_MODULE.ACCESS_LOG_HEADERS
        original_header_limit = LB_MODULE.ACCESS_LOG_HEADER_MAX_CHARS
        try:
            LB_MODULE.ACCESS_LOG_HEADERS = True
            LB_MODULE.ACCESS_LOG_HEADER_MAX_CHARS = 32
            details = LB_MODULE.http_access_fields(
                ["GET / HTTP/1.1", "X-Long: " + "x" * 128]
            )
            self.assertIn("HTTP头=[", details)
            self.assertIn("…]", details)
            self.assertLessEqual(
                len(details.partition("HTTP头=[")[2].removesuffix("]")), 32
            )
        finally:
            LB_MODULE.ACCESS_LOG_HEADERS = original_headers_enabled
            LB_MODULE.ACCESS_LOG_HEADER_MAX_CHARS = original_header_limit

    def test_username_round_is_uniform_and_sticky_in_memory(self) -> None:
        """username-round 首次严格轮询，后续连接复用进程内映射。"""
        second_backend = SocksEchoBackend()
        second_backend.start()
        self.addCleanup(second_backend.close)
        self._stop_lb()
        (self.runtime / "backends.txt").write_text(
            f"127.0.0.1:{self.backend.port}\n127.0.0.1:{second_backend.port}\n",
            encoding="utf-8",
        )
        self._start_lb(
            {"LB_STICKY_MODE": "username-round", "LB_STRATEGY": "rotate"}
        )

        def open_username(username: str) -> None:
            user_bytes = username.encode("utf-8")
            with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
                client.sendall(b"\x05\x01\x02")
                self.assertEqual(receive_exact(client, 2), b"\x05\x02")
                client.sendall(bytes([1, len(user_bytes)]) + user_bytes + b"\x06unused")
                self.assertEqual(receive_exact(client, 2), b"\x01\x00")
                client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
                self.assertEqual(receive_exact(client, 10)[1], 0)

        for username in ("user-1", "user-2", "user-3", "user-4"):
            open_username(username)
        self.assertEqual(self.backend.request_count, 2)
        self.assertEqual(second_backend.request_count, 2)

        # 已见 username 不再推进游标，仍命中首次分配的后端。
        open_username("user-1")
        self.assertEqual(self.backend.request_count, 3)
        self.assertEqual(second_backend.request_count, 2)

    def test_username_sticky_only_applies_when_username_is_supplied(self) -> None:
        """匿名请求按 round 分发；同一主动用户名才稳定映射到一个后端。"""
        second_backend = SocksEchoBackend()
        second_backend.start()
        self.addCleanup(second_backend.close)
        self._stop_lb()
        (self.runtime / "backends.txt").write_text(
            f"127.0.0.1:{self.backend.port}\n127.0.0.1:{second_backend.port}\n",
            encoding="utf-8",
        )
        self._start_lb({"LB_STICKY_MODE": "username-hash", "LB_STRATEGY": "round"})

        # 不提供用户名时不创建粘性：两条新连接按 round 分别进入两个后端。
        for _ in range(2):
            with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
                client.sendall(b"\x05\x01\x00")
                self.assertEqual(receive_exact(client, 2), b"\x05\x00")
                client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
                self.assertEqual(receive_exact(client, 10)[1], 0)
        self.assertEqual(self.backend.request_count, 1)
        self.assertEqual(second_backend.request_count, 1)

        # 同一用户名的两条新连接必须继续命中同一个后端。
        before = (self.backend.request_count, second_backend.request_count)
        for _ in range(2):
            with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
                client.sendall(b"\x05\x01\x02")
                self.assertEqual(receive_exact(client, 2), b"\x05\x02")
                client.sendall(b"\x01\x04test\x06unused")
                self.assertEqual(receive_exact(client, 2), b"\x01\x00")
                client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
                self.assertEqual(receive_exact(client, 10)[1], 0)
        delta = (
            self.backend.request_count - before[0],
            second_backend.request_count - before[1],
        )
        self.assertIn(delta, {(2, 0), (0, 2)})

    def test_username_sticky_overrides_rotate_but_anonymous_uses_rotate(self) -> None:
        """rotate 仅分发匿名请求；携带用户名时必须优先按用户名粘性。"""
        second_backend = SocksEchoBackend()
        second_backend.start()
        self.addCleanup(second_backend.close)
        self._stop_lb()
        backends = [
            ("127.0.0.1", self.backend.port),
            ("127.0.0.1", second_backend.port),
        ]
        (self.runtime / "backends.txt").write_text(
            f"127.0.0.1:{self.backend.port}\n127.0.0.1:{second_backend.port}\n",
            encoding="utf-8",
        )
        self._start_lb(
            {
                "LB_STICKY_MODE": "username-hash",
                "LB_STRATEGY": "rotate",
                "LB_ROTATE_INTERVAL": "1h",
            }
        )

        # rotate 的第一个窗口固定选择后端列表第一项；匿名请求应全部命中它。
        for _ in range(2):
            with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
                client.sendall(b"\x05\x01\x00")
                self.assertEqual(receive_exact(client, 2), b"\x05\x00")
                client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
                self.assertEqual(receive_exact(client, 10)[1], 0)
        self.assertEqual(self.backend.request_count, 2)
        self.assertEqual(second_backend.request_count, 0)

        # 选取一个确定由 Rendezvous Hash 映射到第二个后端的用户名，以证明它没有
        # 被 rotate 的统一出口规则覆盖。
        username = ""
        for index in range(1000):
            candidate = f"rotate-user-{index}"
            if LB_MODULE.rendezvous_pick(f"user:{candidate}", backends) == backends[1]:
                username = candidate
                break
        self.assertTrue(username, "测试用户名未映射到第二个后端")
        username_bytes = username.encode("utf-8")
        password = b"unused"
        for _ in range(2):
            with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
                client.sendall(b"\x05\x01\x02")
                self.assertEqual(receive_exact(client, 2), b"\x05\x02")
                client.sendall(
                    bytes([1, len(username_bytes)])
                    + username_bytes
                    + bytes([len(password)])
                    + password
                )
                self.assertEqual(receive_exact(client, 2), b"\x01\x00")
                client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
                self.assertEqual(receive_exact(client, 10)[1], 0)

        self.assertEqual(self.backend.request_count, 2)
        self.assertEqual(second_backend.request_count, 2)

    def test_username_sticky_recovers_when_health_pool_changes(self) -> None:
        """摘流/恢复后，新连接应故障转移且既有连接不受影响。"""
        second_backend = SocksEchoBackend()
        second_backend.start()
        self.addCleanup(second_backend.close)
        self._stop_lb()
        backends = [
            ("127.0.0.1", self.backend.port),
            ("127.0.0.1", second_backend.port),
        ]

        def replace_healthy_pool(healthy_backends: list[tuple[str, int]]) -> None:
            """模拟健康守护/滚动重启对后端池文件的原子替换。"""
            temporary = self.runtime / "backends.next.txt"
            temporary.write_text(
                "".join(f"{host}:{port}\n" for host, port in healthy_backends),
                encoding="utf-8",
            )
            os.replace(temporary, self.runtime / "backends.txt")
            # lb-proxy.py 依靠 mtime 热加载；让低精度文件系统也能观测到替换。
            time.sleep(0.02)

        def open_sticky_connection(username: str) -> socket.socket:
            client = socket.create_connection(("127.0.0.1", self.port), timeout=2)
            self.addCleanup(client.close)
            username_bytes = username.encode("utf-8")
            password = b"unused"
            client.sendall(b"\x05\x01\x02")
            self.assertEqual(receive_exact(client, 2), b"\x05\x02")
            client.sendall(
                bytes([1, len(username_bytes)])
                + username_bytes
                + bytes([len(password)])
                + password
            )
            self.assertEqual(receive_exact(client, 2), b"\x01\x00")
            client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
            self.assertEqual(receive_exact(client, 10)[1], 0)
            return client

        replace_healthy_pool(backends)
        self._start_lb(
            {
                "LB_STICKY_MODE": "username-hash",
                "LB_STRATEGY": "rotate",
                "LB_ROTATE_INTERVAL": "1h",
            }
        )

        username = ""
        for index in range(1000):
            candidate = f"health-user-{index}"
            if LB_MODULE.rendezvous_pick(f"user:{candidate}", backends) == backends[1]:
                username = candidate
                break
        self.assertTrue(username, "测试用户名未映射到将要摘流的后端")

        # 已建立的会话继续由原后端转发；摘流只阻止新的后端选择。
        established = open_sticky_connection(username)
        self.assertEqual(second_backend.request_count, 1)
        replace_healthy_pool([backends[0]])
        established.sendall(b"existing-session-stays-alive")
        self.assertEqual(
            receive_exact(established, len(b"existing-session-stays-alive")),
            b"existing-session-stays-alive",
        )

        # 健康检查摘流后，同一用户名的新连接会在剩余健康后端中重新映射。
        with open_sticky_connection(username):
            pass
        self.assertEqual(self.backend.request_count, 1)
        self.assertEqual(second_backend.request_count, 1)

        # 实例通过探测重新入池后，Rendezvous Hash 恢复原来的确定性映射。
        replace_healthy_pool(backends)
        with open_sticky_connection(username):
            pass
        self.assertEqual(self.backend.request_count, 1)
        self.assertEqual(second_backend.request_count, 2)

    def test_socks_user_pass_protects_public_frontend(self) -> None:
        """Mixed/LB 仅接受 SOCKS_USER/SOCKS_PASS，内部后端仍走无认证。"""
        self._stop_lb()
        self._start_lb(
            {
                "SOCKS_USER": "public-user",
                "SOCKS_PASS": "public-pass",
                # 旧变量不能覆盖已明确设置的新变量。
                "PROXY_USER": "legacy-user",
                "PROXY_PASS": "legacy-pass",
            }
        )

        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(b"\x05\x01\x00")
            self.assertEqual(receive_exact(client, 2), b"\x05\xff")

        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(b"\x05\x01\x02")
            self.assertEqual(receive_exact(client, 2), b"\x05\x02")
            client.sendall(b"\x01\x0blegacy-user\x0blegacy-pass")
            self.assertEqual(receive_exact(client, 2), b"\x01\x01")

        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(b"\x05\x01\x02")
            self.assertEqual(receive_exact(client, 2), b"\x05\x02")
            client.sendall(b"\x01\x0bpublic-user\x0bpublic-pass")
            self.assertEqual(receive_exact(client, 2), b"\x01\x00")
            client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
            self.assertEqual(receive_exact(client, 10)[1], 0)

    def test_socks5_http_connect_and_plain_http(self) -> None:
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(b"\x05\x01\x00")
            self.assertEqual(receive_exact(client, 2), b"\x05\x00")
            client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
            self.assertEqual(receive_exact(client, 10)[1], 0)
            client.sendall(b"socks-data")
            self.assertEqual(receive_exact(client, 10), b"socks-data")

        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(
                b"CONNECT example.com:443 HTTP/1.1\r\n"
                b"Host: example.com:443\r\n\r\n"
            )
            self.assertIn(b"200 Connection Established", client.recv(1024))
            client.sendall(b"connect-data")
            self.assertEqual(receive_exact(client, 12), b"connect-data")

        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(
                b"GET http://example.com/path?q=1 HTTP/1.1\r\n"
                b"Host: example.com\r\n"
                b"Proxy-Connection: keep-alive\r\n\r\n"
            )
            forwarded = client.recv(4096)
            self.assertTrue(forwarded.startswith(b"GET /path?q=1 HTTP/1.1\r\n"))
            self.assertNotIn(b"Proxy-Connection", forwarded)

    def test_management_ui_reuses_listener_and_bypasses_proxy_auth(self) -> None:
        """管理保留路径在 SOCKS5 端口匿名可用，不放宽实际代理认证。"""
        self._stop_lb()
        (self.runtime / "backends.meta").write_text("0=up\n", encoding="utf-8")
        (self.runtime / "instances" / "0").mkdir(parents=True)
        (self.runtime / "instances" / "0" / "health.state").write_text(
            "ready ip=2001:db8::10 ip4=203.0.113.10 ip6=2001:db8::10 "
            "warp=on warp4=on warp6=on loc=US colo=SJC checked_at=1\n",
            encoding="utf-8",
        )
        fake_controller = self.runtime / "fake-management-control.sh"
        fake_controller.write_text(
            "#!/bin/sh\n"
            "runtime=\"${MICROWARP_RUNTIME_ROOT}/instances/$2\"\n"
            "mkdir -p \"$runtime\"\n"
            "printf 'action=%s\\nstatus=success\\nmessage=测试操作完成\\nupdated_at=1\\n' \"$1\" > \"$runtime/management.state\"\n",
            encoding="utf-8",
        )
        fake_controller.chmod(0o755)
        self._start_lb(
            {
                "PROXY_MODE": "socks5",
                "MANAGEMENT_UI_ENABLED": "1",
                "MANAGEMENT_CONTROL_COMMAND": str(fake_controller),
                "SOCKS_USER": "proxy-user",
                "SOCKS_PASS": "proxy-pass",
                "INSTANCE_COUNT": "2",
                "ROTATE_RESTART_ENABLED": "1",
                "ROTATE_RESTART_INTERVAL": "6h",
                "ROTATE_RESTART_CONCURRENCY": "2",
                "ROTATE_RESTART_DEFERRED_CHECK_INTERVAL": "1m",
            }
        )
        self.assertIsNotNone(self.lb)
        worker_started_at = int(time.time()) - 120
        instance_runtime = self.runtime / "instances" / "0"
        (instance_runtime / "worker.pid").write_text(str(self.lb.pid), encoding="utf-8")
        (instance_runtime / "worker.started_at").write_text(
            f"{worker_started_at}\n", encoding="utf-8"
        )
        schedule_next_run_at = int(time.time()) + 3600
        (self.runtime / "rotate-restart.schedule.state").write_text(
            "version=2\n"
            "configured_enabled=1\n"
            "config_active=yes\n"
            "paused=no\n"
            "interval=6h\n"
            "interval_seconds=21600\n"
            "status=waiting\n"
            "running=no\n"
            f"next_run_at={schedule_next_run_at}\n"
            "scope_count=1\n"
            "current_total=0\n"
            "current_queued=0\n"
            "current_completed=0\n"
            "current_succeeded=0\n"
            "current_failed=0\n"
            "current_deferred=0\n"
            "last_run_at=100\n"
            "last_completed_at=160\n"
            "last_duration_seconds=60\n"
            "last_status=success\n"
            "last_total=1\n"
            "last_succeeded=1\n"
            "last_failed=0\n"
            "last_deferred=0\n",
            encoding="utf-8",
        )

        status, _, body = self._http_request(
            b"GET /__microwarp/ HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        self.assertIn("MicroWARP 管理面板".encode("utf-8"), body)
        self.assertIn("强制重连".encode("utf-8"), body)
        self.assertIn("进行中的任务".encode("utf-8"), body)
        self.assertIn("需要关注".encode("utf-8"), body)
        self.assertIn("我知道这会立即中断当前实例上的连接".encode("utf-8"), body)
        self.assertIn(b"pendingInstances=new Map()", body)
        self.assertIn(b"AbortController", body)
        self.assertIn(b'href="data:,"', body)
        self.assertIn(b'aria-current="page"', body)
        self.assertIn(b"function syncNavigationFocus()", body)
        self.assertIn(b"window.addEventListener('scroll',scheduleNavigationFocus,{passive:true})", body)
        self.assertIn(b'id="instance-connections-dialog"', body)
        self.assertIn(b"function openInstanceConnections(item,trigger)", body)
        self.assertIn(b"function renderInstanceConnectionDialog()", body)
        self.assertIn(b"connection-link", body)
        self.assertIn(b"function uptimeContent(item)", body)
        self.assertIn("定时重启计划".encode("utf-8"), body)
        self.assertIn("管理计划".encode("utf-8"), body)
        self.assertIn("队列状态".encode("utf-8"), body)
        self.assertIn("延后队列".encode("utf-8"), body)
        self.assertIn("等待自然空闲".encode("utf-8"), body)
        self.assertIn(b'id="restart-schedule-dialog"', body)
        self.assertIn(b"function renderRestartSchedule(status)", body)
        self.assertIn(b"function resetRestartScheduleDialog()", body)
        self.assertIn(b"const dialog=el(dialogId),trigger=dialogTrigger", body)
        self.assertIn(b'document.contains(trigger)', body)
        self.assertIn(b'id="restart-schedule-actions"', body)
        self.assertIn(b"restart-schedule-action failure", body)
        self.assertIn(b"restart-schedule-toggle", body)
        # 高风险操作使用内嵌确认对话框，不依赖可能在字符串转义时损坏的浏览器提示文本。
        self.assertIn(b'id="confirm-dialog"', body)
        self.assertIn(b"force=name==='force-reconnect'", body)
        # hidden 属性必须胜过确认框的 flex 样式；优雅重连和零连接的强制重连都不能显示中断确认。
        self.assertIn(b"requiresAck=force&&Number(item.active_connections||0)>0", body)
        self.assertIn(b"terminalStatuses=new Set(['success','failed','partial','cancelled','recovered'])", body)
        self.assertIn("超时后已恢复".encode("utf-8"), body)
        self.assertIn("健康守护恢复".encode("utf-8"), body)
        self.assertIn(b"impact.hidden=!requiresAck", body)
        self.assertIn(b"ack.hidden=!requiresAck", body)
        self.assertIn("当前无活跃连接，将立即摘流并重建 WARP 连接".encode("utf-8"), body)
        self.assertIn(b".acknowledgement:not([hidden]){display:flex!important", body)
        self.assertIn(b".acknowledgement[hidden]{display:none!important}", body)
        self.assertIn(b"value==='?'?'", body)
        self.assertIn("<th>出口</th><th>后端</th>".encode("utf-8"), body)
        for label in ("进程", "人工状态", "健康", "IPv4 出口", "IPv6 出口", "国家", "PoP", "活跃连接", "在线时长", "最近操作", "出口"):
            self.assertIn(label.encode("utf-8"), body)
        self.assertIn(b"table-layout:fixed", body)
        self.assertIn(b"operation-detail-row", body)
        self.assertIn(b"function operationRecovered(item)", body)
        self.assertIn(b"function operationTimingText(operation)", body)
        self.assertIn("查看失败原因与本次日志".encode("utf-8"), body)
        # 紧凑表格在常见桌面宽度下不需要横向滚动；操作列保留重连和停用两个图标。
        self.assertIn(b".canvas-app .instance-table{width:100%;min-width:1120px;table-layout:fixed}", body)
        self.assertIn(b".instance-table .actions-column{width:80px}", body)
        self.assertIn(b".canvas-app .table th{padding:9px 8px", body)
        self.assertIn(b".canvas-app .table td{padding:9px 8px", body)
        self.assertIn(b"td.instance-actions{position:sticky;right:0", body)
        self.assertIn(b".action-icon{display:inline-flex", body)
        self.assertIn(b"function restartActionButton(item)", body)
        self.assertIn("选择优雅重连或强制重连".encode("utf-8"), body)
        self.assertIn(b'id="restart-choice-dialog"', body)
        self.assertIn("优雅重连".encode("utf-8"), body)
        self.assertIn("强制重连".encode("utf-8"), body)
        self.assertIn(b"function chooseRestartMode(name)", body)
        self.assertIn("actionIconButton(item,'disable','⏻','停用','disable')".encode("utf-8"), body)
        self.assertNotIn(b"action-menu-trigger", body)
        self.assertNotIn("更多".encode("utf-8"), body)

        # 管理页嵌入 Python 三引号字符串，JavaScript 的换行字面量必须经过
        # 双重转义；否则浏览器会在单引号字符串中收到真实换行而解析失败。
        page_script = LB_MODULE.MANAGEMENT_PAGE.split("<script>", 1)[1].rsplit("</script>", 1)[0]
        self.assertNotIn("'\n'", page_script)
        self.assertIn("'\\n'", page_script)

        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(payload["instance_count"], 2)
        self.assertEqual(payload["instances"][0]["health"]["ip4"], "203.0.113.10")
        self.assertEqual(payload["instances"][0]["health"]["ip6"], "2001:db8::10")
        self.assertEqual(payload["instances"][0]["process"], "up")
        self.assertEqual(payload["instances"][0]["started_at"], worker_started_at)
        self.assertGreaterEqual(payload["instances"][0]["uptime_seconds"], 120)
        self.assertIn("resize_operation", payload)
        schedule = payload["restart_schedule"]
        self.assertTrue(schedule["config_active"])
        self.assertEqual(schedule["status"], "waiting")
        self.assertEqual(schedule["next_run_at"], schedule_next_run_at)
        self.assertTrue(schedule["scheduler_available"])
        self.assertEqual(schedule["policy"]["concurrency"], 2)
        self.assertEqual(schedule["policy"]["mode"], "idle-first-deferred")
        self.assertEqual(schedule["policy"]["busy_instance_policy"], "defer-until-idle")
        self.assertEqual(schedule["policy"]["deferred_check_interval"], "1m")
        self.assertEqual(schedule["policy"]["deferred_check_interval_seconds"], 60)
        self.assertEqual(schedule["last_result"]["status"], "success")
        self.assertEqual(schedule["last_result"]["duration_seconds"], 60)
        self.assertEqual(schedule["last_result"]["deferred"], 0)
        self.assertIn("management", payload)
        self.assertEqual(payload["management"]["deferred_check_interval"], "1m")
        self.assertEqual(payload["management"]["deferred_check_interval_seconds"], 60)
        self.assertEqual(payload["management"]["max_instance_count"], 255)

        pause_body = json.dumps({"action": "pause"}).encode("utf-8")
        status, _, body = self._http_request(
            b"POST /__microwarp/api/v1/restart-schedule HTTP/1.1\r\n"
            b"Host: localhost\r\nContent-Type: application/json\r\nContent-Length: "
            + str(len(pause_body)).encode("ascii")
            + b"\r\n\r\n"
            + pause_body
        )
        self.assertEqual(status, 200)
        paused_schedule = json.loads(body)["schedule"]
        self.assertTrue(paused_schedule["paused"])
        self.assertEqual(paused_schedule["status"], "paused")
        self.assertTrue((self.runtime / "rotate-restart.paused").exists())

        resume_body = json.dumps({"action": "resume"}).encode("utf-8")
        status, _, body = self._http_request(
            b"POST /__microwarp/api/v1/restart-schedule HTTP/1.1\r\n"
            b"Host: localhost\r\nContent-Type: application/json\r\nContent-Length: "
            + str(len(resume_body)).encode("ascii")
            + b"\r\n\r\n"
            + resume_body
        )
        self.assertEqual(status, 200)
        resumed_schedule = json.loads(body)["schedule"]
        self.assertFalse(resumed_schedule["paused"])
        self.assertEqual(resumed_schedule["status"], "waiting")
        self.assertFalse((self.runtime / "rotate-restart.paused").exists())

        # 当前队列、失败原因和历史记录由调度器的结构化状态文件提供，不能只暴露一个失败计数。
        run_id = "restart-20260822-200000-12345"
        run_dir = self.runtime / "rotate-restart.history" / "runs" / run_id
        (run_dir / "failures").mkdir(parents=True)
        (run_dir / "skipped").mkdir()
        (run_dir / "summary.state").write_text(
            f"version=1\nrun_id={run_id}\nstatus=partial\n"
            "started_at=100\ncompleted_at=160\nduration_seconds=60\n"
            "total=2\nsucceeded=1\nfailed=1\nskipped=0\ndeferred=1\n"
            "max_queued=2\nmax_deferred=1\navg_deferred_wait_seconds=30\n"
            "configured_concurrency=2\ndeferred_check_interval_seconds=60\n",
            encoding="utf-8",
        )
        (run_dir / "failures" / "0.state").write_text(
            f"run_id={run_id}\ninstance_id=0\nstatus=failed\nphase=warp-probe\n"
            "reason_code=warp-probe-timeout\nreason=在 180 秒内未确认 WARP 已就绪\n"
            "attempt=3\nmax_attempts=3\nactive_connections=0\nstarted_at=120\nfinished_at=160\n"
            "log_reference=rotate.log\n",
            encoding="utf-8",
        )
        next_check_at = int(time.time()) + 60
        (self.runtime / "rotate-restart.schedule.state").write_text(
            "version=3\nconfigured_enabled=1\nconfig_active=yes\npaused=no\n"
            "interval=6h\ninterval_seconds=21600\nstatus=running\nrunning=yes\n"
            f"current_run_id={run_id}\nnext_run_at=0\nnext_deferred_check_at={next_check_at}\n"
            "round_started_at=100\nscope_count=2\neligible_count=2\n"
            "current_total=2\ncurrent_queued=1\ncurrent_running=0\ncurrent_completed=0\n"
            "current_succeeded=0\ncurrent_failed=0\ncurrent_skipped=0\ncurrent_deferred=1\n"
            "current_deferred_connections=2\ncurrent_max_queued=1\ncurrent_max_deferred=1\n"
            f"last_run_id={run_id}\nlast_run_at=100\nlast_completed_at=160\n"
            "last_duration_seconds=60\nlast_status=partial\nlast_total=2\nlast_succeeded=1\n"
            "last_failed=1\nlast_skipped=0\nlast_deferred=1\nlast_max_queued=2\n"
            "last_max_deferred=1\nlast_avg_deferred_wait_seconds=30\nhistory_limit=20\n",
            encoding="utf-8",
        )
        (self.runtime / "rotate-restart.lock").mkdir()
        (instance_runtime / "scheduled-restart.state").write_text(
            "action=scheduled-rolling-restart\nstatus=queued\nqueue=ready\n"
            "queue_position=1\nqueue_total=1\nqueue_entered_at=110\n"
            "message=等待本轮定时滚动重启\n",
            encoding="utf-8",
        )
        second_runtime = self.runtime / "instances" / "1"
        second_runtime.mkdir(exist_ok=True)
        (second_runtime / "scheduled-restart.state").write_text(
            "action=scheduled-rolling-restart\nstatus=deferred\nqueue=deferred\n"
            "active_connections=2\ndeferred_at=111\n"
            f"next_check_at={next_check_at}\nmessage=当前有 2 条活跃连接，保留服务并等待自然空闲\n",
            encoding="utf-8",
        )
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        running_schedule = json.loads(body)["restart_schedule"]
        self.assertEqual(running_schedule["status"], "running")
        self.assertEqual(running_schedule["current"]["queued"], 1)
        self.assertEqual(running_schedule["current"]["deferred"], 1)
        self.assertEqual(running_schedule["current"]["deferred_queue"]["next_check_at"], next_check_at)
        self.assertEqual(running_schedule["last_result"]["failure_summary"][0]["reason_code"], "warp-probe-timeout")
        self.assertEqual(running_schedule["history"][0]["run_id"], run_id)
        self.assertEqual(running_schedule["policy"]["history_limit"], 20)

        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/restart-schedule/runs/current/queue/ready HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["instances"][0]["instance_id"], 0)
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/restart-schedule/runs/current/queue/deferred HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["instances"][0]["active_connections"], 2)
        status, _, body = self._http_request(
            f"GET /__microwarp/api/v1/restart-schedule/runs/{run_id}/failures HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
        )
        self.assertEqual(status, 200)
        failure_record = json.loads(body)["records"][0]
        self.assertEqual(failure_record["phase"], "warp-probe")
        self.assertEqual(failure_record["attempt"], 3)
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/restart-schedule/history HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["runs"][0]["run_id"], run_id)
        status, _, _ = self._http_request(
            b"GET /__microwarp/api/v1/restart-schedule/runs/not-a-run/failures HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 404)
        (self.runtime / "rotate-restart.lock").rmdir()
        (instance_runtime / "scheduled-restart.state").unlink()
        (second_runtime / "scheduled-restart.state").unlink()

        # 尚未轮到的实例应在表格“当前操作”中显示定时重启排队信息，但不被误判为
        # 已开始执行的滚动重启阶段。
        (instance_runtime / "scheduled-restart.state").write_text(
            "action=scheduled-rolling-restart\n"
            "status=queued\n"
            "message=等待本轮定时滚动重启\n"
            "queue_position=3\n"
            "queue_total=12\n"
            f"started_at={int(time.time())}\n",
            encoding="utf-8",
        )
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        queued_instance = json.loads(body)["instances"][0]
        self.assertFalse(queued_instance["operation_running"])
        self.assertEqual(queued_instance["operation"]["action"], "scheduled-rolling-restart")
        self.assertEqual(queued_instance["operation"]["queue_position"], "3")
        (instance_runtime / "scheduled-restart.state").unlink()

        # 延后实例仅展示等待自然空闲的状态，不应被当成正在执行的管理操作。
        (instance_runtime / "scheduled-restart.state").write_text(
            "action=scheduled-rolling-restart\n"
            "status=deferred\n"
            "message=当前有 2 条活跃连接，保留服务并等待自然空闲\n"
            "active_connections=2\n"
            f"started_at={int(time.time())}\n"
            f"next_check_at={int(time.time()) + 60}\n",
            encoding="utf-8",
        )
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        deferred_instance = json.loads(body)["instances"][0]
        self.assertFalse(deferred_instance["operation_running"])
        self.assertEqual(deferred_instance["operation"]["status"], "deferred")
        self.assertEqual(deferred_instance["operation"]["active_connections"], "2")
        self.assertIn("next_check_at", deferred_instance["operation"])
        (instance_runtime / "scheduled-restart.state").unlink()

        # 自动滚动重启不会经过 management.lock；管理状态 API 仍须将其视为进行中的
        # 节点操作，以便页面的“进行中的任务”和“操作中”筛选能实时展示阶段。
        rotation_runtime = self.runtime / "instances" / "0"
        (rotation_runtime / "rotating").write_text("123\n", encoding="utf-8")
        (rotation_runtime / "rotation.state").write_text(
            "action=rolling-restart\n"
            "status=draining\n"
            "message=已摘流，等待 2 条连接排空\n"
            f"started_at={int(time.time())}\n"
            "active_connections=2\n",
            encoding="utf-8",
        )
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        rolling_instance = json.loads(body)["instances"][0]
        self.assertTrue(rolling_instance["operation_running"])
        self.assertEqual(rolling_instance["operation"]["action"], "rolling-restart")
        self.assertEqual(rolling_instance["operation"]["status"], "draining")
        self.assertEqual(rolling_instance["operation"]["active_connections"], "2")
        self.assertFalse(rolling_instance["operation"]["terminal"])
        (rotation_runtime / "rotating").unlink()
        (rotation_runtime / "rotation.state").unlink()

        # 非管理 HTTP 请求仍不会在 socks5 模式中被当作 HTTP Proxy 转发。
        status, _, _ = self._http_request(
            b"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        self.assertEqual(status, 400)

        # SOCKS5 代理认证依旧严格执行，管理页不能意外绕开代理认证。
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as client:
            client.sendall(b"\x05\x01\x00")
            self.assertEqual(receive_exact(client, 2), b"\x05\xff")

        (self.runtime / "instances" / "0" / "management.lock").mkdir()
        status, _, body = self._http_request(
            b"POST /__microwarp/api/v1/instances/0/force-reconnect HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
        )
        self.assertEqual(status, 409)
        self.assertFalse(json.loads(body)["accepted"])
        (self.runtime / "instances" / "0" / "management.lock").rmdir()

        # 已停用实例不能被任一重连操作隐式恢复。
        (self.runtime / "instances" / "0" / "manual.disabled").touch()
        status, _, body = self._http_request(
            b"POST /__microwarp/api/v1/instances/0/force-reconnect HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
        )
        self.assertEqual(status, 409)
        self.assertFalse(json.loads(body)["accepted"])
        (self.runtime / "instances" / "0" / "manual.disabled").unlink()

        # 强制重连异步返回 202，状态 API 随后可读取控制脚本写入的结果。
        status, _, body = self._http_request(
            b"POST /__microwarp/api/v1/instances/0/force-reconnect HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
        )
        self.assertEqual(status, 202)
        action_payload = json.loads(body)
        self.assertTrue(action_payload["accepted"])
        self.assertTrue(action_payload["operation"]["operation_id"])
        self.assertEqual(action_payload["operation"]["status"], "queued")
        deadline = time.monotonic() + 2
        operation_status = ""
        operation_action = ""
        while time.monotonic() < deadline:
            _, _, body = self._http_request(
                b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
            operation = json.loads(body)["instances"][0]["operation"]
            operation_status = operation.get("status", "")
            operation_action = operation.get("action", "")
            if operation_status == "success":
                break
            time.sleep(0.05)
        self.assertEqual(operation_status, "success")
        self.assertEqual(operation_action, "force-reconnect")
        self.assertTrue(operation["terminal"])
        self.assertTrue(operation["operation_id"])

        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/instances/0/logs HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        self.assertIn("lines", json.loads(body))

        resize_body = b'{"action":"add","count":2}'
        status, _, body = self._http_request(
            b"POST /__microwarp/api/v1/instances HTTP/1.1\r\n"
            b"Host: localhost\r\nContent-Type: application/json\r\nContent-Length: "
            + str(len(resize_body)).encode("ascii")
            + b"\r\n\r\n"
            + resize_body
        )
        self.assertEqual(status, 202)
        resize_payload = json.loads(body)
        self.assertEqual(resize_payload["operation"]["action"], "add")
        self.assertEqual(resize_payload["operation"]["total"], 2)

        deadline = time.monotonic() + 2
        resize_status = ""
        while time.monotonic() < deadline:
            _, _, body = self._http_request(
                b"GET /__microwarp/api/v1/status HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
            resize_operation = json.loads(body)["resize_operation"]
            resize_status = str(resize_operation.get("status", ""))
            if resize_operation.get("terminal"):
                break
            time.sleep(0.05)
        self.assertEqual(resize_status, "success")
        self.assertEqual(resize_operation["completed"], "2")

    def test_internal_socks_success_reply_reports_ipv6_egress(self) -> None:
        """内部 SOCKS 的 BND.ADDR 地址族必须传递为真实出口地址族。"""
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        def backend_reply() -> None:
            try:
                self.assertEqual(receive_exact(right, 3), b"\x05\x01\x00")
                right.sendall(b"\x05\x00")
                header = receive_exact(right, 4)
                self.assertEqual(header[:3], b"\x05\x01\x00")
                if header[3] == 0x03:
                    receive_exact(right, receive_exact(right, 1)[0])
                elif header[3] == 0x01:
                    receive_exact(right, 4)
                else:
                    receive_exact(right, 16)
                receive_exact(right, 2)
                # IPv6 BND.ADDR；MicroSOCKS 会在真正的 IPv6 出站 socket 上返回此格式。
                right.sendall(b"\x05\x00\x00\x04" + b"\x00" * 18)
            finally:
                right.close()

        thread = threading.Thread(target=backend_reply, daemon=True)
        thread.start()
        self.assertEqual(LB_MODULE.socks_connect(left, "example.com", 443), "IPv6")
        thread.join(timeout=1)

    def test_management_connections_are_live_and_removed_on_close(self) -> None:
        """连接 API 只返回实时会话，并持续更新字节统计。"""
        self._stop_lb()
        self._start_lb({"PROXY_MODE": "socks5", "MANAGEMENT_UI_ENABLED": "1"})
        client = socket.create_connection(("127.0.0.1", self.port), timeout=2)
        self.addCleanup(client.close)
        client.sendall(b"\x05\x01\x00")
        self.assertEqual(receive_exact(client, 2), b"\x05\x00")
        client.sendall(b"\x05\x01\x00\x03\x0bexample.com\x01\xbb")
        self.assertEqual(receive_exact(client, 10)[1], 0)

        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/connections HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        connections = json.loads(body)["connections"]
        self.assertEqual(len(connections), 1)
        self.assertEqual(connections[0]["protocol"], "SOCKS")
        self.assertEqual(connections[0]["target"], "example.com:443")
        self.assertEqual(connections[0]["egress_family"], "IPv4")

        client.sendall(b"live-bytes")
        self.assertEqual(receive_exact(client, 10), b"live-bytes")
        status, _, body = self._http_request(
            b"GET /__microwarp/api/v1/connections HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        self.assertEqual(status, 200)
        connection = json.loads(body)["connections"][0]
        self.assertGreaterEqual(connection["bytes_client_to_backend"], 10)
        self.assertGreaterEqual(connection["bytes_backend_to_client"], 10)

        client.close()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            _, _, body = self._http_request(
                b"GET /__microwarp/api/v1/connections HTTP/1.1\r\nHost: localhost\r\n\r\n"
            )
            if not json.loads(body)["connections"]:
                break
            time.sleep(0.05)
        self.assertFalse(json.loads(body)["connections"])


class ManagementOperationTests(unittest.TestCase):
    def test_resize_operation_reports_queue_progress_and_terminal_result(self) -> None:
        """批量调整要提供可持续读取的任务 ID、进度和最终结果。"""
        with tempfile.TemporaryDirectory(prefix="microwarp-resize-test-") as temporary:
            runtime = Path(temporary)
            controller = runtime / "fake-resize-control.sh"
            controller.write_text(
                "#!/bin/sh\n"
                "sleep 0.05\n"
                "printf '%s\\n' \"$1\" >> \"$MICROWARP_RUNTIME_ROOT/resize-calls\"\n",
                encoding="utf-8",
            )
            controller.chmod(0o755)
            with mock.patch.object(LB_MODULE, "RUNTIME_ROOT", str(runtime)), mock.patch.object(
                LB_MODULE, "INSTANCE_COUNT", 1
            ), mock.patch.object(LB_MODULE, "MANAGEMENT_CONTROL_COMMAND", str(controller)):
                accepted, status_code, _, operation = LB_MODULE.launch_resize_action("add", count=2)
                self.assertTrue(accepted)
                self.assertEqual(status_code, 202)
                self.assertEqual(operation["status"], "queued")
                self.assertEqual(operation["total"], 2)
                self.assertTrue(operation["operation_id"])

                deadline = time.monotonic() + 2
                snapshot: dict[str, object] = {}
                while time.monotonic() < deadline:
                    snapshot = LB_MODULE.resize_operation_snapshot()
                    if snapshot.get("terminal"):
                        break
                    time.sleep(0.02)

                self.assertEqual(snapshot.get("status"), "success")
                self.assertTrue(snapshot.get("terminal"))
                self.assertEqual(snapshot.get("completed"), "2")
                self.assertEqual(snapshot.get("succeeded"), "2")
                self.assertEqual((runtime / "resize-calls").read_text(encoding="utf-8").splitlines(), ["add", "add"])

    def test_management_operation_snapshot_freezes_terminal_duration(self) -> None:
        """终态操作必须冻结真实耗时，不能把失败记录的存续时间展示为执行耗时。"""
        operation = LB_MODULE.enrich_management_operation(
            {
                "action": "reconnect",
                "status": "failed",
                "started_at": "100",
                "finished_at": "190",
                "duration_seconds": "90",
                "phase": "warp-probe",
                "reason_code": "warp-probe-timeout",
            }
        )
        self.assertTrue(operation["terminal"])
        self.assertEqual(operation["finished_at"], 190)
        self.assertEqual(operation["duration_seconds"], 90)
        self.assertEqual(operation["elapsed_seconds"], 90)
        self.assertEqual(operation["phase"], "warp-probe")
        self.assertEqual(operation["reason_code"], "warp-probe-timeout")

    def test_timed_out_management_operation_reports_late_recovery(self) -> None:
        """超时后由健康守护恢复时，状态接口必须明确给出最终恢复与首次超时诊断。"""
        timed_out = LB_MODULE.enrich_management_operation(
            {
                "action": "reconnect",
                "status": "failed",
                "message": "在 180 秒内未确认 WARP 已就绪",
                "reason_code": "warp-probe-timeout",
                "started_at": "100",
                "finished_at": "280",
                "duration_seconds": "180",
                "phase": "warp-probe",
            }
        )
        recovered = LB_MODULE.annotate_timed_out_operation_recovery(
            timed_out, {"kind": "ready", "checked_at": "310"}, "up"
        )
        self.assertEqual(recovered["status"], "recovered")
        self.assertTrue(recovered["terminal"])
        self.assertTrue(recovered["recovered_after_timeout"])
        self.assertEqual(recovered["timed_out_at"], 280)
        self.assertEqual(recovered["recovered_at"], 310)
        self.assertEqual(recovered["recovery_delay_seconds"], 30)
        self.assertEqual(recovered["timeout_reason_code"], "warp-probe-timeout")
        self.assertEqual(recovered["timeout_message"], "在 180 秒内未确认 WARP 已就绪")
        self.assertEqual(recovered["duration_seconds"], 210)
        self.assertNotIn("reason_code", recovered)

        # 旧的健康快照早于这次超时时不能错误地覆盖失败记录。
        stale = LB_MODULE.annotate_timed_out_operation_recovery(
            timed_out, {"kind": "ready", "checked_at": "279"}, "up"
        )
        self.assertEqual(stale["status"], "failed")

    def test_management_operation_snapshot_migrates_legacy_terminal_timestamp(self) -> None:
        """升级前只有 updated_at 的终态记录应按该时间补齐固定执行耗时。"""
        operation = LB_MODULE.enrich_management_operation(
            {"action": "reconnect", "status": "success", "started_at": "100", "updated_at": "160"}
        )
        self.assertTrue(operation["terminal"])
        self.assertEqual(operation["finished_at"], 160)
        self.assertEqual(operation["duration_seconds"], 60)
        self.assertEqual(operation["elapsed_seconds"], 60)


if __name__ == "__main__":
    unittest.main(verbosity=2)
