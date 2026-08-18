use std::sync::Arc;

use argon2::{
    Argon2,
    password_hash::{PasswordHasher, SaltString},
};
use chrono::{Duration, Utc};
use robine_application::ControlPlane;
use robine_core::identity::Role;
use robine_persistence::{Database, Readiness};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

#[tokio::test]
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

    let database = Arc::new(database);
    let control_plane = ControlPlane::new(database.clone(), database)
        .with_bootstrap_token("bootstrap-once", Utc::now() + Duration::minutes(5));
    let authentication = control_plane.authenticate(&token).await;
    let repeated_bootstrap = control_plane
        .bootstrap_administrator(
            "bootstrap-once",
            "other-admin@example.invalid",
            "another-long-password",
        )
        .await;
    let local_session = control_plane
        .authenticate_local(&format!("RUST-{user_id}@EXAMPLE.INVALID"), password)
        .await
        .expect("authenticate an existing Argon2 credential case-insensitively");
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

    let user = authentication.expect("resolve the Phoenix-compatible session digest");
    assert_eq!(user.id, user_id);
    assert_eq!(user.role, Role::Viewer);
    assert_eq!(local_session.user.id, user_id);
    assert!(revoked_authentication.is_err());
    assert!(matches!(
        repeated_bootstrap,
        Err(robine_application::ApplicationError::AlreadyBootstrapped)
    ));
}
