#!/bin/sh
# Builds target/stowlark_<version>_<arch>.deb on a Debian or Ubuntu machine:
# the engine and CLI (/usr/bin/stowlark, stowlark-init), the stowlark system service,
# and the window (/usr/lib/stowlark/stowlark-window) with its launcher and icon.
#
# Needs: Rust, dpkg-deb, and libwebkit2gtk-4.1-dev for the window. Run it
# on the oldest release the package should install on: the window links
# that release's glibc, GTK and WebKitGTK.
set -eu
cd "$(dirname "$0")/../.."
root=$(pwd)
version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
arch=$(dpkg --print-architecture)

cargo build --release -p stowlark -p stowlark-init
# Its own target dir: the same crate with another feature set would
# otherwise rebuild over the engine's binary each time.
CARGO_TARGET_DIR=target/window cargo build --release -p stowlark --features window

pkg=target/deb/stowlark_${version}_${arch}
rm -rf "$pkg"
install -d "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/stowlark" "$pkg/usr/lib/systemd/system" "$pkg/usr/share/applications"
install -m 755 target/release/stowlark target/release/stowlark-init "$pkg/usr/bin/"
install -m 755 target/window/release/stowlark "$pkg/usr/lib/stowlark/stowlark-window"
sed 's|^ExecStart=/usr/local/bin/stowlark daemon|ExecStart=/usr/bin/stowlark daemon|' contrib/linux/stowlark.service >"$pkg/usr/lib/systemd/system/stowlark.service"
install -m 644 contrib/linux/dev.stowlark.Stowlark.desktop "$pkg/usr/share/applications/dev.stowlark.Stowlark.desktop"
for s in 16 32 64 128 256 512; do
    install -D -m 644 "brand/icon/png/stowlark-app-icon-$s.png" "$pkg/usr/share/icons/hicolor/${s}x${s}/apps/stowlark.png"
done
install -D -m 644 brand/icon/stowlark-app-icon.svg "$pkg/usr/share/icons/hicolor/scalable/apps/stowlark.svg"
install -m 755 contrib/linux/deb/postinst contrib/linux/deb/prerm contrib/linux/deb/postrm "$pkg/DEBIAN/"

size=$(du -sk "$pkg/usr" | cut -f1)
cat >"$pkg/DEBIAN/control" <<EOF
Package: stowlark
Version: $version
Architecture: $arch
Maintainer: Stowlark
Homepage: https://github.com/stowlark/stowlark
Section: admin
Priority: optional
Installed-Size: $size
Depends: libc6, libgtk-3-0t64 | libgtk-3-0, libwebkit2gtk-4.1-0, docker.io | docker-ce-cli
Recommends: docker-buildx | docker-buildx-plugin, docker-compose-v2 | docker-compose-plugin
Description: Run, build and share containers
 Stowlark is a small container engine with its own window. Plain docker
 commands work against it through the "stowlark" docker context, and the
 window shows containers, images, volumes, builds and Kubernetes, and
 shares a container on a public https link.
EOF
dpkg-deb --root-owner-group --build "$pkg" "target/stowlark_${version}_${arch}.deb"
echo "$root/target/stowlark_${version}_${arch}.deb"
