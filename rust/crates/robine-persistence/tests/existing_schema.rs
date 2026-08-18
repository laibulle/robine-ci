use std::sync::Arc;

use argon2::{
    Argon2,
    password_hash::{PasswordHasher, SaltString},
};
use async_trait::async_trait;
use chrono::{Duration, Utc};
use hmac::{Hmac, Mac};
use robine_application::{ApplicationError, ControlPlane};
use robine_core::{
    identity::{OidcAuthorization, OidcClaims, Role, User},
    pipelines::{
        CreatePipelineInput, JobState, NewJob, NewPipeline, NewWorkflowRevision,
        RecordAttemptEvent, RecordRemoteAttemptEvent, SchedulerClaim, source_digest,
    },
    ports::{IdentityRepository, OidcProvider, PipelineRepository, PortError},
};
use robine_persistence::{Database, Readiness};
use robine_secrets::SecretRepository;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

struct FakeOidc(OidcClaims);

#[async_trait]
impl OidcProvider for FakeOidc {
    async fn start(&self) -> Result<OidcAuthorization, PortError> {
        Ok(OidcAuthorization {
            url: "https://issuer.example/authorize".into(),
            state: "state".into(),
        })
    }

    async fn complete(&self, _code: &str, _state: &str) -> Result<OidcClaims, PortError> {
        Ok(self.0.clone())
    }
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn reads_the_existing_ecto_schema_when_configured() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };

    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect to the migrated Robine database");

    database.ready().await.expect("database is ready");
    database
        .list_pipelines("standalone", 10)
        .await
        .expect("read pipelines through the existing schema and tenant policy");

    let fixture_pool = PgPool::connect(&database_url)
        .await
        .expect("connect fixture pool");
    let user_id = Uuid::new_v4();
    let session_id = Uuid::new_v4();
    let credential_id = Uuid::new_v4();
    let token = format!("rust-session-{session_id}");
    let digest = Sha256::digest(token.as_bytes());
    let password = "correct horse battery staple";
    let password_hash = Argon2::default()
        .hash_password(
            password.as_bytes(),
            &SaltString::encode_b64(b"ecto-compatible-salt").expect("valid test salt"),
        )
        .expect("hash test password")
        .to_string();

    sqlx::query(
        "INSERT INTO users (id, email, role, disabled, inserted_at) \
         VALUES ($1, $2, 'viewer', false, NOW())",
    )
    .bind(user_id)
    .bind(format!("rust-{user_id}@example.invalid"))
    .execute(&fixture_pool)
    .await
    .expect("insert compatibility user");
    sqlx::query(
        "INSERT INTO local_credentials (id, user_id, password_hash, inserted_at) \
         VALUES ($1, $2, $3, NOW())",
    )
    .bind(credential_id)
    .bind(user_id)
    .bind(password_hash)
    .execute(&fixture_pool)
    .await
    .expect("insert compatible Argon2 credential");
    sqlx::query(
        "INSERT INTO sessions (id, user_id, token_digest, expires_at, inserted_at) \
         VALUES ($1, $2, $3, NOW() + INTERVAL '5 minutes', NOW())",
    )
    .bind(session_id)
    .bind(user_id)
    .bind(digest.as_slice())
    .execute(&fixture_pool)
    .await
    .expect("insert compatibility session");

    let oidc_user_id = Uuid::new_v4();
    let oidc_claims = OidcClaims {
        issuer: "https://issuer.example".into(),
        subject: format!("subject-{oidc_user_id}"),
        email: format!("oidc-{oidc_user_id}@example.invalid"),
        email_verified: true,
    };
    let oidc_user = database
        .find_or_provision_oidc_user(&oidc_claims, oidc_user_id, Utc::now())
        .await
        .expect("provision verified OIDC identity");
    let mut renamed_claims = oidc_claims.clone();
    renamed_claims.email = "renamed@example.invalid".into();
    let stable_oidc_user = database
        .find_or_provision_oidc_user(&renamed_claims, Uuid::new_v4(), Utc::now())
        .await
        .expect("resolve existing OIDC identity by issuer and subject");
    let collision = database
        .find_or_provision_oidc_user(
            &OidcClaims {
                issuer: oidc_claims.issuer.clone(),
                subject: "different-subject".into(),
                email: format!("rust-{user_id}@example.invalid"),
                email_verified: true,
            },
            Uuid::new_v4(),
            Utc::now(),
        )
        .await;

    let database = Arc::new(database);
    let control_plane = ControlPlane::new(database.clone(), database)
        .with_bootstrap_token("bootstrap-once", Utc::now() + Duration::minutes(5))
        .with_oidc_provider(Arc::new(FakeOidc(oidc_claims.clone())));
    let authentication = control_plane.authenticate(&token).await;
    let repeated_bootstrap = control_plane
        .bootstrap_administrator(
            "bootstrap-once",
            "other-admin@example.invalid",
            "another-long-password",
        )
        .await;
    let first_admin_id = Uuid::new_v4();
    let second_admin_id = Uuid::new_v4();
    let admin_inserted_at = Utc::now();
    sqlx::query(
        "INSERT INTO users (id, email, role, disabled, inserted_at) \
         VALUES ($1, $2, 'administrator', false, $3)",
    )
    .bind(first_admin_id)
    .bind(format!("first-admin-{first_admin_id}@example.invalid"))
    .bind(admin_inserted_at)
    .execute(&fixture_pool)
    .await
    .expect("insert first administrator");
    let administrator = User {
        id: first_admin_id,
        email: format!("first-admin-{first_admin_id}@example.invalid"),
        role: Role::Administrator,
        disabled: false,
        inserted_at: admin_inserted_at,
    };
    let users = control_plane
        .list_users(&administrator)
        .await
        .expect("administrator lists users");
    let last_admin_change = control_plane
        .change_user_role(&administrator, first_admin_id, Role::Viewer)
        .await;
    sqlx::query(
        "INSERT INTO users (id, email, role, disabled, inserted_at) \
         VALUES ($1, $2, 'administrator', false, NOW())",
    )
    .bind(second_admin_id)
    .bind(format!("second-admin-{second_admin_id}@example.invalid"))
    .execute(&fixture_pool)
    .await
    .expect("insert second administrator");
    let changed_user = control_plane
        .change_user_role(&administrator, first_admin_id, Role::Viewer)
        .await
        .expect("demote administrator when another remains");
    let local_session = control_plane
        .authenticate_local(&format!("RUST-{user_id}@EXAMPLE.INVALID"), password)
        .await
        .expect("authenticate an existing Argon2 credential case-insensitively");
    let oidc_authorization = control_plane.start_oidc().await.expect("start OIDC");
    let oidc_session = control_plane
        .complete_oidc("code", &oidc_authorization.state)
        .await
        .expect("complete OIDC and issue local session");
    control_plane
        .revoke_session(&local_session.token)
        .await
        .expect("revoke the issued session");
    let revoked_authentication = control_plane.authenticate(&local_session.token).await;

    sqlx::query("DELETE FROM sessions WHERE user_id = $1")
        .bind(user_id)
        .execute(&fixture_pool)
        .await
        .expect("remove compatibility sessions");
    sqlx::query("DELETE FROM local_credentials WHERE id = $1")
        .bind(credential_id)
        .execute(&fixture_pool)
        .await
        .expect("remove compatibility credential");
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(&fixture_pool)
        .await
        .expect("remove compatibility user");
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(oidc_user_id)
        .execute(&fixture_pool)
        .await
        .expect("remove OIDC user fixture");
    sqlx::query("DELETE FROM users WHERE id = ANY($1)")
        .bind(vec![first_admin_id, second_admin_id])
        .execute(&fixture_pool)
        .await
        .expect("remove administrator fixtures");

    let user = authentication.expect("resolve the Phoenix-compatible session digest");
    assert_eq!(user.id, user_id);
    assert_eq!(user.role, Role::Viewer);
    assert_eq!(local_session.user.id, user_id);
    assert!(revoked_authentication.is_err());
    assert!(matches!(
        repeated_bootstrap,
        Err(robine_application::ApplicationError::AlreadyBootstrapped)
    ));
    assert!(users.iter().any(|user| user.id == first_admin_id));
    assert!(matches!(
        last_admin_change,
        Err(ApplicationError::LastAdministrator)
    ));
    assert_eq!(changed_user.role, Role::Viewer);
    assert_eq!(oidc_user.id, oidc_user_id);
    assert_eq!(oidc_session.user.id, oidc_user_id);
    assert_eq!(stable_oidc_user.id, oidc_user_id);
    assert_eq!(stable_oidc_user.email, oidc_claims.email);
    assert!(matches!(
        collision,
        Err(robine_core::ports::PortError::OidcEmailCollision)
    ));
}

