#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bash -n install.sh install-client.sh uninstall.sh scripts/ttctl
shellcheck install.sh install-client.sh uninstall.sh scripts/ttctl

./install.sh --help >/dev/null
./install-client.sh --help >/dev/null
./scripts/ttctl --help >/dev/null

expected_ttctl_hash="$(sed -nE 's/^readonly TTCTL_SHA256="([0-9a-f]{64})"$/\1/p' install.sh)"
actual_ttctl_hash="$(sha256sum scripts/ttctl | awk '{print $1}')"
[[ -n "$expected_ttctl_hash" ]]
[[ "$expected_ttctl_hash" == "$actual_ttctl_hash" ]]

grep -Fq 'gpg --batch --verify' install.sh
grep -Fq 'certbot certonly' install.sh
grep -Fq 'systemctl enable --now trusttunnel.service' install.sh
grep -Fq 'ss -H -lun' scripts/ttctl
grep -Fq 'gpg --batch --verify' install-client.sh
grep -Fq 'IFS= read -r -s DEEPLINK </dev/tty' install-client.sh
grep -Fq 'SSH session detected' install-client.sh
grep -Fq 'systemctl disable "$SERVICE_NAME"' install-client.sh
grep -Fq 'install -m 0600 "$TEMP_DIR/client.toml" "$CONFIG_FILE"' install-client.sh
! grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' install-client.sh README.md README.ru.md

printf 'static checks: OK\n'
