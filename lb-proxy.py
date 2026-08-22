#!/usr/bin/env python3
"""MicroWARP 单容器 Mixed 代理负载均衡器。

监听一个 TCP 端口，按首字节识别 SOCKS5 或 HTTP 代理请求；所有目标连接都
通过选中的内部 SOCKS5 后端建立，避免在 LB 所在命名空间解析目标域名。
"""

from __future__ import annotations

import base64
import errno
import hashlib
import json
import os
import random
import re
import secrets
import select
import shutil
import socket
import struct
import subprocess
import threading
import time
from typing import Dict, List, Optional, Tuple
from urllib.parse import urlsplit

LISTEN_ADDR = os.environ.get("BIND_ADDR", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("BIND_PORT", "1080"))
PROXY_MODE = os.environ.get("PROXY_MODE", "socks5").strip().lower()
STRATEGY = os.environ.get("LB_STRATEGY", "round").strip().lower()
BACKENDS_FILE = os.environ.get("LB_BACKENDS_FILE", "/run/microwarp/backends.txt")
RUNTIME_ROOT = os.environ.get("MICROWARP_RUNTIME_ROOT", "/run/microwarp")
CONNECTION_FILE = os.environ.get(
    "LB_CONNECTION_STATE_FILE", "/run/microwarp/lb-connections.txt"
)
LOG_FILE = os.environ.get("MICROWARP_LOG_FILE", os.path.join(RUNTIME_ROOT, "console.log"))
try:
    MAX_LOG_LINES = max(50, min(int(os.environ.get("MANAGEMENT_LOG_LINES", "300")), 2000))
except ValueError:
    MAX_LOG_LINES = 300
AUTH_USER = os.environ.get("SOCKS_USER", "")
AUTH_PASS = os.environ.get("SOCKS_PASS", "")
STICKY_MODE = os.environ.get("LB_STICKY_MODE", "username-round").strip().lower()
# username 映射和轮询游标仅保存在 LB 进程内存中。容器重启后所有实例出口都会变化，
# 因此不写入磁盘；节点摘流时会删除受影响的映射，恢复节点只作为新的轮询候选。
# SOCKS_USER/SOCKS_PASS 固定认证时必须选择用户名/密码协商。未配置固定认证时，
# username 粘性仅在客户端主动提供该协商时提取用户名；缺少用户名时按 LB 策略选后端。
AUTH_REQUIRED = bool(AUTH_USER or AUTH_PASS)
ROTATE_INTERVAL = os.environ.get("LB_ROTATE_INTERVAL", "5m")
# 这是双向无字节流动超时，并非连接总时长。600 秒可覆盖常见 LLM 首 token
# 等待与流式间歇；任一方向有数据时都会重置计时。
IDLE_TIMEOUT = float(os.environ.get("LB_IDLE_TIMEOUT", "600"))
HANDSHAKE_TIMEOUT = float(os.environ.get("LB_HANDSHAKE_TIMEOUT", "30"))
MAX_CONN = max(1, int(os.environ.get("LB_MAX_CONN", "512")))
ACCESS_LOG = os.environ.get("LB_ACCESS_LOG", "0").strip().lower() in {
    "1", "true", "yes", "on",
}
# 开启访问日志后默认记录可解析的 HTTP 请求头，便于排障。认证凭据、Cookie、Token
# 等敏感字段始终仅展示字段名与脱敏标记；日志中绝不能输出代理密码或上游凭据。
ACCESS_LOG_HEADERS = os.environ.get("LB_ACCESS_LOG_HEADERS", "1").strip().lower() in {
    "1", "true", "yes", "on",
}
try:
    ACCESS_LOG_HEADER_MAX_CHARS = int(
        os.environ.get("LB_ACCESS_LOG_HEADER_MAX_CHARS", "8192")
    )
except ValueError:
    ACCESS_LOG_HEADER_MAX_CHARS = 8192
ACCESS_LOG_HEADER_MAX_CHARS = max(256, min(ACCESS_LOG_HEADER_MAX_CHARS, 65536))
MANAGEMENT_UI_ENABLED = os.environ.get("MANAGEMENT_UI_ENABLED", "0").strip().lower() in {
    "1", "true", "yes", "on",
}
MANAGEMENT_BASE_PATH = "/__microwarp"
MANAGEMENT_CONTROL_COMMAND = os.environ.get(
    "MANAGEMENT_CONTROL_COMMAND", "/app/management-control.sh"
)
INTERNAL_PROXY_PORT = int(os.environ.get("INTERNAL_PROXY_PORT", "1081"))
try:
    INSTANCE_COUNT = max(1, int(os.environ.get("INSTANCE_COUNT", "1")))
except ValueError:
    INSTANCE_COUNT = 1
BUFFER_SIZE = 64 * 1024

_backends: List[Tuple[str, int]] = []
_backends_mtime = -1.0
_backends_lock = threading.Lock()
_rr_index = 0
_sticky_state_lock = threading.Lock()
_sticky_next_index = 0
_sticky_assignments: Dict[str, Tuple[str, int]] = {}
_sticky_pool_seen: Optional[set[Tuple[str, int]]] = None
_active_connections: Dict[Tuple[str, int], int] = {}
_active_connection_details: Dict[str, Dict[str, object]] = {}
_active_lock = threading.Lock()
_connection_slots = threading.BoundedSemaphore(MAX_CONN)
_access_id = 0
_access_id_lock = threading.Lock()
_rotate_started = time.monotonic()
_rotate_slot = -1
_rotate_target: Optional[Tuple[str, int]] = None
_rotate_order: List[Tuple[str, int]] = []


def log(message: str, level: str = "INFO") -> None:
    """以与 Shell 控制面一致的组件/级别格式输出单行日志。"""
    labels = {
        "INFO": ("INFO", "ℹ"),
        "OK": ("OK", "✓"),
        "WARN": ("WARN", "⚠"),
        "ERROR": ("ERROR", "✗"),
        "ACCESS": ("ACCESS", "↗"),
    }
    label, icon = labels.get(level.upper(), labels["INFO"])
    line = f"[MicroWARP][LB][{label}] {icon} {message}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as output:
            output.write(line + "\n")
    except OSError:
        pass


def log_access(message: str) -> None:
    """默认不输出每个请求，避免泄露访问目标并淹没容器日志。"""
    if ACCESS_LOG:
        log(message, "ACCESS")


SENSITIVE_HTTP_HEADERS = {
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-api-key",
    "x-auth-token",
    "x-access-token",
    "x-csrf-token",
    "x-amz-security-token",
    "x-goog-api-key",
}


def truncate_access_value(value: str, limit: int) -> str:
    """限制单行访问日志大小，避免异常请求头无限放大容器日志。"""
    if len(value) <= limit:
        return value
    if limit <= 1:
        return "…"
    return value[: limit - 1] + "…"


def safe_access_value(value: Optional[str], limit: int = 1024) -> str:
    """将客户端可控文本安全地嵌入单行结构化日志。"""
    if value is None:
        return "-"
    safe = (
        str(value)
        .replace("\\", "\\\\")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
        .replace("|", "\\|")
        .strip()
    )
    return truncate_access_value(safe or "-", limit)


def next_access_id() -> str:
    """生成进程内递增请求 ID，便于关联同一容器生命周期中的访问日志。"""
    global _access_id
    with _access_id_lock:
        _access_id += 1
        return f"{os.getpid()}-{_access_id}"


def format_client_address(client_ip: str, client_port: int) -> str:
    """IPv6 客户端加方括号，避免地址与端口边界不清晰。"""
    if ":" in client_ip:
        return f"[{client_ip}]:{client_port}"
    return f"{client_ip}:{client_port}"


def access_prefix(
    protocol: str,
    client_ip: str,
    client_port: int,
    username: Optional[str],
    request_id: Optional[str] = None,
) -> str:
    """所有成功转发请求共享的访问日志基础字段。"""
    return (
        f"{protocol} | 请求ID={request_id or next_access_id()} | "
        f"客户端={format_client_address(client_ip, client_port)} | "
        f"用户ID={safe_access_value(username, 256)}"
    )


def is_sensitive_http_header(header_name: str) -> bool:
    """识别常见凭据字段；仍保留字段名以便排障。"""
    normalized = header_name.strip().lower()
    if normalized in SENSITIVE_HTTP_HEADERS:
        return True
    return any(
        marker in normalized
        for marker in ("token", "secret", "password", "credential", "api-key")
    )


def format_http_headers(lines: List[str]) -> str:
    """序列化已解析的 HTTP 请求头，并对凭据字段做不可逆脱敏。"""
    if not ACCESS_LOG_HEADERS:
        return "HTTP头=已关闭"

    headers: List[str] = []
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        if not separator or not name.strip():
            headers.append(f"原始={safe_access_value(line, 512)}")
            continue
        display_name = safe_access_value(name, 128)
        if is_sensitive_http_header(name):
            display_value = "<已脱敏>"
        else:
            display_value = safe_access_value(value, 2048)
        headers.append(f"{display_name}={display_value}")

    rendered = "; ".join(headers) if headers else "-"
    rendered = truncate_access_value(rendered, ACCESS_LOG_HEADER_MAX_CHARS)
    return f"HTTP头=[{rendered}]"


def http_access_fields(lines: List[str]) -> str:
    """返回 HTTP 请求行与请求头日志字段；CONNECT 仅能看到其明文握手头。"""
    request_line = safe_access_value(lines[0] if lines else None, 2048)
    return f"请求行={request_line} | {format_http_headers(lines)}"


def parse_duration(raw: str) -> int:
    value = raw.strip().lower()
    if not value:
        raise ValueError("empty duration")
    number = value[:-1] if value[-1:] in {"s", "m", "h", "d"} else value
    if not number.isdigit() or int(number) <= 0:
        raise ValueError(f"invalid duration: {raw}")
    unit = value[-1:] if value[-1:] in {"s", "m", "h", "d"} else "m"
    return int(number) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]


try:
    ROTATE_SECONDS = parse_duration(ROTATE_INTERVAL)
except ValueError:
    ROTATE_SECONDS = 300
    log(f"LB_ROTATE_INTERVAL 无效，回退为 5m | 值={ROTATE_INTERVAL!r}", "WARN")


