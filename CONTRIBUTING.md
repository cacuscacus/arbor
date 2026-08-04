# Contributing

Thanks for helping improve Arbor.

Public repo: https://github.com/cacuscacus/arbor  
License for contributions: [Apache-2.0](LICENSE)

## Before you open a PR

Run the full local gate from the repo root:

```bash
./scripts/dev-check.sh
```

That is the same Rust / script / cask surface GitHub Actions runs on every pull request. **PRs that fail CI will not merge.**

| Check | What it covers |
|-------|----------------|
| `bash -n` | `scripts/dev-check.sh`, `scripts/package-macos.sh` |
| `cargo fmt --check` | Formatting |
| `cargo clippy -D warnings` | Lints as errors |
| `cargo test --workspace` | Unit + CLI integration tests |
| CLI smoke | `arbor version` / `arbor list` |
| Cask shape | `Casks/arbor.rb` has version + real sha256 |

### Tooling

```bash
rustup toolchain install stable
rustup component add rustfmt clippy
```

- Rust **1.75+** (workspace `rust-version`)
- macOS UI work also needs **Xcode 26+** / **macOS 26 (Tahoe)+** — UI changes are not covered by CI yet; say how you smoke-tested them in the PR

## Development

```bash
cargo build
cargo test --workspace
cargo run -p arbor-cli -- list .
cargo run -p arbor-cli -- list --json .
open apps/macos/Arbor.xcodeproj   # SwiftUI app
```

Packaging / Homebrew release flow: [docs/RELEASES.md](docs/RELEASES.md).

## Pull request checklist

- [ ] `./scripts/dev-check.sh` passes locally
- [ ] New behavior has tests (prefer `arbor-core` / CLI / FFI over UI-only logic)
- [ ] Docs updated when behavior or install/release steps change (`README.md`, `CHANGELOG.md`, `docs/`, cask)
- [ ] No unrelated formatting or drive-by refactors
- [ ] Clear PR description: *what* changed and *why*
- [ ] macOS UI changes: note Xcode version + what you manually verified

## What we review first

1. **CI green** (required signal)
2. Tests covering the change
3. API / UX impact and docs
4. Small, focused diffs

## Code style

- **Rust**: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`
- Prefer small crates/modules; keep SwiftUI thin and put logic in `arbor-core` when possible
- Do not commit signing secrets, notarization credentials, or `dist/` build products

## Commit messages

Imperative subject; explain *why* when it is not obvious:

```
Add directory listing API to arbor-core

Enable SwiftUI to render folders via FFI without touching std::fs directly.
```

## License

By contributing, you agree that your contributions are licensed under Apache-2.0.
