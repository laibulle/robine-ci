use std::sync::{
    Arc,
    atomic::{AtomicI64, Ordering},
};

use argon2::{
    Argon2,
    password_hash::{PasswordHasher, SaltString},
};
use async_trait::async_trait;
use chrono::{Duration, Timelike, Utc};
use hmac::{Hmac, Mac};
use robine_application::{ApplicationError, ControlPlane, RetentionConfig};
use robine_core::{
    identity::{OidcAuthorization, OidcClaims, Role, User},
    pipelines::{
        CreatePipelineInput, JobState, NewJob, NewPipeline, NewWorkflowRevision,
        RecordAttemptEvent, RecordRemoteAttemptEvent, SchedulerClaim, SourceControlDelivery,
        source_digest,
    },
    ports::{IdentityRepository, OidcProvider, PipelineRepository, PortError},
};
use robine_persistence::{Database, PersistenceError, Readiness, storage_transition_ack};
use robine_secrets::{AesGcmKeyring, SecretRepository};
use robine_source::{
    ArchiveFetcher, ArchiveLimits, AvailableRepository, BranchHead, Provider, Repository,
    RepositoryStore, SourceError, SourceFile, SourceInspector, StatusProjection, StatusProjector,
    create_source_tar_gz,
};
use robine_storage::{
    Artifact, BlobStore, CacheEntry, LocalBlobStore, MetadataRepository, StorageError,
    StorageQuotas, StoredObject,
};
use sha2::{Digest, Sha256};
use sqlx::{
    PgPool,
    postgres::{PgConnectOptions, PgPoolOptions},
};
use uuid::Uuid;

struct FakeOidc(OidcClaims);

struct WorkflowArchive(Vec<u8>);

#[derive(Default)]
struct RecordingStatusProjector(AtomicI64);

#[tokio::test]
async fn instance_github_credentials_are_encrypted_write_only_and_replaceable() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let pool = PgPool::connect(&database_url).await.expect("database");
    let database = Database::from_pool(pool.clone());
    let tenant = format!("instance-secret-{}", Uuid::new_v4());
    let actor = Uuid::new_v4();
    let keyring = AesGcmKeyring::from_encoded(
        Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
        None,
        1,
    )
    .expect("keyring");
    for value in [b"first-private-key".as_slice(), b"replacement-private-key"] {
        let secret = keyring
            .encrypt_instance("GITHUB_APP_PRIVATE_KEY".into(), value)
            .expect("encrypt instance secret");
        database
            .upsert_instance(&tenant, actor, &secret)
            .await
            .expect("store instance secret");
    }
    let stored = database
        .find_instance(&tenant, "GITHUB_APP_PRIVATE_KEY")
        .await
        .expect("load instance secret")
        .expect("stored instance secret");
    assert_ne!(stored.ciphertext, b"replacement-private-key");
    assert_eq!(
        keyring.decrypt(&stored).expect("decrypt").as_slice(),
        b"replacement-private-key"
    );
    let count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM secrets WHERE tenant_id = $1 AND scope = 'instance'",
    )
    .bind(&tenant)
    .fetch_one(&pool)
    .await
    .expect("instance secret count");
    assert_eq!(count, 1);
    sqlx::query("DELETE FROM audit_events WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&pool)
        .await
        .expect("cleanup audit");
    sqlx::query("DELETE FROM secrets WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&pool)
        .await
        .expect("cleanup secret");
}

#[tokio::test]
async fn trusting_a_rediscovered_github_repository_is_idempotent_and_audited() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let pool = PgPool::connect(&database_url).await.expect("database");
    let database = Database::from_pool(pool.clone());
    let tenant = format!("github-discovery-{}", Uuid::new_v4());
    let actor = Uuid::new_v4();
    let available = AvailableRepository {
        provider_id: Utc::now().timestamp_micros(),
        installation_id: 42,
        full_name: "acme/discovered".into(),
        private: true,
    };

    let first = RepositoryStore::trust_github(&database, &tenant, actor, &available)
        .await
        .expect("trust repository");
    let second = RepositoryStore::trust_github(&database, &tenant, actor, &available)
        .await
        .expect("repeat trust");

    assert_eq!(first.id, second.id);
    assert_eq!(first.full_name, "acme/discovered");
    let webhook_at = Utc::now();
    sqlx::query(
        "INSERT INTO github_deliveries \
         (id, event, payload, status, received_at, processed_at, provider, provider_instance, provider_delivery_id, tenant_id) \
         VALUES ($1, 'push', $2, 'processed', $3, $3, 'github', 'https://github.com', $1, $4)",
    )
    .bind(format!("delivery-{}", Uuid::new_v4()))
    .bind(serde_json::json!({"repository": {"full_name": "acme/discovered"}}))
    .bind(webhook_at)
    .bind(&tenant)
    .execute(&pool)
    .await
    .expect("insert delivery activity");
    let activity = RepositoryStore::integration_activity(&database, &tenant, &first)
        .await
        .expect("integration activity");
    assert_eq!(activity.last_webhook_status.as_deref(), Some("processed"));
    assert!(activity.last_webhook_at.is_some());
    let repository_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM github_repositories WHERE tenant_id = $1 AND provider_id = $2",
    )
    .bind(&tenant)
    .bind(available.provider_id)
    .fetch_one(&pool)
    .await
    .expect("repository count");
    let audit_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM audit_events WHERE tenant_id = $1 AND action = 'repository.trusted' AND target_id = $2",
    )
    .bind(&tenant)
    .bind(first.id)
    .fetch_one(&pool)
    .await
    .expect("audit count");
    assert_eq!(repository_count, 1);
    assert_eq!(audit_count, 2);
    sqlx::query("DELETE FROM audit_events WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&pool)
        .await
        .expect("cleanup audit");
    sqlx::query("DELETE FROM github_deliveries WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&pool)
        .await
        .expect("cleanup delivery");
    sqlx::query("DELETE FROM github_repositories WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&pool)
        .await
        .expect("cleanup repository");
}

#[async_trait]
impl StatusProjector for RecordingStatusProjector {
    async fn upsert_status(
        &self,
        _repository: &Repository,
        _projection: &StatusProjection,
    ) -> Result<i64, SourceError> {
        Ok(self.0.fetch_add(1, Ordering::SeqCst) + 1)
    }
}

#[tokio::test]
async fn rust_bootstrap_creates_and_revalidates_a_fresh_database() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let options = database_url
        .parse::<PgConnectOptions>()
        .expect("database URL");
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options.clone().database("postgres"))
        .await
        .expect("admin database");
    let database_name = format!("robine_rust_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE DATABASE \"{database_name}\""))
        .execute(&admin)
        .await
        .expect("create fresh database");
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect_with(options.database(&database_name))
        .await
        .expect("fresh database");
    let database = Database::from_pool(pool.clone());
    database.bootstrap_schema().await.expect("bootstrap schema");
    database
        .bootstrap_schema()
        .await
        .expect("idempotent schema validation");
    assert_eq!(
        database
            .storage_tenants()
            .await
            .expect("list fresh tenants"),
        vec!["standalone"]
    );
    let tables = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('pipelines', 'durable_jobs', 'secrets', 'remote_runners')").fetch_one(&pool).await.expect("schema tables");
    assert_eq!(tables, 4);
    pool.close().await;
    drop(database);
    sqlx::query(&format!("DROP DATABASE \"{database_name}\" WITH (FORCE)"))
        .execute(&admin)
        .await
        .expect("drop fresh database");
}

