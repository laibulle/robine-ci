//! Framework-independent orchestration for Robine use cases.

use std::{
    collections::BTreeSet,
    sync::{Arc, LazyLock},
};

use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Timelike, Utc};
use hmac::{Hmac, Mac};
use robine_core::{
    execution_context::{Actor, ActorKind, Capability, ExecutionContext},
    identity::{OidcAuthorization, Role, User},
    pipelines::{
        AttemptProjection, ConfigureRunner, ConsumeRunnerEnrollment, CreatePipelineInput,
        ExecutionLogChunk, JobState, NewJob, NewPipeline, NewRunnerEnrollment, NewWorkflowRevision,
        OutboxDelivery, PipelineProjection, RecordAttemptEvent, RecordRemoteAttemptEvent,
        RetryProjection, RevokeRunner, RotateRunnerCredential, RunnerFleetEntry,
        RunnerLeaseHeartbeat, RunnerReconciliation, SchedulerClaim, SourceControlDelivery,
        outbox_backoff_seconds, source_digest,
    },
    ports::{IdentityRepository, OidcProvider, PipelineRepository, PortError},
    source_control::{NormalizationOutcome, SourceControlTrigger, normalize},
};
use robine_execution::{
    BuiltinHandler, BuiltinRestore, CancellationSignal, ExecutionControl, ExecutionError,
    ExecutionResult, ExecutionRunner, ExecutionSpecification, ExecutionStatus, OutputChannel,
    OutputChunk, OutputSink,
};
use robine_secrets::{AesGcmKeyring, SecretDecryptor, SecretRepository};
use robine_source::{
    ArchiveFetcher, ArchiveLimits, Provider, RepositoryStore, SourceInspector, extract_tar_gz,
    valid_commit_sha,
};
use robine_storage::{
    Artifact, BlobStore, CacheEntry, MetadataRepository, RetentionRepository, RetentionResult,
    StorageQuotas,
};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

static DUMMY_PASSWORD_HASH: LazyLock<String> = LazyLock::new(|| {
    let salt =
        SaltString::encode_b64(b"robine-dummy-salt").expect("static dummy password salt is valid");
    Argon2::default()
        .hash_password(b"not-a-real-password", &salt)
        .expect("static dummy password can be hashed")
        .to_string()
});

pub struct ControlPlane {
    identities: Arc<dyn IdentityRepository>,
    pipelines: Arc<dyn PipelineRepository>,
    bootstrap: Option<BootstrapConfig>,
    oidc: Option<Arc<dyn OidcProvider>>,
    runner_credential_key: Option<[u8; 32]>,
    execution_runner: Option<Arc<dyn ExecutionRunner>>,
    secret_repository: Option<Arc<dyn SecretRepository>>,
    secret_decryptor: Option<Arc<dyn SecretDecryptor>>,
    secret_encryptor: Option<Arc<AesGcmKeyring>>,
    source_repositories: Option<Arc<dyn RepositoryStore>>,
    source_fetcher: Option<Arc<dyn ArchiveFetcher>>,
    source_inspector: Option<Arc<dyn SourceInspector>>,
    storage_repository: Option<Arc<dyn MetadataRepository>>,
    retention_repository: Option<Arc<dyn RetentionRepository>>,
    blob_store: Option<Arc<dyn BlobStore>>,
    storage_quotas: StorageQuotas,
    retention: RetentionConfig,
    workflow_limits: robine_workflows::WorkflowLimits,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetentionConfig {
    pub log_seconds: i64,
    pub gc_grace_seconds: i64,
    pub batch_size: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScheduleReconciliation {
    pub scanned_minutes: u32,
    pub due_occurrences: u32,
    pub pipelines: u32,
    pub truncated_minutes: u64,
    pub cursor_advanced: bool,
}

impl Default for RetentionConfig {
    fn default() -> Self {
        Self {
            log_seconds: 2_592_000,
            gc_grace_seconds: 3_600,
            batch_size: 1_000,
        }
    }
}

struct BootstrapConfig {
    token_digest: [u8; 32],
    expires_at: chrono::DateTime<Utc>,
}

struct DurableOutputSink {
    pipelines: Arc<dyn PipelineRepository>,
    tenant_id: String,
    attempt_id: Uuid,
}

#[async_trait::async_trait]
impl OutputSink for DurableOutputSink {
    async fn append(&self, chunk: OutputChunk) -> Result<(), ExecutionError> {
        self.pipelines
            .append_execution_log(
                &self.tenant_id,
                &ExecutionLogChunk {
                    id: Uuid::new_v4(),
                    attempt_id: self.attempt_id,
                    sequence: i64::try_from(chunk.sequence).map_err(|_| ExecutionError::Output)?,
                    step_position: i32::try_from(chunk.step).map_err(|_| ExecutionError::Output)?,
                    step_name: chunk.step_name,
                    stream: match chunk.channel {
                        OutputChannel::Stdout => "stdout",
                        OutputChannel::Stderr => "stderr",
                        OutputChannel::System => "system",
                    }
                    .into(),
                    content: chunk.bytes,
                    inserted_at: Utc::now(),
                },
            )
            .await
            .map_err(|_| ExecutionError::Output)
    }
}

struct DurableCancellationSignal {
    pipelines: Arc<dyn PipelineRepository>,
    tenant_id: String,
    idempotency_token: Uuid,
}

struct ExecutionBuiltinHandler {
    tenant_id: String,
    repository_id: Uuid,
    pipeline_id: Uuid,
    attempt_id: Uuid,
    needs: Vec<String>,
    repository: Arc<dyn MetadataRepository>,
    blobs: Arc<dyn BlobStore>,
    quotas: StorageQuotas,
}

#[async_trait::async_trait]
impl BuiltinHandler for ExecutionBuiltinHandler {
    async fn restore(
        &self,
        step: &robine_execution::ExecutionStep,
    ) -> Result<BuiltinRestore, ExecutionError> {
        let now = Utc::now();
        let object = match step.value.as_str() {
            "cache/restore" => {
                let key = builtin_string(step, "key")?;
                let Some(cache) = self
                    .repository
                    .restore_cache(&self.tenant_id, self.repository_id, key, now)
                    .await
                    .map_err(storage_execution_error)?
                else {
                    return Ok(BuiltinRestore::CacheMiss);
                };
                cache.object
            }
            "artifacts/download" => {
                let from = builtin_string(step, "from")?;
                if !self.needs.iter().any(|need| need == from) {
                    return Err(ExecutionError::InvalidSpecification("artifact dependency"));
                }
                self.repository
                    .dependency_artifact(
                        &self.tenant_id,
                        self.pipeline_id,
                        from,
                        builtin_string(step, "name")?,
                        now,
                    )
                    .await
                    .map_err(storage_execution_error)?
                    .object
            }
            _ => return Err(ExecutionError::Unsupported("restore builtin")),
        };
        let content = self
            .blobs
            .get(&self.tenant_id, &object)
            .await
            .map_err(storage_execution_error)?;
        Ok(BuiltinRestore::Archive(content))
    }

    async fn publish(
        &self,
        step: &robine_execution::ExecutionStep,
        archive: Vec<u8>,
    ) -> Result<(), ExecutionError> {
        let now = Utc::now();
        let object = self
            .blobs
            .put(&self.tenant_id, archive)
            .await
            .map_err(storage_execution_error)?;
        let result = match step.value.as_str() {
            "cache/save" => {
                let cache = CacheEntry {
                    id: Uuid::new_v4(),
                    repository_id: self.repository_id,
                    key: builtin_string(step, "key")?.to_owned(),
                    object: object.clone(),
                    created_at: now,
                    expires_at: now + chrono::Duration::days(7),
                };
                self.repository
                    .save_cache(&self.tenant_id, &cache, self.quotas)
                    .await
            }
            "artifacts/upload" => {
                let days = step
                    .with
                    .get("retention-days")
                    .and_then(serde_json::Value::as_i64)
                    .unwrap_or(7);
                let artifact = Artifact {
                    id: Uuid::new_v4(),
                    repository_id: self.repository_id,
                    attempt_id: self.attempt_id,
                    name: builtin_string(step, "name")?.to_owned(),
                    object: object.clone(),
                    created_at: now,
                    expires_at: now + chrono::Duration::days(days),
                };
                self.repository
                    .upload_artifact(&self.tenant_id, &artifact, self.quotas)
                    .await
            }
            _ => return Err(ExecutionError::Unsupported("publish builtin")),
        };
        if result.is_err() {
            let _ = self
                .repository
                .stage_blob_gc(
                    &self.tenant_id,
                    &object.blob_id,
                    now + chrono::Duration::hours(1),
                    now,
                )
                .await;
        }
        result.map_err(storage_execution_error)
    }
}

#[async_trait::async_trait]
impl CancellationSignal for DurableCancellationSignal {
    async fn requested(&self) -> Result<bool, ExecutionError> {
        self.pipelines
            .cancellation_requested(&self.tenant_id, self.idempotency_token)
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "cancellation_poll",
            })
    }
}

#[derive(Debug, Error)]
pub enum ApplicationError {
    #[error("invalid email or password")]
    InvalidCredentials,
    #[error("bootstrap token is invalid")]
    InvalidBootstrapToken,
    #[error("bootstrap token has expired")]
    BootstrapTokenExpired,
    #[error("email address is invalid")]
    InvalidEmail,
    #[error("password must contain at least 12 characters")]
    WeakPassword,
    #[error("the instance has already been bootstrapped")]
    AlreadyBootstrapped,
    #[error("the last usable administrator cannot be demoted")]
    LastAdministrator,
    #[error("OpenID Connect is not configured")]
    OidcNotConfigured,
    #[error("OpenID Connect protocol validation failed")]
    OidcProtocol,
    #[error("OpenID Connect identity is incomplete or unverified")]
    InvalidOidcIdentity,
    #[error("the verified email belongs to another identity")]
    OidcEmailCollision,
    #[error("authentication is required")]
    Unauthenticated,
    #[error("operation is forbidden")]
    Forbidden,
    #[error("pipeline was not found")]
    PipelineNotFound,
    #[error("pipeline cannot be cancelled from its current state")]
    PipelineNotCancellable,
    #[error("pipeline cannot be queued from its current state")]
    PipelineNotQueueable,
    #[error("job or pipeline cannot be retried from its current state")]
    JobNotRetryable,
    #[error("job dependencies are unavailable: {0:?}")]
    RetryDependenciesUnavailable(Vec<String>),
    #[error("retained artifact inputs are unavailable: {0:?}")]
    RetryInputsUnavailable(Vec<String>),
    #[error("pipeline creation input is invalid")]
    InvalidPipelineInput,
    #[error("workflow revision is invalid")]
    InvalidWorkflow(Vec<robine_workflows::Diagnostic>),
    #[error("idempotency key conflicts with an existing pipeline")]
    IdempotencyConflict,
    #[error("scheduler capacity is exhausted")]
    SchedulerCapacity,
    #[error("no eligible work is queued")]
    NoWork,
    #[error("attempt event sequence gap: expected {expected}, got {actual}")]
    EventSequenceGap { expected: i32, actual: i32 },
    #[error("attempt event is invalid")]
    InvalidAttemptEvent,
    #[error("application dependency is unavailable")]
    Unavailable,
}

