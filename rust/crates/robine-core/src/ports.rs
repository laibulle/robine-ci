use async_trait::async_trait;
use chrono::{DateTime, Utc};
use thiserror::Error;
use uuid::Uuid;

use crate::{identity::User, pipelines::PipelineProjection};

#[derive(Debug, Error)]
pub enum PortError {
    #[error("record was not found")]
    NotFound,
    #[error("stored data violates a domain contract")]
    InvalidData,
    #[error("persistence operation failed")]
    Unavailable,
}

#[async_trait]
pub trait IdentityRepository: Send + Sync {
    async fn resolve_session(
        &self,
        token_digest: &[u8],
        now: DateTime<Utc>,
    ) -> Result<User, PortError>;
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
