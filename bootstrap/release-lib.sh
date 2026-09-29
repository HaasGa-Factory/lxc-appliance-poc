#!/bin/bash

verify_manifest_signature() {
  local manifest=$1 signature=$2 public_key=$3
  minisign -Vm "$manifest" -x "$signature" -p "$public_key" >/dev/null
}

manifest_fields() {
  local manifest=$1 channel=${2:-stable}
  jq -er --arg channel "$channel" '
    select(
      type == "object" and
      (keys | sort) == ["channel", "filename", "schema", "sha256", "size", "version"] and
      .schema == 1 and
      .channel == $channel and
      (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
      (.filename | type == "string" and test("^appliance-app-[0-9]+\\.[0-9]+\\.[0-9]+\\.tar\\.gz$")) and
      .filename == ("appliance-app-" + .version + ".tar.gz") and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.size | type == "number" and . >= 1 and floor == .)
    ) |
    [.version, .filename, .sha256, (.size | tostring)] | @tsv
  ' "$manifest"
}

verify_archive() {
  local archive=$1 expected_sha=$2 expected_size=$3
  [[ $(stat -c %s "$archive") == "$expected_size" ]] || return 1
  [[ $(sha256sum "$archive" | awk '{print $1}') == "$expected_sha" ]]
}

