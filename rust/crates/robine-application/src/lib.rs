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
use chrono::Utc;
use hmac::{Hmac, Mac};
use robine_core::{
    execution_context::{Actor, ActorKind, Capability, ExecutionContext},
    identity::{OidcAuthorization, Role, User},
    pipelines::{
        AttemptProjection, CreatePipelineInput, ExecutionLogChunk, JobState, NewJob, NewPipeline,
        NewWorkflowRevision, OutboxDelivery, PipelineProjection, RecordAttemptEvent,
        RecordRemoteAttemptEvent, RetryProjection, RunnerLeaseHeartbeat, RunnerReconciliation,
        SchedulerClaim, outbox_backoff_seconds, source_digest,
    },
    ports::{IdentityRepository, OidcProvider, PipelineRepository, PortError},
};
use robine_execution::{
    BuiltinHandler, BuiltinRestore, CancellationSignal, ExecutionControl, ExecutionError,
    ExecutionResult, ExecutionRunner, ExecutionSpecification, ExecutionStatus, OutputChannel,
    OutputChunk, OutputSink,
};
use robine_secrets::{SecretDecryptor, SecretRepository};
use robine_source::{
    ArchiveFetcher, ArchiveLimits, RepositoryStore, extract_tar_gz, valid_commit_sha,
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
    source_repositories: Option<Arc<dyn RepositoryStore>>,
    source_fetcher: Option<Arc<dyn ArchiveFetcher>>,
    storage_repository: Option<Arc<dyn MetadataRepository>>,
    retention_repository: Option<Arc<dyn RetentionRepository>>,
    blob_store: Option<Arc<dyn BlobStore>>,
    storage_quotas: StorageQuotas,
    retention: RetentionConfig,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetentionConfig {
    pub log_seconds: i64,
    pub gc_grace_seconds: i64,
    pub batch_size: i64,
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
            source_repositories: None,
            source_fetcher: None,
            storage_repository: None,
            retention_repository: None,
            blob_store: None,
            storage_quotas: StorageQuotas {
                instance_bytes: 53_687_091_200,
                repository_bytes: 10_737_418_240,
            },
            retention: RetentionConfig::default(),
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
        decryptor: Arc<dyn SecretDecryptor>,
    ) -> Self {
        self.secret_repository = Some(repository);
        self.secret_decryptor = Some(decryptor);
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

    /// Validates and atomically persists a pipeline, immutable revision, job graph, and event.
    ///
    /// # Errors
    ///
    /// Returns forbidden for viewers, invalid input for malformed metadata/graphs/revisions,
    /// conflict when an idempotency key is reused differently, or unavailable on storage failure.
    pub async fn create_pipeline(
        &self,
        user: &User,
        mut input: CreatePipelineInput,
    ) -> Result<PipelineProjection, ApplicationError> {
        if user.role == Role::Viewer {
            return Err(ApplicationError::Forbidden);
        }
        populate_jobs_from_workflow(&mut input)?;
        input
            .validate()
            .map_err(|_| ApplicationError::InvalidPipelineInput)?;
        let context = ExecutionContext::embedded(
            Actor {
                id: user.id.to_string(),
                kind: ActorKind::User,
            },
            "standalone",
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
        let pipeline = build_new_pipeline(input, pipeline_id, user, context.correlation_id, now)?;
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
        self.pipelines
            .remote_job_offer(tenant_id, runner_id, attempt_id)
            .await
            .map_err(|error| match error {
                PortError::NotFound => ApplicationError::PipelineNotFound,
                PortError::AttemptNotAssigned => ApplicationError::Forbidden,
                _ => ApplicationError::Unavailable,
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
            return Err(ApplicationError::Unauthenticated);
        }
        Ok(())
    }
}

fn populate_jobs_from_workflow(input: &mut CreatePipelineInput) -> Result<(), ApplicationError> {
    if !input.jobs.is_empty() {
        return Ok(());
    }
    let Some(revision) = input.workflow_revision.as_ref() else {
        return Ok(());
    };
    if !robine_workflows::valid_workflow_path(&revision.path) {
        return Err(ApplicationError::InvalidPipelineInput);
    }
    let workflow = robine_workflows::parse(
        &revision.source,
        &revision.path,
        &robine_workflows::WorkflowLimits::default(),
    )
    .map_err(|_| ApplicationError::InvalidPipelineInput)?;
    let jobs = workflow
        .pipeline_jobs(&input.trigger, &input.inputs)
        .map_err(|_| ApplicationError::InvalidPipelineInput)?;
    input.workflow_name = workflow.name;
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

fn deterministic_uuid(key: &str) -> Uuid {
    let digest = Sha256::digest(key.as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    Uuid::from_bytes(bytes)
}

fn build_new_pipeline(
    input: CreatePipelineInput,
    id: Uuid,
    user: &User,
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
        actor: user.id.to_string(),
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

        populate_jobs_from_workflow(&mut input).expect("valid workflow revision");

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
            populate_jobs_from_workflow(&mut input),
            Err(ApplicationError::InvalidPipelineInput)
        ));

        input.workflow_revision.as_mut().expect("revision").path =
            ".robine-ci/workflows/ci.yml".into();
        input.trigger = "pull_request".into();
        assert!(matches!(
            populate_jobs_from_workflow(&mut input),
            Err(ApplicationError::InvalidPipelineInput)
        ));
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
