#!/usr/bin/env python3
"""验证标准 SOCKS5 CONNECT 本地中继保留固定目标地址并双向转发。"""

from __future__ import annotations

import select
import socket
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELAY = ROOT / "tcp-socks5-relay.py"


def reserve_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def receive_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("连接提前关闭")
        data.extend(chunk)
    return bytes(data)


def bridge(left: socket.socket, right: socket.socket) -> None:
    try:
        while True:
            readable, _, _ = select.select((left, right), (), (), 1)
            for source in readable:
                data = source.recv(65536)
                if not data:
                    return
                (right if source is left else left).sendall(data)
    finally:
        left.close()
        right.close()


class TcpEchoServer:
    """用于确认 relay 后的字节流完整返回。"""

    def __init__(self) -> None:
        self.port = reserve_port()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", self.port))
        self.listener.listen()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.stop.set()
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                pass
        except OSError:
            pass
        self.thread.join(timeout=2)
        self.listener.close()

    def _serve(self) -> None:
        self.listener.settimeout(0.2)
        while not self.stop.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    @staticmethod
    def _handle(client: socket.socket) -> None:
        try:
            while data := client.recv(65536):
                client.sendall(data)
        finally:
            client.close()


class StandardSocks5Server:
    """最小标准 SOCKS5 CONNECT 服务，不实现 UDP ASSOCIATE。"""

    def __init__(self) -> None:
        self.port = reserve_port()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", self.port))
        self.listener.listen()
        self.stop = threading.Event()
        self.targets: list[tuple[str, int]] = []
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def close(self) -> None:
        self.stop.set()
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                pass
        except OSError:
            pass
        self.thread.join(timeout=2)
        self.listener.close()

    def _serve(self) -> None:
        self.listener.settimeout(0.2)
        while not self.stop.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _handle(self, client: socket.socket) -> None:
        upstream: socket.socket | None = None
        try:
            version, count = receive_exact(client, 2)
            if version != 5:
                return
            methods = receive_exact(client, count)
            if 0 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x00")
            version, command, reserved, atyp = receive_exact(client, 4)
            if (version, command, reserved) != (5, 1, 0):
                return
            if atyp == 1:
                target = socket.inet_ntop(socket.AF_INET, receive_exact(client, 4))
            elif atyp == 4:
                target = socket.inet_ntop(socket.AF_INET6, receive_exact(client, 16))
            elif atyp == 3:
                target = receive_exact(client, receive_exact(client, 1)[0]).decode()
            else:
                return
            port = int.from_bytes(receive_exact(client, 2), "big")
            self.targets.append((target, port))
            upstream = socket.create_connection((target, port), timeout=2)
            client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            bridge(client, upstream)
            upstream = None
        except (ConnectionError, OSError):
            return
        finally:
            client.close()
            if upstream is not None:
                upstream.close()


class TcpSocks5RelayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.echo = TcpEchoServer()
        self.socks = StandardSocks5Server()
        self.echo.start()
        self.socks.start()
        self.listen_port = reserve_port()
        self.relay = subprocess.Popen(
            [
                sys.executable,
                str(RELAY),
                "--listen-port",
                str(self.listen_port),
                "--proxy-uri",
                f"socks5://127.0.0.1:{self.socks.port}",
                "--target-host",
                "127.0.0.1",
                "--target-port",
                str(self.echo.port),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.listen_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            stderr = self.relay.stderr.read() if self.relay.stderr else ""
            self.fail(f"TCP SOCKS5 relay 未监听：{stderr}")

    def tearDown(self) -> None:
        self.relay.terminate()
        try:
            self.relay.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.relay.kill()
            self.relay.wait(timeout=2)
        if self.relay.stderr is not None:
            self.relay.stderr.close()
        self.socks.close()
        self.echo.close()

    def test_relays_to_fixed_target_through_connect_only_socks5(self) -> None:
        with socket.create_connection(("127.0.0.1", self.listen_port), timeout=2) as client:
            client.sendall(b"masque-http2-data")
            self.assertEqual(receive_exact(client, 17), b"masque-http2-data")
        self.assertIn(("127.0.0.1", self.echo.port), self.socks.targets)


if __name__ == "__main__":
    unittest.main(verbosity=2)
