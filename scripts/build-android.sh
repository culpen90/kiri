#!/bin/sh
# Build the arm64 Termux distribution from this checkout.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1:-}" = "--help" ]; then
    printf 'Usage: ANDROID_NDK_HOME=/path/to/ndk %s [output-directory]\n' "$0"
    printf 'Default output directory: target/android-dist in the repository.\n'
    exit 0
fi
if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [output-directory]\n' "$0" >&2
    exit 2
fi

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an installed Android NDK directory}"
ndk=$(CDPATH='' cd -- "$ANDROID_NDK_HOME" && pwd)
case "$(uname -s)" in
    Darwin) host=darwin-x86_64 ;;
    Linux) host=linux-x86_64 ;;
    *) printf 'Build the Android bundle on macOS or Linux.\n' >&2; exit 1 ;;
esac
linker=$ndk/toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android26-clang
if [ ! -x "$linker" ]; then
    printf 'Android NDK linker not found at %s\n' "$linker" >&2
    exit 1
fi

output=${1:-"$root/target/android-dist"}
mkdir -p -- "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
scratch=$(mktemp -d "$output/.kiri-android.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
bundle=$scratch/kiri-android
assets=$bundle/share/kiri-android
mkdir -p "$bundle/bin" "$assets"

cd "$root"
build_dir=${CARGO_TARGET_DIR:-"$root/target"}
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$linker cargo build --locked \
    -p kiri-android --release --target aarch64-linux-android --target-dir "$build_dir"
install -m 0755 "$build_dir/aarch64-linux-android/release/kiri-android" "$bundle/bin/"
python3 guest/android/build.py --output-dir "$assets"
install -m 0644 LICENSE NOTICE "$assets/"

archive=kiri-android-aarch64.tar.gz
python3 - "$scratch" "$archive" <<'PY'
import gzip
import sys
import tarfile
from pathlib import Path

stage = Path(sys.argv[1])

def normalize(entry):
    entry.mtime = entry.uid = entry.gid = 0
    entry.uname = entry.gname = ""
    entry.mode = 0o755 if entry.isdir() or entry.name == "kiri-android/bin/kiri-android" else 0o644
    return entry

with (stage / sys.argv[2]).open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            tar.add(stage / "kiri-android", arcname="kiri-android", filter=normalize)
PY
(
    cd "$scratch"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$archive"
    else
        shasum -a 256 "$archive"
    fi
) > "$scratch/$archive.sha256"
mv -f -- "$scratch/$archive" "$scratch/$archive.sha256" "$output/"
cat "$output/$archive.sha256"
printf 'Android bundle: %s/%s\n' "$output" "$archive"
