#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly INSTALL_DIR="${TT_CLIENT_INSTALL_DIR:-/opt/trusttunnel_client}"
readonly CONFIG_DIR="${TT_CLIENT_CONFIG_DIR:-/etc/trusttunnel-client}"
readonly CONFIG_FILE="$CONFIG_DIR/client.toml"
readonly SERVICE_NAME="trusttunnel-client.service"
readonly SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
readonly UPSTREAM_REPO="TrustTunnel/TrustTunnelClient"
readonly SIGNING_FINGERPRINT="28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6"

DEEPLINK="${TT_DEEPLINK:-}"
VERSION="${TT_CLIENT_VERSION:-}"
START_MODE="${TT_CLIENT_START:-auto}"
TEMP_DIR=""
RELEASE_ROOT=""

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

cleanup() {
  DEEPLINK=""
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'printf "Error: client installation failed near line %s.\n" "$LINENO" >&2' ERR

usage() {
  cat <<'EOF'
TrustTunnel Linux client installer

Usage:
  sudo bash install-client.sh [options]

Options:
  --version VERSION   TrustTunnelClient release (default: latest)
  --no-start          Install and configure without starting the VPN
  -h, --help          Show this help

The installer asks for a private tt:// link using hidden input. Do not put the
link on the command line or in shell history.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) VERSION="${2:-}"; shift 2 ;;
      --no-start) START_MODE="no"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run the installer as root (use sudo)"
  [[ -d /run/systemd/system ]] || die "systemd is required"
}

