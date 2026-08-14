#!/usr/bin/env bash
# 多实例网络命名空间的 DNS 配置工具。
# ip netns exec 会将 /etc/netns/<名称>/resolv.conf 绑定到该命名空间进程的
# /etc/resolv.conf，从而避免 Docker 内置 DNS 127.0.0.11 仅存在于默认网络命名空间。

netns_write_resolv_conf() {
    local namespace="$1" root servers directory file temporary server count=0
    root="${NETNS_CONFIG_ROOT:-/etc/netns}"
    servers="${NETNS_DNS_SERVERS:-1.1.1.1,1.0.0.1}"
    directory="${root}/${namespace}"
    file="${directory}/resolv.conf"
    temporary="${file}.$$"

    mkdir -p "$directory" || return 1
    : > "$temporary" || return 1
    printf '%s\n' '# 由 MicroWARP 为此网络命名空间生成；请勿手工修改。' >> "$temporary"
    IFS=',' read -r -a netns_dns_server_list <<< "$servers"
    for server in "${netns_dns_server_list[@]}"; do
        server="${server//[[:space:]]/}"
        [ -n "$server" ] || continue
        printf 'nameserver %s\n' "$server" >> "$temporary"
        count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
        rm -f "$temporary"
        return 1
    fi
    mv "$temporary" "$file"
}

netns_remove_resolv_conf() {
    local namespace="$1" root directory
    root="${NETNS_CONFIG_ROOT:-/etc/netns}"
    directory="${root}/${namespace}"
    rm -f "${directory}/resolv.conf"
    rmdir "$directory" 2>/dev/null || true
}
