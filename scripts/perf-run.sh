#!/bin/sh
# Runs Stowlark's speed check (scripts/perf.py) for two Linux builds: main's and
# a change's. Each engine runs in its own privileged container on this
# machine's Docker, with its socket in WORK, and the check talks to both.
#
#   scripts/perf-run.sh BASE_BIN HEAD_BIN WORK [RUNS]
#
# BASE_BIN and HEAD_BIN hold `stowlark` and `stowlark-init` (cargo xtask linux).
# A baseline from before the rename may contain `kiri` and `kiri-init`.
# Needs docker, python3 and strace, and root for strace and the sockets
# (it uses sudo when not root). Writes WORK/report.md; exits 1 when the
# change is past a limit.
set -eu
BASE_BIN=$(cd "$1" && pwd); HEAD_BIN=$(cd "$2" && pwd); WORK=$3; RUNS=${4:-400}
HERE=$(cd "$(dirname "$0")" && pwd)
POLICY=${STOWLARK_PERF_POLICY:-$HERE/perf.py}
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)

stop() {
  docker rm -f stowlark-perf-base stowlark-perf-head >/dev/null 2>&1 || true
  docker volume rm stowlark-perf-base-lib stowlark-perf-base-store stowlark-perf-head-lib stowlark-perf-head-store >/dev/null 2>&1 || true
}
trap stop EXIT
stop
for e in base head; do
  bin=$BASE_BIN; [ $e = head ] && bin=$HEAD_BIN
  brand=stowlark
  if [ ! -x "$bin/$brand" ] && [ -x "$bin/kiri" ]; then brand=kiri; fi
  $SUDO rm -rf "$WORK/$e-run"; mkdir -p "$WORK/$e-run"
  docker run -d --name stowlark-perf-$e --privileged --tmpfs /run \
    -v "stowlark-perf-$e-lib:/var/lib/$brand" -v "stowlark-perf-$e-store:/root/.local/share/$brand" \
    -v "$bin:/opt/stowlark:ro" -v "$WORK/$e-run:/root/.$brand/run" \
    alpine:3.21 "/opt/stowlark/$brand" daemon >/dev/null
done
pid() { docker inspect -f '{{.State.Pid}}' stowlark-perf-$1; }
for e in base head; do
  i=0; while [ ! -S "$WORK/$e-run/docker.sock" ]; do
    i=$((i + 1)); [ $i -gt 120 ] && { docker logs stowlark-perf-$e 2>&1 | tail -20; echo "the $e engine made no socket"; exit 2; }
    sleep 0.5
  done
done
python3 "$HERE/perf.py" sizes --base "$BASE_BIN" --head "$HEAD_BIN" --out "$WORK/sizes.json"
$SUDO python3 "$POLICY" bench --runs "$RUNS" --out "$WORK/results.json" \
  --base "$WORK/base-run/docker.sock:$(pid base)" --head "$WORK/head-run/docker.sock:$(pid head)"
status=0
python3 "$POLICY" report "$WORK/results.json" "$WORK/sizes.json" > "$WORK/report.md" || status=$?
cat "$WORK/report.md"
exit $status
