#!/bin/bash
set -Eeuo pipefail
cd -- "$(dirname -- "$0")/../dist/releases"
exec python3 -m http.server 8000 --bind 0.0.0.0