fn schedule_failure_code(error: &ApplicationError) -> &'static str {
    match error {
        ApplicationError::InvalidWorkflow(_) => "invalid_workflow",
        ApplicationError::IdempotencyConflict => "idempotency_conflict",
        ApplicationError::InvalidPipelineInput => "invalid_pipeline",
        ApplicationError::PipelineNotFound => "repository_not_found",
        _ => "dependency_unavailable",
    }
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct RunnerEnrollment {
    pub id: Uuid,
    pub token: String,
    pub expires_at: chrono::DateTime<Utc>,
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct EnrolledRunner {
    pub runner_id: Uuid,
    pub credential: String,
}

#[derive(Debug, serde::Serialize)]
pub struct IssuedSession {
    pub token: String,
    pub expires_at: chrono::DateTime<Utc>,
    pub user: User,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct OutboxBatch {
    pub processed: u64,
    pub delivered: u64,
    pub dispatch_enqueued: u64,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct DispatchBatch {
    pub processed: u64,
    pub attempts_created: u64,
    pub no_work: u64,
    pub retried: u64,
    pub discarded: u64,
    pub reconciled: u64,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct ExecutionBatch {
    pub claimed: u64,
    pub succeeded: u64,
    pub failed: u64,
    pub recovered_terminal: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SourceControlBatch {
    pub claimed: u64,
    pub processed: u64,
    pub ignored: u64,
    pub failed: u64,
    pub retried: u64,
}

pub struct RemoteTransferDownload {
    pub content: Vec<u8>,
    pub digest: String,
}

#[derive(Debug, serde::Serialize)]
pub struct RemoteTransferUpload {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<Uuid>,
    pub digest: String,
    pub size: i64,
}

impl ControlPlane {
    #[must_use]
    pub fn new(
        identities: Arc<dyn IdentityRepository>,
        pipelines: Arc<dyn PipelineRepository>,
    ) -> Self {
        Self {
            identities,
            pipelines,
            bootstrap: None,
            oidc: None,
            runner_credential_key: None,
            execution_runner: None,
            secret_repository: None,
            secret_decryptor: None,
            secret_encryptor: None,
            source_repositories: None,
            source_fetcher: None,
            source_inspector: None,
            storage_repository: None,
            retention_repository: None,
            blob_store: None,
            storage_quotas: StorageQuotas {
                instance_bytes: 53_687_091_200,
                repository_bytes: 10_737_418_240,
            },
            retention: RetentionConfig::default(),
            workflow_limits: robine_workflows::WorkflowLimits::default(),
        }
    }

    #[must_use]
    pub fn with_execution_runner(mut self, runner: Arc<dyn ExecutionRunner>) -> Self {
        self.execution_runner = Some(runner);
        self
    }

    #[must_use]
    pub fn with_secret_runtime(
        mut self,
        repository: Arc<dyn SecretRepository>,
        keyring: Arc<AesGcmKeyring>,
    ) -> Self {
        self.secret_repository = Some(repository);
        self.secret_decryptor = Some(keyring.clone());
        self.secret_encryptor = Some(keyring);
        self
    }

    #[must_use]
    pub fn with_source_runtime(
        mut self,
        repositories: Arc<dyn RepositoryStore>,
        fetcher: Arc<dyn ArchiveFetcher>,
    ) -> Self {
        self.source_repositories = Some(repositories);
        self.source_fetcher = Some(fetcher);
        self
    }

    #[must_use]
    pub fn with_source_inspector(mut self, inspector: Arc<dyn SourceInspector>) -> Self {
        self.source_inspector = Some(inspector);
        self
    }

    #[must_use]
    pub fn with_storage_runtime(
        mut self,
        repository: Arc<dyn MetadataRepository>,
        blobs: Arc<dyn BlobStore>,
        quotas: StorageQuotas,
    ) -> Self {
        self.storage_repository = Some(repository);
        self.blob_store = Some(blobs);
        self.storage_quotas = quotas;
        self
    }

    #[must_use]
    pub fn with_retention_runtime(
        mut self,
        repository: Arc<dyn RetentionRepository>,
        config: RetentionConfig,
    ) -> Self {
        self.retention_repository = Some(repository);
        self.retention = config;
        self
    }

    #[must_use]
    pub fn with_workflow_limits(mut self, limits: robine_workflows::WorkflowLimits) -> Self {
        self.workflow_limits = limits;
        self
    }

    #[must_use]
    /// Configures compatibility verification for existing remote-runner credentials.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts arbitrary key lengths, so construction cannot panic for this input.
    pub fn with_runner_secret_key_base(mut self, secret_key_base: &str) -> Self {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret_key_base.as_bytes())
            .expect("HMAC accepts keys of any length");
        mac.update(b"robine:runner-credential:v1");
        self.runner_credential_key = Some(mac.finalize().into_bytes().into());
        self
    }

    #[must_use]
    pub fn with_bootstrap_token(mut self, token: &str, expires_at: chrono::DateTime<Utc>) -> Self {
        self.bootstrap = Some(BootstrapConfig {
            token_digest: Sha256::digest(token.as_bytes()).into(),
            expires_at,
        });
        self
    }

    #[must_use]
    pub fn with_oidc_provider(mut self, oidc: Arc<dyn OidcProvider>) -> Self {
        self.oidc = Some(oidc);
        self
    }

    /// Starts an OIDC authorization-code flow with provider-owned transient state.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::OidcNotConfigured`] without a provider and
    /// [`ApplicationError::OidcProtocol`] when discovery or authorization fails.
    pub async fn start_oidc(&self) -> Result<OidcAuthorization, ApplicationError> {
        self.oidc
            .as_ref()
            .ok_or(ApplicationError::OidcNotConfigured)?
            .start()
            .await
            .map_err(|_| ApplicationError::OidcProtocol)
    }

    /// Completes OIDC, provisions only by issuer/subject, and creates a local session.
    ///
    /// # Errors
    ///
    /// Returns protocol/identity errors for invalid claims, collision for an email owned by
    /// another identity, or unavailable when provisioning/session persistence fails.
    pub async fn complete_oidc(
        &self,
        code: &str,
        state: &str,
    ) -> Result<IssuedSession, ApplicationError> {
        let claims = self
            .oidc
            .as_ref()
            .ok_or(ApplicationError::OidcNotConfigured)?
            .complete(code, state)
            .await
            .map_err(|_| ApplicationError::OidcProtocol)?;
        if claims.issuer.is_empty()
            || claims.subject.is_empty()
            || claims.email.is_empty()
            || !claims.email_verified
        {
            return Err(ApplicationError::InvalidOidcIdentity);
        }

        let now = Utc::now();
        let user = self
            .identities
            .find_or_provision_oidc_user(&claims, Uuid::new_v4(), now)
            .await
            .map_err(|error| match error {
                PortError::OidcEmailCollision => ApplicationError::OidcEmailCollision,
                PortError::InvalidData => ApplicationError::InvalidOidcIdentity,
                _ => ApplicationError::Unavailable,
            })?;
        self.issue_session(user, now).await
    }

    /// Creates the first administrator under an expiring out-of-band token.
    ///
    /// # Errors
    ///
    /// Returns a specific validation error for an invalid/expired token, malformed email,
    /// weak password, or an already initialized instance. Persistence failures return
    /// [`ApplicationError::Unavailable`].
    pub async fn bootstrap_administrator(
        &self,
        token: &str,
        email: &str,
        password: &str,
    ) -> Result<User, ApplicationError> {
        let config = self
            .bootstrap
            .as_ref()
            .ok_or(ApplicationError::InvalidBootstrapToken)?;
        let actual_digest: [u8; 32] = Sha256::digest(token.as_bytes()).into();
        if !bool::from(actual_digest.ct_eq(&config.token_digest)) {
            return Err(ApplicationError::InvalidBootstrapToken);
        }
        let now = Utc::now();
        if now >= config.expires_at {
            return Err(ApplicationError::BootstrapTokenExpired);
        }
        let email = email.to_lowercase();
        if !valid_email(&email) {
            return Err(ApplicationError::InvalidEmail);
        }
        if password.chars().count() < 12 {
            return Err(ApplicationError::WeakPassword);
        }

        let mut salt_bytes = [0_u8; 16];
        getrandom::fill(&mut salt_bytes).map_err(|_| ApplicationError::Unavailable)?;
        let salt =
            SaltString::encode_b64(&salt_bytes).map_err(|_| ApplicationError::Unavailable)?;
        let password_hash = Argon2::default()
            .hash_password(password.as_bytes(), &salt)
            .map_err(|_| ApplicationError::Unavailable)?
            .to_string();

        self.identities
            .bootstrap_administrator(Uuid::new_v4(), Uuid::new_v4(), &email, &password_hash, now)
            .await
            .map_err(|error| match error {
                PortError::AlreadyBootstrapped => ApplicationError::AlreadyBootstrapped,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Resolves the same opaque session-token digest used by the Phoenix implementation.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::Unauthenticated`] for unknown, expired, revoked, or
    /// disabled-user sessions, and [`ApplicationError::Unavailable`] for storage failures.
    pub async fn authenticate(&self, token: &str) -> Result<User, ApplicationError> {
        if token.is_empty() {
            return Err(ApplicationError::Unauthenticated);
        }

        let digest = Sha256::digest(token.as_bytes());
        self.identities
            .resolve_session(digest.as_slice(), Utc::now())
            .await
            .map_err(|error| authentication_error(&error))
    }

    /// Verifies a local Argon2 password and creates a seven-day opaque session.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::InvalidCredentials`] without revealing whether the
    /// email exists, or [`ApplicationError::Unavailable`] when persistence fails.
    pub async fn authenticate_local(
        &self,
        email: &str,
        password: &str,
    ) -> Result<IssuedSession, ApplicationError> {
        let identity = self
            .identities
            .get_local_identity(&email.to_lowercase())
            .await;
        let password_hash = identity
            .as_ref()
            .map_or(DUMMY_PASSWORD_HASH.as_str(), |identity| {
                identity.password_hash.as_str()
            });
        let verified = PasswordHash::new(password_hash).ok().is_some_and(|parsed| {
            Argon2::default()
                .verify_password(password.as_bytes(), &parsed)
                .is_ok()
        });

        let identity = match identity {
            Ok(identity) if verified && !identity.user.disabled => identity,
            Ok(_) | Err(PortError::NotFound | PortError::InvalidData) => {
                return Err(ApplicationError::InvalidCredentials);
            }
            Err(
                PortError::AlreadyBootstrapped
                | PortError::LastAdministrator
                | PortError::OidcEmailCollision
                | PortError::InvalidTransition
                | PortError::RetryDependenciesUnavailable(_)
                | PortError::RetryInputsUnavailable(_)
                | PortError::IdempotencyConflict
                | PortError::Capacity
                | PortError::NoWork
                | PortError::EventGap { .. }
                | PortError::InvalidAttemptEvent
                | PortError::MessageIdConflict
                | PortError::AttemptNotAssigned
                | PortError::StaleEvent { .. }
                | PortError::Unavailable,
            ) => {
                return Err(ApplicationError::Unavailable);
            }
        };

        let now = Utc::now();
        self.issue_session(identity.user, now).await
    }

    /// Revokes an opaque session token.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::Unauthenticated`] for an empty or unknown session and
    /// [`ApplicationError::Unavailable`] when persistence fails.
    pub async fn revoke_session(&self, token: &str) -> Result<(), ApplicationError> {
        if token.is_empty() {
            return Err(ApplicationError::Unauthenticated);
        }
        let digest = Sha256::digest(token.as_bytes());
        self.identities
            .revoke_session(digest.as_slice(), Utc::now())
            .await
            .map_err(|error| authentication_error(&error))
    }

    /// Lists non-sensitive user metadata for an administrator.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::Forbidden`] for non-administrators and
    /// [`ApplicationError::Unavailable`] when persistence fails.
    pub async fn list_users(&self, actor: &User) -> Result<Vec<User>, ApplicationError> {
        if actor.role != Role::Administrator {
            return Err(ApplicationError::Forbidden);
        }
        self.identities
            .list_users()
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Changes a user's role while preserving a usable administrator.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::Forbidden`] for non-administrators,
    /// [`ApplicationError::LastAdministrator`] when the mutation would remove the final
    /// usable administrator, and an authentication/dependency error for missing data.
    pub async fn change_user_role(
        &self,
        actor: &User,
        user_id: Uuid,
        role: Role,
    ) -> Result<User, ApplicationError> {
        if actor.role != Role::Administrator {
            return Err(ApplicationError::Forbidden);
        }
        self.identities
            .change_user_role(user_id, role)
            .await
            .map_err(|error| match error {
                PortError::LastAdministrator => ApplicationError::LastAdministrator,
                PortError::NotFound => ApplicationError::Unauthenticated,
                _ => ApplicationError::Unavailable,
            })
    }

    async fn issue_session(
        &self,
        user: User,
        now: chrono::DateTime<Utc>,
    ) -> Result<IssuedSession, ApplicationError> {
        let mut token_bytes = [0_u8; 32];
        getrandom::fill(&mut token_bytes).map_err(|_| ApplicationError::Unavailable)?;
        let token = URL_SAFE_NO_PAD.encode(token_bytes);
        let digest = Sha256::digest(token.as_bytes());
        let expires_at = now + chrono::Duration::days(7);
        self.identities
            .create_session(Uuid::new_v4(), user.id, digest.as_slice(), expires_at, now)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(IssuedSession {
            token,
            expires_at,
            user,
        })
    }

    /// Lists the bounded pipeline projection visible to an authenticated user.
    ///
    /// # Errors
    ///
    /// Returns [`ApplicationError::Forbidden`] when authorization context construction
    /// fails and [`ApplicationError::Unavailable`] when persistence fails.
    pub async fn list_pipelines(
        &self,
        user: &User,
        repository_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<PipelineProjection>, ApplicationError> {
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::User,
            },
            "standalone",
            [Capability::new("pipelines:read")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;

        if !context.permits("pipelines:read") {
            return Err(ApplicationError::Forbidden);
        }

        self.pipelines
            .list_recent(&context.tenant_id, repository_id, limit.clamp(1, 100))
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Lists trusted source repositories for an authenticated tenant user.
    ///
    /// # Errors
    ///
    /// Returns unavailable when source-control persistence is not configured or cannot respond.
    pub async fn list_source_repositories(
        &self,
        user: &User,
        tenant_id: &str,
    ) -> Result<Vec<robine_source::Repository>, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.source_repositories
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .list_trusted(tenant_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Resolves public badge data only for an explicitly trusted repository.
    ///
    /// # Errors
    ///
    /// Returns not-found for unknown public identities or unavailable on persistence failure.
    pub async fn public_badge_data(
        &self,
        provider: &str,
        owner: &str,
        name: &str,
    ) -> Result<serde_json::Value, ApplicationError> {
        let repositories = self
            .source_repositories
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .list_trusted("standalone")
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let repository = repositories
            .into_iter()
            .find(|repository| {
                let candidate = match repository.provider {
                    Provider::GitHub => "github",
                    Provider::GitLab => "gitlab",
                    Provider::Forgejo => "forgejo",
                };
                candidate == provider && repository.owner == owner && repository.name == name
            })
            .ok_or(ApplicationError::PipelineNotFound)?;
        let status = self
            .pipelines
            .list_recent("standalone", Some(repository.id), 1)
            .await
            .map_err(|_| ApplicationError::Unavailable)?
            .into_iter()
            .next()
            .map(|pipeline| pipeline.status);
        let coverage = self
            .pipelines
            .latest_coverage("standalone", repository.id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(serde_json::json!({"status": status, "coverage": coverage}))
    }

    /// Returns bounded aggregate values for the authenticated Prometheus endpoint.
    ///
    /// # Errors
    ///
    /// Returns unavailable when persistence cannot produce a consistent snapshot.
    pub async fn operational_metrics(&self) -> Result<serde_json::Value, ApplicationError> {
        self.pipelines
            .operational_metrics("standalone")
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Discovers manually enabled workflows at one immutable branch head.
    ///
    /// # Errors
    ///
    /// Returns forbidden for disabled users, invalid workflow diagnostics, or provider failure.
    pub async fn discover_manual_workflows(
        &self,
        user: &User,
        repository_id: Uuid,
        branch: Option<&str>,
    ) -> Result<serde_json::Value, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        let (head, sources) = self.workflow_sources(repository_id, branch).await?;
        let mut workflows = Vec::new();
        for path in sources.keys() {
            let resolved = robine_workflows::resolve(path, &sources, &self.workflow_limits)
                .map_err(ApplicationError::InvalidWorkflow)?;
            let Some(dispatch) = resolved.workflow.triggers.get("workflow_dispatch") else {
                continue;
            };
            workflows.push(serde_json::json!({
                "path": path,
                "name": resolved.workflow.name,
                "inputs": dispatch.get("inputs").cloned().unwrap_or_else(|| serde_json::json!({}))
            }));
        }
        Ok(
            serde_json::json!({"branch": head.branch, "commit_sha": head.commit_sha, "workflows": workflows}),
        )
    }

    /// Discovers scheduled workflows at the immutable default-branch head.
    ///
    /// # Errors
    ///
    /// Returns forbidden for disabled users, invalid workflow diagnostics, or provider failure.
    pub async fn discover_scheduled_workflows(
        &self,
        user: &User,
        repository_id: Uuid,
    ) -> Result<serde_json::Value, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        let (head, sources) = self.workflow_sources(repository_id, None).await?;
        let mut workflows = Vec::new();
        for path in sources.keys() {
            let resolved = robine_workflows::resolve(path, &sources, &self.workflow_limits)
                .map_err(ApplicationError::InvalidWorkflow)?;
            let Some(schedules) = resolved
                .workflow
                .triggers
                .get("schedule")
                .and_then(serde_json::Value::as_array)
            else {
                continue;
            };
            if schedules.is_empty() {
                continue;
            }
            workflows.push(serde_json::json!({
                "path": path,
                "name": resolved.workflow.name,
                "schedules": schedules.iter().filter_map(|schedule| schedule.get("cron").and_then(serde_json::Value::as_str)).collect::<Vec<_>>()
            }));
        }
        Ok(
            serde_json::json!({"branch": head.branch, "commit_sha": head.commit_sha, "workflows": workflows}),
        )
    }

    /// Reconciles all trusted scheduled workflows against a bounded durable UTC cursor.
    ///
    /// Source heads and archives are fetched once per repository and no database
    /// transaction remains open while a provider is contacted. A failed scan records
    /// only sanitized health metadata and deliberately retains the previous cursor.
    ///
    /// # Errors
    ///
    /// Returns unavailable when persistence or a provider fails, or invalid workflow
    /// when a trusted default-branch workflow cannot be resolved.
    pub async fn reconcile_scheduled_workflows(
        &self,
        now: chrono::DateTime<Utc>,
    ) -> Result<ScheduleReconciliation, ApplicationError> {
        self.reconcile_scheduled_workflows_for_tenant("standalone", now)
            .await
    }

    /// Reconciles schedules independently for every registered tenant.
    ///
    /// # Errors
    ///
    /// Returns unavailable when tenant discovery or any tenant scan fails.
    pub async fn reconcile_all_tenant_schedules(
        &self,
        now: chrono::DateTime<Utc>,
    ) -> Result<Vec<(String, ScheduleReconciliation)>, ApplicationError> {
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut reconciliations = Vec::with_capacity(tenants.len());
        for tenant in tenants {
            let outcome = self
                .reconcile_scheduled_workflows_for_tenant(&tenant, now)
                .await?;
            reconciliations.push((tenant, outcome));
        }
        Ok(reconciliations)
    }

    async fn reconcile_scheduled_workflows_for_tenant(
        &self,
        tenant_id: &str,
        now: chrono::DateTime<Utc>,
    ) -> Result<ScheduleReconciliation, ApplicationError> {
        const CURSOR_KEY: &str = "scheduled-workflows:v1";
        let minute = now
            .with_second(0)
            .and_then(|value| value.with_nanosecond(0))
            .ok_or(ApplicationError::Unavailable)?;
        let cursor = self
            .pipelines
            .schedule_cursor(tenant_id, CURSOR_KEY, now)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let outcome = self
            .reconcile_schedule_window(tenant_id, cursor, minute)
            .await;
        match outcome {
            Ok(mut outcome) => {
                if outcome.scanned_minutes == 0 {
                    return Ok(outcome);
                }
                outcome.cursor_advanced = self
                    .pipelines
                    .advance_schedule_cursor(tenant_id, CURSOR_KEY, cursor, minute, Utc::now())
                    .await
                    .map_err(|_| ApplicationError::Unavailable)?;
                Ok(outcome)
            }
            Err(error) => {
                let failure = schedule_failure_code(&error);
                let _ = self
                    .pipelines
                    .record_schedule_failure(tenant_id, CURSOR_KEY, failure, Utc::now())
                    .await;
                Err(error)
            }
        }
    }

    async fn reconcile_schedule_window(
        &self,
        tenant_id: &str,
        cursor: Option<chrono::DateTime<Utc>>,
        minute: chrono::DateTime<Utc>,
    ) -> Result<ScheduleReconciliation, ApplicationError> {
        if cursor.is_some_and(|cursor| cursor >= minute) {
            return Ok(ScheduleReconciliation {
                scanned_minutes: 0,
                due_occurrences: 0,
                pipelines: 0,
                truncated_minutes: 0,
                cursor_advanced: false,
            });
        }
        let desired_start = cursor.map_or(minute, |cursor| cursor + Duration::minutes(1));
        let oldest_bounded = minute - Duration::minutes(1_439);
        let start = desired_start.max(oldest_bounded);
        let truncated_minutes = (start - desired_start).num_minutes().max(0).cast_unsigned();
        let scanned_minutes = u32::try_from((minute - start).num_minutes() + 1)
            .map_err(|_| ApplicationError::Unavailable)?;
        let repositories = self
            .source_repositories
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .list_trusted(tenant_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut due_occurrences = 0_u32;
        let mut pipelines = 0_u32;
        for repository in repositories {
            let (repository_due, repository_pipelines) = self
                .reconcile_repository_schedules(tenant_id, &repository, start, scanned_minutes)
                .await?;
            due_occurrences = due_occurrences.saturating_add(repository_due);
            pipelines = pipelines.saturating_add(repository_pipelines);
        }
        Ok(ScheduleReconciliation {
            scanned_minutes,
            due_occurrences,
            pipelines,
            truncated_minutes,
            cursor_advanced: false,
        })
    }

    async fn reconcile_repository_schedules(
        &self,
        tenant_id: &str,
        repository: &robine_source::Repository,
        start: chrono::DateTime<Utc>,
        scanned_minutes: u32,
    ) -> Result<(u32, u32), ApplicationError> {
        let (head, sources) = self
            .workflow_sources_for_repository(tenant_id, repository, None)
            .await?;
        let mut due = 0_u32;
        for (path, source) in &sources {
            let resolved = robine_workflows::resolve(path, &sources, &self.workflow_limits)
                .map_err(ApplicationError::InvalidWorkflow)?;
            let schedules = resolved
                .workflow
                .triggers
                .get("schedule")
                .and_then(serde_json::Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|schedule| schedule.get("cron").and_then(serde_json::Value::as_str));
            for cron in schedules {
                for offset in 0..i64::from(scanned_minutes) {
                    let scheduled_for = start + Duration::minutes(offset);
                    if !robine_workflows::cron_matches(cron, scheduled_for) {
                        continue;
                    }
                    due = due.saturating_add(1);
                    let identity = format!(
                        "{}\0{}\0{}\0{}",
                        repository.id,
                        path,
                        cron,
                        scheduled_for.to_rfc3339()
                    );
                    let mut included_sources = sources.clone();
                    included_sources.remove(path);
                    self.create_pipeline_as(
                        tenant_id,
                        "system:scheduler",
                        ActorKind::System,
                        CreatePipelineInput {
                            repository_id: repository.id,
                            workflow_name: resolved.workflow.name.clone(),
                            commit_sha: head.commit_sha.clone(),
                            source_ref: Some(head.branch.clone()),
                            trigger: "schedule".into(),
                            inputs: std::collections::BTreeMap::new(),
                            scheduled_for: Some(scheduled_for),
                            idempotency_key: Some(format!(
                                "schedule:{:x}",
                                Sha256::digest(identity.as_bytes())
                            )),
                            jobs: std::collections::BTreeMap::new(),
                            workflow_revision: Some(
                                robine_core::pipelines::CreateWorkflowRevisionInput {
                                    path: path.clone(),
                                    source: source.clone(),
                                    sources: included_sources,
                                },
                            ),
                        },
                    )
                    .await?;
                }
            }
        }
        Ok((due, due))
    }

    /// Revalidates and launches a manual workflow at the current exact branch SHA.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, not-found for an unknown workflow, invalid input, or provider failure.
    pub async fn launch_manual_workflow(
        &self,
        user: &User,
        repository_id: Uuid,
        branch: Option<&str>,
        workflow_path: &str,
        request_id: &str,
        inputs: std::collections::BTreeMap<String, String>,
    ) -> Result<PipelineProjection, ApplicationError> {
        if user.disabled || user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        if workflow_path.len() > 512 || request_id.is_empty() || request_id.len() > 128 {
            return Err(ApplicationError::InvalidPipelineInput);
        }
        let (head, sources) = self.workflow_sources(repository_id, branch).await?;
        let source = sources
            .get(workflow_path)
            .cloned()
            .ok_or(ApplicationError::PipelineNotFound)?;
        let resolved = robine_workflows::resolve(workflow_path, &sources, &self.workflow_limits)
            .map_err(ApplicationError::InvalidWorkflow)?;
        let normalized_inputs = resolved
            .workflow
            .normalized_inputs("workflow_dispatch", &inputs)
            .map_err(|diagnostic| ApplicationError::InvalidWorkflow(vec![diagnostic]))?;
        let mut included_sources = sources;
        included_sources.remove(workflow_path);
        self.create_pipeline(
            user,
            CreatePipelineInput {
                repository_id,
                workflow_name: resolved.workflow.name,
                commit_sha: head.commit_sha,
                source_ref: Some(head.branch),
                trigger: "workflow_dispatch".into(),
                inputs: normalized_inputs,
                scheduled_for: None,
                idempotency_key: Some(format!("manual:{repository_id}:{request_id}")),
                jobs: std::collections::BTreeMap::new(),
                workflow_revision: Some(robine_core::pipelines::CreateWorkflowRevisionInput {
                    path: workflow_path.into(),
                    source,
                    sources: included_sources,
                }),
            },
        )
        .await
    }

    async fn workflow_sources(
        &self,
        repository_id: Uuid,
        branch: Option<&str>,
    ) -> Result<
        (
            robine_source::BranchHead,
            std::collections::BTreeMap<String, String>,
        ),
        ApplicationError,
    > {
        let repository = self
            .source_repositories
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .find_trusted("standalone", repository_id)
            .await
            .map_err(|_| ApplicationError::PipelineNotFound)?;
        self.workflow_sources_for_repository("standalone", &repository, branch)
            .await
    }

    async fn workflow_sources_for_repository(
        &self,
        _tenant_id: &str,
        repository: &robine_source::Repository,
        branch: Option<&str>,
    ) -> Result<
        (
            robine_source::BranchHead,
            std::collections::BTreeMap<String, String>,
        ),
        ApplicationError,
    > {
        let inspector = self
            .source_inspector
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let head = match branch.filter(|branch| !branch.is_empty()) {
            Some(branch) => inspector.branch_head(repository, branch).await,
            None => inspector.default_branch_head(repository).await,
        }
        .map_err(|_| ApplicationError::Unavailable)?;
        if !valid_commit_sha(&head.commit_sha) {
            return Err(ApplicationError::Unavailable);
        }
        let archive = self
            .source_fetcher
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .fetch_archive(repository, &head.commit_sha)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let files = extract_tar_gz(&archive, ArchiveLimits::default())
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut sources = std::collections::BTreeMap::new();
        for file in files {
            let Some(path) = file
                .path
                .to_str()
                .filter(|path| robine_workflows::valid_workflow_path(path))
            else {
                continue;
            };
            let source = String::from_utf8(file.contents)
                .map_err(|_| ApplicationError::InvalidPipelineInput)?;
            sources.insert(path.to_owned(), source);
        }
        Ok((head, sources))
    }

    /// Lists write-only repository secret metadata for maintainers.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers or unavailable when secret storage is not configured.
    pub async fn list_repository_secrets(
        &self,
        user: &User,
        repository_id: Uuid,
    ) -> Result<Vec<String>, ApplicationError> {
        if user.disabled || user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        let secrets = self
            .secret_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .list_repository("standalone", repository_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(secrets.into_iter().map(|secret| secret.name).collect())
    }

    /// Encrypts and atomically audits a write-only repository secret.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, invalid input for malformed values, or unavailable.
    pub async fn store_repository_secret(
        &self,
        user: &User,
        repository_id: Uuid,
        name: String,
        value: &[u8],
    ) -> Result<(), ApplicationError> {
        if user.disabled || user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        if !valid_secret_name(&name) || !(8..=65_536).contains(&value.len()) {
            return Err(ApplicationError::InvalidPipelineInput);
        }
        let secret = self
            .secret_encryptor
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .encrypt_repository(repository_id, name, value)
            .map_err(|_| ApplicationError::Unavailable)?;
        self.secret_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .upsert_repository("standalone", user.id, &secret)
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Loads one tenant-scoped pipeline browser projection.
    ///
    /// # Errors
    ///
    /// Returns forbidden for a disabled user, not-found for an unknown pipeline, or unavailable.
    pub async fn pipeline_browser_projection(
        &self,
        user: &User,
        pipeline_id: Uuid,
    ) -> Result<serde_json::Value, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .pipeline_browser_projection("standalone", pipeline_id)
            .await
            .map_err(|error| browser_projection_error(&error))
    }

    /// Loads one immutable workflow revision projection.
    ///
    /// # Errors
    ///
    /// Returns forbidden for a disabled user, not-found for an unknown pipeline, or unavailable.
    pub async fn workflow_browser_projection(
        &self,
        user: &User,
        pipeline_id: Uuid,
    ) -> Result<serde_json::Value, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .workflow_browser_projection("standalone", pipeline_id)
            .await
            .map_err(|error| browser_projection_error(&error))
    }

    /// Loads one job projection belonging to a pipeline.
    ///
    /// # Errors
    ///
    /// Returns forbidden for a disabled user, not-found for unknown work, or unavailable.
    pub async fn job_browser_projection(
        &self,
        user: &User,
        pipeline_id: Uuid,
        job_id: Uuid,
    ) -> Result<serde_json::Value, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .job_browser_projection("standalone", pipeline_id, job_id)
            .await
            .map_err(|error| browser_projection_error(&error))
    }

    /// Downloads ordered text logs for every retained attempt of one job.
    ///
    /// # Errors
    ///
    /// Returns forbidden for a disabled user, not-found for unknown work, or unavailable.
    pub async fn job_log_download(
        &self,
        user: &User,
        pipeline_id: Uuid,
        job_id: Uuid,
    ) -> Result<String, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .job_log_download("standalone", pipeline_id, job_id)
            .await
            .map_err(|error| browser_projection_error(&error))
    }

    /// Downloads one unexpired artifact produced by a visible job.
    ///
    /// # Errors
    ///
    /// Returns forbidden for a disabled user, not-found for unknown content, or unavailable.
    pub async fn job_artifact_download(
        &self,
        user: &User,
        pipeline_id: Uuid,
        job_id: Uuid,
        name: &str,
    ) -> Result<RemoteTransferDownload, ApplicationError> {
        if user.disabled {
            return Err(ApplicationError::Forbidden);
        }
        if name.is_empty() || name.len() > 128 {
            return Err(ApplicationError::PipelineNotFound);
        }
        self.pipelines
            .job_browser_projection("standalone", pipeline_id, job_id)
            .await
            .map_err(|error| browser_projection_error(&error))?;
        let artifact = self
            .storage_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .job_artifact("standalone", pipeline_id, job_id, name, Utc::now())
            .await
            .map_err(|_| ApplicationError::PipelineNotFound)?;
        let content = self
            .blob_store
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .get("standalone", &artifact.object)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(RemoteTransferDownload {
            content,
            digest: artifact.object.digest,
        })
    }

    /// Validates and atomically persists a pipeline, immutable revision, job graph, and event.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, invalid input for malformed metadata/graphs/revisions,
    /// conflict when an idempotency key is reused differently, or unavailable on storage failure.
    pub async fn create_pipeline(
        &self,
        user: &User,
        input: CreatePipelineInput,
    ) -> Result<PipelineProjection, ApplicationError> {
        if user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        self.create_pipeline_as("standalone", &user.id.to_string(), ActorKind::User, input)
            .await
    }

    async fn create_pipeline_as(
        &self,
        tenant_id: &str,
        actor_id: &str,
        actor_kind: ActorKind,
        mut input: CreatePipelineInput,
    ) -> Result<PipelineProjection, ApplicationError> {
        populate_jobs_from_workflow(&mut input, &self.workflow_limits)?;
        input
            .validate()
            .map_err(|_| ApplicationError::InvalidPipelineInput)?;
        let context = ExecutionContext::embedded(
            Actor {
                id: actor_id.into(),
                kind: actor_kind,
            },
            tenant_id,
            [Capability::new("pipelines:create")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;
        let pipeline_id = match &input.idempotency_key {
            Some(key) if (1..=512).contains(&key.len()) => deterministic_uuid(key),
            Some(_) => return Err(ApplicationError::InvalidPipelineInput),
            None => Uuid::new_v4(),
        };
        let now = Utc::now();
        let pipeline =
            build_new_pipeline(input, pipeline_id, actor_id, context.correlation_id, now)?;
        self.pipelines
            .create(&context.tenant_id, &pipeline)
            .await
            .map_err(|error| match error {
                PortError::IdempotencyConflict => ApplicationError::IdempotencyConflict,
                PortError::InvalidData => ApplicationError::InvalidPipelineInput,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Cancels queued work immediately and marks active work for cancellation atomically.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, not found for an unknown tenant-visible pipeline,
    /// not cancellable for terminal state, or unavailable for persistence failures.
    pub async fn cancel_pipeline(
        &self,
        user: &User,
        pipeline_id: Uuid,
    ) -> Result<PipelineProjection, ApplicationError> {
        if user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::User,
            },
            "standalone",
            [Capability::new("pipelines:cancel")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;

        self.pipelines
            .cancel(&context.tenant_id, pipeline_id, Uuid::new_v4(), Utc::now())
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::InvalidTransition => ApplicationError::PipelineNotCancellable,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Queues a created pipeline, idempotently accepting already queued/running work.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, not found for an unknown tenant-visible pipeline,
    /// conflict for a cancelling/terminal pipeline, or unavailable for storage failures.
    pub async fn queue_pipeline(
        &self,
        user: &User,
        pipeline_id: Uuid,
    ) -> Result<PipelineProjection, ApplicationError> {
        if user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::User,
            },
            "standalone",
            [Capability::new("pipelines:queue")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;
        self.pipelines
            .queue(&context.tenant_id, pipeline_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::InvalidTransition => ApplicationError::PipelineNotQueueable,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Requeues a failed or cancelled job after validating dependencies and retained inputs.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, not found for an unknown tenant-visible job, conflict
    /// errors for invalid state or unavailable prerequisites, and unavailable for storage errors.
    pub async fn retry_job(
        &self,
        user: &User,
        job_id: Uuid,
    ) -> Result<RetryProjection, ApplicationError> {
        if user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::User,
            },
            "standalone",
            [Capability::new("pipelines:retry")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;
        self.pipelines
            .retry_job(&context.tenant_id, job_id, Uuid::new_v4(), Utc::now())
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::InvalidTransition => ApplicationError::JobNotRetryable,
                PortError::RetryDependenciesUnavailable(keys) => {
                    ApplicationError::RetryDependenciesUnavailable(keys)
                }
                PortError::RetryInputsUnavailable(inputs) => {
                    ApplicationError::RetryInputsUnavailable(inputs)
                }
                _ => ApplicationError::Unavailable,
            })
    }

    /// Atomically claims one fair ready job and creates a leased execution attempt.
    ///
    /// # Errors
    ///
    /// Returns forbidden outside administrator-owned scheduler delivery, capacity when an
    /// active limit is reached, no work when nothing is eligible, or unavailable on failure.
    pub async fn claim_next_job(
        &self,
        user: &User,
        global_limit: i64,
        repository_limit: i64,
        lease_seconds: i64,
        runner_id: Option<Uuid>,
    ) -> Result<AttemptProjection, ApplicationError> {
        if user.role != Role::Administrator {
            return Err(ApplicationError::Forbidden);
        }
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::System,
            },
            "standalone",
            [Capability::new("scheduler:claim")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;
        let claim = SchedulerClaim {
            global_limit: global_limit.clamp(1, 1_024),
            repository_limit: repository_limit.clamp(1, 1_024),
            lease_seconds: lease_seconds.clamp(1, 86_400),
            attempt_id: Uuid::new_v4(),
            idempotency_token: Uuid::new_v4(),
            event_id: Uuid::new_v4(),
            now: Utc::now(),
            runner_id,
        };
        self.pipelines
            .claim_next_job(&context.tenant_id, &claim)
            .await
            .map_err(|error| match error {
                PortError::Capacity => ApplicationError::SchedulerCapacity,
                PortError::NoWork => ApplicationError::NoWork,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Records one ordered local-runner event and reconciles the durable job graph.
    ///
    /// # Errors
    ///
    /// Returns forbidden outside administrator-owned delivery, a sequence/validation error
    /// for invalid events, unauthenticated for unknown attempts, or unavailable on failure.
    pub async fn record_attempt_event(
        &self,
        user: &User,
        event: RecordAttemptEvent,
    ) -> Result<AttemptProjection, ApplicationError> {
        if user.role != Role::Administrator {
            return Err(ApplicationError::Forbidden);
        }
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::System,
            },
            "standalone",
            [Capability::new("attempts:record")],
            Uuid::new_v4(),
        )
        .map_err(|_| ApplicationError::Forbidden)?;
        self.pipelines
            .record_attempt_event(&context.tenant_id, Uuid::new_v4(), &event, Utc::now())
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::Unauthenticated,
                PortError::EventGap { expected, actual } => {
                    ApplicationError::EventSequenceGap { expected, actual }
                }
                PortError::InvalidAttemptEvent | PortError::InvalidTransition => {
                    ApplicationError::InvalidAttemptEvent
                }
                _ => ApplicationError::Unavailable,
            })
    }

    /// Renews one active local attempt lease without advancing its event sequence.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators, unauthenticated for an unknown token,
    /// invalid-event for a terminal attempt, or unavailable on persistence failure.
    pub async fn heartbeat_attempt(
        &self,
        user: &User,
        idempotency_token: Uuid,
        lease_seconds: i64,
    ) -> Result<AttemptProjection, ApplicationError> {
        if user.role != Role::Administrator {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .heartbeat_attempt(
                "standalone",
                idempotency_token,
                lease_seconds.clamp(1, 86_400),
                Utc::now(),
            )
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::Unauthenticated,
                PortError::InvalidTransition => ApplicationError::InvalidAttemptEvent,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Fails expired active attempts as `runner_lost` and reconciles their graphs.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators or unavailable on persistence failure.
    pub async fn reconcile_expired_attempts(
        &self,
        user: &User,
        limit: i64,
    ) -> Result<u64, ApplicationError> {
        if user.role != Role::Administrator {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .reconcile_expired_attempts("standalone", limit.clamp(1, 1_000), Utc::now())
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Reconciles a bounded number of expired attempts for every registered tenant.
    ///
    /// This operation is owned by the runtime worker rather than an HTTP actor. Durable row locks
    /// and terminal-event idempotency make concurrent worker ticks safe.
    ///
    /// # Errors
    ///
    /// Returns unavailable when tenant discovery or graph reconciliation fails.
    pub async fn reconcile_all_expired_attempts(
        &self,
        per_tenant_limit: i64,
    ) -> Result<u64, ApplicationError> {
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut reconciled = 0_u64;
        for tenant_id in tenants {
            reconciled = reconciled.saturating_add(
                self.pipelines
                    .reconcile_expired_attempts(
                        &tenant_id,
                        per_tenant_limit.clamp(1, 1_000),
                        Utc::now(),
                    )
                    .await
                    .map_err(|_| ApplicationError::Unavailable)?,
            );
        }
        Ok(reconciled)
    }

    /// Authenticates a remote runner and renews every active attempt it owns.
    ///
    /// # Errors
    ///
    /// Returns unauthenticated for missing/invalid/revoked machine credentials or unavailable
    /// when durable runner state cannot be loaded or updated.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn heartbeat_runner_attempts(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        lease_seconds: i64,
    ) -> Result<RunnerLeaseHeartbeat, ApplicationError> {
        let now = Utc::now();
        self.authenticate_runner(tenant_id, runner_id, credential, now)
            .await?;
        self.pipelines
            .heartbeat_runner_attempts(tenant_id, runner_id, lease_seconds.clamp(1, 86_400), now)
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Creates a one-time runner enrollment token for an administrator.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators or unavailable on entropy/persistence failure.
    pub async fn create_runner_enrollment(
        &self,
        tenant_id: &str,
        actor: &User,
    ) -> Result<RunnerEnrollment, ApplicationError> {
        if actor.role != Role::Administrator || actor.disabled {
            return Err(ApplicationError::Forbidden);
        }
        let token = generated_runner_secret("rbe")?;
        let now = Utc::now();
        let id = Uuid::new_v4();
        let expires_at = now + chrono::Duration::minutes(15);
        self.pipelines
            .create_runner_enrollment(
                tenant_id,
                &NewRunnerEnrollment {
                    id,
                    token_digest: self.runner_secret_digest(&token)?,
                    expires_at,
                    created_by: actor.id,
                    audit_id: Uuid::new_v4(),
                    correlation_id: Uuid::new_v4(),
                    inserted_at: now,
                },
            )
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(RunnerEnrollment {
            id,
            token,
            expires_at,
        })
    }

    /// Atomically consumes one enrollment token and returns the credential once.
    ///
    /// # Errors
    ///
    /// Returns invalid credentials for malformed, expired, consumed, or unknown tokens; invalid
    /// input for a bad runner name; or unavailable on entropy/persistence failure.
    pub async fn enroll_runner(
        &self,
        tenant_id: &str,
        token: &str,
        name: &str,
    ) -> Result<EnrolledRunner, ApplicationError> {
        let name = name.trim();
        if name.is_empty() || name.chars().count() > 80 {
            return Err(ApplicationError::InvalidPipelineInput);
        }
        if token
            .strip_prefix("rbe_")
            .is_none_or(|value| value.len() < 43)
        {
            return Err(ApplicationError::InvalidCredentials);
        }
        let credential = generated_runner_secret("rrc")?;
        let runner_id = Uuid::new_v4();
        let request = ConsumeRunnerEnrollment {
            token_digest: self.runner_secret_digest(token)?,
            runner_id,
            runner_name: name.into(),
            credential_id: Uuid::new_v4(),
            credential_digest: self.runner_secret_digest(&credential)?,
            audit_id: Uuid::new_v4(),
            correlation_id: Uuid::new_v4(),
            now: Utc::now(),
        };
        self.pipelines
            .consume_runner_enrollment(tenant_id, &request)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::InvalidCredentials,
                _ => ApplicationError::Unavailable,
            })?;
        Ok(EnrolledRunner {
            runner_id,
            credential,
        })
    }

    /// Rotates a runner credential with a five-minute overlap.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators, not-found for an unknown/revoked runner, or
    /// unavailable on entropy/persistence failure.
    pub async fn rotate_runner_credential(
        &self,
        tenant_id: &str,
        actor: &User,
        runner_id: Uuid,
    ) -> Result<EnrolledRunner, ApplicationError> {
        if actor.role != Role::Administrator || actor.disabled {
            return Err(ApplicationError::Forbidden);
        }
        let credential = generated_runner_secret("rrc")?;
        let now = Utc::now();
        self.pipelines
            .rotate_runner_credential(
                tenant_id,
                &RotateRunnerCredential {
                    runner_id,
                    credential_id: Uuid::new_v4(),
                    credential_digest: self.runner_secret_digest(&credential)?,
                    overlap_expires_at: now + chrono::Duration::minutes(5),
                    actor_id: actor.id,
                    audit_id: Uuid::new_v4(),
                    correlation_id: Uuid::new_v4(),
                    now,
                },
            )
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                _ => ApplicationError::Unavailable,
            })?;
        Ok(EnrolledRunner {
            runner_id,
            credential,
        })
    }

    /// Immediately revokes a runner and every active credential.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators, not-found for an unknown runner, or unavailable
    /// on persistence failure.
    pub async fn revoke_runner(
        &self,
        tenant_id: &str,
        actor: &User,
        runner_id: Uuid,
    ) -> Result<(), ApplicationError> {
        if actor.role != Role::Administrator || actor.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .revoke_runner(
                tenant_id,
                &RevokeRunner {
                    runner_id,
                    actor_id: actor.id,
                    audit_id: Uuid::new_v4(),
                    correlation_id: Uuid::new_v4(),
                    now: Utc::now(),
                },
            )
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Lists the tenant runner fleet for an administrator.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators or unavailable on persistence failure.
    pub async fn list_runner_fleet(
        &self,
        tenant_id: &str,
        actor: &User,
    ) -> Result<Vec<RunnerFleetEntry>, ApplicationError> {
        if actor.role != Role::Administrator || actor.disabled {
            return Err(ApplicationError::Forbidden);
        }
        self.pipelines
            .list_runner_fleet(tenant_id, Utc::now())
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Durably accepts one authenticated source-control delivery.
    ///
    /// Returns `true` for a newly accepted delivery and `false` for a duplicate provider
    /// identity. Authentication and JSON decoding are adapter responsibilities so invalid
    /// requests cannot reach persistence.
    ///
    /// # Errors
    ///
    /// Returns unavailable when the delivery cannot be persisted.
    pub async fn accept_source_control_delivery(
        &self,
        tenant_id: &str,
        delivery: &SourceControlDelivery,
    ) -> Result<bool, ApplicationError> {
        self.pipelines
            .accept_source_control_delivery(tenant_id, delivery)
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Updates an active runner's display name, labels, and enabled/draining state.
    ///
    /// # Errors
    ///
    /// Returns forbidden for non-administrators, invalid input for malformed configuration,
    /// not-found for an unknown/revoked runner, or unavailable on persistence failure.
    pub async fn configure_runner(
        &self,
        tenant_id: &str,
        actor: &User,
        runner_id: Uuid,
        name: &str,
        labels: Vec<String>,
        admin_state: &str,
    ) -> Result<(), ApplicationError> {
        if actor.role != Role::Administrator || actor.disabled {
            return Err(ApplicationError::Forbidden);
        }
        let name = name.trim();
        let mut normalized_labels = Vec::new();
        for label in labels {
            let label = label.trim();
            let valid_start = label
                .as_bytes()
                .first()
                .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit());
            let valid = !label.is_empty() && label.len() <= 63 && valid_start;
            let valid_tail = label.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._-".contains(&byte)
            });
            if !valid || !valid_tail || normalized_labels.len() >= 32 {
                return Err(ApplicationError::InvalidPipelineInput);
            }
            if !normalized_labels.iter().any(|known| known == label) {
                normalized_labels.push(label.to_owned());
            }
        }
        if name.is_empty()
            || name.chars().count() > 80
            || !matches!(admin_state, "enabled" | "draining")
        {
            return Err(ApplicationError::InvalidPipelineInput);
        }
        self.pipelines
            .configure_runner(
                tenant_id,
                &ConfigureRunner {
                    runner_id,
                    name: name.into(),
                    labels: normalized_labels,
                    admin_state: admin_state.into(),
                    actor_id: actor.id,
                    audit_id: Uuid::new_v4(),
                    correlation_id: Uuid::new_v4(),
                    now: Utc::now(),
                },
            )
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                _ => ApplicationError::Unavailable,
            })
    }

    /// Authenticates and records a bounded protocol-v1 remote-runner session.
    ///
    /// # Errors
    ///
    /// Returns invalid-event for an incompatible or malformed hello, unauthenticated for an
    /// invalid or revoked machine credential, or unavailable when session metadata cannot be
    /// persisted.
    pub async fn negotiate_runner_session(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        supported_versions: &[i32],
        software_version: &str,
        capabilities: &serde_json::Value,
    ) -> Result<i32, ApplicationError> {
        let valid_capabilities = capabilities.is_object()
            && serde_json::to_vec(capabilities).is_ok_and(|encoded| encoded.len() <= 32_768);
        if !supported_versions.contains(&1)
            || software_version.is_empty()
            || software_version.len() > 128
            || !valid_capabilities
        {
            return Err(ApplicationError::InvalidAttemptEvent);
        }
        let now = Utc::now();
        self.authenticate_runner(tenant_id, runner_id, credential, now)
            .await?;
        self.pipelines
            .record_runner_session(tenant_id, runner_id, 1, software_version, capabilities, now)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::Unauthenticated,
                _ => ApplicationError::Unavailable,
            })?;
        Ok(1)
    }

    /// Reconciles a reconnecting runner's reported work with durable active ownership.
    ///
    /// # Errors
    ///
    /// Returns invalid-event for more than 64 reported attempts, unauthenticated for invalid
    /// machine credentials, or unavailable when durable state cannot be reconciled.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn reconcile_runner_attempts(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        reported_attempt_ids: Vec<Uuid>,
    ) -> Result<RunnerReconciliation, ApplicationError> {
        if reported_attempt_ids.len() > 64 {
            return Err(ApplicationError::InvalidAttemptEvent);
        }
        let now = Utc::now();
        self.authenticate_runner(tenant_id, runner_id, credential, now)
            .await?;
        let resume = self
            .pipelines
            .reconcile_runner_attempts(tenant_id, runner_id, now)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::Unauthenticated,
                _ => ApplicationError::Unavailable,
            })?;
        let assigned = resume
            .iter()
            .map(|item| item.attempt_id)
            .collect::<BTreeSet<_>>();
        let reported = reported_attempt_ids.into_iter().collect::<BTreeSet<_>>();
        Ok(RunnerReconciliation {
            resume,
            lease_lost: reported.difference(&assigned).copied().collect(),
        })
    }

    /// Authenticates and durably records one idempotent ordered remote-runner event.
    ///
    /// # Errors
    ///
    /// Returns unauthenticated for invalid machine credentials, forbidden for an unowned
    /// attempt, conflict for message reuse or sequence gaps, invalid-event for invalid state,
    /// or unavailable on persistence failure.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn record_remote_attempt_event(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        event: RecordRemoteAttemptEvent,
    ) -> Result<AttemptProjection, ApplicationError> {
        let now = Utc::now();
        self.authenticate_runner(tenant_id, runner_id, credential, now)
            .await?;
        self.pipelines
            .record_remote_attempt_event(
                tenant_id,
                runner_id,
                Uuid::new_v4(),
                Uuid::new_v4(),
                &event,
                now,
            )
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::Unauthenticated,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                PortError::MessageIdConflict => ApplicationError::IdempotencyConflict,
                PortError::EventGap { expected, actual } => {
                    ApplicationError::EventSequenceGap { expected, actual }
                }
                PortError::StaleEvent { last, actual } => ApplicationError::EventSequenceGap {
                    expected: last + 1,
                    actual,
                },
                PortError::InvalidAttemptEvent | PortError::InvalidTransition => {
                    ApplicationError::InvalidAttemptEvent
                }
                _ => ApplicationError::Unavailable,
            })
    }

    /// Returns a claimed execution offer only to its authenticated owning runner.
    ///
    /// # Errors
    ///
    /// Returns unauthenticated for invalid machine credentials, forbidden for a claim owned by
    /// another runner, not-found for an unknown attempt, or unavailable on persistence failure.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn remote_job_offer(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
    ) -> Result<serde_json::Value, ApplicationError> {
        self.authenticate_runner(tenant_id, runner_id, credential, Utc::now())
            .await?;
        let mut offer = self
            .pipelines
            .remote_job_offer(tenant_id, runner_id, attempt_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                _ => ApplicationError::Unavailable,
            })?;
        let checkout = offer
            .get("steps")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|steps| {
                steps.iter().any(|step| {
                    step.get("kind").and_then(serde_json::Value::as_str) == Some("builtin")
                        && step.get("value").and_then(serde_json::Value::as_str) == Some("checkout")
                })
            });
        if let Some(object) = offer.as_object_mut() {
            let base = format!("/api/v1/runners/attempts/{attempt_id}");
            object.insert(
                "builtins_url".into(),
                serde_json::Value::String(base.clone()),
            );
            object.insert(
                "secrets_url".into(),
                serde_json::Value::String(format!("{base}/secrets")),
            );
            if checkout {
                object.insert(
                    "source_url".into(),
                    serde_json::Value::String(format!("{base}/source")),
                );
            }
        }
        Ok(offer)
    }

    /// Returns a bounded source archive only to the authenticated runner owning the attempt.
    ///
    /// # Errors
    ///
    /// Returns unauthenticated for invalid machine credentials, forbidden for another runner's
    /// attempt, not-found when checkout is not declared, or unavailable for source failures.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn remote_attempt_source(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
    ) -> Result<Vec<u8>, ApplicationError> {
        self.authenticate_runner(tenant_id, runner_id, credential, Utc::now())
            .await?;
        let raw = self
            .pipelines
            .remote_job_offer(tenant_id, runner_id, attempt_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                _ => ApplicationError::Unavailable,
            })?;
        let checkout = raw
            .get("steps")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|steps| {
                steps.iter().any(|step| {
                    step.get("kind").and_then(serde_json::Value::as_str) == Some("builtin")
                        && step.get("value").and_then(serde_json::Value::as_str) == Some("checkout")
                })
            });
        if !checkout {
            return Err(ApplicationError::PipelineNotFound);
        }
        let repository_id = raw
            .get("repository_id")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .ok_or(ApplicationError::Unavailable)?;
        let commit_sha = raw
            .get("commit_sha")
            .and_then(serde_json::Value::as_str)
            .filter(|value| valid_commit_sha(value))
            .ok_or(ApplicationError::Unavailable)?;
        let repositories = self
            .source_repositories
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let fetcher = self
            .source_fetcher
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let repository = repositories
            .find_trusted(tenant_id, repository_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let provider_archive = fetcher
            .fetch_archive(&repository, commit_sha)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let files = robine_source::extract_tar_gz(
            &provider_archive,
            robine_source::ArchiveLimits::default(),
        )
        .map_err(|_| ApplicationError::Unavailable)?;
        robine_source::create_source_tar_gz(&files, robine_source::ArchiveLimits::default())
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Returns declared secret values only to the authenticated runner owning the attempt.
    ///
    /// # Errors
    ///
    /// Returns unauthenticated for invalid machine credentials, forbidden for another runner's
    /// attempt, or unavailable when declarations cannot be resolved and decrypted completely.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn remote_attempt_secrets(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
    ) -> Result<Vec<u8>, ApplicationError> {
        self.authenticate_runner(tenant_id, runner_id, credential, Utc::now())
            .await?;
        let raw = self
            .pipelines
            .remote_job_offer(tenant_id, runner_id, attempt_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                _ => ApplicationError::Unavailable,
            })?;
        let names = match raw
            .get("secret_names")
            .and_then(serde_json::Value::as_array)
        {
            None => Vec::new(),
            Some(names) => names
                .iter()
                .map(serde_json::Value::as_str)
                .map(|name| name.map(str::to_owned))
                .collect::<Option<Vec<_>>>()
                .ok_or(ApplicationError::Unavailable)?,
        };
        if names.is_empty() {
            return serde_json::to_vec(&serde_json::json!({"secrets": {}}))
                .map_err(|_| ApplicationError::Unavailable);
        }
        let repository_id = raw
            .get("repository_id")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .ok_or(ApplicationError::Unavailable)?;
        let repository = self
            .secret_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let decryptor = self
            .secret_decryptor
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let encrypted = repository
            .find_authorized(tenant_id, repository_id, &names)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut resolved = std::collections::BTreeMap::new();
        for secret in encrypted {
            let plaintext = decryptor
                .decrypt(&secret)
                .map_err(|_| ApplicationError::Unavailable)?;
            let plaintext =
                String::from_utf8(plaintext.to_vec()).map_err(|_| ApplicationError::Unavailable)?;
            if resolved.insert(secret.name, plaintext).is_some() {
                return Err(ApplicationError::Unavailable);
            }
        }
        if names.iter().any(|name| !resolved.contains_key(name)) {
            return Err(ApplicationError::Unavailable);
        }
        serde_json::to_vec(&serde_json::json!({"secrets": resolved}))
            .map_err(|_| ApplicationError::Unavailable)
    }

    /// Persists one bounded idempotent log chunk from the authenticated owning runner.
    ///
    /// # Errors
    ///
    /// Returns unauthenticated for invalid credentials, forbidden for another runner's attempt,
    /// invalid-event for malformed metadata, or unavailable when persistence fails.
    ///
    /// # Panics
    ///
    /// HMAC-SHA256 accepts the fixed 32-byte derived key, so construction cannot panic.
    pub async fn record_remote_log(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        mut chunk: ExecutionLogChunk,
    ) -> Result<i64, ApplicationError> {
        self.authenticate_runner(tenant_id, runner_id, credential, Utc::now())
            .await?;
        self.pipelines
            .remote_job_offer(tenant_id, runner_id, chunk.attempt_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                _ => ApplicationError::Unavailable,
            })?;
        if chunk.sequence <= 0
            || chunk.step_position < 0
            || chunk.step_name.len() > 255
            || chunk.content.len() > 64_000
            || !matches!(chunk.stream.as_str(), "stdout" | "stderr" | "system")
        {
            return Err(ApplicationError::InvalidAttemptEvent);
        }
        chunk.id = Uuid::new_v4();
        chunk.inserted_at = Utc::now();
        let sequence = chunk.sequence;
        self.pipelines
            .append_execution_log(tenant_id, &chunk)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(sequence)
    }

    /// Restores a repository cache through an owning runner's attempt scope.
    ///
    /// # Errors
    ///
    /// Returns authentication/ownership errors, invalid-event for an invalid key, or unavailable
    /// when storage metadata or content cannot be read safely.
    pub async fn remote_restore_cache(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
        key: &str,
    ) -> Result<Option<RemoteTransferDownload>, ApplicationError> {
        let raw = self
            .authorized_remote_offer(tenant_id, runner_id, credential, attempt_id)
            .await?;
        if key.is_empty() || key.len() > 512 {
            return Err(ApplicationError::InvalidAttemptEvent);
        }
        let repository_id = remote_uuid(&raw, "repository_id")?;
        let repository = self
            .storage_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let Some(cache) = repository
            .restore_cache(tenant_id, repository_id, key, Utc::now())
            .await
            .map_err(|_| ApplicationError::Unavailable)?
        else {
            return Ok(None);
        };
        let content = self
            .blob_store
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .get(tenant_id, &cache.object)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(Some(RemoteTransferDownload {
            content,
            digest: cache.object.digest,
        }))
    }

    /// Publishes a bounded validated repository cache through an owning attempt scope.
    ///
    /// # Errors
    ///
    /// Returns authentication/ownership errors, invalid-event for invalid input, or unavailable
    /// when content-addressed publication or quota-locked metadata persistence fails.
    pub async fn remote_save_cache(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
        key: &str,
        content: Vec<u8>,
    ) -> Result<RemoteTransferUpload, ApplicationError> {
        let raw = self
            .authorized_remote_offer(tenant_id, runner_id, credential, attempt_id)
            .await?;
        if key.is_empty()
            || key.len() > 512
            || robine_source::validate_workspace_tar_gz(
                &content,
                robine_source::ArchiveLimits::default(),
            )
            .is_err()
        {
            return Err(ApplicationError::InvalidAttemptEvent);
        }
        let repository_id = remote_uuid(&raw, "repository_id")?;
        let blobs = self
            .blob_store
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let object = blobs
            .put(tenant_id, content)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let now = Utc::now();
        let cache = CacheEntry {
            id: Uuid::new_v4(),
            repository_id,
            key: key.into(),
            object: object.clone(),
            created_at: now,
            expires_at: now + chrono::Duration::days(7),
        };
        let repository = self
            .storage_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        if repository
            .save_cache(tenant_id, &cache, self.storage_quotas)
            .await
            .is_err()
        {
            let _ = repository
                .stage_blob_gc(
                    tenant_id,
                    &object.blob_id,
                    now + chrono::Duration::hours(1),
                    now,
                )
                .await;
            return Err(ApplicationError::Unavailable);
        }
        Ok(RemoteTransferUpload {
            id: None,
            digest: object.digest,
            size: object.size,
        })
    }

    /// Downloads one retained artifact from a declared successful dependency.
    ///
    /// # Errors
    ///
    /// Returns authentication/ownership errors, not-found for undeclared or unavailable content,
    /// or unavailable when storage cannot be read safely.
    #[allow(clippy::too_many_arguments)]
    pub async fn remote_download_artifact(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
        from_job: &str,
        name: &str,
    ) -> Result<RemoteTransferDownload, ApplicationError> {
        let raw = self
            .authorized_remote_offer(tenant_id, runner_id, credential, attempt_id)
            .await?;
        let declared = raw
            .get("needs")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|needs| needs.iter().any(|need| need.as_str() == Some(from_job)));
        if !declared || name.is_empty() || name.len() > 128 {
            return Err(ApplicationError::PipelineNotFound);
        }
        let artifact = self
            .storage_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .dependency_artifact(
                tenant_id,
                remote_uuid(&raw, "pipeline_id")?,
                from_job,
                name,
                Utc::now(),
            )
            .await
            .map_err(|_| ApplicationError::PipelineNotFound)?;
        let content = self
            .blob_store
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .get(tenant_id, &artifact.object)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(RemoteTransferDownload {
            content,
            digest: artifact.object.digest,
        })
    }

    /// Publishes one immutable attempt-owned artifact after validating its archive.
    ///
    /// # Errors
    ///
    /// Returns authentication/ownership errors, invalid-event for invalid input, or unavailable
    /// when content-addressed publication or quota-locked metadata persistence fails.
    #[allow(clippy::too_many_arguments)]
    pub async fn remote_upload_artifact(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
        name: &str,
        retention_days: i64,
        content: Vec<u8>,
    ) -> Result<RemoteTransferUpload, ApplicationError> {
        let raw = self
            .authorized_remote_offer(tenant_id, runner_id, credential, attempt_id)
            .await?;
        if name.is_empty()
            || name.len() > 128
            || !(1..=90).contains(&retention_days)
            || robine_source::validate_workspace_tar_gz(
                &content,
                robine_source::ArchiveLimits::default(),
            )
            .is_err()
        {
            return Err(ApplicationError::InvalidAttemptEvent);
        }
        let blobs = self
            .blob_store
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let object = blobs
            .put(tenant_id, content)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let now = Utc::now();
        let artifact = Artifact {
            id: Uuid::new_v4(),
            repository_id: remote_uuid(&raw, "repository_id")?,
            attempt_id,
            name: name.into(),
            object: object.clone(),
            created_at: now,
            expires_at: now + chrono::Duration::days(retention_days),
        };
        let repository = self
            .storage_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        if repository
            .upload_artifact(tenant_id, &artifact, self.storage_quotas)
            .await
            .is_err()
        {
            let _ = repository
                .stage_blob_gc(
                    tenant_id,
                    &object.blob_id,
                    now + chrono::Duration::hours(1),
                    now,
                )
                .await;
            return Err(ApplicationError::Unavailable);
        }
        Ok(RemoteTransferUpload {
            id: Some(artifact.id),
            digest: object.digest,
            size: object.size,
        })
    }

    /// Processes a bounded batch of pending durable outbox events.
    ///
    /// # Errors
    ///
    /// Returns unavailable when the durable delivery transaction fails.
    pub async fn process_outbox_batch(
        &self,
        tenant_id: &str,
        limit: usize,
    ) -> Result<OutboxBatch, ApplicationError> {
        let mut batch = OutboxBatch::default();
        for _ in 0..limit.clamp(1, 100) {
            let Some(delivery) = self
                .pipelines
                .process_next_outbox_event(tenant_id, Utc::now())
                .await
                .map_err(|_| ApplicationError::Unavailable)?
            else {
                break;
            };
            count_outbox_delivery(&mut batch, &delivery);
        }
        Ok(batch)
    }

    /// Processes one bounded outbox batch for every registered tenant.
    ///
    /// # Errors
    ///
    /// Returns unavailable when tenant discovery or any durable delivery transaction fails.
    pub async fn process_all_tenant_outboxes(
        &self,
        per_tenant_limit: usize,
    ) -> Result<OutboxBatch, ApplicationError> {
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut total = OutboxBatch::default();
        for tenant in tenants {
            let batch = self.process_outbox_batch(&tenant, per_tenant_limit).await?;
            total.processed += batch.processed;
            total.delivered += batch.delivered;
            total.dispatch_enqueued += batch.dispatch_enqueued;
        }
        Ok(total)
    }

    /// Reconciles local execution handoffs and consumes bounded durable scheduler work.
    ///
    /// # Errors
    ///
    /// Returns unavailable when tenant discovery, claiming, or retry persistence fails.
    pub async fn process_all_tenant_dispatches(
        &self,
        per_tenant_limit: usize,
    ) -> Result<DispatchBatch, ApplicationError> {
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut total = DispatchBatch::default();
        for tenant in tenants {
            let batch = self
                .process_dispatch_batch(&tenant, per_tenant_limit)
                .await?;
            total.processed += batch.processed;
            total.attempts_created += batch.attempts_created;
            total.no_work += batch.no_work;
            total.retried += batch.retried;
            total.discarded += batch.discarded;
            total.reconciled += batch.reconciled;
        }
        Ok(total)
    }

    /// Claims and processes authenticated source-control deliveries for every tenant.
    ///
    /// Pipeline creation is idempotent per delivery and workflow path, so a crash between a
    /// pipeline commit and delivery completion can safely replay the durable job.
    ///
    /// # Errors
    ///
    /// Returns unavailable when tenant discovery or durable state cannot be advanced.
    pub async fn process_all_tenant_source_control(
        &self,
        per_tenant_limit: usize,
    ) -> Result<SourceControlBatch, ApplicationError> {
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut total = SourceControlBatch::default();
        for tenant in tenants {
            for _ in 0..per_tenant_limit.clamp(1, 100) {
                let Some(job) = self
                    .pipelines
                    .claim_next_source_control_job(
                        &tenant,
                        Uuid::new_v4(),
                        Utc::now(),
                        Utc::now() - chrono::Duration::minutes(5),
                    )
                    .await
                    .map_err(|_| ApplicationError::Unavailable)?
                else {
                    break;
                };
                total.claimed += 1;
                match self.process_source_control_job(&tenant, &job).await {
                    Ok(SourceControlJobOutcome::Processed) => total.processed += 1,
                    Ok(SourceControlJobOutcome::Ignored) => total.ignored += 1,
                    Ok(SourceControlJobOutcome::Failed) => total.failed += 1,
                    Err(error) => {
                        let discard = job.attempt >= 10;
                        self.pipelines
                            .retry_durable_job(
                                &tenant,
                                job.id,
                                job.claim_token,
                                Utc::now()
                                    + chrono::Duration::seconds(outbox_backoff_seconds(
                                        job.attempt,
                                        job.id,
                                    )),
                                &error.to_string(),
                                discard,
                                Utc::now(),
                            )
                            .await
                            .map_err(|_| ApplicationError::Unavailable)?;
                        if discard {
                            if let Some(delivery_id) = job
                                .payload
                                .get("delivery_id")
                                .and_then(serde_json::Value::as_str)
                            {
                                self.pipelines
                                    .finish_source_control_delivery(
                                        &tenant,
                                        delivery_id,
                                        "failed",
                                        Some("retry_exhausted"),
                                        Utc::now(),
                                    )
                                    .await
                                    .map_err(|_| ApplicationError::Unavailable)?;
                            }
                            total.failed += 1;
                        } else {
                            total.retried += 1;
                        }
                    }
                }
            }
        }
        Ok(total)
    }

    #[allow(clippy::too_many_lines)]
    async fn process_source_control_job(
        &self,
        tenant_id: &str,
        job: &robine_core::pipelines::DurableJobClaim,
    ) -> Result<SourceControlJobOutcome, ApplicationError> {
        let delivery_id = job
            .payload
            .get("delivery_id")
            .and_then(serde_json::Value::as_str)
            .ok_or(ApplicationError::Unavailable)?;
        let delivery = self
            .pipelines
            .get_source_control_delivery(tenant_id, delivery_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let event = match normalize(&delivery) {
            Ok(NormalizationOutcome::Ignored(reason)) => {
                self.finish_source_control_job(
                    tenant_id,
                    job,
                    delivery_id,
                    "ignored",
                    Some(reason),
                )
                .await?;
                return Ok(SourceControlJobOutcome::Ignored);
            }
            Err(reason) => {
                let failure = format!("{reason:?}");
                self.finish_source_control_job(
                    tenant_id,
                    job,
                    delivery_id,
                    "failed",
                    Some(&failure),
                )
                .await?;
                return Ok(SourceControlJobOutcome::Failed);
            }
            Ok(NormalizationOutcome::Event(event)) => event,
        };
        let repositories = self
            .source_repositories
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let provider = match delivery.provider.as_str() {
            "github" => Provider::GitHub,
            "gitlab" => Provider::GitLab,
            "forgejo" => Provider::Forgejo,
            _ => return Err(ApplicationError::Unavailable),
        };
        let Ok(repository) = repositories
            .find_trusted_by_provider(
                tenant_id,
                provider,
                &delivery.provider_instance,
                event.repository_provider_id,
            )
            .await
        else {
            self.finish_source_control_job(
                tenant_id,
                job,
                delivery_id,
                "ignored",
                Some("untrusted_repository"),
            )
            .await?;
            return Ok(SourceControlJobOutcome::Ignored);
        };
        let archive = self
            .source_fetcher
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .fetch_archive(&repository, &event.commit_sha)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let files = extract_tar_gz(&archive, ArchiveLimits::default())
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut sources = std::collections::BTreeMap::new();
        for file in files {
            let Some(path) = file.path.to_str() else {
                continue;
            };
            if robine_workflows::valid_workflow_path(path) {
                let source = String::from_utf8(file.contents)
                    .map_err(|_| ApplicationError::InvalidPipelineInput)?;
                sources.insert(path.to_owned(), source);
            }
        }
        let entry_paths: Vec<String> = sources.keys().cloned().collect();
        for path in entry_paths {
            let resolved = robine_workflows::resolve(&path, &sources, &self.workflow_limits)
                .map_err(ApplicationError::InvalidWorkflow)?;
            if !source_control_trigger_matches(&resolved.workflow.triggers, &event) {
                continue;
            }
            let source = sources
                .get(&path)
                .cloned()
                .ok_or(ApplicationError::Unavailable)?;
            let mut included_sources = sources.clone();
            included_sources.remove(&path);
            let trigger = match event.trigger {
                SourceControlTrigger::Push | SourceControlTrigger::Tag => "push",
                SourceControlTrigger::PullRequest => "pull_request",
            };
            let mut inputs = std::collections::BTreeMap::new();
            if event.trigger == SourceControlTrigger::Tag {
                inputs.insert("tag".into(), event.source_ref.clone());
            }
            let mut input = CreatePipelineInput {
                repository_id: repository.id,
                workflow_name: resolved.workflow.name,
                commit_sha: event.commit_sha.clone(),
                source_ref: Some(event.source_ref.clone()),
                trigger: trigger.into(),
                inputs,
                scheduled_for: None,
                idempotency_key: Some(format!("{}:{}:{path}", delivery.provider, delivery.id)),
                jobs: std::collections::BTreeMap::new(),
                workflow_revision: Some(robine_core::pipelines::CreateWorkflowRevisionInput {
                    path,
                    source,
                    sources: included_sources,
                }),
            };
            populate_jobs_from_workflow(&mut input, &self.workflow_limits)?;
            input
                .validate()
                .map_err(|_| ApplicationError::InvalidPipelineInput)?;
            let pipeline_id = input
                .idempotency_key
                .as_deref()
                .map(deterministic_uuid)
                .ok_or(ApplicationError::Unavailable)?;
            let pipeline =
                build_new_pipeline(input, pipeline_id, &event.actor, Uuid::new_v4(), Utc::now())?;
            self.pipelines
                .create(tenant_id, &pipeline)
                .await
                .map_err(|error| match error {
                    PortError::IdempotencyConflict => ApplicationError::IdempotencyConflict,
                    _ => ApplicationError::Unavailable,
                })?;
        }
        self.finish_source_control_job(tenant_id, job, delivery_id, "processed", None)
            .await?;
        Ok(SourceControlJobOutcome::Processed)
    }

    async fn finish_source_control_job(
        &self,
        tenant_id: &str,
        job: &robine_core::pipelines::DurableJobClaim,
        delivery_id: &str,
        status: &str,
        failure: Option<&str>,
    ) -> Result<(), ApplicationError> {
        self.pipelines
            .finish_source_control_delivery(tenant_id, delivery_id, status, failure, Utc::now())
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        self.pipelines
            .complete_durable_job(tenant_id, job.id, job.claim_token, Utc::now())
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    async fn process_dispatch_batch(
        &self,
        tenant_id: &str,
        limit: usize,
    ) -> Result<DispatchBatch, ApplicationError> {
        let now = Utc::now();
        let mut batch = DispatchBatch {
            reconciled: self
                .pipelines
                .reconcile_local_execution_jobs(tenant_id, 100, now)
                .await
                .map_err(|_| ApplicationError::Unavailable)?,
            ..DispatchBatch::default()
        };
        for _ in 0..limit.clamp(1, 100) {
            let claim_token = Uuid::new_v4();
            let Some(job) = self
                .pipelines
                .claim_next_dispatch_job(
                    tenant_id,
                    claim_token,
                    Utc::now(),
                    Utc::now() - chrono::Duration::minutes(5),
                )
                .await
                .map_err(|_| ApplicationError::Unavailable)?
            else {
                break;
            };
            batch.processed += 1;
            let claim = SchedulerClaim {
                global_limit: 4,
                repository_limit: 2,
                lease_seconds: 60,
                attempt_id: Uuid::new_v4(),
                idempotency_token: Uuid::new_v4(),
                event_id: Uuid::new_v4(),
                now: Utc::now(),
                runner_id: None,
            };
            match self
                .pipelines
                .consume_dispatch_job(tenant_id, job.id, job.claim_token, &claim)
                .await
            {
                Ok(Some(_)) => batch.attempts_created += 1,
                Ok(None) => batch.no_work += 1,
                Err(error) => {
                    let discard = job.attempt >= 10;
                    let available_at = Utc::now()
                        + chrono::Duration::seconds(outbox_backoff_seconds(job.attempt, job.id));
                    self.pipelines
                        .retry_durable_job(
                            tenant_id,
                            job.id,
                            job.claim_token,
                            available_at,
                            &error.to_string(),
                            discard,
                            Utc::now(),
                        )
                        .await
                        .map_err(|_| ApplicationError::Unavailable)?;
                    if discard {
                        batch.discarded += 1;
                    } else {
                        batch.retried += 1;
                    }
                }
            }
        }
        Ok(batch)
    }

    /// Consumes at most one durable local execution job per registered tenant.
    ///
    /// Execution effects occur outside database transactions. Ordered attempt events and the
    /// durable claim token make terminal completion recoverable after interruption.
    ///
    /// # Errors
    ///
    /// Returns unavailable when the executor is not configured or durable state cannot advance.
    pub async fn process_all_tenant_executions(&self) -> Result<ExecutionBatch, ApplicationError> {
        let runner = self
            .execution_runner
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?
            .clone();
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut batch = ExecutionBatch::default();
        for tenant_id in tenants {
            let tenant_batch = self
                .process_tenant_execution(&tenant_id, runner.as_ref())
                .await?;
            merge_execution_batch(&mut batch, &tenant_batch);
        }
        Ok(batch)
    }

    /// Applies bounded retention and reference-safe blob reconciliation for every tenant.
    ///
    /// # Errors
    ///
    /// Returns unavailable when metadata or the configured blob backend cannot complete a full
    /// reconciliation. No orphan is staged from an incomplete inventory.
    pub async fn process_all_tenant_retention(&self) -> Result<RetentionResult, ApplicationError> {
        let tenants = self
            .pipelines
            .list_tenants()
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        let mut total = RetentionResult::default();
        for tenant_id in tenants {
            let result = self.prune_tenant_retention(&tenant_id, Utc::now()).await?;
            merge_retention_result(&mut total, &result);
        }
        Ok(total)
    }

    async fn prune_tenant_retention(
        &self,
        tenant_id: &str,
        now: chrono::DateTime<Utc>,
    ) -> Result<RetentionResult, ApplicationError> {
        let repository = self
            .retention_repository
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        let blobs = self
            .blob_store
            .as_ref()
            .ok_or(ApplicationError::Unavailable)?;
        prune_retention(
            repository.as_ref(),
            blobs.as_ref(),
            self.retention,
            tenant_id,
            now,
        )
        .await
    }

    async fn process_tenant_execution(
        &self,
        tenant_id: &str,
        runner: &dyn ExecutionRunner,
    ) -> Result<ExecutionBatch, ApplicationError> {
        let now = Utc::now();
        let Some(job) = self
            .pipelines
            .claim_next_execution_job(
                tenant_id,
                Uuid::new_v4(),
                now,
                now - chrono::Duration::minutes(5),
            )
            .await
            .map_err(|_| ApplicationError::Unavailable)?
        else {
            return Ok(ExecutionBatch::default());
        };
        let work = self
            .pipelines
            .local_execution_work(tenant_id, job.source_event_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        if matches!(
            work.attempt.status.as_str(),
            "succeeded" | "failed" | "cancelled"
        ) {
            self.pipelines
                .complete_durable_job(tenant_id, job.id, job.claim_token, Utc::now())
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
            return Ok(ExecutionBatch {
                claimed: 1,
                recovered_terminal: 1,
                ..ExecutionBatch::default()
            });
        }
        let attempt = self.prepare_local_attempt(tenant_id, work.attempt).await?;
        let output = DurableOutputSink {
            pipelines: self.pipelines.clone(),
            tenant_id: tenant_id.into(),
            attempt_id: attempt.id,
        };
        let cancellation = DurableCancellationSignal {
            pipelines: self.pipelines.clone(),
            tenant_id: tenant_id.into(),
            idempotency_token: attempt.idempotency_token,
        };
        let result = if attempt.status == "cancelling" {
            Ok(ExecutionResult {
                status: ExecutionStatus::Cancelled,
                exit_code: None,
            })
        } else {
            self.run_local_specification(
                tenant_id,
                runner,
                work.specification,
                attempt.id,
                (
                    &output,
                    &cancellation,
                    u64::try_from(work.last_log_sequence)
                        .map_err(|_| ApplicationError::Unavailable)?,
                ),
            )
            .await
        };
        let (terminal_status, reason, succeeded) = execution_outcome(&result);
        self.pipelines
            .record_attempt_event(
                tenant_id,
                Uuid::new_v4(),
                &RecordAttemptEvent {
                    idempotency_token: attempt.idempotency_token,
                    sequence: attempt.last_sequence + 1,
                    status: terminal_status.into(),
                    reason: reason.map(str::to_owned),
                },
                Utc::now(),
            )
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        self.pipelines
            .complete_durable_job(tenant_id, job.id, job.claim_token, Utc::now())
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        Ok(ExecutionBatch {
            claimed: 1,
            succeeded: u64::from(succeeded),
            failed: u64::from(!succeeded),
            recovered_terminal: 0,
        })
    }

    async fn run_local_specification(
        &self,
        tenant_id: &str,
        runner: &dyn ExecutionRunner,
        raw: serde_json::Value,
        attempt_id: Uuid,
        control: (&dyn OutputSink, &dyn CancellationSignal, u64),
    ) -> Result<ExecutionResult, ExecutionError> {
        let builtin_handler = self.execution_builtin_handler(tenant_id, &raw, attempt_id)?;
        let specification = self
            .resolve_execution_specification(tenant_id, raw)
            .await
            .map_err(|_| ExecutionError::InvalidSpecification("persisted execution"))?;
        runner
            .run(
                &specification,
                ExecutionControl {
                    output: control.0,
                    cancellation: control.1,
                    builtins: builtin_handler
                        .as_ref()
                        .map(|handler| handler as &dyn BuiltinHandler),
                    last_sequence: control.2,
                },
            )
            .await
    }

    async fn prepare_local_attempt(
        &self,
        tenant_id: &str,
        mut attempt: AttemptProjection,
    ) -> Result<AttemptProjection, ApplicationError> {
        if attempt.status == "queued" {
            attempt = self
                .pipelines
                .record_attempt_event(
                    tenant_id,
                    Uuid::new_v4(),
                    &RecordAttemptEvent {
                        idempotency_token: attempt.idempotency_token,
                        sequence: attempt.last_sequence + 1,
                        status: "preparing".into(),
                        reason: None,
                    },
                    Utc::now(),
                )
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
        }
        if attempt.status == "preparing" {
            attempt = self
                .pipelines
                .record_attempt_event(
                    tenant_id,
                    Uuid::new_v4(),
                    &RecordAttemptEvent {
                        idempotency_token: attempt.idempotency_token,
                        sequence: attempt.last_sequence + 1,
                        status: "running".into(),
                        reason: None,
                    },
                    Utc::now(),
                )
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
        }
        Ok(attempt)
    }

    async fn resolve_execution_specification(
        &self,
        tenant_id: &str,
        raw: serde_json::Value,
    ) -> Result<ExecutionSpecification, serde_json::Error> {
        let repository_id = raw
            .get("repository_id")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok());
        let commit_sha = raw
            .get("commit_sha")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        let mut specification = serde_json::from_value::<ExecutionSpecification>(raw)?;
        self.resolve_source(
            tenant_id,
            repository_id,
            commit_sha.as_deref(),
            &mut specification,
        )
        .await?;
        resolve_cache_keys(&mut specification)?;
        resolve_builtin_templates(&mut specification)?;
        if specification.secret_names.is_empty() {
            return Ok(specification);
        }
        let Some(repository_id) = repository_id else {
            return Err(serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "secret repository identity is invalid",
            )));
        };
        let repository = self.secret_repository.as_ref().ok_or_else(|| {
            serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "secret repository is not configured",
            ))
        })?;
        let decryptor = self.secret_decryptor.as_ref().ok_or_else(|| {
            serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::NotConnected,
                "secret decryptor is not configured",
            ))
        })?;
        let encrypted = repository
            .find_authorized(tenant_id, repository_id, &specification.secret_names)
            .await
            .map_err(|_| serde_json::Error::io(std::io::Error::other("secret lookup failed")))?;
        let mut resolved = std::collections::BTreeMap::new();
        for secret in encrypted {
            let plaintext = decryptor.decrypt(&secret).map_err(|_| {
                serde_json::Error::io(std::io::Error::other("secret decryption failed"))
            })?;
            let plaintext = String::from_utf8(plaintext.to_vec()).map_err(|_| {
                serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "secret plaintext is not UTF-8",
                ))
            })?;
            if resolved
                .insert(secret.name, zeroize::Zeroizing::new(plaintext))
                .is_some()
            {
                return Err(serde_json::Error::io(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "duplicate authorized secret",
                )));
            }
        }
        if specification
            .secret_names
            .iter()
            .any(|name| !resolved.contains_key(name))
        {
            return Err(serde_json::Error::io(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "required secret is missing",
            )));
        }
        for service in &mut specification.services {
            for (environment_name, secret_name) in &service.secret_references {
                let value = resolved.get(secret_name).ok_or_else(|| {
                    serde_json::Error::io(std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "service secret is missing",
                    ))
                })?;
                service
                    .secrets
                    .insert(environment_name.clone(), value.clone());
            }
            service.secret_references.clear();
        }
        specification.secret_names.clear();
        specification.secrets = resolved;
        Ok(specification)
    }

    fn execution_builtin_handler(
        &self,
        tenant_id: &str,
        raw: &serde_json::Value,
        attempt_id: Uuid,
    ) -> Result<Option<ExecutionBuiltinHandler>, ExecutionError> {
        let has_storage_builtin = raw
            .get("steps")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|steps| {
                steps.iter().any(|step| {
                    step.get("kind").and_then(serde_json::Value::as_str) == Some("builtin")
                        && matches!(
                            step.get("value").and_then(serde_json::Value::as_str),
                            Some(
                                "cache/restore"
                                    | "cache/save"
                                    | "artifacts/upload"
                                    | "artifacts/download"
                            )
                        )
                })
            });
        if !has_storage_builtin {
            return Ok(None);
        }
        let parse_id = |name| {
            raw.get(name)
                .and_then(serde_json::Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ExecutionError::InvalidSpecification("builtin identity"))
        };
        let needs = raw
            .get("needs")
            .and_then(serde_json::Value::as_array)
            .ok_or(ExecutionError::InvalidSpecification("builtin dependencies"))?
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .map(str::to_owned)
                    .ok_or(ExecutionError::InvalidSpecification("builtin dependency"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(ExecutionBuiltinHandler {
            tenant_id: tenant_id.to_owned(),
            repository_id: parse_id("repository_id")?,
            pipeline_id: parse_id("pipeline_id")?,
            attempt_id,
            needs,
            repository: self
                .storage_repository
                .clone()
                .ok_or(ExecutionError::Unsupported("storage repository"))?,
            blobs: self
                .blob_store
                .clone()
                .ok_or(ExecutionError::Unsupported("blob store"))?,
            quotas: self.storage_quotas,
        }))
    }

    async fn resolve_source(
        &self,
        tenant_id: &str,
        repository_id: Option<Uuid>,
        commit_sha: Option<&str>,
        specification: &mut ExecutionSpecification,
    ) -> Result<(), serde_json::Error> {
        let checkout = specification.steps.iter().any(|step| {
            step.kind == robine_execution::StepKind::Builtin && step.value == "checkout"
        });
        if checkout {
            let repository_id = repository_id.ok_or_else(|| source_error("repository identity"))?;
            let commit_sha = commit_sha
                .filter(|sha| valid_commit_sha(sha))
                .ok_or_else(|| source_error("commit SHA"))?;
            let repositories = self
                .source_repositories
                .as_ref()
                .ok_or_else(|| source_error("source repository adapter"))?;
            let fetcher = self
                .source_fetcher
                .as_ref()
                .ok_or_else(|| source_error("source provider adapter"))?;
            let repository = repositories
                .find_trusted(tenant_id, repository_id)
                .await
                .map_err(|_| source_error("trusted repository"))?;
            let archive = fetcher
                .fetch_archive(&repository, commit_sha)
                .await
                .map_err(|_| source_error("provider archive"))?;
            specification.source_files = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                tokio::task::spawn_blocking(move || {
                    extract_tar_gz(&archive, ArchiveLimits::default())
                }),
            )
            .await
            .map_err(|_| source_error("archive timeout"))?
            .map_err(|_| source_error("archive task"))?
            .map_err(|_| source_error("archive validation"))?;
            specification.steps.retain(|step| {
                step.kind != robine_execution::StepKind::Builtin || step.value != "checkout"
            });
        }
        Ok(())
    }

    async fn authenticate_runner(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        now: chrono::DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        let key = self
            .runner_credential_key
            .ok_or(ApplicationError::Unauthenticated)?;
        if !credential.starts_with("rrc_") || credential.len() < 47 {
            let _ = self
                .audit_runner_authentication_failure(tenant_id, Some(runner_id), now)
                .await;
            return Err(ApplicationError::Unauthenticated);
        }
        let material = self
            .pipelines
            .runner_authentication_material(tenant_id, runner_id, now)
            .await;
        let (known_and_enabled, credential_digests) = match material {
            Ok(material) => (
                material.admin_state != "revoked",
                material.credential_digests,
            ),
            Err(PortError::NotFound) => {
                let mut dummy =
                    Hmac::<Sha256>::new_from_slice(&key).expect("fixed HMAC key is valid");
                dummy.update(b"invalid-runner-credential-sentinel");
                (false, vec![dummy.finalize().into_bytes().to_vec()])
            }
            Err(_) => return Err(ApplicationError::Unavailable),
        };
        let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("fixed HMAC key is valid");
        mac.update(credential.as_bytes());
        let actual = mac.finalize().into_bytes();
        let authenticated = credential_digests.iter().fold(false, |matched, digest| {
            let equal =
                digest.len() == actual.len() && actual.as_slice().ct_eq(digest.as_slice()).into();
            matched | equal
        });
        if !known_and_enabled || !authenticated {
            let _ = self
                .audit_runner_authentication_failure(tenant_id, Some(runner_id), now)
                .await;
            return Err(ApplicationError::Unauthenticated);
        }
        Ok(())
    }

    /// Appends a bounded, secret-free runner authentication anomaly audit event.
    ///
    /// # Errors
    ///
    /// Returns unavailable when the audit event cannot be persisted.
    pub async fn audit_runner_authentication_failure(
        &self,
        tenant_id: &str,
        claimed_runner_id: Option<Uuid>,
        now: chrono::DateTime<Utc>,
    ) -> Result<(), ApplicationError> {
        self.pipelines
            .audit_runner_authentication_failure(
                tenant_id,
                claimed_runner_id,
                Uuid::new_v4(),
                Uuid::new_v4(),
                now,
            )
            .await
            .map_err(|_| ApplicationError::Unavailable)
    }

    fn runner_secret_digest(&self, secret: &str) -> Result<Vec<u8>, ApplicationError> {
        let key = self
            .runner_credential_key
            .ok_or(ApplicationError::Unavailable)?;
        let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("fixed HMAC key is valid");
        mac.update(secret.as_bytes());
        Ok(mac.finalize().into_bytes().to_vec())
    }

    async fn authorized_remote_offer(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        credential: &str,
        attempt_id: Uuid,
    ) -> Result<serde_json::Value, ApplicationError> {
        self.authenticate_runner(tenant_id, runner_id, credential, Utc::now())
            .await?;
        self.pipelines
            .remote_job_offer(tenant_id, runner_id, attempt_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                _ => ApplicationError::Unavailable,
            })
    }
}

