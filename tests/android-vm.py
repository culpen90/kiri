#!/usr/bin/env python3
"""Smoke-test kiri-android against the installed guest and a real QEMU.

Pass the path to kiri-android. The launcher must be able to find QEMU and its
guest assets as usual. On a development host, set KIRI_ANDROID_ASSETS first.
The test uses a private state directory on development hosts and unique
workspace names in Termux.
"""

import argparse
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile


OUTPUT_LIMIT = 256 * 1024
SCRIPT_LIMIT = 64 * 1024


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Launcher:
    def __init__(self, program, state_dir, guest_timeout):
        self.program = program
        self.guest_timeout = guest_timeout
        self.env = dict(os.environ, KIRI_ANDROID_STATE_DIR=str(state_dir))
        self.env["KIRI_ANDROID_VM_HOST_ONLY"] = "not-for-the-guest"
        self.owned = []

    def call(self, *args, script=None, code=0, timeout=30):
        command = [self.program, *args]
        process = subprocess.run(
            command,
            input=script.encode() if script is not None else b"",
            capture_output=True,
            timeout=timeout,
            env=self.env,
        )
        context = f"{shlex.join(command)} (exit {process.returncode})"
        diagnostic = f"{context}\n{process.stdout[:600]!r}\n{process.stderr[:600]!r}"
        require(process.returncode == code, f"Expected exit {code}: {diagnostic}")
        try:
            result = json.loads(process.stdout.decode("utf-8"))
        except (UnicodeError, ValueError) as error:
            raise AssertionError(f"Expected a UTF-8 JSON response: {diagnostic}") from error
        require(isinstance(result, dict), f"Expected a JSON object: {diagnostic}")
        return result

    def run(self, script, *, name=None, seconds=None, status="exited", code=0):
        seconds = self.guest_timeout if seconds is None else seconds
        args = ["run"]
        if name is not None:
            args.append(name)
        args.extend(["--timeout", str(seconds)])
        result = self.call(*args, script=script, code=code, timeout=seconds + 30)
        require(result.get("status") == status, f"Expected {status}, got {result.get('status')}")
        if status == "error":
            require(bool(result.get("message")), "Run error has no diagnostic")
            return result
        require(isinstance(result.get("stdout"), str), "Run response omits stdout text")
        require(isinstance(result.get("stderr"), str), "Run response omits stderr text")
        if status == "exited":
            require(result.get("exit_code") == code, f"Expected guest exit {code}, got {result.get('exit_code')}")
        return result

    def workspaces(self):
        return self.call("list").get("workspaces")

    def create(self, name):
        self.call("create", name)
        self.owned.append(name)

    def delete(self, name):
        self.call("delete", name)
        self.owned.remove(name)