read_deeplink() {
  if [[ -z "$DEEPLINK" ]]; then
    [[ -r /dev/tty ]] || die "a private tt:// link is required"
    printf 'Paste the private tt:// link (input is hidden): ' >/dev/tty
    IFS= read -r -s DEEPLINK </dev/tty
    printf '\n' >/dev/tty
  fi
  [[ "$DEEPLINK" == tt://\?* ]] || die "the value is not a TrustTunnel tt:// link"
  [[ "$DEEPLINK" != *$'\n'* && "$DEEPLINK" != *$'\r'* ]] || die "the tt:// link must be one line"
}

install_dependencies() {
  command -v apt-get >/dev/null || die "this release supports Ubuntu/Debian with apt"
  export DEBIAN_FRONTEND=noninteractive
  log "Installing required packages"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg iproute2 python3 tar
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

latest_version() {
  curl --proto '=https' --tlsv1.2 -fsSL "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" \
    | python3 -c 'import json,sys; t=json.load(sys.stdin)["tag_name"]; print(t[1:] if t.startswith("v") else t)'
}

download_and_verify_release() {
  local arch archive url unpack_root actual_fingerprint
  arch="$(detect_arch)"
  if [[ -z "$VERSION" ]]; then VERSION="$(latest_version)"; fi
  VERSION="${VERSION#v}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid release version: $VERSION"

  TEMP_DIR="$(mktemp -d /tmp/trusttunnel-client-install.XXXXXX)"
  archive="$TEMP_DIR/client.tar.gz"
  url="https://github.com/$UPSTREAM_REPO/releases/download/v$VERSION/trusttunnel_client-v$VERSION-linux-$arch.tar.gz"
  log "Downloading official TrustTunnelClient v$VERSION for $arch"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$archive"
  tar -tzf "$archive" >/dev/null
  if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    die "release archive contains an unsafe path"
  fi
  mkdir -p "$TEMP_DIR/unpack"
  tar -xzf "$archive" -C "$TEMP_DIR/unpack"
  unpack_root="$(find "$TEMP_DIR/unpack" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -x "$unpack_root/trusttunnel_client" && -x "$unpack_root/setup_wizard" ]] || die "release archive is incomplete"
  [[ -f "$unpack_root/trusttunnel_client.sig" && -f "$unpack_root/setup_wizard.sig" ]] || die "release signatures are missing"

  log "Verifying the official AdGuard release signatures"
  export GNUPGHOME="$TEMP_DIR/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  if ! timeout 45 gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$SIGNING_FINGERPRINT"; then
    timeout 45 gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$SIGNING_FINGERPRINT"
  fi
  actual_fingerprint="$(gpg --batch --with-colons --fingerprint "$SIGNING_FINGERPRINT" | awk -F: '$1=="fpr" {print $10; exit}')"
  [[ "$actual_fingerprint" == "$SIGNING_FINGERPRINT" ]] || die "unexpected signing key fingerprint"
  gpg --batch --verify "$unpack_root/trusttunnel_client.sig" "$unpack_root/trusttunnel_client"
  gpg --batch --verify "$unpack_root/setup_wizard.sig" "$unpack_root/setup_wizard"
  RELEASE_ROOT="$unpack_root"
}

backup_existing() {
  local backup_dir
  [[ -e "$CONFIG_FILE" || -e "$SERVICE_FILE" ]] || return 0
  backup_dir="/var/backups/trusttunnel-client/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  chmod 0700 "$backup_dir"
  [[ ! -f "$CONFIG_FILE" ]] || install -m 0600 "$CONFIG_FILE" "$backup_dir/client.toml"
  [[ ! -f "$SERVICE_FILE" ]] || install -m 0600 "$SERVICE_FILE" "$backup_dir/trusttunnel-client.service"
  printf 'Backup: %s\n' "$backup_dir"
}

generate_config() {
  local generated="$TEMP_DIR/client.toml"
  log "Creating the private client configuration"
  if ! "$RELEASE_ROOT/setup_wizard" -m non-interactive -d "$DEEPLINK" --settings "$generated" >"$TEMP_DIR/setup-wizard.log" 2>&1; then
    die "the official setup wizard rejected the tt:// link"
  fi
  [[ -s "$generated" ]] || die "the setup wizard did not create a configuration"
  grep -Eq '^\[endpoint\]$' "$generated" || die "generated configuration has no endpoint"
  grep -Eq '^password[[:space:]]*=' "$generated" || die "generated configuration has no credentials"
}

install_files() {
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
  chmod 0700 "$CONFIG_DIR"
  install -m 0755 "$RELEASE_ROOT/trusttunnel_client" "$INSTALL_DIR/trusttunnel_client"
  install -m 0755 "$RELEASE_ROOT/setup_wizard" "$INSTALL_DIR/setup_wizard"
  install -m 0644 "$RELEASE_ROOT/LICENSE" "$INSTALL_DIR/LICENSE"
  install -m 0600 "$TEMP_DIR/client.toml" "$CONFIG_FILE"

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TrustTunnel VPN Client
Documentation=https://github.com/TrustTunnel/TrustTunnelClient
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/trusttunnel_client --config $CONFIG_FILE
Restart=on-failure
RestartSec=5s
User=root
Group=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
}

start_client() {
  if [[ "$START_MODE" == "no" ]]; then
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    warn "VPN was installed but not started (--no-start)."
    return 0
  fi
  if [[ "$START_MODE" == "auto" && -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    warn "SSH session detected; the VPN was not auto-started to protect remote access."
    printf 'Start it from a local console: sudo systemctl start %s\n' "$SERVICE_NAME"
    return 0
  fi
  log "Starting TrustTunnel client"
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  sleep 3
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
    die "TrustTunnel client failed to start"
  fi
  printf 'VPN service: active\n'
}

main() {
  parse_args "$@"
  require_root
  read_deeplink
  install_dependencies
  download_and_verify_release
  generate_config
  backup_existing
  install_files
  start_client
  DEEPLINK=""
  log "TrustTunnelClient v$VERSION is installed"
  cat <<EOF
Status:     sudo systemctl status $SERVICE_NAME
Logs:       sudo journalctl -u $SERVICE_NAME -f
Connect:    sudo systemctl start $SERVICE_NAME
Disconnect: sudo systemctl stop $SERVICE_NAME
EOF
}

main "$@"
