#!/usr/bin/env bash
# uninstall.sh -- remove the xray-tun daemon. Run with sudo. Keeps /etc/xray-tun.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

systemctl disable --now xray-tun.service 2>/dev/null
/usr/local/lib/xray-tun/netctl.sh down 2>/dev/null
rm -f /etc/systemd/system/xray-tun.service \
      /etc/systemd/system/xray-tun-resume.service \
      /etc/systemd/system-sleep/xray-tun \
      /etc/NetworkManager/conf.d/99-xray-tun-unmanaged.conf \
      /etc/NetworkManager/dispatcher.d/90-xray-tun \
      /usr/local/bin/xray-tun \
      /usr/local/bin/vless2xray \
      /usr/local/lib/xray-tun/netctl.sh \
      /etc/polkit-1/rules.d/49-xray-tun.rules
rmdir /usr/local/lib/xray-tun 2>/dev/null
systemctl daemon-reload
systemctl reload NetworkManager 2>/dev/null || true
echo "removed. config and saved servers left in /etc/xray-tun"
echo "(delete them by hand if you want: rm -rf /etc/xray-tun)"
