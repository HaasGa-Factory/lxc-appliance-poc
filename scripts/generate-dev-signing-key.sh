#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
KEY_DIR="$PROJECT_DIR/keys"
PRIVATE_KEY="$KEY_DIR/release.key"
PUBLIC_KEY="$KEY_DIR/release.pub"

command -v minisign >/dev/null || { echo "ERROR: minisign is required" >&2; exit 1; }
[[ ! -e $PRIVATE_KEY && ! -e $PUBLIC_KEY ]] || {
  echo "ERROR: refusing to overwrite existing signing keys" >&2
  exit 1
}
mkdir -p "$KEY_DIR"
minisign -G -W -s "$PRIVATE_KEY" -p "$PUBLIC_KEY"
chmod 0600 "$PRIVATE_KEY"
echo "WARNING: passwordless DEVELOPMENT key generated. Never use it in production."
echo "Private (Git-ignored): $PRIVATE_KEY"
echo "Public (embedded in template): $PUBLIC_KEY"

