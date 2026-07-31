#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_ADDRESS="${OPENSCQ30_MAC_ADDRESS:-}"
MODEL="${OPENSCQ30_DEVICE_MODEL:-SoundcoreA3957}"

if [[ -z "$MAC_ADDRESS" ]]; then
    echo "Set OPENSCQ30_MAC_ADDRESS to the paired device address." >&2
    exit 2
fi

SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openscq30-smoke.XXXXXX")"
cleanup() {
    find "$SMOKE_DIR" -depth -delete
}
trap cleanup EXIT

cd "$ROOT_DIR"
cargo build -p openscq30-cli

export OPENSCQ30_DATABASE_PATH="$SMOKE_DIR/openscq30.sqlite"
"$ROOT_DIR/target/debug/openscq30" paired-devices add \
    --mac-address "$MAC_ADDRESS" \
    --model "$MODEL"
"$ROOT_DIR/target/debug/openscq30" -vvvv device \
    --mac-address "$MAC_ADDRESS" \
    list-settings --json
