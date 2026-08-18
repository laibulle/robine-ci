//! `PostgreSQL` adapters for the existing Robine schema.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use robine_core::{
    identity::{Role, User},
    pipelines::{PipelineProjection, PipelineState, UnknownPipelineState},
    ports::{IdentityRepository, PipelineRepository, PortError},
};
use sqlx::{PgPool, Postgres, Transaction, postgres::PgPoolOptions};
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone)]
pub struct Database {
    pool: PgPool,
}

#[derive(Debug, Error)]
pub enum PersistenceError {
    #[error("database operation failed")]
    Database(#[source] sqlx::Error),
    #[error(transparent)]
    UnknownPipelineState(#[from] UnknownPipelineState),
}

impl From<sqlx::Error> for PersistenceError {
    fn from(error: sqlx::Error) -> Self {
        Self::Database(error)
    }
}

#[async_trait]
pub trait Readiness: Send + Sync {
    async fn ready(&self) -> Result<(), PersistenceError>;
}

impl Database {
    /// Connects to an existing Robine `PostgreSQL` database.
    ///
    /// # Errors
    ///
    /// Returns [`PersistenceError`] when the pool cannot connect.
    pub async fn connect(url: &str, max_connections: u32) -> Result<Self, PersistenceError> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .connect(url)
            .await?;
        Ok(Self { pool })
    }

    #[must_use]
    pub fn from_pool(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Opens a transaction with `PostgreSQL` row-level security scoped to one tenant.
    ///
    /// # Errors
    ///
    /// Returns [`PersistenceError`] when the transaction or tenant setting fails.
    pub async fn tenant_transaction(
        &self,
        tenant_id: &str,
    ) -> Result<Transaction<'_, Postgres>, PersistenceError> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SELECT set_config('robine.tenant_id', $1, true)")
            .bind(tenant_id)
            .execute(&mut *transaction)
            .await?;
        Ok(transaction)
    }

    /// Lists pipelines visible to the supplied tenant, newest first.
    ///
    /// # Errors
    ///
    /// Returns [`PersistenceError`] for database failures or an unknown persisted status.
    pub async fn list_pipelines(
        &self,
        tenant_id: &str,
        limit: i64,
    ) -> Result<Vec<PipelineProjection>, PersistenceError> {
        self.list_pipeline_projection(tenant_id, None, limit).await
    }

    async fn list_pipeline_projection(
        &self,
        tenant_id: &str,
        repository_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<PipelineProjection>, PersistenceError> {
        let mut transaction = self.tenant_transaction(tenant_id).await?;
        let records = sqlx::query_as::<_, PipelineRecordRow>(
            "SELECT id, repository_id, workflow_name, commit_sha, status, inserted_at \
             FROM pipelines \
             WHERE ($2::uuid IS NULL OR repository_id = $2) \
             ORDER BY inserted_at DESC, id DESC LIMIT $1",
        )
        .bind(limit.clamp(1, 100))
        .bind(repository_id)
        .fetch_all(&mut *transaction)
        .await?;
        transaction.commit().await?;

        records.into_iter().map(TryInto::try_into).collect()
    }
}

#[async_trait]
impl Readiness for Database {
    async fn ready(&self) -> Result<(), PersistenceError> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }
}

#[async_trait]
impl IdentityRepository for Database {
    async fn resolve_session(
        &self,
        token_digest: &[u8],
        now: DateTime<Utc>,
    ) -> Result<User, PortError> {
        let row = sqlx::query_as::<_, UserRow>(
            "SELECT users.id, users.email, users.role \
             FROM sessions \
             JOIN users ON users.id = sessions.user_id \
             WHERE sessions.token_digest = $1 \
               AND sessions.revoked_at IS NULL \
               AND sessions.expires_at > $2 \
               AND users.disabled = false",
        )
        .bind(token_digest)
        .bind(now)
        .fetch_optional(&self.pool)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;

        Ok(User {
            id: row.id,
            email: row.email,
            role: Role::try_from(row.role.as_str()).map_err(|_| PortError::InvalidData)?,
        })
    }
}

#[async_trait]
impl PipelineRepository for Database {
    async fn list_recent(
        &self,
        tenant_id: &str,
        repository_id: Option<Uuid>,
        limit: i64,
    ) -> Result<Vec<PipelineProjection>, PortError> {
        self.list_pipeline_projection(tenant_id, repository_id, limit)
            .await
            .map_err(|_| PortError::Unavailable)
    }
}

#[derive(sqlx::FromRow)]
struct PipelineRecordRow {
    id: Uuid,
    repository_id: Uuid,
    workflow_name: String,
    commit_sha: String,
    status: String,
    inserted_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct UserRow {
    id: Uuid,
    email: String,
    role: String,
}

impl TryFrom<PipelineRecordRow> for PipelineProjection {
    type Error = PersistenceError;

    fn try_from(row: PipelineRecordRow) -> Result<Self, Self::Error> {
        let status = PipelineState::try_from(row.status.as_str())?;
        Ok(PipelineProjection {
            id: row.id,
            repository_id: row.repository_id,
            workflow_name: row.workflow_name,
            commit_sha: row.commit_sha,
            status: status.as_str().into(),
            inserted_at: row.inserted_at,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persisted_pipeline_rejects_unknown_state() {
        let row = PipelineRecordRow {
            id: Uuid::nil(),
            repository_id: Uuid::nil(),
            workflow_name: "CI".into(),
            commit_sha: "0".repeat(40),
            status: "surprising".into(),
            inserted_at: Utc::now(),
        };

        assert!(matches!(
            PipelineProjection::try_from(row),
            Err(PersistenceError::UnknownPipelineState(_))
        ));
    }
}
