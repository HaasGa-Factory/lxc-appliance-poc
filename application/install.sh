#!/bin/bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: installer must run as root" >&2; exit 10; }
cd -- "$(dirname -- "$0")"
[[ -s app.py && -s VERSION && -s appliance.service ]] || {
  echo "ERROR: incomplete application release" >&2
  exit 11
}

echo "[..] Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y --no-install-recommends python3
echo "[OK] System packages"

getent group appliance >/dev/null || groupadd --system appliance
id appliance >/dev/null 2>&1 || useradd --system --gid appliance \
  --home-dir /opt/appliance --shell /usr/sbin/nologin appliance

install -d -o root -g root -m 0755 /opt/appliance
install -o root -g root -m 0755 app.py /opt/appliance/app.py
install -o root -g root -m 0644 VERSION /opt/appliance/VERSION
install -o root -g root -m 0644 appliance.service /etc/systemd/system/appliance.service
install -d -o root -g root -m 0755 /var/lib/appliance
printf '%s\n' "${APPLIANCE_BOOTSTRAP_VERSION:-unknown}" > /var/lib/appliance/bootstrap-version

systemctl daemon-reload
systemctl enable --now appliance.service
echo "[OK] Application"
echo "[OK] Service"
