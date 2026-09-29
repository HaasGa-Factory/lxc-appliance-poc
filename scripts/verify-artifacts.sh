#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$PROJECT_DIR/VERSION")
APP_VERSION=$(cat "$PROJECT_DIR/application/VERSION")
TEMPLATE="$PROJECT_DIR/dist/appliance-poc_${VERSION}_amd64.tar.zst"
RELEASE_DIR="$PROJECT_DIR/dist/releases"
ARCHIVE="$RELEASE_DIR/appliance-app-$APP_VERSION.tar.gz"
MANIFEST="$RELEASE_DIR/release.json"
SIGNATURE="$RELEASE_DIR/release.json.sig"
PUBLIC_KEY="$PROJECT_DIR/keys/release.pub"
# shellcheck source=../bootstrap/release-lib.sh
source "$PROJECT_DIR/bootstrap/release-lib.sh"

for file in "$TEMPLATE" "$ARCHIVE" "$MANIFEST" "$SIGNATURE" "$PUBLIC_KEY"; do
  [[ -s $file ]] || { echo "ERROR: missing artifact: $file" >&2; exit 1; }
done

verify_manifest_signature "$MANIFEST" "$SIGNATURE" "$PUBLIC_KEY"
IFS=$'\t' read -r manifest_version filename sha size < <(manifest_fields "$MANIFEST" stable)
[[ $manifest_version == "$APP_VERSION" && $filename == "$(basename "$ARCHIVE")" ]]
verify_archive "$ARCHIVE" "$sha" "$size"
echo "[OK] Signed release chain"

zstd -q -t "$TEMPLATE"
listing=$(tar --zstd -tf "$TEMPLATE")
for required in \
  ./etc/os-release \
  ./etc/appliance/appliance.conf \
  ./etc/systemd/system/appliance-firstboot.service \
  ./usr/lib/appliance-bootstrap/firstboot.sh \
  ./usr/lib/appliance-bootstrap/release-lib.sh \
  ./usr/lib/appliance-bootstrap/release.pub; do
  grep -Fxq "$required" <<< "$listing" || { echo "ERROR: template missing $required" >&2; exit 1; }
done
if grep -Eq '^\./(opt/appliance|usr/bin/python|.*release\.key)' <<< "$listing"; then
  echo "ERROR: template contains application, Python, or private key" >&2
  exit 1
fi
cmp -s "$PUBLIC_KEY" <(tar --zstd -xOf "$TEMPLATE" ./usr/lib/appliance-bootstrap/release.pub) || {
  echo "ERROR: embedded public key differs" >&2
  exit 1
}
echo "[OK] Template structure and embedded public key"

echo "Template: $TEMPLATE"
echo "Size: $(stat -c %s "$TEMPLATE") bytes"
echo "SHA256: $(sha256sum "$TEMPLATE" | awk '{print $1}')"
