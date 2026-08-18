use std::{io, sync::Arc};

use actix_web::{App, HttpServer, web};
use chrono::{Duration, Utc};
use robine_application::{ControlPlane, RetentionConfig};
use robine_execution::{DockerCli, DockerConfig};
use robine_oidc::OidcClient;
use robine_persistence::Database;
use robine_secrets::AesGcmKeyring;
use robine_server::{AppState, WebhookConfiguration};
use robine_source::HttpArchiveFetcher;
use robine_storage::{
    BlobStore, LocalBlobStore, S3BlobStore, S3Config, S3Encryption, StorageQuotas,
};
use sha2::{Digest, Sha256};
use tokio::sync::watch;

#[actix_web::main]
async fn main() -> io::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("robine-server {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    let bind_address = std::env::var("ROBINE_BIND").unwrap_or_else(|_| "127.0.0.1:4000".into());
    let database_url = std::env::var("DATABASE_URL")
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "DATABASE_URL must be set"))?;
    let database = Arc::new(
        Database::connect(&database_url, 10)
            .await
            .map_err(io::Error::other)?,
    );
    database
        .bootstrap_schema()
        .await
        .map_err(io::Error::other)?;
    let mut control_plane = ControlPlane::new(database.clone(), database.clone());
    let public_url =
        std::env::var("ROBINE_PUBLIC_URL").unwrap_or_else(|_| "http://localhost:4000".into());
    control_plane = control_plane.with_workflow_limits(robine_workflows::WorkflowLimits {
        max_bytes: environment_usize("ROBINE_WORKFLOW_MAX_BYTES", 262_144)?,
        max_jobs: environment_usize("ROBINE_WORKFLOW_MAX_JOBS", 64)?,
        max_steps_per_job: environment_usize("ROBINE_WORKFLOW_MAX_STEPS_PER_JOB", 128)?,
        max_total_steps: environment_usize("ROBINE_WORKFLOW_MAX_TOTAL_STEPS", 512)?,
        max_graph_depth: environment_usize("ROBINE_WORKFLOW_MAX_GRAPH_DEPTH", 16)?,
    });
    let source_fetcher = Arc::new(
        HttpArchiveFetcher::new(
            std::env::var("GITHUB_APP_ID").ok(),
            std::env::var("GITHUB_APP_PRIVATE_KEY")
                .ok()
                .map(|value| value.replace("\\n", "\n")),
            std::env::var("GITLAB_URL").ok(),
            std::env::var("GITLAB_TOKEN").ok(),
            std::env::var("FORGEJO_URL").ok(),
            std::env::var("FORGEJO_TOKEN").ok(),
            &public_url,
        )
        .map_err(io::Error::other)?,
    );
    control_plane = control_plane
        .with_source_runtime(database.clone(), source_fetcher.clone())
        .with_source_inspector(source_fetcher.clone())
        .with_status_projector(source_fetcher);
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
    let (blob_store, storage_backend, storage_namespace_digest) =
        configure_blob_store(storage_root, max_object_bytes).await?;
    let storage_migration_ack = std::env::var("ROBINE_STORAGE_BACKEND_MIGRATION_ACK").ok();
    for tenant_id in database.storage_tenants().await.map_err(io::Error::other)? {
        database
            .verify_storage_backend(
                &tenant_id,
                &storage_backend,
                &storage_namespace_digest,
                storage_migration_ack.as_deref(),
            )
            .await
            .map_err(io::Error::other)?;
    }
    control_plane =
        control_plane.with_storage_runtime(database.clone(), blob_store, storage_quotas);
    control_plane = control_plane.with_retention_runtime(
        database.clone(),
        RetentionConfig {
            log_seconds: environment_i64("ROBINE_LOG_RETENTION_SECONDS", 2_592_000)?,
            gc_grace_seconds: environment_i64("ROBINE_GC_GRACE_SECONDS", 3_600)?,
            batch_size: environment_i64("ROBINE_RETENTION_BATCH_SIZE", 1_000)?,
        },
    );
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
    ) && let Ok(provider) = OidcClient::discover(
        &issuer,
        client_id,
        client_secret,
        format!("{}/auth/oidc/callback", public_url.trim_end_matches('/')),
    )
    .await
    {
        control_plane = control_plane.with_oidc_provider(Arc::new(provider));
    }
    let control_plane = Arc::new(control_plane);
    let webhook_configuration = WebhookConfiguration::new(
        std::env::var("GITHUB_WEBHOOK_SECRET").ok(),
        std::env::var("GITLAB_WEBHOOK_SECRET").ok(),
        std::env::var("FORGEJO_WEBHOOK_SECRET").ok(),
    )
    .with_provider_instances(
        std::env::var("GITLAB_URL").ok(),
        std::env::var("FORGEJO_URL").ok(),
    );
    let state = web::Data::new(
        AppState::new(database, control_plane.clone()).with_webhooks(webhook_configuration),
    );

    let (shutdown_sender, shutdown_receiver) = watch::channel(false);
    let worker_control_plane = control_plane.clone();
    let outbox_worker = tokio::spawn(run_outbox_worker(
        worker_control_plane,
        shutdown_receiver.clone(),
    ));
    let execution_worker = tokio::spawn(run_execution_worker(
        control_plane.clone(),
        shutdown_receiver.clone(),
    ));
    let lease_worker = tokio::spawn(run_lease_worker(
        control_plane.clone(),
        shutdown_receiver.clone(),
    ));
    let schedule_worker = tokio::spawn(run_schedule_worker(
        control_plane.clone(),
        shutdown_receiver.clone(),
    ));
    let retention_worker = tokio::spawn(run_retention_worker(
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
    let _ = lease_worker.await;
    let _ = schedule_worker.await;
    let _ = retention_worker.await;
    result
}

async fn configure_blob_store(
    storage_root: std::path::PathBuf,
    max_object_bytes: usize,
) -> io::Result<(Arc<dyn BlobStore>, String, String)> {
    match std::env::var("ROBINE_BLOB_STORE")
        .unwrap_or_else(|_| "local".into())
        .as_str()
    {
        "local" => {
            let locator = format!("local:{}", storage_root.display());
            let store =
                LocalBlobStore::new(storage_root, max_object_bytes).map_err(io::Error::other)?;
            Ok((
                Arc::new(store),
                "local".into(),
                storage_namespace_digest(&locator),
            ))
        }
        "s3" => {
            let endpoint = required_environment("ROBINE_S3_ENDPOINT")?;
            let bucket = required_environment("ROBINE_S3_BUCKET")?;
            let region = required_environment("ROBINE_S3_REGION")?;
            let prefix = std::env::var("ROBINE_S3_PREFIX").unwrap_or_default();
            let encryption = if let Ok(key_id) = std::env::var("ROBINE_S3_KMS_KEY_ID") {
                if key_id.is_empty() {
                    return Err(invalid_environment("ROBINE_S3_KMS_KEY_ID"));
                }
                S3Encryption::Kms { key_id }
            } else {
                match std::env::var("ROBINE_S3_SERVER_SIDE_ENCRYPTION")
                    .unwrap_or_else(|_| "none".into())
                    .as_str()
                {
                    "none" => S3Encryption::None,
                    "AES256" => S3Encryption::Aes256,
                    _ => return Err(invalid_environment("ROBINE_S3_SERVER_SIDE_ENCRYPTION")),
                }
            };
            let part_timeout = std::time::Duration::from_millis(environment_u64(
                "ROBINE_S3_PART_TIMEOUT_MS",
                60_000,
            )?);
            let store = S3BlobStore::new(S3Config {
                endpoint: endpoint.clone(),
                region,
                bucket: bucket.clone(),
                prefix: prefix.clone(),
                path_style: environment_bool("ROBINE_S3_PATH_STYLE", false)?,
                allow_http_loopback: environment_bool("ROBINE_S3_ALLOW_HTTP_LOOPBACK", false)?,
                max_object_bytes,
                part_size: environment_usize("ROBINE_S3_PART_SIZE_BYTES", 8_388_608)?,
                request_timeout: std::time::Duration::from_millis(environment_u64(
                    "ROBINE_S3_REQUEST_TIMEOUT_MS",
                    120_000,
                )?),
                attempt_timeout: part_timeout,
                connect_timeout: std::time::Duration::from_millis(environment_u64(
                    "ROBINE_S3_CONNECT_TIMEOUT_MS",
                    5_000,
                )?),
                spool_root: storage_root.join(".s3-spool"),
                encryption,
            })
            .await
            .map_err(io::Error::other)?;
            store.health().await.map_err(io::Error::other)?;
            let locator = format!(
                "s3:{}/{}/{}",
                endpoint.trim_end_matches('/'),
                bucket,
                prefix.trim_matches('/')
            );
            Ok((
                Arc::new(store),
                "s3".into(),
                storage_namespace_digest(&locator),
            ))
        }
        _ => Err(invalid_environment("ROBINE_BLOB_STORE")),
    }
}

fn storage_namespace_digest(locator: &str) -> String {
    format!("{:x}", Sha256::digest(locator.as_bytes()))
}

fn required_environment(name: &str) -> io::Result<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| invalid_environment(name))
}