#[tokio::test]
async fn repository_secrets_are_encrypted_upserted_and_listed_with_audit() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-secrets-{}", Uuid::new_v4());
    let repository_id = Uuid::new_v4();
    let actor_id = Uuid::new_v4();
    let keyring = AesGcmKeyring::from_encoded(
        Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
        None,
        1,
    )
    .expect("keyring");
    let first = keyring
        .encrypt_repository(repository_id, "TOKEN".into(), b"first-secret")
        .expect("encrypt");
    SecretRepository::upsert_repository(&database, &tenant, actor_id, &first)
        .await
        .expect("store secret");
    let second = keyring
        .encrypt_repository(repository_id, "TOKEN".into(), b"second-secret")
        .expect("encrypt replacement");
    SecretRepository::upsert_repository(&database, &tenant, actor_id, &second)
        .await
        .expect("replace secret");
    let listed = SecretRepository::list_repository(&database, &tenant, repository_id)
        .await
        .expect("list secrets");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, second.id);
    assert_eq!(
        keyring.decrypt(&listed[0]).expect("decrypt").as_slice(),
        b"second-secret"
    );
    let mut cleanup = database
        .tenant_transaction(&tenant)
        .await
        .expect("cleanup transaction");
    let audit_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM audit_events WHERE tenant_id = $1 AND target_type = 'secret'",
    )
    .bind(&tenant)
    .fetch_one(&mut *cleanup)
    .await
    .expect("audit count");
    assert_eq!(audit_count, 2);
    sqlx::query("DELETE FROM audit_events WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *cleanup)
        .await
        .expect("delete audits");
    sqlx::query("DELETE FROM secrets WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *cleanup)
        .await
        .expect("delete secrets");
    cleanup.commit().await.expect("commit cleanup");
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn interrupted_secret_rotation_resumes_with_mixed_version_reads_and_atomic_audit() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let tenant = format!("rust-secret-rotation-{}", Uuid::new_v4());
    let repository_id = Uuid::new_v4();
    let administrator = User {
        id: Uuid::new_v4(),
        email: "rotation@example.invalid".into(),
        role: Role::Administrator,
        disabled: false,
        inserted_at: Utc::now(),
    };
    let old_keyring = AesGcmKeyring::from_encoded(
        Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
        None,
        1,
    )
    .expect("old keyring");
    let rotating_keyring = Arc::new(
        AesGcmKeyring::from_encoded(
            None,
            Some(
                r#"{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","2":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="}"#,
            ),
            2,
        )
        .expect("rotating keyring"),
    );
    for (name, value) in [
        ("FIRST", b"first-secret".as_slice()),
        ("SECOND", b"second-secret".as_slice()),
    ] {
        let secret = old_keyring
            .encrypt_repository(repository_id, name.into(), value)
            .expect("encrypt old secret");
        SecretRepository::upsert_repository(&*database, &tenant, administrator.id, &secret)
            .await
            .expect("store old secret");
    }
    let control_plane = ControlPlane::new(database.clone(), database.clone())
        .with_secret_runtime(database.clone(), rotating_keyring.clone());
    let first = control_plane
        .rotate_secrets(&tenant, &administrator, None, 1)
        .await
        .expect("first rotation batch");
    assert_eq!(first.rotated, 1);
    assert!(!first.complete);
    let mixed = SecretRepository::list_repository(&*database, &tenant, repository_id)
        .await
        .expect("mixed version read");
    assert_eq!(
        mixed
            .iter()
            .filter(|secret| secret.key_version == 2)
            .count(),
        1
    );
    for secret in &mixed {
        rotating_keyring
            .decrypt(secret)
            .expect("decrypt mixed secret");
    }
    let second = control_plane
        .rotate_secrets(&tenant, &administrator, first.next_cursor, 1)
        .await
        .expect("resumed rotation batch");
    assert_eq!(second.rotated, 1);
    let finished = control_plane
        .rotate_secrets(&tenant, &administrator, second.next_cursor, 1)
        .await
        .expect("finish rotation");
    assert!(finished.complete);
    assert_eq!(finished.rotated, 0);

    let mut verification = database
        .tenant_transaction(&tenant)
        .await
        .expect("rotation verification");
    let versions = sqlx::query_scalar::<_, i32>(
        "SELECT key_version FROM secrets WHERE tenant_id = $1 ORDER BY id",
    )
    .bind(&tenant)
    .fetch_all(&mut *verification)
    .await
    .expect("rotated versions");
    assert_eq!(versions, vec![2, 2]);
    let audits = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM audit_events WHERE tenant_id = $1 AND action = 'secret.key_rotated'",
    )
    .bind(&tenant)
    .fetch_one(&mut *verification)
    .await
    .expect("rotation audits");
    assert_eq!(audits, 2);
    sqlx::query("DELETE FROM audit_events WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *verification)
        .await
        .expect("delete audits");
    sqlx::query("DELETE FROM secrets WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *verification)
        .await
        .expect("delete secrets");
    verification.commit().await.expect("commit cleanup");
}

#[async_trait]
impl ArchiveFetcher for WorkflowArchive {
    async fn fetch_archive(
        &self,
        _repository: &Repository,
        _commit_sha: &str,
    ) -> Result<Vec<u8>, SourceError> {
        Ok(self.0.clone())
    }
}

#[async_trait]
impl SourceInspector for WorkflowArchive {
    async fn default_branch_head(
        &self,
        _repository: &Repository,
    ) -> Result<BranchHead, SourceError> {
        Ok(BranchHead {
            branch: "main".into(),
            commit_sha: "b".repeat(40),
        })
    }

    async fn branch_head(
        &self,
        _repository: &Repository,
        branch: &str,
    ) -> Result<BranchHead, SourceError> {
        Ok(BranchHead {
            branch: branch.into(),
            commit_sha: "b".repeat(40),
        })
    }
}

#[tokio::test]
async fn manual_workflow_discovery_and_launch_are_exact_sha_and_audited() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let repository_id = Uuid::new_v4();
    let provider_id = i64::from_be_bytes(
        repository_id.as_bytes()[..8]
            .try_into()
            .expect("UUID prefix"),
    ) & i64::MAX;
    let mut setup = database
        .tenant_transaction("standalone")
        .await
        .expect("setup transaction");
    sqlx::query("INSERT INTO github_repositories (id, provider_id, installation_id, owner, name, full_name, trusted, inserted_at, provider, provider_instance, tenant_id) VALUES ($1, $2, 1, 'acme', 'manual', 'acme/manual', TRUE, $3, 'github', 'https://github.com', 'standalone')")
        .bind(repository_id).bind(provider_id).bind(Utc::now())
        .execute(&mut *setup).await.expect("insert repository");
    setup.commit().await.expect("commit repository");
    let archive = create_source_tar_gz(&[SourceFile {
        path: ".robine-ci/workflows/manual.yml".into(),
        contents: b"version: 1\nname: Deploy\non:\n  workflow_dispatch:\n    inputs:\n      target:\n        type: choice\n        options: [staging, production]\n        required: true\njobs:\n  deploy:\n    image: alpine:3.22\n    steps:\n      - run: echo deploy\n".to_vec(),
    }], ArchiveLimits::default()).expect("manual workflow archive");
    let source = Arc::new(WorkflowArchive(archive));
    let control_plane = ControlPlane::new(database.clone(), database.clone())
        .with_source_runtime(database.clone(), source.clone())
        .with_source_inspector(source);
    let maintainer = User {
        id: Uuid::new_v4(),
        email: "manual@example.invalid".into(),
        role: Role::Maintainer,
        disabled: false,
        inserted_at: Utc::now(),
    };
    let discovery = control_plane
        .discover_manual_workflows(&maintainer, repository_id, Some("release"))
        .await
        .expect("discover manual workflow");
    assert_eq!(discovery["branch"], "release");
    assert_eq!(discovery["workflows"].as_array().map(Vec::len), Some(1));
    let pipeline = control_plane
        .launch_manual_workflow(
            &maintainer,
            repository_id,
            Some("release"),
            ".robine-ci/workflows/manual.yml",
            &Uuid::new_v4().to_string(),
            std::collections::BTreeMap::from([("target".into(), "production".into())]),
        )
        .await
        .expect("launch workflow");
    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("verification transaction");
    let audit_count = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM audit_events WHERE tenant_id = 'standalone' AND action = 'workflow.manual_launched' AND target_id = $1 AND metadata->>'pipeline_id' = $2").bind(repository_id).bind(pipeline.id.to_string()).fetch_one(&mut *verification).await.expect("audit count");
    assert_eq!(audit_count, 1);
    sqlx::query("DELETE FROM audit_events WHERE target_id = $1")
        .bind(repository_id)
        .execute(&mut *verification)
        .await
        .expect("delete audit");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("delete pipeline");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(pipeline.id)
        .execute(&mut *verification)
        .await
        .expect("delete outbox");
    sqlx::query("DELETE FROM github_repositories WHERE id = $1")
        .bind(repository_id)
        .execute(&mut *verification)
        .await
        .expect("delete repository");
    verification.commit().await.expect("commit cleanup");
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn scheduled_reconciliation_is_exact_sha_durable_and_idempotent() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let repository_id = Uuid::new_v4();
    let provider_id = i64::from_be_bytes(
        repository_id.as_bytes()[..8]
            .try_into()
            .expect("UUID prefix"),
    ) & i64::MAX;
    let repository_name = format!("scheduled-{provider_id}");
    let repository_full_name = format!("acme/{repository_name}");
    let mut setup = database
        .tenant_transaction("standalone")
        .await
        .expect("setup transaction");
    sqlx::query(
        "DELETE FROM github_repositories WHERE tenant_id = 'standalone' AND owner = 'acme' AND name LIKE 'scheduled%'",
    )
    .execute(&mut *setup)
    .await
    .expect("remove stale scheduled-test repositories");
    sqlx::query("DELETE FROM schedule_reconciliation_states WHERE tenant_id = 'standalone' AND key = 'scheduled-workflows:v1'")
        .execute(&mut *setup)
        .await
        .expect("reset schedule cursor");
    sqlx::query("INSERT INTO github_repositories (id, provider_id, installation_id, owner, name, full_name, trusted, inserted_at, provider, provider_instance, tenant_id) VALUES ($1, $2, 1, 'acme', $3, $4, TRUE, $5, 'github', 'https://github.com', 'standalone')")
        .bind(repository_id)
        .bind(provider_id)
        .bind(&repository_name)
        .bind(&repository_full_name)
        .bind(Utc::now())
        .execute(&mut *setup)
        .await
        .expect("insert repository");
    setup.commit().await.expect("commit repository");
    let now = Utc::now();
    let invalid_archive = create_source_tar_gz(
        &[SourceFile {
            path: ".robine-ci/workflows/nightly.yml".into(),
            contents: b"version: 1\nname: Nightly\non:\n  schedule:\n    - cron: '@daily'\njobs:\n  test:\n    image: alpine:3.22\n    steps:\n      - run: echo scheduled\n"
                .to_vec(),
        }],
        ArchiveLimits::default(),
    )
    .expect("invalid workflow archive");
    let invalid_source = Arc::new(WorkflowArchive(invalid_archive));
    let invalid_control_plane = ControlPlane::new(database.clone(), database.clone())
        .with_source_runtime(database.clone(), invalid_source.clone())
        .with_source_inspector(invalid_source);
    assert!(matches!(
        invalid_control_plane
            .reconcile_scheduled_workflows(now)
            .await,
        Err(ApplicationError::InvalidWorkflow(_))
    ));
    let mut failed_scan = database
        .tenant_transaction("standalone")
        .await
        .expect("failed scan transaction");
    let failed_state = sqlx::query_as::<_, (Option<chrono::NaiveDateTime>, Option<String>)>(
        "SELECT cursor, last_failure FROM schedule_reconciliation_states WHERE tenant_id = 'standalone' AND key = 'scheduled-workflows:v1'",
    )
    .fetch_one(&mut *failed_scan)
    .await
    .expect("failed schedule state");
    assert!(failed_state.0.is_none());
    assert_eq!(failed_state.1.as_deref(), Some("invalid_workflow"));
    failed_scan.commit().await.expect("commit failed scan read");

    let archive = create_source_tar_gz(
        &[SourceFile {
            path: ".robine-ci/workflows/nightly.yml".into(),
            contents: b"version: 1\nname: Nightly\non:\n  schedule:\n    - cron: '* * * * *'\njobs:\n  test:\n    image: alpine:3.22\n    steps:\n      - run: echo scheduled\n"
                .to_vec(),
        }],
        ArchiveLimits::default(),
    )
    .expect("scheduled workflow archive");
    let source = Arc::new(WorkflowArchive(archive));
    let control_plane = ControlPlane::new(database.clone(), database.clone())
        .with_source_runtime(database.clone(), source.clone())
        .with_source_inspector(source)
        .with_status_projector(Arc::new(RecordingStatusProjector::default()));
    let first = control_plane
        .reconcile_scheduled_workflows(now)
        .await
        .expect("first reconciliation");
    assert_eq!(first.scanned_minutes, 1);
    assert!(first.due_occurrences >= 1);
    assert!(first.pipelines >= 1);
    assert!(first.cursor_advanced);
    let mut own_pipeline_verification = database
        .tenant_transaction("standalone")
        .await
        .expect("own scheduled pipeline verification");
    let own_pipeline_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM pipelines WHERE tenant_id = 'standalone' AND repository_id = $1 AND trigger = 'schedule'",
    )
    .bind(repository_id)
    .fetch_one(&mut *own_pipeline_verification)
    .await
    .expect("count own scheduled pipeline");
    own_pipeline_verification
        .commit()
        .await
        .expect("commit own pipeline verification");
    assert_eq!(own_pipeline_count, 1);
    let duplicate = control_plane
        .reconcile_scheduled_workflows(now)
        .await
        .expect("duplicate reconciliation");
    assert_eq!(duplicate.scanned_minutes, 0);

    let future_cursor =
        now.with_nanosecond(0).expect("valid second precision") + Duration::minutes(10);
    let mut future_setup = database
        .tenant_transaction("standalone")
        .await
        .expect("future cursor transaction");
    sqlx::query("UPDATE schedule_reconciliation_states SET cursor = $1 WHERE tenant_id = 'standalone' AND key = 'scheduled-workflows:v1'")
        .bind(future_cursor)
        .execute(&mut *future_setup)
        .await
        .expect("set future cursor");
    future_setup.commit().await.expect("commit future cursor");
    let future_scan = control_plane
        .reconcile_scheduled_workflows(now)
        .await
        .expect("future cursor reconciliation");
    assert_eq!(future_scan.scanned_minutes, 0);
    let mut future_verification = database
        .tenant_transaction("standalone")
        .await
        .expect("future cursor verification transaction");
    let persisted_future = sqlx::query_scalar::<_, Option<chrono::NaiveDateTime>>(
        "SELECT cursor FROM schedule_reconciliation_states WHERE tenant_id = 'standalone' AND key = 'scheduled-workflows:v1'",
    )
    .fetch_one(&mut *future_verification)
    .await
    .expect("read future cursor")
    .expect("cursor present")
    .and_utc();
    assert_eq!(persisted_future, future_cursor);
    future_verification
        .commit()
        .await
        .expect("commit future verification");

    let outbox = control_plane
        .process_outbox_batch("standalone", 100)
        .await
        .expect("process pipeline outbox");
    assert!(outbox.dispatch_enqueued >= 1);
    let projected = control_plane
        .process_status_projection_batch("standalone", 100)
        .await
        .expect("project GitHub checks");
    assert!(projected.projected >= 1);

    let mut projection_setup = database
        .tenant_transaction("standalone")
        .await
        .expect("projection serialization setup");
    let projection_pipeline_id =
        sqlx::query_scalar::<_, Uuid>("SELECT id FROM pipelines WHERE repository_id = $1")
            .bind(repository_id)
            .fetch_one(&mut *projection_setup)
            .await
            .expect("projection pipeline ID");
    for source_event_id in [Uuid::new_v4(), Uuid::new_v4()] {
        sqlx::query(
            "INSERT INTO durable_jobs (id, source_event_id, kind, payload, status, attempts, available_at, inserted_at, updated_at, tenant_id) \
             VALUES ($1, $2, 'project_status', $3, 'available', 0, $4, $4, $4, 'standalone')",
        )
        .bind(Uuid::new_v4())
        .bind(source_event_id)
        .bind(serde_json::json!({"pipeline_id": projection_pipeline_id}))
        .bind(Utc::now())
        .execute(&mut *projection_setup)
        .await
        .expect("insert projection job");
    }
    projection_setup
        .commit()
        .await
        .expect("commit projection jobs");
    let claim_time = Utc::now();
    let first_claim = database
        .claim_next_status_projection_job(
            "standalone",
            Uuid::new_v4(),
            claim_time,
            claim_time - Duration::minutes(5),
        )
        .await
        .expect("claim first serialized projection")
        .expect("first projection present");
    assert!(
        database
            .claim_next_status_projection_job(
                "standalone",
                Uuid::new_v4(),
                claim_time,
                claim_time - Duration::minutes(5),
            )
            .await
            .expect("attempt concurrent projection")
            .is_none()
    );
    database
        .complete_durable_job(
            "standalone",
            first_claim.id,
            first_claim.claim_token,
            Utc::now(),
        )
        .await
        .expect("complete first projection");
    let second_claim = database
        .claim_next_status_projection_job(
            "standalone",
            Uuid::new_v4(),
            Utc::now(),
            Utc::now() - Duration::minutes(5),
        )
        .await
        .expect("claim second serialized projection")
        .expect("second projection present");
    database
        .complete_durable_job(
            "standalone",
            second_claim.id,
            second_claim.claim_token,
            Utc::now(),
        )
        .await
        .expect("complete second projection");
    let repair_time = Utc::now();
    let repairs = database
        .reconcile_status_projection_jobs("standalone", 1_000, repair_time)
        .await
        .expect("enqueue repair projections");
    assert!(repairs >= 1);
    assert_eq!(
        database
            .reconcile_status_projection_jobs("standalone", 1_000, repair_time)
            .await
            .expect("repeat repair reconciliation"),
        0
    );

    let mut verification = database
        .tenant_transaction("standalone")
        .await
        .expect("verification transaction");
    let pipeline = sqlx::query_as::<_, (Uuid, String, String, String, Option<chrono::NaiveDateTime>)>(
        "SELECT id, commit_sha, trigger, actor, scheduled_for FROM pipelines WHERE repository_id = $1",
    )
    .bind(repository_id)
    .fetch_one(&mut *verification)
    .await
    .expect("scheduled pipeline");
    assert_eq!(pipeline.1, "b".repeat(40));
    assert_eq!(pipeline.2, "schedule");
    assert_eq!(pipeline.3, "system:scheduler");
    assert!(pipeline.4.is_some());
    let count =
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM pipelines WHERE repository_id = $1")
            .bind(repository_id)
            .fetch_one(&mut *verification)
            .await
            .expect("pipeline count");
    assert_eq!(count, 1);
    let audit = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM audit_events WHERE action = 'workflow.scheduled' AND metadata->>'pipeline_id' = $1",
    )
    .bind(pipeline.0.to_string())
    .fetch_one(&mut *verification)
    .await
    .expect("schedule audit");
    assert_eq!(audit, 1);
    let schedule_metrics = sqlx::query_as::<_, (String, i32, i32, i32, i64, i64)>(
        "SELECT last_outcome, last_scanned_minutes, last_due_occurrences, \
                last_pipeline_count, last_truncated_minutes, last_duration_ms \
         FROM schedule_reconciliation_states \
         WHERE tenant_id = 'standalone' AND key = 'scheduled-workflows:v1'",
    )
    .fetch_one(&mut *verification)
    .await
    .expect("scheduler metrics");
    assert_eq!(schedule_metrics.0, "success");
    assert_eq!(schedule_metrics.1, 1);
    assert_eq!(schedule_metrics.2, 1);
    assert_eq!(schedule_metrics.3, 1);
    assert_eq!(schedule_metrics.4, 0);
    assert!(schedule_metrics.5 >= 0);
    let checks = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM github_checks WHERE pipeline_id = $1 AND provider = 'github'",
    )
    .bind(pipeline.0)
    .fetch_one(&mut *verification)
    .await
    .expect("GitHub check count");
    assert_eq!(checks, 2);
    sqlx::query("DELETE FROM github_checks WHERE pipeline_id = $1")
        .bind(pipeline.0)
        .execute(&mut *verification)
        .await
        .expect("delete checks");
    sqlx::query("DELETE FROM durable_jobs WHERE payload->>'pipeline_id' = $1")
        .bind(pipeline.0.to_string())
        .execute(&mut *verification)
        .await
        .expect("delete durable jobs");
    sqlx::query("DELETE FROM outbox_events WHERE aggregate_id = $1")
        .bind(pipeline.0)
        .execute(&mut *verification)
        .await
        .expect("delete outbox");
    sqlx::query("DELETE FROM pipelines WHERE id = $1")
        .bind(pipeline.0)
        .execute(&mut *verification)
        .await
        .expect("delete pipeline");
    sqlx::query("DELETE FROM audit_events WHERE target_id = $1")
        .bind(repository_id)
        .execute(&mut *verification)
        .await
        .expect("delete audit");
    sqlx::query("DELETE FROM github_repositories WHERE id = $1")
        .bind(repository_id)
        .execute(&mut *verification)
        .await
        .expect("delete repository");
    sqlx::query("DELETE FROM schedule_reconciliation_states WHERE tenant_id = 'standalone' AND key = 'scheduled-workflows:v1'")
        .execute(&mut *verification)
        .await
        .expect("delete cursor");
    verification.commit().await.expect("commit cleanup");
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn source_control_worker_creates_an_exact_sha_tenant_pipeline() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let admin_pool = PgPool::connect(&database_url)
        .await
        .expect("connect tenant registry database");
    let tenant = format!("rust-source-worker-{}", Uuid::new_v4());
    let repository_id = Uuid::new_v4();
    let provider_id = 9_001_i64;
    let delivery_id = Uuid::new_v4().to_string();
    let sha = "a".repeat(40);
    sqlx::query("INSERT INTO ci_tenants (id, inserted_at) VALUES ($1, $2)")
        .bind(&tenant)
        .bind(Utc::now())
        .execute(&admin_pool)
        .await
        .expect("register tenant");
    let mut setup = database
        .tenant_transaction(&tenant)
        .await
        .expect("repository setup transaction");
    sqlx::query(
        "INSERT INTO github_repositories \
         (id, provider_id, installation_id, owner, name, full_name, trusted, inserted_at, \
          provider, provider_instance, tenant_id) \
         VALUES ($1, $2, 1, 'acme', 'widget', 'acme/widget', TRUE, $3, 'github', 'default', $4)",
    )
    .bind(repository_id)
    .bind(provider_id)
    .bind(Utc::now())
    .bind(&tenant)
    .execute(&mut *setup)
    .await
    .expect("insert trusted repository");
    setup.commit().await.expect("commit repository");
    let delivery = SourceControlDelivery {
        id: delivery_id.clone(),
        provider: "github".into(),
        provider_instance: "default".into(),
        provider_delivery_id: delivery_id.clone(),
        event: "push".into(),
        payload: serde_json::json!({
            "repository": {"id": provider_id},
            "after": sha,
            "ref": "refs/heads/main",
            "sender": {"login": "octo"}
        }),
        received_at: Utc::now(),
    };
    database
        .accept_source_control_delivery(&tenant, &delivery)
        .await
        .expect("accept delivery");
    let archive = create_source_tar_gz(
        &[SourceFile {
            path: ".robine-ci/workflows/ci.yml".into(),
            contents: b"version: 1\nname: CI\non:\n  push:\n    branches: [main]\njobs:\n  test:\n    image: alpine:3.22\n    steps:\n      - run: echo ok\n"
                .to_vec(),
        }],
        ArchiveLimits::default(),
    )
    .expect("workflow archive");
    let control_plane = ControlPlane::new(database.clone(), database.clone())
        .with_source_runtime(database.clone(), Arc::new(WorkflowArchive(archive)));
    let batch = control_plane
        .process_all_tenant_source_control(10)
        .await
        .expect("process delivery");
    assert!(batch.processed >= 1);

    let mut verification = database
        .tenant_transaction(&tenant)
        .await
        .expect("worker verification transaction");
    let pipeline = sqlx::query_as::<_, (String, String, String)>(
        "SELECT commit_sha, source_ref, actor FROM pipelines WHERE repository_id = $1",
    )
    .bind(repository_id)
    .fetch_one(&mut *verification)
    .await
    .expect("read webhook pipeline");
    let delivery_status =
        sqlx::query_scalar::<_, String>("SELECT status FROM github_deliveries WHERE id = $1")
            .bind(&delivery_id)
            .fetch_one(&mut *verification)
            .await
            .expect("read processed delivery");
    sqlx::query("DELETE FROM pipelines WHERE repository_id = $1")
        .bind(repository_id)
        .execute(&mut *verification)
        .await
        .expect("cleanup pipeline");
    sqlx::query("DELETE FROM durable_jobs WHERE payload->>'delivery_id' = $1")
        .bind(&delivery_id)
        .execute(&mut *verification)
        .await
        .expect("cleanup delivery job");
    sqlx::query("DELETE FROM github_deliveries WHERE id = $1")
        .bind(&delivery_id)
        .execute(&mut *verification)
        .await
        .expect("cleanup delivery");
    sqlx::query("DELETE FROM github_repositories WHERE id = $1")
        .bind(repository_id)
        .execute(&mut *verification)
        .await
        .expect("cleanup repository");
    verification.commit().await.expect("commit cleanup");
    sqlx::query("DELETE FROM ci_tenants WHERE id = $1")
        .bind(&tenant)
        .execute(&admin_pool)
        .await
        .expect("cleanup tenant");

    assert_eq!(pipeline, (sha, "main".into(), "github:octo".into()));
    assert_eq!(delivery_status, "processed");
}

