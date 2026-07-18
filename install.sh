#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly INSTALL_DIR="${TT_INSTALL_DIR:-/opt/trusttunnel}"
readonly SERVICE_FILE="/etc/systemd/system/trusttunnel.service"
readonly RAW_BASE="https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main"
readonly UPSTREAM_REPO="TrustTunnel/TrustTunnel"
readonly SIGNING_FINGERPRINT="28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6"
readonly TTCTL_SHA256="a7803acf4bc43ecbe5f105ccdb9015e1aa1011924a5f672a370daab26a49d782"

DOMAIN="${TT_DOMAIN:-}"
EMAIL="${TT_EMAIL:-}"
USERNAME="${TT_USERNAME:-vpnuser}"
PASSWORD="${TT_PASSWORD:-}"
DISPLAY_NAME="${TT_DISPLAY_NAME:-TrustTunnel VPN}"
PORT="${TT_PORT:-443}"
VERSION="${TT_VERSION:-}"
SKIP_DNS_CHECK="${TT_SKIP_DNS_CHECK:-0}"
SKIP_FIREWALL="${TT_SKIP_FIREWALL:-0}"
UPDATE_ONLY="${TT_UPDATE_ONLY:-0}"
FORCE_RECONFIGURE="${TT_FORCE_RECONFIGURE:-0}"
TEMP_DIR=""

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'printf "Error: installation failed near line %s.\n" "$LINENO" >&2' ERR

usage() {
  cat <<'EOF'
TrustTunnel one-click endpoint installer

Usage:
  sudo bash install.sh [options]

Options:
  --domain DOMAIN        Public DNS name pointing to this server
  --email EMAIL          Email for Let's Encrypt
  --user USER            Initial VPN username (default: vpnuser)
  --password PASSWORD    Initial password (generated when omitted)
  --port PORT            Endpoint TCP+UDP port (default: 443)
  --name NAME            Client display name
  --version VERSION      TrustTunnel release version (default: latest)
  --skip-dns-check       Do not verify that DOMAIN points to this server
  --no-firewall          Do not touch an already-active ufw/firewalld
  -h, --help             Show this help

Unattended example:
  curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh \
    | sudo env TT_DOMAIN=vpn.example.com TT_EMAIL=admin@example.com bash
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      --user) USERNAME="${2:-}"; shift 2 ;;
      --password) PASSWORD="${2:-}"; shift 2 ;;
      --port) PORT="${2:-}"; shift 2 ;;
      --name) DISPLAY_NAME="${2:-}"; shift 2 ;;
      --version) VERSION="${2:-}"; shift 2 ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --no-firewall) SKIP_FIREWALL=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

prompt_required() {
  local variable_name="$1" prompt="$2" value
  value="${!variable_name}"
  if [[ -z "$value" ]]; then
    [[ -r /dev/tty ]] || die "$variable_name is required in non-interactive mode"
    read -r -p "$prompt: " value </dev/tty
    printf -v "$variable_name" '%s' "$value"
  fi
}

