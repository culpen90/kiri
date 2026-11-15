# Development

Building Stowlark from source, running it, and how it fits together.

## Build

Needs Rust and, for the kernel and disk template, a Docker engine. Stowlark can
build its own kernel: `DOCKER_CONTEXT=stowlark cargo xtask kernel`.

```sh
cargo xtask kernel    # guest/out/Image
cargo xtask disk      # guest/out/data.img (sparse 64 GiB ext4 template)
cargo xtask guest     # guest/out/initramfs.cpio
cargo xtask host      # target/release/stowlark, signed with the virtualization entitlement
cargo xtask app       # target/Stowlark.app with Docker CLI, Compose and buildx
```

For Intel Macs add `--arch x86_64` to `kernel`, `guest`, `host`, `app`,
`dmg` and `release`: an x86-64 guest in `guest/out/x86_64` (a `bzImage`,
cross-compiled on Apple Silicon), the host for `x86_64-apple-darwin`
(`rustup target add x86_64-apple-darwin x86_64-unknown-linux-musl`), and
`target/intel/Stowlark.app` with Intel builds of the docker CLI, Compose and
buildx. The Intel packages are named `Stowlark-<version>-x86_64.dmg` and
`Stowlark-<version>-x86_64.tar.gz`. Each architecture has its own app. On Intel there is
no Rosetta for Linux: amd64 images run natively, and images with no amd64
build are refused.

The Android distribution builds separately from the desktop engine. See
[Android setup](android.md#build-from-source) for the ARM64 Termux bundle and
real QEMU smoke test.

On Windows, `cargo xtask windows-dev` builds the Linux engine, Stowlark Linux and
Docker tools into `target/stowlark-windows-x86_64` with a debug `stowlark-win.exe`.
`cargo run -p stowlark-win` uses that bundle automatically. Use `cargo xtask
windows` for the release bundle and `cargo xtask msi` for the installer.
Add `--arch arm64` to any of the three for Windows on Arm
(`target/stowlark-windows-aarch64`, `Stowlark-<version>-arm64.msi`); testing it in
a VM on a Mac is in [Testing Windows on Arm](testing-windows-arm.md).

For Linux packages, see [the packaging guide](../packaging/README.md).

## Use

```sh
./target/release/stowlark daemon &      # serves ~/.stowlark/run/docker.sock; the VM boots on first use
docker context create stowlark --docker host=unix://$HOME/.stowlark/run/docker.sock
docker --context stowlark run --rm alpine echo hello
docker buildx create --name stowlark-build --driver docker-container \
  --driver-opt default-load=true --use stowlark    # for docker build
./target/release/stowlark bench         # Stowlark vs OrbStack vs Docker Desktop
SOAK=600 tests/e2e.sh               # every check, then 600 runs watching for leaks
```

Docker's commands also work as `stowlark` commands, always on Stowlark whatever
docker context is selected: `stowlark run`, `stowlark ps`, `stowlark exec`, `stowlark logs`,
`stowlark build`, `stowlark compose up` and the rest run the docker CLI against
Stowlark's socket. (`stowlark import` is Stowlark's own: it brings images, volumes and
containers over from OrbStack or Docker Desktop.) The daemon-free tools
that boot their own guest are `stowlark raw run|pull|images|rmi`.

`stowlark` keeps its data in `~/Library/Application Support/Stowlark` (override with
`STOWLARK_DATA_DIR`). It does not touch `/usr/local/bin/docker`.
The desktop app keeps its state separate from Kiri.
`/var/run/docker.sock` changes only when you ask: `stowlark setup --docker-socket`
(or the password prompt for `*.stowlark.local` names) links it to Stowlark's socket
when no other engine has it, after macOS asks for an administrator password,
and installs `/Library/LaunchDaemons/dev.stowlark.docker-socket.plist` to put the
link back after a restart. A socket another engine owns is never replaced.

## Architecture

```
docker CLI ─┐
compose ────┼─ ~/.stowlark/run/docker.sock ─► stowlark daemon ── vsock ──► guest agent (PID 1)
buildx ─────┤     Docker Engine API          owns the VM            clone3 → container
stowlark UI ────┘
```

- **VM**: Apple's Virtualization.framework, driven from Rust through objc2.
  A custom 10 MB kernel (`guest/kernel/`) built from allnoconfig, with one
  patch that cuts virtio-pci reset waits from a scheduler tick to
  microseconds, one that hands big TCP to the host as GSO, one that keeps
  newly created FUSE files owner-readable, and an upstream GRO fix that keeps
  forwarded packets segmentable. Rosetta is shared in over virtiofs and registered with
  binfmt_misc.
- **Guest agent**: a ~900 KB static Rust binary that is PID 1. One `poll()`
  loop serves the host, reaps children, forwards container output, relays
  ports, answers DNS and runs DHCP. `docker cp` and friends run in forked
  children so a large copy never stalls it.
- **Containers**: one `clone3` straight into new namespaces and the
  container's cgroup (`CLONE_INTO_CGROUP`), overlayfs over layers unpacked
  on an ext4 data disk, `pivot_root`, capabilities and a seccomp filter.
  Networking is set up with hand-written rtnetlink and nf_tables messages.
  No runc, no shim, no dockerd.
- **Images**: pulled and pushed on the Mac (`crates/kiri-image`), streamed
  into the guest once and unpacked there.

## Layout

| Path | What |
|------|------|
| `crates/kiri` | the `stowlark` binary: daemon, Docker API, CLI, UI, bench |
| `crates/kiri-vmm` | Virtualization.framework VM |
| `crates/kiri-init` | guest PID 1, agent and container runtime |
| `crates/kiri-android` | local Termux launcher and JSON CLI for offline ARM64 Linux VMs |
| `crates/kiri-proto` | host ↔ guest wire protocol (no_std, no allocation per message) |
| `crates/kiri-image` | image references, registry client, blob store, archives |
| `guest/kernel` | kernel config and patches |
| `guest/android` | pinned Alpine inputs and the Android initramfs builder |
| `tests/e2e.sh` | ~350 checks through the real `docker` CLI, plus a leak soak (`K8S=1` adds Kubernetes) |
| `tests/linux-host.sh` | the Linux host build, driven in a privileged container |
| `tests/finder-mount.sh` | the Mac's Finder mount at `~/Stowlark`: covers only an empty folder or its own old mount, never your files or another mount |
| `contrib/` | systemd unit, WSL2 and Windows install scripts |
| `installer/windows` | the Windows MSI (WiX 5): `stowlark.wxs`, licence, dialog bitmaps |
| `packaging/` | Linux `.deb` and `.rpm` (`stowlark` with the docker CLI, `stowlark-lite` engine only), the Homebrew plan |
| `xtask` | build tasks |
| `bench/results.json` | upstream benchmark results |
| `brand/` | logos, app icons and Windows installer artwork |

To regenerate the vector assets, run `python3 brand/generate.py brand` from
the repository root. Install CairoSVG (with Cairo available to Python) and
Pillow, then add `--rasters` to regenerate the PNG, ICO and BMP assets.
