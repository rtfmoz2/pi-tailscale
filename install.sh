#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Install Tailscale on a Raspberry Pi (Raspberry Pi OS / Debian) and let SSH in
# over it, adding to whatever firewall the device already has.
#
#   sudo ./install.sh                  install (or update the add-on's files)
#   sudo ./install.sh --ports "22 80"  TCP ports to allow over Tailscale
#                                      (default: 22, plus 80 if star-lan-bridge's
#                                      admin page is installed)
#   sudo ./install.sh --auto-updates   also let unattended-upgrades update Tailscale
#   sudo ./install.sh --no-log-upload  stop tailscaled sending its logs to Tailscale
#
# Safe to run again. Nothing here logs the device in to Tailscale: run
# `sudo tailscale up` afterwards and open the link it prints.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

PORTS=""
AUTO_UPDATES=0
NO_LOG_UPLOAD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ports) PORTS="${2:?--ports needs a value, e.g. \"22 80\"}"; shift 2 ;;
        --auto-updates) AUTO_UPDATES=1; shift ;;
        --no-log-upload) NO_LOG_UPLOAD=1; shift ;;
        -h|--help) sed -n '3,16p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$PORTS" && ! "$PORTS" =~ ^[0-9]+([\ ,][0-9]+)*$ ]]; then
    echo "--ports: TCP port numbers separated by spaces, e.g. \"22 80\"" >&2
    exit 2
fi

has_unit() { systemctl cat "$1" >/dev/null 2>&1; }

echo "== Tailscale"
if command -v tailscale >/dev/null; then
    echo "already installed: $(tailscale version | head -1)"
else
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|raspbian) ;;
        *) echo "unsupported OS '${ID:-?}': install Tailscale yourself, then run this again" >&2; exit 1 ;;
    esac
    # Tailscale's own apt repository (https://pkgs.tailscale.com), signed.
    install -d -m 755 /usr/share/keyrings
    curl -fsSL "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/$ID/$VERSION_CODENAME.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale >/dev/null
    echo "installed: $(tailscale version | head -1)"
fi

echo "== Ports"
if [[ -n "$PORTS" || ! -f /etc/default/pi-tailscale ]]; then
    if [[ -z "$PORTS" ]]; then
        PORTS="22"
        has_unit star-admin.service && PORTS="22 80"
    fi
    PORTS="${PORTS//,/ }"
    cat > /etc/default/pi-tailscale <<EOF
# pi-tailscale: TCP ports allowed in over Tailscale (tailscale0 only).
# After changing this, run: sudo pi-tailscale-firewall apply
TCP_PORTS="$PORTS"
EOF
fi
# shellcheck disable=SC1091
. /etc/default/pi-tailscale
echo "TCP $TCP_PORTS over Tailscale (/etc/default/pi-tailscale)"

echo "== Firewall add-on"
install -m 755 "$DIR/sbin/pi-tailscale-firewall" /usr/local/sbin/pi-tailscale-firewall
install -m 644 "$DIR/systemd/pi-tailscale-firewall.service" \
    "$DIR/systemd/pi-tailscale-firewall-recheck.service" \
    "$DIR/systemd/pi-tailscale-firewall-recheck.timer" /etc/systemd/system/
install -d /etc/systemd/system/nftables.service.d
install -m 644 "$DIR/systemd/nftables-pi-tailscale.conf" \
    /etc/systemd/system/nftables.service.d/50-pi-tailscale.conf
systemctl daemon-reload
/usr/local/sbin/pi-tailscale-firewall setup
systemctl enable --quiet pi-tailscale-firewall.service pi-tailscale-firewall-recheck.timer
systemctl restart pi-tailscale-firewall.service
systemctl start pi-tailscale-firewall-recheck.timer
/usr/local/sbin/pi-tailscale-firewall status

# star-lan-bridge's admin page only accepts LAN addresses; add Tailscale's.
if has_unit star-admin.service && [[ " $TCP_PORTS " == *" 80 "* ]]; then
    echo "== star-lan-bridge admin page"
    install -d /etc/systemd/system/star-admin.service.d
    install -m 644 "$DIR/systemd/star-admin-tailscale.conf" \
        /etc/systemd/system/star-admin.service.d/50-tailscale.conf
    systemctl daemon-reload
    systemctl try-restart star-admin.service
    echo "admin page allowed from Tailscale addresses"
fi

if [[ $AUTO_UPDATES == 1 ]]; then
    echo "== Automatic Tailscale updates"
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
        cat > /etc/apt/apt.conf.d/53unattended-upgrades-tailscale <<'EOF'
// Installed by pi-tailscale: unattended-upgrades also updates Tailscale.
Unattended-Upgrade::Origins-Pattern {
        "origin=Tailscale,label=Tailscale";
};
EOF
        if ! apt-config dump | grep -q '^APT::Periodic::Unattended-Upgrade "1"'; then
            echo "note: unattended-upgrades is installed but not switched on, so this has no effect until it is"
        fi
        echo "Tailscale added to unattended-upgrades"
    else
        echo "unattended-upgrades isn't installed; nothing changed (update with: sudo apt upgrade)"
    fi
fi

if [[ $NO_LOG_UPLOAD == 1 ]]; then
    echo "== Log upload"
    if grep -q -- '--no-logs-no-support' /etc/default/tailscaled 2>/dev/null; then
        echo "already off"
    else
        sed -i 's/^FLAGS="\(.*\)"/FLAGS="\1 --no-logs-no-support"/; s/^FLAGS=" /FLAGS="/' /etc/default/tailscaled
        grep -q -- '--no-logs-no-support' /etc/default/tailscaled || echo 'FLAGS="--no-logs-no-support"' >> /etc/default/tailscaled
        echo "restarting tailscaled (Tailscale connections drop for a few seconds)"
        systemctl restart tailscaled
        echo "tailscaled no longer uploads logs (Tailscale support can't see them either)"
    fi
fi

echo
if tailscale status >/dev/null 2>&1; then
    echo "Tailscale is up: $(tailscale ip -4 2>/dev/null | head -1)"
else
    echo "Next: sudo tailscale up   (open the link it prints to add this device to your tailnet)"
fi
echo "Then, in the Tailscale admin console: turn off key expiry for this device, so it"
echo "doesn't drop off the tailnet after 180 days."
