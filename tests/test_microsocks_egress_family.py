#!/usr/bin/env python3
"""验证已修补 MicroSOCKS 的 SOCKS5 成功响应返回真实出站 socket 地址族。"""

from __future__ import annotations

import socket


def receive_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("SOCKS 连接提前关闭")
        data.extend(chunk)
    return bytes(data)


def create_listener(family: int, address: tuple[object, ...]) -> socket.socket:
    listener = socket.socket(family)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    listener.bind(address)
    listener.listen()
    return listener


def verify_reply_family(atyp: int, address: str, port: int, expected_atyp: int) -> None:
    with socket.create_connection(("127.0.0.1", 1080), timeout=3) as client:
        client.sendall(b"\x05\x01\x00")
        if receive_exact(client, 2) != b"\x05\x00":
            raise RuntimeError("MicroSOCKS 未接受无认证握手")
        family = socket.AF_INET if atyp == 0x01 else socket.AF_INET6
        raw_address = socket.inet_pton(family, address)
        client.sendall(
            b"\x05\x01\x00" + bytes([atyp]) + raw_address + port.to_bytes(2, "big")
        )
        header = receive_exact(client, 4)
        if header[:2] != b"\x05\x00" or header[3] != expected_atyp:
            raise RuntimeError(
                f"SOCKS 成功响应地址族错误：响应={header!r}，期望 ATYP={expected_atyp}"
            )
        receive_exact(client, 6 if expected_atyp == 0x01 else 18)


def main() -> None:
    # 只需监听即可让 connect() 成功；无需向远端服务写入业务数据。
    ipv4_listener = create_listener(socket.AF_INET, ("127.0.0.1", 18881))
    ipv6_listener = create_listener(socket.AF_INET6, ("::1", 18882))
    try:
        verify_reply_family(0x01, "127.0.0.1", 18881, 0x01)
        verify_reply_family(0x04, "::1", 18882, 0x04)
    finally:
        ipv4_listener.close()
        ipv6_listener.close()
    print("MicroSOCKS 成功响应按真实出站 socket 返回 IPv4 / IPv6 地址族：通过")


if __name__ == "__main__":
    main()
