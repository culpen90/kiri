# Stowlark on a Linux host as an RPM: `stowlark` (engine + docker CLI, Compose,
# buildx) or `stowlark-lite` (engine only), chosen by packaging/linux/build.sh
# through stowlark_name and with_cli. Static (musl) binaries: no runtime
# dependencies, no debuginfo. With with_window, `stowlark` also carries the
# window (stowlark built against GTK 3 and WebKitGTK 4.1), which needs those.
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_mangle_shebangs %{nil}

Name:           %{stowlark_name}
Version:        %{stowlark_version}
Release:        1%{?dist}
Summary:        Tiny, fast container runtime (Docker API)%{!?with_cli:, engine only}
License:        Apache-2.0
URL:            https://github.com/culpen90/stowlark
Source0:        stowlark
Source1:        stowlark-init
Source2:        stowlark.service
Source3:        LICENSE
Source4:        NOTICE
Source18:       dev.stowlark.host-access.policy
%if 0%{?with_cli}
Source5:        docker
Source6:        docker-compose
Source7:        docker-buildx
Source8:        docker-wrapper
Conflicts:      stowlark-lite
%if 0%{?with_window}
Source9:        stowlark-window
Source10:       dev.stowlark.Stowlark.desktop
Source11:       stowlark-app-icon.svg
Source12:       stowlark-app-icon-16.png
Source13:       stowlark-app-icon-32.png
Source14:       stowlark-app-icon-64.png
Source15:       stowlark-app-icon-128.png
Source16:       stowlark-app-icon-256.png
Source17:       stowlark-app-icon-512.png
Source19:       dev.stowlark.Stowlark.metainfo.xml
Requires:       gtk3
Requires:       webkit2gtk4.1
# The window's setup checklist asks for the password through pkexec.
Recommends:     polkit
%endif
%else
Conflicts:      stowlark
%endif
BuildArch:      %{stowlark_arch}
# Static binaries: nothing to find by scanning them.
AutoReq:        no
Requires(pre):  shadow-utils
%if 0%{?with_cli}
Requires(post): %{_sbindir}/update-alternatives
Requires(preun): %{_sbindir}/update-alternatives
Requires(posttrans): %{_sbindir}/update-alternatives
%endif

%description
Stowlark runs containers on this machine's kernel and speaks the Docker API on
/run/stowlark/docker.sock for users in the stowlark group (and at
/var/run/docker.sock while no Docker engine has it). No VM, no daemon other
than stowlark itself. Members of the stowlark group can run containers as root on
this machine; treat it like the docker group.
%if 0%{?with_cli}
This package brings the docker CLI, Compose and buildx with it, as Stowlark.app
does on the Mac: `docker run` works right after installing. A docker CLI from
another package keeps precedence on PATH.
%if 0%{?with_window}
Stowlark's window is in the app menu, or: stowlark ui
%endif
%else
Engine only: point any docker CLI at it with
  docker context create stowlark --docker host=unix:///run/stowlark/docker.sock
%endif

%prep

%build

%install
install -D -m 755 %{SOURCE0} %{buildroot}%{_bindir}/stowlark
install -D -m 755 %{SOURCE1} %{buildroot}%{_bindir}/stowlark-init
install -D -m 644 %{SOURCE2} %{buildroot}%{_unitdir}/stowlark.service
install -D -m 644 %{SOURCE3} %{buildroot}%{_licensedir}/%{name}/LICENSE
install -D -m 644 %{SOURCE4} %{buildroot}%{_licensedir}/%{name}/NOTICE
install -D -m 644 %{SOURCE18} %{buildroot}%{_datadir}/polkit-1/actions/dev.stowlark.host-access.policy
%if 0%{?with_cli}
install -D -m 755 %{SOURCE5} %{buildroot}/usr/libexec/stowlark/bin/docker
install -D -m 755 %{SOURCE8} %{buildroot}/usr/libexec/stowlark/docker
install -D -m 755 %{SOURCE6} %{buildroot}/usr/libexec/stowlark/cli-plugins/docker-compose
install -D -m 755 %{SOURCE7} %{buildroot}/usr/libexec/stowlark/cli-plugins/docker-buildx
%endif
%if 0%{?with_window}
install -D -m 755 %{SOURCE9} %{buildroot}/usr/lib/stowlark/stowlark-window
install -D -m 644 %{SOURCE10} %{buildroot}%{_datadir}/applications/dev.stowlark.Stowlark.desktop
install -D -m 644 %{SOURCE19} %{buildroot}%{_datadir}/metainfo/dev.stowlark.Stowlark.metainfo.xml
install -D -m 644 %{SOURCE11} %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/stowlark.svg
for s in 16 32 64 128 256 512; do
  install -D -m 644 %{_sourcedir}/stowlark-app-icon-$s.png %{buildroot}%{_datadir}/icons/hicolor/${s}x${s}/apps/stowlark.png
