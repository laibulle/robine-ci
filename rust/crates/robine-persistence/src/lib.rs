//! `PostgreSQL` adapters for the existing Robine schema.

use async_trait::async_trait;
use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use robine_core::{
    identity::{LocalIdentity, OidcClaims, Role, User},
    pipelines::{
        AttemptEventError, AttemptProjection, AttemptState, DurableJobClaim, JobState, NewPipeline,
        OutboxDelivery, PipelineEvent, PipelineProjection, PipelineState, RecordAttemptEvent,
        RecordRemoteAttemptEvent, RetryProjection, RunnerAuthenticationMaterial,
        RunnerLeaseHeartbeat, RunnerResume, SchedulerClaim, UnknownPipelineState,
        outbox_backoff_seconds,
    },
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
        sqlx::query(
            "INSERT INTO ci_tenants (id, inserted_at) VALUES ($1, NOW()) ON CONFLICT DO NOTHING",
        )
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await?;
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
            inserted_at,
        })
    }

    async fn get_local_identity(&self, email: &str) -> Result<LocalIdentity, PortError> {
        let row = sqlx::query_as::<_, LocalIdentityRow>(
            "SELECT users.id, users.email, users.role, users.disabled, users.inserted_at, \
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
            user: user_from_parts(row.id, row.email, &row.role, row.disabled, row.inserted_at)?,
            password_hash: row.password_hash,
        })
    }

    async fn resolve_session(
        &self,
        token_digest: &[u8],
        now: DateTime<Utc>,
    ) -> Result<User, PortError> {
        let row = sqlx::query_as::<_, UserRow>(
            "SELECT users.id, users.email, users.role, users.disabled, users.inserted_at \
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

        user_from_parts(row.id, row.email, &row.role, row.disabled, row.inserted_at)
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

    async fn list_users(&self) -> Result<Vec<User>, PortError> {
        let rows = sqlx::query_as::<_, UserRow>(
            "SELECT id, email, role, disabled, inserted_at FROM users ORDER BY email ASC",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(|_| PortError::Unavailable)?;

        rows.into_iter()
            .map(|row| user_from_parts(row.id, row.email, &row.role, row.disabled, row.inserted_at))
            .collect()
    }

    async fn change_user_role(&self, user_id: Uuid, role: Role) -> Result<User, PortError> {
        let mut transaction = self
            .pool
            .begin()
            .await
            .map_err(|_| PortError::Unavailable)?;
        sqlx::query("LOCK TABLE users IN EXCLUSIVE MODE")
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let row = sqlx::query_as::<_, UserRow>(
            "SELECT id, email, role, disabled, inserted_at FROM users WHERE id = $1",
        )
        .bind(user_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        let current_role = Role::try_from(row.role.as_str()).map_err(|_| PortError::InvalidData)?;

        if current_role == Role::Administrator && role != Role::Administrator {
            let usable_administrators = sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM users WHERE role = 'administrator' AND disabled = false",
            )
            .fetch_one(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
            if usable_administrators <= 1 {
                return Err(PortError::LastAdministrator);
            }
        }

        sqlx::query("UPDATE users SET role = $2 WHERE id = $1")
            .bind(user_id)
            .bind(role.as_str())
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;

        Ok(User {
            id: row.id,
            email: row.email,
            role,
            disabled: row.disabled,
            inserted_at: row.inserted_at.and_utc(),
        })
    }

    async fn find_or_provision_oidc_user(
        &self,
        claims: &OidcClaims,
        user_id: Uuid,
        inserted_at: DateTime<Utc>,
    ) -> Result<User, PortError> {
        let mut transaction = self
            .pool
            .begin()
            .await
            .map_err(|_| PortError::Unavailable)?;
        let identity_key = format!("{}:{}", claims.issuer, claims.subject);
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(identity_key)
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;

        let existing = sqlx::query_as::<_, UserRow>(
            "SELECT users.id, users.email, users.role, users.disabled, users.inserted_at \
             FROM oidc_identities \
             JOIN users ON users.id = oidc_identities.user_id \
             WHERE oidc_identities.issuer = $1 AND oidc_identities.subject = $2",
        )
        .bind(&claims.issuer)
        .bind(&claims.subject)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if let Some(row) = existing {
            return user_from_parts(row.id, row.email, &row.role, row.disabled, row.inserted_at);
        }

        let email = claims.email.to_lowercase();
        let email_exists =
            sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM users WHERE email = $1)")
                .bind(&email)
                .fetch_one(&mut *transaction)
                .await
                .map_err(|_| PortError::Unavailable)?;
        if email_exists {
            return Err(PortError::OidcEmailCollision);
        }

        sqlx::query(
            "INSERT INTO users (id, email, role, disabled, inserted_at) \
             VALUES ($1, $2, 'viewer', false, $3)",
        )
        .bind(user_id)
        .bind(&email)
        .bind(inserted_at)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        sqlx::query(
            "INSERT INTO oidc_identities (id, user_id, issuer, subject, inserted_at) \
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(Uuid::new_v4())
        .bind(user_id)
        .bind(&claims.issuer)
        .bind(&claims.subject)
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
            email,
            role: Role::Viewer,
            disabled: false,
            inserted_at,
        })
    }
}

#[async_trait]
impl PipelineRepository for Database {
    async fn list_tenants(&self) -> Result<Vec<String>, PortError> {
        let mut tenants =
            sqlx::query_scalar::<_, String>("SELECT id FROM ci_tenants ORDER BY inserted_at, id")
                .fetch_all(&self.pool)
                .await
                .map_err(|_| PortError::Unavailable)?;
        if !tenants.iter().any(|tenant| tenant == "standalone") {
            tenants.insert(0, "standalone".into());
        }
        Ok(tenants)
    }

    async fn create(
        &self,
        tenant_id: &str,
        pipeline: &NewPipeline,
    ) -> Result<PipelineProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(format!("pipeline:{}", pipeline.id))
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        if let Some(existing) =
            load_existing_creation(&mut transaction, tenant_id, pipeline.id).await?
        {
            if creation_matches(&existing, pipeline) {
                transaction
                    .commit()
                    .await
                    .map_err(|_| PortError::Unavailable)?;
                return existing.projection(pipeline.id);
            }
            return Err(PortError::IdempotencyConflict);
        }

        insert_new_creation(&mut transaction, tenant_id, pipeline).await?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(pipeline_projection(pipeline))
    }

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

    async fn queue(
        &self,
        tenant_id: &str,
        pipeline_id: Uuid,
    ) -> Result<PipelineProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let pipeline = sqlx::query_as::<_, PipelineRecordRow>(
            "SELECT id, repository_id, workflow_name, commit_sha, status, inserted_at \
             FROM pipelines WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
        )
        .bind(pipeline_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        let target = PipelineState::try_from(pipeline.status.as_str())
            .map_err(|_| PortError::InvalidData)?
            .queue()
            .map_err(|_| PortError::InvalidTransition)?;
        if pipeline.status != target.as_str() {
            sqlx::query("UPDATE pipelines SET status = $2 WHERE id = $1 AND tenant_id = $3")
                .bind(pipeline_id)
                .bind(target.as_str())
                .bind(tenant_id)
                .execute(&mut *transaction)
                .await
                .map_err(|_| PortError::Unavailable)?;
        }
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;

        let mut projection: PipelineProjection =
            pipeline.try_into().map_err(|_| PortError::InvalidData)?;
        projection.status = target.as_str().into();
        Ok(projection)
    }

    async fn cancel(
        &self,
        tenant_id: &str,
        pipeline_id: Uuid,
        event_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<PipelineProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let pipeline = sqlx::query_as::<_, PipelineRecordRow>(
            "SELECT id, repository_id, workflow_name, commit_sha, status, inserted_at \
             FROM pipelines WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
        )
        .bind(pipeline_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        let current = PipelineState::try_from(pipeline.status.as_str())
            .map_err(|_| PortError::InvalidData)?;
        let target = current
            .request_cancellation()
            .map_err(|_| PortError::InvalidTransition)?;

        sqlx::query(
            "UPDATE pipeline_jobs SET status = CASE \
               WHEN status IN ('blocked', 'queued') THEN 'cancelled' \
               WHEN status = 'running' THEN 'cancelling' ELSE status END, \
             updated_at = CASE WHEN status IN ('blocked', 'queued', 'running') THEN $2 ELSE updated_at END \
             WHERE pipeline_id = $1 AND tenant_id = $3",
        )
        .bind(pipeline_id)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;

        let updated = sqlx::query_as::<_, PipelineRecordRow>(
            "UPDATE pipelines SET status = $2, \
               finished_at = CASE WHEN $2 = 'cancelled' THEN $3 ELSE finished_at END \
             WHERE id = $1 AND tenant_id = $4 \
             RETURNING id, repository_id, workflow_name, commit_sha, status, inserted_at",
        )
        .bind(pipeline_id)
        .bind(target.as_str())
        .bind(now)
        .bind(tenant_id)
        .fetch_one(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;

        sqlx::query(
            "INSERT INTO outbox_events \
             (id, event_type, aggregate_id, payload, occurred_at, inserted_at, tenant_id) \
             VALUES ($1, 'pipeline.projection_requested', $2, $3, $4, $4, $5)",
        )
        .bind(event_id)
        .bind(pipeline_id)
        .bind(serde_json::json!({"pipeline_id": pipeline_id, "dispatch": false}))
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;

        updated.try_into().map_err(|_| PortError::InvalidData)
    }

    async fn retry_job(
        &self,
        tenant_id: &str,
        job_id: Uuid,
        event_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<RetryProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let row = sqlx::query_as::<_, RetryJobRow>(
            "SELECT job.pipeline_id, job.status, job.needs, job.execution_spec, \
                    pipeline.status AS pipeline_status \
             FROM pipeline_jobs AS job \
             JOIN pipelines AS pipeline ON pipeline.id = job.pipeline_id \
               AND pipeline.tenant_id = job.tenant_id \
             WHERE job.id = $1 AND job.tenant_id = $2 \
             FOR UPDATE OF job, pipeline",
        )
        .bind(job_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        JobState::try_from(row.status.as_str())
            .map_err(|_| PortError::InvalidData)?
            .retry()
            .map_err(|_| PortError::InvalidTransition)?;
        PipelineState::try_from(row.pipeline_status.as_str())
            .map_err(|_| PortError::InvalidData)?
            .reopen_for_retry()
            .map_err(|_| PortError::InvalidTransition)?;

        validate_retry_dependencies(&mut transaction, &row, tenant_id).await?;
        validate_retry_artifacts(&mut transaction, &row, tenant_id, now).await?;

        sqlx::query(
            "UPDATE pipeline_jobs SET status = 'queued', updated_at = $2 \
             WHERE id = $1 AND tenant_id = $3",
        )
        .bind(job_id)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        sqlx::query(
            "UPDATE pipelines SET status = 'running', started_at = $2, finished_at = NULL \
             WHERE id = $1 AND tenant_id = $3",
        )
        .bind(row.pipeline_id)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        sqlx::query(
            "INSERT INTO outbox_events \
             (id, event_type, aggregate_id, payload, occurred_at, inserted_at, tenant_id) \
             VALUES ($1, 'pipeline.projection_requested', $2, $3, $4, $4, $5)",
        )
        .bind(event_id)
        .bind(row.pipeline_id)
        .bind(serde_json::json!({"pipeline_id": row.pipeline_id, "dispatch": true}))
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;

        Ok(RetryProjection {
            pipeline_id: row.pipeline_id,
            job_id,
            status: "queued".into(),
            rerun_jobs: Vec::new(),
        })
    }

    async fn claim_next_job(
        &self,
        tenant_id: &str,
        claim: &SchedulerClaim,
    ) -> Result<AttemptProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let attempt = claim_job_in_transaction(&mut transaction, tenant_id, claim).await?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(attempt)
    }

    async fn record_attempt_event(
        &self,
        tenant_id: &str,
        event_id: Uuid,
        event: &RecordAttemptEvent,
        now: DateTime<Utc>,
    ) -> Result<AttemptProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let attempt = sqlx::query_as::<_, AttemptEventRow>(
            "SELECT attempt.id, attempt.job_id, attempt.number, attempt.idempotency_token, \
                    attempt.status, attempt.lease_expires_at, attempt.last_sequence, \
                    attempt.result_reason, job.pipeline_id \
             FROM job_attempts AS attempt \
             JOIN pipeline_jobs AS job ON job.id = attempt.job_id \
               AND job.tenant_id = attempt.tenant_id \
             WHERE attempt.idempotency_token = $1 AND attempt.tenant_id = $2 \
             FOR UPDATE OF attempt",
        )
        .bind(event.idempotency_token)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        let state =
            AttemptState::try_from(attempt.status.as_str()).map_err(|_| PortError::InvalidData)?;
        let Some(target) = state
            .apply(attempt.last_sequence, event)
            .map_err(|error| attempt_event_error(&error))?
        else {
            transaction
                .commit()
                .await
                .map_err(|_| PortError::Unavailable)?;
            return Ok(attempt.projection());
        };
        sqlx::query(
            "UPDATE job_attempts SET status = $2, last_sequence = $3, result_reason = $4, \
             updated_at = $5 WHERE id = $1 AND tenant_id = $6",
        )
        .bind(attempt.id)
        .bind(target.as_str())
        .bind(event.sequence)
        .bind(&event.reason)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if target.terminal() {
            reconcile_terminal_attempt(
                &mut transaction,
                tenant_id,
                attempt.job_id,
                attempt.pipeline_id,
                target,
                event_id,
                now,
            )
            .await?;
        }
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(AttemptProjection {
            id: attempt.id,
            job_id: attempt.job_id,
            number: attempt.number,
            idempotency_token: attempt.idempotency_token,
            status: target.as_str().into(),
            lease_expires_at: attempt.lease_expires_at.and_utc(),
            last_sequence: event.sequence,
            result_reason: event.reason.clone(),
        })
    }

    async fn heartbeat_attempt(
        &self,
        tenant_id: &str,
        idempotency_token: Uuid,
        lease_seconds: i64,
        now: DateTime<Utc>,
    ) -> Result<AttemptProjection, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let attempt = load_attempt_for_update(&mut transaction, tenant_id, idempotency_token)
            .await?
            .ok_or(PortError::NotFound)?;
        let renewed = attempt
            .projection()
            .heartbeat(now, lease_seconds)
            .map_err(|_| PortError::InvalidTransition)?;
        sqlx::query(
            "UPDATE job_attempts SET lease_expires_at = $2, updated_at = $3 \
             WHERE id = $1 AND tenant_id = $4",
        )
        .bind(attempt.id)
        .bind(renewed)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        let mut projection = attempt.projection();
        projection.lease_expires_at = renewed;
        Ok(projection)
    }

    async fn reconcile_expired_attempts(
        &self,
        tenant_id: &str,
        limit: i64,
        now: DateTime<Utc>,
    ) -> Result<u64, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let attempts = sqlx::query_as::<_, AttemptEventRow>(
            "SELECT attempt.id, attempt.job_id, attempt.number, attempt.idempotency_token, \
                    attempt.status, attempt.lease_expires_at, attempt.last_sequence, \
                    attempt.result_reason, job.pipeline_id \
             FROM job_attempts AS attempt \
             JOIN pipeline_jobs AS job ON job.id = attempt.job_id \
               AND job.tenant_id = attempt.tenant_id \
             WHERE attempt.tenant_id = $1 \
               AND attempt.status IN ('queued', 'preparing', 'running', 'cancelling') \
               AND attempt.lease_expires_at < $2 \
             ORDER BY attempt.lease_expires_at, attempt.id LIMIT $3 \
             FOR UPDATE OF attempt SKIP LOCKED",
        )
        .bind(tenant_id)
        .bind(now)
        .bind(limit.clamp(1, 1_000))
        .fetch_all(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        for attempt in &attempts {
            sqlx::query(
                "UPDATE job_attempts SET status = 'failed', last_sequence = $2, \
                 result_reason = 'runner_lost', updated_at = $3 \
                 WHERE id = $1 AND tenant_id = $4",
            )
            .bind(attempt.id)
            .bind(attempt.last_sequence + 1)
            .bind(now)
            .bind(tenant_id)
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
            reconcile_terminal_attempt(
                &mut transaction,
                tenant_id,
                attempt.job_id,
                attempt.pipeline_id,
                AttemptState::Failed,
                Uuid::new_v4(),
                now,
            )
            .await?;
        }
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        u64::try_from(attempts.len()).map_err(|_| PortError::Unavailable)
    }

    async fn runner_authentication_material(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<RunnerAuthenticationMaterial, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let runner = sqlx::query_as::<_, (Uuid, String, String)>(
            "SELECT id, name, admin_state FROM remote_runners \
             WHERE id = $1 AND tenant_id = $2",
        )
        .bind(runner_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        let credential_digests = sqlx::query_scalar::<_, Vec<u8>>(
            "SELECT credential_digest FROM runner_credentials \
             WHERE runner_id = $1 AND tenant_id = $2 AND revoked_at IS NULL \
               AND (expires_at IS NULL OR expires_at > $3) ORDER BY inserted_at",
        )
        .bind(runner_id)
        .bind(tenant_id)
        .bind(now)
        .fetch_all(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        if credential_digests.is_empty() {
            return Err(PortError::NotFound);
        }
        Ok(RunnerAuthenticationMaterial {
            id: runner.0,
            name: runner.1,
            admin_state: runner.2,
            credential_digests,
        })
    }

    async fn heartbeat_runner_attempts(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        lease_seconds: i64,
        now: DateTime<Utc>,
    ) -> Result<RunnerLeaseHeartbeat, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let state = sqlx::query_scalar::<_, String>(
            "SELECT admin_state FROM remote_runners WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
        )
        .bind(runner_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        if state == "revoked" {
            return Err(PortError::NotFound);
        }
        let attempts = sqlx::query_as::<_, (Uuid, String)>(
            "SELECT attempt.id, pipeline.status FROM job_attempts AS attempt \
             JOIN pipeline_jobs AS job ON job.id = attempt.job_id \
               AND job.tenant_id = attempt.tenant_id \
             JOIN pipelines AS pipeline ON pipeline.id = job.pipeline_id \
               AND pipeline.tenant_id = attempt.tenant_id \
             WHERE attempt.runner_id = $1 AND attempt.tenant_id = $2 \
               AND attempt.status IN ('queued', 'preparing', 'running', 'cancelling') \
             ORDER BY attempt.inserted_at FOR UPDATE OF attempt",
        )
        .bind(runner_id.to_string())
        .bind(tenant_id)
        .fetch_all(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        let renewed_lease = now + chrono::Duration::seconds(lease_seconds);
        for (attempt_id, _) in &attempts {
            sqlx::query(
                "UPDATE job_attempts SET lease_expires_at = GREATEST(lease_expires_at, $2), \
                 updated_at = $3 WHERE id = $1 AND tenant_id = $4",
            )
            .bind(attempt_id)
            .bind(renewed_lease)
            .bind(now)
            .bind(tenant_id)
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        }
        sqlx::query(
            "UPDATE remote_runners SET last_authenticated_at = $2, last_seen_at = $2, \
             updated_at = $2 WHERE id = $1 AND tenant_id = $3",
        )
        .bind(runner_id)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(RunnerLeaseHeartbeat {
            renewed_attempts: u64::try_from(attempts.len()).map_err(|_| PortError::Unavailable)?,
            cancellation_requested_attempt_ids: attempts
                .into_iter()
                .filter_map(|(id, status)| {
                    matches!(status.as_str(), "cancelling" | "cancelled").then_some(id)
                })
                .collect(),
        })
    }

    async fn reconcile_runner_attempts(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<Vec<RunnerResume>, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let state = sqlx::query_scalar::<_, String>(
            "SELECT admin_state FROM remote_runners WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
        )
        .bind(runner_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        if state == "revoked" {
            return Err(PortError::NotFound);
        }
        let assigned = sqlx::query_as::<_, (Uuid, i32)>(
            "SELECT id, last_sequence FROM job_attempts \
             WHERE runner_id = $1 AND tenant_id = $2 \
               AND status IN ('queued', 'preparing', 'running', 'cancelling') \
             ORDER BY inserted_at, id FOR UPDATE",
        )
        .bind(runner_id.to_string())
        .bind(tenant_id)
        .fetch_all(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        sqlx::query(
            "UPDATE remote_runners SET last_authenticated_at = $2, last_seen_at = $2, \
             updated_at = $2 WHERE id = $1 AND tenant_id = $3",
        )
        .bind(runner_id)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(assigned
            .into_iter()
            .map(|(attempt_id, acknowledged_sequence)| RunnerResume {
                attempt_id,
                acknowledged_sequence,
            })
            .collect())
    }

    #[allow(clippy::too_many_lines)]
    async fn record_remote_attempt_event(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        receipt_id: Uuid,
        outbox_event_id: Uuid,
        event: &RecordRemoteAttemptEvent,
        now: DateTime<Utc>,
    ) -> Result<AttemptProjection, PortError> {
        if event.message_id.is_empty() || event.message_id.len() > 128 || event.sequence <= 0 {
            return Err(PortError::InvalidAttemptEvent);
        }
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let attempt = load_attempt_for_update(&mut transaction, tenant_id, event.idempotency_token)
            .await?
            .ok_or(PortError::NotFound)?;
        let assigned_runner = sqlx::query_scalar::<_, Option<String>>(
            "SELECT runner_id FROM job_attempts WHERE id = $1 AND tenant_id = $2",
        )
        .bind(attempt.id)
        .bind(tenant_id)
        .fetch_one(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if assigned_runner.as_deref() != Some(runner_id.to_string().as_str()) {
            return Err(PortError::AttemptNotAssigned);
        }
        let receipt = sqlx::query_as::<_, RunnerEventReceiptRow>(
            "SELECT attempt_id, sequence, status, reason FROM runner_attempt_events \
             WHERE runner_id = $1 AND message_id = $2 AND tenant_id = $3",
        )
        .bind(runner_id.to_string())
        .bind(&event.message_id)
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if let Some(receipt) = receipt {
            if receipt.attempt_id == attempt.id
                && receipt.sequence == event.sequence
                && receipt.status == event.status
                && receipt.reason == event.reason
            {
                transaction
                    .commit()
                    .await
                    .map_err(|_| PortError::Unavailable)?;
                return Ok(attempt.projection());
            }
            return Err(PortError::MessageIdConflict);
        }
        if event.sequence <= attempt.last_sequence {
            return Err(PortError::StaleEvent {
                last: attempt.last_sequence,
                actual: event.sequence,
            });
        }
        let attempt_event = event.attempt_event();
        let state =
            AttemptState::try_from(attempt.status.as_str()).map_err(|_| PortError::InvalidData)?;
        let target = state
            .apply(attempt.last_sequence, &attempt_event)
            .map_err(|error| attempt_event_error(&error))?
            .ok_or(PortError::InvalidAttemptEvent)?;
        sqlx::query(
            "UPDATE job_attempts SET status = $2, last_sequence = $3, result_reason = $4, \
             updated_at = $5 WHERE id = $1 AND tenant_id = $6",
        )
        .bind(attempt.id)
        .bind(target.as_str())
        .bind(event.sequence)
        .bind(&event.reason)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if target.terminal() {
            reconcile_terminal_attempt(
                &mut transaction,
                tenant_id,
                attempt.job_id,
                attempt.pipeline_id,
                target,
                outbox_event_id,
                now,
            )
            .await?;
        }
        let inserted = sqlx::query(
            "INSERT INTO runner_attempt_events \
             (id, runner_id, message_id, attempt_id, sequence, status, reason, inserted_at, tenant_id) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        )
        .bind(receipt_id)
        .bind(runner_id.to_string())
        .bind(&event.message_id)
        .bind(attempt.id)
        .bind(event.sequence)
        .bind(&event.status)
        .bind(&event.reason)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await;
        if let Err(error) = inserted {
            return Err(if unique_violation(&error) {
                PortError::MessageIdConflict
            } else {
                PortError::Unavailable
            });
        }
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(AttemptProjection {
            id: attempt.id,
            job_id: attempt.job_id,
            number: attempt.number,
            idempotency_token: attempt.idempotency_token,
            status: target.as_str().into(),
            lease_expires_at: attempt.lease_expires_at.and_utc(),
            last_sequence: event.sequence,
            result_reason: event.reason.clone(),
        })
    }

    async fn remote_job_offer(
        &self,
        tenant_id: &str,
        runner_id: Uuid,
        attempt_id: Uuid,
    ) -> Result<serde_json::Value, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let row = sqlx::query_as::<_, RemoteOfferRow>(
            "SELECT attempt.id AS attempt_id, attempt.idempotency_token, job.id AS job_id, \
                    job.job_key, job.needs, job.execution_spec, pipeline.id AS pipeline_id, \
                    pipeline.correlation_id, pipeline.commit_sha, pipeline.repository_id, \
                    pipeline.source_ref, pipeline.trigger, pipeline.started_at, pipeline.inserted_at \
             FROM job_attempts AS attempt \
             JOIN pipeline_jobs AS job ON job.id = attempt.job_id \
               AND job.tenant_id = attempt.tenant_id \
             JOIN pipelines AS pipeline ON pipeline.id = job.pipeline_id \
               AND pipeline.tenant_id = attempt.tenant_id \
             WHERE attempt.id = $1 AND attempt.runner_id = $2 AND attempt.tenant_id = $3",
        )
        .bind(attempt_id)
        .bind(runner_id.to_string())
        .bind(tenant_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?
        .ok_or(PortError::NotFound)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        let mut execution = row
            .execution_spec
            .as_object()
            .cloned()
            .ok_or(PortError::InvalidData)?;
        let timestamp = row.started_at.unwrap_or(row.inserted_at).and_utc();
        let ref_type = match row.trigger.as_str() {
            "tag" => "tag",
            "pull_request" | "merge_request" => "pull_request",
            _ if row
                .source_ref
                .as_deref()
                .is_some_and(|value| !value.is_empty()) =>
            {
                "branch"
            }
            _ => "unknown",
        };
        execution.insert(
            "build_env".into(),
            serde_json::json!({
                "ROBINE_BUILD_COMMIT_SHA": row.commit_sha,
                "ROBINE_BUILD_REF_NAME": row.source_ref.clone().unwrap_or_default(),
                "ROBINE_BUILD_REF_TYPE": ref_type,
                "ROBINE_BUILD_TIMESTAMP": timestamp.to_rfc3339_opts(SecondsFormat::AutoSi, true),
                "ROBINE_BUILD_PIPELINE_ID": row.pipeline_id,
                "ROBINE_BUILD_TRIGGER": row.trigger,
            }),
        );
        execution.extend([
            ("attempt_id".into(), serde_json::json!(row.attempt_id)),
            ("job_id".into(), serde_json::json!(row.job_id)),
            ("job_key".into(), serde_json::json!(row.job_key)),
            ("needs".into(), serde_json::json!(row.needs)),
            (
                "idempotency_token".into(),
                serde_json::json!(row.idempotency_token),
            ),
            ("pipeline_id".into(), serde_json::json!(row.pipeline_id)),
            (
                "correlation_id".into(),
                serde_json::json!(row.correlation_id),
            ),
            ("commit_sha".into(), serde_json::json!(row.commit_sha)),
            ("repository_id".into(), serde_json::json!(row.repository_id)),
        ]);
        Ok(serde_json::Value::Object(execution))
    }

    async fn process_next_outbox_event(
        &self,
        tenant_id: &str,
        now: DateTime<Utc>,
    ) -> Result<Option<OutboxDelivery>, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let event = sqlx::query_as::<_, PendingOutboxRow>(
            "SELECT id, event_type, aggregate_id, payload, delivery_attempts \
             FROM outbox_events WHERE tenant_id = $1 AND delivered_at IS NULL \
               AND dead_lettered_at IS NULL \
               AND COALESCE(available_at, occurred_at) <= $2 \
             ORDER BY occurred_at, id LIMIT 1 FOR UPDATE SKIP LOCKED",
        )
        .bind(tenant_id)
        .bind(now)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        let Some(event) = event else {
            transaction
                .commit()
                .await
                .map_err(|_| PortError::Unavailable)?;
            return Ok(None);
        };
        let attempt = event.delivery_attempts + 1;
        let delivery = prepare_outbox_delivery(&mut transaction, tenant_id, &event).await;
        let dispatch = match delivery {
            Ok(dispatch) => dispatch,
            Err(reason) => {
                let dead_lettered_at = (attempt >= 10).then_some(now);
                let available_at =
                    now + chrono::Duration::seconds(outbox_backoff_seconds(attempt, event.id));
                sqlx::query(
                    "UPDATE outbox_events SET delivery_attempts = $2, available_at = $3, \
                     last_error = $4, dead_lettered_at = $5 WHERE id = $1 AND tenant_id = $6",
                )
                .bind(event.id)
                .bind(attempt)
                .bind(available_at)
                .bind(reason)
                .bind(dead_lettered_at)
                .bind(tenant_id)
                .execute(&mut *transaction)
                .await
                .map_err(|_| PortError::Unavailable)?;
                transaction
                    .commit()
                    .await
                    .map_err(|_| PortError::Unavailable)?;
                return Ok(Some(OutboxDelivery {
                    event_id: event.id,
                    dispatch_enqueued: false,
                    delivered: false,
                    attempt,
                }));
            }
        };
        if dispatch {
            sqlx::query(
                "INSERT INTO durable_jobs \
                 (id, source_event_id, kind, payload, status, attempts, available_at, \
                  inserted_at, updated_at, tenant_id) \
                 VALUES ($1, $2, 'run_next_job', $3, 'available', 0, $4, $4, $4, $5) \
                 ON CONFLICT (tenant_id, source_event_id, kind) DO NOTHING",
            )
            .bind(Uuid::new_v4())
            .bind(event.id)
            .bind(serde_json::json!({"pipeline_id": event.aggregate_id}))
            .bind(now)
            .bind(tenant_id)
            .execute(&mut *transaction)
            .await
            .map_err(|_| PortError::Unavailable)?;
        }
        sqlx::query(
            "UPDATE outbox_events SET delivered_at = $2, delivery_attempts = $3, \
             last_error = NULL WHERE id = $1 AND tenant_id = $4",
        )
        .bind(event.id)
        .bind(now)
        .bind(attempt)
        .bind(tenant_id)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(Some(OutboxDelivery {
            event_id: event.id,
            dispatch_enqueued: dispatch,
            delivered: true,
            attempt,
        }))
    }

    async fn claim_next_dispatch_job(
        &self,
        tenant_id: &str,
        claim_token: Uuid,
        now: DateTime<Utc>,
        stale_before: DateTime<Utc>,
    ) -> Result<Option<DurableJobClaim>, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let claimed = sqlx::query_as::<_, DurableJobRow>(
            "WITH candidate AS ( \
               SELECT id FROM durable_jobs WHERE tenant_id = $1 AND kind = 'run_next_job' \
                 AND ((status IN ('available', 'retry') AND available_at <= $2) \
                   OR (status = 'executing' AND claimed_at < $3)) \
               ORDER BY available_at, inserted_at, id LIMIT 1 FOR UPDATE SKIP LOCKED \
             ) UPDATE durable_jobs AS job SET status = 'executing', attempts = attempts + 1, \
                 claimed_at = $2, claim_token = $4, updated_at = $2 \
             FROM candidate WHERE job.id = candidate.id AND job.tenant_id = $1 \
             RETURNING job.id, job.source_event_id, job.kind, job.payload, \
                       job.claim_token, job.attempts",
        )
        .bind(tenant_id)
        .bind(now)
        .bind(stale_before)
        .bind(claim_token)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(claimed.map(|job| DurableJobClaim {
            id: job.id,
            source_event_id: job.source_event_id,
            kind: job.kind,
            payload: job.payload,
            claim_token: job.claim_token,
            attempt: job.attempts,
        }))
    }

    async fn complete_durable_job(
        &self,
        tenant_id: &str,
        job_id: Uuid,
        claim_token: Uuid,
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        update_durable_job(
            self,
            tenant_id,
            job_id,
            claim_token,
            "completed",
            now,
            None,
            now,
        )
        .await
    }

    async fn retry_durable_job(
        &self,
        tenant_id: &str,
        job_id: Uuid,
        claim_token: Uuid,
        available_at: DateTime<Utc>,
        error: &str,
        discard: bool,
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        update_durable_job(
            self,
            tenant_id,
            job_id,
            claim_token,
            if discard { "discarded" } else { "retry" },
            available_at,
            Some(error),
            now,
        )
        .await
    }

    async fn enqueue_local_execution(
        &self,
        tenant_id: &str,
        attempt_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<(), PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        insert_local_execution_job(&mut transaction, tenant_id, attempt_id, now).await?;
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)
    }

    async fn reconcile_local_execution_jobs(
        &self,
        tenant_id: &str,
        limit: i64,
        now: DateTime<Utc>,
    ) -> Result<u64, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let attempts = sqlx::query_scalar::<_, Uuid>(
            "SELECT attempt.id FROM job_attempts AS attempt \
             WHERE attempt.tenant_id = $1 AND attempt.runner_id IS NULL \
               AND attempt.status IN ('queued', 'preparing', 'running', 'cancelling') \
               AND NOT EXISTS (SELECT 1 FROM durable_jobs AS job \
                 WHERE job.tenant_id = attempt.tenant_id \
                   AND job.source_event_id = attempt.id AND job.kind = 'execute_local_attempt') \
             ORDER BY attempt.inserted_at, attempt.id LIMIT $2 FOR UPDATE SKIP LOCKED",
        )
        .bind(tenant_id)
        .bind(limit.clamp(1, 1_000))
        .fetch_all(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        for attempt_id in &attempts {
            insert_local_execution_job(&mut transaction, tenant_id, *attempt_id, now).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        u64::try_from(attempts.len()).map_err(|_| PortError::Unavailable)
    }

    async fn consume_dispatch_job(
        &self,
        tenant_id: &str,
        durable_job_id: Uuid,
        claim_token: Uuid,
        claim: &SchedulerClaim,
    ) -> Result<Option<AttemptProjection>, PortError> {
        let mut transaction = self
            .tenant_transaction(tenant_id)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let claimed = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM durable_jobs \
             WHERE id = $1 AND tenant_id = $2 AND kind = 'run_next_job' \
               AND status = 'executing' AND claim_token = $3 FOR UPDATE)",
        )
        .bind(durable_job_id)
        .bind(tenant_id)
        .bind(claim_token)
        .fetch_one(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if !claimed {
            return Err(PortError::NotFound);
        }

        let attempt = match claim_job_in_transaction(&mut transaction, tenant_id, claim).await {
            Ok(attempt) => {
                insert_local_execution_job(&mut transaction, tenant_id, attempt.id, claim.now)
                    .await?;
                Some(attempt)
            }
            Err(PortError::NoWork) => None,
            Err(error) => return Err(error),
        };
        let completed = sqlx::query(
            "UPDATE durable_jobs SET status = 'completed', claimed_at = NULL, \
             claim_token = NULL, last_error = NULL, updated_at = $4 \
             WHERE id = $1 AND tenant_id = $2 AND status = 'executing' AND claim_token = $3",
        )
        .bind(durable_job_id)
        .bind(tenant_id)
        .bind(claim_token)
        .bind(claim.now)
        .execute(&mut *transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if completed.rows_affected() != 1 {
            return Err(PortError::NotFound);
        }
        transaction
            .commit()
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(attempt)
    }
}

#[allow(clippy::too_many_arguments)]
async fn update_durable_job(
    database: &Database,
    tenant_id: &str,
    job_id: Uuid,
    claim_token: Uuid,
    status: &str,
    available_at: DateTime<Utc>,
    error: Option<&str>,
    now: DateTime<Utc>,
) -> Result<(), PortError> {
    let mut transaction = database
        .tenant_transaction(tenant_id)
        .await
        .map_err(|_| PortError::Unavailable)?;
    let result = sqlx::query(
        "UPDATE durable_jobs SET status = $4, available_at = $5, claimed_at = NULL, \
         claim_token = NULL, last_error = $6, updated_at = $7 \
         WHERE id = $1 AND tenant_id = $2 AND status = 'executing' AND claim_token = $3",
    )
    .bind(job_id)
    .bind(tenant_id)
    .bind(claim_token)
    .bind(status)
    .bind(available_at)
    .bind(error)
    .bind(now)
    .execute(&mut *transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    if result.rows_affected() != 1 {
        return Err(PortError::NotFound);
    }
    transaction
        .commit()
        .await
        .map_err(|_| PortError::Unavailable)
}

async fn insert_local_execution_job(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    attempt_id: Uuid,
    now: DateTime<Utc>,
) -> Result<(), PortError> {
    sqlx::query(
        "INSERT INTO durable_jobs \
         (id, source_event_id, kind, payload, status, attempts, available_at, \
          inserted_at, updated_at, tenant_id) \
         VALUES ($1, $2, 'execute_local_attempt', $3, 'available', 0, $4, $4, $4, $5) \
         ON CONFLICT (tenant_id, source_event_id, kind) DO NOTHING",
    )
    .bind(Uuid::new_v4())
    .bind(attempt_id)
    .bind(serde_json::json!({"attempt_id": attempt_id}))
    .bind(now)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    Ok(())
}

async fn prepare_outbox_delivery(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    event: &PendingOutboxRow,
) -> Result<bool, &'static str> {
    match event.event_type.as_str() {
        "pipeline.created" => {
            let status = sqlx::query_scalar::<_, String>(
                "SELECT status FROM pipelines WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
            )
            .bind(event.aggregate_id)
            .bind(tenant_id)
            .fetch_optional(&mut **transaction)
            .await
            .map_err(|_| "pipeline lookup failed")?
            .ok_or("pipeline not found")?;
            match status.as_str() {
                "created" => {
                    sqlx::query(
                        "UPDATE pipelines SET status = 'queued' WHERE id = $1 AND tenant_id = $2",
                    )
                    .bind(event.aggregate_id)
                    .bind(tenant_id)
                    .execute(&mut **transaction)
                    .await
                    .map_err(|_| "pipeline queue failed")?;
                }
                "queued" | "running" => {}
                _ => return Err("pipeline cannot be queued"),
            }
            Ok(true)
        }
        "pipeline.projection_requested" => event
            .payload
            .get("dispatch")
            .and_then(serde_json::Value::as_bool)
            .ok_or("projection dispatch flag missing"),
        _ => Err("unsupported outbox event"),
    }
}

fn unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .is_some_and(|database| database.code().as_deref() == Some("23505"))
}

async fn load_attempt_for_update(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    idempotency_token: Uuid,
) -> Result<Option<AttemptEventRow>, PortError> {
    sqlx::query_as::<_, AttemptEventRow>(
        "SELECT attempt.id, attempt.job_id, attempt.number, attempt.idempotency_token, \
                attempt.status, attempt.lease_expires_at, attempt.last_sequence, \
                attempt.result_reason, job.pipeline_id \
         FROM job_attempts AS attempt \
         JOIN pipeline_jobs AS job ON job.id = attempt.job_id \
           AND job.tenant_id = attempt.tenant_id \
         WHERE attempt.idempotency_token = $1 AND attempt.tenant_id = $2 \
         FOR UPDATE OF attempt",
    )
    .bind(idempotency_token)
    .bind(tenant_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)
}

fn attempt_event_error(error: &AttemptEventError) -> PortError {
    match error {
        AttemptEventError::Gap { expected, actual } => PortError::EventGap {
            expected: *expected,
            actual: *actual,
        },
        AttemptEventError::InvalidTransition | AttemptEventError::InvalidReason => {
            PortError::InvalidAttemptEvent
        }
    }
}

async fn reconcile_terminal_attempt(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    job_id: Uuid,
    pipeline_id: Uuid,
    attempt_state: AttemptState,
    event_id: Uuid,
    now: DateTime<Utc>,
) -> Result<(), PortError> {
    let mut jobs = sqlx::query_as::<_, JobGraphRow>(
        "SELECT id, job_key, status, needs, execution_spec FROM pipeline_jobs \
         WHERE pipeline_id = $1 AND tenant_id = $2 ORDER BY position FOR UPDATE",
    )
    .bind(pipeline_id)
    .bind(tenant_id)
    .fetch_all(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    let terminal_job_state = match attempt_state {
        AttemptState::Succeeded => JobState::Succeeded,
        AttemptState::Failed => JobState::Failed,
        AttemptState::Cancelled => JobState::Cancelled,
        _ => return Err(PortError::InvalidAttemptEvent),
    };
    let source = jobs
        .iter_mut()
        .find(|job| job.id == job_id)
        .ok_or(PortError::InvalidData)?;
    let source_state =
        JobState::try_from(source.status.as_str()).map_err(|_| PortError::InvalidData)?;
    if !matches!(source_state, JobState::Running | JobState::Cancelling) {
        return Err(PortError::InvalidTransition);
    }
    source.status = terminal_job_state.as_str().into();
    release_job_graph(&mut jobs)?;
    for job in &jobs {
        sqlx::query(
            "UPDATE pipeline_jobs SET status = $2, updated_at = $3 \
             WHERE id = $1 AND tenant_id = $4 AND status <> $2",
        )
        .bind(job.id)
        .bind(&job.status)
        .bind(now)
        .bind(tenant_id)
        .execute(&mut **transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
    }
    let pipeline_status = sqlx::query_scalar::<_, String>(
        "SELECT status FROM pipelines WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
    )
    .bind(pipeline_id)
    .bind(tenant_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    let current_pipeline =
        PipelineState::try_from(pipeline_status.as_str()).map_err(|_| PortError::InvalidData)?;
    let job_states = jobs
        .iter()
        .map(|job| JobState::try_from(job.status.as_str()).map_err(|_| PortError::InvalidData))
        .collect::<Result<Vec<_>, _>>()?;
    let completed = current_pipeline
        .complete_from_jobs(&job_states)
        .map_err(|_| PortError::InvalidTransition)?;
    if completed != current_pipeline {
        sqlx::query(
            "UPDATE pipelines SET status = $2, finished_at = $3 WHERE id = $1 AND tenant_id = $4",
        )
        .bind(pipeline_id)
        .bind(completed.as_str())
        .bind(now)
        .bind(tenant_id)
        .execute(&mut **transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
    }
    sqlx::query(
        "INSERT INTO outbox_events \
         (id, event_type, aggregate_id, payload, occurred_at, inserted_at, tenant_id) \
         VALUES ($1, 'pipeline.projection_requested', $2, $3, $4, $4, $5)",
    )
    .bind(event_id)
    .bind(pipeline_id)
    .bind(serde_json::json!({"pipeline_id": pipeline_id, "dispatch": true}))
    .bind(now)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    Ok(())
}

fn release_job_graph(jobs: &mut [JobGraphRow]) -> Result<(), PortError> {
    loop {
        let statuses = jobs
            .iter()
            .map(|job| {
                JobState::try_from(job.status.as_str())
                    .map(|status| (job.job_key.clone(), status))
                    .map_err(|_| PortError::InvalidData)
            })
            .collect::<Result<std::collections::HashMap<_, _>, _>>()?;
        let mut changed = false;
        for job in &mut *jobs {
            let state = *statuses.get(&job.job_key).ok_or(PortError::InvalidData)?;
            let dependencies = job
                .needs
                .iter()
                .map(|key| statuses.get(key).copied().ok_or(PortError::InvalidData))
                .collect::<Result<Vec<_>, _>>()?;
            let condition = job
                .execution_spec
                .get("condition")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("success");
            let released = state.release(condition, &dependencies);
            if released != state {
                job.status = released.as_str().into();
                changed = true;
            }
        }
        if !changed {
            return Ok(());
        }
    }
}

async fn insert_new_creation(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    pipeline: &NewPipeline,
) -> Result<(), PortError> {
    sqlx::query(
        "INSERT INTO pipelines \
         (id, repository_id, workflow_name, commit_sha, source_ref, trigger, actor, \
          correlation_id, status, scheduled_for, inputs, inserted_at, tenant_id) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'created', $9, $10, $11, $12)",
    )
    .bind(pipeline.id)
    .bind(pipeline.repository_id)
    .bind(&pipeline.workflow_name)
    .bind(&pipeline.commit_sha)
    .bind(&pipeline.source_ref)
    .bind(&pipeline.trigger)
    .bind(&pipeline.actor)
    .bind(pipeline.correlation_id.to_string())
    .bind(pipeline.scheduled_for)
    .bind(serde_json::json!(pipeline.inputs))
    .bind(pipeline.inserted_at)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    sqlx::query(
        "INSERT INTO workflow_revisions \
         (id, pipeline_id, path, source, digest, normalized_graph, included_sources, \
          created_at, tenant_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
    )
    .bind(pipeline.revision.id)
    .bind(pipeline.id)
    .bind(&pipeline.revision.path)
    .bind(&pipeline.revision.source)
    .bind(&pipeline.revision.digest)
    .bind(&pipeline.revision.normalized_graph)
    .bind(&pipeline.revision.included_sources)
    .bind(pipeline.inserted_at)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    for job in &pipeline.jobs {
        sqlx::query(
            "INSERT INTO pipeline_jobs \
             (id, pipeline_id, job_key, status, needs, position, execution_spec, \
              inserted_at, updated_at, tenant_id) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $9)",
        )
        .bind(job.id)
        .bind(pipeline.id)
        .bind(&job.key)
        .bind(job.status.as_str())
        .bind(&job.needs)
        .bind(job.position)
        .bind(&job.execution)
        .bind(pipeline.inserted_at)
        .bind(tenant_id)
        .execute(&mut **transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
    }
    sqlx::query(
        "INSERT INTO outbox_events \
         (id, event_type, aggregate_id, payload, occurred_at, inserted_at, tenant_id) \
         VALUES ($1, 'pipeline.created', $2, $3, $4, $4, $5)",
    )
    .bind(pipeline.event_id)
    .bind(pipeline.id)
    .bind(serde_json::json!({
        "pipeline_id": pipeline.id,
        "repository_id": pipeline.repository_id
    }))
    .bind(pipeline.inserted_at)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    Ok(())
}

async fn load_existing_creation(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    pipeline_id: Uuid,
) -> Result<Option<ExistingCreationRow>, PortError> {
    sqlx::query_as::<_, ExistingCreationRow>(
        "SELECT pipeline.repository_id, pipeline.workflow_name, pipeline.commit_sha, \
                pipeline.source_ref, pipeline.trigger, pipeline.inputs, pipeline.scheduled_for, \
                pipeline.status, pipeline.inserted_at, \
                revision.path, revision.source, revision.included_sources \
         FROM pipelines AS pipeline \
         JOIN workflow_revisions AS revision ON revision.pipeline_id = pipeline.id \
           AND revision.tenant_id = pipeline.tenant_id \
         WHERE pipeline.id = $1 AND pipeline.tenant_id = $2",
    )
    .bind(pipeline_id)
    .bind(tenant_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)
}

fn creation_matches(existing: &ExistingCreationRow, pipeline: &NewPipeline) -> bool {
    existing.repository_id == pipeline.repository_id
        && existing.workflow_name == pipeline.workflow_name
        && existing.commit_sha == pipeline.commit_sha
        && existing.source_ref == pipeline.source_ref
        && existing.trigger == pipeline.trigger
        && existing.inputs == serde_json::json!(pipeline.inputs)
        && existing.scheduled_for.as_ref().map(NaiveDateTime::and_utc) == pipeline.scheduled_for
        && existing.path == pipeline.revision.path
        && existing.source == pipeline.revision.source
        && existing.included_sources == pipeline.revision.included_sources
}

fn pipeline_projection(pipeline: &NewPipeline) -> PipelineProjection {
    PipelineProjection {
        id: pipeline.id,
        repository_id: pipeline.repository_id,
        workflow_name: pipeline.workflow_name.clone(),
        commit_sha: pipeline.commit_sha.clone(),
        status: "created".into(),
        inserted_at: pipeline.inserted_at,
    }
}

async fn validate_retry_dependencies(
    transaction: &mut Transaction<'_, Postgres>,
    row: &RetryJobRow,
    tenant_id: &str,
) -> Result<(), PortError> {
    let dependency_rows = sqlx::query_as::<_, (String, String)>(
        "SELECT job_key, status FROM pipeline_jobs \
         WHERE pipeline_id = $1 AND tenant_id = $2 AND job_key = ANY($3)",
    )
    .bind(row.pipeline_id)
    .bind(tenant_id)
    .bind(&row.needs)
    .fetch_all(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    let succeeded = dependency_rows
        .into_iter()
        .filter_map(|(key, status)| (status == "succeeded").then_some(key))
        .collect::<std::collections::HashSet<_>>();
    let unavailable = row
        .needs
        .iter()
        .filter(|key| !succeeded.contains(key.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    if unavailable.is_empty() {
        Ok(())
    } else {
        Err(PortError::RetryDependenciesUnavailable(unavailable))
    }
}

async fn claim_job_in_transaction(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    claim: &SchedulerClaim,
) -> Result<AttemptProjection, PortError> {
    sqlx::query("SELECT pg_advisory_xact_lock(90464863604293)")
        .execute(&mut **transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
    let active = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM job_attempts WHERE tenant_id = $1 \
         AND status IN ('queued', 'preparing', 'running', 'cancelling')",
    )
    .bind(tenant_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    if active >= claim.global_limit {
        return Err(PortError::Capacity);
    }
    let labels = if let Some(runner_id) = claim.runner_id {
        runner_capacity_labels(transaction, tenant_id, runner_id, claim.now).await?
    } else {
        vec!["docker".into()]
    };
    let candidate = select_claim_candidate(transaction, tenant_id, claim.repository_limit, &labels)
        .await?
        .ok_or(PortError::NoWork)?;
    let pipeline_state = PipelineState::try_from(candidate.pipeline_status.as_str())
        .map_err(|_| PortError::InvalidData)?;
    if pipeline_state == PipelineState::Queued {
        pipeline_state
            .transition(PipelineEvent::Start)
            .map_err(|_| PortError::InvalidTransition)?;
    } else if pipeline_state != PipelineState::Running {
        return Err(PortError::InvalidTransition);
    }
    let number = sqlx::query_scalar::<_, i32>(
        "SELECT COALESCE(MAX(number), 0)::integer + 1 FROM job_attempts \
         WHERE job_id = $1 AND tenant_id = $2",
    )
    .bind(candidate.job_id)
    .bind(tenant_id)
    .fetch_one(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    let lease_expires_at = claim.now + chrono::Duration::seconds(claim.lease_seconds);
    persist_claim(
        transaction,
        tenant_id,
        &candidate,
        claim,
        number,
        lease_expires_at,
    )
    .await?;
    Ok(AttemptProjection {
        id: claim.attempt_id,
        job_id: candidate.job_id,
        number,
        idempotency_token: claim.idempotency_token,
        status: "queued".into(),
        lease_expires_at,
        last_sequence: 0,
        result_reason: None,
    })
}

async fn select_claim_candidate(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    repository_limit: i64,
    labels: &[String],
) -> Result<Option<ClaimCandidate>, PortError> {
    sqlx::query_as::<_, ClaimCandidate>(
        "WITH active_by_repository AS ( \
           SELECT pipeline.repository_id, COUNT(attempt.id) AS active_count \
           FROM job_attempts AS attempt \
           JOIN pipeline_jobs AS active_job ON active_job.id = attempt.job_id \
             AND active_job.tenant_id = attempt.tenant_id \
           JOIN pipelines AS pipeline ON pipeline.id = active_job.pipeline_id \
             AND pipeline.tenant_id = active_job.tenant_id \
           WHERE attempt.tenant_id = $1 \
             AND attempt.status IN ('queued', 'preparing', 'running', 'cancelling') \
           GROUP BY pipeline.repository_id) \
         SELECT job.id AS job_id, job.pipeline_id, pipeline.status AS pipeline_status \
         FROM pipeline_jobs AS job \
         JOIN pipelines AS pipeline ON pipeline.id = job.pipeline_id \
           AND pipeline.tenant_id = job.tenant_id \
         LEFT JOIN github_repositories AS repository ON repository.id = pipeline.repository_id \
           AND repository.tenant_id = pipeline.tenant_id \
         LEFT JOIN active_by_repository AS active \
           ON active.repository_id = pipeline.repository_id \
         WHERE job.tenant_id = $1 AND job.status = 'queued' \
           AND pipeline.status IN ('queued', 'running') \
           AND (repository.id IS NULL OR repository.trusted = true) \
           AND COALESCE(active.active_count, 0) < $2 \
           AND NOT EXISTS ( \
             SELECT 1 FROM jsonb_array_elements_text( \
               COALESCE(job.execution_spec->'runs_on', '[\"docker\"]'::jsonb) \
             ) AS required(label) WHERE NOT (required.label = ANY($3::text[])) \
           ) \
         ORDER BY pipeline.inserted_at ASC, job.position ASC \
         LIMIT 1 FOR UPDATE OF job SKIP LOCKED",
    )
    .bind(tenant_id)
    .bind(repository_limit)
    .bind(labels)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)
}

async fn runner_capacity_labels(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    runner_id: Uuid,
    now: DateTime<Utc>,
) -> Result<Vec<String>, PortError> {
    let runner = sqlx::query_as::<
        _,
        (
            String,
            Option<i32>,
            Option<NaiveDateTime>,
            serde_json::Value,
            Vec<String>,
        ),
    >(
        "SELECT admin_state, protocol_version, last_seen_at, capabilities, labels \
         FROM remote_runners WHERE id = $1 AND tenant_id = $2 FOR UPDATE",
    )
    .bind(runner_id)
    .bind(tenant_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?
    .ok_or(PortError::Capacity)?;
    let recent = runner
        .2
        .is_some_and(|seen| seen.and_utc() >= now - chrono::Duration::seconds(60));
    let executable = runner.3.get("docker").and_then(serde_json::Value::as_bool) == Some(true)
        || runner.3.get("native").and_then(serde_json::Value::as_bool) == Some(true);
    if runner.0 != "enabled" || runner.1 != Some(1) || !recent || !executable {
        return Err(PortError::Capacity);
    }
    let concurrency = runner
        .3
        .get("concurrency")
        .and_then(serde_json::Value::as_i64)
        .filter(|value| (1..=64).contains(value))
        .unwrap_or(1);
    let active = sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM job_attempts WHERE tenant_id = $1 AND runner_id = $2 \
         AND status IN ('queued', 'preparing', 'running', 'cancelling')",
    )
    .bind(tenant_id)
    .bind(runner_id.to_string())
    .fetch_one(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    if active >= concurrency {
        return Err(PortError::Capacity);
    }
    let mut labels = runner.4;
    for key in ["os", "architecture"] {
        if let Some(value) = runner.3.get(key).and_then(serde_json::Value::as_str)
            && !value.is_empty()
        {
            labels.push(value.into());
        }
    }
    for (key, label) in [("docker", "docker"), ("native", "native")] {
        if runner.3.get(key).and_then(serde_json::Value::as_bool) == Some(true) {
            labels.push(label.into());
        }
    }
    labels.sort();
    labels.dedup();
    Ok(labels)
}

async fn persist_claim(
    transaction: &mut Transaction<'_, Postgres>,
    tenant_id: &str,
    candidate: &ClaimCandidate,
    claim: &SchedulerClaim,
    number: i32,
    lease_expires_at: DateTime<Utc>,
) -> Result<(), PortError> {
    sqlx::query(
        "UPDATE pipelines SET status = 'running', started_at = COALESCE(started_at, $2) \
         WHERE id = $1 AND tenant_id = $3",
    )
    .bind(candidate.pipeline_id)
    .bind(claim.now)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    sqlx::query(
        "UPDATE pipeline_jobs SET status = 'running', updated_at = $2 \
         WHERE id = $1 AND tenant_id = $3",
    )
    .bind(candidate.job_id)
    .bind(claim.now)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    sqlx::query(
        "INSERT INTO job_attempts \
         (id, job_id, number, idempotency_token, status, lease_expires_at, last_sequence, \
          runner_id, inserted_at, updated_at, tenant_id) \
         VALUES ($1, $2, $3, $4, 'queued', $5, 0, $6, $7, $7, $8)",
    )
    .bind(claim.attempt_id)
    .bind(candidate.job_id)
    .bind(number)
    .bind(claim.idempotency_token)
    .bind(lease_expires_at)
    .bind(claim.runner_id.map(|id| id.to_string()))
    .bind(claim.now)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    sqlx::query(
        "INSERT INTO outbox_events \
         (id, event_type, aggregate_id, payload, occurred_at, inserted_at, tenant_id) \
         VALUES ($1, 'pipeline.projection_requested', $2, $3, $4, $4, $5)",
    )
    .bind(claim.event_id)
    .bind(candidate.pipeline_id)
    .bind(serde_json::json!({
        "pipeline_id": candidate.pipeline_id,
        "dispatch": false
    }))
    .bind(claim.now)
    .bind(tenant_id)
    .execute(&mut **transaction)
    .await
    .map_err(|_| PortError::Unavailable)?;
    Ok(())
}

async fn validate_retry_artifacts(
    transaction: &mut Transaction<'_, Postgres>,
    row: &RetryJobRow,
    tenant_id: &str,
    now: DateTime<Utc>,
) -> Result<(), PortError> {
    let mut missing = Vec::new();
    for (producer, name) in artifact_requirements(&row.execution_spec)? {
        let retained = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS( \
               SELECT 1 FROM artifacts AS artifact \
               JOIN job_attempts AS attempt ON attempt.id = artifact.attempt_id \
                 AND attempt.tenant_id = artifact.tenant_id \
               JOIN pipeline_jobs AS producer ON producer.id = attempt.job_id \
                 AND producer.tenant_id = attempt.tenant_id \
               WHERE producer.pipeline_id = $1 AND producer.job_key = $2 \
                 AND attempt.status = 'succeeded' AND artifact.name = $3 \
                 AND artifact.expires_at > $4 AND artifact.tenant_id = $5)",
        )
        .bind(row.pipeline_id)
        .bind(&producer)
        .bind(&name)
        .bind(now)
        .bind(tenant_id)
        .fetch_one(&mut **transaction)
        .await
        .map_err(|_| PortError::Unavailable)?;
        if !retained {
            missing.push(format!("{producer}/{name}"));
        }
    }
    if missing.is_empty() {
        Ok(())
    } else {
        Err(PortError::RetryInputsUnavailable(missing))
    }
}

fn artifact_requirements(
    execution_spec: &serde_json::Value,
) -> Result<Vec<(String, String)>, PortError> {
    let Some(steps) = execution_spec
        .get("steps")
        .and_then(serde_json::Value::as_array)
    else {
        return Ok(Vec::new());
    };
    let mut requirements = Vec::new();
    for step in steps {
        if step.get("kind").and_then(serde_json::Value::as_str) != Some("builtin")
            || step.get("value").and_then(serde_json::Value::as_str) != Some("artifacts/download")
        {
            continue;
        }
        let inputs = step
            .get("with")
            .and_then(serde_json::Value::as_object)
            .ok_or(PortError::InvalidData)?;
        let producer = inputs
            .get("from")
            .and_then(serde_json::Value::as_str)
            .ok_or(PortError::InvalidData)?;
        let name = inputs
            .get("name")
            .and_then(serde_json::Value::as_str)
            .ok_or(PortError::InvalidData)?;
        let requirement = (producer.to_owned(), name.to_owned());
        if !requirements.contains(&requirement) {
            requirements.push(requirement);
        }
    }
    Ok(requirements)
}

#[derive(sqlx::FromRow)]
struct PipelineRecordRow {
    id: Uuid,
    repository_id: Uuid,
    workflow_name: String,
    commit_sha: String,
    status: String,
    inserted_at: NaiveDateTime,
}

#[derive(sqlx::FromRow)]
struct RetryJobRow {
    pipeline_id: Uuid,
    status: String,
    needs: Vec<String>,
    execution_spec: serde_json::Value,
    pipeline_status: String,
}

#[derive(sqlx::FromRow)]
struct ClaimCandidate {
    job_id: Uuid,
    pipeline_id: Uuid,
    pipeline_status: String,
}

#[derive(sqlx::FromRow)]
struct AttemptEventRow {
    id: Uuid,
    job_id: Uuid,
    number: i32,
    idempotency_token: Uuid,
    status: String,
    lease_expires_at: NaiveDateTime,
    last_sequence: i32,
    result_reason: Option<String>,
    pipeline_id: Uuid,
}

#[derive(sqlx::FromRow)]
struct RunnerEventReceiptRow {
    attempt_id: Uuid,
    sequence: i32,
    status: String,
    reason: Option<String>,
}

#[derive(sqlx::FromRow)]
struct RemoteOfferRow {
    attempt_id: Uuid,
    idempotency_token: Uuid,
    job_id: Uuid,
    job_key: String,
    needs: Vec<String>,
    execution_spec: serde_json::Value,
    pipeline_id: Uuid,
    correlation_id: String,
    commit_sha: String,
    repository_id: Uuid,
    source_ref: Option<String>,
    trigger: String,
    started_at: Option<NaiveDateTime>,
    inserted_at: NaiveDateTime,
}

#[derive(sqlx::FromRow)]
struct PendingOutboxRow {
    id: Uuid,
    event_type: String,
    aggregate_id: Uuid,
    payload: serde_json::Value,
    delivery_attempts: i32,
}

#[derive(sqlx::FromRow)]
struct DurableJobRow {
    id: Uuid,
    source_event_id: Uuid,
    kind: String,
    payload: serde_json::Value,
    claim_token: Uuid,
    attempts: i32,
}

impl AttemptEventRow {
    fn projection(&self) -> AttemptProjection {
        AttemptProjection {
            id: self.id,
            job_id: self.job_id,
            number: self.number,
            idempotency_token: self.idempotency_token,
            status: self.status.clone(),
            lease_expires_at: self.lease_expires_at.and_utc(),
            last_sequence: self.last_sequence,
            result_reason: self.result_reason.clone(),
        }
    }
}

#[derive(sqlx::FromRow)]
struct JobGraphRow {
    id: Uuid,
    job_key: String,
    status: String,
    needs: Vec<String>,
    execution_spec: serde_json::Value,
}

#[derive(sqlx::FromRow)]
struct ExistingCreationRow {
    repository_id: Uuid,
    workflow_name: String,
    commit_sha: String,
    source_ref: Option<String>,
    trigger: String,
    inputs: serde_json::Value,
    scheduled_for: Option<NaiveDateTime>,
    status: String,
    inserted_at: NaiveDateTime,
    path: String,
    source: String,
    included_sources: serde_json::Value,
}

impl ExistingCreationRow {
    fn projection(&self, id: Uuid) -> Result<PipelineProjection, PortError> {
        let status =
            PipelineState::try_from(self.status.as_str()).map_err(|_| PortError::InvalidData)?;
        Ok(PipelineProjection {
            id,
            repository_id: self.repository_id,
            workflow_name: self.workflow_name.clone(),
            commit_sha: self.commit_sha.clone(),
            status: status.as_str().into(),
            inserted_at: self.inserted_at.and_utc(),
        })
    }
}

#[derive(sqlx::FromRow)]
struct UserRow {
    id: Uuid,
    email: String,
    role: String,
    disabled: bool,
    inserted_at: NaiveDateTime,
}

#[derive(sqlx::FromRow)]
struct LocalIdentityRow {
    id: Uuid,
    email: String,
    role: String,
    disabled: bool,
    inserted_at: NaiveDateTime,
    password_hash: String,
}

fn user_from_parts(
    id: Uuid,
    email: String,
    role: &str,
    disabled: bool,
    inserted_at: NaiveDateTime,
) -> Result<User, PortError> {
    Ok(User {
        id,
        email,
        role: Role::try_from(role).map_err(|_| PortError::InvalidData)?,
        disabled,
        inserted_at: inserted_at.and_utc(),
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
            inserted_at: row.inserted_at.and_utc(),
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
            inserted_at: Utc::now().naive_utc(),
        };

        assert!(matches!(
            PipelineProjection::try_from(row),
            Err(PersistenceError::UnknownPipelineState(_))
        ));
    }
}
