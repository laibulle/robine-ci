# Install and verify the Robine CLI

The CLI is one native Rust executable and does not require Elixir, Erlang, ERTS, or a Robine server.

```sh
cargo run --release -p robine-package -- --output dist
cd dist/cli
sha256sum --check SHA256SUMS
install -m 0755 robine "$HOME/.local/bin/robine"
robine version
```

Stable exit classes are: `0` success, `2` configuration, `3` infrastructure, `4` protected mutation, `5` job failure, and `64` usage. Local secret files must be ignored by Git; the CLI never downloads server-side secrets or transmits repository data by default.