done
%endif

%pre
getent group stowlark >/dev/null || groupadd --system stowlark
exit 0

%post
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || :
  # Not started or enabled: it starts when someone sets Stowlark up (the window's
  # Allow access, or `stowlark host-access`). An upgrade ($1 >= 2) leaves a
  # running engine alone: it keeps the old binary until it restarts, which
  # stops its containers.
  if [ "$1" -ge 2 ] && systemctl is-active -q stowlark.service; then
    echo "Stowlark is upgraded. The engine keeps running the old version until it restarts:"
    echo "  sudo systemctl restart stowlark   (running containers stop; those with a restart policy start again)"
    echo "or open Stowlark and choose Restart engine. The next boot starts the new one either way."
  fi
fi
# A `stowlark` before /usr/bin on PATH runs instead of this package's.
for d in /usr/local/sbin /usr/local/bin; do
  if [ -e "$d/stowlark" ] && [ "$(readlink -f "$d/stowlark")" != /usr/bin/stowlark ]; then
    echo "Warning: $d/stowlark comes before /usr/bin/stowlark on PATH, so it runs instead of this Stowlark."
    echo "  If it's an older Stowlark, remove it:  sudo rm $d/stowlark"
  fi
done
%if 0%{?with_cli}
# Only a /usr/bin/docker that is absent or already an alternatives link; a
# real file, or a symlink another package or the administrator put there, is
# left alone: Stowlark's CLI must not take over someone else's docker.
free=1
if [ -e /usr/bin/docker ] || [ -L /usr/bin/docker ]; then
  case "$(readlink /usr/bin/docker 2>/dev/null)" in /etc/alternatives/*) ;; *) free=0 ;; esac
fi
if [ "$free" = 1 ]; then
  %{_sbindir}/update-alternatives --install /usr/bin/docker docker /usr/libexec/stowlark/docker 10 || :
  echo "Stowlark is installed with its own docker CLI (docker, docker compose, docker buildx)."
else
  echo "Stowlark is installed; /usr/bin/docker belongs to something else and stays. Stowlark's CLI: /usr/libexec/stowlark/docker"
fi
%else
echo "Stowlark is installed (engine only). Point a docker CLI at it:"
echo "  docker context create stowlark --docker host=unix:///run/stowlark/docker.sock && docker context use stowlark"
%endif
echo "To use it without sudo:  sudo stowlark host-access \$USER   (or open Stowlark, which sets it up)"
echo "Members of the stowlark group can run containers as root on this machine; treat it like the docker group."
echo "While no Docker engine has /var/run/docker.sock, it leads to Stowlark too (for Testcontainers, docker-py and other tools that ignore docker contexts)."
exit 0

%preun
if [ "$1" -eq 0 ]; then
  if [ -d /run/systemd/system ]; then
    systemctl disable --now stowlark.service >/dev/null 2>&1 || :
  fi
  # Everything else it runs: a window or stowlark command still open.
  for sig in TERM KILL; do
    pkill -$sig -f '^/usr/lib/stowlark/stowlark-window( |$)' >/dev/null 2>&1 || :
    pkill -$sig -f '^(/usr)?/bin/stowlark( |$)' >/dev/null 2>&1 || :
    [ "$sig" = KILL ] || sleep 1
  done
%if 0%{?with_cli}
  %{_sbindir}/update-alternatives --remove docker /usr/libexec/stowlark/docker || :
  for p in docker-compose docker-buildx; do
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/stowlark/cli-plugins/$p || :
  done
%endif
fi
exit 0

%if 0%{?with_cli}
%posttrans
# Compose and buildx into /usr/lib/docker/cli-plugins where the slot is free
# and Docker's own copy isn't in another of the CLI's plugin folders; else
# Stowlark's link goes and Docker's copy is used. In %posttrans because an
# upgrade from a Stowlark that put real files there erases them only after %post;
# again whenever another package changes Docker's plugin folders.
mkdir -p /usr/lib/docker/cli-plugins
for p in docker-compose docker-buildx; do
  l=/usr/lib/docker/cli-plugins/$p
  theirs=
  for d in /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
    [ -e $d/$p ] && theirs=1
  done
  if [ -z "$theirs" ] && { [ ! -e $l ] && [ ! -L $l ] || readlink $l 2>/dev/null | grep -q '^/etc/alternatives/'; }; then
    %{_sbindir}/update-alternatives --install $l $p /usr/libexec/stowlark/cli-plugins/$p 10 || :
  elif %{_sbindir}/update-alternatives --display $p 2>/dev/null | grep -q "^/usr/libexec/stowlark/cli-plugins/$p "; then
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/stowlark/cli-plugins/$p || :
  fi
done
exit 0

%filetriggerin -- /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
mkdir -p /usr/lib/docker/cli-plugins
for p in docker-compose docker-buildx; do
  l=/usr/lib/docker/cli-plugins/$p
  theirs=
  for d in /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
    [ -e $d/$p ] && theirs=1
  done
  if [ -z "$theirs" ] && { [ ! -e $l ] && [ ! -L $l ] || readlink $l 2>/dev/null | grep -q '^/etc/alternatives/'; }; then
    %{_sbindir}/update-alternatives --install $l $p /usr/libexec/stowlark/cli-plugins/$p 10 || :
  elif %{_sbindir}/update-alternatives --display $p 2>/dev/null | grep -q "^/usr/libexec/stowlark/cli-plugins/$p "; then
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/stowlark/cli-plugins/$p || :
  fi
done
exit 0

%filetriggerpostun -- /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
mkdir -p /usr/lib/docker/cli-plugins
for p in docker-compose docker-buildx; do
  l=/usr/lib/docker/cli-plugins/$p
  theirs=
  for d in /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
    [ -e $d/$p ] && theirs=1
  done
  if [ -z "$theirs" ] && { [ ! -e $l ] && [ ! -L $l ] || readlink $l 2>/dev/null | grep -q '^/etc/alternatives/'; }; then
    %{_sbindir}/update-alternatives --install $l $p /usr/libexec/stowlark/cli-plugins/$p 10 || :
  elif %{_sbindir}/update-alternatives --display $p 2>/dev/null | grep -q "^/usr/libexec/stowlark/cli-plugins/$p "; then
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/stowlark/cli-plugins/$p || :
  fi
done
exit 0
%endif

%postun
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || :
fi
if [ "$1" -eq 0 ]; then
  echo "Stowlark is removed; its images, containers and volumes stay in /var/lib/stowlark"
fi
exit 0

%files
%license %{_licensedir}/%{name}/LICENSE
%license %{_licensedir}/%{name}/NOTICE
%{_bindir}/stowlark
%{_bindir}/stowlark-init
%{_unitdir}/stowlark.service
%{_datadir}/polkit-1/actions/dev.stowlark.host-access.policy
%if 0%{?with_cli}
%dir /usr/libexec/stowlark
%dir /usr/libexec/stowlark/bin
/usr/libexec/stowlark/bin/docker
/usr/libexec/stowlark/docker
%dir /usr/libexec/stowlark/cli-plugins
/usr/libexec/stowlark/cli-plugins/docker-compose
/usr/libexec/stowlark/cli-plugins/docker-buildx
%endif
%if 0%{?with_window}
%dir /usr/lib/stowlark
/usr/lib/stowlark/stowlark-window
%{_datadir}/applications/dev.stowlark.Stowlark.desktop
%{_datadir}/icons/hicolor/*/apps/stowlark.*
%{_datadir}/metainfo/dev.stowlark.Stowlark.metainfo.xml
%endif
