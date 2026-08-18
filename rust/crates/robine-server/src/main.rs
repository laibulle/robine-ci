use std::{io, sync::Arc};

use actix_web::{App, HttpServer, web};
use chrono::{Duration, Utc};
use robine_application::ControlPlane;
use robine_execution::{DockerCli, DockerConfig};
use robine_oidc::OidcClient;
use robine_persistence::Database;
use robine_secrets::AesGcmKeyring;
use robine_server::AppState;
use robine_source::HttpArchiveFetcher;
use robine_storage::{LocalBlobStore, StorageQuotas};
use tokio::sync::watch;

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
    let source_fetcher = HttpArchiveFetcher::new(
        std::env::var("GITHUB_APP_ID").ok(),
        std::env::var("GITHUB_APP_PRIVATE_KEY")
            .ok()
            .map(|value| value.replace("\\n", "\n")),
        std::env::var("GITLAB_URL").ok(),
        std::env::var("GITLAB_TOKEN").ok(),
        std::env::var("FORGEJO_URL").ok(),
        std::env::var("FORGEJO_TOKEN").ok(),
    )
    .map_err(io::Error::other)?;
    control_plane = control_plane.with_source_runtime(database.clone(), Arc::new(source_fetcher));
    let configured_storage_root =
        std::env::var("ROBINE_STORAGE_ROOT").unwrap_or_else(|_| "var/storage".into());
    let storage_path = std::path::PathBuf::from(configured_storage_root);
    let storage_root = if storage_path.is_absolute() {
        storage_path
    } else {
        std::env::current_dir()?.join(storage_path)
    };
    let max_object_bytes = environment_usize("ROBINE_STORAGE_MAX_OBJECT_BYTES", 1_073_741_824)?;
    let storage_quotas = StorageQuotas {
        instance_bytes: environment_i64("ROBINE_STORAGE_INSTANCE_QUOTA_BYTES", 53_687_091_200)?,
        repository_bytes: environment_i64("ROBINE_STORAGE_REPOSITORY_QUOTA_BYTES", 10_737_418_240)?,
    };
    if storage_quotas.repository_bytes > storage_quotas.instance_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "repository storage quota exceeds instance quota",
        ));
    }
    let blob_store =
        LocalBlobStore::new(storage_root, max_object_bytes).map_err(io::Error::other)?;
    control_plane =
        control_plane.with_storage_runtime(database.clone(), Arc::new(blob_store), storage_quotas);
    control_plane = control_plane.with_execution_runner(Arc::new(DockerCli::new(DockerConfig {
        instance: std::env::var("ROBINE_RUNNER_RESOURCE_NAMESPACE")
            .unwrap_or_else(|_| "production".into()),
        ..DockerConfig::default()
    })));
    let single_secret_key = std::env::var("ROBINE_CI_SECRET_KEY").ok();
    let secret_keys = std::env::var("ROBINE_CI_SECRET_KEYS").ok();
    if single_secret_key.is_some() || secret_keys.is_some() {
        let key_version = std::env::var("ROBINE_CI_SECRET_KEY_VERSION")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .unwrap_or(1);
        let keyring = AesGcmKeyring::from_encoded(
            single_secret_key.as_deref(),
            secret_keys.as_deref(),
            key_version,
        )
        .map_err(io::Error::other)?;
        control_plane = control_plane.with_secret_runtime(database.clone(), Arc::new(keyring));
    }
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
    let state = web::Data::new(AppState::new(database, control_plane.clone()));

    let (shutdown_sender, shutdown_receiver) = watch::channel(false);
    let worker_control_plane = control_plane.clone();
    let outbox_worker = tokio::spawn(run_outbox_worker(
        worker_control_plane,
        shutdown_receiver.clone(),
    ));
    let execution_worker = tokio::spawn(run_execution_worker(
        control_plane.clone(),
        shutdown_receiver,
    ));
    let server = HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .configure(robine_server::configure)
    })
    .bind(bind_address)?
    .run();
    let result = server.await;
    let _ = shutdown_sender.send(true);
    let _ = outbox_worker.await;
    let _ = execution_worker.await;
    result
}

fn environment_usize(name: &str, default: usize) -> io::Result<usize> {
    std::env::var(name).ok().map_or(Ok(default), |value| {
        value
            .parse::<usize>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("invalid {name}")))
    })
}

fn environment_i64(name: &str, default: i64) -> io::Result<i64> {
    std::env::var(name).ok().map_or(Ok(default), |value| {
        value
            .parse::<i64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("invalid {name}")))
    })
}

async fn run_execution_worker(
    control_plane: Arc<ControlPlane>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(250));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let _ = control_plane.process_all_tenant_executions().await;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}

async fn run_outbox_worker(control_plane: Arc<ControlPlane>, mut shutdown: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(std::time::Duration::from_millis(250));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let _ = control_plane.process_all_tenant_outboxes(25).await;
                let _ = control_plane.process_all_tenant_dispatches(25).await;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}
