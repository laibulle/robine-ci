use async_trait::async_trait;
use chrono::{DateTime, Utc};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    identity::{LocalIdentity, OidcAuthorization, OidcClaims, Role, User},
    pipelines::{
        AttemptProjection, NewPipeline, OutboxDelivery, PipelineProjection, RecordAttemptEvent,
        RecordRemoteAttemptEvent, RetryProjection, RunnerAuthenticationMaterial,
        RunnerLeaseHeartbeat, RunnerResume, SchedulerClaim,
    },
};

#[derive(Debug, Error)]
pub enum PortError {
    #[error("record was not found")]
    NotFound,
    #[error("the instance has already been bootstrapped")]
    AlreadyBootstrapped,
    #[error("the last usable administrator cannot be demoted")]
    LastAdministrator,
    #[error("an existing email belongs to a different identity")]
    OidcEmailCollision,
    #[error("stored data violates a domain contract")]
    InvalidData,
    #[error("the requested state transition is not allowed")]
    InvalidTransition,
    #[error("job dependencies are not available: {0:?}")]
    RetryDependenciesUnavailable(Vec<String>),
    #[error("retained artifact inputs are not available: {0:?}")]
    RetryInputsUnavailable(Vec<String>),
    #[error("an idempotent creation key was reused with different input")]
    IdempotencyConflict,
    #[error("scheduler capacity is exhausted")]
    Capacity,
    #[error("no eligible work is queued")]
    NoWork,
    #[error("attempt event sequence gap: expected {expected}, got {actual}")]
    EventGap { expected: i32, actual: i32 },
    #[error("attempt event is invalid")]
    InvalidAttemptEvent,
    #[error("runner message id conflicts with a different event")]
    MessageIdConflict,
    #[error("attempt is not assigned to the authenticated runner")]
    AttemptNotAssigned,
    #[error("runner event sequence is stale: last {last}, got {actual}")]
    StaleEvent { last: i32, actual: i32 },
    #[error("persistence operation failed")]
    Unavailable,
}

#[async_trait]
pub trait IdentityRepository: Send + Sync {
    async fn bootstrap_administrator(
        &self,
        user_id: Uuid,
        credential_id: Uuid,
        email: &str,
        password_hash: &str,
        inserted_at: DateTime<Utc>,
    ) -> Result<User, PortError>;

    async fn get_local_identity(&self, email: &str) -> Result<LocalIdentity, PortError>;

    async fn resolve_session(
        &self,
        token_digest: &[u8],
        now: DateTime<Utc>,
    ) -> Result<User, PortError>;

    async fn create_session(
        &self,
        id: Uuid,
        user_id: Uuid,
        token_digest: &[u8],
        expires_at: DateTime<Utc>,
        inserted_at: DateTime<Utc>,
    ) -> Result<(), PortError>;

    async fn revoke_session(
        &self,
        token_digest: &[u8],
        revoked_at: DateTime<Utc>,
    ) -> Result<(), PortError>;

    async fn list_users(&self) -> Result<Vec<User>, PortError>;

    async fn change_user_role(&self, user_id: Uuid, role: Role) -> Result<User, PortError>;

    async fn find_or_provision_oidc_user(
        &self,
        claims: &OidcClaims,
        user_id: Uuid,
        inserted_at: DateTime<Utc>,
    ) -> Result<User, PortError>;
}

#[async_trait]
pub trait OidcProvider: Send + Sync {
    async fn start(&self) -> Result<OidcAuthorization, PortError>;
    async fn complete(&self, code: &str, state: &str) -> Result<OidcClaims, PortError>;
}

#[async_trait]
pub trait PipelineRepository: Send + Sync {
    async fn list_tenants(&self) -> Result<Vec<String>, PortError>;

    async fn create(
        &self,
        tenant_id: &str,
        pipeline: &NewPipeline,
    ) -> Result<PipelineProjection, PortError>;

    async fn list_recent(
        &self,
        tenant_id: &str,
        repository_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<PipelineProjection>, PortError>;

    async fn queue(
        &self,
        tenant_id: &str,
        pipeline_id: Uuid,
    ) -> Result<PipelineProjection, PortError>;

    async fn cancel(
        &self,
        tenant_id: &str,
        pipeline_id: Uuid,
        event_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<PipelineProjection, PortError>;

    async fn retry_job(
        &self,
        tenant_id: &str,
        job_id: Uuid,
        event_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<RetryProjection, PortError>;

    async fn claim_next_job(
        &self,
        tenant_id: &str,
        claim: &SchedulerClaim,
    ) -> Result<AttemptProjection, PortError>;

    async fn record_attempt_event(
        &self,
        tenant_id: &str,
        event_id: Uuid,
        event: &RecordAttemptEvent,
        now: DateTime<Utc>,
    ) -> Result<AttemptProjection, PortError>;

    async fn heartbeat_attempt(
        &self,
        tenant_id: &str,
        idempotency_token: Uuid,
        lease_seconds: i64,
        now: DateTime<Utc>,
    ) -> Result<AttemptProjection, PortError>;

    async fn reconcile_expired_attempts(
        &self,
        tenant_id: &str,
        limit: i64,
        now: DateTime<Utc>,
    ) -> Result<u64, PortError>;

    async fn runner_authentication_material(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<RunnerAuthenticationMaterial, PortError>;

    async fn heartbeat_runner_attempts(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        lease_seconds: i64,
        now: DateTime<Utc>,
    ) -> Result<RunnerLeaseHeartbeat, PortError>;

    async fn reconcile_runner_attempts(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<Vec<RunnerResume>, PortError>;

    async fn record_remote_attempt_event(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        receipt_id: Uuid,
        outbox_event_id: Uuid,
        event: &RecordRemoteAttemptEvent,
        now: DateTime<Utc>,
    ) -> Result<AttemptProjection, PortError>;

    async fn remote_job_offer(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        attempt_id: Uuid,
    ) -> Result<serde_json::Value, PortError>;

    async fn process_next_outbox_event(
        &self,
        tenant_id: &str,
        now: DateTime<Utc>,
    ) -> Result<Option<OutboxDelivery>, PortError>;
}
