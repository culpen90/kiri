#!/bin/bash
# Checks the packages build.sh made, without touching this machine's own Stowlark:
#   DOCKER_HOST=unix:///run/stowlark/docker.sock packaging/linux/test.sh <outdir> [docker CLI] [static docker CLI dir]
# Needs any Docker-compatible engine (Stowlark itself works) and, for the package
# listings, dpkg-deb and rpm on this machine.
# For each of stowlark-lite and stowlark:
# 1. lists the .deb and .rpm and their scripts;
# 2. in a privileged Ubuntu container: installs the .deb, starts the engine the
#    way the unit would (no systemd there), runs a container through it (the
#    full package with its own docker on PATH; lite with the static CLI dir
#    given as the 3rd argument), then removes and purges the package;
# 3. in a Fedora container: installs, verifies and removes the .rpm.
# Exit status is the number of failed checks.
set -u
out=$(cd "$1" && pwd) docker=${2:-docker} clidir=${3:-}
fail=0
# Scratch files of this run's own, not fixed names in /tmp another user could plant.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ok() { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
step() { # container name command
  if $docker exec "$1" bash -c "$3" >"$tmp/step.log" 2>&1; then ok "$2"; else bad "$2"; sed 's/^/         /' "$tmp/step.log" | tail -5; fi
}

