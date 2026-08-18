# Build and verify a server release

Build all native release artifacts, license payloads, deployment overlays, and SHA-256 manifests with:

```bash
cargo run --release -p robine-package -- --output dist
```

The server bundle is under `dist/server/`. It contains the Actix executable, pinned Docker client, complete AGPL license, third-party notices, Compose/Caddy configuration, and secret-generating installer. It contains no BEAM, ERTS, EPMD, or Erlang Distribution configuration.

Verify it before installation:

```bash
cd dist/server
sha256sum --check SHA256SUMS
./robine-server --version
```

Preserve the prior bundle for rollback. The server creates the complete baseline on an empty PostgreSQL database and validates an existing cutover schema before serving traffic. Never copy secrets into a release artifact.

Before production cutover, rehearse [upgrade, backup, recovery, and rollback](operations/upgrade-backup-and-recovery.md) on a restored database. A release smoke must start the packaged executable on an empty database, receive HTTP 200 from both health probes, stop it cleanly, restart it on the created schema, and receive readiness again.