def smoke_test(client, host_only_file):
    doctor = client.call("doctor")
    require(doctor.get("status") == "ready", "Doctor did not report ready")
    require(doctor.get("network") is False and doctor.get("host_mounts") is False, "Doctor reports host channels")
    require(Path(doctor["state_dir"]).stat().st_mode & 0o077 == 0, "State directory is not private")
    before = client.workspaces()
    require(isinstance(before, list), "Workspace list is missing")
    prefix = "kiri-smoke-" + secrets.token_hex(4)
    first, second = f"{prefix}-a", f"{prefix}-b"
    expected_workspaces = sorted([*before, first, second])
    rejected = client.call("create", "../", code=125)
    require(rejected.get("status") == "error" and "workspace name" in rejected.get("message", ""),
            "Create did not reject a path at name validation")
    client.create(second)
    client.create(first)
    require(client.workspaces() == expected_workspaces, "Workspace list is missing names or out of order")
    print("PASS preflight, workspace creation, and name validation", flush=True)

    # Interrupt a fresh workspace, then check below that it still boots.
    client.run("sleep 30\n", name=first, seconds=1, status="timeout", code=124)
    host_path = shlex.quote(str(host_only_file))
    result = client.run(
        f"""set -eu
test "$(uname -s)" = Linux
test "$(id -u)" = 1000
test "$PWD" = /workspace
test "${{KIRI_ANDROID_VM_HOST_ONLY+x}}" = ''
test ! -e {host_path}
test "$(cut -s -d: -f1 /proc/net/dev | tr -d ' ')" = lo
test ! -r /dev/vda
test ! -w /dev/vda
for port in /dev/vport*; do
    test -e "$port"
    test ! -r "$port"
    test ! -w "$port"
done
test -r /proc/mounts
if grep -qE '[[:space:]](9p|virtiofs)[[:space:]]' /proc/mounts; then exit 98; fi
python3 - <<'PYTHON'
import json
import sqlite3
import ssl

db = sqlite3.connect(':memory:')
result = db.execute('select 40 + 2').fetchone()
assert json.loads(json.dumps(result)) == [42]
ssl.create_default_context()
PYTHON
printf '%s\\n' 'hello 世界 $(echo literal) $KIRI_ANDROID_VM_HOST_ONLY'
printf '%s\\n' 'guest stderr' >&2
printf '%s' 'persistent' > marker
sleep 300 &
exit 23
""",
        name=first,
        code=23,
    )
    require(result["stdout"] == "hello 世界 $(echo literal) $KIRI_ANDROID_VM_HOST_ONLY\n", "Guest stdout changed")
    require(result["stderr"] == "guest stderr\n", "Guest stderr was mixed with VM output")
    require(host_only_file.read_text() == "host fixture\n", "Host fixture unexpectedly changed")
    print("PASS Linux shell, Python, process cleanup, guest UID and output, and disabled host channels", flush=True)

    result = client.run("cat marker\n", name=first)
    require(result["stdout"] == "persistent", "Workspace data did not survive a second boot")
    client.run("test ! -e marker\n", name=second)
    client.run("set -e\ntest ! -e marker\nprintf '%s' transient > marker\n")
    client.run("test ! -e marker\n")
    require(client.workspaces() == expected_workspaces, "An ephemeral run registered a workspace")
    print("PASS named persistence and independent ephemeral workspaces", flush=True)

    result = client.run(f"yes kiri | head -c {OUTPUT_LIMIT + 4096}\n", status="output_limit", code=125)
    output_size = len(result["stdout"].encode()) + len(result["stderr"].encode())
    require(output_size <= OUTPUT_LIMIT, f"Run returned {output_size} bytes above the output limit")
    # The shell command is first, so the next run can detect accidental partial
    # execution of the oversized input.
    oversized = "touch oversize-ran\n#" + "x" * SCRIPT_LIMIT
    client.run(oversized, name=first, status="error", code=125)
    client.run("test ! -e oversize-ran\n", name=first)
    print("PASS timeout, output cap, and oversized input rejection", flush=True)

    client.delete(first)
    require(client.workspaces() == sorted([*before, second]), "Deleted workspace still appears")
    client.run("exit 0\n", name=first, status="error", code=125)
    client.delete(second)
    require(client.workspaces() == before, "Named workspaces remain after deletion")
    print("PASS workspace deletion", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("launcher", help="Path to kiri-android, or its name on PATH")
    parser.add_argument("--guest-timeout", type=int, default=90, help="Timeout for each normal guest run in seconds")
    args = parser.parse_args()
    if not 1 <= args.guest_timeout <= 300:
        parser.error("--guest-timeout must be between 1 and 300 seconds")

    with tempfile.TemporaryDirectory(prefix="kiri-android-test-") as temp_dir:
        temp = Path(temp_dir)
        host_only_file = temp / "host-only.txt"
        host_only_file.write_text("host fixture\n")
        # Keep the canary outside the launcher's state directory.
        client = Launcher(args.launcher, temp / "state", args.guest_timeout)
        try:
            smoke_test(client, host_only_file)
        finally:
            for name in client.owned[:]:
                try:
                    client.delete(name)
                except (AssertionError, OSError, subprocess.SubprocessError) as error:
                    print(f"Failed to clean up test workspace {name}: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
