#!/usr/bin/env bash
# install.sh -- install the xray-tun daemon. Run with sudo.
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WITH_POLKIT=0
[ "${1:-}" = "--polkit" ] && WITH_POLKIT=1

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
command -v xray >/dev/null || { echo "xray not found in PATH" >&2; exit 1; }

install -d -m 0755 /etc/xray-tun /usr/local/lib/xray-tun
# 0700: profiles hold UUIDs and keys.
install -d -m 0700 /etc/xray-tun/servers

# Never clobber a config you have already edited.
for f in config.json xray-tun.conf; do
    if [ -e "/etc/xray-tun/$f" ]; then
        install -m 0600 "$SRC/etc/$f" "/etc/xray-tun/$f.new"
        echo "kept existing /etc/xray-tun/$f  (new version at $f.new)"
    else
        install -m 0600 "$SRC/etc/$f" "/etc/xray-tun/$f"
        echo "installed /etc/xray-tun/$f"
    fi
done

install -m 0755 "$SRC/lib/netctl.sh"  /usr/local/lib/xray-tun/netctl.sh
install -m 0755 "$SRC/bin/xray-tun"   /usr/local/bin/xray-tun
install -m 0755 "$SRC/bin/vless2xray" /usr/local/bin/vless2xray
install -m 0644 "$SRC/systemd/xray-tun.service" /etc/systemd/system/xray-tun.service
install -m 0644 "$SRC/systemd/xray-tun-resume.service" \
                /etc/systemd/system/xray-tun-resume.service

# Resume handling. Without this, waking up leaves the machine black-holed:
# the routing rules still send everything into the TUN while xray cannot
# reach the server yet, and NetworkManager has rewritten resolv.conf.
install -d -m 0755 /etc/systemd/system-sleep
install -m 0755 "$SRC/systemd/system-sleep-xray-tun" /etc/systemd/system-sleep/xray-tun

TUN_NAME=$(sed -n 's/^[[:space:]]*TUN_NAME=\([^[:space:]#]*\).*/\1/p' \
           /etc/xray-tun/xray-tun.conf 2>/dev/null | tail -1)
TUN_NAME=${TUN_NAME:-xtun0}

if [ -d /etc/NetworkManager ]; then
    install -d -m 0755 /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d
    if grep -rqs 'unmanaged-devices' /etc/NetworkManager/ \
         --exclude=99-xray-tun-unmanaged.conf; then
        echo "note: NetworkManager already sets unmanaged-devices somewhere;"
        echo "      not touching it. Add 'interface-name:$TUN_NAME' yourself so"
        echo "      NM stops managing the tunnel device."
    else
        sed "s/@TUN_NAME@/$TUN_NAME/" \
            "$SRC/networkmanager/99-xray-tun-unmanaged.conf.in" \
            > /etc/NetworkManager/conf.d/99-xray-tun-unmanaged.conf
        chmod 0644 /etc/NetworkManager/conf.d/99-xray-tun-unmanaged.conf
        echo "installed NM rule: $TUN_NAME is unmanaged"
    fi
    install -m 0755 "$SRC/networkmanager/90-xray-tun" \
                    /etc/NetworkManager/dispatcher.d/90-xray-tun
    echo "installed NM dispatcher hook (re-asserts DNS on network changes)"
fi
echo "installed /usr/local/bin/{xray-tun,vless2xray}, /usr/local/lib/xray-tun/netctl.sh, units"

if [ "$WITH_POLKIT" = 1 ]; then
    install -d -m 0755 /etc/polkit-1/rules.d
    install -m 0644 "$SRC/polkit/49-xray-tun.rules" /etc/polkit-1/rules.d/49-xray-tun.rules
    echo "installed polkit rule (wheel group may toggle without a password)"
fi

systemctl daemon-reload
systemctl reload NetworkManager 2>/dev/null || true
echo
echo "done. next:"
echo "  xray-tun add home 'vless://...'  # add a server (repeat for more)"
echo "  xray-tun ls                      # list them"
echo "  xray-tun on                      # bring the tunnel up"
echo
echo "or edit the config by hand instead:  sudo xray-tun edit"
echo
echo "the service is NOT enabled at boot; 'xray-tun enable' does that."
