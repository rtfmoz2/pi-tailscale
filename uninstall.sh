#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Undo install.sh.
#
#   sudo ./uninstall.sh                     remove the firewall add-on and its
#                                           settings; Tailscale stays installed
#   sudo ./uninstall.sh --remove-tailscale  also log out and remove Tailscale
#
# Every firewall rule and file the add-on made is removed; nothing else in the
# firewall is touched.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

REMOVE_TAILSCALE=0
case "${1:-}" in
    "") ;;
    --remove-tailscale) REMOVE_TAILSCALE=1 ;;
    -h|--help) sed -n '3,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

echo "== Firewall add-on"
systemctl disable --now --quiet pi-tailscale-firewall-recheck.timer 2>/dev/null || true
systemctl disable --now --quiet pi-tailscale-firewall.service 2>/dev/null || true
if [[ -x /usr/local/sbin/pi-tailscale-firewall ]]; then
    /usr/local/sbin/pi-tailscale-firewall uninstall
fi
rm -f /usr/local/sbin/pi-tailscale-firewall \
    /etc/systemd/system/pi-tailscale-firewall.service \
    /etc/systemd/system/pi-tailscale-firewall-recheck.service \
    /etc/systemd/system/pi-tailscale-firewall-recheck.timer \
    /etc/systemd/system/nftables.service.d/50-pi-tailscale.conf \
    /etc/default/pi-tailscale \
    /etc/apt/apt.conf.d/53unattended-upgrades-tailscale
rmdir /etc/systemd/system/nftables.service.d 2>/dev/null || true

if [[ -f /etc/systemd/system/star-admin.service.d/50-tailscale.conf ]]; then
    echo "== star-lan-bridge admin page: LAN only again"
    rm -f /etc/systemd/system/star-admin.service.d/50-tailscale.conf
    rmdir /etc/systemd/system/star-admin.service.d 2>/dev/null || true
    systemctl daemon-reload
    systemctl try-restart star-admin.service
fi
systemctl daemon-reload

if [[ $REMOVE_TAILSCALE == 1 ]] && command -v tailscale >/dev/null; then
    echo "== Tailscale"
    tailscale logout 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq tailscale >/dev/null
    rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
    rm -rf /var/lib/tailscale
    echo "removed; also delete the device in the Tailscale admin console"
fi
echo "done"
