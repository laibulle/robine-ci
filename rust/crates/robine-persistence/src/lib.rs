//! `PostgreSQL` adapters for the existing Robine schema.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use robine_core::{
    identity::{LocalIdentity, Role, User},
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
    async fn bootstrap_administrator(
        &self,
        user_id: Uuid,
        credential_id: Uuid,
        email: &str,
        password_hash: &str,
        inserted_at: DateTime<Utc>,
    ) -> Result<User, PortError> {
        let mut transaction = self
            .pool
            .begin()
            .await
            .map_err(|_| PortError::Unavailable)?;
        sqlx::query("LOCK TABLE users IN EXCLUSIVE MODE")
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let count = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users")
            .fetch_one(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        if count != 0 {
            return Err(PortError::AlreadyBootstrapped);
        }

        sqlx::query(
            "INSERT INTO users (id, email, role, disabled, inserted_at) \
             VALUES ($1, $2, 'administrator', false, $3)",
        )
        .bind(user_id)
        .bind(email)
        .bind(inserted_at)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        sqlx::query(
            "INSERT INTO local_credentials (id, user_id, password_hash, inserted_at) \
             VALUES ($1, $2, $3, $4)",
        )
        .bind(credential_id)
        .bind(user_id)
        .bind(password_hash)
        .bind(inserted_at)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;

        Ok(User {
            id: user_id,
            email: email.into(),
            role: Role::Administrator,
            disabled: false,
        })
    }

    async fn get_local_identity(&self, email: &str) -> Result<LocalIdentity, PortError> {
        let row = sqlx::query_as::<_, LocalIdentityRow>(
            "SELECT users.id, users.email, users.role, users.disabled, \
                    local_credentials.password_hash \
             FROM users \
             JOIN local_credentials ON local_credentials.user_id = users.id \
             WHERE users.email = $1",
        )
        .bind(email)
        .fetch_optional(&self.pool)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;

        Ok(LocalIdentity {
            user: user_from_parts(row.id, row.email, &row.role, row.disabled)?,
            password_hash: row.password_hash,
        })
    }

    async fn resolve_session(
        &self,
        token_digest: &[u8],
        now: DateTime<Utc>,
    ) -> Result<User, PortError> {
        let row = sqlx::query_as::<_, UserRow>(
            "SELECT users.id, users.email, users.role, users.disabled \
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

        user_from_parts(row.id, row.email, &row.role, row.disabled)
    }

    async fn create_session(
        &self,
        id: Uuid,
        user_id: Uuid,
        token_digest: &[u8],
        expires_at: DateTime<Utc>,
        inserted_at: DateTime<Utc>,
    ) -> Result<(), PortError> {
        sqlx::query(
            "INSERT INTO sessions \
             (id, user_id, token_digest, expires_at, inserted_at) \
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(id)
        .bind(user_id)
        .bind(token_digest)
        .bind(expires_at)
        .bind(inserted_at)
        .execute(&self.pool)
        .await
        .map_err(|_| PortError::Unavailable)?;
        Ok(())
    }

    async fn revoke_session(
        &self,
        token_digest: &[u8],
        revoked_at: DateTime<Utc>,
    ) -> Result<(), PortError> {
        let result = sqlx::query(
            "UPDATE sessions SET revoked_at = $2 \
             WHERE token_digest = $1 AND revoked_at IS NULL",
        )
        .bind(token_digest)
        .bind(revoked_at)
        .execute(&self.pool)
        .await
        .map_err(|_| PortError::Unavailable)?;

        if result.rows_affected() == 0 {
            Err(PortError::NotFound)
        } else {
            Ok(())
        }
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
    disabled: bool,
}

#[derive(sqlx::FromRow)]
struct LocalIdentityRow {
    id: Uuid,
    email: String,
    role: String,
    disabled: bool,
    password_hash: String,
}

fn user_from_parts(id: Uuid, email: String, role: &str, disabled: bool) -> Result<User, PortError> {
    Ok(User {
        id,
        email,
        role: Role::try_from(role).map_err(|_| PortError::InvalidData)?,
        disabled,
    })
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