#[tokio::test]
async fn cancellation_is_tenant_scoped_atomic_and_outboxed() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let pipeline_id = Uuid::new_v4();
    let running_job_id = Uuid::new_v4();
    let queued_job_id = Uuid::new_v4();
    let repository_id = Uuid::new_v4();
    let mut fixture = database
        .tenant_transaction("standalone")
        .await
        .expect("open fixture transaction");
    sqlx::query(
        "INSERT INTO pipelines \
         (id, repository_id, workflow_name, commit_sha, status, trigger, actor, correlation_id, inserted_at) \
         VALUES ($1, $2, 'Cancellation', $3, 'running', 'manual', 'test', $4, NOW())",
    )
    .bind(pipeline_id)
    .bind(repository_id)
    .bind("a".repeat(40))
    .bind(format!("rust-cancel-{pipeline_id}"))
    .execute(&mut *fixture)
    .await
    .expect("insert pipeline");
    sqlx::query(
        "INSERT INTO pipeline_jobs \
         (id, pipeline_id, job_key, status, needs, position, execution_spec, inserted_at, updated_at) \
         VALUES ($1, $3, 'running', 'running', '{}', 0, '{}', NOW(), NOW()), \
                ($2, $3, 'queued', 'queued', '{}', 1, '{}', NOW(), NOW())",
    )
    .bind(running_job_id)
    .bind(queued_job_id)
    .bind(pipeline_id)
    .execute(&mut *fixture)
    .await
    .expect("insert jobs");
    fixture.commit().await.expect("commit fixtures");

    let cross_tenant = database
        .cancel("different-tenant", pipeline_id, Uuid::new_v4(), Utc::now())
        .await;
    assert!(matches!(cross_tenant, Err(PortError::NotFound)));

    let now = Utc::now();
    let maintainer = User {
        id: Uuid::new_v4(),
        email: "maintainer@example.invalid".into(),
        role: Role::Maintainer,
        disabled: false,
        inserted_at: now,
    };
    let control_plane = ControlPlane::new(database.clone(), database.clone());
    let cancelled = control_plane
        .cancel_pipeline(&maintainer, pipeline_id)
        .await
        .expect("cancel active pipeline");

    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("open verification transaction");
    let job_states = sqlx::query_as::<_, (String, String)>(
        "SELECT job_key, status FROM pipeline_jobs WHERE pipeline_id = $1 ORDER BY position",
    )
    .bind(pipeline_id)
    .fetch_all(&mut *verification)
    .await
    .expect("read cancelled jobs");
    let outbox_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM outbox_events \
         WHERE aggregate_id = $1 AND event_type = 'pipeline.projection_requested' \
           AND payload->>'dispatch' = 'false'",
    )
    .bind(pipeline_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read cancellation outbox event");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline_id)
        .execute(&mut *verification)
        .await
        .expect("remove pipeline fixture");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(pipeline_id)
        .execute(&mut *verification)
        .await
        .expect("remove outbox fixture");
    verification.commit().await.expect("commit cleanup");

    assert_eq!(cancelled.status, "cancelling");
    assert_eq!(
        job_states,
        vec![
            ("running".into(), "cancelling".into()),
            ("queued".into(), "cancelled".into())
        ]
    );
    assert_eq!(outbox_count, 1);
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn retry_validates_prerequisites_and_reopens_atomically() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let pipeline_id = Uuid::new_v4();
    let producer_id = Uuid::new_v4();
    let missing_input_job_id = Uuid::new_v4();
    let retry_job_id = Uuid::new_v4();
    let mut fixture = database
        .tenant_transaction("standalone")
        .await
        .expect("open fixture transaction");
    sqlx::query(
        "INSERT INTO pipelines \
         (id, repository_id, workflow_name, commit_sha, status, trigger, actor, correlation_id, \
          started_at, finished_at, inserted_at) \
         VALUES ($1, $2, 'Retry', $3, 'failed', 'manual', 'test', $4, NOW(), NOW(), NOW())",
    )
    .bind(pipeline_id)
    .bind(Uuid::new_v4())
    .bind("b".repeat(40))
    .bind(format!("rust-retry-{pipeline_id}"))
    .execute(&mut *fixture)
    .await
    .expect("insert failed pipeline");
    sqlx::query(
        "INSERT INTO pipeline_jobs \
         (id, pipeline_id, job_key, status, needs, position, execution_spec, inserted_at, updated_at) \
         VALUES ($1, $4, 'build', 'succeeded', '{}', 0, '{}', NOW(), NOW()), \
                ($2, $4, 'artifact-test', 'failed', ARRAY['build'], 1, $5, NOW(), NOW()), \
                ($3, $4, 'plain-test', 'failed', ARRAY['build'], 2, $6, NOW(), NOW())",
    )
    .bind(producer_id)
    .bind(missing_input_job_id)
    .bind(retry_job_id)
    .bind(pipeline_id)
    .bind(serde_json::json!({
        "steps": [{
            "kind": "builtin",
            "value": "artifacts/download",
            "with": {"from": "build", "name": "release"}
        }]
    }))
    .bind(serde_json::json!({"steps": [{"kind": "run", "value": "mix test"}]}))
    .execute(&mut *fixture)
    .await
    .expect("insert retry jobs");
    fixture.commit().await.expect("commit fixtures");

    let missing_input = database
        .retry_job(
            "standalone",
            missing_input_job_id,
            Uuid::new_v4(),
            Utc::now(),
        )
        .await;
    assert!(matches!(
        missing_input,
        Err(PortError::RetryInputsUnavailable(ref inputs))
            if inputs == &vec!["build/release".to_owned()]
    ));
    let cross_tenant = database
        .retry_job("different-tenant", retry_job_id, Uuid::new_v4(), Utc::now())
        .await;
    assert!(matches!(cross_tenant, Err(PortError::NotFound)));

    let maintainer = User {
        id: Uuid::new_v4(),
        email: "maintainer@example.invalid".into(),
        role: Role::Maintainer,
        disabled: false,
        inserted_at: Utc::now(),
    };
    let control_plane = ControlPlane::new(database.clone(), database.clone());
    let retry = control_plane
        .retry_job(&maintainer, retry_job_id)
        .await
        .expect("retry failed job");

    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("open verification transaction");
    let pipeline_state = sqlx::query_as::<_, (String, Option<chrono::NaiveDateTime>)>(
        "SELECT status, finished_at FROM pipelines WHERE id = $1",
    )
    .bind(pipeline_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read reopened pipeline");
    let retried_state =
        sqlx::query_scalar::<_, String>("SELECT status FROM pipeline_jobs WHERE id = $1")
            .bind(retry_job_id)
            .fetch_one(&mut *verification)
            .await
            .expect("read retried job");
    let rejected_state =
        sqlx::query_scalar::<_, String>("SELECT status FROM pipeline_jobs WHERE id = $1")
            .bind(missing_input_job_id)
            .fetch_one(&mut *verification)
            .await
            .expect("read rejected job");
    let dispatch_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM outbox_events WHERE aggregate_id = $1 \
         AND event_type = 'pipeline.projection_requested' AND payload->>'dispatch' = 'true'",
    )
    .bind(pipeline_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read retry outbox event");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline_id)
        .execute(&mut *verification)
        .await
        .expect("remove pipeline fixture");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(pipeline_id)
        .execute(&mut *verification)
        .await
        .expect("remove outbox fixture");
    verification.commit().await.expect("commit cleanup");

    assert_eq!(retry.pipeline_id, pipeline_id);
    assert_eq!(retry.job_id, retry_job_id);
    assert_eq!(retry.status, "queued");
    assert_eq!(pipeline_state, ("running".into(), None));
    assert_eq!(retried_state, "queued");
    assert_eq!(rejected_state, "failed");
    assert_eq!(dispatch_count, 1);
}

#[tokio::test]
async fn queue_is_tenant_scoped_and_idempotent() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let pipeline_id = Uuid::new_v4();
    let mut fixture = database
        .tenant_transaction("standalone")
        .await
        .expect("open fixture transaction");
    sqlx::query(
        "INSERT INTO pipelines \
         (id, repository_id, workflow_name, commit_sha, status, trigger, actor, correlation_id, inserted_at) \
         VALUES ($1, $2, 'Queue', $3, 'created', 'manual', 'test', $4, NOW())",
    )
    .bind(pipeline_id)
    .bind(Uuid::new_v4())
    .bind("c".repeat(40))
    .bind(format!("rust-queue-{pipeline_id}"))
    .execute(&mut *fixture)
    .await
    .expect("insert created pipeline");
    fixture.commit().await.expect("commit fixture");

    let cross_tenant = database.queue("different-tenant", pipeline_id).await;
    assert!(matches!(cross_tenant, Err(PortError::NotFound)));
    let maintainer = User {
        id: Uuid::new_v4(),
        email: "maintainer@example.invalid".into(),
        role: Role::Maintainer,
        disabled: false,
        inserted_at: Utc::now(),
    };
    let control_plane = ControlPlane::new(database.clone(), database.clone());
    let queued = control_plane
        .queue_pipeline(&maintainer, pipeline_id)
        .await
        .expect("queue created pipeline");
    let repeated = control_plane
        .queue_pipeline(&maintainer, pipeline_id)
        .await
        .expect("queue is idempotent");

    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("open verification transaction");
    sqlx::query("UPDATE pipelines SET status = 'succeeded' WHERE id = $1")
        .bind(pipeline_id)
        .execute(&mut *verification)
        .await
        .expect("make pipeline terminal");
    verification.commit().await.expect("commit terminal state");
    let terminal = control_plane.queue_pipeline(&maintainer, pipeline_id).await;

    let mut cleanup = database
        .tenant_transaction("standalone")
        .await
        .expect("open cleanup transaction");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline_id)
        .execute(&mut *cleanup)
        .await
        .expect("remove pipeline fixture");
    cleanup.commit().await.expect("commit cleanup");

    assert_eq!(queued.status, "queued");
    assert_eq!(repeated.status, "queued");
    assert!(matches!(
        terminal,
        Err(ApplicationError::PipelineNotQueueable)
    ));
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn creation_persists_revision_graph_and_event_atomically() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let maintainer = User {
        id: Uuid::new_v4(),
        email: "maintainer@example.invalid".into(),
        role: Role::Maintainer,
        disabled: false,
        inserted_at: Utc::now(),
    };
    let idempotency_key = format!("rust-create-{}", Uuid::new_v4());
    let input = || -> CreatePipelineInput {
        serde_json::from_value(serde_json::json!({
            "repository_id": Uuid::new_v4(),
            "workflow_name": "Rust creation",
            "commit_sha": "d".repeat(40),
            "idempotency_key": idempotency_key,
            "jobs": {
                "build": {"execution": {"image": "alpine", "steps": []}},
                "test": {
                    "needs": ["build"],
                    "execution": {"image": "alpine", "steps": []}
                }
            },
            "workflow_revision": {
                "path": ".robine-ci/workflows/ci.yml",
                "source": "version: 1\nname: CI\n",
                "sources": {"shared.yml": "version: 1\nname: Shared\n"}
            }
        }))
        .expect("valid pipeline input")
    };
    let first_input = input();
    let repository_id = first_input.repository_id;
    let control_plane = ControlPlane::new(database.clone(), database.clone());
    let created = control_plane
        .create_pipeline(&maintainer, first_input)
        .await
        .expect("create pipeline atomically");

    let repeated_input: CreatePipelineInput = serde_json::from_value(serde_json::json!({
        "repository_id": repository_id,
        "workflow_name": "Rust creation",
        "commit_sha": "d".repeat(40),
        "idempotency_key": idempotency_key,
        "jobs": {
            "build": {"execution": {"image": "alpine", "steps": []}},
            "test": {"needs": ["build"], "execution": {"image": "alpine", "steps": []}}
        },
        "workflow_revision": {
            "path": ".robine-ci/workflows/ci.yml",
            "source": "version: 1\nname: CI\n",
            "sources": {"shared.yml": "version: 1\nname: Shared\n"}
        }
    }))
    .expect("repeated input");
    let repeated = control_plane
        .create_pipeline(&maintainer, repeated_input)
        .await
        .expect("reuse identical idempotent pipeline");
    let conflicting: CreatePipelineInput = serde_json::from_value(serde_json::json!({
        "repository_id": repository_id,
        "workflow_name": "Different",
        "commit_sha": "d".repeat(40),
        "idempotency_key": idempotency_key
    }))
    .expect("conflicting input shape");
    let conflict = control_plane
        .create_pipeline(&maintainer, conflicting)
        .await;

    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("open verification transaction");
    let jobs = sqlx::query_as::<_, (String, String, Vec<String>)>(
        "SELECT job_key, status, needs FROM pipeline_jobs WHERE pipeline_id = $1 ORDER BY position",
    )
    .bind(created.id)
    .fetch_all(&mut *verification)
    .await
    .expect("read persisted graph");
    let revision = sqlx::query_as::<_, (String, String, serde_json::Value)>(
        "SELECT path, digest, included_sources FROM workflow_revisions WHERE pipeline_id = $1",
    )
    .bind(created.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read immutable revision");
    let event_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM outbox_events WHERE aggregate_id = $1 AND event_type = 'pipeline.created'",
    )
    .bind(created.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read creation event");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(created.id)
        .execute(&mut *verification)
        .await
        .expect("remove pipeline fixture");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(created.id)
        .execute(&mut *verification)
        .await
        .expect("remove event fixture");
    verification.commit().await.expect("commit cleanup");

    assert_eq!(created.id, repeated.id);
    assert_eq!(created.status, "created");
    assert!(matches!(
        conflict,
        Err(ApplicationError::IdempotencyConflict)
    ));
    assert_eq!(
        jobs,
        vec![
            ("build".into(), "queued".into(), Vec::new()),
            ("test".into(), "blocked".into(), vec!["build".into()])
        ]
    );
    assert_eq!(revision.0, ".robine-ci/workflows/ci.yml");
    assert_eq!(revision.1.len(), 64);
    assert_eq!(
        revision.2["shared.yml"]["source"],
        "version: 1\nname: Shared\n"
    );
    assert_eq!(event_count, 1);
}

