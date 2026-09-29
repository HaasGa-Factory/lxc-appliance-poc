#!/bin/bash
set -Eeuo pipefail

STATE_DIR=/var/lib/appliance
LOG_FILE=/var/log/appliance-bootstrap.log
CONFIG=/etc/appliance/appliance.conf
PUBLIC_KEY=/usr/lib/appliance-bootstrap/release.pub
BOOTSTRAP_VERSION=$(cat /usr/lib/appliance-bootstrap/VERSION)

install -d -m 0755 "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "[ERROR] Bootstrap failed (exit $rc); it will retry at the next service start or reboot"; exit "$rc"' ERR

[[ ! -e "$STATE_DIR/installed" ]] || exit 0
[[ -r "$CONFIG" ]] || { echo "ERROR: missing $CONFIG" >&2; exit 20; }
# shellcheck source=/dev/null
source "$CONFIG"
[[ $RELEASE_BASE_URL =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || {
  echo "ERROR: RELEASE_BASE_URL must be a safe HTTP(S) URL" >&2
  exit 21
}
[[ ${RELEASE_CHANNEL:-} == stable ]] || { echo "ERROR: unsupported release channel" >&2; exit 22; }
[[ -s $PUBLIC_KEY ]] || { echo "ERROR: missing trusted public key" >&2; exit 23; }
[[ $RELEASE_BASE_URL == https://* || $RELEASE_BASE_URL =~ ^http://(localhost|127\.0\.0\.1|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] || {
  echo "ERROR: HTTP is allowed only for localhost or private LAN addresses" >&2
  exit 24
}
# shellcheck source=release-lib.sh
source /usr/lib/appliance-bootstrap/release-lib.sh

cat <<EOF
----------------------------------------
       LXC APPLIANCE POC SETUP
----------------------------------------

Bootstrap : $BOOTSTRAP_VERSION
System    : Debian 13
Arch      : $(dpkg --print-architecture)
EOF

host=${RELEASE_BASE_URL#*://}
host=${host%%[:/]*}
echo "[..] Waiting for network and DNS"
for attempt in $(seq 1 30); do
  if ip route show default | grep -q . && getent ahosts "$host" >/dev/null 2>&1; then
    echo "[OK] Network"
    break
  fi
  [[ $attempt -lt 30 ]] || { echo "ERROR: network unavailable after 5 minutes" >&2; exit 30; }
  sleep 10
done

workdir=$(mktemp -d /var/tmp/appliance-firstboot.XXXXXX)
trap 'rm -rf -- "$workdir"' EXIT

echo "[..] Downloading signed release manifest"
curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
  --connect-timeout 15 --max-time 60 --output "$workdir/release.json" \
  "${RELEASE_BASE_URL%/}/release.json"
curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
  --connect-timeout 15 --max-time 60 --output "$workdir/release.json.sig" \
  "${RELEASE_BASE_URL%/}/release.json.sig"
echo "[OK] Repository"

verify_manifest_signature "$workdir/release.json" "$workdir/release.json.sig" "$PUBLIC_KEY" || {
  echo "ERROR: invalid release manifest signature" >&2
  exit 31
}
echo "[OK] Manifest signature"

IFS=$'\t' read -r APP_VERSION archive expected_sha expected_size \
  < <(manifest_fields "$workdir/release.json" "$RELEASE_CHANNEL") || {
    echo "ERROR: invalid or unsupported release manifest" >&2
    exit 32
  }
[[ -n ${expected_size:-} ]] || { echo "ERROR: incomplete release manifest" >&2; exit 32; }

echo "[..] Downloading application $APP_VERSION"
curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
  --connect-timeout 15 --max-time 300 --output "$workdir/$archive" \
  "${RELEASE_BASE_URL%/}/$archive"
verify_archive "$workdir/$archive" "$expected_sha" "$expected_size" || {
  echo "ERROR: application archive size or SHA256 mismatch" >&2
  exit 33
}
echo "[OK] Archive integrity"

mkdir "$workdir/release"
tar -xzf "$workdir/$archive" -C "$workdir/release" --no-same-owner --no-same-permissions
[[ -s "$workdir/release/install.sh" ]] || { echo "ERROR: release has no install.sh" >&2; exit 34; }
APPLIANCE_BOOTSTRAP_VERSION="$BOOTSTRAP_VERSION" bash "$workdir/release/install.sh"

echo "[..] Health check"
systemctl is-active --quiet appliance.service || { echo "ERROR: appliance.service is not active" >&2; exit 40; }
for attempt in $(seq 1 20); do
  response=$(curl --fail --silent --show-error --max-time 3 http://127.0.0.1:8080/health 2>/dev/null || true)
  [[ $response == "OK" ]] && break
  [[ $attempt -lt 20 ]] || { echo "ERROR: health check failed" >&2; exit 41; }
  sleep 1
done
echo "[OK] Health check"

printf 'application=%s\nbootstrap=%s\ninstalled_at=%s\n' \
  "$APP_VERSION" "$BOOTSTRAP_VERSION" "$(date --iso-8601=seconds)" > "$STATE_DIR/installed.tmp"
mv -f "$STATE_DIR/installed.tmp" "$STATE_DIR/installed"

ip_address=$(ip -4 -o addr show scope global | awk 'NR == 1 {split($4,a,"/"); print a[1]}')
cat <<EOF
----------------------------------------
      INSTALLATION COMPLETED
----------------------------------------

Application : $APP_VERSION
Hostname    : $(hostname)
IP          : ${ip_address:-unavailable}
Web UI      : http://${ip_address:-IP_DU_LXC}:8080

The appliance is ready.
EOF