fn environment_bool(name: &str, default: bool) -> io::Result<bool> {
    match std::env::var(name) {
        Ok(value) if matches!(value.as_str(), "1" | "true") => Ok(true),
        Ok(value) if matches!(value.as_str(), "0" | "false") => Ok(false),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Ok(_) | Err(_) => Err(invalid_environment(name)),
    }
}

fn environment_u64(name: &str, default: u64) -> io::Result<u64> {
    std::env::var(name).ok().map_or(Ok(default), |value| {
        value
            .parse::<u64>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| invalid_environment(name))
    })
}

fn invalid_environment(name: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, format!("invalid {name}"))
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
                let _ = control_plane.process_all_tenant_status_projections(25).await;
                let _ = control_plane.process_all_tenant_source_control(25).await;
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

async fn run_lease_worker(control_plane: Arc<ControlPlane>, mut shutdown: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let _ = control_plane.reconcile_all_expired_attempts(100).await;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}

async fn run_schedule_worker(
    control_plane: Arc<ControlPlane>,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut interval = tokio::time::interval(std::time::Duration::from_mins(1));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let _ = control_plane.reconcile_all_tenant_schedules(chrono::Utc::now()).await;
                let _ = control_plane.reconcile_all_status_projection_jobs(100).await;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}

async fn run_retention_worker(
    control_plane: Arc<ControlPlane>,
    mut shutdown: watch::Receiver<bool>,
) {
    let start = tokio::time::Instant::now() + std::time::Duration::from_hours(1);
    let mut interval = tokio::time::interval_at(start, std::time::Duration::from_hours(1));
    loop {
        tokio::select! {
            _ = interval.tick() => {
                let _ = control_plane.process_all_tenant_retention().await;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }
}
