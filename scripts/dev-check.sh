#!/usr/bin/env bash
# Quick smoke checks for local development.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> cargo fmt (check)"
cargo fmt --all -- --check

echo "==> cargo clippy"
cargo clippy --workspace --all-targets -- -D warnings

echo "==> cargo test"
cargo test --workspace

echo "==> arbor-cli list"
cargo run -q -p arbor-cli -- list "$ROOT" | head -20

echo "OK"
