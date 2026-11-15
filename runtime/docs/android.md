# Linux workspaces on Android

`stowlark-android` boots a small ARM64 Alpine Linux VM with BusyBox (including a
POSIX shell and common command-line tools) and Python 3. It runs locally on an
ARM64 Android device in [Termux](https://github.com/termux/termux-app#installation),
without root or a desktop daemon. An agent that can start processes in Termux
can call the CLI directly. AnythingLLM Mobile calls the CLI through the Termux
command API and asks for approval before each script.
[Set up AnythingLLM Mobile](../../docs/stowlark-android.md).

## Set up in Termux

1. Install QEMU from Termux's signed package repository. The emulator and its
   dependencies may need around 1 GB of free storage on a clean Termux install.

   ```sh
   pkg install qemu-system-aarch64-headless
   ```

2. Put `stowlark-android-aarch64.tar.gz` and its `.sha256` file from your [trusted
   build](#build-from-source) together in your Termux working directory. Get
   the checksum from a trusted build or distribution channel; a checksum
   downloaded with an untrusted archive does not authenticate its publisher.

   ```sh
   sha256sum -c stowlark-android-aarch64.tar.gz.sha256 &&
     mkdir -p "$HOME/.local" &&
     tar -xzf stowlark-android-aarch64.tar.gz -C "$HOME/.local" &&
     "$HOME/.local/stowlark-android/bin/stowlark-android" doctor
   ```

   Install into Termux's private home, which allows the included binary to
   run. For the examples below, run `export PATH="$HOME/.local/stowlark-android/bin:$PATH"`
   or use the full path in your agent configuration.

3. Try a temporary VM:

   ```sh
   printf 'uname -m; python3 -c "print(6 * 7)"\n' | stowlark-android run
   ```

   The JSON response should have `status: "exited"`, `exit_code: 0`, and
   `aarch64` and `42` in `stdout`.

If you used the earlier `kiri-android` preview, stop any running jobs and move
the workspace directory before creating workspaces with Stowlark:

```sh
test -d "$HOME/.kiri-android" &&
  test ! -e "$HOME/.stowlark-android" &&
  test ! -L "$HOME/.stowlark-android" &&
  mv "$HOME/.kiri-android" "$HOME/.stowlark-android"
```

If `~/.stowlark-android` already exists, leave both directories in place.

## Use from an agent

Use an argument array to start the CLI, put the script on stdin, then read its
JSON reply from stdout. No host shell is needed. For example, from an agent
running in Termux with Python:

```python
import json
import subprocess
from pathlib import Path

stowlark = Path.home() / ".local/stowlark-android/bin/stowlark-android"
job = subprocess.run(
    [stowlark, "run", "--timeout", "30"],
    input="printf 'hello from Linux\\n'\n",
    text=True,
    encoding="utf-8",
    capture_output=True,
)
result = json.loads(job.stdout)
if result["status"] == "exited" and result["exit_code"] == 0:
    print(result["stdout"], end="")
else:
    print(result)
```

Use a named workspace if a later job needs the files. For example:

```sh
stowlark-android create notes
printf 'echo draft > status.txt\n' | stowlark-android run notes
printf 'cat status.txt\n' | stowlark-android run notes
stowlark-android list
stowlark-android delete notes
```

Each job starts a new Linux boot, under guest UID 1000 with its working
directory and `HOME` set to `/workspace`. Only this directory persists in a
named workspace. A run without a name discards its workspace at exit. The
launcher runs one VM at a time and keeps its private state in `~/.stowlark-android`.
Names contain up to 32 lowercase ASCII letters, digits and hyphens and begin
with a letter or digit. Deleting a workspace removes its saved files.

| Command | JSON response |
|---|---|
| `doctor` | `status: "ready"`, `api_version`, backend, limits and state directory. Checks local prerequisites. |
| `list` | Sorted `workspaces` array. |
| `create NAME` / `delete NAME` | `status: "created"` / `"deleted"` and `name`. |
| `run [NAME] [--timeout SECONDS]` | `status`, captured `stdout` and `stderr` as UTF-8 text, and `exit_code` if the guest script exited. |

For `run`, `status: "exited"` returns the guest exit code as the CLI exit
code. `"timeout"` returns 124 and `"output_limit"` returns 125. Launcher and
guest startup errors return `"error"` with a `message`. Use the JSON `status`
to distinguish a limit from a script that itself exits with code 124 or 125.

The guest has 256 MiB of RAM and a 64 MiB workspace disk. Scripts must be
UTF-8, with at most 64 KiB of source. The VM stops after 256 KiB of combined
stdout and stderr or on the configured deadline (1–300 seconds, default 90,
including boot). Writes interrupted by a timeout or output limit may be
partial. Guest networking is disabled, so bundle any extra trusted tools
into the guest build beforehand. Docker images and Android apps do not run
inside this guest.

## Trust model

The launcher has no listening socket or Android intent receiver. It never
exposes the phone's files, environment variables, ports, or network to the
Linux guest by design. It uses fixed VM options, a private disk per workspace,
and a dedicated job channel instead of a QEMU monitor.

Use it for your own or reviewed scripts. QEMU's software accelerator (TCG)
[does not guarantee isolation for hostile workloads](https://www.qemu.org/docs/master/system/security.html#non-virtualization-use-case).
QEMU runs under Termux's app identity; a guest escape could reach anything that
Termux can access. Avoid storing sensitive credentials in the same Termux
environment. The agent that launches the CLI already has that Termux identity.

## Build from source

From a trusted checkout on macOS or x86-64 Linux, use Rust, Python 3 and an
installed Android NDK. This packages the ARM64 Android executable together
with the pinned Alpine kernel, initramfs, and source notices. It verifies the
guest inputs against `guest/android/alpine.sha256` before using them.

```sh
cd runtime
rustup target add aarch64-linux-android aarch64-unknown-linux-musl
ANDROID_NDK_HOME=/path/to/android/ndk scripts/build-android.sh
```

The bundle and checksum land in `runtime/target/android-dist` in the checkout.
The Android launcher targets API 26 or newer and was exercised with Termux on
an ARM64 Android 16 emulator. To run the same smoke test from `runtime/` on a
development host, put `qemu-system-aarch64` on `PATH` and run:

```sh
python3 guest/android/build.py --output-dir target/android-guest
cargo build --locked -p stowlark-android
STOWLARK_ANDROID_ASSETS="$PWD/target/android-guest" \
  python3 tests/android-vm.py "$PWD/target/debug/stowlark-android"
```

On Android, `python3 tests/android-vm.py "$HOME/.local/stowlark-android/bin/stowlark-android"`
can verify an installed bundle from Termux (install the Termux `python`
package to run the test). It creates and deletes only its own workspaces.