test_package() { # name full(0|1)
  local name=$1 full=$2
  local deb rpm; deb=$(ls "$out"/${name}_*.deb) rpm=$(ls "$out"/${name}-[0-9]*.rpm)
  echo
  echo "#### $name"
  echo "== packages"
  dpkg-deb -I "$deb" | sed -n '2,9p' | sed 's/^/     /'
  check "deb lists stowlark, stowlark-init, unit, copyright" "dpkg-deb -c '$deb' | grep -q 'usr/bin/stowlark$' && dpkg-deb -c '$deb' | grep -q usr/bin/stowlark-init && dpkg-deb -c '$deb' | grep -q lib/systemd/system/stowlark.service && dpkg-deb -c '$deb' | grep -q usr/share/doc/$name/copyright"
  check "deb carries LICENSE and NOTICE" "dpkg-deb -c '$deb' | grep -q usr/share/doc/$name/LICENSE && dpkg-deb -c '$deb' | grep -q usr/share/doc/$name/NOTICE"
  if [ "$full" = 1 ]; then
    check "deb carries docker, compose, buildx" "dpkg-deb -c '$deb' | grep -q usr/libexec/stowlark/bin/docker && dpkg-deb -c '$deb' | grep -q usr/libexec/stowlark/cli-plugins/docker-compose && dpkg-deb -c '$deb' | grep -q usr/libexec/stowlark/cli-plugins/docker-buildx && ! dpkg-deb -c '$deb' | grep -q usr/lib/docker/"
  else
    check "deb carries no docker CLI" "! dpkg-deb -c '$deb' | grep -q libexec/stowlark"
  fi
  check "deb maintainer scripts" "rm -rf '$tmp/deb-ctl' && dpkg-deb -e '$deb' '$tmp/deb-ctl' && test -x '$tmp/deb-ctl/postinst' -a -x '$tmp/deb-ctl/prerm' -a -x '$tmp/deb-ctl/postrm'"
  rpm -qpi "$rpm" 2>/dev/null | grep -E '^(Name|Version|Release|Architecture|License|Size|Summary)' | sed 's/^/     /'
  check "rpm lists stowlark, stowlark-init, unit, licences" "rpm -qpl '$rpm' | grep -q '^/usr/bin/stowlark$' && rpm -qpl '$rpm' | grep -q /usr/bin/stowlark-init && rpm -qpl '$rpm' | grep -q /usr/lib/systemd/system/stowlark.service && rpm -qpl '$rpm' | grep -q LICENSE && rpm -qpl '$rpm' | grep -q NOTICE"
  check "rpm needs nothing beyond rpmlib, shadow-utils, /bin/sh, update-alternatives" "! rpm -qp --requires '$rpm' | grep -v -E '^(rpmlib|shadow-utils|/bin/sh|/usr/sbin/update-alternatives|rtld)'"
  check "rpm scripts: pre, post, preun, postun" "rpm -qp --scripts '$rpm' | grep -q preinstall && rpm -qp --scripts '$rpm' | grep -q postinstall && rpm -qp --scripts '$rpm' | grep -q preuninstall && rpm -qp --scripts '$rpm' | grep -q postuninstall"

  echo "== .deb in a privileged Ubuntu container"
  local c=stowlark-deb-test-$name debname; debname=$(basename "$deb")
  local climount=()
  [ -n "$clidir" ] && climount=(-v "$(cd "$clidir" && pwd):/opt/docker:ro")
  $docker rm -f "$c" >/dev/null 2>&1
  $docker run -d --name "$c" --privileged --tmpfs /run --tmpfs /tmp -v "$out:/pkg:ro" "${climount[@]}" ubuntu:24.04 sleep infinity >/dev/null
  step "$c" "dpkg -i" "dpkg -i /pkg/$debname"
  step "$c" "/usr/bin/stowlark, stowlark-init, unit, copyright" "test -x /usr/bin/stowlark -a -x /usr/bin/stowlark-init -a -f /lib/systemd/system/stowlark.service -a -f /usr/share/doc/$name/copyright"
  step "$c" "group stowlark made by postinst" "getent group stowlark"
  step "$c" "engine starts as the unit would" "mkdir -p /run/stowlark /var/lib/stowlark-daemon && chmod 755 /run/stowlark && (STOWLARK_SOCKET=/run/stowlark/docker.sock STOWLARK_SOCKET_GROUP=stowlark HOME=/var/lib/stowlark-daemon nohup /usr/bin/stowlark daemon >/var/log/stowlark.log 2>&1 &) && for i in \$(seq 30); do [ -S /run/stowlark/docker.sock ] && exit 0; sleep 1; done; cat /var/log/stowlark.log; exit 1"
  step "$c" "socket owned by group stowlark, mode 660" "stat -c '%G %a' /run/stowlark/docker.sock | grep -q '^stowlark 660'"
  step "$c" "/var/lib/stowlark is 710, not world-readable" "test \"\$(stat -c %a /var/lib/stowlark)\" = 710"
  local cli
  if [ "$full" = 1 ]; then
    step "$c" "/usr/bin/docker is Stowlark's, through update-alternatives" "readlink -f /usr/bin/docker | grep -q /usr/libexec/stowlark/docker"
    step "$c" "docker version, no DOCKER_HOST needed" "for i in \$(seq 30); do docker version >/dev/null 2>&1 && break; sleep 1; done; docker version --format '{{.Server.Os}}' | grep -q linux"
    step "$c" "docker compose and buildx plugins found" "docker compose version | grep -q 'v5' && docker buildx version | grep -q 'v0.38'"
    step "$c" "DOCKER_HOST set by the user wins over Stowlark's default" "DOCKER_HOST=unix:///nonexistent docker version 2>&1 | grep -q nonexistent"
    cli=docker
  elif [ -n "$clidir" ]; then
    step "$c" "docker version through the socket" "for i in \$(seq 30); do /opt/docker/docker -H unix:///run/stowlark/docker.sock version >/dev/null 2>&1 && break; sleep 1; done; /opt/docker/docker -H unix:///run/stowlark/docker.sock version --format '{{.Server.Os}}' | grep -q linux"
    cli="/opt/docker/docker -H unix:///run/stowlark/docker.sock"
  fi
  if [ -n "${cli:-}" ]; then
    # Nested in a container, overlay on overlay: the engine may answer the API
    # yet not run a container. test-host.sh proves that on a real host.
    step "$c" "docker run alpine on the packaged engine (nested; may be denied by the host)" "timeout -s KILL 120 $cli run --rm alpine cat /etc/alpine-release | grep -q '^3\.'"
  else
    echo "  [skip] docker run (pass a static docker CLI dir as the 3rd argument)"
  fi
  step "$c" "dpkg -r removes binaries, keeps data" "dpkg -r $name && test ! -e /usr/bin/stowlark -a ! -e /lib/systemd/system/stowlark.service && test -d /var/lib/stowlark-daemon"
  [ "$full" = 1 ] && step "$c" "docker alternative withdrawn" "test ! -e /usr/bin/docker"
  step "$c" "dpkg -P drops data and group" "dpkg -P $name && test ! -e /var/lib/stowlark -a ! -e /var/lib/stowlark-daemon && ! getent group stowlark"
  $docker rm -f "$c" >/dev/null 2>&1

  echo "== .rpm in a Fedora container"
  local rpmname; rpmname=$(basename "$rpm")
  $docker run --rm -v "$out:/pkg:ro" fedora:41 bash -c "
    rpm -ivh /pkg/$rpmname >/tmp/i.log 2>&1 || { cat /tmp/i.log; exit 1; }
    test -x /usr/bin/stowlark && test -x /usr/bin/stowlark-init && test -f /usr/lib/systemd/system/stowlark.service && test -f /usr/share/licenses/$name/LICENSE || exit 2
    getent group stowlark >/dev/null || exit 3
    rpm -q $name >/dev/null || exit 4
    rpm -V $name || exit 7
    if [ $full = 1 ]; then readlink -f /usr/bin/docker | grep -q /usr/libexec/stowlark/docker || exit 8; docker --version | grep -q 'version 29' || exit 9; fi
    rpm -e $name >/tmp/e.log 2>&1 || { cat /tmp/e.log; exit 5; }
    test ! -e /usr/bin/stowlark && test ! -e /usr/lib/systemd/system/stowlark.service && test ! -e /usr/bin/docker || exit 6
    echo RPM-OK" >"$tmp/rpm-test.log" 2>&1
  local code=$?
  check "rpm -ivh lays files, group, verifies$([ "$full" = 1 ] && echo ', docker on PATH'), rpm -e removes cleanly (exit $code)" "test $code -eq 0 && grep -q RPM-OK '$tmp/rpm-test.log'"
  [ $code -ne 0 ] && sed 's/^/         /' "$tmp/rpm-test.log" | tail -5
}

test_package stowlark-lite 0
ls "$out"/stowlark_*.deb >/dev/null 2>&1 && test_package stowlark 1
echo
echo "== $fail failed"
exit $fail
