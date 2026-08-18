//! Framework-independent orchestration for Robine use cases.

use std::sync::Arc;

use chrono::Utc;
use robine_core::{
    execution_context::{Actor, ActorKind, Capability, ExecutionContext},
    identity::User,
    pipelines::PipelineProjection,
    ports::{IdentityRepository, PipelineRepository, PortError},
};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

pub struct ControlPlane {
    identities: Arc<dyn IdentityRepository>,
    pipelines: Arc<dyn PipelineRepository>,
}

#[derive(Debug, Error)]
pub enum ApplicationError {
    #[error("authentication is required")]
    Unauthenticated,
    #[error("operation is forbidden")]
    Forbidden,
    #[error("application dependency is unavailable")]
    Unavailable,
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
        }
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
}

fn authentication_error(error: &PortError) -> ApplicationError {
    match error {
        PortError::NotFound | PortError::InvalidData => ApplicationError::Unauthenticated,
        PortError::Unavailable => ApplicationError::Unavailable,
    }
}
