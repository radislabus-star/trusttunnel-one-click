#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_DIR="${TT_INSTALL_DIR:-/opt/trusttunnel}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this script with sudo"
[[ -d "$INSTALL_DIR" ]] || die "TrustTunnel is not installed in $INSTALL_DIR"

if [[ "${TT_UNINSTALL_CONFIRM:-}" != "YES" ]]; then
  [[ -r /dev/tty ]] || die "set TT_UNINSTALL_CONFIRM=YES for non-interactive use"
  read -r -p "Disable TrustTunnel and archive its configuration? Type YES: " answer </dev/tty
  [[ "$answer" == "YES" ]] || die "cancelled"
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="/var/backups/trusttunnel"
backup="$backup_dir/uninstalled-$timestamp.tar.gz"
mkdir -p "$backup_dir"
chmod 0700 "$backup_dir"
tar -czf "$backup" -C "$INSTALL_DIR" .
chmod 0600 "$backup"

systemctl disable --now trusttunnel.service 2>/dev/null || true
rm -f /etc/systemd/system/trusttunnel.service
rm -f /etc/letsencrypt/renewal-hooks/deploy/trusttunnel-restart
rm -f /etc/sysctl.d/99-trusttunnel.conf
rm -f /usr/local/sbin/ttctl
systemctl daemon-reload
rm -rf -- "$INSTALL_DIR"

cat <<EOF
TrustTunnel was removed.
Configuration and credentials were archived with root-only permissions:
$backup

The Let's Encrypt certificate and firewall rules were intentionally kept.
EOF
