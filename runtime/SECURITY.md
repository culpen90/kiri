# Security

Stowlark runs a virtual machine, containers that can be privileged, and a local
certificate authority on your computer (macOS, Windows or Linux), so security
reports matter a lot.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use the repository's
Security tab to report it privately if GitHub offers that option. For a
vulnerability in upstream Kiri, see [Kiri's security
policy](https://github.com/libracoder/kiri/security/policy).

Include what you found, how to reproduce it, and the Stowlark version
(Stowlark → About in the app).

## Supported versions

Check the [Stowlark releases](https://github.com/stowlark/stowlark/releases)
and confirm the issue on the latest available version before reporting.

## In scope

- Escaping a container or the VM to the host (the Mac, Windows or the Linux
  machine).
- The daemon socket, the HTTP/HTTPS router, DNS, and the certificate
  authority (it is limited to `stowlark.local` and `stowlark.localhost` names).
- The installer, `stowlark setup` and auto-update.
- The Android launcher and guest runner, including unexpected host file or
  network exposure in the supported configuration. The Android backend uses
  QEMU TCG, which [does not promise isolation from hostile guests](https://www.qemu.org/docs/master/system/security.html#non-virtualization-use-case).
  See [the Android trust model](docs/android.md#trust-model).
