#!/usr/bin/env python3
"""Build the ARM64 Android guest from pinned Alpine packages and this checkout."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
from urllib.parse import quote
from urllib.request import urlopen

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TARGET = "aarch64-unknown-linux-musl"
MIRROR = "https://cdn.alpinelinux.org/v3.24"
KERNEL_RELEASE = "6.18.63-0-virt"
MODULES = (
    "drivers/block/virtio_blk", "lib/crc/crc16", "fs/mbcache", "fs/jbd2/jbd2", "fs/ext4/ext4",
)


def input_url(name):
    location = "main/aarch64" if name.endswith(".apk") else "releases/aarch64"
    return f"{MIRROR}/{location}/{quote(name)}"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(cache, digest, name):
    cached = cache / name
    if cached.is_file() and sha256(cached) == digest:
        return cached
    with tempfile.TemporaryDirectory(dir=cache) as directory:
        temporary = Path(directory) / name
        with urlopen(input_url(name), timeout=60) as source, temporary.open("wb") as target:
            shutil.copyfileobj(source, target)
        if sha256(temporary) != digest:
            raise ValueError(f"SHA-256 mismatch for {name}")
        temporary.replace(cached)
    return cached


def add_archive(files, archive):
    # Build cpio in memory from metadata. No archive path is extracted on the host.
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe package path {member.name!r}")
        if not path.parts or path.parts[0].startswith("."):
            continue  # APK signatures, package installation scripts and metadata.
        if member.isdir():
            entry = (stat.S_IFDIR | (member.mode & 0o777), b"", 0, 0)
        elif member.issym():
            entry = (stat.S_IFLNK | 0o777, member.linkname.encode(), 0, 0)
        elif member.isfile() or member.islnk():
            entry = (stat.S_IFREG | (member.mode & 0o777), archive.extractfile(member).read(), 0, 0)
        else:
            raise ValueError(f"unsupported package member {member.name!r}")
        files[str(path)] = entry


def kernel_assets(archive, files):
    wrapped = archive.extractfile("boot/vmlinuz-virt").read()
    # Arm64 EFI zboot wrapper. QEMU's direct kernel boot needs its Image payload.
    if wrapped[4:8] != b"zimg" or wrapped[24:28] != b"gzip":
        raise ValueError("expected a gzip-compressed Arm64 EFI zboot kernel")
    offset, length = struct.unpack_from("<II", wrapped, 8)
    image = gzip.decompress(wrapped[offset:offset + length])
    if image[56:60] != b"ARMd":
        raise ValueError("unexpected ARM64 Image header")
    files["lib/stowlark-modules"] = (stat.S_IFDIR | 0o755, b"", 0, 0)
    for module in MODULES:
        compressed = archive.extractfile(f"lib/modules/{KERNEL_RELEASE}/kernel/{module}.ko.gz").read()
        module_file = f"lib/stowlark-modules/{Path(module).name}.ko"
        files[module_file] = (stat.S_IFREG | 0o644, gzip.decompress(compressed), 0, 0)
    return image


def write_cpio(stream, files):
    # Linux's newc format requires 4-byte alignment and parent directories first.
    entries = sorted(files.items()) + [("TRAILER!!!", (0, b"", 0, 0))]
    for inode, (path, (mode, data, major, minor)) in enumerate(entries, 1):
        name = path.encode() + b"\0"
        fields = (inode, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0, len(data), 0, 0, major, minor, len(name), 0)
        header = b"070701" + "".join(f"{value:08x}" for value in fields).encode()
        stream.write(header + name)
        stream.write(b"\0" * (-(len(header) + len(name)) % 4))
        stream.write(data)
        stream.write(b"\0" * (-len(data) % 4))


def package_source(name, version, origin, revision, license_text):
    url = f"https://gitlab.alpinelinux.org/alpine/aports/-/tree/{revision}/main/{origin}"
    return f"- [{name} {version}]({url}) ({license_text})\n"


def base_sources(files):
    packages = files["lib/apk/db/installed"][1].decode().split("\n\n")
    for package in packages:
        metadata = dict(line.split(":", 1) for line in package.splitlines() if ":" in line)
        if "P" in metadata:
            yield package_source(*(metadata[key] for key in ("P", "V", "o", "c", "L")))


def apk_source(archive):
    metadata = dict(line.split(" = ", 1) for line in archive.extractfile(".PKGINFO").read().decode().splitlines() if " = " in line)
    return package_source(*(metadata[key] for key in ("pkgname", "pkgver", "origin", "commit", "license")))


def build(output, cache):
    target_dir = ROOT / "target"
    cache.mkdir(parents=True, exist_ok=True)
    pins = [line.split() for line in (HERE / "alpine.sha256").read_text().splitlines() if line and not line.startswith("#")]
    with ThreadPoolExecutor(max_workers=6) as workers:
        archives = list(workers.map(lambda pin: fetch(cache, *pin), pins))
    subprocess.run([
        "cargo", "build", "--locked", "--release", "-p", "stowlark-init", "--bin", "stowlark-android-init", "--features", "android-guest",
        "--target", TARGET, "--target-dir", str(target_dir),
    ], cwd=ROOT, check=True)
    init = (target_dir / TARGET / "release" / "stowlark-android-init").read_bytes()
    files = {}
    image = None
    sources = []
    for path in archives:
        with tarfile.open(path, ignore_zeros=True) as archive:
            if path.name.startswith("linux-virt-"):
                image = kernel_assets(archive, files)
            else:
                add_archive(files, archive)
            if path.suffix == ".apk":
                sources.append(apk_source(archive))
            else:
                sources.extend(base_sources(files))
    if image is None:
        raise ValueError("missing the pinned Alpine Linux kernel")
    files["init"] = (stat.S_IFREG | 0o755, init, 0, 0)
    files["dev/console"] = (stat.S_IFCHR | 0o600, b"", 5, 1)
    files["workspace"] = (stat.S_IFDIR | 0o700, b"", 0, 0)
    files["etc/passwd"] = (stat.S_IFREG | 0o644, b"root:x:0:0:root:/root:/bin/sh\nagent:x:1000:1000:agent:/workspace:/bin/sh\n", 0, 0)
    files["etc/group"] = (stat.S_IFREG | 0o644, b"root:x:0:\nagent:x:1000:\n", 0, 0)
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as directory:
        stage = Path(directory)
        (stage / "Image").write_bytes(image)
        with (stage / "initramfs.cpio.gz").open("wb") as target, gzip.GzipFile(filename="", fileobj=target, mode="wb", mtime=0) as compressed:
            write_cpio(compressed, files)
        notice = (
            "# Android guest components\n\n"
            "`Image` and the workspace driver modules come from Alpine Linux’s [aarch64 repository]"
            f"({MIRROR}/main/aarch64/). The initial filesystem contains the [Alpine minirootfs]"
            f"({MIRROR}/releases/aarch64/) and the packages listed below. The included links point to "
            "the packaging sources with upstream source URLs, patches, and build instructions.\n\n"
            "The Stowlark guest launcher is built from `crates/kiri-init/src/bin/kiri-android-init.rs` "
            "under Apache-2.0. `guest/android/alpine.sha256` records every downloaded artifact.\n\n"
            + "".join(sorted(set(sources)))
        )
        (stage / "ANDROID-GUEST-NOTICE.md").write_text(notice, encoding="utf-8")
        for artifact in stage.iterdir():
            artifact.replace(output / artifact.name)
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "target/android-guest-inputs")
    args = parser.parse_args()
    build(args.output_dir, args.cache_dir)
