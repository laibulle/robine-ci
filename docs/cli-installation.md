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

Reproduce a complete workflow, one job with its dependencies, or one named/indexed step:

```sh
robine run
robine run test --input environment=staging
robine run test --step compile
robine run test --step 2 --no-deps
robine run test --verbose
```

Step selection includes preceding run steps in the selected job so workspace state can be reconstructed. Dependency jobs still run completely unless `--no-deps` is explicit.

Declared secrets are opt-in and local only:

```sh
printf '.robine.env\n' >> .gitignore
# Create .robine.env with literal NAME=VALUE lines, then:
robine run test --env-file .robine.env
```

The CLI accepts only a regular, UTF-8 file reached without symlinks, inside the current Git worktree, matched by `git check-ignore`, and no larger than 1 MiB. Values must contain 8–65,536 bytes. It resolves every selected job before Docker starts, injects only declared names, ignores undeclared entries, and never prints secret values.

`--verbose` prints the normalized local execution specification and executor phases. Serialization excludes secret values and source-file contents by type, including when a local env file is active.

Release reviewers validate the two external MVP evidence records with the same native executable:

```sh
robine verify-acceptance \
  --first-pipeline /secure/release-evidence/first-pipeline.json \
  --accessibility /secure/release-evidence/accessibility.json \
  --artifact-manifest /secure/release-evidence/SHA256SUMS
```

The verifier accepts only bounded regular files, strictly validates every evidence field, rejects placeholders, overlapping exclusions and unresolved blocking accessibility findings, and cryptographically binds the session to the exact version-matched CLI, server, and runner manifest. `--format json` emits a machine-readable release record.
