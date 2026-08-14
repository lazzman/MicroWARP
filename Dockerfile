# ==========================================
# Stage 1: Build patched microsocks (pure C SOCKS5)
# ==========================================
FROM alpine:3.21 AS microsocks-builder

RUN apk add --no-cache build-base git patch

# 固定源码版本，确保 RESOLVE_PREFERENCE 补丁可重复应用。
ARG MICROSOCKS_REF=69f004aeb7c4ed7da3bf538d60a2d705c5a618df
COPY patches/microsocks-resolve-preference.patch /tmp/microsocks-resolve-preference.patch
RUN git init /src \
    && cd /src \
    && git remote add origin https://github.com/rofl0r/microsocks.git \
    && git fetch --depth 1 origin "${MICROSOCKS_REF}" \
    && git checkout --detach FETCH_HEAD \
    && git apply /tmp/microsocks-resolve-preference.patch \
    && make

# ==========================================
# Stage 2: Fetch usque (MASQUE / CONNECT-IP client)
# ==========================================
FROM alpine:3.21 AS usque-downloader

RUN apk add --no-cache curl ca-certificates unzip \
    && update-ca-certificates

ARG USQUE_VERSION=4.2.1
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64|x86_64) arch=amd64 ;; \
        arm64|aarch64) arch=arm64 ;; \
        arm|arm/v7) arch=armv7 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}/usque_${USQUE_VERSION}_linux_${arch}.zip"; \
    echo "Downloading ${url}"; \
    curl -fsSL -o /tmp/usque.zip "${url}"; \
    unzip -q /tmp/usque.zip -d /tmp/usque-extract; \
    bin="$(find /tmp/usque-extract -type f -name 'usque' | head -n 1)"; \
    test -n "${bin}" && test -s "${bin}"; \
    install -m 755 "${bin}" /usr/local/bin/usque

# ==========================================
# Stage 3: Fetch hev-socks5-tunnel (optional upstream path)
# ==========================================
FROM alpine:3.21 AS hev-downloader

RUN apk add --no-cache curl ca-certificates \
    && update-ca-certificates

ARG HEV_VERSION=2.17.0
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64|x86_64) arch=x86_64 ;; \
        arm64|aarch64) arch=arm64 ;; \
        arm|arm/v7) arch=arm32v7 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_VERSION}/hev-socks5-tunnel-linux-${arch}"; \
    echo "Downloading ${url}"; \
    curl -fsSL -o /usr/local/bin/hev-socks5-tunnel "${url}"; \
    chmod 755 /usr/local/bin/hev-socks5-tunnel

# ==========================================
# Stage 4: Minimal runtime + optional control plane
# ==========================================
FROM alpine:3.21

# bash：实例控制与上游路由；python3：仅多实例/LB 时运行。
# tini 负责 PID 1 信号转发和子进程回收。
# /dev/net/tun 仅在配置 UPSTREAM_SOCKS5 时由运行容器挂载，默认轻量路径无需该设备。
RUN apk add --no-cache \
        bash \
        tini \
        python3 \
        wireguard-tools \
        iptables \
        iproute2 \
        curl \
        wget \
        ca-certificates \
        openresolv \
    && update-ca-certificates \
    && rm -rf /var/cache/apk/*

COPY --from=microsocks-builder /src/microsocks /usr/local/bin/microsocks
COPY --from=usque-downloader /usr/local/bin/usque /usr/local/bin/usque
COPY --from=hev-downloader /usr/local/bin/hev-socks5-tunnel /usr/local/bin/hev-socks5-tunnel

WORKDIR /app
COPY entrypoint.sh log-utils.sh netns-utils.sh lb-proxy.py health-check.sh rotate-restart.sh instance-ctl.sh management-control.sh upstream-setup.sh tcp-socks5-relay.py ./
RUN chmod +x entrypoint.sh log-utils.sh netns-utils.sh lb-proxy.py health-check.sh rotate-restart.sh instance-ctl.sh management-control.sh upstream-setup.sh tcp-socks5-relay.py \
    && mkdir -p /etc/wireguard /run/microwarp

EXPOSE 1080/tcp
# 唯一公开入口由 BIND_PORT 决定；Mixed/LB 不再拥有独立的 LB_PORT。
# WARP 身份配置在一个 volume 中：单实例兼容 wg0.conf，多实例保存在 instances/<id>/。
VOLUME ["/etc/wireguard"]

HEALTHCHECK --interval=30s --timeout=12s --start-period=90s --retries=3 \
    CMD ["/app/health-check.sh", "docker"]

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/entrypoint.sh"]
