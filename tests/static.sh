#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bash -n install.sh uninstall.sh scripts/ttctl
shellcheck install.sh uninstall.sh scripts/ttctl

./install.sh --help >/dev/null
./scripts/ttctl --help >/dev/null

expected_ttctl_hash="$(sed -nE 's/^readonly TTCTL_SHA256="([0-9a-f]{64})"$/\1/p' install.sh)"
actual_ttctl_hash="$(sha256sum scripts/ttctl | awk '{print $1}')"
[[ -n "$expected_ttctl_hash" ]]
[[ "$expected_ttctl_hash" == "$actual_ttctl_hash" ]]

grep -Fq 'gpg --batch --verify' install.sh
grep -Fq 'certbot certonly' install.sh
grep -Fq 'systemctl enable --now trusttunnel.service' install.sh
grep -Fq 'ss -H -lun' scripts/ttctl

printf 'static checks: OK\n'
