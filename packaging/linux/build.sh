#!/bin/bash
# Stowlark's Linux packages from the static (musl) binaries:
#   packaging/linux/build.sh <bindir> <outdir> [arch] [cli-dir] [window]
#     bindir   holds stowlark and stowlark-init (cargo xtask linux: target/linux/release,
#              or scripts/windows-engine.sh: target/linux-x86_64-musl)
#     outdir   gets the packages
#     arch     x86_64 (default) or aarch64
#     cli-dir  docker, docker-compose, docker-buildx from fetch-cli.sh; with it
#              the full `stowlark` package is built too, else only `stowlark-lite`
#     window   stowlark built with --features window for this arch (glibc, GTK 3,
#              WebKitGTK 4.1); with it the full package gets the window as
#              /usr/lib/stowlark/stowlark-window, its launcher and icons, and depends
#              on GTK and WebKitGTK. Without it, `stowlark ui` says there's none.
# Packages:
#   stowlark-lite  the engine: stowlark, stowlark-init, the systemd unit        (~2 MB)
#   stowlark       the same plus the docker CLI, Compose and buildx      (~60 MB)
#              and the window when one is given
# Needs dpkg-deb (any Debian/Ubuntu, also in WSL) and rpmbuild (apt install rpm).
# Either tool missing: those packages are skipped with a note.
set -euo pipefail
# Directories in the packages are made here with mkdir -p and keep this
# mask; a builder's stricter umask would otherwise ship 0750 /usr/bin.
umask 022
bindir=$(cd "$1" && pwd) outdir=$2 arch=${3:-x86_64} clidir=${4:-} window=${5:-}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# tr: a Windows checkout has CRLF line endings.
version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/Cargo.toml" | head -1 | tr -d '\r')
# A test build's 0.1.8-dev.42 is 0.1.8~dev.42 here: rpm takes no "-" in a
# version, and "~" sorts before the release in both dpkg and rpm.
version=${version/-/\~}
case $arch in
  x86_64) deb_arch=amd64 ;;
  aarch64) deb_arch=arm64 ;;
  *) echo "arch must be x86_64 or aarch64" >&2; exit 1 ;;
esac
for b in stowlark stowlark-init; do
  [ -x "$bindir/$b" ] || { echo "no $bindir/$b" >&2; exit 1; }
done
if [ -n "$clidir" ]; then
  clidir=$(cd "$clidir" && pwd)
  for b in docker docker-compose docker-buildx; do
    [ -x "$clidir/$b" ] || { echo "no $clidir/$b (run fetch-cli.sh)" >&2; exit 1; }
  done
fi
if [ -n "$window" ]; then
  [ -n "$clidir" ] || { echo "the window goes in the full stowlark package: give a cli-dir too" >&2; exit 1; }
  [ -x "$window" ] || { echo "no $window" >&2; exit 1; }
  window=$(cd "$(dirname "$window")" && pwd)/$(basename "$window")