fn generated_runner_secret(prefix: &str) -> Result<String, ApplicationError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| ApplicationError::Unavailable)?;
    Ok(format!("{prefix}_{}", URL_SAFE_NO_PAD.encode(bytes)))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SourceControlJobOutcome {
    Processed,
    Ignored,
    Failed,
}

fn source_control_trigger_matches(
    triggers: &serde_json::Value,
    event: &robine_core::source_control::NormalizedSourceControlEvent,
) -> bool {
    let key = if event.trigger == SourceControlTrigger::PullRequest {
        "pull_request"
    } else {
        "push"
    };
    let Some(configuration) = triggers.get(key) else {
        return false;
    };
    let Some(object) = configuration.as_object() else {
        return true;
    };
    if object.is_empty() {
        return true;
    }
    let selector = if event.trigger == SourceControlTrigger::Tag {
        "tags"
    } else {
        "branches"
    };
    if event.trigger == SourceControlTrigger::Tag && object.contains_key("branches")
        || event.trigger != SourceControlTrigger::Tag && object.contains_key("tags")
    {
        return false;
    }
    object.get(selector).is_none_or(|patterns| {
        patterns.as_array().is_some_and(|patterns| {
            patterns.iter().any(|pattern| {
                pattern
                    .as_str()
                    .is_some_and(|pattern| wildcard_matches(pattern, &event.source_ref))
            })
        })
    })
}

