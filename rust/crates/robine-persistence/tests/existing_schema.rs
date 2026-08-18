use std::sync::Arc;

use argon2::{
    Argon2,
    password_hash::{PasswordHasher, SaltString},
};
use async_trait::async_trait;
use chrono::{Duration, Utc};
use robine_application::{ApplicationError, ControlPlane};
use robine_core::{
    identity::{OidcAuthorization, OidcClaims, Role, User},
    ports::{IdentityRepository, OidcProvider, PortError},
};
use robine_persistence::{Database, Readiness};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

struct FakeOidc(OidcClaims);

#[async_trait]
impl OidcProvider for FakeOidc {
    async fn start(&self) -> Result<OidcAuthorization, PortError> {
        Ok(OidcAuthorization {
            url: "https://issuer.example/authorize".into(),
            state: "state".into(),
        })
    }

    async fn complete(&self, _code: &str, _state: &str) -> Result<OidcClaims, PortError> {
        Ok(self.0.clone())
    }
}

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn reads_the_existing_ecto_schema_when_configured() {
    let Ok(database_url) = std::env::var("ROBINE_DATABASE_INTEGRATION_URL") else {
        return;
    };

    let database = Database::connect(&database_url, 2)
        .await
        .expect("connect to the migrated Robine database");

    database.ready().await.expect("database is ready");
    database
        .list_pipelines("standalone", 10)
        .await
        .expect("read pipelines through the existing schema and tenant policy");

    let fixture_pool = PgPool::connect(&database_url)
        .await
        .expect("connect fixture pool");
    let user_id = Uuid::new_v4();
    let session_id = Uuid::new_v4();
    let credential_id = Uuid::new_v4();
    let token = format!("rust-session-{session_id}");
    let digest = Sha256::digest(token.as_bytes());
    let password = "correct horse battery staple";
    let password_hash = Argon2::default()
        .hash_password(
            password.as_bytes(),
            &SaltString::encode_b64(b"ecto-compatible-salt").expect("valid test salt"),
        )
        .expect("hash test password")
        .to_string();

    sqlx::query(
        "INSERT INTO users (id, email, role, disabled, inserted_at) \
         VALUES ($1, $2, 'viewer', false, NOW())",
    )
    .bind(user_id)
    .bind(format!("rust-{user_id}@example.invalid"))
    .execute(&fixture_pool)
    .await
    .expect("insert compatibility user");
    sqlx::query(
        "INSERT INTO local_credentials (id, user_id, password_hash, inserted_at) \
         VALUES ($1, $2, $3, NOW())",
    )
    .bind(credential_id)
    .bind(user_id)
    .bind(password_hash)
    .execute(&fixture_pool)
    .await
    .expect("insert compatible Argon2 credential");
    sqlx::query(
        "INSERT INTO sessions (id, user_id, token_digest, expires_at, inserted_at) \
         VALUES ($1, $2, $3, NOW() + INTERVAL '5 minutes', NOW())",
    )
    .bind(session_id)
    .bind(user_id)
    .bind(digest.as_slice())
    .execute(&fixture_pool)
    .await
    .expect("insert compatibility session");

    let oidc_user_id = Uuid::new_v4();
    let oidc_claims = OidcClaims {
        issuer: "https://issuer.example".into(),
        subject: format!("subject-{oidc_user_id}"),
        email: format!("oidc-{oidc_user_id}@example.invalid"),
        email_verified: true,
    };
    let oidc_user = database
        .find_or_provision_oidc_user(&oidc_claims, oidc_user_id, Utc::now())
        .await
        .expect("provision verified OIDC identity");
    let mut renamed_claims = oidc_claims.clone();
    renamed_claims.email = "renamed@example.invalid".into();
    let stable_oidc_user = database
        .find_or_provision_oidc_user(&renamed_claims, Uuid::new_v4(), Utc::now())
        .await
        .expect("resolve existing OIDC identity by issuer and subject");
    let collision = database
        .find_or_provision_oidc_user(
            &OidcClaims {
                issuer: oidc_claims.issuer.clone(),
                subject: "different-subject".into(),
                email: format!("rust-{user_id}@example.invalid"),
                email_verified: true,
            },
            Uuid::new_v4(),
            Utc::now(),
        )
        .await;

    let database = Arc::new(database);
    let control_plane = ControlPlane::new(database.clone(), database)
        .with_bootstrap_token("bootstrap-once", Utc::now() + Duration::minutes(5))
        .with_oidc_provider(Arc::new(FakeOidc(oidc_claims.clone())));
    let authentication = control_plane.authenticate(&token).await;
    let repeated_bootstrap = control_plane
        .bootstrap_administrator(
            "bootstrap-once",
            "other-admin@example.invalid",
            "another-long-password",
        )
        .await;
    let first_admin_id = Uuid::new_v4();
    let second_admin_id = Uuid::new_v4();
    let admin_inserted_at = Utc::now();
    sqlx::query(
        "INSERT INTO users (id, email, role, disabled, inserted_at) \
         VALUES ($1, $2, 'administrator', false, $3)",
    )
    .bind(first_admin_id)
    .bind(format!("first-admin-{first_admin_id}@example.invalid"))
    .bind(admin_inserted_at)
    .execute(&fixture_pool)
    .await
    .expect("insert first administrator");
    let administrator = User {
        id: first_admin_id,
        email: format!("first-admin-{first_admin_id}@example.invalid"),
        role: Role::Administrator,
        disabled: false,
        inserted_at: admin_inserted_at,
    };
    let users = control_plane
        .list_users(&administrator)
        .await
        .expect("administrator lists users");
    let last_admin_change = control_plane
        .change_user_role(&administrator, first_admin_id, Role::Viewer)
        .await;
    sqlx::query(
        "INSERT INTO users (id, email, role, disabled, inserted_at) \
         VALUES ($1, $2, 'administrator', false, NOW())",
    )
    .bind(second_admin_id)
    .bind(format!("second-admin-{second_admin_id}@example.invalid"))
    .execute(&fixture_pool)
    .await
    .expect("insert second administrator");
    let changed_user = control_plane
        .change_user_role(&administrator, first_admin_id, Role::Viewer)
        .await
        .expect("demote administrator when another remains");
    let local_session = control_plane
        .authenticate_local(&format!("RUST-{user_id}@EXAMPLE.INVALID"), password)
        .await
        .expect("authenticate an existing Argon2 credential case-insensitively");
    let oidc_authorization = control_plane.start_oidc().await.expect("start OIDC");
    let oidc_session = control_plane
        .complete_oidc("code", &oidc_authorization.state)
        .await
        .expect("complete OIDC and issue local session");
    control_plane
        .revoke_session(&local_session.token)
        .await
        .expect("revoke the issued session");
    let revoked_authentication = control_plane.authenticate(&local_session.token).await;

    sqlx::query("DELETE FROM sessions WHERE user_id = $1")
        .bind(user_id)
        .execute(&fixture_pool)
        .await
        .expect("remove compatibility sessions");
    sqlx::query("DELETE FROM local_credentials WHERE id = $1")
        .bind(credential_id)
        .execute(&fixture_pool)
        .await
        .expect("remove compatibility credential");
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(&fixture_pool)
        .await
        .expect("remove compatibility user");
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(oidc_user_id)
        .execute(&fixture_pool)
        .await
        .expect("remove OIDC user fixture");
    sqlx::query("DELETE FROM users WHERE id = ANY($1)")
        .bind(vec![first_admin_id, second_admin_id])
        .execute(&fixture_pool)
        .await
        .expect("remove administrator fixtures");

    let user = authentication.expect("resolve the Phoenix-compatible session digest");
    assert_eq!(user.id, user_id);
    assert_eq!(user.role, Role::Viewer);
    assert_eq!(local_session.user.id, user_id);
    assert!(revoked_authentication.is_err());
    assert!(matches!(
        repeated_bootstrap,
        Err(robine_application::ApplicationError::AlreadyBootstrapped)
    ));
    assert!(users.iter().any(|user| user.id == first_admin_id));
    assert!(matches!(
        last_admin_change,
        Err(ApplicationError::LastAdministrator)
    ));
    assert_eq!(changed_user.role, Role::Viewer);
    assert_eq!(oidc_user.id, oidc_user_id);
    assert_eq!(oidc_session.user.id, oidc_user_id);
    assert_eq!(stable_oidc_user.id, oidc_user_id);
    assert_eq!(stable_oidc_user.email, oidc_claims.email);
    assert!(matches!(
        collision,
        Err(robine_core::ports::PortError::OidcEmailCollision)
    ));
}