fi
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The files both packages share, into a staging root.
stage_engine() { # root unitdir
  mkdir -p "$1/usr/bin" "$1/$2"
  install -m 755 "$bindir/stowlark" "$bindir/stowlark-init" "$1/usr/bin/"
  install -m 644 "$here/stowlark.service" "$1/$2/stowlark.service"
  # The password prompt for `stowlark host-access` (the window's setup checklist).
  install -D -m 644 "$here/dev.stowlark.host-access.policy" "$1/usr/share/polkit-1/actions/dev.stowlark.host-access.policy"
}
stage_cli() { # root
  # The plugins stay in Stowlark's own directory: /usr/lib/docker/cli-plugins
  # belongs to Docker's packages (docker-compose-plugin, docker-desktop), and
  # dpkg/rpm refuse to install over their files. postinst links them there
  # through update-alternatives when the slot is free, as with /usr/bin/docker.
  mkdir -p "$1/usr/libexec/stowlark/bin" "$1/usr/libexec/stowlark/cli-plugins"
  install -m 755 "$clidir/docker" "$1/usr/libexec/stowlark/bin/docker"
  install -m 755 "$here/docker-wrapper" "$1/usr/libexec/stowlark/docker"
  install -m 755 "$clidir/docker-compose" "$1/usr/libexec/stowlark/cli-plugins/docker-compose"
  install -m 755 "$clidir/docker-buildx" "$1/usr/libexec/stowlark/cli-plugins/docker-buildx"
}
# The AppStream entry software centers list Stowlark by, with this version.
metainfo() { # destination
  mkdir -p "$(dirname "$1")"
  sed -e "s/@VERSION@/$version/" -e "s/@DATE@/$(date -u +%Y-%m-%d)/" "$root/contrib/linux/dev.stowlark.Stowlark.metainfo.xml" > "$1"
  chmod 644 "$1"
}
# The window, its launcher, the app icon and the AppStream entry.
stage_window() { # root
  mkdir -p "$1/usr/lib/stowlark" "$1/usr/share/applications"
  install -m 755 "$window" "$1/usr/lib/stowlark/stowlark-window"
  install -m 644 "$root/contrib/linux/dev.stowlark.Stowlark.desktop" "$1/usr/share/applications/dev.stowlark.Stowlark.desktop"
  metainfo "$1/usr/share/metainfo/dev.stowlark.Stowlark.metainfo.xml"
  for s in 16 32 64 128 256 512; do
    install -D -m 644 "$root/brand/icon/png/stowlark-app-icon-$s.png" "$1/usr/share/icons/hicolor/${s}x${s}/apps/stowlark.png"
  done
  install -D -m 644 "$root/brand/icon/stowlark-app-icon.svg" "$1/usr/share/icons/hicolor/scalable/apps/stowlark.svg"
}

