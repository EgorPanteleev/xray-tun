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
echo "installed /usr/local/bin/{xray-tun,vless2xray}, /usr/local/lib/xray-tun/netctl.sh, unit"

if [ "$WITH_POLKIT" = 1 ]; then
    install -d -m 0755 /etc/polkit-1/rules.d
    install -m 0644 "$SRC/polkit/49-xray-tun.rules" /etc/polkit-1/rules.d/49-xray-tun.rules
    echo "installed polkit rule (wheel group may toggle without a password)"
fi

systemctl daemon-reload
echo
echo "done. next:"
echo "  xray-tun add home 'vless://...'  # add a server (repeat for more)"
echo "  xray-tun ls                      # list them"
echo "  xray-tun on                      # bring the tunnel up"
echo
echo "or edit the config by hand instead:  sudo xray-tun edit"
echo
echo "the service is NOT enabled at boot; 'xray-tun enable' does that."
