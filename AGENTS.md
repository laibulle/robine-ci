# Robine contributor instructions

Robine is a Rust workspace whose HTTP control plane uses Actix Web.

## Verification

- Run `cargo fmt --all -- --check` after changes.
- Run `cargo clippy --workspace --all-targets --all-features -- -D warnings`.
- Run `cargo test --workspace --all-targets`.
- For persistence changes, also run `robine-persistence/tests/existing_schema.rs` against PostgreSQL through `ROBINE_DATABASE_INTEGRATION_URL`.
- Build release payloads with `cargo run -p robine-package -- --output <directory>` and verify every emitted `SHA256SUMS` from its own directory.

## Product specifications and task tracking

- Write specifications in English under `docs/specs/<domain>/<feat-id>-<feature-name>.md`.
- Start new specifications from `docs/specs/TEMPLATE.md`; use stable uppercase feature IDs in prose and lowercase kebab-case filenames.
- Accepted specifications are the source of truth. Resolve blocking questions before changing a specification to `Accepted`.
- Track implementation in `TASKS.md`. Mark an item `[x]` only after its exit criteria are implemented and verified; annotate partial work accurately.
- Update the corresponding specification and `TASKS.md` whenever implementation changes a documented contract.

## Architecture

- Keep Robine as one deployable product split into focused workspace crates.
- Put framework-independent invariants, typed state, and transitions in `robine-core` or another framework-independent domain crate.
- Coordinate policies and outbound traits in `robine-application`; expected outcomes use typed `Result` values.
- Keep Actix, SQLx, Docker, HTTP providers, filesystems, and object stores in boundary crates. Actix handlers call the application service and do not implement business transitions.
- Keep tenant identity and actor capabilities explicit in every application operation. Never infer tenant scope from request parameters alone.
- Keep external effects outside database transactions. Persist required effects atomically through durable jobs or the outbox, then deliver them after commit.
- Use named persistence/application projections; delivery code must not issue arbitrary SQL.
- Temporary architecture exceptions require a narrow test allowlist, an owner, a removal condition, and a linked unchecked `TASKS.md` item.

## Rust and async code

- Keep `unsafe` code forbidden.
- Do not panic on request, database, provider, runner, or workflow input. Return a typed error and translate it at the boundary.
- Bound request bodies, archives, collections, logs, retries, concurrency, and timeouts.
- Never hold a synchronous lock or database transaction across network, Docker, filesystem, or other long-running effects.
- Use Tokio cancellation/shutdown signals for workers and keep duplicate delivery idempotent.
- Do not expose secrets through `Debug`, tracing, errors, URLs, command arguments, or persisted public metadata. Keep plaintext in zeroizing values where supported.
- Avoid adding dependencies when the standard library or an existing workspace dependency is sufficient.

## PostgreSQL

- PostgreSQL is the durable source of truth. Tenant-owned reads and writes must set and validate tenant scope.
- Use transactions and row/advisory locks for invariants that span records.
- Keep migrations forward-only and restart-safe. The Rust baseline must continue to accept an empty database and validate the final historical schema.
- Preserve idempotency constraints for webhooks, runner messages, attempts, durable jobs, and outbox deliveries.

## Actix and browser delivery

- Authenticate and authorize every protected handler on the server, including forged requests to hidden actions.
- Require CSRF verification for cookie-authenticated mutations. Machine APIs use scoped credentials and must not rely on cookies.
- Use semantic server-rendered HTML with stable unique IDs, accessible labels, keyboard operation, and meaningful content before JavaScript loads.
- Keep browser JavaScript in the local `robine-server` asset bundle; do not add inline scripts or external CDN dependencies.
- Real-time updates may enhance committed state only. Reconnect must recover from PostgreSQL projections rather than browser or process memory.
- Use responsive, polished styling and subtle interactions without weakening loading, error, empty, or degraded states.

## Tests

- Test outcomes and durable contracts rather than private implementation details.
- Prefer deterministic clocks, signals, and monitored process completion over sleeps.
- Integration tests that require PostgreSQL must create isolated identities/data, serialize destructive schema operations, and clean up temporary databases.
- Preserve the shared workflow fixture corpus under `test/fixtures/workflows` until it is intentionally relocated with all Rust consumers updated.