#[tokio::test]
async fn source_control_delivery_acceptance_is_tenant_scoped_and_deduplicated() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-webhook-{}", Uuid::new_v4());
    let delivery = SourceControlDelivery {
        id: format!("gitlab:default:{}", Uuid::new_v4()),
        provider: "gitlab".into(),
        provider_instance: "default".into(),
        provider_delivery_id: Uuid::new_v4().to_string(),
        event: "Push Hook".into(),
        payload: serde_json::json!({"after": "a".repeat(40)}),
        received_at: Utc::now(),
    };
    assert!(
        database
            .accept_source_control_delivery(&tenant, &delivery)
            .await
            .expect("accept delivery")
    );
    assert!(
        !database
            .accept_source_control_delivery(&tenant, &delivery)
            .await
            .expect("deduplicate delivery")
    );
    let claim = database
        .claim_next_source_control_job(
            &tenant,
            Uuid::new_v4(),
            Utc::now(),
            Utc::now() - Duration::minutes(5),
        )
        .await
        .expect("claim delivery job")
        .expect("delivery job available");
    assert_eq!(
        database
            .get_source_control_delivery(&tenant, &delivery.id)
            .await
            .expect("load delivery")
            .payload,
        delivery.payload
    );
    database
        .finish_source_control_delivery(&tenant, &delivery.id, "processed", None, Utc::now())
        .await
        .expect("finish delivery");
    database
        .complete_durable_job(&tenant, claim.id, claim.claim_token, Utc::now())
        .await
        .expect("complete delivery job");

    let mut transaction = database
        .tenant_transaction(&tenant)
        .await
        .expect("delivery verification transaction");
    let count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM github_deliveries WHERE provider = $1 \
         AND provider_instance = $2 AND provider_delivery_id = $3",
    )
    .bind(&delivery.provider)
    .bind(&delivery.provider_instance)
    .bind(&delivery.provider_delivery_id)
    .fetch_one(&mut *transaction)
    .await
    .expect("read accepted delivery");
    let job_count = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM durable_jobs WHERE kind = 'process_source_control_delivery' \
         AND payload->>'delivery_id' = $1 AND status = 'completed'",
    )
    .bind(&delivery.id)
    .fetch_one(&mut *transaction)
    .await
    .expect("read atomic delivery handoff");
    sqlx::query(
        "DELETE FROM durable_jobs WHERE kind = 'process_source_control_delivery' \
         AND payload->>'delivery_id' = $1",
    )
    .bind(&delivery.id)
    .execute(&mut *transaction)
    .await
    .expect("cleanup delivery job");
    sqlx::query("DELETE FROM github_deliveries WHERE id = $1")
        .bind(&delivery.id)
        .execute(&mut *transaction)
        .await
        .expect("cleanup delivery");
    transaction.commit().await.expect("commit cleanup");
    assert_eq!(count, 1);
    assert_eq!(job_count, 1);
}

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
async fn cache_and_dependency_artifact_metadata_are_tenant_scoped_and_quota_locked() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-storage-{}", Uuid::new_v4());
    let repository_id = Uuid::new_v4();
    let pipeline_id = Uuid::new_v4();
    let job_id = Uuid::new_v4();
    let attempt_id = Uuid::new_v4();
    let now = Utc::now();
    let object = StoredObject {
        blob_id: "a".repeat(64),
        digest: "a".repeat(64),
        size: 7,
    };
    let cache = CacheEntry {
        id: Uuid::new_v4(),
        repository_id,
        key: "deps-v1".into(),
        object: object.clone(),
        created_at: now,
        expires_at: now + Duration::days(7),
    };
    let quotas = StorageQuotas {
        instance_bytes: 1_024,
        repository_bytes: 1_024,
    };
    MetadataRepository::save_cache(&database, &tenant, &cache, quotas)
        .await
        .expect("save cache metadata");
    let restored =
        MetadataRepository::restore_cache(&database, &tenant, repository_id, "deps-v1", now)
            .await
            .expect("restore cache metadata")
            .expect("cache hit");
    assert_eq!(restored.object, object);
    assert_eq!(
        MetadataRepository::restore_cache(
            &database,
            "different-tenant",
            repository_id,
            "deps-v1",
            now,
        )
        .await
        .expect("cross-tenant cache miss"),
        None
    );

    let mut fixture = database
        .tenant_transaction(&tenant)
        .await
        .expect("storage fixture transaction");
    sqlx::query(
        "INSERT INTO pipelines \
         (id, repository_id, workflow_name, commit_sha, status, trigger, actor, correlation_id, inserted_at) \
         VALUES ($1, $2, 'Storage', $3, 'running', 'manual', 'test', $4, $5)",
    )
    .bind(pipeline_id)
    .bind(repository_id)
    .bind("a".repeat(40))
    .bind(format!("rust-storage-{pipeline_id}"))
    .bind(now)
    .execute(&mut *fixture)
    .await
    .expect("insert storage pipeline");
    sqlx::query(
        "INSERT INTO pipeline_jobs \
         (id, pipeline_id, job_key, status, needs, position, execution_spec, inserted_at, updated_at) \
         VALUES ($1, $2, 'build', 'succeeded', '{}', 0, '{}', $3, $3)",
    )
    .bind(job_id)
    .bind(pipeline_id)
    .bind(now)
    .execute(&mut *fixture)
    .await
    .expect("insert storage job");
    sqlx::query(
        "INSERT INTO job_attempts \
         (id, job_id, number, idempotency_token, status, lease_expires_at, last_sequence, inserted_at, updated_at) \
         VALUES ($1, $2, 1, $3, 'succeeded', $4, 3, $4, $4)",
    )
    .bind(attempt_id)
    .bind(job_id)
    .bind(Uuid::new_v4())
    .bind(now)
    .execute(&mut *fixture)
    .await
    .expect("insert successful attempt");
    fixture.commit().await.expect("commit storage fixture");

    let mut coverage_fixture = database
        .tenant_transaction(&tenant)
        .await
        .expect("coverage fixture transaction");
    sqlx::query("UPDATE pipelines SET status = 'succeeded' WHERE id = $1 AND tenant_id = $2")
        .bind(pipeline_id)
        .bind(&tenant)
        .execute(&mut *coverage_fixture)
        .await
        .expect("finish coverage pipeline");
    sqlx::query("INSERT INTO log_chunks (id, attempt_id, sequence, step_position, step_name, step_status, duration_ms, content, inserted_at, tenant_id) VALUES ($1, $2, 1, 0, 'coverage', 'succeeded', 1, $3, $4, $5)")
        .bind(Uuid::new_v4()).bind(attempt_id)
        .bind("ROBINE_COVERAGE total=91.2 threshold=90 report=coverage.json\n")
        .bind(now).bind(&tenant).execute(&mut *coverage_fixture).await.expect("insert coverage marker");
    coverage_fixture
        .commit()
        .await
        .expect("commit coverage fixture");
    let coverage = PipelineRepository::latest_coverage(&database, &tenant, repository_id)
        .await
        .expect("latest coverage")
        .expect("coverage report");
    assert_eq!(coverage["total"], "91.2");
    assert_eq!(coverage["pipeline_id"], pipeline_id.to_string());
    let operational = PipelineRepository::operational_metrics(&database, &tenant)
        .await
        .expect("operational metrics");
    assert!(operational["outbox_pending"].as_i64().is_some());
    assert!(operational["runners_online"].as_i64().is_some());

    let artifact = Artifact {
        id: Uuid::new_v4(),
        repository_id,
        attempt_id,
        name: "report".into(),
        object: object.clone(),
        created_at: now,
        expires_at: now + Duration::days(7),
    };
    MetadataRepository::upload_artifact(&database, &tenant, &artifact, quotas)
        .await
        .expect("upload artifact metadata");
    let dependency = MetadataRepository::dependency_artifact(
        &database,
        &tenant,
        pipeline_id,
        "build",
        "report",
        now,
    )
    .await
    .expect("download dependency metadata");
    assert_eq!(dependency.id, artifact.id);
    let browser_artifact =
        MetadataRepository::job_artifact(&database, &tenant, pipeline_id, job_id, "report", now)
            .await
            .expect("download job artifact metadata");
    assert_eq!(browser_artifact.id, artifact.id);
    assert_eq!(
        MetadataRepository::upload_artifact(&database, &tenant, &artifact, quotas).await,
        Err(StorageError::ImmutableConflict)
    );

    let oversized = CacheEntry {
        id: Uuid::new_v4(),
        key: "too-large".into(),
        object: StoredObject {
            size: 2_000,
            ..object
        },
        ..cache
    };
    assert_eq!(
        MetadataRepository::save_cache(&database, &tenant, &oversized, quotas).await,
        Err(StorageError::QuotaExceeded)
    );

    let mut cleanup = database
        .tenant_transaction(&tenant)
        .await
        .expect("storage cleanup transaction");
    sqlx::query("DELETE FROM artifacts WHERE tenant_id = $1 AND repository_id = $2")
        .bind(&tenant)
        .bind(repository_id)
        .execute(&mut *cleanup)
        .await
        .expect("delete artifact fixture");
    sqlx::query("DELETE FROM cache_entries WHERE tenant_id = $1 AND repository_id = $2")
        .bind(&tenant)
        .bind(repository_id)
        .execute(&mut *cleanup)
        .await
        .expect("delete cache fixture");
    sqlx::query("DELETE FROM pipelines WHERE tenant_id = $1 AND id = $2")
        .bind(&tenant)
        .bind(pipeline_id)
        .execute(&mut *cleanup)
        .await
        .expect("delete pipeline fixture");
    cleanup.commit().await.expect("commit storage cleanup");
}