validate_inputs() {
  [[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
    || die "invalid domain: $DOMAIN"
  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die "invalid email: $EMAIL"
  [[ "$USERNAME" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] \
    || die "username may contain only letters, digits, dot, underscore, @, and hyphen"
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 && "$PORT" -ne 80 ]] \
    || die "port must be an integer from 1 to 65535 except 80"
  [[ "$DISPLAY_NAME" != *$'\n'* && "$DISPLAY_NAME" != *$'\r'* ]] || die "display name must be one line"
  if [[ -n "$PASSWORD" ]]; then
    [[ ${#PASSWORD} -ge 16 && ${#PASSWORD} -le 128 ]] || die "password must be 16-128 characters"
    [[ "$PASSWORD" != *$'\n'* && "$PASSWORD" != *$'\r'* ]] || die "password must be one line"
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run the installer as root (use sudo)"
  [[ -d /run/systemd/system ]] || die "systemd is required"
}

install_dependencies() {
  command -v apt-get >/dev/null || die "this release supports Ubuntu/Debian with apt"
  export DEBIAN_FRONTEND=noninteractive
  log "Installing required packages"
  apt-get update -qq
  apt-get install -y -qq ca-certificates certbot curl gnupg iproute2 openssl python3 qrencode tar
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

latest_version() {
  curl -fsSL "https://api.github.com/repos/$UPSTREAM_REPO/releases/latest" \
    | python3 -c 'import json,sys; t=json.load(sys.stdin)["tag_name"]; print(t[1:] if t.startswith("v") else t)'
}

download_and_verify_release() {
  local arch archive url unpack_root actual_fingerprint
  arch="$(detect_arch)"
  if [[ -z "$VERSION" ]]; then
    VERSION="$(latest_version)"
  fi
  VERSION="${VERSION#v}"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid release version: $VERSION"

  TEMP_DIR="$(mktemp -d /tmp/trusttunnel-install.XXXXXX)"
  archive="$TEMP_DIR/trusttunnel.tar.gz"
  url="https://github.com/$UPSTREAM_REPO/releases/download/v$VERSION/trusttunnel-v$VERSION-linux-$arch.tar.gz"

  log "Downloading official TrustTunnel v$VERSION for $arch"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$archive"
  tar -tzf "$archive" >/dev/null
  if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    die "release archive contains an unsafe path"
  fi
  mkdir -p "$TEMP_DIR/unpack"
  tar -xzf "$archive" -C "$TEMP_DIR/unpack"
  unpack_root="$(find "$TEMP_DIR/unpack" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [[ -x "$unpack_root/trusttunnel_endpoint" && -x "$unpack_root/setup_wizard" ]] \
    || die "release archive is incomplete"
  [[ -f "$unpack_root/trusttunnel_endpoint.sig" && -f "$unpack_root/setup_wizard.sig" ]] \
    || die "release signatures are missing"

  log "Verifying the official AdGuard release signatures"
  export GNUPGHOME="$TEMP_DIR/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  if ! timeout 45 gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$SIGNING_FINGERPRINT"; then
    timeout 45 gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$SIGNING_FINGERPRINT"
  fi
  actual_fingerprint="$(gpg --batch --with-colons --fingerprint "$SIGNING_FINGERPRINT" | awk -F: '$1=="fpr" {print $10; exit}')"
  [[ "$actual_fingerprint" == "$SIGNING_FINGERPRINT" ]] || die "unexpected signing key fingerprint"
  gpg --batch --verify "$unpack_root/trusttunnel_endpoint.sig" "$unpack_root/trusttunnel_endpoint"
  gpg --batch --verify "$unpack_root/setup_wizard.sig" "$unpack_root/setup_wizard"
  RELEASE_ROOT="$unpack_root"
}

install_ttctl() {
  local source_file="$TEMP_DIR/ttctl"
  if [[ -n "${TT_TTCTL_LOCAL_SOURCE:-}" ]]; then
    cp -- "$TT_TTCTL_LOCAL_SOURCE" "$source_file"
  else
    curl --proto '=https' --tlsv1.2 -fsSL "$RAW_BASE/scripts/ttctl" -o "$source_file"
  fi
  printf '%s  %s\n' "$TTCTL_SHA256" "$source_file" | sha256sum -c - >/dev/null
  install -m 0755 "$source_file" /usr/local/sbin/ttctl
}

backup_existing() {
  local backup_dir timestamp archive
  backup_dir="/var/backups/trusttunnel"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$backup_dir/trusttunnel-$timestamp.tar.gz"
  mkdir -p "$backup_dir"
  chmod 0700 "$backup_dir"
  tar -czf "$archive" -C "$INSTALL_DIR" .
  chmod 0600 "$archive"
  printf 'Backup: %s\n' "$archive"
}

install_release_files() {
  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$RELEASE_ROOT/trusttunnel_endpoint" "$INSTALL_DIR/trusttunnel_endpoint.new"
  install -m 0755 "$RELEASE_ROOT/setup_wizard" "$INSTALL_DIR/setup_wizard.new"
  install -m 0644 "$RELEASE_ROOT/LICENSE" "$INSTALL_DIR/LICENSE.new"
  install -m 0644 "$RELEASE_ROOT/trusttunnel.service.template" "$INSTALL_DIR/trusttunnel.service.template.new"

  if [[ -x "$INSTALL_DIR/trusttunnel_endpoint" ]]; then
    cp -a "$INSTALL_DIR/trusttunnel_endpoint" "$INSTALL_DIR/trusttunnel_endpoint.previous"
    cp -a "$INSTALL_DIR/setup_wizard" "$INSTALL_DIR/setup_wizard.previous"
  fi
  mv -f "$INSTALL_DIR/trusttunnel_endpoint.new" "$INSTALL_DIR/trusttunnel_endpoint"
  mv -f "$INSTALL_DIR/setup_wizard.new" "$INSTALL_DIR/setup_wizard"
  mv -f "$INSTALL_DIR/LICENSE.new" "$INSTALL_DIR/LICENSE"
  mv -f "$INSTALL_DIR/trusttunnel.service.template.new" "$INSTALL_DIR/trusttunnel.service.template"
}

restore_previous_binaries() {
  if [[ -x "$INSTALL_DIR/trusttunnel_endpoint.previous" ]]; then
    warn "restoring the previous endpoint binary"
    mv -f "$INSTALL_DIR/trusttunnel_endpoint.previous" "$INSTALL_DIR/trusttunnel_endpoint"
    mv -f "$INSTALL_DIR/setup_wizard.previous" "$INSTALL_DIR/setup_wizard"
    systemctl start trusttunnel.service || true
  fi
}

remove_previous_binaries() {
  rm -f "$INSTALL_DIR/trusttunnel_endpoint.previous" "$INSTALL_DIR/setup_wizard.previous"
}

update_existing() {
  log "Existing installation found; preserving configuration and users"
  backup_existing
  download_and_verify_release
  systemctl stop trusttunnel.service
  install_release_files
  install_ttctl
  systemctl start trusttunnel.service
  if ! systemctl is-active --quiet trusttunnel.service; then
    restore_previous_binaries
    die "updated endpoint failed to start; previous binary restored"
  fi
  remove_previous_binaries
  log "TrustTunnel updated to v$VERSION"
  ttctl doctor
}

port_busy() {
  ss -H -ltn "sport = :$1" | grep -q . || ss -H -lun "sport = :$1" | grep -q .
}

check_ports() {
  if port_busy 80; then
    die "port 80 is busy; Let's Encrypt HTTP-01 needs it during setup and renewal"
  fi
  if port_busy "$PORT"; then
    die "port $PORT is already in use"
  fi
}

check_dns() {
  local public_ipv4 dns_ipv4
  [[ "$SKIP_DNS_CHECK" == 1 ]] && { warn "DNS ownership check skipped"; return; }
  public_ipv4="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
  [[ -n "$public_ipv4" ]] || die "could not determine this server's public IPv4; use --skip-dns-check only after manual verification"
  dns_ipv4="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)"
  [[ -n "$dns_ipv4" ]] || die "$DOMAIN has no visible A record"
  grep -Fxq "$public_ipv4" <<<"$dns_ipv4" \
    || die "$DOMAIN does not point to this server ($public_ipv4); current A records: $(tr '\n' ' ' <<<"$dns_ipv4")"
  printf 'DNS OK: %s -> %s\n' "$DOMAIN" "$public_ipv4"
}

configure_firewall() {
  [[ "$SKIP_FIREWALL" == 1 ]] && return
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "Adding TrustTunnel ports to active ufw"
    ufw allow 80/tcp
    ufw allow "$PORT/tcp"
    ufw allow "$PORT/udp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    log "Adding TrustTunnel ports to active firewalld"
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-port="$PORT/tcp"
    firewall-cmd --permanent --add-port="$PORT/udp"
    firewall-cmd --reload
  else
    warn "no active ufw/firewalld detected; also check your provider's cloud firewall"
  fi
}

issue_certificate() {
  log "Issuing a renewable Let's Encrypt certificate"
  certbot certonly --standalone --non-interactive --agree-tos \
    --email "$EMAIL" --preferred-challenges http --keep-until-expiring -d "$DOMAIN"
  [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || die "certificate issuance did not create fullchain.pem"
  [[ -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] || die "certificate issuance did not create privkey.pem"
}

write_credentials() {
  local credentials_file="$INSTALL_DIR/credentials.toml"
  cat >"$credentials_file" <<EOF
[[client]]
username = "$USERNAME"
password = "$PASSWORD"
EOF
  chmod 0600 "$credentials_file"
}

configure_endpoint() {
  log "Generating the endpoint configuration"
  cd "$INSTALL_DIR"
  ./setup_wizard -m non-interactive \
    -a "0.0.0.0:$PORT" \
    -c bootstrap:bootstrap-not-a-real-password \
    -n "$DOMAIN" \
    --lib-settings vpn.toml \
    --hosts-settings hosts.toml \
    --cert-type self-signed

  cat >hosts.toml <<EOF
[[main_hosts]]
hostname = "$DOMAIN"
cert_chain_path = "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
private_key_path = "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
EOF
  rm -rf -- "$INSTALL_DIR/certs"
  write_credentials
  chmod 0600 "$INSTALL_DIR"/*.toml
}

install_systemd_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TrustTunnel endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/trusttunnel_endpoint vpn.toml hosts.toml
Restart=on-failure
RestartSec=3s
LimitNOFILE=524288
TasksMax=infinity
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/trusttunnel-restart <<'EOF'
#!/usr/bin/env sh
systemctl try-restart trusttunnel.service
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/trusttunnel-restart

  systemctl daemon-reload
  systemctl enable --now trusttunnel.service
  systemctl enable --now certbot.timer 2>/dev/null || true
}

configure_network_tuning() {
  if modprobe tcp_bbr 2>/dev/null && sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
    cat >/etc/sysctl.d/99-trusttunnel.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
EOF
    sysctl --system >/dev/null
  else
    warn "BBR is not available on this kernel; continuing without it"
  fi
}

print_result() {
  local link
  link="$(ttctl link "$USERNAME")"
  cat <<EOF

============================================================
TrustTunnel is ready
============================================================
Server:   $DOMAIN:$PORT
User:     $USERNAME
Password: $PASSWORD

Client link:
$link

Show QR again:  sudo ttctl qr $USERNAME
Health check:   sudo ttctl doctor
Add a user:     sudo ttctl add-user NAME
Logs:           sudo ttctl logs
============================================================
EOF
  if command -v qrencode >/dev/null; then
    printf '%s' "$link" | qrencode -t ANSIUTF8 || true
  fi
}

fresh_install() {
  prompt_required DOMAIN "VPN domain (A record must point to this server)"
  prompt_required EMAIL "Email for Let's Encrypt"
  if [[ -z "$PASSWORD" ]]; then
    PASSWORD="$(openssl rand -hex 16)"
  fi
  validate_inputs
  check_ports
  check_dns
  configure_firewall
  download_and_verify_release
  install_release_files
  issue_certificate
  configure_endpoint
  install_ttctl
  configure_network_tuning
  install_systemd_service
  sleep 2
  if ! systemctl is-active --quiet trusttunnel.service; then
    journalctl -u trusttunnel.service -n 80 --no-pager >&2 || true
    die "TrustTunnel failed to start"
  fi
  ttctl doctor
  print_result
}

main() {
  parse_args "$@"
  require_root
  install_dependencies

  if [[ -f "$INSTALL_DIR/vpn.toml" && "$FORCE_RECONFIGURE" != 1 ]]; then
    update_existing
    return
  fi
  [[ "$UPDATE_ONLY" != 1 ]] || die "no existing installation found in $INSTALL_DIR"
  fresh_install
}

main "$@"
