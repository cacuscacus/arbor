# Contributing

Thanks for your interest in Arbor.

This project is in early local development. Contribution guidelines will expand once the repository is public.

## Development

```bash
# Build everything
cargo build

# Run tests
cargo test

# CLI smoke check
cargo run -p arbor-cli -- list .
```

## Code style

- **Rust**: `cargo fmt`, `cargo clippy --workspace -- -D warnings`
- Prefer small, focused crates/modules over mega-files
- UI stays thin; business logic lives in `arbor-core`

## Commit messages

Use clear, imperative subjects focused on *why*:

```
Add directory listing API to arbor-core

Enable SwiftUI to render folders via FFI without touching std::fs directly.
```

## License

By contributing, you agree that your contributions are licensed under Apache-2.0.