#[tokio::test]
async fn retention_rechecks_shared_references_and_deletes_only_staged_orphans() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Arc::new(
        Database::connect(&database_url, 2)
            .await
            .expect("connect migrated database"),
    );
    let tenant = format!("rust-retention-{}", Uuid::new_v4());
    let repository_id = Uuid::new_v4();
    let root = std::env::temp_dir().join(format!("robine-retention-{}", Uuid::new_v4()));
    let blobs = Arc::new(LocalBlobStore::new(root.clone(), 1_024).expect("local blob store"));
    let shared = blobs
        .put(&tenant, b"shared".to_vec())
        .await
        .expect("shared blob");
    let orphan = blobs
        .put(&tenant, b"orphan".to_vec())
        .await
        .expect("orphan blob");
    let now = Utc::now();
    let quotas = StorageQuotas {
        instance_bytes: 10_000,
        repository_bytes: 10_000,
    };
    for (key, expires_at) in [
        ("expired", now - Duration::seconds(1)),
        ("live", now + Duration::days(7)),
    ] {
        MetadataRepository::save_cache(
            database.as_ref(),
            &tenant,
            &CacheEntry {
                id: Uuid::new_v4(),
                repository_id,
                key: key.into(),
                object: shared.clone(),
                created_at: now - Duration::days(1),
                expires_at,
            },
            quotas,
        )
        .await
        .expect("cache fixture");
    }
    let control_plane = ControlPlane::new(database.clone(), database.clone())
        .with_storage_runtime(database.clone(), blobs.clone(), quotas)
        .with_retention_runtime(
            database.clone(),
            RetentionConfig {
                log_seconds: 60,
                gc_grace_seconds: 0,
                batch_size: 100,
            },
        );
    let first = control_plane
        .process_all_tenant_retention()
        .await
        .expect("first retention pass");
    assert!(first.caches_deleted >= 1);
    assert!(first.orphan_objects >= 1);
    assert_eq!(blobs.get(&tenant, &shared).await.unwrap(), b"shared");
    assert_eq!(blobs.get(&tenant, &orphan).await.unwrap(), b"orphan");

    let second = control_plane
        .process_all_tenant_retention()
        .await
        .expect("second retention pass");
    assert!(second.blobs_deleted >= 1);
    assert_eq!(blobs.get(&tenant, &shared).await.unwrap(), b"shared");
    assert_eq!(
        blobs.get(&tenant, &orphan).await,
        Err(StorageError::NotFound)
    );

    let mut cleanup = database
        .tenant_transaction(&tenant)
        .await
        .expect("retention cleanup transaction");
    sqlx::query("DELETE FROM cache_entries WHERE tenant_id = $1 AND repository_id = $2")
        .bind(&tenant)
        .bind(repository_id)
        .execute(&mut *cleanup)
        .await
        .expect("delete retention cache fixtures");
    sqlx::query("DELETE FROM storage_gc_candidates WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *cleanup)
        .await
        .expect("delete retention candidates");
    cleanup.commit().await.expect("commit retention cleanup");
    std::fs::remove_dir_all(root).expect("remove retention blobs");
}

