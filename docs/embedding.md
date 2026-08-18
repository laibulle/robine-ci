# Embedding the Robine CI backend

Robine's control plane is available as Rust libraries without starting Actix or any human interface. A host owns process supervision, authentication, HTTP delivery, and shutdown; Robine owns workflow, authorization, persistence-port, execution, and tenant-isolation contracts.

## Crates and assembly

Use the framework-independent crates from this workspace:

```toml
[dependencies]
robine-application = { path = "rust/crates/robine-application" }
robine-core = { path = "rust/crates/robine-core" }
robine-persistence = { path = "rust/crates/robine-persistence" }
tokio = { version = "1", features = ["rt-multi-thread"] }
uuid = { version = "1", features = ["v4"] }
```

The host creates adapters explicitly. Constructing `ControlPlane` starts no web server or background task:

```rust
use robine_application::ControlPlane;
use robine_persistence::Database;
use std::sync::Arc;

let database = Arc::new(Database::connect(&database_url, 10).await?);
database.bootstrap_schema().await?;
let control_plane = Arc::new(ControlPlane::new(database.clone(), database));
```

Optional execution, source, storage, secret, retention, and OIDC adapters are assembled through the typed `with_*` methods before the value is shared. The standalone `robine-server` binary is the complete reference assembly.

## Schema ownership

`Database::bootstrap_schema()` takes a PostgreSQL advisory lock, creates the Rust baseline only on an empty database, applies idempotent forward migrations, and fails closed when an older incomplete schema is detected. Embedded hosts use a dedicated PostgreSQL database or role without `SUPERUSER` or `BYPASSRLS`; they do not copy SQL migrations into their own source tree.

## Calls and authorization

The host translates its authenticated server-side scope into an explicit context. Host role names carry no implicit authority:

```rust
use robine_core::execution_context::{Actor, ActorKind, Capability, ExecutionContext};
use uuid::Uuid;

let context = ExecutionContext::embedded(
    Actor { id: user_id, kind: ActorKind::User },
    workspace_id,
    [Capability::new("pipelines:read")],
    Uuid::new_v4(),
)?;

let pipelines = control_plane
    .list_pipelines_for_context(&context, None, 50)
    .await?;
```

The public embedded query derives its tenant exclusively from `ExecutionContext`, checks the exact capability, and clamps the result bound. Caller-provided repository filters never replace tenant isolation. Context construction rejects blank tenant IDs and empty capabilities.

## Background work

Embedding does not silently start workers. A host that enables durable execution calls the public bounded batch methods on its own shutdown-aware Tokio tasks, using the standalone server loops as the reference cadence. This makes task ownership, restart policy, and cancellation part of the host's supervision model.

Robine exports no Actix route, template, stylesheet, JavaScript, session, or identity UI through this integration boundary. The host owns the complete product experience.
