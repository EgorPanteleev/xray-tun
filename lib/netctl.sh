#!/usr/bin/env bash
# netctl.sh {up|down} -- network plumbing for the xray-tun daemon.
#
# xray creates the TUN device itself, but it does NOT address it or touch
# routing. This script does that half:
#
#   * address + link up on the TUN device
#   * a default route into it, parked in its own routing table
#   * an ip rule sending everything EXCEPT xray's own fwmarked sockets to
#     that table (this is what prevents the server connection from looping
#     back into the tunnel it is carrying)
#   * higher-priority rules keeping LAN/loopback/multicast on the main table
#   * optional /etc/resolv.conf takeover
#
# "down" reverses all of it and is safe to run repeatedly, including after a
# half-finished "up".

set -uo pipefail

CONF=/etc/xray-tun/xray-tun.conf

TUN_NAME=xtun0
TUN_MTU=1500
TUN_ADDR4=198.18.0.1/30
TUN_ADDR6=fd00:198:18::1/126
FWMARK=255
RT_TABLE=8888
PREF_MARK=7080
PREF_BYPASS=7090
PREF_MAIN=7100
IPV6_MODE=block
MANAGE_DNS=1
DNS_SERVERS="1.1.1.1 8.8.8.8"
BYPASS4="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10 224.0.0.0/4 240.0.0.0/4"
BYPASS6="::1/128 fe80::/10 fc00::/7 ff00::/8"

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

STATE_DIR=/run/xray-tun
RESOLV=/etc/resolv.conf
RESOLV_BAK="$STATE_DIR/resolv.conf.bak"
RESOLV_LINK="$STATE_DIR/resolv.conf.link"

log() { printf 'xray-tun/netctl: %s\n' "$*" >&2; }

# Delete every rule sitting at a priority, however many there are.
flush_pref() {
    local fam=$1 pref=$2 i
    for i in $(seq 1 16); do
        ip "$fam" rule del pref "$pref" 2>/dev/null || break
    done
}

wait_for_device() {
    local i
    for i in $(seq 1 100); do
        ip link show dev "$TUN_NAME" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

up() {
    if ! wait_for_device; then
        log "timed out waiting for $TUN_NAME to appear (is xray running?)"
        return 1
    fi

    ip link set dev "$TUN_NAME" mtu "$TUN_MTU"          || return 1
    ip addr replace "$TUN_ADDR4" dev "$TUN_NAME"        || return 1
    ip link set dev "$TUN_NAME" up                      || return 1

    # Start from a clean slate in case a previous run died mid-way.
    flush_pref -4 "$PREF_MARK"
    flush_pref -4 "$PREF_BYPASS"
    flush_pref -4 "$PREF_MAIN"
    ip route flush table "$RT_TABLE" 2>/dev/null

    ip route replace default dev "$TUN_NAME" table "$RT_TABLE" || return 1

    # Send xray's own sockets to main EXPLICITLY, at the highest priority we
    # use. Relying on them falling through past PREF_MAIN is not enough: any
    # other VPN client with a catch-all rule of its own (sing-box installs
    # "from all lookup <table>" around pref 9001) would swallow them first and
    # our server connection would end up inside someone else's tunnel.
    ip rule add fwmark "$FWMARK" lookup main pref "$PREF_MARK" || return 1

    local net
    for net in $BYPASS4; do
        ip rule add to "$net" lookup main pref "$PREF_BYPASS" || return 1
    done
    ip rule add not fwmark "$FWMARK" lookup "$RT_TABLE" pref "$PREF_MAIN" || return 1

    # ---- IPv6 ----
    flush_pref -6 "$PREF_MARK"
    flush_pref -6 "$PREF_BYPASS"
    flush_pref -6 "$PREF_MAIN"
    ip -6 route flush table "$RT_TABLE" 2>/dev/null

    case "$IPV6_MODE" in
        tunnel)
            ip -6 addr replace "$TUN_ADDR6" dev "$TUN_NAME" 2>/dev/null
            ip -6 route replace default dev "$TUN_NAME" table "$RT_TABLE" 2>/dev/null
            ;;
        block)
            ip -6 route replace blackhole default table "$RT_TABLE" 2>/dev/null
            ;;
        leave)
            log "IPV6_MODE=leave -- IPv6 traffic is NOT tunnelled"
            ;;
        *)
            log "unknown IPV6_MODE='$IPV6_MODE', treating as block"
            ip -6 route replace blackhole default table "$RT_TABLE" 2>/dev/null
            ;;
    esac

    if [ "$IPV6_MODE" != leave ]; then
        ip -6 rule add fwmark "$FWMARK" lookup main pref "$PREF_MARK" 2>/dev/null
        for net in $BYPASS6; do
            ip -6 rule add to "$net" lookup main pref "$PREF_BYPASS" 2>/dev/null
        done
        ip -6 rule add not fwmark "$FWMARK" lookup "$RT_TABLE" pref "$PREF_MAIN" 2>/dev/null
    fi

    take_dns
    log "up: $TUN_NAME $TUN_ADDR4, table $RT_TABLE, fwmark $FWMARK, ipv6=$IPV6_MODE"
    return 0
}

take_dns() {
    [ "$MANAGE_DNS" = 1 ] || return 0
    mkdir -p "$STATE_DIR"
    # Only snapshot once; a restart must not overwrite the real backup with
    # our own generated file.
    if [ ! -e "$RESOLV_BAK" ] && [ ! -e "$RESOLV_LINK" ]; then
        if [ -L "$RESOLV" ]; then
            readlink "$RESOLV" > "$RESOLV_LINK"
        elif [ -e "$RESOLV" ]; then
            cp -a "$RESOLV" "$RESOLV_BAK"
        else
            : > "$RESOLV_LINK"   # nothing was there
        fi
    fi
    {
        echo "# Written by xray-tun. Original saved under $STATE_DIR."
        local ns
        for ns in $DNS_SERVERS; do echo "nameserver $ns"; done
        echo "options edns0"
    } > "$RESOLV".xray-tun.tmp && mv -f "$RESOLV".xray-tun.tmp "$RESOLV"
}

restore_dns() {
    [ -d "$STATE_DIR" ] || return 0
    if [ -e "$RESOLV_LINK" ]; then
        local target
        target=$(cat "$RESOLV_LINK")
        rm -f "$RESOLV"
        [ -n "$target" ] && ln -s "$target" "$RESOLV"
        rm -f "$RESOLV_LINK"
    elif [ -e "$RESOLV_BAK" ]; then
        cp -a "$RESOLV_BAK" "$RESOLV" && rm -f "$RESOLV_BAK"
    fi
}

down() {
    flush_pref -4 "$PREF_MARK"
    flush_pref -4 "$PREF_BYPASS"
    flush_pref -4 "$PREF_MAIN"
    flush_pref -6 "$PREF_MARK"
    flush_pref -6 "$PREF_BYPASS"
    flush_pref -6 "$PREF_MAIN"

    ip route flush table "$RT_TABLE" 2>/dev/null
    ip -6 route flush table "$RT_TABLE" 2>/dev/null

    # xray removes the device when it exits; clean up if it crashed instead.
    ip link del dev "$TUN_NAME" 2>/dev/null

    restore_dns
    log "down: routing restored"
    return 0
}

case "${1:-}" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: $0 {up|down}" >&2; exit 2 ;;
esac
