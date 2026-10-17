# Security policy

## Reporting a vulnerability
Please do not open a public issue for security problems.

Report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (GitHub private vulnerability reporting). Include what you found, how to reproduce it, and what an attacker could do.

We aim to reply within 7 days. Libre is a small project, so fixes may take longer; we will keep you updated and credit you if you want.

## Scope
Of most interest: room encryption and key derivation, the signed Bluetooth hello and device identity, signed admin manifests and moderation, the browser gateway on the local network, and anything that could leak messages or let someone impersonate a device.

The README's Security section lists known limits (for example, browser joins are plain HTTP and off by default).

## Supported versions
Only the latest `main` is supported.