fn wildcard_matches(pattern: &str, value: &str) -> bool {
    let mut remaining = value;
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == value;
    }
    for (index, part) in parts.iter().enumerate() {
        if part.is_empty() {
            continue;
        }
        if index == 0 && !pattern.starts_with('*') {
            let Some(next) = remaining.strip_prefix(part) else {
                return false;
            };
            remaining = next;
        } else if index == parts.len() - 1 && !pattern.ends_with('*') {
            return remaining.ends_with(part);
        } else if let Some(position) = remaining.find(part) {
            remaining = &remaining[position + part.len()..];
        } else {
            return false;
        }
    }
    pattern.ends_with('*') || remaining.is_empty()
}

fn remote_uuid(raw: &serde_json::Value, name: &str) -> Result<Uuid, ApplicationError> {
    raw.get(name)
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ApplicationError::Unavailable)
}

fn populate_jobs_from_workflow(
    input: &mut CreatePipelineInput,
    limits: &robine_workflows::WorkflowLimits,
) -> Result<(), ApplicationError> {
    if !input.jobs.is_empty() {
        return Ok(());
    }
    let Some(revision) = input.workflow_revision.as_ref() else {
        return Ok(());
    };
    let mut source_set = revision.sources.clone();
    source_set.insert(revision.path.clone(), revision.source.clone());
    let resolved = robine_workflows::resolve(&revision.path, &source_set, limits)
        .map_err(ApplicationError::InvalidWorkflow)?;
    let workflow = resolved.workflow;
    let normalized_inputs = workflow
        .normalized_inputs(&input.trigger, &input.inputs)
        .map_err(|diagnostic| {
            ApplicationError::InvalidWorkflow(vec![locate_application_diagnostic(
                diagnostic,
                &revision.path,
            )])
        })?;
    let jobs = workflow
        .pipeline_jobs(&input.trigger, &normalized_inputs)
        .map_err(|diagnostic| {
            ApplicationError::InvalidWorkflow(vec![locate_application_diagnostic(
                diagnostic,
                &revision.path,
            )])
        })?;
    input.workflow_name = workflow.name;
    input.inputs = normalized_inputs;
    if let Some(revision) = input.workflow_revision.as_mut() {
        revision.sources = resolved.included_sources;
    }
    input.jobs = jobs
        .into_iter()
        .map(|(key, job)| {
            (
                key,
                robine_core::pipelines::CreateJobInput {
                    needs: job.needs,
                    execution: job.execution,
                },
            )
        })
        .collect();
    Ok(())
}

