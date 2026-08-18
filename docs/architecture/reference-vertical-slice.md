# Reference vertical slice: create a pipeline

`robine_application::ControlPlane::create_pipeline` is the canonical state-changing application operation. It preserves inward dependency direction while supporting durable provider delivery, pure validation, and PostgreSQL transaction tests.

## Path through the architecture

1. The Actix webhook handler authenticates the bounded raw payload and calls `ControlPlane::accept_source_control_delivery`.
2. The PostgreSQL source-delivery adapter records provider identity and deduplication state durably.
3. A shutdown-aware Tokio loop calls the bounded source-control batch operation.
4. Provider-neutral normalization and workflow resolution produce an exact-SHA `CreatePipelineInput`.
5. Framework-independent workflow and pipeline modules validate the immutable revision, expanded graph, dependencies, inputs, and lifecycle invariants.
6. `PipelineRepository::create_pipeline` expresses the atomic capability required by the application boundary.
7. The SQLx adapter persists pipeline metadata, immutable workflow revision, included-source digests, jobs, and one outbox event in one tenant-scoped transaction.
8. After commit, outbox and status-projection workers claim durable jobs and call provider adapters. No provider or Docker effect occurs inside creation.

The input is a typed Rust contract. Actix parses transport JSON into that contract; webhook processing constructs it from normalized provider and workflow data. Neither path exposes an Actix request or SQLx row to the domain.

## Shared query example

`ControlPlane::list_pipelines` serves authenticated standalone Actix delivery. `ControlPlane::list_pipelines_for_context` serves a Rust embedding host with the same repository projection while deriving tenant and capability from `ExecutionContext`. Both call the context-owned `PipelineRepository` trait; neither delivery surface issues SQL.

## Tests to copy

- `robine-core` pipeline tests exercise lifecycle, retry, cancellation, event ordering, and dependency release without external services.
- `robine-application` tests exercise workflow-to-durable-graph orchestration.
- `robine-persistence/tests/existing_schema.rs` proves atomic creation, rollback, idempotency, tenant isolation, durable outbox behavior, and embedded context isolation against PostgreSQL.
- `robine-server` tests verify transport parsing, authentication, authorization, and response translation.

For a new operation, add or reuse a core contract, expose a capability trait when the boundary is volatile, orchestrate it in `ControlPlane`, implement the adapter, assemble it only in the binary or embedding host, and add delivery translation last.
