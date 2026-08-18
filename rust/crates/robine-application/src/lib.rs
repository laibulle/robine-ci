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
    identity::User,
    pipelines::PipelineProjection,
    ports::{IdentityRepository, PipelineRepository, PortError},
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
    #[error("authentication is required")]
    Unauthenticated,
    #[error("operation is forbidden")]
    Forbidden,
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
            Err(PortError::AlreadyBootstrapped | PortError::Unavailable) => {
                return Err(ApplicationError::Unavailable);
            }
        };

        let mut token_bytes = [0_u8; 32];
        getrandom::fill(&mut token_bytes).map_err(|_| ApplicationError::Unavailable)?;
        let token = URL_SAFE_NO_PAD.encode(token_bytes);
        let digest = Sha256::digest(token.as_bytes());
        let now = Utc::now();
        let expires_at = now + chrono::Duration::days(7);

        self.identities
            .create_session(
                Uuid::new_v4(),
                identity.user.id,
                digest.as_slice(),
                expires_at,
                now,
            )
            .await
            .map_err(|_| ApplicationError::Unavailable)?;

        Ok(IssuedSession {
            token,
            expires_at,
            user: identity.user,
        })
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
        PortError::AlreadyBootstrapped | PortError::Unavailable => ApplicationError::Unavailable,
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