def close_quietly(sock: Optional[socket.socket]) -> None:
    if sock is None:
        return
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def recv_exact(sock: socket.socket, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("连接提前关闭")
        data.extend(chunk)
    return bytes(data)


def load_backends(force: bool = False) -> List[Tuple[str, int]]:
    """后端文件以原子替换方式更新，按 mtime 热加载。"""
    global _backends, _backends_mtime
    try:
        mtime = os.stat(BACKENDS_FILE).st_mtime
    except OSError:
        return list(_backends)

    pool_changed = False
    with _backends_lock:
        if not force and mtime == _backends_mtime:
            return list(_backends)
        loaded: List[Tuple[str, int]] = []
        try:
            with open(BACKENDS_FILE, encoding="utf-8") as source:
                for line in source:
                    raw = line.strip()
                    if not raw or raw.startswith("#"):
                        continue
                    host, separator, port_text = raw.rpartition(":")
                    if not separator:
                        continue
                    try:
                        port = int(port_text)
                    except ValueError:
                        continue
                    if host and 0 < port < 65536:
                        loaded.append((host, port))
        except OSError as error:
            log(f"读取后端池文件失败 | 错误={error}", "WARN")
            return list(_backends)

        pool_changed = set(loaded) != set(_backends)
        _backends = loaded
        _backends_mtime = mtime
        result = list(_backends)
    if pool_changed or force:
        reconcile_sticky_pool(result)
    return result


def reconcile_sticky_pool(backends: List[Tuple[str, int]]) -> None:
    """健康池变化时删除失效 username 映射，恢复节点只参加后续轮询。"""
    global _sticky_pool_seen
    if STICKY_MODE != "username-round":
        return
    current = set(backends)
    with _sticky_state_lock:
        previous = _sticky_pool_seen
        _sticky_pool_seen = current
        removed = (set() if previous is None else previous - current) | {
            backend for backend in _sticky_assignments.values() if backend not in current
        }
        if not removed:
            return
        stale = [username for username, backend in _sticky_assignments.items() if backend in removed]
        if stale:
            for username in stale:
                _sticky_assignments.pop(username, None)


def sticky_round_pick(username: str, backends: List[Tuple[str, int]]) -> Tuple[str, int]:
    """为新 username 严格轮询健康后端，同一 username 后续连接复用映射。"""
    global _sticky_next_index
    with _sticky_state_lock:
        # 即使后端文件的 mtime 未变化，也要防御性清理手工修改后的失效映射。
        valid = set(backends)
        stale = [username_key for username_key, backend in _sticky_assignments.items() if backend not in valid]
        for username_key in stale:
            _sticky_assignments.pop(username_key, None)
        assigned = _sticky_assignments.get(username)
        if assigned in valid:
            return assigned

        # 保留绝对游标而不是按当前池长度取模；这样节点摘流后又恢复时，恢复节点
        # 会真正接到后续轮询位置，而不是因为池长度变化永远从第一项开始。
        backend = backends[_sticky_next_index % len(backends)]
        _sticky_next_index += 1
        _sticky_assignments[username] = backend
        return backend


def write_connection_state() -> None:
    directory = os.path.dirname(CONNECTION_FILE) or "."
    temporary = f"{CONNECTION_FILE}.{os.getpid()}.{threading.get_ident()}.tmp"
    try:
        os.makedirs(directory, exist_ok=True)
        with open(temporary, "w", encoding="utf-8") as target:
            for (host, port), count in sorted(_active_connections.items()):
                if count > 0:
                    target.write(f"{host}:{port}\t{count}\n")
        os.replace(temporary, CONNECTION_FILE)
    except OSError as error:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        log(f"写入连接状态失败 | 错误={error}", "WARN")


def track_backend(backend: Tuple[str, int], delta: int) -> None:
    with _active_lock:
        count = _active_connections.get(backend, 0) + delta
        if count > 0:
            _active_connections[backend] = count
        else:
            _active_connections.pop(backend, None)
        write_connection_state()


def register_connection(
    request_id: str,
    protocol: str,
    client_ip: str,
    client_port: int,
    username: Optional[str],
    target_host: str,
    target_port: int,
    backend: Tuple[str, int],
    egress_family: str,
) -> None:
    """登记已完成代理握手的实时连接，供管理面板查询。"""
    now = time.time()
    with _active_lock:
        _active_connection_details[request_id] = {
            "id": request_id,
            "protocol": protocol,
            "client": format_client_address(client_ip, client_port),
            "username": safe_access_value(username, 256),
            "target": f"{safe_access_value(target_host, 1024)}:{target_port}",
            "backend_instance": backend_instance_id(backend),
            "backend": f"{backend[0]}:{backend[1]}",
            "egress_family": egress_family,
            "started_at": int(now),
            "last_activity_at": now,
            "bytes_client_to_backend": 0,
            "bytes_backend_to_client": 0,
        }


def update_connection_activity(request_id: Optional[str], client_to_backend: bool, size: int) -> None:
    """更新实时连接的流量计数与最后活动时间。"""
    if not request_id or size <= 0:
        return
    with _active_lock:
        connection = _active_connection_details.get(request_id)
        if not connection:
            return
        key = "bytes_client_to_backend" if client_to_backend else "bytes_backend_to_client"
        connection[key] = int(connection[key]) + size
        connection["last_activity_at"] = time.time()


def unregister_connection(request_id: Optional[str]) -> None:
    """连接关闭后立即移除，不保留历史会话。"""
    if not request_id:
        return
    with _active_lock:
        _active_connection_details.pop(request_id, None)


def active_connection_snapshot() -> List[Dict[str, object]]:
    """生成管理 API 使用的活跃连接快照，锁外返回可序列化副本。"""
    now = time.time()
    with _active_lock:
        snapshot: List[Dict[str, object]] = []
        for connection in _active_connection_details.values():
            item = dict(connection)
            started = float(item["started_at"])
            last_activity = float(item["last_activity_at"])
            item["duration_seconds"] = max(0, int(now - started))
            item["idle_seconds"] = max(0, int(now - last_activity))
            snapshot.append(item)
    return sorted(snapshot, key=lambda item: str(item["id"]), reverse=True)


def rendezvous_score(key: str, backend: Tuple[str, int]) -> bytes:
    return hashlib.sha256(f"{key}\0{backend[0]}:{backend[1]}".encode()).digest()


def rendezvous_pick(key: str, backends: List[Tuple[str, int]]) -> Tuple[str, int]:
    return max(backends, key=lambda backend: rendezvous_score(key, backend))


def select_rotate(backends: List[Tuple[str, int]]) -> Tuple[str, int]:
    """固定时间窗口统一出口；后端摘流时仅故障转移，不重置窗口。"""
    global _rotate_slot, _rotate_target
    with _backends_lock:
        for backend in backends:
            if backend not in _rotate_order:
                _rotate_order.append(backend)
        if not _rotate_order:
            return backends[0]

        slot = int((time.monotonic() - _rotate_started) // ROTATE_SECONDS)
        if _rotate_target is None:
            _rotate_target = _rotate_order[0]
            _rotate_slot = 0
        while _rotate_slot < slot:
            current = _rotate_order.index(_rotate_target)
            _rotate_target = _rotate_order[(current + 1) % len(_rotate_order)]
            _rotate_slot += 1
        if _rotate_target in backends:
            return _rotate_target
        start = _rotate_order.index(_rotate_target)
        for offset in range(1, len(_rotate_order) + 1):
            candidate = _rotate_order[(start + offset) % len(_rotate_order)]
            if candidate in backends:
                return candidate
        return backends[0]


def pick_backend(client_ip: str, session_id: Optional[str]) -> Optional[Tuple[str, int]]:
    global _rr_index
    backends = load_backends()
    if not backends:
        return None

    if STICKY_MODE == "username-round" and session_id:
        # 默认状态型粘性轮询：首次见到 username 严格按健康池轮询，后续连接复用映射。
        # 该分支优先于 rotate；匿名客户端仍按 LB_STRATEGY 分发。
        return sticky_round_pick(session_id, backends)
    if STICKY_MODE == "username-hash" and session_id:
        return rendezvous_pick(f"user:{session_id}", backends)
    if STICKY_MODE == "client-ip-hash":
        return rendezvous_pick(f"ip:{client_ip}", backends)
    if STRATEGY == "rotate":
        return select_rotate(backends)
    if STRATEGY == "hash":
        return rendezvous_pick(f"ip:{client_ip}", backends)
    if STRATEGY == "random":
        return random.choice(backends)
    with _backends_lock:
        selected = backends[_rr_index % len(backends)]
        _rr_index = (_rr_index + 1) % max(len(backends), 1)
        return selected


def connect_backend(backend: Tuple[str, int]) -> socket.socket:
    upstream = socket.create_connection(backend, timeout=HANDSHAKE_TIMEOUT)
    upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    upstream.settimeout(HANDSHAKE_TIMEOUT)
    return upstream


def backend_instance_id(backend: Tuple[str, int]) -> str:
    """从受控网络命名空间地址恢复实例序号，供访问日志快速关联状态表。"""
    host, _port = backend
    parts = host.split(".")
    if len(parts) == 4 and parts[0:2] == ["10", "64"] and parts[3] == "2":
        try:
            instance_id = int(parts[2])
        except ValueError:
            return "?"
        # entrypoint 将基础实例限制在 0~254；临时实例也受同一 IPv4
        # 地址布局约束。管理面与访问日志必须完整显示高编号实例。
        if 0 <= instance_id <= 254:
            return str(instance_id)
    # 单实例 Mixed/LB 的内部后端固定为回环地址，可明确对应实例 0。
    if host in {"127.0.0.1", "::1"}:
        return "0"
    return "?"


def backend_access_fields(backend: Tuple[str, int]) -> str:
    """构造稳定的后端实例与地址字段，避免仅凭地址反查实例。"""
    return f"后端实例={backend_instance_id(backend)} | 后端={backend[0]}:{backend[1]}"


def socks_connect(
    upstream: socket.socket, host: str, port: int, atyp: Optional[int] = None, raw: bytes = b""
) -> str:
    """经内部无认证 SOCKS 后端建立目标连接，并返回实际出站 socket 的地址族。"""
    upstream.sendall(b"\x05\x01\x00")
    if recv_exact(upstream, 2) != b"\x05\x00":
        raise ConnectionError("内部 SOCKS 后端拒绝握手")

    if atyp == 0x01:
        address = raw
        request = b"\x05\x01\x00\x01" + address
    elif atyp == 0x04:
        address = raw
        request = b"\x05\x01\x00\x04" + address
    else:
        encoded = host.encode("idna")
        if not encoded or len(encoded) > 255:
            raise ValueError("目标域名长度非法")
        request = b"\x05\x01\x00\x03" + bytes([len(encoded)]) + encoded
    upstream.sendall(request + struct.pack("!H", port))

    header = recv_exact(upstream, 4)
    if header[0] != 5:
        raise ConnectionError("内部 SOCKS 响应格式错误")
    reply_atyp = header[3]
    if reply_atyp == 0x01:
        recv_exact(upstream, 6)
        egress_family = "IPv4"
    elif reply_atyp == 0x04:
        recv_exact(upstream, 18)
        egress_family = "IPv6"
    elif reply_atyp == 0x03:
        length = recv_exact(upstream, 1)
        recv_exact(upstream, length[0] + 2)
        egress_family = "未知"
    else:
        raise ConnectionError("内部 SOCKS 响应地址类型非法")
    if header[1] != 0:
        raise ConnectionError(f"内部 SOCKS 连接目标失败，响应码 {header[1]}")
    # RFC 1928 的成功 BND.ADDR 是代理已建立远端连接的本地绑定地址；其 ATYP
    # 因而与实际出站 socket 的 IPv4 / IPv6 地址族一致。MicroSOCKS 已显式返回它。
    return egress_family


def relay(left: socket.socket, right: socket.socket, request_id: Optional[str] = None) -> None:
    left.settimeout(None)
    right.settimeout(None)
    ends = [left, right]
    last_activity = time.monotonic()
    try:
        while True:
            readable, _, exceptional = select.select(ends, [], ends, 1.0)
            if exceptional:
                return
            if not readable:
                if time.monotonic() - last_activity >= IDLE_TIMEOUT:
                    return
                continue
            for source in readable:
                target = right if source is left else left
                try:
                    chunk = source.recv(BUFFER_SIZE)
                except OSError:
                    return
                if not chunk:
                    return
                target.sendall(chunk)
                update_connection_activity(request_id, source is left, len(chunk))
                last_activity = time.monotonic()
    finally:
        close_quietly(left)
        close_quietly(right)


def socks_failure(client: socket.socket, code: int = 1) -> None:
    try:
        client.sendall(bytes([5, code, 0, 1, 0, 0, 0, 0, 0, 0]))
    except OSError:
        pass


def check_credentials(username: str, password: str) -> bool:
    if not AUTH_USER and not AUTH_PASS:
        return True
    return username == AUTH_USER and password == AUTH_PASS


def handle_socks(
    client: socket.socket, initial: bytes, client_ip: str, client_port: int
) -> None:
    upstream: Optional[socket.socket] = None
    backend: Optional[Tuple[str, int]] = None
    request_id: Optional[str] = None
    tracked = False
    try:
        greeting = initial + recv_exact(client, 1)
        method_count = greeting[1]
        methods = set(recv_exact(client, method_count))
        username: Optional[str] = None

        # 固定认证必须协商用户名/密码。未固定认证时，用户名粘性优先使用客户端
        # 主动提供的 0x02；只提供无认证 0x00 的客户端可正常接入并按 LB 策略分发。
        use_userpass = AUTH_REQUIRED or (
            STICKY_MODE in {"username-round", "username-hash"}
            and 0x02 in methods
        ) or (0x00 not in methods and 0x02 in methods)
        if use_userpass:
            if 0x02 not in methods:
                client.sendall(b"\x05\xff")
                return
            client.sendall(b"\x05\x02")
            if recv_exact(client, 1) != b"\x01":
                client.sendall(b"\x01\x01")
                return
            user_length = recv_exact(client, 1)[0]
            username = recv_exact(client, user_length).decode("utf-8", errors="replace")
            password_length = recv_exact(client, 1)[0]
            password = recv_exact(client, password_length).decode("utf-8", errors="replace")
            if not check_credentials(username, password):
                client.sendall(b"\x01\x01")
                return
            client.sendall(b"\x01\x00")
        elif 0x00 in methods:
            client.sendall(b"\x05\x00")
        else:
            client.sendall(b"\x05\xff")
            return

        header = recv_exact(client, 4)
        if header[0] != 5 or header[1] != 1 or header[2] != 0:
            socks_failure(client, 7)
            return
        atyp = header[3]
        raw = b""
        if atyp == 0x01:
            raw = recv_exact(client, 4)
            host = socket.inet_ntoa(raw)
        elif atyp == 0x04:
            raw = recv_exact(client, 16)
            host = socket.inet_ntop(socket.AF_INET6, raw)
        elif atyp == 0x03:
            length = recv_exact(client, 1)[0]
            host = recv_exact(client, length).decode("utf-8", errors="replace")
        else:
            socks_failure(client, 8)
            return
        port = struct.unpack("!H", recv_exact(client, 2))[0]

        backend = pick_backend(client_ip, username)
        if not backend:
            socks_failure(client, 1)
            return
        track_backend(backend, 1)
        tracked = True
        upstream = connect_backend(backend)
        egress_family = socks_connect(upstream, host, port, atyp, raw)
        request_id = next_access_id()
        register_connection(
            request_id, "SOCKS", client_ip, client_port, username, host, port, backend, egress_family
        )
        client.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        log_access(
            f"{access_prefix('SOCKS', client_ip, client_port, username, request_id)} | "
            f"{backend_access_fields(backend)} | 出口={egress_family} | 命令=CONNECT | 目标={safe_access_value(host, 1024)}:{port}"
        )
        relay(client, upstream, request_id)
        upstream = None
    except (ConnectionError, OSError, ValueError) as error:
        log(f"SOCKS 请求失败 | 客户端={client_ip} | 错误={error}", "WARN")
        socks_failure(client, 1)
    finally:
        unregister_connection(request_id)
        if tracked and backend:
            track_backend(backend, -1)
        close_quietly(upstream)


def read_http_headers(client: socket.socket, initial: bytes) -> Tuple[List[str], bytes]:
    data = initial
    while b"\r\n\r\n" not in data:
        if len(data) >= 65536:
            raise ValueError("HTTP 头过大")
        chunk = client.recv(4096)
        if not chunk:
            raise ConnectionError("HTTP 客户端提前关闭")
        data += chunk
    header, _, body = data.partition(b"\r\n\r\n")
    lines = header.decode("iso-8859-1", errors="replace").split("\r\n")
    if not lines or len(lines[0].split()) < 2:
        raise ValueError("HTTP 请求行非法")
    content_length = 0
    for line in lines[1:]:
        if line.lower().startswith("content-length:"):
            try:
                content_length = max(0, min(int(line.partition(":")[2].strip()), 1_048_576))
            except ValueError:
                raise ValueError("Content-Length 非法")
            break
    while len(body) < content_length:
        chunk = client.recv(min(4096, content_length - len(body)))
        if not chunk:
            raise ConnectionError("HTTP 请求体提前结束")
        body += chunk
    return lines, body[:content_length] if content_length else body


def http_auth(lines: List[str]) -> Tuple[Optional[str], bool]:
    encoded = ""
    for line in lines[1:]:
        if line.lower().startswith("proxy-authorization:"):
            encoded = line.partition(":")[2].strip()
            break
    username: Optional[str] = None
    password = ""
    if encoded.lower().startswith("basic "):
        try:
            decoded = base64.b64decode(encoded.split(None, 1)[1]).decode("utf-8")
            username, _, password = decoded.partition(":")
        except Exception:
            return None, False
    if AUTH_USER or AUTH_PASS:
        return username, check_credentials(username or "", password)
    return username, True


def http_target(lines: List[str]) -> Tuple[str, str, int, str]:
    request = lines[0].split()
    method = request[0].upper()
    target = request[1]
    if method == "CONNECT":
        host, separator, port_text = target.rpartition(":")
        if not separator:
            raise ValueError("CONNECT 缺少端口")
        return method, host.strip("[]"), int(port_text), target

    parsed = urlsplit(target)
    if parsed.scheme and parsed.hostname:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        return method, parsed.hostname, port, path

    host_header = ""
    for line in lines[1:]:
        if line.lower().startswith("host:"):
            host_header = line.partition(":")[2].strip()
            break
    if not host_header:
        raise ValueError("HTTP 请求缺少 Host")
    host, separator, port_text = host_header.rpartition(":")
    if separator and port_text.isdigit():
        return method, host.strip("[]"), int(port_text), target
    return method, host_header.strip("[]"), 80, target


def send_http_response(
    client: socket.socket,
    status: str,
    body: bytes = b"",
    content_type: str = "text/plain; charset=utf-8",
    extra_headers: Optional[Dict[str, str]] = None,
) -> None:
    """写入短 HTTP 响应；管理面板不需要独立 Web 服务器。"""
    headers = {
        "Content-Type": content_type,
        "Content-Length": str(len(body)),
        "Connection": "close",
        "Cache-Control": "no-store",
    }
    if extra_headers:
        headers.update(extra_headers)
    encoded = [f"HTTP/1.1 {status}"]
    encoded.extend(f"{name}: {value}" for name, value in headers.items())
    client.sendall("\r\n".join(encoded).encode("iso-8859-1") + b"\r\n\r\n" + body)


def json_response(client: socket.socket, status: str, payload: Dict[str, object]) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    send_http_response(client, status, body, "application/json; charset=utf-8")


def management_target(lines: List[str]) -> Optional[str]:
    """仅识别浏览器直连的 origin-form 路径，绝不截获 HTTP Proxy 绝对 URL。"""
    if not lines:
        return None
    request = lines[0].split()
    if len(request) < 2:
        return None
    target = request[1]
    if not target.startswith("/"):
        return None
    path = target.split("?", 1)[0]
    if path == MANAGEMENT_BASE_PATH or path.startswith(MANAGEMENT_BASE_PATH + "/"):
        return path
    return None


def read_key_values(path: str) -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as source:
            for line in source:
                key, separator, value = line.rstrip("\n").partition("=")
                if separator and key:
                    values[key] = value
    except OSError:
        pass
    return values


def read_health_state(path: str) -> Dict[str, str]:
    """解析 health.state 的首个状态词与其后的 key=value 元数据。"""
    try:
        with open(path, encoding="utf-8") as source:
            tokens = source.read().strip().split()
    except OSError:
        return {"kind": "unknown"}
    if not tokens:
        return {"kind": "unknown"}
    result = {"kind": tokens[0]}
    for token in tokens[1:]:
        key, separator, value = token.partition("=")
        if separator and key:
            result[key] = value
    return result


def process_is_alive(pid_text: str) -> bool:
    try:
        os.kill(int(pid_text), 0)
    except (OSError, ValueError):
        return False
    return True


def read_instance_started_at(path: str, now: int) -> Optional[int]:
    """读取实例工作进程启动时间；无效或明显未来的时间戳按未知处理。"""
    try:
        with open(path, encoding="utf-8") as source:
            started_at = int(source.read().strip())
    except (OSError, ValueError):
        return None
    if started_at <= 0 or started_at > now + 60:
        return None
    return started_at


def duration_seconds(value: str, fallback: int = 0) -> int:
    """解析与滚动重启脚本一致的秒数或 s/m/h/d 时长配置。"""
    raw = str(value or "").strip().lower().replace(" ", "")
    if raw.isdigit():
        return int(raw)
    if len(raw) >= 2 and raw[:-1].isdigit():
        multiplier = {"s": 1, "m": 60, "h": 3600, "d": 86400}.get(raw[-1])
        if multiplier is not None:
            return int(raw[:-1]) * multiplier
    return fallback


def positive_int(value: object, fallback: int = 0) -> int:
    try:
        parsed = int(str(value))
    except (TypeError, ValueError):
        return fallback
    return parsed if parsed >= 0 else fallback


def restart_schedule_state_file() -> str:
    return os.path.join(RUNTIME_ROOT, "rotate-restart.schedule.state")


def restart_schedule_pause_file() -> str:
    return os.path.join(RUNTIME_ROOT, "rotate-restart.paused")


def restart_schedule_run_now_file() -> str:
    """返回一次性立即执行请求标记；由滚动重启守护进程原子消费。"""
    return os.path.join(RUNTIME_ROOT, "rotate-restart.run-now")


def restart_schedule_history_root() -> str:
    """返回滚动重启每轮诊断记录的运行时目录。"""
    return os.path.join(RUNTIME_ROOT, "rotate-restart.history", "runs")


def restart_schedule_run_directory(run_id: str) -> Optional[str]:
    """仅接受调度器生成的安全 run ID，防止管理 API 读取目录之外的文件。"""
    if not re.fullmatch(r"restart-[0-9]{8}-[0-9]{6}-[0-9]+", run_id or ""):
        return None
    return os.path.join(restart_schedule_history_root(), run_id)


def restart_schedule_record(record: Dict[str, str]) -> Dict[str, object]:
    """将 key=value 诊断文件规整为管理 API 可直接使用的结构。"""
    numeric_keys = {"instance_id", "attempt", "max_attempts", "active_connections", "started_at", "finished_at"}
    result: Dict[str, object] = {}
    for key, value in record.items():
        result[key] = positive_int(value) if key in numeric_keys else value
    return result


def restart_schedule_run_summary(run_id: str) -> Optional[Dict[str, object]]:
    directory = restart_schedule_run_directory(run_id)
    if directory is None:
        return None
    values = read_key_values(os.path.join(directory, "summary.state"))
    if not values or values.get("run_id") != run_id:
        return None
    numeric_keys = {
        "started_at", "completed_at", "duration_seconds", "total", "succeeded", "failed",
        "skipped", "deferred", "backend_retry", "max_queued", "max_deferred",
        "max_backend_retry", "avg_deferred_wait_seconds", "deferred_check_interval_seconds",
    }
    result: Dict[str, object] = {"run_id": run_id}
    for key, value in values.items():
        result[key] = positive_int(value) if key in numeric_keys else value
    return result


def restart_schedule_history(limit: int = 20) -> List[Dict[str, object]]:
    """读取最近有限轮的摘要。记录缺失或写入中的轮次会被安全忽略。"""
    try:
        names = sorted(os.listdir(restart_schedule_history_root()), reverse=True)
    except OSError:
        return []
    entries: List[Dict[str, object]] = []
    for run_id in names:
        summary = restart_schedule_run_summary(run_id)
        if summary is not None:
            entries.append(summary)
        if len(entries) >= max(1, limit):
            break
    return entries


def restart_schedule_run_records(run_id: str, category: str) -> Optional[List[Dict[str, object]]]:
    """读取某轮失败或跳过实例；返回 None 表示该轮不存在。"""
    if category not in {"failures", "skipped"}:
        return None
    directory = restart_schedule_run_directory(run_id)
    if directory is None or restart_schedule_run_summary(run_id) is None:
        return None
    folder = os.path.join(directory, category)
    try:
        names = sorted(name for name in os.listdir(folder) if name.endswith(".state"))
    except OSError:
        return []
    records: List[Dict[str, object]] = []
    for name in names:
        record = read_key_values(os.path.join(folder, name))
        if record:
            records.append(restart_schedule_record(record))
    return sorted(records, key=lambda record: positive_int(record.get("instance_id")))


def restart_schedule_failure_summary(run_id: str) -> List[Dict[str, object]]:
    records = restart_schedule_run_records(run_id, "failures")
    if records is None:
        return []
    counts: Dict[Tuple[str, str, str], int] = {}
    for record in records:
        code = str(record.get("reason_code") or "unknown")
        phase = str(record.get("phase") or "unknown")
        reason = str(record.get("reason") or "未提供失败原因")
        key = (code, phase, reason)
        counts[key] = counts.get(key, 0) + 1
    return [
        {"reason_code": code, "phase": phase, "reason": reason, "count": count}
        for (code, phase, reason), count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    ]


def restart_schedule_queue_snapshot(queue_name: str) -> Optional[Dict[str, object]]:
    """按实例状态文件构建当前队列，避免仅显示过期的汇总计数。"""
    if queue_name not in {"ready", "deferred", "backend-retry"}:
        return None
    entries: List[Dict[str, object]] = []
    for instance_id in runtime_instance_ids():
        values = read_key_values(
            os.path.join(RUNTIME_ROOT, "instances", str(instance_id), "scheduled-restart.state")
        )
        if values.get("action") != "scheduled-rolling-restart" or values.get("queue") != queue_name:
            continue
        entry: Dict[str, object] = {"instance_id": instance_id, "status": values.get("status", queue_name)}
        for key in ("queue_position", "queue_total", "active_connections", "started_at", "queue_entered_at", "deferred_at", "backend_retry_at", "backend_retry_attempt", "backend_retry_limit", "next_check_at", "updated_at"):
            if key in values:
                entry[key] = positive_int(values[key])
        if values.get("reason_code"):
            entry["reason_code"] = values["reason_code"]
        if values.get("message"):
            entry["message"] = values["message"]
        entries.append(entry)
    entries.sort(key=lambda item: (positive_int(item.get("queue_position"), 1 << 30), positive_int(item.get("instance_id"))))
    return {"queue": queue_name, "count": len(entries), "generated_at": int(time.time()), "instances": entries}


def restart_schedule_config_active() -> bool:
    configured = os.environ.get("ROTATE_RESTART_ENABLED", "auto").strip().lower()
    if configured in {"1", "true", "yes", "on"}:
        return True
    if configured in {"0", "false", "no", "off"}:
        return False
    return INSTANCE_COUNT >= 4


def restart_schedule_scheduler_available() -> bool:
    """滚动重启守护仅为多实例启动，单实例不应伪装成存在可执行计划。"""
    return INSTANCE_COUNT > 1


def restart_schedule_concurrency(scope_count: int) -> int:
    """返回与 rotate-restart.sh 相同的有效并行额度。"""
    total = max(1, scope_count)
    configured = os.environ.get("ROTATE_RESTART_CONCURRENCY", "auto").strip().lower()
    if configured.isdigit() and int(configured) >= 1:
        return min(total, int(configured))
    return min(total, max(1, total // 5))


def restart_schedule_snapshot(now: Optional[int] = None) -> Dict[str, object]:
    """合并调度器运行时状态、实时队列和已持久化诊断，供管理页展示。"""
    current_time = int(time.time()) if now is None else now
    state = read_key_values(restart_schedule_state_file())
    interval = os.environ.get("ROTATE_RESTART_INTERVAL", "6h")
    interval_seconds = max(60, duration_seconds(interval, 21600))
    deferred_check_interval = os.environ.get("ROTATE_RESTART_DEFERRED_CHECK_INTERVAL", "60")
    deferred_check_interval_seconds = max(1, duration_seconds(deferred_check_interval, 60))
    history_limit = max(1, positive_int(os.environ.get("ROTATE_RESTART_HISTORY_LIMIT", "20"), 20))
    scope_count = len(runtime_instance_ids())
    configured_enabled = os.environ.get("ROTATE_RESTART_ENABLED", "auto").strip().lower()
    config_active = restart_schedule_config_active()
    scheduler_available = restart_schedule_scheduler_available()
    paused = os.path.exists(restart_schedule_pause_file())
    run_now_requested = os.path.exists(restart_schedule_run_now_file())
    running = os.path.isdir(os.path.join(RUNTIME_ROOT, "rotate-restart.lock")) or state.get("running") == "yes"
    state_name = state.get("status", "")
    if running:
        status = "running"
    elif not config_active:
        status = "disabled"
    elif not scheduler_available:
        status = "unavailable"
    elif run_now_requested:
        # 请求文件先于守护进程取得调度锁写入，页面需要在这段短窗口明确显示已受理。
        status = "starting"
    elif paused:
        status = "paused"
    elif state_name in {"waiting", "starting"}:
        status = state_name
    else:
        status = "waiting"

    next_run_at = positive_int(state.get("next_run_at"))
    if status != "waiting" or next_run_at <= current_time:
        next_run_at = 0
    next_deferred_check_at = positive_int(state.get("next_deferred_check_at"))
    if status != "running" or next_deferred_check_at <= current_time:
        next_deferred_check_at = 0
    next_backend_retry_at = positive_int(state.get("next_backend_retry_at"))
    if status != "running" or next_backend_retry_at <= current_time:
        next_backend_retry_at = 0
    ready_queue = restart_schedule_queue_snapshot("ready") or {"queue": "ready", "count": 0, "instances": []}
    deferred_queue = restart_schedule_queue_snapshot("deferred") or {"queue": "deferred", "count": 0, "instances": []}
    backend_retry_queue = restart_schedule_queue_snapshot("backend-retry") or {"queue": "backend-retry", "count": 0, "instances": []}
    # 汇总状态在状态文件原子写入的短窗口中可能领先/滞后于实例状态文件；页面优先
    # 展示实时队列，若实例文件尚未出现则回退到调度器汇总，避免瞬间显示成 0。
    ready_count = len(ready_queue["instances"]) or positive_int(state.get("current_queued"))
    deferred_count = len(deferred_queue["instances"]) or positive_int(state.get("current_deferred"))
    backend_retry_count = len(backend_retry_queue["instances"]) or positive_int(state.get("current_backend_retry"))
    current = {
        "run_id": state.get("current_run_id") or None,
        "total": positive_int(state.get("current_total")),
        "queued": ready_count,
        "running": positive_int(state.get("current_running")),
        "completed": positive_int(state.get("current_completed")),
        "succeeded": positive_int(state.get("current_succeeded")),
        "failed": positive_int(state.get("current_failed")),
        "skipped": positive_int(state.get("current_skipped")),
        "deferred": deferred_count,
        "deferred_connections": positive_int(state.get("current_deferred_connections")),
        "backend_retry": backend_retry_count,
        "backend_retry_total": positive_int(state.get("current_backend_retry_total")),
        "max_queued": positive_int(state.get("current_max_queued")),
        "max_deferred": positive_int(state.get("current_max_deferred")),
        "max_backend_retry": positive_int(state.get("current_max_backend_retry")),
        "next_deferred_check_at": next_deferred_check_at or None,
        "next_backend_retry_at": next_backend_retry_at or None,
        "started_at": positive_int(state.get("round_started_at")),
        "ready_queue": {**ready_queue, "count": ready_count},
        "deferred_queue": {**deferred_queue, "count": deferred_count, "next_check_at": next_deferred_check_at or None},
        "backend_retry_queue": {**backend_retry_queue, "count": backend_retry_count, "next_check_at": next_backend_retry_at or None},
    }
    last_run_at = positive_int(state.get("last_run_at"))
    last_run_id = state.get("last_run_id", "")
    last_result = {
        "run_id": last_run_id or None,
        "status": state.get("last_status", ""),
        "total": positive_int(state.get("last_total")),
        "succeeded": positive_int(state.get("last_succeeded")),
        "failed": positive_int(state.get("last_failed")),
        "skipped": positive_int(state.get("last_skipped")),
        "deferred": positive_int(state.get("last_deferred")),
        "backend_retry": positive_int(state.get("last_backend_retry")),
        "max_queued": positive_int(state.get("last_max_queued")),
        "max_deferred": positive_int(state.get("last_max_deferred")),
        "max_backend_retry": positive_int(state.get("last_max_backend_retry")),
        "avg_deferred_wait_seconds": positive_int(state.get("last_avg_deferred_wait_seconds")),
        "completed_at": positive_int(state.get("last_completed_at")),
        "duration_seconds": positive_int(state.get("last_duration_seconds")),
        "failure_summary": restart_schedule_failure_summary(last_run_id) if last_run_id else [],
    }
    return {
        "configured_enabled": configured_enabled or "auto",
        "config_active": config_active,
        "scheduler_available": scheduler_available,
        "enabled": config_active and scheduler_available and not paused,
        "paused": paused,
        "pause_requested": paused and running,
        "run_now_requested": run_now_requested,
        "status": status,
        "interval": interval,
        "interval_seconds": interval_seconds,
        "next_run_at": next_run_at or None,
        "scope_count": scope_count,
        "policy": {
            "mode": "idle-first-deferred",
            "concurrency": restart_schedule_concurrency(scope_count),
            "configured_concurrency": os.environ.get("ROTATE_RESTART_CONCURRENCY", "auto"),
            "busy_instance_policy": "defer-until-idle",
            "deferred_check_interval": deferred_check_interval,
            "deferred_check_interval_seconds": deferred_check_interval_seconds,
            "probe_timeout": os.environ.get("ROTATE_RESTART_PROBE_TIMEOUT", "90"),
            "history_limit": history_limit,
        },
        "current": current,
        "last_run_at": last_run_at or None,
        "last_result": last_result if last_run_at else None,
        "history": restart_schedule_history(history_limit),
        "updated_at": positive_int(state.get("updated_at")),
    }


def update_restart_schedule(action: str) -> Tuple[bool, int, str, Dict[str, object]]:
    """更新计划运行时状态，或请求守护进程立即执行一轮滚动重启。"""
    if action not in {"pause", "resume", "run-now"}:
        return False, 404, "未知定时重启计划操作", {}
    if not restart_schedule_config_active():
        return False, 409, "当前滚动重启配置未启用，无法修改运行时计划状态", {}
    if not restart_schedule_scheduler_available():
        return False, 409, "定时滚动重启仅适用于多实例部署", {}
    try:
        os.makedirs(RUNTIME_ROOT, exist_ok=True)
        if action == "run-now":
            schedule = restart_schedule_snapshot()
            if schedule["status"] in {"running", "starting"}:
                return False, 409, "已有滚动重启任务正在执行或启动", schedule
            # O_EXCL 让并发请求天然去重；守护进程会在取得调度锁后删除此标记。
            target = restart_schedule_run_now_file()
            try:
                descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                return False, 409, "已收到立即执行请求，正在等待调度器启动", restart_schedule_snapshot()
            with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
                destination.write(f"requested_at={int(time.time())}\n")
            message = "已请求立即执行滚动重启；守护进程将立即接管本轮任务"
            return True, 202, message, restart_schedule_snapshot()

        target = restart_schedule_pause_file()
        if action == "pause":
            temporary = f"{target}.{os.getpid()}.{threading.get_ident()}.tmp"
            with open(temporary, "w", encoding="utf-8") as destination:
                destination.write(f"paused_at={int(time.time())}\n")
            os.replace(temporary, target)
            message = "已暂停后续定时滚动重启；正在执行的本轮任务不会中断"
        else:
            try:
                os.unlink(target)
            except FileNotFoundError:
                pass
            message = "已恢复定时滚动重启；下一次执行时间将从恢复时重新计算"
    except OSError as error:
        return False, 500, f"无法更新定时重启计划：{error}", {}
    return True, 200, message, restart_schedule_snapshot()


def instance_backend_address(instance_id: int) -> Tuple[str, int]:
    if INSTANCE_COUNT > 1:
        return f"10.64.{instance_id}.2", 1080
    return "127.0.0.1", INTERNAL_PROXY_PORT


def runtime_instance_ids() -> List[int]:
    """返回基础实例与当前生命周期内临时实例的并集。"""
    ids = set(range(INSTANCE_COUNT))
    path = os.environ.get(
        "MICROWARP_DYNAMIC_INSTANCES_FILE", os.path.join(RUNTIME_ROOT, "instances.dynamic")
    )
    try:
        with open(path, encoding="utf-8") as source:
            for raw in source:
                value = raw.strip()
                if value.isdigit():
                    ids.add(int(value))
    except OSError:
        pass
    return sorted(ids)


def backend_pool_snapshot() -> Dict[str, str]:
    return read_key_values(os.path.join(RUNTIME_ROOT, "backends.meta"))


TERMINAL_OPERATION_STATUSES = {"success", "failed", "partial", "cancelled", "recovered"}


def enrich_management_operation(operation: Dict[str, str]) -> Dict[str, object]:
    """补全终态时间与耗时，避免页面把历史记录的存续时间误当成执行耗时。"""
    result: Dict[str, object] = dict(operation)
    status = str(result.get("status", ""))
    terminal = status in TERMINAL_OPERATION_STATUSES
    result["terminal"] = terminal

    def timestamp(key: str) -> int:
        try:
            value = int(str(result.get(key, "0")))
        except (TypeError, ValueError):
            return 0
        return value if value > 0 else 0

    started_at = timestamp("started_at")
    finished_at = timestamp("finished_at")
    if terminal and not finished_at:
        # 兼容升级前未写 finished_at 的历史文件；其最后一次更新时间就是最接近的终态时间。
        finished_at = timestamp("updated_at")
    if terminal and finished_at:
        result["finished_at"] = finished_at
    try:
        stored_duration = int(str(result.get("duration_seconds", "")))
    except (TypeError, ValueError):
        stored_duration = -1

    if terminal and stored_duration >= 0:
        result["duration_seconds"] = stored_duration
        result["elapsed_seconds"] = stored_duration
    elif terminal and started_at and finished_at:
        duration_seconds = max(0, finished_at - started_at)
        result["duration_seconds"] = duration_seconds
        result["elapsed_seconds"] = duration_seconds
    if started_at > 0:
        if not terminal:
            result["elapsed_seconds"] = max(0, int(time.time()) - started_at)
    return result


def annotate_timed_out_operation_recovery(
    operation: Dict[str, object], health: Dict[str, str], pool: str
) -> Dict[str, object]:
    """将 WARP 探测超时后由健康守护恢复的操作标记为最终恢复，保留超时审计。"""
    result: Dict[str, object] = dict(operation)
    if result.get("status") != "failed" or result.get("reason_code") != "warp-probe-timeout":
        return result
    if result.get("action") not in {"enable", "reconnect", "force-reconnect"}:
        return result
    if health.get("kind") != "ready" or pool != "up":
        return result

    timed_out_at = positive_int(result.get("finished_at") or result.get("updated_at"))
    recovered_at = positive_int(health.get("checked_at"))
    # 只接受发生在原失败之后的健康探测结果，避免历史 ready 状态误覆盖新的失败诊断。
    if not timed_out_at or not recovered_at or recovered_at < timed_out_at:
        return result

    started_at = positive_int(result.get("started_at"))
    timeout_duration = positive_int(result.get("duration_seconds"))
    final_duration = max(0, recovered_at - started_at) if started_at else timeout_duration
    result.update(
        {
            "status": "recovered",
            "message": "WARP 已在超时后的健康探测中恢复并重新加入后端池",
            "phase": "recovered",
            "original_status": "failed",
            "timeout_reason_code": str(result.get("reason_code") or "warp-probe-timeout"),
            "timeout_message": str(result.get("message") or "WARP 健康探测超时"),
            "timed_out_at": timed_out_at,
            "timeout_duration_seconds": timeout_duration,
            "recovered_at": recovered_at,
            "recovery_delay_seconds": max(0, recovered_at - timed_out_at),
            "finished_at": recovered_at,
            "duration_seconds": final_duration,
            "elapsed_seconds": final_duration,
            "terminal": True,
            "recovered_after_timeout": True,
        }
    )
    result.pop("reason_code", None)
    return result


def rolling_restart_operation_snapshot(runtime: str) -> Tuple[bool, Dict[str, object]]:
    """读取滚动重启的瞬时阶段；标记存在期间优先于历史管理操作。"""
    rotating = os.path.exists(os.path.join(runtime, "rotating"))
    if not rotating:
        return False, {}
    operation = read_key_values(os.path.join(runtime, "rotation.state"))
    if operation.get("action") != "rolling-restart":
        # 写入标记与原子状态文件之间存在极短窗口，仍须让页面明确节点正被滚动重启。
        operation = {
            "action": "rolling-restart",
            "status": "running",
            "message": "正在初始化滚动重启状态",
        }
    return True, enrich_management_operation(operation)


def scheduled_restart_operation_snapshot(runtime: str) -> Dict[str, object]:
    """读取定时重启的等待、连接延后或后端池重试状态。"""
    operation = read_key_values(os.path.join(runtime, "scheduled-restart.state"))
    if operation.get("action") != "scheduled-rolling-restart" or operation.get("status") not in {
        "queued",
        "deferred",
        "backend-retry",
    }:
        return {}
    return enrich_management_operation(operation)


def resize_operation_file() -> str:
    return os.path.join(RUNTIME_ROOT, "management.resize.state")


def resize_operation_lock() -> str:
    return os.path.join(RUNTIME_ROOT, "management.resize.lock")


def resize_operation_snapshot() -> Dict[str, object]:
    return enrich_management_operation(read_key_values(resize_operation_file()))


def management_control_environment() -> Dict[str, str]:
    """向异步控制脚本显式传递当前 LB 使用的运行时路径。"""
    environment = os.environ.copy()
    environment["MICROWARP_RUNTIME_ROOT"] = RUNTIME_ROOT
    environment.setdefault(
        "MICROWARP_DYNAMIC_INSTANCES_FILE", os.path.join(RUNTIME_ROOT, "instances.dynamic")
    )
    environment["LB_CONNECTION_STATE_FILE"] = CONNECTION_FILE
    environment["LB_BACKENDS_FILE"] = BACKENDS_FILE
    return environment


def management_status_snapshot() -> Dict[str, object]:
    """收集控制面运行时文件与 LB 内存连接状态，供页面一次读取。"""
    now = int(time.time())
    pool = backend_pool_snapshot()
    connections = active_connection_snapshot()
    active_by_instance: Dict[str, int] = {}
    for connection in connections:
        instance_id = str(connection["backend_instance"])
        active_by_instance[instance_id] = active_by_instance.get(instance_id, 0) + 1

    instances: List[Dict[str, object]] = []
    for instance_id in runtime_instance_ids():
        runtime = os.path.join(RUNTIME_ROOT, "instances", str(instance_id))
        health = read_health_state(os.path.join(runtime, "health.state"))
        rotation_running, rotation_operation = rolling_restart_operation_snapshot(runtime)
        operation = (
            rotation_operation
            or scheduled_restart_operation_snapshot(runtime)
            or enrich_management_operation(read_key_values(os.path.join(runtime, "management.state")))
        )
        operation = annotate_timed_out_operation_recovery(
            operation, health, pool.get(str(instance_id), "down")
        )
        pid_text = ""
        try:
            with open(os.path.join(runtime, "worker.pid"), encoding="utf-8") as source:
                pid_text = source.read().strip()
        except OSError:
            pass
        process_up = process_is_alive(pid_text)
        started_at = (
            read_instance_started_at(os.path.join(runtime, "worker.started_at"), now)
            if process_up
            else None
        )
        backend = instance_backend_address(instance_id)
        instances.append(
            {
                "id": instance_id,
                "process": "up" if process_up else "down",
                "pid": pid_text or None,
                "started_at": started_at,
                "uptime_seconds": max(0, now - started_at) if started_at is not None else None,
                "manual_disabled": os.path.exists(os.path.join(runtime, "manual.disabled")),
                "operation_running": rotation_running
                or os.path.isdir(os.path.join(runtime, "management.lock")),
                "operation": operation,
                "health": health,
                "pool": pool.get(str(instance_id), "down"),
                "backend": f"{backend[0]}:{backend[1]}",
                "active_connections": active_by_instance.get(str(instance_id), 0),
            }
        )

    return {
        "generated_at": int(time.time()),
        "management_enabled": MANAGEMENT_UI_ENABLED,
        "bind": f"{LISTEN_ADDR}:{LISTEN_PORT}",
        "proxy_mode": PROXY_MODE,
        "instance_count": len(instances),
        "configured_instance_count": INSTANCE_COUNT,
        "strategy": STRATEGY,
        "sticky_mode": STICKY_MODE,
        "instances": instances,
        "active_connection_count": len(connections),
        "resize_operation_running": os.path.isdir(resize_operation_lock()),
        "resize_operation": resize_operation_snapshot(),
        "restart_schedule": restart_schedule_snapshot(now),
        "management": {
            "max_instance_count": 255,
            "deferred_check_interval": os.environ.get(
                "ROTATE_RESTART_DEFERRED_CHECK_INTERVAL", "60"
            ),
            "deferred_check_interval_seconds": max(
                1,
                duration_seconds(os.environ.get("ROTATE_RESTART_DEFERRED_CHECK_INTERVAL", "60"), 60),
            ),
        },
    }


def write_management_operation(
    instance_id: int,
    action: str,
    status: str,
    message: str,
    operation_id: str = "",
    started_at: int = 0,
    phase: str = "",
    reason_code: str = "",
) -> None:
    runtime = os.path.join(RUNTIME_ROOT, "instances", str(instance_id))
    os.makedirs(runtime, exist_ok=True)
    target = os.path.join(runtime, "management.state")
    temporary = f"{target}.{os.getpid()}.{threading.get_ident()}.tmp"
    try:
        now = int(time.time())
        effective_started_at = started_at or now
        with open(temporary, "w", encoding="utf-8") as destination:
            values = {
                "action": action,
                "status": status,
                "message": message,
                "operation_id": operation_id,
                "started_at": str(effective_started_at),
                "updated_at": str(now),
                "phase": phase,
                "reason_code": reason_code,
            }
            if status in TERMINAL_OPERATION_STATUSES:
                values["finished_at"] = str(now)
                values["duration_seconds"] = str(max(0, now - effective_started_at))
            for key, value in values.items():
                if value:
                    destination.write(f"{key}={str(value).replace(chr(10), ' ')}\n")
        os.replace(temporary, target)
    except OSError as error:
        log(f"写入管理操作状态失败 | 实例={instance_id} | 错误={error}", "WARN")
        try:
            os.unlink(temporary)
        except OSError:
            pass


def launch_management_action(instance_id: int, action: str) -> Tuple[bool, int, str, Dict[str, object]]:
    """以运行时目录锁串行化管理操作，操作本身在后台线程中执行。"""
    if instance_id < 0 or instance_id not in runtime_instance_ids():
        return False, 404, "实例不存在", {}
    if action not in {"enable", "disable", "reconnect", "force-reconnect"}:
        return False, 404, "未知管理操作", {}

    runtime = os.path.join(RUNTIME_ROOT, "instances", str(instance_id))
    lock = os.path.join(runtime, "management.lock")
    if action in {"reconnect", "force-reconnect"} and os.path.exists(
        os.path.join(runtime, "manual.disabled")
    ):
        return False, 409, "实例已停用，请先启用", {}
    try:
        os.makedirs(runtime, exist_ok=True)
        os.mkdir(lock)
    except FileExistsError:
        return False, 409, "实例正在执行其他管理操作", {}
    except OSError as error:
        return False, 500, f"无法创建管理锁：{error}", {}

    started_at = int(time.time())
    operation_id = f"instance-{instance_id}-{started_at}-{secrets.token_hex(4)}"
    queued_message = (
        "已加入空闲优先队列，等待自然空闲后执行"
        if action in {"disable", "reconnect"}
        else "已加入管理操作队列"
    )
    write_management_operation(
        instance_id, action, "queued", queued_message, operation_id, started_at
    )

    def run_action() -> None:
        log_path = os.path.join(runtime, "management.log")
        environment = management_control_environment()
        environment["MANAGEMENT_LOCK_HELD"] = "1"
        environment["MANAGEMENT_OPERATION_ID"] = operation_id
        environment["MANAGEMENT_OPERATION_STARTED_AT"] = str(started_at)
        try:
            with open(log_path, "a", encoding="utf-8") as output:
                result = subprocess.run(
                    [MANAGEMENT_CONTROL_COMMAND, action, str(instance_id)],
                    env=environment,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
            if result.returncode != 0:
                current = read_key_values(os.path.join(runtime, "management.state"))
                if current.get("status") not in {"failed", "success"}:
                    write_management_operation(
                        instance_id,
                        action,
                        "failed",
                        "管理操作执行失败，请查看本次日志",
                        operation_id,
                        started_at,
                        "controller",
                        "controller-exit-nonzero",
                    )
            else:
                current = read_key_values(os.path.join(runtime, "management.state"))
                if not current.get("operation_id"):
                    write_management_operation(
                        instance_id,
                        action,
                        current.get("status", "success"),
                        current.get("message", "操作完成"),
                        operation_id,
                        started_at,
                    )
        except OSError as error:
            write_management_operation(
                instance_id,
                action,
                "failed",
                f"无法启动管理操作：{error}",
                operation_id,
                started_at,
                "controller",
                "controller-launch-failed",
            )
        finally:
            shutil.rmtree(lock, ignore_errors=True)

    threading.Thread(target=run_action, daemon=True).start()
    return True, 202, queued_message, {
        "operation_id": operation_id,
        "action": action,
        "status": "queued",
        "started_at": started_at,
    }


def write_resize_operation(
    operation_id: str,
    action: str,
    status: str,
    message: str,
    started_at: int,
    total: int,
    completed: int = 0,
    succeeded: int = 0,
    failed: int = 0,
) -> None:
    """原子写入批量扩缩容进度，页面可在单次状态请求中读取。"""
    os.makedirs(RUNTIME_ROOT, exist_ok=True)
    target = resize_operation_file()
    temporary = f"{target}.{os.getpid()}.{threading.get_ident()}.tmp"
    values = {
        "operation_id": operation_id,
        "action": action,
        "status": status,
        "message": message,
        "started_at": started_at,
        "updated_at": int(time.time()),
        "total": total,
        "completed": completed,
        "succeeded": succeeded,
        "failed": failed,
    }
    try:
        with open(temporary, "w", encoding="utf-8") as destination:
            for key, value in values.items():
                destination.write(f"{key}={str(value).replace(chr(10), ' ')}\n")
        os.replace(temporary, target)
    except OSError as error:
        log(f"写入实例调整状态失败 | 错误={error}", "WARN")
        try:
            os.unlink(temporary)
        except OSError:
            pass


def launch_resize_action(
    action: str, instance_ids: Optional[List[int]] = None, count: int = 1
) -> Tuple[bool, int, str, Dict[str, object]]:
    """异步执行临时实例增减；仅写运行时文件，容器重启后自动失效。"""
    if action not in {"add", "remove"}:
        return False, 404, "未知实例调整操作", {}
    if action == "remove" and not instance_ids:
        return False, 400, "请至少选择一个临时实例", {}
    try:
        count = max(1, min(int(count or 1), 8))
    except (TypeError, ValueError):
        count = 1
    if action == "remove":
        available = set(runtime_instance_ids()) - set(range(INSTANCE_COUNT))
        invalid = [item for item in instance_ids or [] if item not in available]
        if invalid:
            return False, 409, f"仅支持移除临时实例：{','.join(map(str, invalid))}", {}
    else:
        available_slots = 255 - len(runtime_instance_ids())
        if count > available_slots:
            return False, 409, f"可用实例槽位仅剩 {available_slots} 个", {}

    try:
        os.makedirs(RUNTIME_ROOT, exist_ok=True)
        os.mkdir(resize_operation_lock())
    except FileExistsError:
        return False, 409, "已有实例增减操作正在执行", {}
    except OSError as error:
        return False, 500, f"无法创建实例调整锁：{error}", {}

    commands = [[MANAGEMENT_CONTROL_COMMAND, "add"] for _ in range(count)]
    if action == "remove":
        commands = [[MANAGEMENT_CONTROL_COMMAND, "remove", str(item)] for item in instance_ids or []]
    total = len(commands)
    verb = "添加" if action == "add" else "移除"
    started_at = int(time.time())
    operation_id = f"resize-{started_at}-{secrets.token_hex(4)}"
    write_resize_operation(
        operation_id, action, "queued", "已加入实例调整队列", started_at, total
    )

    def run_resize() -> None:
        succeeded = 0
        failed = 0
        environment = management_control_environment()
        environment["MANAGEMENT_OPERATION_ID"] = operation_id
        environment["MANAGEMENT_OPERATION_STARTED_AT"] = str(started_at)
        try:
            for completed, command in enumerate(commands, start=1):
                write_resize_operation(
                    operation_id,
                    action,
                    "running",
                    f"正在{verb}第 {completed} / {total} 个临时实例",
                    started_at,
                    total,
                    completed - 1,
                    succeeded,
                    failed,
                )
                try:
                    result = subprocess.run(
                        command,
                        env=environment,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        check=False,
                    )
                    output = (result.stdout or "").strip()
                    if output:
                        log(
                            f"实例调整 | 动作={action} | 输出={safe_access_value(output, 2048)}",
                            "INFO" if result.returncode == 0 else "WARN",
                        )
                    if result.returncode == 0:
                        succeeded += 1
                    else:
                        failed += 1
                        log(f"实例调整失败 | 动作={action} | 返回码={result.returncode}", "WARN")
                except OSError as error:
                    failed += 1
                    log(f"实例调整无法启动 | 动作={action} | 错误={error}", "ERROR")
                write_resize_operation(
                    operation_id,
                    action,
                    "running",
                    f"已处理 {completed} / {total} 个临时实例",
                    started_at,
                    total,
                    completed,
                    succeeded,
                    failed,
                )
            final_status = "success" if failed == 0 else ("partial" if succeeded else "failed")
            final_message = f"实例{verb}完成：成功 {succeeded}，失败 {failed}"
            write_resize_operation(
                operation_id,
                action,
                final_status,
                final_message,
                started_at,
                total,
                total,
                succeeded,
                failed,
            )
        finally:
            shutil.rmtree(resize_operation_lock(), ignore_errors=True)

    threading.Thread(target=run_resize, daemon=True).start()
    return True, 202, "实例调整已加入队列", {
        "operation_id": operation_id,
        "action": action,
        "status": "queued",
        "started_at": started_at,
        "total": total,
    }


def management_logs(limit: int = MAX_LOG_LINES) -> List[str]:
    """读取容器生命周期内最近的控制台日志，按时间倒序接口返回。"""
    try:
        with open(LOG_FILE, encoding="utf-8", errors="replace") as source:
            lines = source.readlines()[-limit:]
    except OSError:
        lines = []
    return [line.rstrip("\n") for line in lines]


def management_instance_logs(instance_id: int, limit: int = MAX_LOG_LINES) -> List[str]:
    """读取单个实例的管理操作日志，供失败任务快速定位。"""
    if instance_id not in runtime_instance_ids():
        return []
    path = os.path.join(RUNTIME_ROOT, "instances", str(instance_id), "management.log")
    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            lines = source.readlines()[-limit:]
    except OSError:
        lines = []
    return [line.rstrip("\n") for line in lines]


MANAGEMENT_PAGE = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MicroWARP 管理面板</title><link rel="icon" href="data:,"><style>
:root{color-scheme:light;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}*{box-sizing:border-box}body{margin:0;background:#0a1020;color:#edf2ff}.app{max-width:1440px;margin:auto;padding:28px 30px 36px}.topbar{display:flex;align-items:center;justify-content:space-between;gap:18px;padding-bottom:24px}.brand{display:flex;align-items:center;gap:11px;font-size:17px;font-weight:750;letter-spacing:-.03em}.brand-mark{width:30px;height:30px;border-radius:9px;display:grid;place-items:center;background:linear-gradient(140deg,#76a8ff,#5967e8);font-size:16px;box-shadow:0 8px 20px rgba(76,111,241,.28)}.brand-subtitle{font-size:12px;color:#94a4c5;font-weight:500;letter-spacing:0}.top-meta{display:flex;align-items:center;gap:12px;color:#98a7c6;font-size:12px}.live{display:flex;align-items:center;gap:7px;color:#b7c6e5}.live:before{content:"";width:7px;height:7px;border-radius:50%;background:#5bd694;box-shadow:0 0 0 4px rgba(91,214,148,.12)}button{font:inherit}.hero{display:grid;grid-template-columns:1fr auto;align-items:end;gap:22px;padding:27px 28px;background:linear-gradient(120deg,#142342,#10182b 58%,#111a31);border:1px solid #263b63;border-radius:16px}.eyebrow{font-size:11px;font-weight:700;letter-spacing:.11em;text-transform:uppercase;color:#9eb9ee}.hero h1{margin:8px 0 7px;font-size:28px;line-height:1.12;letter-spacing:-.055em}.summary{font-size:13px;color:#aebbd7;line-height:1.5}.hero-stats{display:flex;gap:0;min-width:315px}.hero-stat{padding:4px 20px;border-left:1px solid #304664}.hero-stat:first-child{border-left:0}.hero-stat span{display:block;color:#9eb2d9;font-size:11px;margin-bottom:5px}.hero-stat strong{font-size:21px;letter-spacing:-.045em}.app{max-width:1680px;display:grid;grid-template-columns:64px minmax(0,1fr);column-gap:18px;padding:22px 24px 34px}.side-rail{grid-column:1;grid-row:1 / span 12;display:flex;flex-direction:column;align-items:center;gap:20px;padding:13px 8px;border:1px solid #223856;border-radius:16px;background:linear-gradient(180deg,#0e1b2f,#0a1526);min-height:calc(100vh - 56px);position:sticky;top:22px}.rail-mark{width:34px;height:34px;display:grid;place-items:center;border-radius:10px;background:linear-gradient(140deg,#76a8ff,#5967e8);font-size:18px;box-shadow:0 8px 20px rgba(76,111,241,.28)}.side-rail nav{display:flex;flex-direction:column;gap:9px}.rail-link{width:36px;height:36px;display:grid;place-items:center;border-radius:10px;color:#7590b7;text-decoration:none;font-size:18px}.rail-link:hover,.rail-link.active{background:#19345a;color:#eaf1ff}.rail-status{margin-top:auto;color:#69df9f;font-size:12px}.app>.topbar,.app>.hero,.app>.toolbar,.app>section{grid-column:2}.app>.topbar{grid-row:1}.app>.hero{grid-row:2}.app>.toolbar{grid-row:3}.app>section{grid-row:auto}.instance-matrix{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:10px;padding:14px;background:#0d1829;border-top:1px solid #263650}.instance-card{min-width:0;padding:13px;border:1px solid #294364;border-radius:11px;background:linear-gradient(145deg,#122640,#0d1b2e);transition:.16s}.instance-card:hover{border-color:#4d75ad;transform:translateY(-1px)}.instance-card-head{display:flex;align-items:center;justify-content:space-between;gap:8px}.instance-card-id{display:flex;align-items:center;gap:8px;font-weight:750}.instance-card-id .instance-id{width:30px;height:30px}.instance-temp{font-size:10px;color:#78b1ff;background:#17365f;padding:3px 6px;border-radius:999px}.instance-card-meta{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:12px 0;color:#8ea7c8;font-size:10px}.instance-card-meta strong{display:block;color:#e4edfc;font-size:12px;margin-top:3px}.instance-card-operation{min-height:30px;margin-bottom:10px;color:#a6b8d3;font-size:10px;line-height:1.4}.instance-card-actions{display:flex;gap:5px;flex-wrap:wrap}.instance-card-actions .action{padding:5px 7px;font-size:10px}.matrix-fallback{display:none}.panel{border-radius:13px}.log-panel{max-height:none}.log-output{max-height:260px}.connection-panel{margin-top:12px}@media(max-width:800px){.app{display:block;max-width:none;padding:18px 14px 28px}.side-rail{display:none}.app>.topbar,.app>.hero,.app>.toolbar,.app>section{display:block}.instance-matrix{grid-template-columns:repeat(auto-fill,minmax(220px,1fr));padding:10px}.instance-card{padding:11px}}.toolbar{display:flex;justify-content:space-between;align-items:center;gap:12px;margin:21px 0 14px}.toolbar-actions{display:flex;gap:8px;align-items:center}.manage-button{border:1px solid #35527a;background:#1b3358;color:#dbe8ff;border-radius:9px;padding:9px 12px;font-size:12px;font-weight:700;cursor:pointer}.manage-button.primary{background:#3476e7;border-color:#3476e7;color:#fff}.manage-button.danger{color:#ffb0bb;border-color:#6b3849;background:#271b2b}.manage-button:hover{filter:brightness(1.14)}.toolbar-note{display:flex;align-items:center;gap:8px;color:#93a2c1;font-size:12px}.toolbar-note span{color:#637397}.refresh{border:1px solid #314563;background:#15233a;color:#eaf1ff;border-radius:9px;padding:9px 12px;font-size:12px;font-weight:700;cursor:pointer;transition:.16s}.refresh:hover{background:#1c3150}.refresh:disabled{opacity:.62;cursor:not-allowed}.refresh.loading:before{content:"";display:inline-block;width:11px;height:11px;border:2px solid #b4caff;border-right-color:transparent;border-radius:50%;vertical-align:-2px;margin-right:7px;animation:spin .7s linear infinite}@keyframes spin{to{transform:rotate(1turn)}}.panel{background:#111a2c;border:1px solid #263650;border-radius:14px;margin-top:14px;overflow:hidden}.panel-head{display:flex;justify-content:space-between;align-items:center;gap:14px;padding:16px 18px}.panel-title{display:flex;align-items:baseline;gap:9px}.panel-title h2{font-size:15px;letter-spacing:-.025em;margin:0}.panel-title span{font-size:12px;color:#91a0bf}.panel-caption{font-size:12px;color:#8f9dbc}.table-wrap{overflow:auto;border-top:1px solid #263650}.table{width:100%;min-width:1480px;border-collapse:collapse;font-size:12px;white-space:nowrap}.table th{color:#8f9dbc;background:#0f1727;padding:10px 14px;text-align:left;font-size:11px;font-weight:650}.table td{padding:13px 14px;border-top:1px solid #203049;vertical-align:middle}.table tbody tr{transition:background .14s}.table tbody tr:hover{background:#15213a}.instance{display:flex;align-items:center;gap:9px;font-weight:700}.instance-id{width:27px;height:27px;border-radius:8px;display:grid;place-items:center;background:#1d2d4b;color:#aac6ff;font-size:11px}.subline{color:#8f9dbc;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:4px;max-width:190px;overflow:hidden;text-overflow:ellipsis}.badge{display:inline-flex;align-items:center;gap:5px;border-radius:999px;padding:4px 7px;font-size:11px;font-weight:700}.badge:before{content:"";width:5px;height:5px;border-radius:50%;background:currentColor}.badge.ok{background:#123728;color:#6ee4a5}.badge.wait{background:#3a2b16;color:#ffc36f}.badge.off{background:#293248;color:#a4b0c8}.badge.error{background:#452033;color:#ff9aae}.location{color:#c1cce2}.manual{font-size:11px;font-weight:700}.manual.enabled{color:#aebbd7}.manual.disabled{color:#a4b0c8}.pool{font-size:11px;font-weight:700}.pool.up{color:#6ee4a5}.pool.down{color:#a4b0c8}.connections{font-variant-numeric:tabular-nums;font-weight:700}.operation{max-width:250px;white-space:normal;line-height:1.4}.operation strong{font-size:11px}.operation span{display:block;font-size:11px;color:#91a0bf;margin-top:3px}.operation.success strong{color:#6ee4a5}.operation.failed strong{color:#ff9aae}.operation.running strong,.operation.queued strong,.operation.deferred strong,.operation.claiming strong,.operation.draining strong,.operation.restarting strong,.operation.probing strong,.operation.reconnecting strong,.operation.starting strong,.operation.stopping strong{color:#ffc36f}.action-group{display:flex;justify-content:flex-end;gap:6px}.action{border:1px solid #344865;background:transparent;color:#c5d5f5;border-radius:7px;padding:6px 8px;font-size:11px;font-weight:700;cursor:pointer;transition:.14s}.action:hover{background:#203352;color:#fff}.action.force{color:#ffb0bb;border-color:#6b3849}.action.force:hover{background:#3d2130}.action.disable{color:#ffc682;border-color:#675037}.action.disable:hover{background:#392c1e}.action.enable{background:#3476e7;border-color:#3476e7;color:#fff}.action:disabled{opacity:.48;cursor:not-allowed}.empty{padding:32px!important;text-align:center;color:#8f9dbc}.protocol,.egress{font-weight:700;color:#aec7fb}.egress{font-variant-numeric:tabular-nums}.target{max-width:245px;overflow:hidden;text-overflow:ellipsis}.details{color:#95a5c4;font-size:11px}.log-panel{max-height:360px}.log-output{margin:0;padding:15px 18px;max-height:290px;overflow:auto;background:#0c1424;color:#b9c9e8;font:11px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap}.log-line{display:block}.log-line.warn{color:#ffd18d}.log-line.error{color:#ff9eae}.resize-dialog{width:min(460px,calc(100% - 32px));border:1px solid #3c4e6e;border-radius:14px;background:#121c30;color:#edf2ff;padding:0;box-shadow:0 24px 70px rgba(0,0,0,.45)}.resize-dialog::backdrop{background:rgba(4,8,16,.68)}.resize-body{padding:22px}.resize-body h3{margin:0 0 9px;font-size:18px}.resize-body p{margin:0 0 14px;color:#aebbd7;font-size:13px;line-height:1.5}.resize-body label{display:block;color:#b9c9e8;font-size:12px;margin:11px 0 6px}.resize-body input{width:100%;border:1px solid #334b6d;border-radius:8px;background:#0e182b;color:#eef4ff;padding:9px 10px}.remove-list{display:flex;flex-wrap:wrap;gap:7px;max-height:150px;overflow:auto}.remove-list label{display:flex;align-items:center;gap:5px;margin:0;padding:7px 9px;border:1px solid #2f4566;border-radius:7px;background:#17243b}.remove-list input{width:auto}.dialog{width:min(420px,calc(100% - 32px));border:1px solid #3c4e6e;border-radius:14px;background:#121c30;color:#edf2ff;padding:0;box-shadow:0 24px 70px rgba(0,0,0,.45)}.dialog::backdrop{background:rgba(4,8,16,.68)}.dialog-body{padding:22px}.dialog h3{margin:0 0 9px;font-size:18px;letter-spacing:-.035em}.dialog p{margin:0;color:#aebbd7;font-size:13px;line-height:1.55}.dialog .impact{margin-top:12px;padding:10px 11px;border-radius:8px;background:#251c21;color:#ffc0c9;font-size:12px;line-height:1.45}.dialog-actions{display:flex;justify-content:flex-end;gap:8px;padding:14px 22px;border-top:1px solid #2b3c59}.dialog-actions button{border:1px solid #3b506f;border-radius:8px;background:transparent;color:#cbd8ef;padding:8px 11px;font-size:12px;font-weight:700;cursor:pointer}.dialog-actions .confirm{background:#3476e7;border-color:#3476e7;color:#fff}.dialog-actions .confirm.force{background:#b63a50;border-color:#b63a50}.toast{position:fixed;right:24px;bottom:24px;max-width:min(380px,calc(100% - 48px));display:flex;gap:9px;align-items:flex-start;padding:12px 14px;border:1px solid #385072;border-radius:10px;background:#16243b;color:#e9f1ff;box-shadow:0 16px 38px rgba(0,0,0,.3);font-size:12px;line-height:1.45;opacity:0;transform:translateY(10px);pointer-events:none;transition:.18s}.toast.show{opacity:1;transform:translateY(0)}.toast:before{content:"";width:7px;height:7px;margin-top:5px;flex:0 0 auto;border-radius:50%;background:#77a9ff}.toast.error:before{background:#ff91a1}@media(max-width:800px){.app{padding:18px 14px 28px}.topbar{padding-bottom:17px}.brand-subtitle,.top-meta span{display:none}.hero{grid-template-columns:1fr;padding:22px}.hero h1{font-size:25px}.hero-stats{min-width:0;width:100%}.hero-stat{flex:1;padding:4px 12px}.hero-stat:first-child{padding-left:0}.toolbar{align-items:flex-start;flex-direction:column}.panel-head{padding:14px}.panel-caption{display:none}.table{font-size:11px}.table th,.table td{padding:10px}.action-group{min-width:142px}.toast{right:14px;bottom:14px}}

/* 浅色系主题：覆盖深色默认样式，保持桌面端信息密度与状态对比度。 */
body{background:#f3f6fb;color:#17233a}
.app{background:transparent}
.side-rail{background:linear-gradient(180deg,#ffffff,#f7faff);border-color:#d9e3f0;box-shadow:0 12px 30px rgba(49,78,118,.08)}
.rail-mark{box-shadow:0 8px 18px rgba(76,111,241,.2)}
.rail-link{color:#71839d}.rail-link:hover,.rail-link.active{background:#e6efff;color:#2458b8}.rail-status{color:#1eae67}
.brand{color:#14233b}.brand-subtitle{color:#6f8099}.top-meta{color:#667892}.live{color:#415875}.live:before{background:#1fb66f;box-shadow:0 0 0 4px rgba(31,182,111,.14)}
.hero{background:linear-gradient(120deg,#ffffff,#f1f6ff 58%,#eef4ff);border-color:#d2def0;box-shadow:0 14px 36px rgba(43,77,125,.09)}.eyebrow{color:#4771b8}.hero h1{color:#14233c}.summary{color:#627594}.hero-stat{border-left-color:#d8e3f1}.hero-stat span{color:#71839c}.hero-stat strong{color:#172a49}
.toolbar-note{color:#647793}.toolbar-note span{color:#8fa0b7}.manage-button,.refresh{background:#ffffff;border-color:#cbd8e8;color:#294464;box-shadow:0 2px 5px rgba(41,68,100,.05)}.manage-button:hover,.refresh:hover{background:#eef4ff}.manage-button.primary{background:#326ed7;border-color:#326ed7;color:#fff}.manage-button.danger{background:#fff5f6;border-color:#efb8c2;color:#b43e54}
.panel{background:#ffffff;border-color:#d8e2ef;box-shadow:0 10px 28px rgba(40,73,113,.07)}.panel-head{background:#ffffff}.panel-title h2{color:#1b2c45}.panel-title span,.panel-caption{color:#71839c}.table-wrap{border-top-color:#d8e2ef}.table th{background:#f5f8fc;color:#627590}.table td{border-top-color:#e5ebf3;color:#2b3e59}.table tbody tr:hover{background:#f5f8ff}
.instance-id{background:#e7f0ff;color:#2c62bd}.subline{color:#71839c}.badge.ok{background:#e5f7ed;color:#138a52}.badge.wait{background:#fff4dc;color:#b36b00}.badge.off{background:#edf1f6;color:#687b96}.badge.error{background:#ffeaed;color:#c14358}.location{color:#304968}.manual.enabled{color:#526b8b}.manual.disabled{color:#718098}.pool.up{color:#168b55}.pool.down{color:#718098}.connections{color:#24466f}.operation span{color:#71839c}.operation.success strong{color:#138a52}.operation.failed strong{color:#c14358}.operation.running strong,.operation.queued strong,.operation.deferred strong,.operation.claiming strong,.operation.draining strong,.operation.restarting strong,.operation.probing strong,.operation.reconnecting strong,.operation.starting strong,.operation.stopping strong{color:#ad6b05}
.action{border-color:#c2d1e3;color:#315175;background:#fff}.action:hover{background:#edf4ff;color:#1c4e9f}.action.force{color:#b43e54;border-color:#e2aab5;background:#fff7f8}.action.force:hover{background:#ffecee}.action.disable{color:#a26709;border-color:#e2c18d;background:#fffaf0}.action.disable:hover{background:#fff2d6}.action.enable{background:#326ed7;border-color:#326ed7;color:#fff}.empty{color:#7b8ca3}.protocol,.egress{color:#315eaa}.target,.details{color:#5f7696}
.instance-matrix{background:#f7f9fc;border-top-color:#d8e2ef}.instance-card{background:linear-gradient(145deg,#ffffff,#f5f8fd);border-color:#d3dfed;box-shadow:0 5px 14px rgba(43,77,118,.06)}.instance-card:hover{border-color:#82a9e5;box-shadow:0 8px 18px rgba(56,102,170,.12)}.instance-card-id{color:#1d3455}.instance-temp{background:#e6f0ff;color:#2d63bd}.instance-card-meta{color:#6a7f9d}.instance-card-meta strong{color:#203856}.instance-card-operation{color:#71839c}.instance-card-actions .action{background:#fff}
.log-output{background:#f7f9fc;color:#38516f;border-top:1px solid #d8e2ef}.log-line.warn{color:#a46606}.log-line.error{color:#c14358}
.dialog,.resize-dialog{background:#ffffff;border-color:#c8d7e8;color:#172b45;box-shadow:0 24px 70px rgba(38,65,100,.2)}.dialog::backdrop,.resize-dialog::backdrop{background:rgba(32,54,84,.28)}.dialog p,.resize-body p{color:#647793}.dialog .impact{background:#fff1f3;color:#b43e54}.dialog-actions{border-top-color:#e1e8f0}.dialog-actions button{border-color:#c6d4e3;color:#365273;background:#fff}.dialog-actions .confirm{background:#326ed7;border-color:#326ed7;color:#fff}.dialog-actions .confirm.force{background:#c14358;border-color:#c14358}.resize-body label{color:#46617f}.resize-body input{background:#fff;border-color:#c7d6e6;color:#1e3553}.remove-list label{background:#f6f9fd;border-color:#d4e0ed;color:#365273}
.toast{background:#ffffff;border-color:#c8d7e8;color:#294464;box-shadow:0 16px 38px rgba(38,65,100,.18)}.toast:before{background:#4b82dc}.toast.error:before{background:#c14358}


/* 克制画布：以留白、细分隔线和安静的表格层级组织运维信息。 */
body{background:#f7f8fa;color:#1f2a3a}
.canvas-app{max-width:1320px;display:block;margin:auto;padding:0 30px 48px;background:transparent}
.canvas-app>.topbar,.canvas-app>.hero,.canvas-app>.toolbar,.canvas-app>section{display:flex;grid-column:auto;grid-row:auto}
.canvas-app .topbar{position:sticky;top:0;z-index:20;min-height:66px;padding:0;border-bottom:1px solid #e0e5eb;background:rgba(247,248,250,.94);box-shadow:0 8px 18px rgba(42,58,79,.04);backdrop-filter:blur(12px)}.canvas-app section[id]{scroll-margin-top:82px}
.canvas-app .brand{gap:9px;color:#17243a;font-size:16px;font-weight:750}.canvas-app .brand-mark{width:26px;height:26px;border-radius:8px;box-shadow:none}.canvas-app .brand-subtitle{margin-left:3px;color:#8a96a8;font-size:11px;font-weight:500}
.canvas-nav{display:flex;align-self:stretch;align-items:center;gap:21px;margin-left:54px}.canvas-nav a{display:flex;align-items:center;border-bottom:2px solid transparent;color:#758197;font-size:12px;text-decoration:none}.canvas-nav a:hover,.canvas-nav a.active{border-color:#223047;color:#223047;font-weight:700}
.canvas-app .top-meta{margin-left:auto;color:#78859a}.canvas-app .live{color:#506078}.canvas-app .live:before{width:6px;height:6px;background:#1fa66a;box-shadow:none}.canvas-app .refresh-interval-label{display:flex;align-items:center;gap:6px;color:#78859a;font-size:11px}.canvas-app .refresh-interval{height:27px;padding:0 23px 0 8px;border:1px solid #d4dce6;border-radius:6px;background:#fff;color:#344960;font:inherit;cursor:pointer}
.canvas-app .hero{align-items:flex-end;justify-content:space-between;gap:28px;padding:31px 0 23px;border:0;border-bottom:1px solid #dfe5ec;border-radius:0;background:transparent;box-shadow:none}.canvas-app .eyebrow{color:#8492a5;font-size:10px;letter-spacing:.1em}.canvas-app .hero h1{margin:7px 0 5px;color:#17243a;font-size:30px;font-weight:750;letter-spacing:-.058em}.canvas-app .summary{color:#718096;font-size:12px}.canvas-app .hero-stats{min-width:400px;display:grid;grid-template-columns:repeat(4,1fr);border:0}.canvas-app .hero-stat{padding:0 0 0 17px;border-left:1px solid #e0e6ed}.canvas-app .hero-stat:first-child{padding-left:0;border-left:0}.canvas-app .hero-stat span{color:#7e8b9f;font-size:10px}.canvas-app .hero-stat strong{color:#1c2a3e;font-size:18px;font-weight:750;letter-spacing:-.05em}
.canvas-app .toolbar{justify-content:space-between;margin:0;padding:13px 0 18px}.canvas-app .toolbar-note{color:#8090a6;font-size:11px}.canvas-app .toolbar-actions{gap:7px}.canvas-app .manage-button,.canvas-app .refresh{padding:7px 10px;border:1px solid #d2dae4;border-radius:7px;background:#fff;box-shadow:none;color:#30445e;font-size:11px}.canvas-app .manage-button.primary{border-color:#222e43;background:#222e43;color:#fff}.canvas-app .manage-button.danger{border-color:#e9c8cf;background:#fff;color:#b5465a}.canvas-app .manage-button:hover,.canvas-app .refresh:hover{background:#f0f3f7}.canvas-app .manage-button.primary:hover{background:#33435c}
.canvas-app .panel{display:block;margin-top:20px;border:0;border-top:1px solid #dfe5ec;border-radius:0;background:transparent;box-shadow:none;overflow:visible}.canvas-app .panel-head{padding:17px 0 12px;background:transparent}.canvas-app .panel-title{gap:9px}.canvas-app .panel-title h2{color:#26384f;font-size:14px;font-weight:750}.canvas-app .panel-title span,.canvas-app .panel-caption{color:#8090a5;font-size:11px}.canvas-app .panel-caption{font-size:10px}.canvas-app .instance-matrix{display:none}.canvas-app .matrix-fallback{display:block;overflow:auto;border-top:1px solid #dfe5ec}.canvas-app .table{min-width:1280px;font-size:11px;background:#fff}.canvas-app .table th{padding:9px 8px;background:#f8f9fb;color:#7b899c;font-size:10px;font-weight:750}.canvas-app .table td{padding:9px 8px;border-top:1px solid #e9edf2;color:#43566f}.canvas-app .table tbody tr:hover{background:#f7f9fc}.canvas-app .instance-id{width:25px;height:25px;border-radius:7px;background:#eef2f8;color:#3e5a80}.canvas-app .badge{padding:3px 6px}.canvas-app .action-group{gap:5px}.canvas-app .action{padding:5px 7px;border-radius:6px;background:#fff;font-size:10px}.canvas-app .connection-panel{margin-top:28px}.canvas-app .log-panel{margin-top:28px;max-height:none}.canvas-app .log-output{max-height:250px;padding:13px 0;border-top:1px solid #dfe5ec;background:transparent;color:#60738d;font-size:10px}.canvas-app .log-actions{display:flex;gap:7px}.canvas-app .log-control{padding:6px 9px;border:1px solid #d2dae4;border-radius:6px;background:#fff;color:#41556f;font-size:10px;font-weight:700;cursor:pointer}.canvas-app .log-control:hover{background:#f0f3f7;color:#223047}
@media(max-width:800px){.canvas-app{padding:0 16px 30px}.canvas-app .topbar{min-height:57px}.canvas-app .brand-subtitle,.canvas-nav{display:none}.canvas-app .hero{align-items:flex-start;flex-direction:column;padding:24px 0 18px}.canvas-app .hero h1{font-size:25px}.canvas-app .hero-stats{width:100%;min-width:0}.canvas-app .hero-stat{padding-left:10px}.canvas-app .hero-stat span{font-size:9px}.canvas-app .hero-stat strong{font-size:15px}.canvas-app .toolbar{align-items:flex-start;flex-direction:column}.canvas-app .panel-head{padding:14px 0 10px}.canvas-app .panel-caption{display:none}}


.visually-hidden{position:absolute!important;width:1px!important;height:1px!important;padding:0!important;margin:-1px!important;overflow:hidden!important;clip:rect(0,0,0,0)!important;white-space:nowrap!important;border:0!important}.live.degraded{color:#c14358}.live.degraded:before{background:#e59a30;box-shadow:0 0 0 4px rgba(229,154,48,.14)}.operation-panel{border-color:#a6c2eb}.task-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px;padding:0 18px 18px}.task-card{display:flex;flex-direction:column;gap:6px;padding:12px 13px;border:1px solid #cbd9eb;border-radius:10px;background:#f5f8fd;color:#38516f;font-size:12px;line-height:1.45}.task-card strong{color:#294a75}.task-card span{color:#647b99}.task-card small{color:#647b99;font-size:11px}.task-progress{height:6px;overflow:hidden;border-radius:999px;background:#dce6f2}.task-progress span{display:block;height:100%;border-radius:inherit;background:#3476e7;transition:width .2s ease}.instance-panel-head{align-items:flex-start}.attention-summary{max-width:470px;color:#5d7697;font-size:11px;line-height:1.5;text-align:right}.filter-bar{display:flex;flex-wrap:wrap;gap:7px;padding:0 18px 14px;border-bottom:1px solid #dfe5ec}.filter-button{border:1px solid #cfdae8;border-radius:999px;background:#fff;color:#60758f;padding:5px 9px;font-size:11px;font-weight:700;cursor:pointer}.filter-button:hover,.filter-button.active{border-color:#7aa4dc;background:#edf4ff;color:#245da8}.dialog-details{margin-top:12px;padding:9px 10px;border-left:3px solid #82a9e5;border-radius:6px;background:#f2f6fc;color:#506a8a;font-size:12px;line-height:1.5}.dialog-details:empty{display:none}.acknowledgement:not([hidden]){display:flex!important;align-items:flex-start!important;gap:7px!important;margin:14px 0 0!important;padding:10px!important;border:1px solid #e7b5bd!important;border-radius:7px!important;background:#fff5f6!important;color:#903246!important;font-size:12px!important;line-height:1.45!important}.acknowledgement[hidden]{display:none!important}.acknowledgement input{width:auto!important;margin-top:2px}.dialog-actions .confirm:disabled,.manage-button:disabled{opacity:.5;cursor:not-allowed;filter:none}.refresh-error{color:#b54759!important}.log-actions{align-items:center;flex-wrap:wrap}.log-filter-label{display:flex;align-items:center;gap:5px;color:#71839c;font-size:10px}.log-filter{border:1px solid #d2dae4;border-radius:6px;background:#fff;color:#41556f;padding:6px 7px;font:inherit}.log-new-count{color:#9a5e00;font-size:10px;font-weight:700}.canvas-app .operation-panel{display:block}.canvas-app .task-list{padding:0 0 16px}.canvas-app .task-card{background:#f7f9fc}.canvas-app .filter-bar{padding-left:0;padding-right:0}.canvas-app .attention-summary{color:#657b98}.canvas-app .dialog-details{background:#f3f7fc}.canvas-app .acknowledgement{background:#fff5f6}.canvas-app .log-filter-label{font-size:10px}.connection-link{border:0;border-bottom:1px solid currentColor;padding:0;background:transparent;color:inherit;font:inherit;font-weight:inherit;cursor:pointer}.connection-link:hover{color:#1c4e9f}.connection-link:focus-visible{outline:2px solid #6d9fe4;outline-offset:3px;border-radius:2px}.online-duration{display:inline-block;border-bottom:1px dashed #8fa4be;color:#365b87;cursor:help;font-variant-numeric:tabular-nums}.online-duration.unknown{border-bottom:0;color:#7d8da2;cursor:default}.restart-schedule-panel{border-color:#b9cee8}.restart-schedule-body{display:flex;align-items:stretch;gap:18px;padding:0 18px 18px}.restart-schedule-primary{display:flex;min-width:0;flex:1;flex-direction:column;align-items:flex-start;gap:7px;padding:14px;border:1px solid #d6e2ef;border-radius:10px;background:#f6f9fd}.restart-schedule-primary strong{color:#26466c;font-size:14px}.restart-schedule-policy{color:#657b98;font-size:11px;line-height:1.45}.restart-schedule-metrics{display:grid;min-width:390px;grid-template-columns:repeat(2,minmax(0,1fr));border:1px solid #d6e2ef;border-radius:10px;background:#fff}.restart-schedule-metrics>div{min-width:0;padding:14px;border-left:1px solid #e1e9f2}.restart-schedule-metrics>div:first-child{border-left:0}.restart-schedule-metrics span,.restart-schedule-metrics small{display:block;color:#74869d;font-size:10px}.restart-schedule-metrics strong{display:block;margin:6px 0 4px;overflow:hidden;color:#294a73;font-size:12px;text-overflow:ellipsis;white-space:nowrap}.restart-schedule-details{display:grid;gap:8px;margin-top:15px}.restart-schedule-detail{padding:10px 11px;border:1px solid #d8e3ee;border-radius:8px;background:#f7f9fc;color:#5b718e;font-size:12px;line-height:1.45}.restart-schedule-detail strong{display:block;margin-bottom:3px;color:#294a73;font-size:11px}.restart-schedule-queues{display:grid;width:100%;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;margin-top:5px}.restart-queue-stat{min-width:0;padding:9px 10px;border:1px solid #cddced;border-radius:8px;background:#fff;color:#355779;text-align:left;cursor:pointer}.restart-queue-stat:hover{border-color:#78a2d9;background:#eef5ff}.restart-queue-stat span,.restart-queue-stat small{display:block;color:#70839b;font-size:10px}.restart-queue-stat strong{display:block;margin:3px 0;color:#224e83;font-size:18px}.restart-schedule-metrics>.restart-schedule-actions{grid-column:1/-1;display:flex;justify-content:flex-end;gap:8px;padding:9px 12px;border-left:0;border-top:1px solid #e1e9f2;background:#f7f9fc}.restart-schedule-actions[hidden],.restart-schedule-action[hidden]{display:none!important}.restart-schedule-action{display:inline-flex;align-items:center;gap:7px;min-height:29px;padding:5px 9px;border:1px solid #cbd9e8;border-radius:7px;background:#fff;color:#426283;font:11px inherit;font-weight:700;cursor:pointer;transition:border-color .16s ease,background .16s ease,color .16s ease}.restart-schedule-action strong{display:inline-flex;align-items:center;justify-content:center;min-width:17px;height:17px;padding:0 4px;border-radius:999px;background:#e7effa;color:#2864b5;font-size:10px;line-height:1}.restart-schedule-action:hover{border-color:#7ca6dc;background:#eef5ff;color:#1e569f}.restart-schedule-action.failure{border-color:#edc5ca;background:#fffafa;color:#a23f4e}.restart-schedule-action.failure strong{background:#f9e2e5;color:#a23f4e}.restart-schedule-action.failure:hover{border-color:#dc8b96;background:#fff2f3}.restart-schedule-action:focus-visible{outline:2px solid #6d9fe4;outline-offset:2px}.restart-schedule-action:disabled{border-color:#dce4ee;background:#f7f9fc;color:#91a0b3;cursor:default}.restart-schedule-action:disabled strong{background:#e8edf3;color:#91a0b3}.restart-details-dialog{width:min(760px,calc(100% - 32px))}.restart-record-list{display:grid;gap:9px;max-height:min(58vh,540px);margin-top:15px;overflow:auto}.restart-record{padding:11px;border:1px solid #d8e2ee;border-radius:8px;background:#f8fafd}.restart-record strong{display:block;color:#294a73;font-size:12px}.restart-record p{margin:6px 0 0;color:#506a8a;font-size:12px;line-height:1.45}.restart-record small{display:block;margin-top:7px;color:#71839c;font-size:10px}.restart-record-actions{display:flex;gap:10px;margin-top:8px}.restart-record-actions button{padding:0;border:0;border-bottom:1px solid currentColor;background:transparent;color:#2864b5;font:11px inherit;font-weight:700;cursor:pointer}.restart-history-trend{display:grid;gap:7px;padding:10px;border:1px solid #cddced;border-radius:8px;background:#f3f7fc}.restart-history-trend strong{color:#294a73;font-size:12px}.restart-history-trend-line{display:grid;grid-template-columns:92px 1fr auto;align-items:center;gap:8px;color:#617894;font-size:10px}.restart-history-trend-bar{height:7px;overflow:hidden;border-radius:999px;background:#dbe6f1}.restart-history-trend-bar span{display:block;height:100%;border-radius:inherit;background:#3476e7}.restart-history-trend-line.failed .restart-history-trend-bar span{background:#c14358}.restart-record-empty{padding:24px 12px;border:1px dashed #cbd7e5;border-radius:8px;background:#f7f9fc;color:#71839c;font-size:12px;text-align:center}.restart-schedule-dialog{width:min(520px,calc(100% - 32px))}.instance-connections-dialog{width:min(860px,calc(100% - 32px))}.instance-connections-dialog .dialog-body{padding-bottom:18px}.instance-connection-list{display:grid;gap:9px;max-height:min(58vh,560px);margin-top:16px;overflow:auto}.instance-connection-empty{padding:24px 12px;border:1px dashed #cbd7e5;border-radius:8px;background:#f7f9fc;color:#71839c;font-size:12px;text-align:center}.instance-connection-item{padding:12px;border:1px solid #d8e2ee;border-radius:9px;background:#f8fafd}.instance-connection-head{display:flex;align-items:center;justify-content:space-between;gap:10px;color:#2a466d;font-size:12px}.instance-connection-head strong{color:#1e3658}.instance-connection-egress{color:#2864b5;font-size:11px;font-weight:700}.instance-connection-target{margin-top:8px;overflow:hidden;color:#2a3f5c;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}.instance-connection-meta{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px;margin-top:10px;color:#71839c;font-size:10px}.instance-connection-meta strong{display:block;margin-top:3px;overflow:hidden;color:#415b7e;font-size:11px;font-weight:650;text-overflow:ellipsis;white-space:nowrap}@media(max-width:800px){.attention-summary{text-align:left}.filter-bar{padding:0 14px 12px}.task-list{padding:0 14px 14px}.log-actions{justify-content:flex-start}.restart-schedule-body{flex-direction:column;padding:0 14px 14px}.restart-schedule-metrics{min-width:0}.restart-schedule-primary{padding:12px}.instance-connection-meta{grid-template-columns:repeat(2,minmax(0,1fr))}}

/* 实例表把操作摘要与详细诊断分层，避免长错误文本压缩主行。 */
.canvas-app .instance-table{width:100%;min-width:1120px;table-layout:fixed}.instance-table .instance-column{width:82px}.instance-table .process-column{width:42px}.instance-table .manual-column{width:64px}.instance-table .health-column{width:56px}.instance-table .warp-column{width:40px}.instance-table .ipv4-column{width:110px}.instance-table .ipv6-column{width:176px}.instance-table .country-column,.instance-table .pop-column{width:34px}.instance-table .pool-column{width:48px}.instance-table .connections-column{width:60px}.instance-table .uptime-column{width:68px}.instance-table .operation-column{width:144px}.instance-table .actions-column{width:80px}.canvas-app .instance-table th,.canvas-app .instance-table td{overflow:hidden}.canvas-app .instance-table td.operation-column,.canvas-app .instance-table td.instance-actions{overflow:visible}.canvas-app .instance-table th:last-child{position:sticky;right:0;z-index:3;background:#f5f8fc;box-shadow:-10px 0 12px -12px rgba(43,69,103,.45)}.canvas-app .instance-table td.instance-actions{position:sticky;right:0;z-index:2;background:#fff;box-shadow:-10px 0 12px -12px rgba(43,69,103,.45)}.canvas-app .instance-table tbody tr:hover td.instance-actions{background:#f5f8ff}.operation-summary{display:block;width:100%;min-height:34px;padding:0;border:0;background:transparent;color:#38516f;font:inherit;text-align:left;white-space:normal;cursor:pointer}.operation-summary:hover strong{text-decoration:underline;text-underline-offset:3px}.operation-summary:focus-visible{outline:2px solid #6d9fe4;outline-offset:3px;border-radius:3px}.operation-summary strong{display:block;overflow:hidden;color:#304967;font-size:11px;line-height:1.35;text-overflow:ellipsis;white-space:nowrap}.operation-summary span{display:block;overflow:hidden;margin-top:2px;color:#71839c;font-size:10px;line-height:1.3;text-overflow:ellipsis;white-space:nowrap}.operation-summary.failed strong{color:#b54759}.operation-summary.recovered strong{color:#a76a12}.operation-summary.running strong,.operation-summary.queued strong,.operation-summary.deferred strong,.operation-summary.backend-retry strong,.operation-summary.claiming strong,.operation-summary.draining strong,.operation-summary.restarting strong,.operation-summary.probing strong,.operation-summary.reconnecting strong,.operation-summary.starting strong,.operation-summary.stopping strong{color:#9a5e00}.operation-summary.none{cursor:default}.operation-summary.none:hover strong{text-decoration:none}.operation-detail-row:hover{background:transparent!important}.operation-detail-row>td{padding:0!important;border-top:0!important;background:#f8fafc}.operation-detail{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:16px;align-items:start;margin:0 11px 12px;padding:14px 15px;border:1px solid #d8e2ef;border-left:3px solid #c14358;border-radius:8px;background:#fff;box-shadow:0 4px 12px rgba(46,75,110,.06);white-space:normal}.operation-detail.recovered{border-left-color:#d49a35}.operation-detail-main{min-width:0}.operation-detail-heading{display:flex;align-items:center;gap:8px;margin:0 0 10px;color:#263f60;font-size:12px}.operation-detail-heading strong{font-size:13px}.operation-detail-state{padding:3px 6px;border-radius:999px;background:#ffeaed;color:#b54759;font-size:10px;font-weight:750}.operation-detail.recovered .operation-detail-state{background:#fff4dc;color:#a4680a}.operation-detail-grid{display:grid;grid-template-columns:repeat(3,minmax(140px,1fr));gap:9px 18px}.operation-detail-field{min-width:0}.operation-detail-field span{display:block;margin-bottom:2px;color:#7b8ca2;font-size:10px}.operation-detail-field strong{display:block;overflow-wrap:anywhere;color:#3d5573;font-size:11px;font-weight:650;line-height:1.45}.operation-detail-field.reason{grid-column:span 2}.operation-detail-field.reason strong{color:#9f3e50}.operation-detail-current{margin:0 0 10px;color:#5b7393;font-size:11px;line-height:1.45}.operation-detail-actions{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:6px;min-width:170px}.operation-detail-actions .action{background:#fff}.instance-actions{overflow:visible!important}.action-group{display:flex;align-items:center;justify-content:flex-start;gap:6px;min-width:0;white-space:nowrap}.canvas-app .instance-table .action-group>.action{flex:0 0 auto;white-space:nowrap}.action-icon{display:inline-flex;align-items:center;justify-content:center;width:28px;min-width:28px;height:28px;min-height:28px;padding:0!important;font-size:15px;line-height:1}.action-icon.restart{font-size:18px}.action-icon.disable{font-size:15px}.restart-choice-dialog{width:min(520px,calc(100% - 32px))}.restart-choice-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-top:16px}.restart-choice-option{display:flex;min-height:108px;flex-direction:column;align-items:flex-start;justify-content:flex-start;gap:7px;padding:13px;border:1px solid #cbd9e8;border-radius:9px;background:#fff;color:#315175;font:inherit;text-align:left;cursor:pointer}.restart-choice-option:hover{border-color:#78a2d9;background:#eef5ff;color:#1e569f}.restart-choice-option strong{font-size:13px}.restart-choice-option span{color:#657b98;font-size:11px;line-height:1.5}.restart-choice-option.force{border-color:#edc5ca;background:#fffafa;color:#a23f4e}.restart-choice-option.force:hover{border-color:#dc8b96;background:#fff2f3}.restart-choice-option.force span{color:#98606c}@media(max-width:560px){.restart-choice-list{grid-template-columns:1fr}.restart-choice-option{min-height:0}}@media(max-width:800px){.canvas-app .instance-table{width:100%;min-width:1120px}.operation-detail{grid-template-columns:1fr}.operation-detail-grid{grid-template-columns:repeat(2,minmax(130px,1fr))}.operation-detail-field.reason{grid-column:span 2}.operation-detail-actions{justify-content:flex-start}}
</style></head><body><main class="app canvas-app">
<header class="topbar"><div class="brand"><span class="brand-mark">◌</span><span>MicroWARP <span class="brand-subtitle">单端口实例控制面</span></span></div><nav class="canvas-nav" aria-label="管理页面导航"><a class="active" aria-current="page" href="#overview">总览</a><a href="#instances-panel">实例</a><a href="#connections-panel">连接</a><a href="#logs-panel">日志</a></nav><div class="top-meta"><span id="control-plane-state" class="live">控制面在线</span><label class="refresh-interval-label" for="refresh-interval">自动刷新<select id="refresh-interval" class="refresh-interval"><option value="1000">1 秒</option><option value="3000">3 秒</option><option value="5000" selected>5 秒</option><option value="10000">10 秒</option><option value="15000">15 秒</option><option value="30000">30 秒</option></select></label></div></header>
<section id="overview" class="hero"><div><div class="eyebrow">运行概览</div><h1 id="headline">正在读取实例状态…</h1><div id="summary" class="summary">正在连接本地控制面。</div></div><div class="hero-stats"><div class="hero-stat"><span>可用实例</span><strong id="healthy-count">—</strong></div><div class="hero-stat"><span>活跃连接</span><strong id="connection-count">—</strong></div><div class="hero-stat"><span>上行</span><strong id="traffic-up">—</strong></div><div class="hero-stat"><span>下行</span><strong id="traffic-down">—</strong></div></div></section>
<div class="toolbar"><div class="toolbar-note"><span id="updated">等待首次刷新</span><span>·</span><span id="refresh-state">仅展示当前活跃会话</span></div><div class="toolbar-actions"><button id="add-instance" class="manage-button primary" type="button">＋ 添加临时实例</button><button id="remove-instance" class="manage-button danger" type="button">批量移除</button><button id="refresh" class="refresh" type="button">刷新数据</button></div></div>
<section id="operations-panel" class="panel operation-panel" aria-labelledby="operations-title" hidden tabindex="-1"><header class="panel-head"><div class="panel-title"><h2 id="operations-title">进行中的任务</h2><span id="operation-note">操作会自动追踪至完成</span></div><div class="panel-caption">任务进行期间刷新频率自动提升至 1 秒</div></header><div id="task-list" class="task-list"></div></section>
<section id="restart-schedule-panel" class="panel restart-schedule-panel" aria-labelledby="restart-schedule-title"><header class="panel-head"><div class="panel-title"><h2 id="restart-schedule-title">定时重启计划</h2><span id="restart-schedule-note">正在读取计划状态…</span></div><button id="manage-restart-schedule" class="manage-button" type="button">管理计划</button></header><div class="restart-schedule-body"><div class="restart-schedule-primary"><span id="restart-schedule-state" class="badge wait">加载中</span><strong id="restart-schedule-summary">正在读取滚动重启配置</strong><span id="restart-schedule-policy" class="restart-schedule-policy">—</span><div class="restart-schedule-queues" aria-label="滚动重启队列状态"><button id="restart-ready-queue" class="restart-queue-stat" type="button"><span>就绪队列</span><strong id="restart-ready-count">0</strong><small>空闲后可立即处理</small></button><button id="restart-deferred-queue" class="restart-queue-stat" type="button"><span>延后队列</span><strong id="restart-deferred-count">0</strong><small id="restart-deferred-next">当前无待复查实例</small></button><button id="restart-backend-retry-queue" class="restart-queue-stat" type="button"><span>后端池重试</span><strong id="restart-backend-retry-count">0</strong><small id="restart-backend-retry-next">当前无待确认操作</small></button></div></div><div class="restart-schedule-metrics"><div><span>下次执行</span><strong id="restart-schedule-next">—</strong><small id="restart-schedule-countdown">—</small></div><div><span>最近执行</span><strong id="restart-schedule-last">—</strong><small id="restart-schedule-result">暂无执行记录</small></div><div id="restart-schedule-actions" class="restart-schedule-actions" aria-label="定时重启记录操作" hidden><button id="restart-schedule-failures" class="restart-schedule-action failure" type="button" hidden><span>失败详情</span><strong id="restart-schedule-failure-count">0</strong></button><button id="restart-schedule-history" class="restart-schedule-action" type="button" hidden><span>执行历史</span><strong id="restart-schedule-history-count">0</strong></button></div></div></div></section>
<section id="instances-panel" class="panel"><header class="panel-head instance-panel-head"><div class="panel-title"><h2>实例</h2><span id="instance-note">加载中</span></div><div id="attention-summary" class="attention-summary">正在汇总实例状态…</div></header><div class="filter-bar" role="toolbar" aria-label="实例筛选"><button type="button" class="filter-button active" data-filter="all" aria-pressed="true">全部</button><button type="button" class="filter-button" data-filter="attention" aria-pressed="false">需要关注</button><button type="button" class="filter-button" data-filter="running" aria-pressed="false">操作中</button><button type="button" class="filter-button" data-filter="healthy" aria-pressed="false">健康</button><button type="button" class="filter-button" data-filter="disabled" aria-pressed="false">已停用</button><button type="button" class="filter-button" data-filter="temporary" aria-pressed="false">临时实例</button></div><div id="instances-matrix" class="instance-matrix" aria-busy="true"></div><div id="instance-table-wrap" class="table-wrap matrix-fallback"><table class="table instance-table"><colgroup><col class="instance-column"><col class="process-column"><col class="manual-column"><col class="health-column"><col class="warp-column"><col class="ipv4-column"><col class="ipv6-column"><col class="country-column"><col class="pop-column"><col class="pool-column"><col class="connections-column"><col class="uptime-column"><col class="operation-column"><col class="actions-column"></colgroup><thead><tr><th>实例</th><th>进程</th><th>人工状态</th><th>健康</th><th>WARP</th><th>IPv4 出口</th><th>IPv6 出口</th><th>国家</th><th>PoP</th><th>后端池</th><th>活跃连接</th><th>在线时长</th><th>最近操作</th><th>操作</th></tr></thead><tbody id="instances"></tbody></table></div></section>
<section id="connections-panel" class="panel connection-panel"><header class="panel-head"><div class="panel-title"><h2>当前活跃连接</h2><span id="connection-note">加载中</span></div><div class="panel-caption">连接关闭后会立即从此列表移除</div></header><div class="table-wrap"><table class="table"><thead><tr><th>请求 ID</th><th>协议</th><th>客户端</th><th>用户 ID</th><th>目标</th><th>出口</th><th>后端</th><th>已持续 / 空闲</th><th>上行 / 下行</th></tr></thead><tbody id="connections"></tbody></table></div></section>
<section id="logs-panel" class="panel log-panel"><header class="panel-head"><div class="panel-title"><h2>控制台日志</h2><span id="log-note">加载中</span></div><div class="log-actions"><label class="log-filter-label" for="log-filter">筛选<select id="log-filter" class="log-filter"><option value="all">全部</option><option value="warn">警告及错误</option><option value="error">仅错误</option></select></label><span id="log-new-count" class="log-new-count" hidden></span><button id="logs-bottom" class="log-control" type="button">回到底部</button><button id="logs-reset" class="log-control" type="button" hidden>查看控制台</button><button id="copy-logs" class="log-control" type="button">复制日志</button></div></header><pre id="logs" class="log-output" aria-live="off">正在读取日志…</pre></section>
</main><dialog id="instance-connections-dialog" class="dialog instance-connections-dialog"><div class="dialog-body"><h3 id="instance-connections-title">实例活跃连接</h3><p id="instance-connections-note">正在读取当前活跃连接。</p><div id="instance-connections-list" class="instance-connection-list" aria-live="polite"></div></div><div class="dialog-actions"><button id="instance-connections-close" type="button">关闭</button></div></dialog><dialog id="restart-schedule-dialog" class="dialog restart-schedule-dialog"><div class="dialog-body"><h3>定时重启计划</h3><p id="restart-schedule-dialog-message">正在读取计划详情。</p><div id="restart-schedule-details" class="restart-schedule-details"></div></div><div class="dialog-actions"><button id="restart-schedule-close" type="button">关闭</button><button id="restart-schedule-run-now" class="confirm" type="button">立即执行</button><button id="restart-schedule-toggle" type="button">暂停计划</button></div></dialog><dialog id="restart-queue-dialog" class="dialog restart-details-dialog"><div class="dialog-body"><h3 id="restart-queue-title">队列实例</h3><p id="restart-queue-note">正在读取队列实例。</p><div id="restart-queue-list" class="restart-record-list" aria-live="polite"></div></div><div class="dialog-actions"><button id="restart-queue-close" type="button">关闭</button></div></dialog><dialog id="restart-diagnostic-dialog" class="dialog restart-details-dialog"><div class="dialog-body"><h3 id="restart-diagnostic-title">滚动重启诊断</h3><p id="restart-diagnostic-note">正在读取执行诊断。</p><div id="restart-diagnostic-list" class="restart-record-list" aria-live="polite"></div></div><div class="dialog-actions"><button id="restart-diagnostic-close" type="button">关闭</button></div></dialog><dialog id="resize-dialog" class="resize-dialog"><div class="resize-body"><h3 id="resize-title">临时添加实例</h3><p id="resize-message">实例仅在当前容器生命周期内有效，重启后自动恢复配置数量。</p><div id="resize-summary" class="dialog-details"></div><label id="add-count-label" for="add-count">添加数量（1–8）</label><input id="add-count" type="number" min="1" max="8" value="1" inputmode="numeric"><div id="remove-list" class="remove-list" hidden></div></div><div class="dialog-actions"><button id="resize-cancel" type="button">取消</button><button id="resize-confirm" class="confirm" type="button">确认执行</button></div></dialog><dialog id="restart-choice-dialog" class="dialog restart-choice-dialog"><div class="dialog-body"><h3 id="restart-choice-title">选择重连方式</h3><p id="restart-choice-message">请选择重建 WARP 连接的策略。</p><div class="restart-choice-list"><button id="restart-choice-graceful" class="restart-choice-option" type="button"><strong>优雅重连</strong><span>连接归零后才摘流并重建；有活跃连接时进入延后队列。</span></button><button id="restart-choice-force" class="restart-choice-option force" type="button"><strong>强制重连</strong><span>立即摘流并重建；有活跃连接时会要求再次确认中断风险。</span></button></div></div><div class="dialog-actions"><button id="restart-choice-cancel" type="button">取消</button></div></dialog><dialog id="confirm-dialog" class="dialog"><div class="dialog-body"><h3 id="dialog-title">确认操作</h3><p id="dialog-message"></p><div id="dialog-details" class="dialog-details"></div><div id="dialog-impact" class="impact" hidden></div><label id="force-ack-row" class="acknowledgement" hidden><input id="force-ack" type="checkbox"> 我知道这会立即中断当前实例上的连接</label></div><div class="dialog-actions"><button id="dialog-cancel" type="button">取消</button><button id="dialog-confirm" class="confirm" type="button">确认执行</button></div></dialog><div id="toast" class="toast" role="status" aria-live="polite"></div><div id="announcement" class="visually-hidden" aria-live="polite" aria-atomic="true"></div><script>
const base='/__microwarp/api/v1/',el=id=>document.getElementById(id),text=value=>value===undefined||value===null||value===''||value==='?'?'—':String(value),fmt=value=>new Intl.NumberFormat().format(Number(value||0)),fmtKB=value=>{const kb=Number(value||0)/1024;return (kb<10?kb.toFixed(2):kb<100?kb.toFixed(1):Math.round(kb))+' KB'},pendingInstances=new Map(),terminalStatuses=new Set(['success','failed','partial','cancelled','recovered']);
let currentAction=null,dialogTrigger=null,restartChoiceItem=null,restartChoiceTrigger=null,restartScheduleTrigger=null,restartDetailsTrigger=null,refreshing=false,refreshTimer=null,lastStatus=null,lastConnections=null,lastLogs=[],lastLogSource=[],instanceLogId=null,instanceConnectionId=null,instanceConnectionTrigger=null,expandedOperationInstanceId=null,selectedFilter='all',lastRefreshSucceededAt=0,lastRefreshError='',lastLogFingerprint='',knownTerminalOperations=new Set(),trackedResizeOperation='',logLoadError='';
function duration(value){const seconds=Math.max(0,Number(value||0));if(seconds<60)return Math.floor(seconds)+' 秒';if(seconds<3600)return Math.floor(seconds/60)+' 分 '+Math.floor(seconds%60)+' 秒';return Math.floor(seconds/3600)+' 时 '+Math.floor(seconds%3600/60)+' 分'}
function configDurationSeconds(value){const raw=String(value||'').trim().toLowerCase().replace(/\\s/g,''),matched=raw.match(/^([0-9]+)([smhd])?$/);if(!matched)return 0;return Number(matched[1])*({s:1,m:60,h:3600,d:86400}[matched[2]||'s'])}
function timestampText(value){const seconds=Number(value||0);return seconds?new Date(seconds*1000).toLocaleString('zh-CN',{hour12:false}):'—'}
function scheduleResultText(result){if(!result||!result.status)return '暂无执行记录';if(result.status==='skipped')return '本轮无符合条件的实例';const labels={success:'全部成功',partial:'部分完成',failed:'执行失败'},parts=['成功 '+Number(result.succeeded||0)],deferred=Number(result.deferred||0),failed=Number(result.failed||0),durationText=Number(result.duration_seconds||0)?' · 耗时 '+duration(result.duration_seconds):'';if(deferred)parts.push('曾延后 '+deferred);parts.push('失败 '+failed);return (labels[result.status]||result.status)+' · '+parts.join(' · ')+durationText}
function uptimeContent(item){const startedAt=Number(item&&item.started_at||0),uptime=Number(item&&item.uptime_seconds),value=document.createElement('span');value.className='online-duration';if(!startedAt){value.classList.add('unknown');value.textContent='—';return value}const seconds=Number.isFinite(uptime)?uptime:Math.max(0,Math.floor(Date.now()/1000)-startedAt),startedText=new Date(startedAt*1000).toLocaleString('zh-CN',{hour12:false});value.textContent=duration(seconds);value.title='启动时间：'+startedText;value.setAttribute('aria-label','在线时长 '+duration(seconds)+'，启动时间 '+startedText);return value}
function cell(value,className){const td=document.createElement('td');if(className)td.className=className;if(value instanceof Node)td.append(value);else td.textContent=text(value);return td}
function badge(label,kind){const value=document.createElement('span');value.className='badge '+kind;value.textContent=label;return value}
function announce(message){const target=el('announcement');target.textContent='';requestAnimationFrame(()=>{target.textContent=message})}
function toast(message,error=false){const target=el('toast');target.textContent=message;target.className='toast show'+(error?' error':'');clearTimeout(toast.timer);toast.timer=setTimeout(()=>target.className='toast',error?6200:3600);announce(message)}
function scheduleStatePresentation(schedule){const state=schedule&&schedule.status||'waiting';if(state==='disabled')return {label:'未启用',kind:'off'};if(state==='unavailable')return {label:'仅多实例',kind:'off'};if(state==='paused')return {label:'已暂停',kind:'off'};if(state==='running')return {label:'执行中',kind:'wait'};if(state==='starting')return {label:'正在启动',kind:'wait'};return {label:'已启用',kind:'ok'}}
function restartScheduleMessage(schedule){const state=schedule&&schedule.status||'waiting';if(state==='disabled')return '当前滚动重启配置未启用。请调整 ROTATE_RESTART_ENABLED 后重建容器。';if(state==='unavailable')return '定时滚动重启仅适用于多实例部署；当前实例数量不足，无需创建执行计划。';if(state==='starting')return '已收到立即执行请求，正在等待容器内调度器接管本轮任务。该操作遵循空闲优先和繁忙延后策略。';if(state==='paused')return '后续定时轮次已暂停；恢复后会按当前间隔重新计算下一次执行时间。立即执行不会恢复后续定时轮次。';if(state==='running')return schedule.pause_requested?'本轮滚动重启仍在执行，后续定时轮次已暂停。':'当前正在按空闲优先策略滚动重启，繁忙实例会保持服务并按配置间隔复查，直到自然空闲。';return '计划按空闲优先的连续队列执行：空闲实例立即重启；仍有活跃连接的实例保持服务并按配置间隔复查，直到自然空闲。实际执行时间由容器内调度器决定，页面按浏览器本地时区显示。'}
function renderRestartSchedule(status){const schedule=status.restart_schedule||{},presentation=scheduleStatePresentation(schedule),interval=Number(schedule.interval_seconds||0),policy=schedule.policy||{},current=schedule.current||{},result=schedule.last_result||null,state=String(schedule.status||'waiting'),ready=Number(current.queued||0),deferred=Number(current.deferred||0),backendRetry=Number(current.backend_retry||0),nextDeferred=Number(current.next_deferred_check_at||0),nextBackendRetry=Number(current.next_backend_retry_at||0);const badge=el('restart-schedule-state');badge.className='badge '+presentation.kind;badge.textContent=presentation.label;el('restart-schedule-note').textContent=state==='running'?'本轮执行期间自动提升刷新频率':state==='starting'?'立即执行请求已受理，正在等待调度器接管':state==='paused'?'暂停仅影响后续定时轮次':state==='disabled'||state==='unavailable'?'由容器环境变量控制':'计划由调度器持续维护';let summary='每 '+duration(interval)+' 执行一次';if(state==='disabled')summary='未配置定时滚动重启';else if(state==='unavailable')summary='单实例部署无需滚动重启计划';else if(state==='paused')summary='后续定时滚动重启已暂停';else if(state==='starting')summary='正在启动立即执行';else if(state==='running'){const total=Number(current.total||0),completed=Number(current.completed||0);summary='正在滚动重启'+(total?'：已处理 '+completed+' / '+total+' 个实例':'');}el('restart-schedule-summary').textContent=summary;const deferredInterval=duration(Number(policy.deferred_check_interval_seconds||60)),policyText=(Number(schedule.scope_count||0))+' 个实例 · 空闲优先 · 最大并行 '+Number(policy.concurrency||1)+' · 繁忙实例每 '+deferredInterval+' 复查';el('restart-schedule-policy').textContent=policyText;el('restart-ready-count').textContent=String(ready);el('restart-deferred-count').textContent=String(deferred);el('restart-backend-retry-count').textContent=String(backendRetry);el('restart-ready-queue').disabled=ready===0;el('restart-deferred-queue').disabled=deferred===0;el('restart-backend-retry-queue').disabled=backendRetry===0;el('restart-ready-queue').title=ready?'查看 '+ready+' 个就绪队列实例':'当前无就绪队列实例';el('restart-deferred-queue').title=deferred?'查看 '+deferred+' 个延后队列实例':'当前无延后队列实例';el('restart-backend-retry-queue').title=backendRetry?'查看 '+backendRetry+' 个后端池重试实例':'当前无待确认后端池操作';el('restart-deferred-next').textContent=deferred?(nextDeferred?'下次复查 '+timestampText(nextDeferred)+'（约 '+duration(Math.max(0,nextDeferred-Math.floor(Date.now()/1000)))+' 后）':'等待调度器记录下次复查时间'):'当前无待复查实例';el('restart-backend-retry-next').textContent=backendRetry?(nextBackendRetry?'下次重试 '+timestampText(nextBackendRetry)+'（约 '+duration(Math.max(0,nextBackendRetry-Math.floor(Date.now()/1000)))+' 后）':'等待调度器记录下次重试时间'):'当前无待确认操作';const next=Number(schedule.next_run_at||0);if(state==='waiting'&&next){const remaining=Math.max(0,next-Math.floor(Date.now()/1000));el('restart-schedule-next').textContent=timestampText(next);el('restart-schedule-countdown').textContent='约 '+duration(remaining)+' 后';}else if(state==='starting'){el('restart-schedule-next').textContent='正在启动';el('restart-schedule-countdown').textContent='已请求立即执行，等待调度器接管';}else if(state==='running'){el('restart-schedule-next').textContent=nextDeferred?'延后队列复查':nextBackendRetry?'后端池重试':'本轮执行中';el('restart-schedule-countdown').textContent=nextDeferred?'下次复查 '+timestampText(nextDeferred)+'（约 '+duration(Math.max(0,nextDeferred-Math.floor(Date.now()/1000)))+' 后） · 就绪 '+ready+' · 延后 '+deferred+' · 后端池重试 '+backendRetry:nextBackendRetry?'下次重试 '+timestampText(nextBackendRetry)+'（约 '+duration(Math.max(0,nextBackendRetry-Math.floor(Date.now()/1000)))+' 后） · 就绪 '+ready+' · 后端池重试 '+backendRetry:'已处理 '+Number(current.completed||0)+' · 就绪 '+ready+' · 延后 '+deferred+' · 后端池重试 '+backendRetry+' · 成功 '+Number(current.succeeded||0)+' · 失败 '+Number(current.failed||0);}else{el('restart-schedule-next').textContent='—';el('restart-schedule-countdown').textContent=state==='disabled'?'设置后可启用':state==='unavailable'?'需要至少 2 个实例':state==='paused'?'恢复后重新计算':'等待调度器初始化';}const lastAt=Number(schedule.last_run_at||0);el('restart-schedule-last').textContent=lastAt?timestampText(lastAt):'—';el('restart-schedule-result').textContent=scheduleResultText(result);const failures=Number(result&&result.failed||0),historyCount=Number((schedule.history||[]).length),failureButton=el('restart-schedule-failures'),historyButton=el('restart-schedule-history'),actionBar=el('restart-schedule-actions'),hasFailureDetails=failures>0&&Boolean(result&&result.run_id);failureButton.hidden=!hasFailureDetails;failureButton.disabled=!hasFailureDetails;el('restart-schedule-failure-count').textContent=String(failures);historyButton.hidden=historyCount===0;historyButton.disabled=historyCount===0;el('restart-schedule-history-count').textContent=String(historyCount);actionBar.hidden=!hasFailureDetails&&historyCount===0;el('restart-schedule-dialog-message').textContent=restartScheduleMessage(schedule);const details=el('restart-schedule-details');details.replaceChildren();const queueText='就绪队列 '+ready+' · 延后队列 '+deferred+(deferred?(nextDeferred?' · 下次复查 '+timestampText(nextDeferred):' · 等待下次复查时间'):' · 当前无待复查实例')+' · 后端池重试 '+backendRetry+(backendRetry?(nextBackendRetry?' · 下次重试 '+timestampText(nextBackendRetry):' · 等待下次重试时间'):' · 当前无待确认操作'),rows=[['执行周期','每 '+duration(interval)+' 运行一次（配置值：'+text(schedule.interval)+'）'],['范围与策略',policyText],['队列状态',queueText],['下次执行',state==='waiting'&&next?timestampText(next)+'（约 '+duration(Math.max(0,next-Math.floor(Date.now()/1000)))+' 后）':state==='running'?'当前轮次执行中':state==='starting'?'已请求立即执行':state==='paused'?'计划已暂停':state==='unavailable'?'仅多实例可用':'—'],['最近执行',lastAt?timestampText(lastAt)+' · '+scheduleResultText(result)+(failures?' · 可查看 '+failures+' 条失败明细':''):'尚无执行记录']];for(const [label,value] of rows){const row=document.createElement('div'),title=document.createElement('strong');row.className='restart-schedule-detail';title.textContent=label;row.append(title,document.createTextNode(value));details.append(row)}const toggle=el('restart-schedule-toggle'),runNow=el('restart-schedule-run-now'),canToggle=Boolean(schedule.config_active&&schedule.scheduler_available),canRunNow=canToggle&&state!=='running'&&state!=='starting';runNow.disabled=!canRunNow;runNow.textContent=state==='starting'?'正在启动…':'立即执行';runNow.title=canRunNow?'立即启动一轮空闲优先的滚动重启；不会恢复已暂停的后续定时轮次':state==='running'||state==='starting'?'当前已有滚动重启任务正在执行或启动':'当前计划不可立即执行';toggle.disabled=!canToggle;toggle.textContent=schedule.paused?'恢复计划':'暂停计划';toggle.title=canToggle?'':schedule.config_active?'定时滚动重启仅适用于多实例部署':'当前 ROTATE_RESTART_ENABLED 配置未启用';}
function restartDetailEmpty(target,message){target.replaceChildren();const empty=document.createElement('div');empty.className='restart-record-empty';empty.textContent=message;target.append(empty)}
async function copyRestartDiagnostic(record){const content=['实例 '+text(record.instance_id),'阶段：'+text(record.phase),'失败码：'+text(record.reason_code),'原因：'+text(record.reason),'尝试：'+text(record.attempt)+' / '+text(record.max_attempts),'活跃连接：'+text(record.active_connections),'开始：'+timestampText(record.started_at),'结束：'+timestampText(record.finished_at),'日志：'+text(record.log_reference)].join('\\n');try{if(!navigator.clipboard||!window.isSecureContext)throw new Error('clipboard unavailable');await navigator.clipboard.writeText(content);toast('已复制实例 '+text(record.instance_id)+' 的诊断信息')}catch(error){const input=document.createElement('textarea');input.value=content;input.style.position='fixed';input.style.opacity='0';document.body.append(input);input.select();const copied=document.execCommand('copy');input.remove();toast(copied?'已复制实例 '+text(record.instance_id)+' 的诊断信息':'复制诊断失败，请手动复制',!copied)}}
function renderRestartDiagnosticRecords(records,kind){const list=el('restart-diagnostic-list');if(!records.length){restartDetailEmpty(list,kind==='history'?'暂无保留的执行历史':'当前没有可展示的实例记录');return}list.replaceChildren();if(kind==='history'){const trend=document.createElement('section'),heading=document.createElement('strong');trend.className='restart-history-trend';heading.textContent='近 '+records.length+' 轮趋势（成功率 / 失败 / 曾延后）';trend.append(heading);for(const record of [...records].reverse()){const total=Math.max(1,Number(record.total||0)),succeeded=Number(record.succeeded||0),failed=Number(record.failed||0),line=document.createElement('div'),label=document.createElement('span'),bar=document.createElement('div'),fill=document.createElement('span'),value=document.createElement('span');line.className='restart-history-trend-line'+(failed?' failed':'');label.textContent=timestampText(record.completed_at||record.started_at).replace(/^.*\\s/,'');bar.className='restart-history-trend-bar';fill.style.width=Math.round(succeeded*100/total)+'%';bar.append(fill);value.textContent=Math.round(succeeded*100/total)+'% · 失败 '+failed+' · 延后 '+Number(record.deferred||0);line.append(label,bar,value);trend.append(line)}list.append(trend)}for(const record of records){const card=document.createElement('article'),title=document.createElement('strong'),reason=document.createElement('p'),meta=document.createElement('small');card.className='restart-record';if(kind==='history'){title.textContent='执行 '+text(record.run_id)+' · '+text(record.status);reason.textContent='总数 '+Number(record.total||0)+' · 成功 '+Number(record.succeeded||0)+' · 失败 '+Number(record.failed||0)+' · 跳过 '+Number(record.skipped||0)+' · 曾延后 '+Number(record.deferred||0);meta.textContent='开始 '+timestampText(record.started_at)+' · 完成 '+timestampText(record.completed_at)+' · 耗时 '+duration(record.duration_seconds)+' · 队列峰值 '+Number(record.max_queued||0)+' / '+Number(record.max_deferred||0)+' · 平均延后等待 '+duration(record.avg_deferred_wait_seconds);card.append(title,reason,meta);if(Number(record.failed||0)>0){const actions=document.createElement('div'),detail=document.createElement('button');actions.className='restart-record-actions';detail.type='button';detail.textContent='查看失败原因（'+Number(record.failed||0)+'）';detail.onclick=()=>openRestartRunFailures(String(record.run_id),detail);actions.append(detail);card.append(actions)}}else{title.textContent='实例 '+text(record.instance_id)+' · '+(kind==='failures'?'失败：':'跳过：')+text(record.reason_code);reason.textContent=text(record.reason||record.message);meta.textContent=(record.phase?'阶段 '+text(record.phase)+' · ':'')+'活跃连接 '+Number(record.active_connections||0)+' · '+(record.finished_at?'结束 '+timestampText(record.finished_at):record.next_check_at?'下次复查 '+timestampText(record.next_check_at):'');card.append(title,reason,meta);if(kind==='failures'){const actions=document.createElement('div'),copy=document.createElement('button'),logs=document.createElement('button');actions.className='restart-record-actions';copy.type='button';copy.textContent='复制诊断';copy.onclick=()=>copyRestartDiagnostic(record);logs.type='button';logs.textContent='查看实例日志';logs.onclick=()=>{closeRestartDetails();focusLogsForInstance(Number(record.instance_id))};actions.append(copy,logs);card.append(actions)}}list.append(card)}}

function openRestartDetails(title,note,trigger){restartDetailsTrigger=trigger||document.activeElement;el('restart-diagnostic-title').textContent=title;el('restart-diagnostic-note').textContent=note;const dialog=el('restart-diagnostic-dialog');if(!dialog.open)dialog.showModal();requestAnimationFrame(()=>el('restart-diagnostic-close').focus())}
function closeRestartDetails(){const dialog=el('restart-diagnostic-dialog');if(dialog.open)dialog.close()}
function resetRestartDetails(){const trigger=restartDetailsTrigger;restartDetailsTrigger=null;if(trigger&&typeof trigger.focus==='function')requestAnimationFrame(()=>trigger.focus())}
async function openRestartQueue(kind,trigger){restartDetailsTrigger=trigger||document.activeElement;const labels={ready:'就绪队列实例',deferred:'延后队列实例','backend-retry':'后端池重试实例'},dialog=el('restart-queue-dialog');el('restart-queue-title').textContent=labels[kind]||'队列实例';el('restart-queue-note').textContent='正在读取当前队列快照。';if(!dialog.open)dialog.showModal();restartDetailEmpty(el('restart-queue-list'),'正在读取队列实例…');try{const data=await requestJson(base+'restart-schedule/runs/current/queue/'+kind),records=data.instances||[];el('restart-queue-note').textContent=kind==='ready'?'空闲实例会按并行额度连续处理。':kind==='deferred'?'繁忙实例保持服务；连接自然归零后转入就绪队列。':'后端池状态尚未确认；实例保持运行，调度器会按退避时间重试摘流。';const list=el('restart-queue-list');if(!records.length){restartDetailEmpty(list,'当前无'+(kind==='ready'?'就绪':kind==='deferred'?'延后':'后端池重试')+'队列实例');return}list.replaceChildren();for(const record of records){const card=document.createElement('article'),title=document.createElement('strong'),detail=document.createElement('p'),meta=document.createElement('small');card.className='restart-record';title.textContent='实例 '+text(record.instance_id);if(kind==='ready'){detail.textContent='队列位置 '+text(record.queue_position)+' / '+text(record.queue_total)+' · '+text(record.message);meta.textContent='入队 '+timestampText(record.queue_entered_at)}else if(kind==='deferred'){detail.textContent='活跃连接 '+Number(record.active_connections||0)+' · '+text(record.message);meta.textContent='延后于 '+timestampText(record.deferred_at)+' · 下次复查 '+timestampText(record.next_check_at)}else{detail.textContent='重试 '+Number(record.backend_retry_attempt||0)+' / '+Number(record.backend_retry_limit||0)+' · '+text(record.message);meta.textContent='原因码 '+text(record.reason_code||'未记录')+' · 下次重试 '+timestampText(record.next_check_at)}card.append(title,detail,meta);list.append(card)}}catch(error){el('restart-queue-note').textContent='读取失败：'+error.message;restartDetailEmpty(el('restart-queue-list'),'无法读取队列实例') }}
function closeRestartQueue(){const dialog=el('restart-queue-dialog');if(dialog.open)dialog.close()}
async function openRestartRunFailures(runId,trigger){if(!runId){toast('暂无可查看的失败明细',true);return}openRestartDetails('滚动重启失败原因','正在读取失败实例的阶段、原因与尝试次数。',trigger);restartDetailEmpty(el('restart-diagnostic-list'),'正在读取失败明细…');try{const data=await requestJson(base+'restart-schedule/runs/'+encodeURIComponent(runId)+'/failures');el('restart-diagnostic-note').textContent='失败实例不会被延后队列掩盖；可复制诊断或跳转至该实例日志。';renderRestartDiagnosticRecords(data.records||[],'failures')}catch(error){el('restart-diagnostic-note').textContent='读取失败：'+error.message;restartDetailEmpty(el('restart-diagnostic-list'),'无法读取失败明细')}}
async function openRestartFailures(trigger){const result=lastStatus&&lastStatus.restart_schedule&&lastStatus.restart_schedule.last_result;return openRestartRunFailures(result&&result.run_id,trigger)}
async function openRestartHistory(trigger){openRestartDetails('定时重启执行历史','正在读取保留的最近执行轮次。',trigger);restartDetailEmpty(el('restart-diagnostic-list'),'正在读取执行历史…');try{const data=await requestJson(base+'restart-schedule/history');el('restart-diagnostic-note').textContent='保留最近 '+Number(data.history_limit||0)+' 轮摘要；失败原因可从最近一轮入口查看。';renderRestartDiagnosticRecords(data.runs||[],'history')}catch(error){el('restart-diagnostic-note').textContent='读取失败：'+error.message;restartDetailEmpty(el('restart-diagnostic-list'),'无法读取执行历史')}}
function openRestartSchedule(trigger){restartScheduleTrigger=trigger||document.activeElement;const dialog=el('restart-schedule-dialog');if(lastStatus)renderRestartSchedule(lastStatus);if(!dialog.open)dialog.showModal();requestAnimationFrame(()=>{const runNow=el('restart-schedule-run-now'),toggle=el('restart-schedule-toggle');(runNow.disabled?(toggle.disabled?el('restart-schedule-close'):toggle):runNow).focus()})}
function closeRestartSchedule(){const dialog=el('restart-schedule-dialog');if(dialog.open)dialog.close()}
function resetRestartScheduleDialog(){const trigger=restartScheduleTrigger;restartScheduleTrigger=null;if(trigger&&typeof trigger.focus==='function')requestAnimationFrame(()=>trigger.focus())}
async function submitRestartScheduleAction(){const schedule=lastStatus&&lastStatus.restart_schedule||{},action=schedule.paused?'resume':'pause',button=el('restart-schedule-toggle');button.disabled=true;button.textContent='正在提交…';try{const data=await requestJson(base+'restart-schedule',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action})});toast(data.message||'定时重启计划已更新');await refresh(true);if(lastStatus)renderRestartSchedule(lastStatus)}catch(error){toast('更新定时重启计划失败：'+error.message,true);if(lastStatus)renderRestartSchedule(lastStatus)}}
async function submitRestartScheduleRunNow(){const button=el('restart-schedule-run-now');button.disabled=true;button.textContent='正在提交…';try{const data=await requestJson(base+'restart-schedule',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'run-now'})});toast(data.message||'已请求立即执行滚动重启');await refresh(true);if(lastStatus)renderRestartSchedule(lastStatus)}catch(error){toast('立即执行滚动重启失败：'+error.message,true);if(lastStatus)renderRestartSchedule(lastStatus)}}
const navigationLinks=[...document.querySelectorAll('.canvas-nav a[href^="#"]')];let navigationFrame=0;
function setActiveNavigation(sectionId){for(const link of navigationLinks){const active=link.getAttribute('href')==='#'+sectionId;link.classList.toggle('active',active);if(active)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current')}}
function syncNavigationFocus(){const sections=navigationLinks.map(link=>document.querySelector(link.getAttribute('href'))).filter(Boolean);if(!sections.length)return;const topbar=document.querySelector('.canvas-app .topbar'),threshold=(topbar?topbar.getBoundingClientRect().height:0)+16;let active=sections[0];for(const section of sections){if(section.getBoundingClientRect().top<=threshold)active=section;else break}if(window.innerHeight+window.scrollY>=document.documentElement.scrollHeight-2)active=sections[sections.length-1];setActiveNavigation(active.id)}
function scheduleNavigationFocus(){if(navigationFrame)return;navigationFrame=requestAnimationFrame(()=>{navigationFrame=0;syncNavigationFocus()})}
navigationLinks.forEach(link=>link.addEventListener('click',()=>{const targetId=link.getAttribute('href').slice(1);setActiveNavigation(targetId);requestAnimationFrame(scheduleNavigationFocus)}));window.addEventListener('scroll',scheduleNavigationFocus,{passive:true});window.addEventListener('resize',scheduleNavigationFocus);window.addEventListener('hashchange',scheduleNavigationFocus);
function healthBadge(item){const kind=item.health&&item.health.kind||'unknown';if(kind==='ready'||kind==='healthy')return badge('健康','ok');if(kind==='disabled')return badge('已停用','off');return item.process!=='up'?badge('未就绪','error'):badge(kind==='unknown'?'等待探测':kind,'wait')}
function actionLabel(action){return {enable:'启用',disable:'停用',reconnect:'优雅重连','force-reconnect':'强制重连','rolling-restart':'滚动重启','scheduled-rolling-restart':'定时滚动重启',add:'添加实例',remove:'移除实例'}[action]||'管理操作'}
function statusLabel(status){return {queued:'已排队',deferred:'等待自然空闲','backend-retry':'等待后端池确认',claiming:'正在摘流复核',running:'执行中',draining:'连接排空中',restarting:'正在重启实例',probing:'WARP 健康探测中',reconnecting:'正在重建 WARP',starting:'正在启动',stopping:'正在停止',success:'已完成',recovered:'超时后已恢复',failed:'执行失败',partial:'部分完成',cancelled:'已取消'}[status]||status||'等待状态更新'}
function phaseLabel(phase){return {received:'已接收请求','wait-idle':'等待自然空闲','backend-drain':'后端池摘流','backend-restore':'恢复后端池流量',reconnect:'重建 WARP 连接','instance-start':'启动实例','instance-stop':'停止实例','warp-probe':'WARP 健康探测',recovered:'健康守护恢复',controller:'管理控制器',completed:'完成',unknown:'未知阶段'}[phase]||phase||'—'}
function operationTerminal(operation){const current=operation||{};return Boolean(current.terminal||terminalStatuses.has(current.status||''))}
function operationTimingText(operation){const current=operation||{},terminal=operationTerminal(current),parts=[],durationSeconds=Number(current.duration_seconds);if(terminal){if(Number.isFinite(durationSeconds)&&durationSeconds>=0)parts.push('执行耗时 '+duration(durationSeconds));else if(current.elapsed_seconds!==undefined&&Number.isFinite(Number(current.elapsed_seconds)))parts.push('执行耗时 '+duration(current.elapsed_seconds));if(Number(current.finished_at||0))parts.push('结束于 '+timestampText(current.finished_at));return parts.join(' · ')}if(current.elapsed_seconds!==undefined&&Number.isFinite(Number(current.elapsed_seconds)))parts.push('已执行 '+duration(current.elapsed_seconds));return parts.join(' · ')}
function operationRunning(operation){return Boolean(operation&&operation.action&&!(operation.action==='scheduled-rolling-restart'&&operation.status==='deferred')&&!operationTerminal(operation))}
function automaticOperation(operation){return Boolean(operation&&(operation.action==='rolling-restart'||operation.action==='scheduled-rolling-restart'))}
function operationDescription(operation){const current=operation||{},queuedRestart=current.action==='scheduled-rolling-restart'&&current.status==='queued',deferredOperation=current.status==='deferred',title=actionLabel(current.action)+' · '+(queuedRestart?'等待定时重启':deferredOperation?'等待自然空闲':statusLabel(current.status)),details=[];if(current.message)details.push(current.message);if(current.recovered_after_timeout)details.push('超时后 '+duration(current.recovery_delay_seconds)+' 恢复');if(current.queue_position!==undefined&&current.queue_total!==undefined)details.push('就绪队列 '+current.queue_position+' / '+current.queue_total);if(current.active_connections!==undefined&&current.active_connections!=='')details.push('活跃连接 '+current.active_connections);if(current.next_check_at!==undefined&&current.next_check_at!=='')details.push('下次复查 '+timestampText(current.next_check_at));const timing=operationTimingText(current);if(timing)details.push(timing);return {title,detail:details.join(' · ')||'等待状态更新'}}
function isTemporary(item){return item.id>=((lastStatus&&lastStatus.configured_instance_count)||0)}
function isHealthy(item){const kind=item.health&&item.health.kind;return !item.manual_disabled&&item.process==='up'&&(kind==='ready'||kind==='healthy')}
function operationRecovered(item){const operation=item&&item.operation||{};return operation.status==='recovered'||operation.status==='failed'&&isHealthy(item)&&item.pool==='up'}
function operationPresentation(item){const current=item&&item.operation||{},status=current.status||'';if(!current.action&&!current.message)return {kind:'none',title:'—',subtitle:'暂无管理操作',detail:''};const content=operationDescription(current),recovered=operationRecovered(item);if(status==='recovered')return {kind:'recovered',title:actionLabel(current.action)+'已恢复',subtitle:'WARP 已恢复并重新入池；保留超时诊断',detail:content.detail,recovered:true};if(recovered)return {kind:'recovered',title:actionLabel(current.action)+'未按时完成',subtitle:'实例当前已恢复并重新入池',detail:content.detail,recovered:true};if(status==='failed')return {kind:'failed',title:content.title,subtitle:'查看失败原因与本次日志',detail:content.detail};const timing=operationTimingText(current);return {kind:status||'running',title:content.title,subtitle:timing||current.message||'查看操作详情',detail:content.detail}}
function operationDetailsId(instanceId){return 'operation-detail-'+String(instanceId)}
function toggleOperationDetails(instanceId){const opening=expandedOperationInstanceId!==instanceId;expandedOperationInstanceId=opening?instanceId:null;renderFromLast();if(opening)requestAnimationFrame(()=>{const detail=document.getElementById(operationDetailsId(instanceId));if(detail)detail.focus()})}
function operationDetailsButton(item,label){const button=document.createElement('button');button.type='button';button.className='action';button.textContent=label;button.onclick=()=>toggleOperationDetails(item.id);return button}
function operationCell(item){const presentation=operationPresentation(item),button=document.createElement('button');button.type='button';button.className='operation-summary '+presentation.kind;button.title=presentation.detail||presentation.subtitle;const title=document.createElement('strong'),subtitle=document.createElement('span');title.textContent=presentation.title;subtitle.textContent=presentation.subtitle;button.append(title,subtitle);if(presentation.kind==='none'){button.disabled=true;return button}const expanded=expandedOperationInstanceId===item.id;button.setAttribute('aria-expanded',String(expanded));button.setAttribute('aria-controls',operationDetailsId(item.id));button.setAttribute('aria-label','查看实例 '+item.id+' 的最近操作详情：'+presentation.title);button.onclick=()=>toggleOperationDetails(item.id);return button}
function currentInstanceState(item){const states=[];states.push(item.process==='up'?'进程运行中':'进程未运行');states.push(item.manual_disabled?'已手工停用':isHealthy(item)?'WARP 健康':'WARP 未就绪');states.push(item.pool==='up'?'已入池':'已摘流');states.push('活跃连接 '+Number(item.active_connections||0));return states.join(' · ')}
function operationDetailField(label,value,className=''){const field=document.createElement('div'),name=document.createElement('span'),content=document.createElement('strong');field.className='operation-detail-field '+className;name.textContent=label;content.textContent=text(value);field.append(name,content);return field}
function operationDetailRow(item){const current=item.operation||{},presentation=operationPresentation(item),recovered=current.status==='recovered'||current.recovered_after_timeout,row=document.createElement('tr'),cellNode=document.createElement('td'),panel=document.createElement('section'),main=document.createElement('div'),heading=document.createElement('div'),title=document.createElement('strong'),state=document.createElement('span'),currentState=document.createElement('p'),grid=document.createElement('div'),actions=document.createElement('div');row.className='operation-detail-row';cellNode.colSpan=14;panel.id=operationDetailsId(item.id);panel.className='operation-detail'+(presentation.recovered?' recovered':'');panel.tabIndex=-1;heading.className='operation-detail-heading';title.textContent='最近操作 · '+actionLabel(current.action);state.className='operation-detail-state';state.textContent=recovered?'超时后已恢复':statusLabel(current.status);heading.append(title,state);currentState.className='operation-detail-current';currentState.textContent='当前实例状态：'+currentInstanceState(item);grid.className='operation-detail-grid';grid.append(operationDetailField('操作结果',recovered?'超时后已恢复并重新入池':statusLabel(current.status)),operationDetailField('执行阶段',phaseLabel(current.phase)),operationDetailField('开始时间',timestampText(current.started_at)),operationDetailField('最终恢复时间',recovered?timestampText(current.recovered_at||current.finished_at):operationTerminal(current)?timestampText(current.finished_at):'执行中'),operationDetailField('全链路耗时',operationTimingText(current)||'—'),operationDetailField(recovered?'首次超时原因':'失败原因',recovered?(current.timeout_message||'WARP 健康探测超时'):current.status==='failed'?(current.message||'未记录具体原因'):'—','reason'),operationDetailField(recovered?'首次超时原因码':'原因码',recovered?(current.timeout_reason_code||'warp-probe-timeout'):current.status==='failed'?(current.reason_code||'未记录'):'—'),operationDetailField(recovered?'超时后恢复等待':'操作 ID',recovered?duration(current.recovery_delay_seconds):current.operation_id||'—'));if(recovered)grid.append(operationDetailField('操作 ID',current.operation_id||'—'));main.append(heading,currentState,grid);actions.className='operation-detail-actions';if(current.action){actions.append(operationDetailsButton(item,'收起'));const logs=document.createElement('button');logs.type='button';logs.className='action';logs.textContent='查看本次日志';logs.onclick=()=>focusLogsForInstance(item.id);actions.append(logs);if(current.status==='failed'&&!presentation.recovered&&!isBusy(item))actions.append(actionButton(item,current.action,'重试','enable'))}panel.append(main,actions);cellNode.append(panel);row.append(cellNode);return row}
function isBusy(item){return Boolean(item.operation_running||operationRunning(item.operation)||pendingInstances.has(item.id))}
function matchesFilter(item){if(selectedFilter==='all')return true;if(selectedFilter==='attention')return !isHealthy(item)||isBusy(item);if(selectedFilter==='running')return isBusy(item);if(selectedFilter==='healthy')return isHealthy(item);if(selectedFilter==='disabled')return item.manual_disabled;if(selectedFilter==='temporary')return isTemporary(item);return true}
function actionButton(item,name,label,className){const busy=isBusy(item),operation=item.operation||{},button=document.createElement('button');button.type='button';button.className='action '+(className||'');button.disabled=busy;if(busy){button.textContent=operationRunning(operation)?statusLabel(operation.status):'操作处理中…';button.title=operationDescription(operation).detail||'实例正在执行管理操作，完成后才能再次操作。'}else{button.textContent=label;button.onclick=event=>openAction(item,name,event.currentTarget)}return button}
function actionIconButton(item,name,icon,label,className){const button=actionButton(item,name,label,className);button.classList.add('action-icon');button.textContent=icon;button.title=label;button.setAttribute('aria-label','实例 '+item.id+'：'+label);return button}
function restartActionButton(item){const button=document.createElement('button');button.type='button';button.className='action action-icon restart';button.textContent='↻';button.title='选择重连方式';button.setAttribute('aria-label','实例 '+item.id+'：选择优雅重连或强制重连');button.setAttribute('aria-haspopup','dialog');button.onclick=event=>openRestartChoice(item,event.currentTarget);return button}
function instanceActionGroup(item){const actions=document.createElement('div');actions.className='action-group';const operation=item.operation||{},failed=operation.status==='failed'&&Boolean(operation.action),recovered=operationRecovered(item);if(isBusy(item)){actions.append(actionIconButton(item,operation.action||'reconnect','◌','查看操作进度',''));return actions}if(failed&&!recovered)actions.append(actionIconButton(item,operation.action,'↻','重试上次操作','enable'));else if(failed&&recovered)actions.append(actionIconButton(item,operation.action,'↻','重试上次操作',''));else if(item.manual_disabled)actions.append(actionIconButton(item,'enable','⏻','启用','enable'));else actions.append(restartActionButton(item));if(!item.manual_disabled)actions.append(actionIconButton(item,'disable','⏻','停用','disable'));return actions}
function focusLogsForInstance(instanceId){instanceLogId=instanceId;el('logs-reset').hidden=false;el('logs-panel').scrollIntoView({behavior:'smooth',block:'start'});refresh(true)}
function instanceConnectionButton(item){const button=document.createElement('button'),count=Number(item.active_connections||0);button.type='button';button.className='connection-link';button.textContent=String(count);button.title='查看实例 '+item.id+' 的当前活跃连接';button.setAttribute('aria-label','查看实例 '+item.id+' 的 '+count+' 条当前活跃连接');button.setAttribute('aria-haspopup','dialog');button.onclick=event=>openInstanceConnections(item,event.currentTarget);return button}
function renderInstanceConnectionDialog(){if(instanceConnectionId===null)return;const dialog=el('instance-connections-dialog');if(!dialog.open)return;const instance=(lastStatus&&lastStatus.instances||[]).find(item=>Number(item.id)===instanceConnectionId),items=(lastConnections&&lastConnections.connections||[]).filter(item=>Number(item.backend_instance)===instanceConnectionId),list=el('instance-connections-list');el('instance-connections-title').textContent='实例 '+instanceConnectionId+' 的活跃连接';el('instance-connections-note').textContent='当前显示 '+items.length+' 条仍在转发的会话；页面刷新时会自动同步。';list.replaceChildren();if(!items.length){const empty=document.createElement('div');empty.className='instance-connection-empty';empty.textContent=instance&&Number(instance.active_connections||0)>0?'连接快照正在同步，请稍候。':'当前实例没有活跃代理连接';list.append(empty);return}for(const item of items){const card=document.createElement('article'),head=document.createElement('div'),title=document.createElement('strong'),egress=document.createElement('span'),target=document.createElement('div'),meta=document.createElement('div');card.className='instance-connection-item';head.className='instance-connection-head';title.textContent='#'+text(item.id)+' · '+text(item.protocol);egress.className='instance-connection-egress';egress.textContent=text(item.egress_family||'未知出口');head.append(title,egress);target.className='instance-connection-target';target.textContent=text(item.target);meta.className='instance-connection-meta';for(const [label,value] of [['客户端',text(item.client)+(item.username?' · '+text(item.username):'')],['已持续 / 空闲',duration(item.duration_seconds)+' / '+duration(item.idle_seconds)],['上行 / 下行',fmtKB(item.bytes_client_to_backend)+' / '+fmtKB(item.bytes_backend_to_client)],['后端',text(item.backend)]]){const field=document.createElement('div'),name=document.createElement('span'),content=document.createElement('strong');name.textContent=label;content.textContent=value;field.append(name,content);meta.append(field)}card.append(head,target,meta);list.append(card)}}
function openInstanceConnections(item,trigger){instanceConnectionId=Number(item.id);instanceConnectionTrigger=trigger||document.activeElement;const dialog=el('instance-connections-dialog');if(!dialog.open)dialog.showModal();renderInstanceConnectionDialog();requestAnimationFrame(()=>el('instance-connections-close').focus());refresh(true)}
function closeInstanceConnections(){const dialog=el('instance-connections-dialog');if(dialog.open)dialog.close()}
function resetInstanceConnectionsDialog(){const trigger=instanceConnectionTrigger;instanceConnectionId=null;instanceConnectionTrigger=null;if(trigger&&typeof trigger.focus==='function')requestAnimationFrame(()=>trigger.focus())}
function renderInstanceMatrix(items){const target=el('instances-matrix');target.replaceChildren();target.setAttribute('aria-busy','false');const visible=items.filter(matchesFilter);if(!visible.length){const empty=document.createElement('div');empty.className='empty';empty.textContent='当前筛选条件下没有匹配实例';target.append(empty);return}for(const item of visible){const health=item.health||{},legacyIp=health.ip||'',ip4=health.ip4||(!legacyIp.includes(':')?legacyIp:'—'),ip6=health.ip6||(legacyIp.includes(':')?legacyIp:'—'),card=document.createElement('article');card.className='instance-card';const head=document.createElement('div');head.className='instance-card-head';const identity=document.createElement('div');identity.className='instance-card-id';const badgeId=document.createElement('span');badgeId.className='instance-id';badgeId.textContent=String(item.id).padStart(2,'0');const title=document.createElement('span');title.textContent='实例 '+item.id;identity.append(badgeId,title);if(isTemporary(item)){const temp=document.createElement('span');temp.className='instance-temp';temp.textContent='临时';head.append(identity,temp)}else head.append(identity);head.append(healthBadge(item));card.append(head);const meta=document.createElement('div');meta.className='instance-card-meta';const fields=[['进程',item.process==='up'?'运行中':'已停止'],['后端池',item.pool==='up'?'已入池':'已摘流'],['IPv4',ip4],['IPv6',ip6],['位置',(health.loc||'—')+' · '+(health.colo||'—')],['活跃连接',null],['在线时长',null]];for(const [label,value] of fields){const box=document.createElement('div'),strong=document.createElement('strong');box.textContent=label;if(label==='活跃连接')strong.append(instanceConnectionButton(item));else if(label==='在线时长')strong.append(uptimeContent(item));else strong.textContent=value;box.append(strong);meta.append(box)}card.append(meta);const op=operationCell(item);op.className+=' instance-card-operation';card.append(op);const actions=instanceActionGroup(item);actions.className+=' instance-card-actions';card.append(actions);target.append(card)}}
function renderInstances(items){renderInstanceMatrix(items);const body=el('instances');body.replaceChildren();const visible=items.filter(matchesFilter);if(expandedOperationInstanceId!==null&&!visible.some(item=>item.id===expandedOperationInstanceId))expandedOperationInstanceId=null;el('instance-note').textContent=selectedFilter==='all'?items.length+' 个实例 · 字段完整展示':visible.length+' / '+items.length+' 个实例';let healthy=0,attention=0,running=0,disabled=0;for(const item of items){if(isHealthy(item))healthy++;else attention++;if(isBusy(item))running++;if(item.manual_disabled)disabled++;}const pieces=[];if(attention)pieces.push(attention+' 个实例需要关注');if(running)pieces.push(running+' 个任务进行中');if(disabled)pieces.push(disabled+' 个实例已停用');el('attention-summary').textContent=pieces.length?pieces.join(' · '):'全部实例健康，当前没有待处理任务';for(const item of visible){const health=item.health||{},instance=document.createElement('div'),id=document.createElement('span'),name=document.createElement('span'),manual=item.manual_disabled?'已停用':'已启用',legacyIp=health.ip||'',ip4=health.ip4||(!legacyIp.includes(':')?legacyIp:'—'),ip6=health.ip6||(legacyIp.includes(':')?health.ip6||legacyIp:'—');id.className='instance-id';id.textContent=String(item.id).padStart(2,'0');name.textContent='实例 '+item.id+(isTemporary(item)?' · 临时':'');instance.className='instance';instance.append(id,name);const row=document.createElement('tr');row.append(cell(instance),cell(item.process==='up'?'up':'down'),cell(manual,'manual '+(item.manual_disabled?'disabled':'enabled')),cell(healthBadge(item)),cell(health.warp||'—'),cell(ip4,'location'),cell(ip6,'location'),cell(health.loc||'—','location'),cell(health.colo||'—','location'),cell(item.pool==='up'?'已入池':'已摘流','pool '+(item.pool==='up'?'up':'down')),cell(instanceConnectionButton(item),'connections'),cell(uptimeContent(item),'uptime'),cell(operationCell(item),'operation-column'),cell(instanceActionGroup(item),'instance-actions'));body.append(row);if(expandedOperationInstanceId===item.id&&item.operation&&(item.operation.action||item.operation.message))body.append(operationDetailRow(item))}if(!visible.length){const row=document.createElement('tr'),empty=cell('当前筛选条件下没有匹配实例','empty');empty.colSpan=14;row.append(empty);body.append(row)}el('healthy-count').textContent=healthy+' / '+items.length;el('headline').textContent=attention?'有实例需要关注':'全部实例运行正常'}
function renderTasks(status){const target=el('task-list');target.replaceChildren();const tasks=[];for(const item of status.instances||[]){const operation=item.operation||{};if((operationRunning(operation)&&operation.action!=='scheduled-rolling-restart')||item.operation_running){tasks.push({kind:'instance',id:item.id,operation:operation.action?operation:{action:'操作',status:'running',message:'正在启动管理操作'}})}}const resize=status.resize_operation||{};if(status.resize_operation_running||operationRunning(resize)){tasks.push({kind:'resize',operation:resize})}const panel=el('operations-panel');panel.hidden=!tasks.length;if(!tasks.length)return;for(const task of tasks){const operation=task.operation||{},content=operationDescription(operation),card=document.createElement('article');card.className='task-card '+(operation.status||'running');const heading=document.createElement('strong');heading.textContent=task.kind==='resize'?content.title+' · 批量任务':'实例 '+task.id+' · '+content.title;const detail=document.createElement('span');detail.textContent=content.detail;card.append(heading,detail);if(task.kind==='resize'){const total=Number(operation.total||0),completed=Number(operation.completed||0),progress=document.createElement('div');progress.className='task-progress';const bar=document.createElement('span');bar.style.width=total?Math.min(100,Math.round(completed*100/total))+'%':'0%';progress.setAttribute('aria-label','已处理 '+completed+' / '+total+' 个实例');progress.append(bar);const label=document.createElement('small');label.textContent='已处理 '+completed+' / '+total+' · 成功 '+Number(operation.succeeded||0)+' · 失败 '+Number(operation.failed||0);card.append(progress,label)}target.append(card)}}
function syncOperationFeedback(status){for(const item of status.instances||[]){const operation=item.operation||{},tracked=pendingInstances.get(item.id);if(tracked&&operation.terminal&&(operation.operation_id===tracked||!operation.operation_id)){pendingInstances.delete(item.id);const key='instance:'+item.id+':'+(operation.operation_id||tracked)+':'+operation.status+':'+(operation.updated_at||'');if(!knownTerminalOperations.has(key)){knownTerminalOperations.add(key);toast('实例 '+item.id+'：'+operationDescription(operation).title+'，'+(operation.message||'操作完成'),operation.status==='failed')}}else if(operationRunning(operation)&&!automaticOperation(operation)){pendingInstances.set(item.id,operation.operation_id||tracked||'server')}}const resize=status.resize_operation||{};if(trackedResizeOperation&&resize.terminal&&(resize.operation_id===trackedResizeOperation||!resize.operation_id)){const key='resize:'+(resize.operation_id||trackedResizeOperation)+':'+resize.status+':'+(resize.updated_at||'');trackedResizeOperation='';if(!knownTerminalOperations.has(key)){knownTerminalOperations.add(key);toast('批量实例调整：'+(resize.message||statusLabel(resize.status)),resize.status==='failed'||resize.status==='partial')}}}
function logsAreAtBottom(){const target=el('logs');return target.scrollHeight-target.scrollTop-target.clientHeight<28}
function countNewLines(previous,next){if(!previous.length)return 0;let start=Math.max(0,previous.length-next.length);while(start<next.length&&previous[0]!==next[start])start++;if(start<next.length&&previous.every((line,index)=>next[start+index]===line))return Math.max(0,next.length-(start+previous.length));return next.length===previous.length?1:Math.max(1,next.length-previous.length)}
function scrollLogsToBottom(){const target=el('logs');target.dataset.follow='true';target.scrollTop=target.scrollHeight;el('log-new-count').hidden=true}
function filteredLogs(){const mode=el('log-filter').value;return (lastLogs||[]).filter(line=>mode==='all'||mode==='error'?mode==='all'||line.includes('[ERROR]'):line.includes('[WARN]')||line.includes('[ERROR]'))}
function renderLogs(lines){const target=el('logs'),follow=target.dataset.follow!=='false'&&logsAreAtBottom(),source=lines||[],newCount=lastLogFingerprint?countNewLines(lastLogSource,source):0;lastLogSource=[...source];lastLogFingerprint=source.join('\\n');target.replaceChildren();for(const line of filteredLogs()){const node=document.createElement('span');node.className='log-line '+(line.includes('[WARN]')?'warn':line.includes('[ERROR]')?'error':'');node.textContent=line;target.append(node,document.createTextNode('\\n'))}const context=instanceLogId?'实例 '+instanceLogId+' 的管理日志':'控制台日志';el('log-note').textContent=context+' · '+filteredLogs().length+' / '+source.length+' 行'+(logLoadError?' · 日志刷新失败：'+logLoadError:'');if(!follow&&newCount){const counter=el('log-new-count');counter.hidden=false;counter.textContent='有 '+newCount+' 条新日志'}if(follow)requestAnimationFrame(scrollLogsToBottom)}
function renderConnections(items){const body=el('connections');body.replaceChildren();el('connection-note').textContent=items.length+' 条会话';if(!items.length){const row=document.createElement('tr'),empty=cell('当前没有活跃代理连接','empty');empty.colSpan=9;row.append(empty);body.append(row);return}for(const item of items){const row=document.createElement('tr');row.append(cell(item.id),cell(item.protocol,'protocol'),cell(item.client),cell(item.username||'—'),cell(item.target,'target'),cell(item.egress_family||'未知','egress'),cell('实例 '+item.backend_instance+' · '+item.backend),cell(duration(item.duration_seconds)+' / '+duration(item.idle_seconds),'details'),cell(fmtKB(item.bytes_client_to_backend)+' / '+fmtKB(item.bytes_backend_to_client),'details'));body.append(row)}}
function resizeAvailability(){const total=(lastStatus&&lastStatus.instances||[]).length;return Math.max(0,255-total)}
function upcomingInstanceIds(count){const used=new Set((lastStatus&&lastStatus.instances||[]).map(item=>Number(item.id))),ids=[];for(let id=0;id<255&&ids.length<count;id++){if(!used.has(id))ids.push(id)}return ids}
function updateResizeDialog(){const dialog=el('resize-dialog'),mode=dialog.dataset.mode;if(mode==='add'){const count=Math.min(8,Math.max(1,Number(el('add-count').value||1))),available=resizeAvailability();el('resize-summary').textContent='当前 '+((lastStatus&&lastStatus.instances||[]).length)+' / 255 个实例；本次将添加 '+count+' 个，可用槽位 '+available+' 个；预览编号：'+upcomingInstanceIds(count).map(id=>'实例 '+id).join('、')+'。';el('resize-confirm').disabled=available<1||count>available;el('resize-confirm').title=available<1?'没有可用实例槽位':''}else{const selected=[...el('remove-list').querySelectorAll('input:checked')],connections=selected.reduce((total,input)=>total+Number(input.dataset.connections||0),0),interval=(lastStatus&&lastStatus.management&&lastStatus.management.deferred_check_interval)||'60';el('resize-summary').textContent=selected.length?'将移除 '+selected.length+' 个临时实例，其中 '+connections+' 条活跃连接会继续服务；连接归零后才摘流并移除，每 '+duration(configDurationSeconds(interval))+' 复查。':'请至少选择一个临时实例。';el('resize-confirm').disabled=!selected.length}}
function openResize(mode,trigger){dialogTrigger=trigger||document.activeElement;const dialog=el('resize-dialog');el('resize-title').textContent=mode==='add'?'临时添加实例':'批量移除临时实例';el('resize-message').textContent=mode==='add'?'实例仅在当前容器生命周期内有效。创建后将启动并进入 WARP 健康探测流程。':'仅可移除带“临时”标记的实例；有活跃连接的实例会留在延后队列继续服务，直到自然空闲后才移除。';el('add-count-label').hidden=mode!=='add';el('add-count').hidden=mode!=='add';const list=el('remove-list');list.hidden=mode!=='remove';list.replaceChildren();if(mode==='remove'){const items=(lastStatus&&lastStatus.instances||[]).filter(isTemporary);if(!items.length)list.textContent='当前没有可移除的临时实例';for(const item of items){const label=document.createElement('label'),input=document.createElement('input');input.type='checkbox';input.value=item.id;input.dataset.connections=String(item.active_connections||0);input.disabled=isBusy(item);input.onchange=updateResizeDialog;label.append(input,document.createTextNode('实例 '+item.id+' · '+Number(item.active_connections||0)+' 条连接'+(isBusy(item)?' · 操作中':'')));list.append(label)}}dialog.dataset.mode=mode;updateResizeDialog();dialog.showModal();requestAnimationFrame(()=>mode==='add'?el('add-count').focus():el('resize-confirm').focus())}
function closeDialog(dialogId,focusTarget=true){const dialog=el(dialogId),trigger=dialogTrigger;if(dialog&&dialog.open)dialog.close();dialogTrigger=null;if(focusTarget&&trigger&&typeof trigger.focus==='function')requestAnimationFrame(()=>{if(document.contains(trigger))trigger.focus()})}
async function requestJson(path,options={}){const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),8000);try{const response=await fetch(path,{...options,signal:controller.signal});let payload={};try{payload=await response.json()}catch(error){}if(!response.ok)throw new Error(payload.message||'请求失败（HTTP '+response.status+'）');return payload}catch(error){throw new Error(error.name==='AbortError'?'请求超时，请检查控制面连接':error.message||'网络请求失败')}finally{clearTimeout(timer)}}
async function submitResize(){const mode=el('resize-dialog').dataset.mode;let payload={action:mode};if(mode==='add')payload.count=Math.min(8,Math.max(1,Number(el('add-count').value||1)));else payload.ids=[...el('remove-list').querySelectorAll('input:checked')].map(input=>Number(input.value));el('resize-confirm').disabled=true;el('resize-confirm').textContent='正在提交…';try{const data=await requestJson(base+'instances',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});trackedResizeOperation=data.operation&&data.operation.operation_id||'pending';closeDialog('resize-dialog',false);toast(data.message||'实例调整已开始');await refresh(true);const panel=el('operations-panel');if(!panel.hidden)panel.focus()}catch(error){toast('实例调整失败：'+error.message,true);el('resize-confirm').textContent='确认执行';updateResizeDialog()}}
function openRestartChoice(item,trigger){restartChoiceItem=item;restartChoiceTrigger=trigger||document.activeElement;el('restart-choice-title').textContent='重连实例 '+item.id;el('restart-choice-message').textContent='请选择重建 WARP 连接的策略。当前活跃连接：'+Number(item.active_connections||0)+' 条。';const dialog=el('restart-choice-dialog');dialog.showModal();requestAnimationFrame(()=>el('restart-choice-graceful').focus())}
function closeRestartChoice(focusTarget=true){const dialog=el('restart-choice-dialog'),trigger=restartChoiceTrigger;if(dialog.open)dialog.close();restartChoiceItem=null;restartChoiceTrigger=null;if(focusTarget&&trigger&&typeof trigger.focus==='function')requestAnimationFrame(()=>{if(document.contains(trigger))trigger.focus()})}
function chooseRestartMode(name){const item=restartChoiceItem,trigger=restartChoiceTrigger;closeRestartChoice(false);if(item)openAction(item,name,trigger)}
function resetRestartChoiceDialog(){restartChoiceItem=null;restartChoiceTrigger=null}
function openAction(item,name,trigger){dialogTrigger=trigger||document.activeElement;const labels={enable:'启用实例',disable:'停用实例',reconnect:'优雅重连','force-reconnect':'强制重连'},messages={enable:'将启动实例，并在 WARP 健康探测通过后重新加入后端池。',disable:'将进入空闲优先队列；实例有连接时会保持服务，直到自然空闲后才停用。',reconnect:'将进入空闲优先队列；实例有连接时会保持服务，直到自然空闲后才重建 WARP 连接。','force-reconnect':'将立即摘流并重建 WARP 连接，不会等待已有连接自然结束。'};currentAction={instanceId:item.id,name};el('dialog-title').textContent=labels[name]+' · 实例 '+item.id;el('dialog-message').textContent=messages[name];const deferredInterval=(lastStatus&&lastStatus.management&&lastStatus.management.deferred_check_interval)||'60',details=[];if(name==='disable'||name==='reconnect')details.push('当前活跃连接：'+Number(item.active_connections||0)+' 条','队列策略：等待连接自然结束，不设排空超时；每 '+configDurationSeconds(deferredInterval)+' 秒检查一次是否已归零');if(name==='enable')details.push('当前后端池：'+(item.pool==='up'?'已入池':'已摘流'),'完成条件：WARP 健康探测通过');if(name==='force-reconnect')details.push('当前活跃连接：'+Number(item.active_connections||0)+' 条',Number(item.active_connections||0)>0?'该实例上的现有代理连接将立即中断':'当前无活跃连接，将立即摘流并重建 WARP 连接');el('dialog-details').textContent=details.join(' · ');const impact=el('dialog-impact'),force=name==='force-reconnect',requiresAck=force&&Number(item.active_connections||0)>0,ack=el('force-ack-row'),confirm=el('dialog-confirm');impact.hidden=!requiresAck;impact.textContent=requiresAck?'强制重连会立即中断该实例上仍在转发的代理连接。':'';ack.hidden=!requiresAck;el('force-ack').checked=false;confirm.className='confirm'+(force?' force':'');confirm.textContent=requiresAck?'立即中断 '+Number(item.active_connections||0)+' 个连接并重连':'确认执行';confirm.disabled=requiresAck;el('confirm-dialog').showModal();requestAnimationFrame(()=>force?el('force-ack').focus():confirm.focus())}
async function submitAction(){if(!currentAction)return;const {instanceId,name}=currentAction;pendingInstances.set(instanceId,'pending');el('dialog-confirm').disabled=true;el('dialog-confirm').textContent='正在提交…';try{const data=await requestJson(base+'instances/'+instanceId+'/'+name,{method:'POST'});pendingInstances.set(instanceId,data.operation&&data.operation.operation_id||'pending');closeDialog('confirm-dialog',false);toast('实例 '+instanceId+'：'+(data.message||'管理操作已开始'));await refresh(true);const panel=el('operations-panel');if(!panel.hidden)panel.focus()}catch(error){pendingInstances.delete(instanceId);toast('实例 '+instanceId+'：'+error.message,true);el('dialog-confirm').disabled=false;el('dialog-confirm').textContent='确认执行';renderFromLast()}finally{currentAction=null}}
function renderFromLast(){if(lastStatus){renderTasks(lastStatus);renderRestartSchedule(lastStatus);renderInstances(lastStatus.instances||[])}if(lastConnections)renderConnections(lastConnections.connections||[]);renderInstanceConnectionDialog();renderLogs(lastLogs)}
function updateRefreshState(success,error=''){const now=Date.now();if(success){lastRefreshSucceededAt=now;lastRefreshError='';el('control-plane-state').className='live';el('control-plane-state').textContent='控制面在线';el('refresh-state').className='';el('refresh-state').textContent='数据已同步'}else{lastRefreshError=error;const age=lastRefreshSucceededAt?duration(Math.floor((now-lastRefreshSucceededAt)/1000)):'尚无成功数据';el('control-plane-state').className='live degraded';el('control-plane-state').textContent='数据可能已过期';el('refresh-state').className='refresh-error';el('refresh-state').textContent='最近成功更新于 '+age+'前 · '+error}}
function hasActiveTasks(){return Boolean((lastStatus&&lastStatus.resize_operation_running)||(lastStatus&&lastStatus.restart_schedule&&['running','starting'].includes(lastStatus.restart_schedule.status))||[...pendingInstances].length||(lastStatus&&lastStatus.instances||[]).some(item=>isBusy(item)))}
function scheduleRefresh(delay){if(refreshTimer)clearTimeout(refreshTimer);const configured=Number(el('refresh-interval').value||5000),next=delay===undefined?(hasActiveTasks()?1000:configured):delay;refreshTimer=setTimeout(()=>refresh(),Math.max(0,next))}
async function refresh(manual=false){if(refreshing)return;refreshing=true;el('instances-matrix').setAttribute('aria-busy','true');const button=el('refresh');button.disabled=true;button.classList.add('loading');button.textContent='正在更新';try{const [status,connections,logs]=await Promise.all([requestJson(base+'status'),requestJson(base+'connections'),requestJson(instanceLogId?base+'instances/'+instanceLogId+'/logs':base+'logs').catch(error=>({_error:error.message,lines:lastLogs}))]);lastStatus=status;lastConnections=connections;lastLogs=logs.lines||[];logLoadError=logs._error||'';syncOperationFeedback(status);renderFromLast();const traffic=(connections.connections||[]).reduce((total,item)=>({up:total.up+Number(item.bytes_client_to_backend||0),down:total.down+Number(item.bytes_backend_to_client||0)}),{up:0,down:0});el('connection-count').textContent=status.active_connection_count||0;el('traffic-up').textContent=fmtKB(traffic.up);el('traffic-down').textContent=fmtKB(traffic.down);el('summary').textContent='入口 '+status.bind+' · '+String(status.proxy_mode).toUpperCase()+' · '+status.strategy+' 调度 · '+status.sticky_mode+' 粘性';el('updated').textContent='更新于 '+new Date().toLocaleTimeString();updateRefreshState(true)}catch(error){updateRefreshState(false,error.message);if(lastRefreshError!==error.message||manual)toast('无法读取控制面状态：'+error.message,true)}finally{refreshing=false;button.disabled=false;button.classList.remove('loading');button.textContent='刷新数据';scheduleRefresh()}}
async function copyLogs(){const content=(filteredLogs()||[]).join('\\n');if(!content){toast('当前筛选条件下没有可复制的日志',true);return}try{if(!navigator.clipboard||!window.isSecureContext)throw new Error('clipboard unavailable');await navigator.clipboard.writeText(content)}catch(error){const input=document.createElement('textarea');input.value=content;input.style.position='fixed';input.style.opacity='0';document.body.append(input);input.select();const copied=document.execCommand('copy');input.remove();if(!copied){toast('复制日志失败，请手动选择复制',true);return}}toast('已复制 '+filteredLogs().length+' 行日志')}
function setFilter(filter){selectedFilter=filter;for(const button of document.querySelectorAll('[data-filter]')){const active=button.dataset.filter===filter;button.classList.toggle('active',active);button.setAttribute('aria-pressed',String(active))}renderFromLast()}
document.querySelectorAll('[data-filter]').forEach(button=>button.onclick=()=>setFilter(button.dataset.filter));el('refresh').onclick=()=>refresh(true);el('restart-choice-cancel').onclick=()=>closeRestartChoice();el('restart-choice-graceful').onclick=()=>chooseRestartMode('reconnect');el('restart-choice-force').onclick=()=>chooseRestartMode('force-reconnect');el('restart-choice-dialog').addEventListener('close',resetRestartChoiceDialog);el('add-instance').onclick=event=>openResize('add',event.currentTarget);el('remove-instance').onclick=event=>openResize('remove',event.currentTarget);el('manage-restart-schedule').onclick=event=>openRestartSchedule(event.currentTarget);el('restart-schedule-close').onclick=closeRestartSchedule;el('restart-schedule-run-now').onclick=submitRestartScheduleRunNow;el('restart-schedule-toggle').onclick=submitRestartScheduleAction;el('restart-ready-queue').onclick=event=>openRestartQueue('ready',event.currentTarget);el('restart-deferred-queue').onclick=event=>openRestartQueue('deferred',event.currentTarget);el('restart-backend-retry-queue').onclick=event=>openRestartQueue('backend-retry',event.currentTarget);el('restart-schedule-failures').onclick=event=>openRestartFailures(event.currentTarget);el('restart-schedule-history').onclick=event=>openRestartHistory(event.currentTarget);el('restart-queue-close').onclick=closeRestartQueue;el('restart-diagnostic-close').onclick=closeRestartDetails;el('restart-schedule-dialog').addEventListener('close',resetRestartScheduleDialog);el('restart-queue-dialog').addEventListener('close',resetRestartDetails);el('restart-diagnostic-dialog').addEventListener('close',resetRestartDetails);el('add-count').oninput=updateResizeDialog;el('logs-bottom').onclick=scrollLogsToBottom;el('logs-reset').onclick=()=>{instanceLogId=null;el('logs-reset').hidden=true;refresh(true)};el('copy-logs').onclick=copyLogs;el('log-filter').onchange=()=>renderLogs(lastLogs);el('logs').onscroll=()=>{el('logs').dataset.follow=logsAreAtBottom()?'true':'false'};el('refresh-interval').onchange=()=>scheduleRefresh(0);el('instance-connections-close').onclick=closeInstanceConnections;el('instance-connections-dialog').addEventListener('close',resetInstanceConnectionsDialog);el('resize-cancel').onclick=()=>closeDialog('resize-dialog');el('resize-confirm').onclick=submitResize;el('dialog-cancel').onclick=()=>{currentAction=null;closeDialog('confirm-dialog')};el('dialog-confirm').onclick=submitAction;el('force-ack').onchange=()=>{if(currentAction&&currentAction.name==='force-reconnect')el('dialog-confirm').disabled=!el('force-ack').checked};scheduleNavigationFocus();scheduleRefresh(0);
</script></body></html>"""


def handle_management_request(client: socket.socket, lines: List[str], body: bytes = b"") -> bool:
    """处理管理页面/API；返回 True 时调用方不得继续作为 HTTP Proxy 转发。"""
    if not MANAGEMENT_UI_ENABLED:
        return False
    path = management_target(lines)
    if path is None:
        return False
    request = lines[0].split()
    method = request[0].upper()
    if path == MANAGEMENT_BASE_PATH:
        send_http_response(client, "302 Found", b"", extra_headers={"Location": MANAGEMENT_BASE_PATH + "/"})
        return True
    if method == "GET" and path == MANAGEMENT_BASE_PATH + "/":
        send_http_response(client, "200 OK", MANAGEMENT_PAGE.encode("utf-8"), "text/html; charset=utf-8")
        return True
    if method == "GET" and path == MANAGEMENT_BASE_PATH + "/api/v1/status":
        json_response(client, "200 OK", management_status_snapshot())
        return True
    restart_schedule_api_prefix = MANAGEMENT_BASE_PATH + "/api/v1/restart-schedule"
    if method == "GET" and path == restart_schedule_api_prefix + "/history":
        schedule = restart_schedule_snapshot()
        json_response(
            client,
            "200 OK",
            {
                "generated_at": int(time.time()),
                "history_limit": schedule["policy"]["history_limit"],
                "runs": schedule["history"],
            },
        )
        return True
    if method == "GET" and path.startswith(restart_schedule_api_prefix + "/runs/"):
        suffix = path[len(restart_schedule_api_prefix + "/runs/"):].strip("/")
        parts = suffix.split("/")
        if len(parts) == 3 and parts[1] == "queue" and parts[2] in {"ready", "deferred", "backend-retry"} and parts[0] == "current":
            queue = restart_schedule_queue_snapshot(parts[2])
            json_response(client, "200 OK", queue or {"message": "未知队列"})
            return True
        if len(parts) == 2 and parts[1] in {"failures", "skipped"}:
            records = restart_schedule_run_records(parts[0], parts[1])
            if records is None:
                json_response(client, "404 Not Found", {"message": "执行记录不存在或已过期"})
            else:
                json_response(
                    client,
                    "200 OK",
                    {
                        "run_id": parts[0],
                        "category": parts[1],
                        "generated_at": int(time.time()),
                        "records": records,
                    },
                )
            return True
    if method == "POST" and path == MANAGEMENT_BASE_PATH + "/api/v1/restart-schedule":
        try:
            payload = json.loads(body.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        action = str(payload.get("action", "")) if isinstance(payload, dict) else ""
        accepted, status_code, message, schedule = update_restart_schedule(action)
        if accepted:
            status = "202 Accepted" if status_code == 202 else "200 OK"
        elif status_code == 404:
            status = "404 Not Found"
        elif status_code == 409:
            status = "409 Conflict"
        else:
            status = "500 Internal Server Error"
        json_response(client, status, {"accepted": accepted, "message": message, "schedule": schedule})
        return True
    if method == "GET" and path == MANAGEMENT_BASE_PATH + "/api/v1/connections":
        json_response(client, "200 OK", {"generated_at": int(time.time()), "connections": active_connection_snapshot()})
        return True
    if method == "GET" and path == MANAGEMENT_BASE_PATH + "/api/v1/logs":
        json_response(client, "200 OK", {"generated_at": int(time.time()), "lines": management_logs()})
        return True
    instance_logs_prefix = MANAGEMENT_BASE_PATH + "/api/v1/instances/"
    if method == "GET" and path.startswith(instance_logs_prefix) and path.endswith("/logs"):
        instance_id_text = path[len(instance_logs_prefix):-len("/logs")].strip("/")
        if instance_id_text.isdigit() and int(instance_id_text) in runtime_instance_ids():
            json_response(
                client,
                "200 OK",
                {"generated_at": int(time.time()), "lines": management_instance_logs(int(instance_id_text))},
            )
        else:
            json_response(client, "404 Not Found", {"message": "实例不存在"})
        return True
    if method == "POST" and path == MANAGEMENT_BASE_PATH + "/api/v1/instances":
        try:
            payload = json.loads(body.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        action = payload.get("action") if isinstance(payload, dict) else None
        raw_ids = payload.get("ids", []) if isinstance(payload, dict) else []
        ids = [int(item) for item in raw_ids if str(item).isdigit()] if isinstance(raw_ids, list) else []
        count = payload.get("count", 1) if isinstance(payload, dict) else 1
        accepted, status_code, message, operation = launch_resize_action(str(action), ids, count)
        status = "202 Accepted" if accepted else ("400 Bad Request" if status_code == 400 else "409 Conflict" if status_code == 409 else "500 Internal Server Error" if status_code == 500 else "404 Not Found")
        json_response(client, status, {"accepted": accepted, "message": message, "operation": operation})
        return True
    prefix = MANAGEMENT_BASE_PATH + "/api/v1/instances/"
    if method == "POST" and path.startswith(prefix):
        parts = path[len(prefix):].split("/")
        if len(parts) == 2 and parts[0].isdigit() and parts[1] in {"enable", "disable", "reconnect", "force-reconnect"}:
            accepted, status_code, message, operation = launch_management_action(int(parts[0]), parts[1])
            json_response(client, "202 Accepted" if accepted else ("404 Not Found" if status_code == 404 else "409 Conflict" if status_code == 409 else "500 Internal Server Error"), {"accepted": accepted, "message": message, "operation": operation})
            return True
    json_response(client, "404 Not Found", {"message": "管理接口不存在"})
    return True


def handle_http(
    client: socket.socket, initial: bytes, client_ip: str, client_port: int
) -> None:
    upstream: Optional[socket.socket] = None
    backend: Optional[Tuple[str, int]] = None
    request_id: Optional[str] = None
    tracked = False
    try:
        lines, body = read_http_headers(client, initial)
        # 管理页面走同一端口的保留 origin-form 路径，必须在代理认证前匿名处理。
        if handle_management_request(client, lines, body):
            return
        if PROXY_MODE != "mixed":
            send_http_response(client, "400 Bad Request", "HTTP Proxy 模式未启用\n".encode("utf-8"))
            return
        username, authenticated = http_auth(lines)
        if not authenticated:
            client.sendall(
                b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                b"Proxy-Authenticate: Basic realm=MicroWARP\r\nContent-Length: 0\r\n\r\n"
            )
            return
        method, host, port, origin_target = http_target(lines)
        backend = pick_backend(client_ip, username)
        if not backend:
            client.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
            return
        track_backend(backend, 1)
        tracked = True
        upstream = connect_backend(backend)
        egress_family = socks_connect(upstream, host, port)

        if method == "CONNECT":
            request_id = next_access_id()
            register_connection(
                request_id,
                "HTTP CONNECT",
                client_ip,
                client_port,
                username,
                host,
                port,
                backend,
                egress_family,
            )
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            log_access(
                f"{access_prefix('HTTP CONNECT', client_ip, client_port, username, request_id)} | "
                f"{backend_access_fields(backend)} | 出口={egress_family} | 目标={safe_access_value(host, 1024)}:{port} | "
                f"{http_access_fields(lines)}"
            )
            relay(client, upstream, request_id)
            upstream = None
            return

        request_parts = lines[0].split()
        request_parts[1] = origin_target
        forwarded = [" ".join(request_parts)]
        for line in lines[1:]:
            lower = line.lower()
            if lower.startswith("proxy-authorization:") or lower.startswith("proxy-connection:"):
                continue
            forwarded.append(line)
        request_id = next_access_id()
        register_connection(
            request_id,
            f"HTTP {method}",
            client_ip,
            client_port,
            username,
            host,
            port,
            backend,
            egress_family,
        )
        forwarded_bytes = "\r\n".join(forwarded).encode("iso-8859-1") + b"\r\n\r\n" + body
        upstream.sendall(forwarded_bytes)
        update_connection_activity(request_id, True, len(forwarded_bytes))
        log_access(
            f"{access_prefix(f'HTTP {method}', client_ip, client_port, username, request_id)} | "
            f"{backend_access_fields(backend)} | 出口={egress_family} | 目标={safe_access_value(host, 1024)}:{port} | "
            f"{http_access_fields(lines)}"
        )
        relay(client, upstream, request_id)
        upstream = None
    except (ConnectionError, OSError, ValueError) as error:
        log(f"HTTP 请求失败 | 客户端={client_ip} | 错误={error}", "WARN")
        try:
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        except OSError:
            pass
    finally:
        unregister_connection(request_id)
        if tracked and backend:
            track_backend(backend, -1)
        close_quietly(upstream)


def handle_client(client: socket.socket, address: Tuple[str, int]) -> None:
    client_ip, client_port = address[0], address[1]
    try:
        client.settimeout(HANDSHAKE_TIMEOUT)
        initial = client.recv(1)
        if not initial:
            return
        if initial == b"\x05":
            handle_socks(client, initial, client_ip, client_port)
        elif PROXY_MODE == "mixed" or MANAGEMENT_UI_ENABLED:
            handle_http(client, initial, client_ip, client_port)
        else:
            log(f"拒绝非 SOCKS5 请求 | 客户端={client_ip}", "WARN")
    except Exception as error:
        log(f"客户端处理异常 | 客户端={client_ip} | 错误={error}", "WARN")
    finally:
        close_quietly(client)


def serve() -> None:
    if PROXY_MODE not in {"socks5", "mixed"}:
        raise SystemExit(f"未知 PROXY_MODE={PROXY_MODE!r}")
    load_backends(force=True)
    with _active_lock:
        write_connection_state()

    listener = socket.socket(socket.AF_INET6 if ":" in LISTEN_ADDR else socket.AF_INET, socket.SOCK_STREAM)
    if listener.family == socket.AF_INET6:
        try:
            listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((LISTEN_ADDR, LISTEN_PORT))
    listener.listen(min(MAX_CONN, 512))
    listener.settimeout(1.0)
    log(
        f"公开入口已监听 | 地址={LISTEN_ADDR}:{LISTEN_PORT} | 模式={PROXY_MODE} | "
        f"策略={STRATEGY} | 粘性={STICKY_MODE} | 固定认证={int(AUTH_REQUIRED)} | "
        f"用户名缺失=按策略 | 最大连接={MAX_CONN} | 访问日志={int(ACCESS_LOG)} | "
        f"HTTP头={int(ACCESS_LOG_HEADERS)} | 头最大字符={ACCESS_LOG_HEADER_MAX_CHARS} | "
        f"管理面板={int(MANAGEMENT_UI_ENABLED)}",
        "OK",
    )

    try:
        while True:
            load_backends()
            try:
                client, address = listener.accept()
            except socket.timeout:
                continue
            except OSError as error:
                if error.errno == errno.EINTR:
                    continue
                raise
            if not _connection_slots.acquire(blocking=False):
                close_quietly(client)
                continue
            try:
                client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                close_quietly(client)
                _connection_slots.release()
                continue

            def run(connection: socket.socket = client, peer: Tuple[str, int] = address) -> None:
                try:
                    handle_client(connection, peer)
                finally:
                    _connection_slots.release()

            threading.Thread(target=run, daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        close_quietly(listener)
        with _active_lock:
            _active_connections.clear()
            _active_connection_details.clear()
            write_connection_state()


if __name__ == "__main__":
    serve()
