#!/usr/bin/env python3
"""将本地固定 TCP 监听经标准 SOCKS5 CONNECT 转发到一个固定远端。

此程序只供 ``UPSTREAM_SOCKS5_TRANSPORT=tcp`` 使用：usque 的 HTTP/2
CONNECT-IP 客户端必须保留 Cloudflare 指定的 endpoint_h2_v4，但标准 SOCKS5
代理会按域名重新解析目标，进而破坏 usque 的证书公钥钉扎。通过本地回环
中继固定远端 IP，可同时保留 usque 的 TLS/SNI/钉扎语义与普通 SOCKS5 CONNECT。
"""

from __future__ import annotations

import argparse
import select
import signal
import socket
import sys
import threading
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit


@dataclass(frozen=True)
class SocksProxy:
    """标准 SOCKS5 服务器连接信息。"""

    host: str
    port: int
    username: str | None
    password: str | None


STOP = threading.Event()


def parse_proxy_uri(raw: str) -> SocksProxy:
    """只接受 socks5 URI，并将百分号编码的认证信息还原。"""
    parsed = urlsplit(raw)
    if parsed.scheme.lower() != "socks5" or not parsed.hostname or not parsed.port:
        raise ValueError("代理地址必须是 socks5://[user:pass@]host:port")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("代理地址不能包含路径、查询参数或片段")
    username = unquote(parsed.username) if parsed.username is not None else None
    password = unquote(parsed.password) if parsed.password is not None else None
    if (username is None) != (password is None):
        raise ValueError("SOCKS5 用户名和密码必须同时提供")
    return SocksProxy(parsed.hostname, parsed.port, username, password)


def receive_exact(sock: socket.socket, size: int) -> bytes:
    """读取固定长度的 SOCKS5 协商帧。"""
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise OSError("SOCKS5 连接在协商时提前关闭")
        data.extend(chunk)
    return bytes(data)


def encode_address(host: str) -> tuple[int, bytes]:
    """把数值 IP 或域名编码为 SOCKS5 ATYP 与地址字段。"""
    try:
        return 0x01, socket.inet_pton(socket.AF_INET, host)
    except OSError:
        pass
    try:
        return 0x04, socket.inet_pton(socket.AF_INET6, host)
    except OSError:
        pass
    encoded = host.encode("idna")
    if not encoded or len(encoded) > 255:
        raise OSError("SOCKS5 目标域名长度非法")
    return 0x03, bytes((len(encoded),)) + encoded


def open_socks_connection(proxy: SocksProxy, target_host: str, target_port: int) -> socket.socket:
    """通过标准 SOCKS5 CONNECT 建立到固定 endpoint 的 TCP 流。"""
    remote = socket.create_connection((proxy.host, proxy.port), timeout=15)
    remote.settimeout(15)
    try:
        methods = b"\x00" if proxy.username is None else b"\x00\x02"
        remote.sendall(b"\x05" + bytes((len(methods),)) + methods)
        version, method = receive_exact(remote, 2)
        if version != 0x05 or method == 0xFF:
            raise OSError("SOCKS5 服务端未接受认证方式")
        if method == 0x02:
            if proxy.username is None or proxy.password is None:
                raise OSError("SOCKS5 服务端要求认证，但未配置认证信息")
            username = proxy.username.encode()
            password = proxy.password.encode()
            if not username or len(username) > 255 or len(password) > 255:
                raise OSError("SOCKS5 认证字段长度非法")
            remote.sendall(b"\x01" + bytes((len(username),)) + username + bytes((len(password),)) + password)
            auth_version, auth_status = receive_exact(remote, 2)
            if auth_version != 0x01 or auth_status != 0x00:
                raise OSError("SOCKS5 用户名密码认证失败")
        elif method != 0x00:
            raise OSError(f"SOCKS5 返回不支持的认证方式: {method}")

        atyp, address = encode_address(target_host)
        remote.sendall(b"\x05\x01\x00" + bytes((atyp,)) + address + target_port.to_bytes(2, "big"))
        version, reply, _, reply_atyp = receive_exact(remote, 4)
        if version != 0x05 or reply != 0x00:
            raise OSError(f"SOCKS5 CONNECT 失败，回复码={reply}")
        if reply_atyp == 0x01:
            receive_exact(remote, 4)
        elif reply_atyp == 0x04:
            receive_exact(remote, 16)
        elif reply_atyp == 0x03:
            receive_exact(remote, receive_exact(remote, 1)[0])
        else:
            raise OSError("SOCKS5 CONNECT 返回未知地址类型")
        receive_exact(remote, 2)
        remote.settimeout(None)
        return remote
    except BaseException:
        remote.close()
        raise


def relay_bidirectional(client: socket.socket, proxy: SocksProxy, target_host: str, target_port: int) -> None:
    """把 usque 的本地 TCP 流与 SOCKS5 CONNECT 后的远端流双向复制。"""
    upstream: socket.socket | None = None
    try:
        upstream = open_socks_connection(proxy, target_host, target_port)
        client.setblocking(False)
        upstream.setblocking(False)
        peers = (client, upstream)
        while not STOP.is_set():
            readable, _, _ = select.select(peers, (), (), 1)
            for source in readable:
                payload = source.recv(65536)
                if not payload:
                    return
                target = upstream if source is client else client
                target.sendall(payload)
    except OSError as exc:
        print(f"[tcp-socks5-relay] 转发失败: {exc}", file=sys.stderr, flush=True)
    finally:
        client.close()
        if upstream is not None:
            upstream.close()


def stop_handler(_signum: int, _frame: object) -> None:
    STOP.set()


def serve(arguments: argparse.Namespace) -> int:
    proxy = parse_proxy_uri(arguments.proxy_uri)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((arguments.listen_host, arguments.listen_port))
    listener.listen(32)
    listener.settimeout(1)
    print(
        "[tcp-socks5-relay] 已监听 "
        f"{arguments.listen_host}:{arguments.listen_port}，"
        f"目标={arguments.target_host}:{arguments.target_port}，"
        f"上游={proxy.host}:{proxy.port}",
        flush=True,
    )
    try:
        while not STOP.is_set():
            try:
                client, _address = listener.accept()
            except socket.timeout:
                continue
            threading.Thread(
                target=relay_bidirectional,
                args=(client, proxy, arguments.target_host, arguments.target_port),
                daemon=True,
            ).start()
    finally:
        listener.close()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="标准 SOCKS5 CONNECT 本地 TCP 中继")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=443)
    parser.add_argument("--proxy-uri", required=True)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=int, default=443)
    arguments = parser.parse_args()
    if not 1 <= arguments.listen_port <= 65535 or not 1 <= arguments.target_port <= 65535:
        parser.error("端口必须在 1 到 65535 之间")
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    try:
        return serve(arguments)
    except (OSError, ValueError) as exc:
        print(f"[tcp-socks5-relay] 启动失败: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