#[tokio::test]
async fn storage_backend_changes_require_the_exact_acknowledgement_with_retained_metadata() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };
    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect migrated database");
    let tenant = format!("rust-storage-guard-{}", Uuid::new_v4());
    let repository_id = Uuid::new_v4();
    let now = Utc::now();
    MetadataRepository::save_cache(
        &database,
        &tenant,
        &CacheEntry {
            id: Uuid::new_v4(),
            repository_id,
            key: "guard".into(),
            object: StoredObject {
                blob_id: "a".repeat(64),
                digest: "a".repeat(64),
                size: 1,
            },
            created_at: now,
            expires_at: now + Duration::days(7),
        },
        StorageQuotas {
            instance_bytes: 100,
            repository_bytes: 100,
        },
    )
    .await
    .expect("retained metadata fixture");

    let local_digest = format!("{:x}", Sha256::digest(b"local:/var/lib/robine"));
    database
        .verify_storage_backend(&tenant, "local", &local_digest, None)
        .await
        .expect("first local namespace is compatible");
    let s3_digest = format!(
        "{:x}",
        Sha256::digest(b"s3:https://s3.example.test/robine/control-plane")
    );
    let expected = storage_transition_ack(&local_digest, &s3_digest);
    assert!(matches!(
        database
            .verify_storage_backend(&tenant, "s3", &s3_digest, Some("wrong"))
            .await,
        Err(PersistenceError::StorageMigrationAcknowledgementRequired(token)) if token == expected
    ));
    database
        .verify_storage_backend(&tenant, "s3", &s3_digest, Some(&expected))
        .await
        .expect("exact migration acknowledgement");

    let mut cleanup = database
        .tenant_transaction(&tenant)
        .await
        .expect("cleanup transaction");
    sqlx::query("DELETE FROM cache_entries WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *cleanup)
        .await
        .expect("delete cache fixture");
    sqlx::query("DELETE FROM storage_backend_states WHERE tenant_id = $1")
        .bind(&tenant)
        .execute(&mut *cleanup)
        .await
        .expect("delete backend state");
    cleanup.commit().await.expect("commit cleanup");
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

    let browser_pipeline = PipelineRepository::pipeline_browser_projection(
        database.as_ref(),
        "standalone",
        created.id,
    )
    .await
    .expect("pipeline browser projection");
    let browser_workflow = PipelineRepository::workflow_browser_projection(
        database.as_ref(),
        "standalone",
        created.id,
    )
    .await
    .expect("workflow browser projection");
    let browser_job_id =
        Uuid::parse_str(browser_pipeline["jobs"][0]["id"].as_str().expect("job id"))
            .expect("UUID job id");
    let browser_job = PipelineRepository::job_browser_projection(
        database.as_ref(),
        "standalone",
        created.id,
        browser_job_id,
    )
    .await
    .expect("job browser projection");
    let browser_log = PipelineRepository::job_log_download(
        database.as_ref(),
        "standalone",
        created.id,
        browser_job_id,
    )
    .await
    .expect("empty job log");

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
    assert_eq!(browser_pipeline["workflow_name"], "Rust creation");
    assert_eq!(browser_pipeline["actor"], maintainer.id.to_string());
    assert!(browser_pipeline["duration_ms"].is_null());
    assert_eq!(browser_pipeline["jobs"].as_array().map(Vec::len), Some(2));
    assert!(browser_pipeline["jobs"][0].get("latest_phase").is_some());
    assert!(browser_pipeline["jobs"][0].get("terminal_reason").is_some());
    assert!(browser_pipeline["jobs"][0].get("duration_ms").is_some());
    assert_eq!(browser_job["workflow_path"], ".robine-ci/workflows/ci.yml");
    assert_eq!(browser_job["commit_sha"], "d".repeat(40));
    assert_eq!(browser_job["pipeline_inputs"], serde_json::json!({}));
    assert_eq!(browser_workflow["path"], ".robine-ci/workflows/ci.yml");
    assert!(browser_job["key"] == "build" || browser_job["key"] == "test");
    assert!(browser_log.is_empty());
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
        lease_seconds: 60,
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
    let transfer_root =
        std::env::temp_dir().join(format!("robine-rust-transfer-{}", Uuid::new_v4()));
    let transfer_blobs =
        LocalBlobStore::new(transfer_root.clone(), 100_000_000).expect("transfer blobs");
    let control_plane = ControlPlane::new(Arc::new(database.clone()), Arc::new(database.clone()))
        .with_runner_secret_key_base(secret_key_base)
        .with_storage_runtime(
            Arc::new(database.clone()),
            Arc::new(transfer_blobs),
            StorageQuotas {
                instance_bytes: 1_000_000_000,
                repository_bytes: 500_000_000,
            },
        );
    let administrator = User {
        id: Uuid::new_v4(),
        email: "runner-admin@example.test".into(),
        role: Role::Administrator,
        disabled: false,
        inserted_at: now,
    };
    let enrollment = control_plane
        .create_runner_enrollment(&tenant, &administrator)
        .await
        .expect("create runner enrollment");
    assert!(enrollment.token.starts_with("rbe_"));
    let identity = control_plane
        .enroll_runner(&tenant, &enrollment.token, "rust-enrolled-runner")
        .await
        .expect("consume runner enrollment");
    assert!(identity.credential.starts_with("rrc_"));
    assert!(matches!(
        control_plane
            .enroll_runner(&tenant, &enrollment.token, "replay")
            .await,
        Err(ApplicationError::InvalidCredentials)
    ));
    control_plane
        .heartbeat_runner_attempts(&tenant, identity.runner_id, &identity.credential, 60)
        .await
        .expect("new runner credential authenticates");
    control_plane
        .configure_runner(
            &tenant,
            &administrator,
            identity.runner_id,
            "rust-enrolled-renamed",
            vec!["linux".into(), "arm64".into()],
            "draining",
        )
        .await
        .expect("configure runner");
    let fleet = control_plane
        .list_runner_fleet(&tenant, &administrator)
        .await
        .expect("list runner fleet");
    let configured = fleet
        .iter()
        .find(|runner| runner.id == identity.runner_id)
        .expect("configured runner in fleet");
    assert_eq!(configured.name, "rust-enrolled-renamed");
    assert_eq!(configured.admin_state, "draining");
    assert_eq!(configured.labels, vec!["linux", "arm64"]);
    assert_eq!(configured.connectivity, "online");
    let rotated = control_plane
        .rotate_runner_credential(&tenant, &administrator, identity.runner_id)
        .await
        .expect("rotate runner credential");
    control_plane
        .heartbeat_runner_attempts(&tenant, identity.runner_id, &identity.credential, 60)
        .await
        .expect("old runner credential overlaps");
    control_plane
        .heartbeat_runner_attempts(&tenant, identity.runner_id, &rotated.credential, 60)
        .await
        .expect("new runner credential authenticates");
    control_plane
        .revoke_runner(&tenant, &administrator, identity.runner_id)
        .await
        .expect("revoke runner");
    assert!(matches!(
        control_plane
            .heartbeat_runner_attempts(&tenant, identity.runner_id, &rotated.credential, 60)
            .await,
        Err(ApplicationError::Unauthenticated)
    ));
    assert!(matches!(
        control_plane
            .heartbeat_runner_attempts(&tenant, runner_id, "rrc_invalid", 120)
            .await,
        Err(ApplicationError::Unauthenticated)
    ));
    let mut anomaly_read = database
        .tenant_transaction(&tenant)
        .await
        .expect("authentication audit transaction");
    let anomaly = sqlx::query_as::<_, (String, serde_json::Value)>(
        "SELECT action, metadata FROM audit_events WHERE action = 'runner.authentication_failed' \
         AND target_id = $1 AND tenant_id = $2",
    )
    .bind(runner_id)
    .bind(&tenant)
    .fetch_one(&mut *anomaly_read)
    .await
    .expect("authentication anomaly audit");
    anomaly_read.commit().await.expect("commit anomaly read");
    assert_eq!(anomaly.0, "runner.authentication_failed");
    assert_eq!(anomaly.1["claimed_runner_id_valid"], true);
    assert!(anomaly.1.get("correlation_id").is_some());
    assert_eq!(
        control_plane
            .negotiate_runner_session(
                &tenant,
                runner_id,
                &credential,
                &[1],
                "0.3.0-test",
                &serde_json::json!({"docker": true, "concurrency": 2}),
            )
            .await
            .expect("negotiate runner session"),
        1
    );
    let mut session_read = database
        .tenant_transaction(&tenant)
        .await
        .expect("session metadata transaction");
    let session_metadata = sqlx::query_as::<_, (Option<i32>, Option<String>, serde_json::Value)>(
        "SELECT protocol_version, software_version, capabilities FROM remote_runners \
         WHERE id = $1 AND tenant_id = $2",
    )
    .bind(runner_id)
    .bind(&tenant)
    .fetch_one(&mut *session_read)
    .await
    .expect("load runner session metadata");
    session_read.commit().await.expect("commit session read");
    assert_eq!(session_metadata.0, Some(1));
    assert_eq!(session_metadata.1.as_deref(), Some("0.3.0-test"));
    assert_eq!(session_metadata.2["docker"], true);
    assert!(matches!(
        control_plane
            .negotiate_runner_session(
                &tenant,
                runner_id,
                &credential,
                &[99],
                "0.3.0-test",
                &serde_json::json!({}),
            )
            .await,
        Err(ApplicationError::InvalidAttemptEvent)
    ));
    let runner_heartbeat = control_plane
        .heartbeat_runner_attempts(&tenant, runner_id, &credential, 120)
        .await
        .expect("authenticated runner heartbeat");
    assert_eq!(runner_heartbeat.renewed_attempts, 0);
    assert_eq!(runner_heartbeat.pending_offer_attempt_ids, vec![attempt.id]);
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
    let offer_heartbeat = control_plane
        .heartbeat_runner_attempts(&tenant, runner_id, &credential, 120)
        .await
        .expect("heartbeat discovers newly reserved offers");
    assert_eq!(
        offer_heartbeat.pending_offer_attempt_ids,
        vec![remote_attempt.id]
    );
    let transfer_archive = robine_source::create_source_tar_gz(
        &[robine_source::SourceFile {
            path: std::path::PathBuf::from("cache.bin"),
            contents: b"bounded remote transfer".to_vec(),
        }],
        robine_source::ArchiveLimits::default(),
    )
    .expect("valid transfer archive");
    let cache_upload = control_plane
        .remote_save_cache(
            &tenant,
            runner_id,
            &credential,
            remote_attempt.id,
            "remote-cache-v1",
            transfer_archive.clone(),
        )
        .await
        .expect("attempt-scoped cache upload");
    let cache_download = control_plane
        .remote_restore_cache(
            &tenant,
            runner_id,
            &credential,
            remote_attempt.id,
            "remote-cache-v1",
        )
        .await
        .expect("attempt-scoped cache restore")
        .expect("cache hit");
    assert_eq!(cache_download.content, transfer_archive);
    assert_eq!(cache_download.digest, cache_upload.digest);
    let artifact_upload = control_plane
        .remote_upload_artifact(
            &tenant,
            runner_id,
            &credential,
            remote_attempt.id,
            "remote-report",
            7,
            transfer_archive,
        )
        .await
        .expect("attempt-scoped artifact upload");
    assert!(artifact_upload.id.is_some());
    assert!(matches!(
        control_plane
            .remote_download_artifact(
                &tenant,
                runner_id,
                &credential,
                remote_attempt.id,
                "undeclared",
                "remote-report",
            )
            .await,
        Err(ApplicationError::PipelineNotFound)
    ));
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
    std::fs::remove_dir_all(&transfer_root).expect("remove transfer fixture storage");
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
    sqlx::query(
        "INSERT INTO github_repositories \
         (id, provider, provider_instance, provider_id, installation_id, owner, name, full_name, trusted, inserted_at, tenant_id) \
         VALUES ($1, 'github', 'https://github.com', $2, 42, 'robine-ci', 'fixture', 'robine-ci/fixture', TRUE, $3, $4)",
    )
    .bind(pipeline.repository_id)
    .bind(now.timestamp_micros())
    .bind(now)
    .bind(&tenant)
    .execute(&mut *secret_fixture)
    .await
    .expect("insert trusted repository fixture");
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
    let source_repository =
        RepositoryStore::find_trusted(&database, &tenant, pipeline.repository_id)
            .await
            .expect("resolve trusted source repository");
    assert_eq!(source_repository.provider, Provider::GitHub);
    assert_eq!(source_repository.full_name, "robine-ci/fixture");
    let mut cleanup = database
        .tenant_transaction(&tenant)
        .await
        .expect("source fixture cleanup transaction");
    sqlx::query("DELETE FROM github_repositories WHERE id = $1 AND tenant_id = $2")
        .bind(pipeline.repository_id)
        .bind(&tenant)
        .execute(&mut *cleanup)
        .await
        .expect("delete trusted repository fixture");
    cleanup
        .commit()
        .await
        .expect("commit source fixture cleanup");
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
