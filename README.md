# TrustTunnel One-Click

[Русская версия](README.ru.md)

Deploy an official [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel)
endpoint on a clean Ubuntu or Debian VPS with one command.

The installer does not contain a custom VPN implementation. It downloads the
official TrustTunnel release, verifies both binaries with the official AdGuard
GPG signing key, configures TLS and systemd, and prints a ready-to-import
`tt://` link and QR code.

## One command

Point a DNS `A` record such as `vpn.example.com` to the VPS, allow inbound
`22/tcp`, `80/tcp`, `443/tcp`, and `443/udp` in the provider firewall, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh | sudo bash
```

The script asks only for the domain and Let's Encrypt email. It generates a
strong VPN password automatically.

Fully unattended:

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh \
  | sudo env TT_DOMAIN=vpn.example.com TT_EMAIL=admin@example.com bash
```

Review before running:

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

## What it configures

- official signed TrustTunnel endpoint for `x86_64` or `aarch64`;
- HTTP/1.1, HTTP/2, and HTTP/3/QUIC on one port;
- renewable Let's Encrypt certificate through Certbot;
- automatic endpoint restart after certificate renewal;
- systemd startup and restart policy;
- BBR/FQ when supported by the kernel;
- additions to an already-active `ufw` or `firewalld` without enabling a new
  firewall or changing SSH rules;
- `ttctl` for users, links, QR codes, health checks, logs, and updates.

## Requirements

- clean Ubuntu 22.04/24.04 or Debian 12 VPS;
- root or `sudo` access;
- systemd and `apt`;
- public IPv4 address;
- DNS `A` record pointing directly to the VPS, without a CDN proxy;
- free `80/tcp` for Let's Encrypt and free `443/tcp+udp` for TrustTunnel.

Port 80 must remain reachable for automatic certificate renewal. If the VPS
provider has a separate cloud firewall, open the ports there as well.

## Daily commands

```bash
sudo ttctl doctor
sudo ttctl status
sudo ttctl users
sudo ttctl add-user alice
sudo ttctl qr alice
sudo ttctl remove-user alice
sudo ttctl logs
sudo ttctl update
```

`ttctl users` never prints passwords. A secret is displayed only when a new
user is created or when `link`/`qr` is explicitly requested.

## Update and rollback

Running the one-command installer again detects the existing installation,
creates a root-only backup under `/var/backups/trusttunnel`, verifies the new
official binaries, and preserves the domain, certificate, users, and settings.
If the updated endpoint does not start, the previous binary is restored.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/radislabus-star/trusttunnel-one-click/main/uninstall.sh | sudo bash
```

Uninstalling disables the service and archives its configuration. It keeps the
Let's Encrypt certificate and firewall rules so an accidental uninstall does
not silently affect other services.

## Security model

- Release binaries are accepted only after detached GPG signature verification
  against fingerprint `28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6`, documented
  by the upstream project.
- The `ttctl` helper is downloaded from an immutable versioned release asset
  and accepted only when its SHA-256 matches the installer.
- The generated password is not passed to the upstream setup wizard on its
  command line.
- Credentials and backups are root-readable only.
- Metrics and an admin panel are not exposed.
- Private networks behind the endpoint are not made reachable by clients.
- The repository contains no server addresses, domains, credentials,
  certificates, or configuration copied from a real deployment.

Always inspect scripts before giving them root access. The short command is a
convenience, not a substitute for review.

## Upstream

- [TrustTunnel endpoint](https://github.com/TrustTunnel/TrustTunnel)
- [TrustTunnel clients](https://github.com/TrustTunnel/TrustTunnelClient)
- [Release verification](https://github.com/TrustTunnel/TrustTunnel/blob/master/VERIFY_RELEASES.md)
- [Configuration reference](https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md)

This helper is an independent community project and is not affiliated with or
endorsed by TrustTunnel or AdGuard.

## License

Apache-2.0.
