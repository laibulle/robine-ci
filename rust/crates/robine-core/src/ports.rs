use async_trait::async_trait;
use chrono::{DateTime, Utc};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    identity::{LocalIdentity, User},
    pipelines::PipelineProjection,
};

#[derive(Debug, Error)]
pub enum PortError {
    #[error("record was not found")]
    NotFound,
    #[error("the instance has already been bootstrapped")]
    AlreadyBootstrapped,
    #[error("stored data violates a domain contract")]
    InvalidData,
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
}

#[async_trait]
pub trait PipelineRepository: Send + Sync {
    async fn list_recent(
        &self,
        tenant_id: &str,
        repository_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<PipelineProjection>, PortError>;
}
