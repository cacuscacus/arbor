#!/usr/bin/env bash
# Required local gate before opening a PR. Same checks as GitHub Actions (Rust job).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> bash -n scripts"
bash -n scripts/dev-check.sh
bash -n scripts/package-macos.sh

echo "==> cargo fmt (check)"
cargo fmt --all -- --check

echo "==> cargo clippy"
cargo clippy --workspace --all-targets -- -D warnings

echo "==> cargo test"
cargo test --workspace

echo "==> arbor-cli smoke"
cargo run -q -p arbor-cli -- version
cargo run -q -p arbor-cli -- list "$ROOT" >/dev/null

echo "==> Homebrew cask shape"
python3 - <<'PY'
from pathlib import Path
import re
text = Path("Casks/arbor.rb").read_text()
assert re.search(r'cask "arbor"', text), "missing cask name"
assert re.search(r'version "', text), "missing version"
assert re.search(r'sha256 "', text), "missing sha256"
assert "REPLACE_WITH" not in text, "placeholder checksum still present"
print("cask ok")
PY

echo "OK — ready to open a PR"
