//! Framework-independent orchestration for Robine use cases.

use std::sync::{Arc, LazyLock};

use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::Utc;
use robine_core::{
    execution_context::{Actor, ActorKind, Capability, ExecutionContext},
    identity::{OidcAuthorization, Role, User},
    pipelines::PipelineProjection,
    ports::{IdentityRepository, OidcProvider, PipelineRepository, PortError},
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
}

struct BootstrapConfig {
    token_digest: [u8; 32],
    expires_at: chrono::DateTime<Utc>,
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
    #[error("application dependency is unavailable")]
    Unavailable,
}

#[derive(Debug, serde::Serialize)]
pub struct IssuedSession {
    pub token: String,
    pub expires_at: chrono::DateTime<Utc>,
    pub user: User,
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
        }
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
}

fn authentication_error(error: &PortError) -> ApplicationError {
    match error {
        PortError::NotFound | PortError::InvalidData => ApplicationError::Unauthenticated,
        PortError::AlreadyBootstrapped
        | PortError::LastAdministrator
        | PortError::OidcEmailCollision
        | PortError::InvalidTransition
        | PortError::Unavailable => ApplicationError::Unavailable,
    }
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