#[tokio::test]
async fn creation_rolls_back_every_record_when_the_graph_insert_fails() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let pipeline_id = Uuid::new_v4();
    let duplicate_job_id = Uuid::new_v4();
    let now = Utc::now();
    let pipeline = NewPipeline {
        id: pipeline_id,
        repository_id: Uuid::new_v4(),
        workflow_name: "Rollback".into(),
        commit_sha: "f".repeat(40),
        source_ref: None,
        trigger: "manual".into(),
        actor: Uuid::new_v4().to_string(),
        correlation_id: Uuid::new_v4(),
        inserted_at: now,
        scheduled_for: None,
        inputs: std::collections::BTreeMap::new(),
        revision: NewWorkflowRevision {
            id: Uuid::new_v4(),
            path: "generated://rollback".into(),
            source: "{}".into(),
            digest: source_digest("{}"),
            normalized_graph: serde_json::json!({"jobs": {}}),
            included_sources: serde_json::json!({}),
        },
        jobs: vec![
            NewJob {
                id: duplicate_job_id,
                key: "one".into(),
                status: JobState::Queued,
                needs: Vec::new(),
                position: 0,
                execution: serde_json::json!({}),
            },
            NewJob {
                id: duplicate_job_id,
                key: "two".into(),
                status: JobState::Queued,
                needs: Vec::new(),
                position: 1,
                execution: serde_json::json!({}),
            },
        ],
        event_id: Uuid::new_v4(),
    };
    let failed = database.create("standalone", &pipeline).await;
    assert!(matches!(failed, Err(PortError::Unavailable)));

    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("open verification transaction");
    let counts = sqlx::query_as::<_, (i64, i64, i64, i64)>(
        "SELECT \
           (SELECT COUNT(*) FROM pipelines WHERE id = $1), \
           (SELECT COUNT(*) FROM workflow_revisions WHERE pipeline_id = $1), \
           (SELECT COUNT(*) FROM pipeline_jobs WHERE pipeline_id = $1), \
           (SELECT COUNT(*) FROM outbox_events WHERE aggregate_id = $1)",
    )
    .bind(pipeline_id)
    .fetch_one(&mut *verification)
    .await
    .expect("verify rollback");
    verification.rollback().await.expect("close transaction");
    assert_eq!(counts, (0, 0, 0, 0));
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn scheduler_claims_fairly_with_atomic_capacity_and_leases() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 4)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-scheduler-{}", Uuid::new_v4());
    let now = Utc::now();
    let first_repository = Uuid::new_v4();
    let second_repository = Uuid::new_v4();
    let make_pipeline = |repository_id: Uuid, inserted_at, keys: &[&str]| NewPipeline {
        id: Uuid::new_v4(),
        repository_id,
        workflow_name: "Scheduler".into(),
        commit_sha: "1".repeat(40),
        source_ref: None,
        trigger: "manual".into(),
        actor: Uuid::new_v4().to_string(),
        correlation_id: Uuid::new_v4(),
        inserted_at,
        scheduled_for: None,
        inputs: std::collections::BTreeMap::new(),
        revision: NewWorkflowRevision {
            id: Uuid::new_v4(),
            path: format!("generated://{}", Uuid::new_v4()),
            source: "{}".into(),
            digest: source_digest("{}"),
            normalized_graph: serde_json::json!({"jobs": {}}),
            included_sources: serde_json::json!({}),
        },
        jobs: keys
            .iter()
            .enumerate()
            .map(|(position, key)| NewJob {
                id: Uuid::new_v4(),
                key: (*key).into(),
                status: JobState::Queued,
                needs: Vec::new(),
                position: i32::try_from(position).expect("bounded test position"),
                execution: serde_json::json!({"runs_on": ["docker"]}),
            })
            .collect(),
        event_id: Uuid::new_v4(),
    };
    let first = make_pipeline(first_repository, now, &["alpha", "bravo"]);
    let second = make_pipeline(
        second_repository,
        now + chrono::Duration::milliseconds(1),
        &["charlie"],
    );
    database
        .create(&tenant, &first)
        .await
        .expect("create first queue");
    database
        .create(&tenant, &second)
        .await
        .expect("create second queue");
    database
        .queue(&tenant, first.id)
        .await
        .expect("queue first pipeline");
    database
        .queue(&tenant, second.id)
        .await
        .expect("queue second pipeline");

    let claim = |offset: i64| SchedulerClaim {
        global_limit: 2,
        repository_limit: 1,
        lease_seconds: 30,
        attempt_id: Uuid::new_v4(),
        idempotency_token: Uuid::new_v4(),
        event_id: Uuid::new_v4(),
        now: now + chrono::Duration::milliseconds(offset),
        runner_id: None,
    };
    let cross_tenant = database.claim_next_job("unrelated-tenant", &claim(1)).await;
    assert!(matches!(cross_tenant, Err(PortError::NoWork)));
    let mut handles = Vec::new();
    for offset in 2..6 {
        let task_database = database.clone();
        let task_tenant = tenant.clone();
        let task_claim = claim(offset);
        handles.push(tokio::spawn(async move {
            task_database
                .claim_next_job(&task_tenant, &task_claim)
                .await
        }));
    }
    let mut attempts = Vec::new();
    let mut capacity_count = 0;
    for handle in handles {
        match handle.await.expect("claim task completes") {
            Ok(attempt) => attempts.push(attempt),
            Err(PortError::Capacity) => capacity_count += 1,
            other => panic!("unexpected concurrent claim result: {other:?}"),
        }
    }
    assert_eq!(attempts.len(), 2);
    assert_eq!(capacity_count, 2);

    let mut verification = database
        .tenant_transaction(&tenant)
        .await
        .expect("open verification transaction");
    let claimed = sqlx::query_as::<_, (Uuid, String, String)>(
        "SELECT pipeline.repository_id, job.job_key, job.status \
         FROM pipeline_jobs AS job JOIN pipelines AS pipeline ON pipeline.id = job.pipeline_id \
         WHERE job.id = ANY($1) ORDER BY pipeline.inserted_at",
    )
    .bind(
        attempts
            .iter()
            .map(|attempt| attempt.job_id)
            .collect::<Vec<_>>(),
    )
    .fetch_all(&mut *verification)
    .await
    .expect("read claimed jobs");
    let projection_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM outbox_events WHERE aggregate_id = ANY($1) \
         AND event_type = 'pipeline.projection_requested' AND payload->>'dispatch' = 'false'",
    )
    .bind(vec![first.id, second.id])
    .fetch_one(&mut *verification)
    .await
    .expect("read claim projection events");
    sqlx::query("DELETE FROM pipelines WHERE id = ANY($1)")
        .bind(vec![first.id, second.id])
        .execute(&mut *verification)
        .await
        .expect("remove scheduler pipelines");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = ANY($1)")
        .bind(vec![first.id, second.id])
        .execute(&mut *verification)
        .await
        .expect("remove scheduler events");
    verification.commit().await.expect("commit cleanup");

    assert!(attempts.iter().all(|attempt| attempt.number == 1));
    assert!(attempts.iter().all(|attempt| attempt.last_sequence == 0));
    assert!(attempts.iter().all(|attempt| {
        attempt.lease_expires_at >= now + chrono::Duration::seconds(30)
            && attempt.lease_expires_at <= now + chrono::Duration::seconds(31)
    }));
    assert_eq!(
        claimed[0],
        (first_repository, "alpha".into(), "running".into())
    );
    assert_eq!(claimed[1].0, second_repository);
    assert_eq!(claimed[1].2, "running");
    assert_eq!(projection_count, 2);
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn ordered_attempt_events_release_dependencies_and_complete_pipeline() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-events-{}", Uuid::new_v4());
    let now = Utc::now();
    let pipeline = NewPipeline {
        id: Uuid::new_v4(),
        repository_id: Uuid::new_v4(),
        workflow_name: "Events".into(),
        commit_sha: "2".repeat(40),
        source_ref: None,
        trigger: "manual".into(),
        actor: Uuid::new_v4().to_string(),
        correlation_id: Uuid::new_v4(),
        inserted_at: now,
        scheduled_for: None,
        inputs: std::collections::BTreeMap::new(),
        revision: NewWorkflowRevision {
            id: Uuid::new_v4(),
            path: "generated://events".into(),
            source: "{}".into(),
            digest: source_digest("{}"),
            normalized_graph: serde_json::json!({"jobs": {}}),
            included_sources: serde_json::json!({}),
        },
        jobs: vec![
            NewJob {
                id: Uuid::new_v4(),
                key: "build".into(),
                status: JobState::Queued,
                needs: Vec::new(),
                position: 0,
                execution: serde_json::json!({"condition": "success"}),
            },
            NewJob {
                id: Uuid::new_v4(),
                key: "test".into(),
                status: JobState::Blocked,
                needs: vec!["build".into()],
                position: 1,
                execution: serde_json::json!({"condition": "success"}),
            },
        ],
        event_id: Uuid::new_v4(),
    };
    database
        .create(&tenant, &pipeline)
        .await
        .expect("create event graph");
    database
        .queue(&tenant, pipeline.id)
        .await
        .expect("queue event graph");
    let claim = |offset: i64| SchedulerClaim {
        global_limit: 4,
        repository_limit: 4,
        lease_seconds: 60,
        attempt_id: Uuid::new_v4(),
        idempotency_token: Uuid::new_v4(),
        event_id: Uuid::new_v4(),
        now: now + chrono::Duration::milliseconds(offset),
        runner_id: None,
    };
    let build = database
        .claim_next_job(&tenant, &claim(1))
        .await
        .expect("claim build");
    let event = |sequence, status: &str, reason: Option<&str>| RecordAttemptEvent {
        idempotency_token: build.idempotency_token,
        sequence,
        status: status.into(),
        reason: reason.map(str::to_owned),
    };
    let preparing = event(1, "preparing", None);
    database
        .record_attempt_event(&tenant, Uuid::new_v4(), &preparing, now)
        .await
        .expect("record preparing");
    let duplicate = database
        .record_attempt_event(&tenant, Uuid::new_v4(), &preparing, now)
        .await
        .expect("duplicate is idempotent");
    assert_eq!(duplicate.last_sequence, 1);
    let gap = database
        .record_attempt_event(&tenant, Uuid::new_v4(), &event(3, "running", None), now)
        .await;
    assert!(matches!(
        gap,
        Err(PortError::EventGap {
            expected: 2,
            actual: 3
        })
    ));
    database
        .record_attempt_event(&tenant, Uuid::new_v4(), &event(2, "running", None), now)
        .await
        .expect("record running");
    let succeeded = event(3, "succeeded", None);
    database
        .record_attempt_event(&tenant, Uuid::new_v4(), &succeeded, now)
        .await
        .expect("complete build");
    let test_attempt = database
        .claim_next_job(&tenant, &claim(2))
        .await
        .expect("dependency released");
    for (sequence, status, reason) in [
        (1, "preparing", None),
        (2, "running", None),
        (3, "failed", Some("command_failed")),
    ] {
        database
            .record_attempt_event(
                &tenant,
                Uuid::new_v4(),
                &RecordAttemptEvent {
                    idempotency_token: test_attempt.idempotency_token,
                    sequence,
                    status: status.into(),
                    reason: reason.map(str::to_owned),
                },
                now,
            )
            .await
            .expect("advance test attempt");
    }
    let cross_tenant = database
        .record_attempt_event("unrelated", Uuid::new_v4(), &succeeded, now)
        .await;
    assert!(matches!(cross_tenant, Err(PortError::NotFound)));

    let mut verification = database
        .tenant_transaction(&tenant)
        .await
        .expect("open verification transaction");
    let pipeline_state = sqlx::query_as::<_, (String, Option<chrono::NaiveDateTime>)>(
        "SELECT status, finished_at FROM pipelines WHERE id = $1",
    )
    .bind(pipeline.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read completed pipeline");
    let job_states = sqlx::query_as::<_, (String, String)>(
        "SELECT job_key, status FROM pipeline_jobs WHERE pipeline_id = $1 ORDER BY position",
    )
    .bind(pipeline.id)
    .fetch_all(&mut *verification)
    .await
    .expect("read terminal jobs");
    let terminal_events = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM outbox_events WHERE aggregate_id = $1 \
         AND event_type = 'pipeline.projection_requested' AND payload->>'dispatch' = 'true'",
    )
    .bind(pipeline.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read terminal projection events");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("remove event pipeline");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("remove event outbox");
    verification.commit().await.expect("commit cleanup");

    assert_eq!(pipeline_state.0, "failed");
    assert!(pipeline_state.1.is_some());
    assert_eq!(
        job_states,
        vec![
            ("build".into(), "succeeded".into()),
            ("test".into(), "failed".into())
        ]
    );
    assert_eq!(terminal_events, 2);
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn heartbeat_and_expiry_reconciliation_are_atomic_and_tenant_scoped() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-leases-{}", Uuid::new_v4());
    let now = Utc::now();
    let pipeline = NewPipeline {
        id: Uuid::new_v4(),
        repository_id: Uuid::new_v4(),
        workflow_name: "Leases".into(),
        commit_sha: "3".repeat(40),
        source_ref: None,
        trigger: "manual".into(),
        actor: Uuid::new_v4().to_string(),
        correlation_id: Uuid::new_v4(),
        inserted_at: now,
        scheduled_for: None,
        inputs: std::collections::BTreeMap::new(),
        revision: NewWorkflowRevision {
            id: Uuid::new_v4(),
            path: "generated://leases".into(),
            source: "{}".into(),
            digest: source_digest("{}"),
            normalized_graph: serde_json::json!({"jobs": {}}),
            included_sources: serde_json::json!({}),
        },
        jobs: vec![NewJob {
            id: Uuid::new_v4(),
            key: "test".into(),
            status: JobState::Queued,
            needs: Vec::new(),
            position: 0,
            execution: serde_json::json!({"condition": "success"}),
        }],
        event_id: Uuid::new_v4(),
    };
    database.create(&tenant, &pipeline).await.expect("create");
    database.queue(&tenant, pipeline.id).await.expect("queue");
    let claim = SchedulerClaim {
        global_limit: 4,
        repository_limit: 4,
        lease_seconds: 1,
        attempt_id: Uuid::new_v4(),
        idempotency_token: Uuid::new_v4(),
        event_id: Uuid::new_v4(),
        now,
        runner_id: None,
    };
    let attempt = database
        .claim_next_job(&tenant, &claim)
        .await
        .expect("claim");
    let runner_id = Uuid::new_v4();
    let credential_id = Uuid::new_v4();
    let credential = format!("rrc_{}{}", runner_id.simple(), "a".repeat(20));
    let secret_key_base = "rust-runner-heartbeat-test-key";
    let mut key_mac =
        Hmac::<Sha256>::new_from_slice(secret_key_base.as_bytes()).expect("valid HMAC key");
    key_mac.update(b"robine:runner-credential:v1");
    let key = key_mac.finalize().into_bytes();
    let mut credential_mac = Hmac::<Sha256>::new_from_slice(&key).expect("valid derived key");
    credential_mac.update(credential.as_bytes());
    let credential_digest = credential_mac.finalize().into_bytes();
    let mut fixture = database
        .tenant_transaction(&tenant)
        .await
        .expect("runner fixture transaction");
    sqlx::query(
        "INSERT INTO remote_runners \
         (id, name, admin_state, protocol_version, capabilities, labels, last_seen_at, \
          inserted_at, updated_at, tenant_id) \
         VALUES ($1, 'lease-runner', 'enabled', 1, \
                 '{\"docker\":true,\"concurrency\":2}', ARRAY['gpu'], $2, $2, $2, $3)",
    )
    .bind(runner_id)
    .bind(now)
    .bind(&tenant)
    .execute(&mut *fixture)
    .await
    .expect("insert runner");
    sqlx::query(
        "INSERT INTO runner_credentials \
         (id, runner_id, credential_digest, inserted_at, tenant_id) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(credential_id)
    .bind(runner_id)
    .bind(credential_digest.as_slice())
    .bind(now)
    .bind(&tenant)
    .execute(&mut *fixture)
    .await
    .expect("insert runner credential");
    sqlx::query("UPDATE job_attempts SET runner_id = $2 WHERE id = $1")
        .bind(attempt.id)
        .bind(runner_id.to_string())
        .execute(&mut *fixture)
        .await
        .expect("assign attempt to runner");
    fixture.commit().await.expect("commit runner fixture");
    let control_plane = ControlPlane::new(Arc::new(database.clone()), Arc::new(database.clone()))
        .with_runner_secret_key_base(secret_key_base);
    assert!(matches!(
        control_plane
            .heartbeat_runner_attempts(&tenant, runner_id, "rrc_invalid", 120)
            .await,
        Err(ApplicationError::Unauthenticated)
    ));
    let runner_heartbeat = control_plane
        .heartbeat_runner_attempts(&tenant, runner_id, &credential, 120)
        .await
        .expect("authenticated runner heartbeat");
    assert_eq!(runner_heartbeat.renewed_attempts, 1);
    assert!(
        runner_heartbeat
            .cancellation_requested_attempt_ids
            .is_empty()
    );
    let reported_lost = Uuid::new_v4();
    let reconciliation = control_plane
        .reconcile_runner_attempts(
            &tenant,
            runner_id,
            &credential,
            vec![attempt.id, reported_lost],
        )
        .await
        .expect("reconcile active runner attempts");
    assert_eq!(reconciliation.resume.len(), 1);
    assert_eq!(reconciliation.resume[0].attempt_id, attempt.id);
    assert_eq!(reconciliation.resume[0].acknowledged_sequence, 0);
    assert_eq!(reconciliation.lease_lost, vec![reported_lost]);
    assert!(matches!(
        control_plane
            .reconcile_runner_attempts(&tenant, runner_id, &credential, vec![Uuid::new_v4(); 65],)
            .await,
        Err(ApplicationError::InvalidAttemptEvent)
    ));
    let preparing = RecordRemoteAttemptEvent {
        idempotency_token: attempt.idempotency_token,
        message_id: Uuid::new_v4().to_string(),
        sequence: 1,
        status: "preparing".into(),
        reason: None,
    };
    let first_event = control_plane
        .record_remote_attempt_event(&tenant, runner_id, &credential, preparing.clone())
        .await
        .expect("record authenticated preparing event");
    assert_eq!(first_event.last_sequence, 1);
    let duplicate = control_plane
        .record_remote_attempt_event(&tenant, runner_id, &credential, preparing.clone())
        .await
        .expect("exact remote event replay is idempotent");
    assert_eq!(duplicate.last_sequence, 1);
    assert!(matches!(
        control_plane
            .record_remote_attempt_event(
                &tenant,
                runner_id,
                &credential,
                RecordRemoteAttemptEvent {
                    status: "running".into(),
                    ..preparing.clone()
                },
            )
            .await,
        Err(ApplicationError::IdempotencyConflict)
    ));
    assert!(matches!(
        control_plane
            .record_remote_attempt_event(
                &tenant,
                runner_id,
                &credential,
                RecordRemoteAttemptEvent {
                    message_id: Uuid::new_v4().to_string(),
                    sequence: 3,
                    status: "running".into(),
                    ..preparing.clone()
                },
            )
            .await,
        Err(ApplicationError::EventSequenceGap {
            expected: 2,
            actual: 3
        })
    ));
    let unowned = database
        .record_remote_attempt_event(
            &tenant,
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            &RecordRemoteAttemptEvent {
                message_id: Uuid::new_v4().to_string(),
                sequence: 2,
                status: "running".into(),
                ..preparing.clone()
            },
            now,
        )
        .await;
    assert!(matches!(unowned, Err(PortError::AttemptNotAssigned)));
    let running = control_plane
        .record_remote_attempt_event(
            &tenant,
            runner_id,
            &credential,
            RecordRemoteAttemptEvent {
                message_id: Uuid::new_v4().to_string(),
                sequence: 2,
                status: "running".into(),
                ..preparing
            },
        )
        .await
        .expect("record running event");
    assert_eq!(running.last_sequence, 2);
    let mut remote_pipeline = pipeline.clone();
    remote_pipeline.id = Uuid::new_v4();
    remote_pipeline.workflow_name = "Remote placement".into();
    remote_pipeline.revision.id = Uuid::new_v4();
    remote_pipeline.revision.path = "generated://remote-placement".into();
    remote_pipeline.event_id = Uuid::new_v4();
    let remote_job_id = Uuid::new_v4();
    remote_pipeline.jobs = vec![NewJob {
        id: remote_job_id,
        key: "gpu-test".into(),
        status: JobState::Queued,
        needs: Vec::new(),
        position: 0,
        execution: serde_json::json!({
            "runs_on": ["docker", "gpu"],
            "steps": [{"kind": "run", "value": "cargo test"}]
        }),
    }];
    database
        .create(&tenant, &remote_pipeline)
        .await
        .expect("create remote placement pipeline");
    database
        .queue(&tenant, remote_pipeline.id)
        .await
        .expect("queue remote placement pipeline");
    let remote_claim = SchedulerClaim {
        global_limit: 4,
        repository_limit: 4,
        lease_seconds: 60,
        attempt_id: Uuid::new_v4(),
        idempotency_token: Uuid::new_v4(),
        event_id: Uuid::new_v4(),
        now,
        runner_id: Some(runner_id),
    };
    let remote_attempt = database
        .claim_next_job(&tenant, &remote_claim)
        .await
        .expect("place matching work on remote runner");
    assert_eq!(remote_attempt.job_id, remote_job_id);
    let saturated = database
        .claim_next_job(
            &tenant,
            &SchedulerClaim {
                attempt_id: Uuid::new_v4(),
                idempotency_token: Uuid::new_v4(),
                event_id: Uuid::new_v4(),
                ..remote_claim.clone()
            },
        )
        .await;
    assert!(matches!(saturated, Err(PortError::Capacity)));
    let offer = control_plane
        .remote_job_offer(&tenant, runner_id, &credential, remote_attempt.id)
        .await
        .expect("owning runner reads normalized offer");
    assert_eq!(offer["attempt_id"], remote_attempt.id.to_string());
    assert_eq!(offer["job_key"], "gpu-test");
    assert_eq!(
        offer["build_env"]["ROBINE_BUILD_COMMIT_SHA"],
        "3".repeat(40)
    );
    assert!(matches!(
        database
            .remote_job_offer(&tenant, Uuid::new_v4(), remote_attempt.id)
            .await,
        Err(PortError::NotFound)
    ));
    let mut remote_cleanup = database
        .tenant_transaction(&tenant)
        .await
        .expect("remote placement cleanup transaction");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(remote_pipeline.id)
        .execute(&mut *remote_cleanup)
        .await
        .expect("cleanup remote outbox");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(remote_pipeline.id)
        .execute(&mut *remote_cleanup)
        .await
        .expect("cleanup remote pipeline");
    remote_cleanup
        .commit()
        .await
        .expect("commit remote cleanup");
    let mut cancellation_fixture = database
        .tenant_transaction(&tenant)
        .await
        .expect("cancellation fixture transaction");
    sqlx::query("UPDATE pipelines SET status = 'cancelling' WHERE id = $1")
        .bind(pipeline.id)
        .execute(&mut *cancellation_fixture)
        .await
        .expect("request cancellation");
    cancellation_fixture
        .commit()
        .await
        .expect("commit cancellation fixture");
    let cancellation_heartbeat = control_plane
        .heartbeat_runner_attempts(&tenant, runner_id, &credential, 120)
        .await
        .expect("heartbeat returns cancellation");
    assert_eq!(
        cancellation_heartbeat.cancellation_requested_attempt_ids,
        vec![attempt.id]
    );
    let mut restore = database
        .tenant_transaction(&tenant)
        .await
        .expect("restore transaction");
    sqlx::query("UPDATE pipelines SET status = 'running' WHERE id = $1")
        .bind(pipeline.id)
        .execute(&mut *restore)
        .await
        .expect("restore running pipeline");
    restore.commit().await.expect("commit restore");
    let renewed = database
        .heartbeat_attempt(&tenant, attempt.idempotency_token, 120, now)
        .await
        .expect("heartbeat");
    assert_eq!(renewed.last_sequence, 2);
    assert!(renewed.lease_expires_at >= now + Duration::seconds(120));
    assert_eq!(
        database
            .reconcile_expired_attempts(&tenant, 100, now + Duration::seconds(60))
            .await
            .expect("lease remains live"),
        0
    );
    assert_eq!(
        database
            .reconcile_expired_attempts("unrelated", 100, now + Duration::seconds(121))
            .await
            .expect("other tenant sees nothing"),
        0
    );
    assert_eq!(
        database
            .reconcile_expired_attempts(&tenant, 100, now + Duration::seconds(121))
            .await
            .expect("expired attempt recovered"),
        1
    );
    assert_eq!(
        database
            .reconcile_expired_attempts(&tenant, 100, now + Duration::seconds(122))
            .await
            .expect("terminal attempt is not repeated"),
        0
    );
    let after_expiry = control_plane
        .reconcile_runner_attempts(&tenant, runner_id, &credential, vec![attempt.id])
        .await
        .expect("terminal attempt loses lease on reconnect");
    assert!(after_expiry.resume.is_empty());
    assert_eq!(after_expiry.lease_lost, vec![attempt.id]);

    let mut verification = database
        .tenant_transaction(&tenant)
        .await
        .expect("verification transaction");
    let stored = sqlx::query_as::<_, (String, i32, Option<String>)>(
        "SELECT status, last_sequence, result_reason FROM job_attempts WHERE id = $1",
    )
    .bind(attempt.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read recovered attempt");
    let pipeline_status =
        sqlx::query_scalar::<_, String>("SELECT status FROM pipelines WHERE id = $1")
            .bind(pipeline.id)
            .fetch_one(&mut *verification)
            .await
            .expect("read failed pipeline");
    let receipt_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM runner_attempt_events WHERE attempt_id = $1",
    )
    .bind(attempt.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read durable runner receipts");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("cleanup pipeline");
    sqlx::query("DELETE FROM remote_runners WHERE id = $1")
        .bind(runner_id)
        .execute(&mut *verification)
        .await
        .expect("cleanup runner");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("cleanup outbox");
    verification.commit().await.expect("commit cleanup");

    assert_eq!(stored, ("failed".into(), 3, Some("runner_lost".into())));
    assert_eq!(pipeline_status, "failed");
    assert_eq!(receipt_count, 2);
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn sql_outbox_claims_once_enqueues_dispatch_and_dead_letters_bounded_failures() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 4)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-outbox-{}", Uuid::new_v4());
    let now = Utc::now();
    let pipeline = NewPipeline {
        id: Uuid::new_v4(),
        repository_id: Uuid::new_v4(),
        workflow_name: "SQL outbox".into(),
        commit_sha: "4".repeat(40),
        source_ref: None,
        trigger: "manual".into(),
        actor: Uuid::new_v4().to_string(),
        correlation_id: Uuid::new_v4(),
        inserted_at: now,
        scheduled_for: None,
        inputs: std::collections::BTreeMap::new(),
        revision: NewWorkflowRevision {
            id: Uuid::new_v4(),
            path: "generated://sql-outbox".into(),
            source: "{}".into(),
            digest: source_digest("{}"),
            normalized_graph: serde_json::json!({"jobs": {}}),
            included_sources: serde_json::json!({}),
        },
        jobs: vec![NewJob {
            id: Uuid::new_v4(),
            key: "test".into(),
            status: JobState::Queued,
            needs: Vec::new(),
            position: 0,
            execution: serde_json::json!({
                "image": "alpine:3.22",
                "shell": "/bin/sh",
                "timeout_ms": 10_000,
                "env": {},
                "services": {
                    "database": {
                        "id": "database",
                        "image": "alpine:3.22",
                        "env": {},
                        "secret_env": {},
                        "command": ["sleep", "30"],
                        "privileged": false
                    }
                },
                "steps": [{
                    "name": "test",
                    "kind": "run",
                    "value": "true",
                    "condition": "success"
                }]
            }),
        }],
        event_id: Uuid::new_v4(),
    };
    database
        .create(&tenant, &pipeline)
        .await
        .expect("create pending outbox event");
    let secret_id = Uuid::new_v4();
    let unauthorized_secret_id = Uuid::new_v4();
    let mut secret_fixture = database
        .tenant_transaction(&tenant)
        .await
        .expect("secret fixture transaction");
    for (id, repository_id, name) in [
        (secret_id, pipeline.repository_id, "TOKEN"),
        (unauthorized_secret_id, Uuid::new_v4(), "OTHER"),
    ] {
        sqlx::query(
            "INSERT INTO secrets (id, name, scope, repository_id, allowed_repository_ids, \
             ciphertext, nonce, tag, key_version, inserted_at, tenant_id) \
             VALUES ($1, $2, 'repository', $3, '{}', '\\x01', decode(repeat('00', 12), 'hex'), \
             decode(repeat('00', 16), 'hex'), 1, $4, $5)",
        )
        .bind(id)
        .bind(name)
        .bind(repository_id)
        .bind(now)
        .bind(&tenant)
        .execute(&mut *secret_fixture)
        .await
        .expect("insert secret fixture");
    }
    secret_fixture
        .commit()
        .await
        .expect("commit secret fixture");
    let authorized = SecretRepository::find_authorized(
        &database,
        &tenant,
        pipeline.repository_id,
        &["TOKEN".into(), "OTHER".into()],
    )
    .await
    .expect("resolve authorized secrets");
    assert_eq!(authorized.len(), 1);
    assert_eq!(authorized[0].id, secret_id);
    let process_at = now + Duration::seconds(1);
    let first_database = database.clone();
    let second_database = database.clone();
    let first_tenant = tenant.clone();
    let second_tenant = tenant.clone();
    let (first, second) = tokio::join!(
        async move {
            first_database
                .process_next_outbox_event(&first_tenant, process_at)
                .await
        },
        async move {
            second_database
                .process_next_outbox_event(&second_tenant, process_at)
                .await
        }
    );
    let outcomes = [first.expect("first worker"), second.expect("second worker")];
    assert_eq!(outcomes.iter().flatten().count(), 1);
    let delivered = outcomes.into_iter().flatten().next().expect("one delivery");
    assert!(delivered.delivered);
    assert!(delivered.dispatch_enqueued);
    assert_eq!(delivered.attempt, 1);
    assert!(
        database
            .process_next_outbox_event(&tenant, process_at)
            .await
            .expect("idempotent poll")
            .is_none()
    );

    let first_token = Uuid::new_v4();
    let second_token = Uuid::new_v4();
    let first_database = database.clone();
    let second_database = database.clone();
    let first_tenant = tenant.clone();
    let second_tenant = tenant.clone();
    let (first, second) = tokio::join!(
        async move {
            first_database
                .claim_next_dispatch_job(
                    &first_tenant,
                    first_token,
                    process_at,
                    process_at - Duration::minutes(5),
                )
                .await
        },
        async move {
            second_database
                .claim_next_dispatch_job(
                    &second_tenant,
                    second_token,
                    process_at,
                    process_at - Duration::minutes(5),
                )
                .await
        }
    );
    let dispatches = [
        first.expect("first dispatch worker"),
        second.expect("second dispatch worker"),
    ];
    assert_eq!(dispatches.iter().flatten().count(), 1);
    let dispatch = dispatches
        .into_iter()
        .flatten()
        .next()
        .expect("one durable dispatch claim");
    let scheduler_claim = SchedulerClaim {
        global_limit: 4,
        repository_limit: 2,
        lease_seconds: 60,
        attempt_id: Uuid::new_v4(),
        idempotency_token: Uuid::new_v4(),
        event_id: Uuid::new_v4(),
        now: process_at,
        runner_id: None,
    };
    let attempt = database
        .consume_dispatch_job(&tenant, dispatch.id, dispatch.claim_token, &scheduler_claim)
        .await
        .expect("consume dispatch atomically")
        .expect("ready job creates an attempt");
    let mut break_handoff = database
        .tenant_transaction(&tenant)
        .await
        .expect("handoff fixture transaction");
    let initial_execution_jobs = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM durable_jobs WHERE source_event_id = $1 \
         AND kind = 'execute_local_attempt'",
    )
    .bind(attempt.id)
    .fetch_one(&mut *break_handoff)
    .await
    .expect("read atomic execution handoff");
    sqlx::query(
        "DELETE FROM durable_jobs WHERE source_event_id = $1 AND kind = 'execute_local_attempt'",
    )
    .bind(attempt.id)
    .execute(&mut *break_handoff)
    .await
    .expect("simulate missing execution handoff");
    break_handoff
        .commit()
        .await
        .expect("commit missing handoff");
    assert_eq!(initial_execution_jobs, 1);
    assert_eq!(
        database
            .reconcile_local_execution_jobs(&tenant, 100, process_at)
            .await
            .expect("repair missing handoff"),
        1
    );
    assert_eq!(
        database
            .reconcile_local_execution_jobs(&tenant, 100, process_at)
            .await
            .expect("idempotent handoff repair"),
        0
    );

    let first_token = Uuid::new_v4();
    let second_token = Uuid::new_v4();
    let first_database = database.clone();
    let second_database = database.clone();
    let first_tenant = tenant.clone();
    let second_tenant = tenant.clone();
    let (first, second) = tokio::join!(
        async move {
            first_database
                .claim_next_execution_job(
                    &first_tenant,
                    first_token,
                    process_at,
                    process_at - Duration::minutes(5),
                )
                .await
        },
        async move {
            second_database
                .claim_next_execution_job(
                    &second_tenant,
                    second_token,
                    process_at,
                    process_at - Duration::minutes(5),
                )
                .await
        }
    );
    let executions = [
        first.expect("first execution worker"),
        second.expect("second execution worker"),
    ];
    assert_eq!(executions.iter().flatten().count(), 1);
    let execution = executions
        .into_iter()
        .flatten()
        .next()
        .expect("one durable execution claim");
    let execution_work = database
        .local_execution_work(&tenant, attempt.id)
        .await
        .expect("load local execution work");
    assert_eq!(execution_work.attempt.id, attempt.id);
    assert_eq!(execution_work.last_log_sequence, 0);
    assert!(execution_work.specification["services"].is_array());
    assert_eq!(
        execution_work.specification["attempt_id"],
        attempt.id.to_string()
    );
    let log_chunk = robine_core::pipelines::ExecutionLogChunk {
        id: Uuid::new_v4(),
        attempt_id: attempt.id,
        sequence: 1,
        step_position: 0,
        step_name: "test".into(),
        stream: "stdout".into(),
        content: b"\x1b[31mhello\x1b[0m".to_vec(),
        inserted_at: process_at,
    };
    database
        .append_execution_log(&tenant, &log_chunk)
        .await
        .expect("append execution output");
    database
        .append_execution_log(&tenant, &log_chunk)
        .await
        .expect("idempotent execution output replay");
    assert_eq!(
        database
            .local_execution_work(&tenant, attempt.id)
            .await
            .expect("reload execution cursor")
            .last_log_sequence,
        1
    );
    assert!(
        !database
            .cancellation_requested(&tenant, attempt.idempotency_token)
            .await
            .expect("read cancellation projection")
    );
    for (sequence, status, reason) in [
        (1, "preparing", None),
        (2, "running", None),
        (3, "succeeded", None),
    ] {
        database
            .record_attempt_event(
                &tenant,
                Uuid::new_v4(),
                &RecordAttemptEvent {
                    idempotency_token: attempt.idempotency_token,
                    sequence,
                    status: status.into(),
                    reason,
                },
                process_at,
            )
            .await
            .expect("advance local execution");
    }
    database
        .complete_durable_job(&tenant, execution.id, execution.claim_token, process_at)
        .await
        .expect("complete durable execution");

    let unsupported_id = Uuid::new_v4();
    let mut fixture = database
        .tenant_transaction(&tenant)
        .await
        .expect("outbox fixture transaction");
    sqlx::query(
        "INSERT INTO outbox_events \
         (id, event_type, aggregate_id, payload, occurred_at, available_at, inserted_at, tenant_id) \
         VALUES ($1, 'unsupported', $2, '{}', $3, $3, $3, $4)",
    )
    .bind(unsupported_id)
    .bind(pipeline.id)
    .bind(now)
    .bind(&tenant)
    .execute(&mut *fixture)
    .await
    .expect("insert unsupported event");
    fixture.commit().await.expect("commit unsupported event");
    let retry = database
        .process_next_outbox_event(&tenant, now)
        .await
        .expect("process retryable failure")
        .expect("failure outcome");
    assert!(!retry.delivered);
    assert_eq!(retry.attempt, 1);
    let mut force_final = database
        .tenant_transaction(&tenant)
        .await
        .expect("force final attempt transaction");
    sqlx::query("UPDATE outbox_events SET delivery_attempts = 9, available_at = $2 WHERE id = $1")
        .bind(unsupported_id)
        .bind(now)
        .execute(&mut *force_final)
        .await
        .expect("make retry due");
    force_final.commit().await.expect("commit final attempt");
    let discarded = database
        .process_next_outbox_event(&tenant, now)
        .await
        .expect("process final failure")
        .expect("discard outcome");
    assert_eq!(discarded.attempt, 10);
    assert!(!discarded.delivered);

    let mut verification = database
        .tenant_transaction(&tenant)
        .await
        .expect("outbox verification transaction");
    let pipeline_status =
        sqlx::query_scalar::<_, String>("SELECT status FROM pipelines WHERE id = $1")
            .bind(pipeline.id)
            .fetch_one(&mut *verification)
            .await
            .expect("read queued pipeline");
    let durable_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM durable_jobs WHERE source_event_id = $1 AND kind = 'run_next_job'",
    )
    .bind(pipeline.event_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read durable dispatch");
    let dispatch_status = sqlx::query_scalar::<_, String>(
        "SELECT status FROM durable_jobs WHERE source_event_id = $1 AND kind = 'run_next_job'",
    )
    .bind(pipeline.event_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read completed durable dispatch");
    let execution_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM durable_jobs WHERE source_event_id = $1 \
         AND kind = 'execute_local_attempt'",
    )
    .bind(attempt.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read repaired execution handoff");
    let execution_status = sqlx::query_scalar::<_, String>(
        "SELECT status FROM durable_jobs WHERE source_event_id = $1 \
         AND kind = 'execute_local_attempt'",
    )
    .bind(attempt.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read completed execution handoff");
    let stored_log = sqlx::query_as::<_, (i64, String, String)>(
        "SELECT COUNT(*), MIN(stream), MIN(content) FROM log_chunks WHERE attempt_id = $1",
    )
    .bind(attempt.id)
    .fetch_one(&mut *verification)
    .await
    .expect("read durable execution output");
    let dead_lettered = sqlx::query_scalar::<_, bool>(
        "SELECT dead_lettered_at IS NOT NULL FROM outbox_events WHERE id = $1",
    )
    .bind(unsupported_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read dead letter");
    sqlx::query("DELETE FROM durable_jobs WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *verification)
        .await
        .expect("cleanup durable jobs");
    sqlx::query("DELETE FROM outbox_events WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *verification)
        .await
        .expect("cleanup outbox");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("cleanup pipeline");
    sqlx::query("DELETE FROM secrets WHERE id = ANY($1)")
        .bind([secret_id, unauthorized_secret_id])
        .execute(&mut *verification)
        .await
        .expect("cleanup secrets");
    verification.commit().await.expect("commit cleanup");

    assert_eq!(pipeline_status, "succeeded");
    assert_eq!(durable_count, 1);
    assert_eq!(dispatch_status, "completed");
    assert_eq!(execution_count, 1);
    assert_eq!(execution_status, "completed");
    assert_eq!(stored_log, (1, "stdout".into(), "hello".into()));
    assert!(dead_lettered);
}