# ---- .deb (plain dpkg-deb: no debhelper, no build dependencies) ----
build_deb() { # name full(0|1)
  local name=$1 full=$2 pkg=$work/deb-$1 other
  rm -rf "$pkg"
  stage_engine "$pkg" lib/systemd/system
  [ "$full" = 1 ] && stage_cli "$pkg"
  [ "$full" = 1 ] && [ -n "$window" ] && stage_window "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/share/doc/$name"
  install -m 644 "$root/LICENSE" "$root/NOTICE" "$pkg/usr/share/doc/$name/"
  cat > "$pkg/usr/share/doc/$name/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Stowlark
Source: https://github.com/culpen90/stowlark
Comment: Stowlark is derived from https://github.com/libracoder/kiri.

Files: *
Copyright: 2026 Kiri
License: Apache-2.0
 See LICENSE and NOTICE in this directory.
EOF
  if [ "$full" = 1 ]; then
    cat >> "$pkg/usr/share/doc/$name/copyright" <<EOF

Files: usr/libexec/stowlark/bin/docker usr/libexec/stowlark/cli-plugins/*
Copyright: Docker, Inc.
License: Apache-2.0
 The docker CLI, Docker Compose and Docker Buildx, unmodified, from
 download.docker.com and github.com/docker.
EOF
  fi
  local size; size=$(du -sk "$pkg/usr" | cut -f1)
  if [ "$full" = 1 ]; then other=stowlark-lite; else other=stowlark; fi
  cat > "$pkg/DEBIAN/control" <<EOF
Package: $name
Version: $version
Section: admin
Priority: optional
Architecture: $deb_arch
Installed-Size: $size
Maintainer: Stowlark <culpen90@users.noreply.github.com>
Homepage: https://github.com/culpen90/stowlark
Conflicts: $other
Replaces: $other
$([ "$full" = 1 ] || echo "Suggests: docker-cli | docker.io")
$([ "$full" = 1 ] && [ -n "$window" ] && echo "Depends: libc6 (>= $(ldd --version | sed -n '1s/.* //p')), libgtk-3-0t64 | libgtk-3-0, libwebkit2gtk-4.1-0")
$([ "$full" = 1 ] && [ -n "$window" ] && echo "Recommends: pkexec | policykit-1")
Description: Tiny, fast container runtime (Docker API)$([ "$full" = 1 ] || echo ", engine only")
 Stowlark runs containers on this machine's kernel and speaks the Docker API on
 /run/stowlark/docker.sock for users in the stowlark group. No VM, no daemon other
 than stowlark itself. Members of the stowlark group can run containers as root on
 this machine; treat it like the docker group.
$(if [ "$full" = 1 ]; then echo " .
 This package brings the docker CLI, Compose and buildx with it, as
 Stowlark.app does on the Mac: \`docker run\` works right after installing.
 A docker CLI from another package keeps precedence on PATH."; [ -n "$window" ] && echo " .
 Stowlark's window is in the app menu, or: stowlark ui"; else echo " .
 Engine only: point any docker CLI at it with
  docker context create stowlark --docker host=unix:///run/stowlark/docker.sock"; fi)
EOF
  sed -i '/^$/d' "$pkg/DEBIAN/control"
  for s in postinst prerm postrm; do install -m 755 "$here/deb/$s" "$pkg/DEBIAN/$s"; done
  # Re-check the plugin links when another package changes Docker's plugin folders.
  [ "$full" = 1 ] && printf 'interest-noawait /usr/lib/docker/cli-plugins\ninterest-noawait /usr/libexec/docker/cli-plugins\ninterest-noawait /usr/local/lib/docker/cli-plugins\ninterest-noawait /usr/local/libexec/docker/cli-plugins\n' > "$pkg/DEBIAN/triggers"
  local deb=$outdir/${name}_${version}_${deb_arch}.deb
  dpkg-deb --build --root-owner-group "$pkg" "$deb" >/dev/null
  echo "$deb"
}

# ---- .rpm ----
build_rpm() { # name full(0|1)
  local top=$work/rpm-$1
  mkdir -p "$top"/{SOURCES,BUILD,RPMS,SRPMS,SPECS}
  cp "$bindir/stowlark" "$bindir/stowlark-init" "$here/stowlark.service" "$here/dev.stowlark.host-access.policy" "$root/LICENSE" "$root/NOTICE" "$top/SOURCES/"
  local with=()
  if [ "$2" = 1 ]; then
    cp "$clidir/docker" "$top/SOURCES/docker"
    cp "$clidir/docker-compose" "$clidir/docker-buildx" "$here/docker-wrapper" "$top/SOURCES/"
    with=(--define "with_cli 1")
    if [ -n "$window" ]; then
      cp "$window" "$top/SOURCES/stowlark-window"
      cp "$root/contrib/linux/dev.stowlark.Stowlark.desktop" "$root/brand/icon/stowlark-app-icon.svg" "$top/SOURCES/"
      metainfo "$top/SOURCES/dev.stowlark.Stowlark.metainfo.xml"
      for s in 16 32 64 128 256 512; do cp "$root/brand/icon/png/stowlark-app-icon-$s.png" "$top/SOURCES/"; done
      with+=(--define "with_window 1")
    fi
  fi
  # xz at level 6, as dpkg-deb packs the .deb: rpmbuild's default (zstd at
  # level 19 on new distros, gzip on old) left the rpm about a quarter bigger.
  # Every rpm distro Stowlark supports reads xz.
  rpmbuild -bb --quiet --define "_topdir $top" --define "stowlark_name $1" --define "stowlark_version $version" --define "stowlark_arch $arch" \
    --define "_binary_payload w6.xzdio" \
    --define "_unitdir /usr/lib/systemd/system" --define "_licensedir /usr/share/licenses" "${with[@]}" \
    --target "$arch" "$here/rpm/stowlark.spec"
  local rpm; rpm=$(ls "$top"/RPMS/*/"$1"-*.rpm)
  cp "$rpm" "$outdir/"
  echo "$outdir/$(basename "$rpm")"
}

if command -v dpkg-deb >/dev/null; then
  build_deb stowlark-lite 0
  [ -n "$clidir" ] && build_deb stowlark 1
else
  echo "dpkg-deb not found: no .deb" >&2
fi
if command -v rpmbuild >/dev/null; then
  build_rpm stowlark-lite 0
  [ -n "$clidir" ] && build_rpm stowlark 1
else
  echo "rpmbuild not found: no .rpm (apt install rpm)" >&2
fi
[ -n "$clidir" ] || echo "(no cli-dir given: only stowlark-lite; run fetch-cli.sh and pass its directory for the full stowlark package)" >&2
