# Security Policy

Please do not open a public issue for a vulnerability that could expose VPN
credentials, private keys, or root access. Use GitHub's private vulnerability
reporting feature for this repository.

The installer trusts:

1. this repository's `install.sh`;
2. GitHub HTTPS delivery;
3. TrustTunnel release binaries only after their upstream GPG signatures match
   the documented AdGuard signing-key fingerprint;
4. Let's Encrypt and Certbot for TLS certificate issuance and renewal.

No telemetry is added by this project.