fn locate_application_diagnostic(
    mut diagnostic: robine_workflows::Diagnostic,
    source_path: &str,
) -> robine_workflows::Diagnostic {
    if diagnostic.source_path.is_empty() {
        diagnostic.source_path = source_path.into();
    }
    diagnostic.line = diagnostic.line.max(1);
    diagnostic.column = diagnostic.column.max(1);
    diagnostic
}

fn source_error(subject: &'static str) -> serde_json::Error {
    serde_json::Error::io(std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        format!("invalid or unavailable {subject}"),
    ))
}

fn builtin_string<'a>(
    step: &'a robine_execution::ExecutionStep,
    name: &str,
) -> Result<&'a str, ExecutionError> {
    step.with
        .get(name)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ExecutionError::InvalidSpecification("builtin option"))
}

fn storage_execution_error(_error: robine_storage::StorageError) -> ExecutionError {
    ExecutionError::Runner {
        phase: "builtin_storage",
    }
}

fn resolve_cache_keys(specification: &mut ExecutionSpecification) -> Result<(), serde_json::Error> {
    for step in &mut specification.steps {
        if !matches!(step.value.as_str(), "cache/restore" | "cache/save") {
            continue;
        }
        let Some(template) = step.with.get("key").and_then(serde_json::Value::as_str) else {
            return Err(source_error("cache key"));
        };
        let mut resolved = template.to_owned();
        while let Some(start) = resolved.find("${{") {
            let tail = &resolved[start + 3..];
            let end = tail
                .find("}}")
                .ok_or_else(|| source_error("cache checksum"))?;
            let expression = tail[..end].trim();
            let relative = expression
                .strip_prefix("checksum('")
                .and_then(|value| value.strip_suffix("')"))
                .ok_or_else(|| source_error("cache checksum"))?;
            let path = std::path::Path::new(relative);
            if path.as_os_str().is_empty()
                || path
                    .components()
                    .any(|component| !matches!(component, std::path::Component::Normal(_)))
            {
                return Err(source_error("cache checksum path"));
            }
            let file = specification
                .source_files
                .iter()
                .find(|file| file.path == path)
                .ok_or_else(|| source_error("cache checksum file"))?;
            let digest = format!("{:x}", Sha256::digest(&file.contents));
            let expression_end = start + 3 + end + 2;
            resolved.replace_range(start..expression_end, &digest);
        }
        if resolved.is_empty() || resolved.len() > 512 {
            return Err(source_error("cache key"));
        }
        step.with.insert("key".into(), serde_json::json!(resolved));
    }
    Ok(())
}

