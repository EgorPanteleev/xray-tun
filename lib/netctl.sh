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

# XRAY_TUN_CONF / XRAY_TUN_STATE / XRAY_TUN_RESOLV exist so the DNS handling
# can be exercised by the test suite against throwaway files, instead of being
# shipped unverified. Unset, they are the real thing.
CONF=${XRAY_TUN_CONF:-/etc/xray-tun/xray-tun.conf}

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

STATE_DIR=${XRAY_TUN_STATE:-/run/xray-tun}
RESOLV=${XRAY_TUN_RESOLV:-/etc/resolv.conf}
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
    snapshot_dns
    write_dns
}

snapshot_dns() {
    mkdir -p "$STATE_DIR"
    # Only snapshot what someone else wrote. Snapshotting our own file would
    # destroy the real original and leave nothing to restore.
    if [ -e "$RESOLV_BAK" ] || [ -e "$RESOLV_LINK" ]; then
        return 0
    fi
    if [ -L "$RESOLV" ]; then
        readlink "$RESOLV" > "$RESOLV_LINK"
    elif [ -e "$RESOLV" ]; then
        cp -a "$RESOLV" "$RESOLV_BAK"
    else
        : > "$RESOLV_LINK"   # nothing was there
    fi
}

write_dns() {
    {
        echo "# Written by xray-tun. Original saved under $STATE_DIR."
        local ns
        for ns in $DNS_SERVERS; do echo "nameserver $ns"; done
        echo "options edns0"
    } > "$RESOLV".xray-tun.tmp && mv -f "$RESOLV".xray-tun.tmp "$RESOLV"
}

ours() {
    head -1 "$RESOLV" 2>/dev/null | grep -q 'Written by xray-tun'
}

# Re-assert our resolver after something else rewrote /etc/resolv.conf.
#
# NetworkManager owns that file and rewrites it whenever a connection comes
# up -- which is exactly what happens on resume, and on every switch between
# wifi and tethering. Without this, the tunnel keeps running while DNS quietly
# points back at the LAN resolver.
#
# It also refreshes the saved original, so `down` restores the DNS of the
# network we are on NOW. The old behaviour snapshotted once and could put back
# a resolver from a network that is no longer in reach.
redns() {
    [ "$MANAGE_DNS" = 1 ] || return 0
    ip link show dev "$TUN_NAME" >/dev/null 2>&1 || return 0
    if ! ours; then
        mkdir -p "$STATE_DIR"
        rm -f "$RESOLV_BAK" "$RESOLV_LINK"
        if [ -L "$RESOLV" ]; then
            readlink "$RESOLV" > "$RESOLV_LINK"
        elif [ -e "$RESOLV" ]; then
            cp -a "$RESOLV" "$RESOLV_BAK"
        fi
        log "adopted the current resolv.conf as the saved original"
    fi
    write_dns
    log "re-asserted DNS ($DNS_SERVERS)"
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

has_phys_default() {
    # Our own default lives in table $RT_TABLE, never in main, so anything
    # here is the real link.
    ip route show table main default 2>/dev/null | grep -q default
}

# Rebuild the tunnel after the machine wakes up.
#
# xray does reconnect on its own, but that is not enough. For the first
# seconds after resume there is no route at all and every dial fails with
# ENETUNREACH, while the routing rules still send all traffic into the TUN --
# so the machine is black-holed, not merely offline. Meanwhile NetworkManager
# has rewritten resolv.conf for the connection it just brought up. Waiting for
# a real default route and then restarting puts all of it back deterministically
# instead of hoping the retry loop wins the race.
resume() {
    local i
    for i in $(seq 1 60); do
        has_phys_default && break
        sleep 0.5
    done
    if ! has_phys_default; then
        log "resume: no default route after 30s; restarting anyway"
    fi
    sleep 1                      # let DHCP and DNS settle
    log "resume: restarting the tunnel"
    systemctl restart xray-tun.service
}

case "${1:-}" in
    up)     up ;;
    down)   down ;;
    redns)  redns ;;
    resume) resume ;;
    *)      echo "usage: $0 {up|down|redns|resume}" >&2; exit 2 ;;
esac
