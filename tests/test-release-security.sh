#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../bootstrap/release-lib.sh
source "$PROJECT_DIR/bootstrap/release-lib.sh"
for command in minisign jq sha256sum stat; do
  command -v "$command" >/dev/null || { echo "SKIP: missing $command" >&2; exit 77; }
done

workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
minisign -G -W -s "$workdir/key" -p "$workdir/key.pub" >/dev/null
minisign -G -W -s "$workdir/wrong-key" -p "$workdir/wrong-key.pub" >/dev/null
printf 'valid application archive\n' > "$workdir/appliance-app-0.1.0.tar.gz"
sha=$(sha256sum "$workdir/appliance-app-0.1.0.tar.gz" | awk '{print $1}')
size=$(stat -c %s "$workdir/appliance-app-0.1.0.tar.gz")

make_manifest() {
  jq -n --arg sha "$sha" --argjson size "$size" \
    '{schema:1,channel:"stable",version:"0.1.0",filename:"appliance-app-0.1.0.tar.gz",sha256:$sha,size:$size}' \
    > "$workdir/release.json"
}
sign_manifest() {
  minisign -S -s "${1:-$workdir/key}" -m "$workdir/release.json" \
    -x "$workdir/release.json.sig" -t test >/dev/null
}
expect_fail() { if "$@" >/dev/null 2>&1; then echo "FAIL: unexpectedly accepted: $*" >&2; exit 1; fi; }

make_manifest
sign_manifest
verify_manifest_signature "$workdir/release.json" "$workdir/release.json.sig" "$workdir/key.pub"
manifest_fields "$workdir/release.json" stable >/dev/null
echo "PASS: valid signed manifest accepted"

printf ' ' >> "$workdir/release.json"
expect_fail verify_manifest_signature "$workdir/release.json" "$workdir/release.json.sig" "$workdir/key.pub"
echo "PASS: modified manifest rejected"

make_manifest
sign_manifest "$workdir/wrong-key"
expect_fail verify_manifest_signature "$workdir/release.json" "$workdir/release.json.sig" "$workdir/key.pub"
echo "PASS: wrong signature rejected"

verify_archive "$workdir/appliance-app-0.1.0.tar.gz" "$sha" "$size"
echo "PASS: correct archive accepted"
printf 'tampered\n' >> "$workdir/appliance-app-0.1.0.tar.gz"
expect_fail verify_archive "$workdir/appliance-app-0.1.0.tar.gz" "$sha" "$size"
echo "PASS: modified archive rejected"

make_manifest
jq '.filename="../appliance-app-0.1.0.tar.gz"' "$workdir/release.json" > "$workdir/bad.json"
expect_fail manifest_fields "$workdir/bad.json" stable
echo "PASS: path traversal rejected"

jq 'del(.sha256)' "$workdir/release.json" > "$workdir/bad.json"
expect_fail manifest_fields "$workdir/bad.json" stable
echo "PASS: incomplete manifest rejected"