fn resolve_builtin_templates(
    specification: &mut ExecutionSpecification,
) -> Result<(), serde_json::Error> {
    let architecture = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        _ => return Err(source_error("runner architecture")),
    };
    for step in &mut specification.steps {
        if step.value != "artifacts/upload" {
            continue;
        }
        let name = step
            .with
            .get("name")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| source_error("artifact name"))?
            .replace("${{ runner.os }}", "linux")
            .replace("${{ runner.arch }}", architecture);
        if name.contains("${{") {
            return Err(source_error("artifact name template"));
        }
        step.with.insert("name".into(), serde_json::json!(name));
    }
    Ok(())
}

fn count_outbox_delivery(batch: &mut OutboxBatch, delivery: &OutboxDelivery) {
    batch.processed += 1;
    batch.delivered += u64::from(delivery.delivered);
    batch.dispatch_enqueued += u64::from(delivery.dispatch_enqueued);
}

fn execution_outcome(
    result: &Result<ExecutionResult, robine_execution::ExecutionError>,
) -> (&'static str, Option<&'static str>, bool) {
    match result {
        Ok(ExecutionResult {
            status: ExecutionStatus::Succeeded,
            ..
        }) => ("succeeded", None, true),
        Ok(ExecutionResult {
            status: ExecutionStatus::Failed,
            ..
        }) => ("failed", Some("command_failed"), false),
        Ok(ExecutionResult {
            status: ExecutionStatus::TimedOut,
            ..
        }) => ("failed", Some("timeout"), false),
        Ok(ExecutionResult {
            status: ExecutionStatus::Cancelled,
            ..
        }) => ("cancelled", Some("cancelled"), false),
        Ok(ExecutionResult {
            status: ExecutionStatus::ServiceUnavailable,
            ..
        }) => ("failed", Some("service_unavailable"), false),
        Err(robine_execution::ExecutionError::ServiceUnavailable { .. }) => {
            ("failed", Some("service_unavailable"), false)
        }
        Err(_) => ("failed", Some("system_failure"), false),
    }
}

