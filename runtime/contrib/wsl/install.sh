#!/bin/sh
# Stowlark on Windows: run inside a WSL2 distro, as root, from the directory that
# holds the Linux build (cargo xtask windows; x86-64, or arm64 with --arch arm64):
#   wsl -d Ubuntu -u root sh ./install.sh
# Containers run on WSL2's Linux kernel. The daemon serves its unix socket
# only; stowlark-win.exe carries the Windows docker CLI's connections to it over
# `stowlark bridge` (see ../windows/stowlark.ps1). It is not served on TCP: WSL's
# localhost relay drops half-closes, which `docker run` needs.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install -m 755 "$here/stowlark" "$here/stowlark-init" /usr/local/bin/
if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/stowlark.service <<UNIT
[Unit]
Description=Stowlark container engine
After=network-online.target
[Service]
ExecStart=/usr/local/bin/stowlark daemon
Environment=HOME=/var/lib/stowlark-daemon
Delegate=yes
KillMode=mixed
Restart=on-failure
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable stowlark
  systemctl restart stowlark
else
  # No systemd in this distro: start Stowlark when WSL boots it.
  if ! grep -q 'stowlark daemon' /etc/wsl.conf 2>/dev/null; then
    printf '\n[boot]\ncommand = HOME=/var/lib/stowlark-daemon nohup /usr/local/bin/stowlark daemon >/var/log/stowlark.log 2>&1 &\n' >> /etc/wsl.conf
  fi
  pkill -f '/usr/local/bin/stowlark daemon' 2>/dev/null || true
  HOME=/var/lib/stowlark-daemon nohup /usr/local/bin/stowlark daemon >/var/log/stowlark.log 2>&1 &
fi
echo "Stowlark runs in WSL on /var/lib/stowlark-daemon/.stowlark/run/docker.sock"
