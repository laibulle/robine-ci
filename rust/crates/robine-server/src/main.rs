use std::{io, sync::Arc};

use actix_web::{App, HttpServer, web};
use chrono::{Duration, Utc};
use robine_application::ControlPlane;
use robine_oidc::OidcClient;
use robine_persistence::Database;
use robine_server::AppState;

#[actix_web::main]
async fn main() -> io::Result<()> {
    let bind_address = std::env::var("ROBINE_BIND").unwrap_or_else(|_| "127.0.0.1:4000".into());
    let database_url = std::env::var("DATABASE_URL")
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "DATABASE_URL must be set"))?;
    let database = Arc::new(
        Database::connect(&database_url, 10)
            .await
            .map_err(io::Error::other)?,
    );
    let mut control_plane = ControlPlane::new(database.clone(), database.clone());
    if let Ok(token) = std::env::var("ROBINE_BOOTSTRAP_TOKEN") {
        control_plane =
            control_plane.with_bootstrap_token(&token, Utc::now() + Duration::minutes(15));
    }
    if let Ok(secret_key_base) = std::env::var("SECRET_KEY_BASE") {
        control_plane = control_plane.with_runner_secret_key_base(&secret_key_base);
    }
    if let (Ok(issuer), Ok(client_id), Ok(client_secret)) = (
        std::env::var("OIDC_ISSUER"),
        std::env::var("OIDC_CLIENT_ID"),
        std::env::var("OIDC_CLIENT_SECRET"),
    ) {
        let public_url =
            std::env::var("ROBINE_PUBLIC_URL").unwrap_or_else(|_| "http://localhost:4000".into());
        if let Ok(provider) = OidcClient::discover(
            &issuer,
            client_id,
            client_secret,
            format!("{}/auth/oidc/callback", public_url.trim_end_matches('/')),
        )
        .await
        {
            control_plane = control_plane.with_oidc_provider(Arc::new(provider));
        }
    }
    let control_plane = Arc::new(control_plane);
    let state = web::Data::new(AppState::new(database, control_plane));

    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .configure(robine_server::configure)
    })
    .bind(bind_address)?
    .run()
    .await
}
