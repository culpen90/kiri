# Features

What Stowlark supports today, through the `stowlark` Docker context.

## Platforms

Apple silicon and Intel Macs (macOS 14+), Windows 10 and 11 (x86-64 and Arm, through WSL 2), and Linux (.deb and .rpm, tested on Ubuntu and Fedora). 
## What works

- **Containers**: `run` (`--rm`, `-d`, `-it`, `-e`, `-u`, `-w`, `--name`,
  `--restart`, `--entrypoint`), `exec`, `logs`, `attach`, `stop`, `kill`,
  `restart`, `rm`, `wait`, `rename`, `pause`/`unpause`, `update`, `stats`,
  `top`, `diff`, `export`, `commit`, `cp` (both ways, running or not),
  `container prune`; records survive a daemon restart; filters on every list
- **Limits and security**: `--memory`, `--cpus`, `--cpu-shares`,
  `--pids-limit`, `--shm-size`; Docker's default capabilities and a default
  seccomp filter; `--cap-add`/`--cap-drop`, `--privileged`, `--read-only`,
  `--security-opt seccomp=unconfined` and `no-new-privileges`. Even
  privileged and unconfined containers keep the host boundary: no vsock
  sockets (the way to the Mac) and no io_uring
- **Networking**: a default bridge, user networks with DNS by name and
  alias, `network connect`/`disconnect`, `--network host|none`, `-p`/`-P`
  (TCP and UDP) on all interfaces (as Docker does; `-p 127.0.0.1:8080:80`
  keeps a port local), `--add-host`, `host.docker.internal`,
  `--network container:<name>` (Compose `network_mode: service:x`; as with
  Docker, if that container restarts, the ones sharing its network keep the
  old, now empty namespace until they are restarted too), IPAM (`--subnet`,
  `--gateway`, `--ip-range`, `--aux-address`), `--ip`, `--mac-address`,
  `--dns`, `--dns-search`, `--dns-option`, `--domainname`, `--link`,
  `--ipv6` (Compose `enable_ipv6`: an IPv6 subnet beside the IPv4 one, from
  `--subnet` or a /64 of Stowlark's own under fd00::/8; the default bridge stays
  IPv4-only, as Docker's does), and
  `http://<name>.stowlark.local` once you turn it on (the app asks on first open;
  Settings → Domains changes it), or `http://<name>.stowlark.localhost` with no
  setup. Compose services answer at `<service>.<project>.stowlark.local`, and a
  `dev.stowlark.domain=api.myapp` label picks a container's own names; HTTPS too
  (`https://<name>.stowlark.local`), with Stowlark's own certificate authority in
  `~/.stowlark/tls`, whose name constraints allow only `*.stowlark.local` and
  `*.stowlark.localhost` (Settings → Domains → HTTPS asks macOS to trust it).
  Set `dev.stowlark.http.port` to select a container's HTTP port. The legacy
  `dev.kiri.domain` and `dev.kiri.http.port` labels are also accepted.
- **Storage**: named and anonymous volumes, bind mounts of Mac paths
  (virtiofs), `--tmpfs`, `--mount`, `volume` commands
- **Images**: `pull` (with `docker login` credentials), `push`, `tag`,
  `save`, `load`, `history`, `search`, `image prune`, `system df`;
  **amd64 images run through Rosetta**, `--platform` honoured
- **Builds**: `docker build` / `buildx build` through BuildKit running in a
  Stowlark container (buildx's docker-container driver), stopped when idle;
  on Apple silicon, amd64 build steps run through Rosetta too
- **Compose**: `up`, `down`, `ps`, `logs`, `exec`, multiple networks, events
- **USB devices (beta)**: the USB tab hands a device (a serial adapter, a
  Zigbee stick, a development board) to your containers on Mac, Windows and
  Linux, and shows where it is inside Linux with the `--device` line to
  copy. On a Mac, a device that drops off the bus while attached (the board
  resets, or the Mac sleeps) is attached again when it comes back
- **Mac integration**: container files at `~/Stowlark` in Finder (read-only
  NFS, always current), SSH agent forwarding at
  `/run/host-services/ssh-auth.sock`
- **Memory**: a balloon gives unused memory back while running, and the VM
  sleeps after 60 s idle (the daemon stays at ~15 MB; waking takes ~0.15 s)
- **The window**: containers, images, volumes and networks, with Compose
  projects grouped (start, stop, restart or remove a whole project); each
  container has its own page with details, live logs (find, level filter),
  a command line (and "Open in Terminal" for a full shell) and its files
  (preview, Save to Downloads, Show in Finder); Settings for fonts, text
  size, the VM's CPUs and memory (`~/.stowlark/vm.json`, used from the VM's
  next start; `STOWLARK_CPUS` and `STOWLARK_MEMORY_MIB` override it) and local names
- **Menu bar**: Stowlark stays in the menu bar when its window closes, with the
  VM's state, running containers (click one to open it) and Start/Stop
- **Kubernetes**: `stowlark k8s start` — a single-node k3s cluster in one
  container, ready in ~20 s, as the `stowlark` kubectl context
- **Linux machines**: `stowlark machine create dev --distro ubuntu` and
  `stowlark machine shell dev` — your user, sudo, and `/Users` at the same path
- **The app**: `cargo xtask app` builds `Stowlark.app` with the `docker` CLI,
  Compose and buildx inside; opening it runs `stowlark setup` (docker context,
  LaunchAgent, build builder) and the window
- **Linux hosts**: the same `stowlark` with no VM — the agent runs on the host's
  kernel (`cargo xtask linux`, `contrib/linux/stowlark.service`); arm64 and
  x86-64; `tests/linux-host.sh` checks it. Packaged as `.deb` and `.rpm`
  (`packaging/linux`): `stowlark` with the docker CLI, Compose and buildx, or
  `stowlark-lite` for the engine alone. Membership of the `stowlark` group is
  root-equivalent, exactly like the `docker` group
- **Windows**: the x86-64 Linux build in a WSL2 distro, and `stowlark-win.exe`,
  which serves the API on `npipe:////./pipe/stowlark` (the `stowlark` docker
  context) and carries it into WSL over one `wsl.exe … stowlark bridge`, so it
  needs no change to WSL's or Windows' network settings (`cargo xtask
  msi` builds `target/Stowlark-<version>-x86_64.msi`, a per-user installer
  around `target/stowlark-windows-x86_64`; `stowlark.ps1` in that folder installs
  the same without an MSI). Not TCP:
  WSL's localhost relay drops half-closes, and `docker run` loses its
  output

Kubernetes LoadBalancer services are published on `localhost`, and
`stowlark machine create NAME --systemd` boots systemd as the machine's init.

## Build outputs and updates

Check [Stowlark releases](https://github.com/stowlark/stowlark/releases) for
published builds. For local builds, see [the development guide](development.md).
Installer filenames include the architecture, for example,
`Stowlark-<version>-arm64.dmg` for Apple silicon and
`Stowlark-<version>-x86_64.msi` for x64 Windows.

The full macOS app bundles the Docker CLI, Compose and buildx. The Lite
build (`cargo xtask app-lite`) downloads the pinned versions on first launch
unless the Mac already has a Docker CLI. Downloads are checked against the
SHA-256 pins in `crates/kiri/src/cli_pins.rs`.

Updates require an explicitly configured signed release feed. Stowlark
checks the manifest signature and download checksum.

## Known issues

- **Mac: an attached USB device leaves your containers while the Mac
  sleeps.** macOS takes USB devices off the bus when it sleeps, so a device
  such as `/dev/ttyACM0` is gone from containers until the Mac wakes. Stowlark
  then attaches it again by itself. Stowlark doesn't keep the Mac awake for a
  device, since that would drain a laptop's battery. For a long job that
  runs unattended (flashing boards, logging a serial port), keep the Mac
  awake while it runs: `caffeinate -s` in a terminal (on power), or turn on
  "Prevent automatic sleeping when the display is off" in System Settings
  (Battery › Options on a laptop, Energy on a desktop Mac).

- **`docker build --add-host name:host-gateway` with BuildKit fails** with
  `host-gateway is not supported by the docker-container driver`. buildx
  refuses `host-gateway` for every builder except Docker's built-in one, and
  Stowlark's builder is a docker-container builder, so the build stops before
  Stowlark sees it. Docker's own docker-container builders do the same. Use the address itself
  (`--add-host name:172.18.0.1` on Windows and Linux, the default bridge's
  gateway; `198.19.248.254` on a Mac) or `DOCKER_BUILDKIT=0`, where Stowlark
  maps `host-gateway` itself.
