<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/logo/stowlark-horizontal-dark.svg">
    <img src="brand/logo/stowlark-horizontal-light.svg" alt="Stowlark" width="280">
  </picture>
</p>

<p align="center">
  <b>A tiny, fast container runtime for macOS, Windows and Linux.</b><br>
  Runs your Docker images and works with the <code>docker</code> CLI, Compose and buildx you already use.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="docs/features.md">Features</a> ·
  <a href="docs/android.md">Android workspaces</a> ·
  <a href="../README.md">AnythingLLM Mobile</a> ·
  <a href="docs/development.md">Build from source</a> ·
  <a href="https://github.com/stowlark/stowlark/releases">Releases</a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-555"></a>
  <a href="#in-your-language"><img alt="38 languages" src="https://img.shields.io/badge/languages-38-2ea043"></a>
</p>

<p align="center">
  🇬🇧 🇮🇩 🇩🇪 🇪🇸 🇫🇷 🇮🇹 🇵🇱 🇧🇷 🇻🇳 🇹🇷 🇷🇺 🇸🇦 🇯🇵 🇰🇷 🇨🇳 🇹🇼<br>
  <sub>Stowlark speaks 38 languages. <a href="#in-your-language">Is yours one?</a></sub>
</p>

---

Stowlark is a lightweight container runtime written in Rust and forked from
[Kiri](https://github.com/libracoder/kiri). On desktop it speaks the Docker
Engine API and runs containers in a small Linux VM, or directly on the host
kernel on Linux. On Android it runs local, offline Linux workspaces in Termux.

[AnythingLLM Mobile](../README.md) uses Stowlark to run reviewed shell and
Python scripts in a temporary Linux workspace on ARM64 Android. See the
[chat app setup guide](../docs/stowlark-android.md).

## Why Stowlark

- **Fast**: the guest starts containers directly in Linux namespaces.
- **Light**: the VM sleeps after 60 seconds idle.
- **Compatible**: `docker`, Compose, buildx, `docker login` and amd64 images through Rosetta.
- **Local domains**: `http://<name>.stowlark.local`, with HTTPS from Stowlark's own certificate authority.
- **More than containers**: a one-command Kubernetes cluster and Linux machines.
- **A native window** for containers, images, volumes and networks, plus a menu bar item.
- **Android workspaces**: run shell and Python scripts in an ARM64 Linux VM from Termux, without root.
- **In your language**: 38 languages, on macOS, Windows and Linux alike.

### In your language

Stowlark's window and setup come in these languages. It follows your system's language, and you can change it in Settings → Appearance. In Arabic, Persian and Central Kurdish the whole window reads right to left.

| | Language | | Language | | Language | | Language |
|---|---|---|---|---|---|---|---|
| 🇬🇧 | English | 🇳🇴 | Norsk bokmål | 🇧🇬 | Български | 🇮🇳 | తెలుగు |
| 🇮🇩 | Bahasa Indonesia | 🇵🇱 | Polski | 🇷🇺 | Русский | 🇹🇭 | ไทย |
| 🇦🇩 | Català | 🇧🇷 | Português (Brasil) | 🇺🇦 | Українська | 🇱🇦 | ລາວ |
| 🇨🇿 | Čeština | 🇷🇴 | Română | 🇰🇿 | Қазақша | 🇯🇵 | 日本語 |
| 🇩🇪 | Deutsch | 🇦🇱 | Shqip | 🇸🇦 | العربية | 🇰🇷 | 한국어 |
| 🇪🇸 | Español | 🇸🇮 | Slovenščina | 🇮🇷 | فارسی | 🇨🇳 | 简体中文 |
| 🇫🇷 | Français | 🇫🇮 | Suomi | 🇮🇶 | کوردیی ناوەندی | 🇹🇼 | 繁體中文 |
| 🇮🇹 | Italiano | 🇻🇳 | Tiếng Việt | 🇮🇳 | हिन्दी | 🇪🇹 | አማርኛ |
| 🇱🇹 | Lietuvių | 🇹🇷 | Türkçe | 🇧🇩 | বাংলা |  |  |
| 🇭🇺 | Magyar | 🇬🇷 | Ελληνικά | 🇮🇳 | தமிழ் |  |  |

Missing yours? Translations live in [`crates/kiri/src/ui/lang`](crates/kiri/src/ui/lang); see [Contributing](#contributing).

## Install

See [GitHub Releases](https://github.com/stowlark/stowlark/releases) for
published builds, or use the source build instructions below.

| Platform | Build |
|----------|--------|
| macOS 14+ (Apple silicon or Intel) | [Build the app](docs/development.md#build) |
| Windows 10 and 11 (x86-64 or Arm, through WSL 2) | [Build the Windows installer](docs/development.md#build) |
| Linux (Ubuntu, Fedora and others) | [Build a `.deb` or `.rpm`](packaging/README.md) |
| ARM64 Android with Termux | [Build and install the launcher](docs/android.md#build-from-source) |

The first time you open the desktop app, it sets up a `stowlark` Docker context.

## Quick start

```sh
docker --context stowlark run --rm alpine echo hello
docker --context stowlark compose up -d
stowlark k8s start                      # single-node Kubernetes as the `stowlark` kubectl context
stowlark machine create dev --distro ubuntu && stowlark machine shell dev
stowlark import                         # bring images, volumes and containers over from OrbStack or Docker Desktop
```

Docker's commands also work as `stowlark` commands (`stowlark run`, `stowlark ps`,
`stowlark compose up`, and so on), and always target Stowlark.

## Linux workspaces on Android

`stowlark-android` runs a small ARM64 Linux VM from Termux on Android without
root. It gives scripts and on-device agents a shell, Python, and optional
persistent workspace files. Each run returns JSON with stdout, stderr and the
exit status, and starts with networking and host file sharing disabled.

```sh
stowlark-android create project
printf 'python3 -c "print(6 * 7)"\n' | stowlark-android run project
stowlark-android delete project
```

See [Android setup and agent integration](docs/android.md) for installation,
limits, and what the QEMU software emulator can safely be used for.

## Upstream benchmarks

The inherited benchmark data measures upstream Kiri. It ran `true` in
`alpine` and removed the container, taking the median of 30 runs with the
same `docker` CLI for all three engines.

|                | Docker Engine API | `docker` CLI |
|----------------|------------------:|-------------:|
| **Kiri (upstream)** | **2.55 ms**      | **14.2 ms**  |
| Docker Desktop | 213 ms            | 243 ms       |
| OrbStack       | 380 ms            | 442 ms       |

See [`bench/results.json`](bench/results.json) for the upstream methodology.
Run `stowlark bench` to measure your own build.

## How it works

```
docker CLI ─┐
compose ────┼─ Docker Engine API ─► stowlark daemon ── vsock ──► guest agent (PID 1)
buildx ─────┤                         owns the VM           clone3 → container
stowlark UI ────┘
```

The VM uses a custom 10 MB kernel, and its PID 1 is a ~900 KB Rust agent.
That agent starts containers with a single `clone3` into namespaces and a
cgroup. There's no runc, no shim and no dockerd. More detail is in
[docs/development.md](docs/development.md#architecture).

## Documentation

- [Features](docs/features.md): supported desktop features, build outputs and known issues
- [Android workspaces](docs/android.md): Termux setup, JSON CLI and build instructions
- [Development](docs/development.md): building, running from source, architecture and repository layout
- [Upstream Kiri release notes](docs/releases)

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
and the [Code of Conduct](../CODE_OF_CONDUCT.md). To report a vulnerability
privately, see [SECURITY.md](SECURITY.md).

## License

The Stowlark runtime is licensed under [Apache-2.0](LICENSE). Third-party
licences are in [NOTICE](NOTICE). The guest kernel is Linux (GPL-2.0). See the
[kernel config and patches](guest/kernel) and the
[source offer](guest/kernel/SOURCE_OFFER.md).

AnythingLLM Mobile is licensed under [GPL-3.0-or-later](../LICENSE) and retains
Mintplex Labs’ copyright and attribution.

Stowlark uses its own name and logo. See [Kiri's README](https://github.com/libracoder/kiri#license)
for the upstream project's branding terms.