fn merge_execution_batch(total: &mut ExecutionBatch, batch: &ExecutionBatch) {
    total.claimed += batch.claimed;
    total.succeeded += batch.succeeded;
    total.failed += batch.failed;
    total.recovered_terminal += batch.recovered_terminal;
}

async fn prune_retention(
    repository: &dyn RetentionRepository,
    blobs: &dyn BlobStore,
    config: RetentionConfig,
    tenant_id: &str,
    now: chrono::DateTime<Utc>,
) -> Result<RetentionResult, ApplicationError> {
    let stage = repository
        .stage_expired(
            tenant_id,
            now,
            now - chrono::Duration::seconds(config.log_seconds),
            now + chrono::Duration::seconds(config.gc_grace_seconds),
            config.batch_size,
        )
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let blobs_deleted = drain_retention_gc(repository, blobs, config, tenant_id, now).await?;
    let mut result = reconcile_retention(repository, blobs, config, tenant_id, now).await?;
    result.artifacts_deleted = stage.artifacts_deleted;
    result.caches_deleted = stage.caches_deleted;
    result.logs_deleted = stage.logs_deleted;
    result.blobs_deleted = blobs_deleted;
    Ok(result)
}

async fn drain_retention_gc(
    repository: &dyn RetentionRepository,
    blobs: &dyn BlobStore,
    config: RetentionConfig,
    tenant_id: &str,
    now: chrono::DateTime<Utc>,
) -> Result<u64, ApplicationError> {
    let candidates = repository
        .eligible_gc(tenant_id, now, config.batch_size)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let mut deleted = 0_u64;
    for blob_id in candidates {
        let referenced = repository
            .blob_referenced(tenant_id, &blob_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
        if !referenced {
            blobs
                .delete(tenant_id, &blob_id)
                .await
                .map_err(|_| ApplicationError::Unavailable)?;
            deleted = deleted.saturating_add(1);
        }
        repository
            .acknowledge_gc(tenant_id, &blob_id)
            .await
            .map_err(|_| ApplicationError::Unavailable)?;
    }
    Ok(deleted)
}

async fn reconcile_retention(
    repository: &dyn RetentionRepository,
    blobs: &dyn BlobStore,
    config: RetentionConfig,
    tenant_id: &str,
    now: chrono::DateTime<Utc>,
) -> Result<RetentionResult, ApplicationError> {
    let inventory = blobs
        .inventory(tenant_id)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let referenced = repository
        .referenced_objects(tenant_id)
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let physical_ids = inventory
        .objects
        .iter()
        .map(|object| object.blob_id.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    let referenced_ids = referenced
        .iter()
        .map(|object| object.blob_id.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    let orphan_count = physical_ids.difference(&referenced_ids).count();
    let orphan_ids = physical_ids
        .difference(&referenced_ids)
        .take(usize::try_from(config.batch_size).unwrap_or(0))
        .map(|blob_id| (*blob_id).to_owned())
        .collect::<Vec<_>>();
    let orphans_staged = repository
        .stage_orphans(
            tenant_id,
            &orphan_ids,
            now + chrono::Duration::seconds(config.gc_grace_seconds),
            now,
        )
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    let temporary_deleted = blobs
        .delete_temporary_before(
            tenant_id,
            now - chrono::Duration::seconds(config.gc_grace_seconds),
        )
        .await
        .map_err(|_| ApplicationError::Unavailable)?;
    Ok(RetentionResult {
        logical_bytes: referenced
            .iter()
            .fold(0_i64, |total, object| total.saturating_add(object.size)),
        physical_bytes: inventory
            .objects
            .iter()
            .fold(0_i64, |total, object| total.saturating_add(object.size)),
        orphan_objects: u64::try_from(orphan_count).unwrap_or(u64::MAX),
        missing_objects: u64::try_from(referenced_ids.difference(&physical_ids).count())
            .unwrap_or(u64::MAX),
        unsafe_objects: inventory.unsafe_objects,
        temporary_deleted,
        orphans_staged,
        ..RetentionResult::default()
    })
}

fn merge_retention_result(total: &mut RetentionResult, result: &RetentionResult) {
    total.artifacts_deleted = total
        .artifacts_deleted
        .saturating_add(result.artifacts_deleted);
    total.caches_deleted = total.caches_deleted.saturating_add(result.caches_deleted);
    total.logs_deleted = total.logs_deleted.saturating_add(result.logs_deleted);
    total.blobs_deleted = total.blobs_deleted.saturating_add(result.blobs_deleted);
    total.logical_bytes = total.logical_bytes.saturating_add(result.logical_bytes);
    total.physical_bytes = total.physical_bytes.saturating_add(result.physical_bytes);
    total.orphan_objects = total.orphan_objects.saturating_add(result.orphan_objects);
    total.missing_objects = total.missing_objects.saturating_add(result.missing_objects);
    total.unsafe_objects = total.unsafe_objects.saturating_add(result.unsafe_objects);
    total.temporary_deleted = total
        .temporary_deleted
        .saturating_add(result.temporary_deleted);
    total.orphans_staged = total.orphans_staged.saturating_add(result.orphans_staged);
}

fn authentication_error(error: &PortError) -> ApplicationError {
    match error {
        PortError::NotFound | PortError::InvalidData => ApplicationError::Unauthenticated,
        PortError::AlreadyBootstrapped
        | PortError::LastAdministrator
        | PortError::OidcEmailCollision
        | PortError::InvalidTransition
        | PortError::RetryDependenciesUnavailable(_)
        | PortError::RetryInputsUnavailable(_)
        | PortError::IdempotencyConflict
        | PortError::Capacity
        | PortError::NoWork
        | PortError::EventGap { .. }
        | PortError::InvalidAttemptEvent
        | PortError::MessageIdConflict
        | PortError::AttemptNotAssigned
        | PortError::StaleEvent { .. }
        | PortError::Unavailable => ApplicationError::Unavailable,
    }
}

fn browser_projection_error(error: &PortError) -> ApplicationError {
    match error {
        PortError::NotFound => ApplicationError::PipelineNotFound,
        _ => ApplicationError::Unavailable,
    }
}

fn valid_secret_name(name: &str) -> bool {
    let mut characters = name.bytes();
    let Some(first) = characters.next() else {
        return false;
    };
    name.len() <= 128
        && (first.is_ascii_uppercase() || first == b'_')
        && characters.all(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || character == b'_'
        })
}

fn deterministic_uuid(key: &str) -> Uuid {
    let digest = Sha256::digest(key.as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    Uuid::from_bytes(bytes)
}

fn build_new_pipeline(
    input: CreatePipelineInput,
    id: Uuid,
    actor: &str,
    correlation_id: Uuid,
    now: chrono::DateTime<Utc>,
) -> Result<NewPipeline, ApplicationError> {
    let mut graph_jobs = serde_json::Map::new();
    let mut jobs = Vec::with_capacity(input.jobs.len());
    for (position, (key, definition)) in input.jobs.iter().enumerate() {
        let mut execution = definition
            .execution
            .as_object()
            .cloned()
            .unwrap_or_default();
        execution
            .entry("base_id")
            .or_insert_with(|| serde_json::Value::String(key.clone()));
        let mut graph_job = execution.clone();
        graph_job.insert("needs".into(), serde_json::json!(definition.needs));
        graph_jobs.insert(key.clone(), serde_json::Value::Object(graph_job));
        jobs.push(NewJob {
            id: Uuid::new_v4(),
            key: key.clone(),
            status: if definition.needs.is_empty() {
                JobState::Queued
            } else {
                JobState::Blocked
            },
            needs: definition.needs.clone(),
            position: i32::try_from(position)
                .map_err(|_| ApplicationError::InvalidPipelineInput)?,
            execution: serde_json::Value::Object(execution),
        });
    }
    let normalized_graph = serde_json::json!({"jobs": graph_jobs});
    let revision_input = input.workflow_revision.unwrap_or_else(|| {
        let source = serde_json::to_string(&normalized_graph).unwrap_or_else(|_| "{}".into());
        robine_core::pipelines::CreateWorkflowRevisionInput {
            path: format!("generated://pipeline/{id}"),
            source,
            sources: std::collections::BTreeMap::new(),
        }
    });
    let included_sources = serde_json::Value::Object(
        revision_input
            .sources
            .iter()
            .map(|(path, source)| {
                (
                    path.clone(),
                    serde_json::json!({"source": source, "digest": source_digest(source)}),
                )
            })
            .collect(),
    );
    Ok(NewPipeline {
        id,
        repository_id: input.repository_id,
        workflow_name: input.workflow_name,
        commit_sha: input.commit_sha,
        source_ref: input.source_ref,
        trigger: input.trigger,
        actor: actor.into(),
        correlation_id,
        inserted_at: now,
        scheduled_for: input.scheduled_for,
        inputs: input.inputs,
        revision: NewWorkflowRevision {
            id: Uuid::new_v4(),
            path: revision_input.path,
            digest: source_digest(&revision_input.source),
            source: revision_input.source,
            normalized_graph,
            included_sources,
        },
        jobs,
        event_id: Uuid::new_v4(),
    })
}

fn valid_email(email: &str) -> bool {
    let Some((local, domain)) = email.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && !domain.contains('@')
        && !email.chars().any(char::is_whitespace)
}

#[cfg(test)]
mod tests {
    use super::*;
    use robine_execution::{ExecutionStep, SourceFile, StepCondition, StepKind};
    use robine_storage::{
        BlobInventory, InventoryObject, RetentionStage, StorageError, StoredObject,
    };
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::{collections::BTreeMap, path::PathBuf};

    struct IncompleteBlobStore;

    #[test]
    fn source_control_trigger_filters_match_branches_tags_and_pull_requests() {
        let event =
            |trigger, source_ref: &str| robine_core::source_control::NormalizedSourceControlEvent {
                trigger,
                repository_provider_id: 1,
                commit_sha: "a".repeat(40),
                source_ref: source_ref.into(),
                actor: "github:octo".into(),
            };
        let triggers = serde_json::json!({
            "push": {"branches": ["main", "release/*"]},
            "pull_request": {}
        });
        assert!(source_control_trigger_matches(
            &triggers,
            &event(SourceControlTrigger::Push, "release/1.0")
        ));
        assert!(!source_control_trigger_matches(
            &triggers,
            &event(SourceControlTrigger::Push, "feature/test")
        ));
        assert!(source_control_trigger_matches(
            &triggers,
            &event(SourceControlTrigger::PullRequest, "main")
        ));
        assert!(!source_control_trigger_matches(
            &triggers,
            &event(SourceControlTrigger::Tag, "v1")
        ));
    }

    #[test]
    fn workflow_revision_populates_the_durable_pipeline_graph() {
        let mut input: CreatePipelineInput = serde_json::from_value(serde_json::json!({
            "repository_id": Uuid::nil(),
            "commit_sha": "a".repeat(40),
            "trigger": "push",
            "workflow_revision": {
                "path": ".robine-ci/workflows/ci.yml",
                "source": "version: 1\nname: CI\non: {push: {}}\njobs:\n  test:\n    image: alpine:3.22\n    steps:\n      - run: echo ok\n"
            }
        }))
        .expect("source-backed pipeline input");

        populate_jobs_from_workflow(&mut input, &robine_workflows::WorkflowLimits::default())
            .expect("valid workflow revision");

        assert_eq!(input.workflow_name, "CI");
        assert_eq!(input.jobs.len(), 1);
        assert_eq!(input.jobs["test"].execution["image"], "alpine:3.22");
        assert!(input.validate().is_ok());
    }

    #[test]
    fn workflow_revision_rejects_noncanonical_paths_and_undeclared_triggers() {
        let source = "version: 1\nname: CI\non: {push: {}}\njobs:\n  test:\n    image: alpine:3.22\n    steps: [{run: echo ok}]\n";
        let mut input: CreatePipelineInput = serde_json::from_value(serde_json::json!({
            "repository_id": Uuid::nil(),
            "commit_sha": "a".repeat(40),
            "trigger": "push",
            "workflow_revision": {"path": "ci.yml", "source": source}
        }))
        .expect("pipeline input");
        assert!(matches!(
            populate_jobs_from_workflow(&mut input, &robine_workflows::WorkflowLimits::default()),
            Err(ApplicationError::InvalidWorkflow(_))
        ));

        input.workflow_revision.as_mut().expect("revision").path =
            ".robine-ci/workflows/ci.yml".into();
        input.trigger = "pull_request".into();
        assert!(matches!(
            populate_jobs_from_workflow(&mut input, &robine_workflows::WorkflowLimits::default()),
            Err(ApplicationError::InvalidWorkflow(_))
        ));
    }

    #[test]
    fn workflow_revision_composes_only_reachable_exact_sources() {
        let reusable_path = ".robine-ci/workflows/quality.yml";
        let mut input: CreatePipelineInput = serde_json::from_value(serde_json::json!({
            "repository_id": Uuid::nil(),
            "commit_sha": "a".repeat(40),
            "trigger": "push",
            "workflow_revision": {
                "path": ".robine-ci/workflows/ci.yml",
                "source": format!("version: 1\nname: CI\non: {{push: {{}}}}\nincludes:\n  quality:\n    path: {reusable_path}\n    inputs:\n      runtime: '3.22'\njobs:\n  package:\n    image: alpine:3.22\n    needs: quality--test\n    steps: [{{run: echo package}}]\n"),
                "sources": {
                    (reusable_path): "version: 1\nname: Quality\non:\n  workflow_call:\n    inputs:\n      runtime:\n        type: choice\n        required: true\n        options: ['3.21', '3.22']\njobs:\n  test:\n    image: alpine:3.22\n    steps: [{run: echo test}]\n",
                    ".robine-ci/workflows/unreachable.yml": "not: decoded"
                }
            }
        }))
        .expect("multi-source pipeline input");

        populate_jobs_from_workflow(&mut input, &robine_workflows::WorkflowLimits::default())
            .expect("valid reusable workflow");

        assert_eq!(input.jobs["package"].needs, ["quality--test"]);
        assert_eq!(
            input.jobs["quality--test"].execution["env"]["ROBINE_CALL_INPUT_RUNTIME"],
            "3.22"
        );
        let sources = &input.workflow_revision.expect("revision").sources;
        assert_eq!(
            sources.keys().map(String::as_str).collect::<Vec<_>>(),
            [reusable_path]
        );
    }

    #[async_trait::async_trait]
    impl BlobStore for IncompleteBlobStore {
        async fn put(
            &self,
            _tenant_id: &str,
            _content: Vec<u8>,
        ) -> Result<StoredObject, StorageError> {
            Err(StorageError::Unavailable)
        }

        async fn get(
            &self,
            _tenant_id: &str,
            _object: &StoredObject,
        ) -> Result<Vec<u8>, StorageError> {
            Err(StorageError::Unavailable)
        }

        async fn delete(&self, _tenant_id: &str, _blob_id: &str) -> Result<(), StorageError> {
            Err(StorageError::Unavailable)
        }

        async fn inventory(&self, _tenant_id: &str) -> Result<BlobInventory, StorageError> {
            Err(StorageError::Unavailable)
        }

        async fn delete_temporary_before(
            &self,
            _tenant_id: &str,
            _cutoff: chrono::DateTime<Utc>,
        ) -> Result<u64, StorageError> {
            panic!("temporary cleanup must not run after incomplete inventory")
        }
    }

    #[derive(Default)]
    struct RecordingRetention {
        staged: AtomicBool,
    }

    #[async_trait::async_trait]
    impl RetentionRepository for RecordingRetention {
        async fn stage_expired(
            &self,
            _tenant_id: &str,
            _now: chrono::DateTime<Utc>,
            _log_cutoff: chrono::DateTime<Utc>,
            _not_before: chrono::DateTime<Utc>,
            _batch_size: i64,
        ) -> Result<RetentionStage, StorageError> {
            Ok(RetentionStage::default())
        }

        async fn eligible_gc(
            &self,
            _tenant_id: &str,
            _now: chrono::DateTime<Utc>,
            _batch_size: i64,
        ) -> Result<Vec<String>, StorageError> {
            Ok(Vec::new())
        }

        async fn blob_referenced(
            &self,
            _tenant_id: &str,
            _blob_id: &str,
        ) -> Result<bool, StorageError> {
            Ok(false)
        }

        async fn acknowledge_gc(
            &self,
            _tenant_id: &str,
            _blob_id: &str,
        ) -> Result<(), StorageError> {
            Ok(())
        }

        async fn referenced_objects(
            &self,
            _tenant_id: &str,
        ) -> Result<Vec<InventoryObject>, StorageError> {
            Ok(Vec::new())
        }

        async fn stage_orphans(
            &self,
            _tenant_id: &str,
            _blob_ids: &[String],
            _not_before: chrono::DateTime<Utc>,
            _now: chrono::DateTime<Utc>,
        ) -> Result<u64, StorageError> {
            self.staged.store(true, Ordering::SeqCst);
            Ok(0)
        }
    }

    #[test]
    fn cache_checksum_and_runner_artifact_templates_resolve_without_expression_evaluation() {
        let mut specification = ExecutionSpecification {
            attempt_id: Uuid::new_v4(),
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 1_000,
            env: BTreeMap::new(),
            build_env: BTreeMap::new(),
            secret_names: Vec::new(),
            secrets: BTreeMap::new(),
            source_files: vec![SourceFile {
                path: PathBuf::from("mix.lock"),
                contents: b"lock".to_vec(),
            }],
            services: Vec::new(),
            steps: vec![
                ExecutionStep {
                    name: "cache".into(),
                    kind: StepKind::Builtin,
                    value: "cache/save".into(),
                    condition: StepCondition::Success,
                    with: BTreeMap::from([
                        (
                            "key".into(),
                            serde_json::json!("mix-${{ checksum('mix.lock') }}"),
                        ),
                        ("paths".into(), serde_json::json!(["deps"])),
                    ]),
                },
                ExecutionStep {
                    name: "artifact".into(),
                    kind: StepKind::Builtin,
                    value: "artifacts/upload".into(),
                    condition: StepCondition::Success,
                    with: BTreeMap::from([
                        (
                            "name".into(),
                            serde_json::json!("release-${{ runner.os }}-${{ runner.arch }}"),
                        ),
                        ("paths".into(), serde_json::json!(["release"])),
                    ]),
                },
            ],
        };
        resolve_cache_keys(&mut specification).unwrap();
        resolve_builtin_templates(&mut specification).unwrap();
        let digest = format!("{:x}", Sha256::digest(b"lock"));
        assert_eq!(specification.steps[0].with["key"], format!("mix-{digest}"));
        assert!(
            specification.steps[1].with["name"]
                .as_str()
                .unwrap()
                .starts_with("release-linux-")
        );
    }

    #[test]
    fn preparation_service_failures_keep_the_service_unavailable_terminal_reason() {
        let result = Err(robine_execution::ExecutionError::ServiceUnavailable {
            service_id: "database".into(),
            phase: robine_execution::ServiceFailurePhase::Readiness,
            diagnostic: b"bounded diagnostic".to_vec(),
        });
        assert_eq!(
            execution_outcome(&result),
            ("failed", Some("service_unavailable"), false)
        );
    }

    #[tokio::test]
    async fn incomplete_inventory_never_stages_reconciliation_garbage() {
        let repository = RecordingRetention::default();
        let result = prune_retention(
            &repository,
            &IncompleteBlobStore,
            RetentionConfig {
                log_seconds: 60,
                gc_grace_seconds: 0,
                batch_size: 100,
            },
            "tenant",
            Utc::now(),
        )
        .await;
        assert!(matches!(result, Err(ApplicationError::Unavailable)));
        assert!(!repository.staged.load(Ordering::SeqCst));
    }
}
