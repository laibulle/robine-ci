# Third-party notices

The authoritative release notice is generated from the locked Cargo dependency graph by `robine-package` and included in each CLI, server, and runner bundle. `deny.toml` enforces accepted SPDX licenses, registries, Git sources, and RustSec advisories in CI.

Run the following to generate and inspect the exact notice for the current `Cargo.lock`:

```sh
ROBINE_DOCKER_CLI=/usr/bin/docker cargo run -p robine-package -- --output dist
less dist/server/THIRD_PARTY_NOTICES.md
```

Review the corresponding crate source archives for complete license text. The generated notice records the `Cargo.lock` SHA-256 so it cannot be mistaken for the inventory of a different dependency graph.
