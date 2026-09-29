#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$PROJECT_DIR/VERSION")
DIST_DIR="$PROJECT_DIR/dist"
OUTPUT="$DIST_DIR/appliance-poc_${VERSION}_amd64.tar.zst"
OUTPUT_TMP="$OUTPUT.tmp"
PUBLIC_KEY=${PUBLIC_KEY:-$PROJECT_DIR/keys/release.pub}
SUITE=${DEBIAN_SUITE:-trixie}
MIRROR=${DEBIAN_MIRROR:-https://deb.debian.org/debian}
BUILD_EPOCH=${SOURCE_DATE_EPOCH:-0}
: "${RELEASE_BASE_URL:?Set RELEASE_BASE_URL to the directory containing release.json}"

[[ $EUID -eq 0 ]] || { echo "ERROR: run this build as root on Debian/Proxmox" >&2; exit 1; }
[[ $RELEASE_BASE_URL =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || {
  echo "ERROR: RELEASE_BASE_URL contains unsupported characters" >&2
  exit 1
}
for command in debootstrap tar zstd sha256sum chroot; do
  command -v "$command" >/dev/null || { echo "ERROR: missing prerequisite: $command" >&2; exit 1; }
done
[[ $(dpkg --print-architecture) == amd64 ]] || { echo "ERROR: this POC build requires an amd64 host" >&2; exit 1; }
[[ -s $PUBLIC_KEY ]] || { echo "ERROR: missing public key: $PUBLIC_KEY" >&2; exit 1; }

ROOTFS=$(mktemp -d /var/tmp/appliance-rootfs.XXXXXX)
cleanup() { rm -rf -- "$ROOTFS"; rm -f -- "$OUTPUT_TMP"; }
trap cleanup EXIT

echo "Building Debian $SUITE minimal rootfs in $ROOTFS"
debootstrap --arch=amd64 --variant=minbase \
  --include=systemd-sysv,ca-certificates,curl,iproute2,ifupdown,dhcpcd-base,minisign,jq \
  "$SUITE" "$ROOTFS" "$MIRROR"
echo "[OK] Debian rootfs"

install -d -m 0755 "$ROOTFS/usr/lib/appliance-bootstrap" "$ROOTFS/etc/appliance" \
  "$ROOTFS/etc/systemd/system" "$ROOTFS/etc/systemd/system/multi-user.target.wants"
install -m 0755 "$PROJECT_DIR/bootstrap/firstboot.sh" "$ROOTFS/usr/lib/appliance-bootstrap/firstboot.sh"
install -m 0644 "$PROJECT_DIR/bootstrap/release-lib.sh" "$ROOTFS/usr/lib/appliance-bootstrap/release-lib.sh"
install -m 0644 "$PROJECT_DIR/bootstrap/VERSION" "$ROOTFS/usr/lib/appliance-bootstrap/VERSION"
install -m 0644 "$PUBLIC_KEY" "$ROOTFS/usr/lib/appliance-bootstrap/release.pub"
install -m 0644 "$PROJECT_DIR/systemd/appliance-firstboot.service" "$ROOTFS/etc/systemd/system/appliance-firstboot.service"
ln -s ../appliance-firstboot.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/appliance-firstboot.service"
echo "[OK] Bootstrap and trust key"

sed -e "s|@RELEASE_BASE_URL@|$RELEASE_BASE_URL|g" \
    "$PROJECT_DIR/bootstrap/appliance.conf.in" > "$ROOTFS/etc/appliance/appliance.conf"
chmod 0644 "$ROOTFS/etc/appliance/appliance.conf"
echo "[OK] Release configuration"

printf 'appliance\n' > "$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 appliance\n' > "$ROOTFS/etc/hosts"
printf 'auto lo\niface lo inet loopback\n\nsource /etc/network/interfaces.d/*\n' > "$ROOTFS/etc/network/interfaces"
printf 'deb %s %s main\ndeb %s %s-updates main\ndeb http://security.debian.org/debian-security %s-security main\n' \
  "$MIRROR" "$SUITE" "$MIRROR" "$SUITE" "$SUITE" > "$ROOTFS/etc/apt/sources.list"
: > "$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/dbus/machine-id"
chroot "$ROOTFS" apt-get clean
echo "[OK] Rootfs configuration"
rm -rf "$ROOTFS/var/lib/apt/lists/"* "$ROOTFS/var/cache/apt/archives/"*.deb \
  "$ROOTFS/var/log/"*.log "$ROOTFS/var/log/apt/"* "$ROOTFS/tmp/"* "$ROOTFS/var/tmp/"*
echo "[OK] Rootfs cleanup"

mkdir -p "$DIST_DIR"
tar --sort=name --mtime="@$BUILD_EPOCH" --clamp-mtime --owner=0 --group=0 --numeric-owner \
  --acls --xattrs --one-file-system -C "$ROOTFS" -cf - . | zstd -19 -T0 -f -o "$OUTPUT_TMP"
echo "[OK] Rootfs archive"
mv -f "$OUTPUT_TMP" "$OUTPUT"
output_sha=$(sha256sum "$OUTPUT" | awk '{print $1}')
printf '%s  %s\n' "$output_sha" "$(basename "$OUTPUT")" > "$OUTPUT.sha256"

echo "Version : $VERSION"
echo "Path    : $OUTPUT"
echo "Size    : $(du -h "$OUTPUT" | awk '{print $1}')"
echo "SHA256  : $output_sha"
