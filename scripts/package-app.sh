#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$PROJECT_DIR/application"
DIST_DIR="$PROJECT_DIR/dist/releases"
VERSION=$(cat "$APP_DIR/VERSION")
ARCHIVE="$DIST_DIR/appliance-app-$VERSION.tar.gz"
MANIFEST="$DIST_DIR/release.json"
SIGNATURE="$DIST_DIR/release.json.sig"
SIGNING_KEY=${SIGNING_KEY:-$PROJECT_DIR/keys/release.key}
BUILD_EPOCH=${SOURCE_DATE_EPOCH:-0}

for command in tar sha256sum stat jq minisign; do
  command -v "$command" >/dev/null || { echo "ERROR: missing prerequisite: $command" >&2; exit 1; }
done
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid application/VERSION" >&2; exit 1; }
[[ -s $SIGNING_KEY ]] || { echo "ERROR: missing signing key: $SIGNING_KEY" >&2; exit 1; }

mkdir -p "$DIST_DIR"
rm -f -- "$ARCHIVE.sha256"
tar --sort=name --mtime="@$BUILD_EPOCH" --owner=0 --group=0 --numeric-owner \
  -czf "$ARCHIVE" -C "$APP_DIR" VERSION app.py install.sh appliance.service
archive_sha=$(sha256sum "$ARCHIVE" | awk '{print $1}')
archive_size=$(stat -c %s "$ARCHIVE")
manifest_tmp=$(mktemp "$DIST_DIR/release.json.XXXXXX")
signature_tmp="$manifest_tmp.sig"
trap 'rm -f -- "$manifest_tmp" "$signature_tmp"' EXIT
jq -n --arg version "$VERSION" --arg filename "$(basename "$ARCHIVE")" \
  --arg sha256 "$archive_sha" --argjson size "$archive_size" \
  '{schema:1, channel:"stable", version:$version, filename:$filename, sha256:$sha256, size:$size}' \
  > "$manifest_tmp"
minisign -S -s "$SIGNING_KEY" -m "$manifest_tmp" -x "$signature_tmp" \
  -t "LXC appliance stable release $VERSION"
mv -f "$signature_tmp" "$SIGNATURE"
mv -f "$manifest_tmp" "$MANIFEST"
trap - EXIT
echo "Created: $ARCHIVE"
echo "SHA256: $archive_sha"
echo "Manifest: $MANIFEST"
echo "Signature: $SIGNATURE"
