use async_trait::async_trait;
use reqwest::Client;
use robine_execution::{
    CancellationSignal, DockerCli, DockerConfig, ExecutionControl, ExecutionError,
    ExecutionSpecification, ExecutionStatus, OutputChannel, OutputChunk, OutputSink, StepKind,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    env, fs, io,
    path::{Path, PathBuf},
    process::ExitCode,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Deserialize, Serialize)]
struct Config {
    server_url: String,
    runner_id: Uuid,
    credential: String,
    name: String,
}

#[derive(Deserialize)]
struct Enrollment {
    runner_id: Uuid,
    credential: String,
}

#[derive(Deserialize)]
struct Heartbeat {
    #[serde(default)]
    pending_offer_attempt_ids: Vec<Uuid>,
    #[serde(default)]
    cancellation_requested_attempt_ids: Vec<Uuid>,
}

#[tokio::main]
async fn main() -> ExitCode {
    match command(env::args().skip(1).collect()).await {
        Ok(message) => {
            println!("{message}");
            ExitCode::SUCCESS
        }
        Err((code, message)) => {
            eprintln!("{message}");
            ExitCode::from(code)
        }
    }
}

async fn command(arguments: Vec<String>) -> Result<String, (u8, String)> {
    match arguments.as_slice() {
        [command] if command == "version" || command == "--version" => {
            Ok(format!("robine-runner {}", env!("CARGO_PKG_VERSION")))
        }
        [command, rest @ ..] if command == "enroll" => enroll(rest).await,
        [command, rest @ ..] if command == "start" => start(rest).await,
        _ => Err((
            64,
            "Usage: robine-runner <version|enroll|start> [options]".into(),
        )),
    }
}

async fn enroll(arguments: &[String]) -> Result<String, (u8, String)> {
    let server = option(arguments, "--server")?;
    let name = option(arguments, "--name")?;
    let path = PathBuf::from(option(arguments, "--config")?);
    let force = arguments.iter().any(|argument| argument == "--force");
    if path.exists() && !force {
        return Err((
            4,
            "Config already exists; pass --force to replace it.".into(),
        ));
    }
    ensure_secure_server(&server)?;
    let token = env::var("ROBINE_RUNNER_ENROLLMENT_TOKEN")
        .map_err(|_| (64, "ROBINE_RUNNER_ENROLLMENT_TOKEN is required".into()))?;
    let response = Client::new()
        .post(format!(
            "{}/api/v1/runners/enroll",
            server.trim_end_matches('/')
        ))
        .json(&serde_json::json!({"token":token,"name":name}))
        .send()
        .await
        .map_err(network)?;
    if response.status() != reqwest::StatusCode::CREATED {
        return Err((
            3,
            format!("Enrollment failed with HTTP {}", response.status()),
        ));
    }
    let enrollment: Enrollment = response.json().await.map_err(network)?;
    let config = Config {
        server_url: server,
        runner_id: enrollment.runner_id,
        credential: enrollment.credential,
        name,
    };
    write_private(
        &path,
        &serde_json::to_vec(&config).map_err(|error| (3, error.to_string()))?,
    )
    .map_err(|error| (3, error.to_string()))?;
    Ok(format!(
        "Runner enrolled as {}. Credential stored in {}.",
        config.runner_id,
        path.display()
    ))
}

async fn start(arguments: &[String]) -> Result<String, (u8, String)> {
    let path = PathBuf::from(option(arguments, "--config")?);
    private_file(&path)?;
    let config: Config = serde_json::from_slice(&fs::read(&path).map_err(io_error)?)
        .map_err(|error| (3, format!("Invalid config: {error}")))?;
    ensure_secure_server(&config.server_url)?;
    let client = Client::builder()
        .timeout(Duration::from_mins(1))
        .build()
        .map_err(network)?;
    register_session(&client, &config).await?;
    println!(
        "Runner {} connected to {}",
        config.runner_id, config.server_url
    );
    loop {
        let heartbeat: Heartbeat = machine(
            client.post(url(&config, "/api/v1/runners/heartbeat")),
            &config,
        )
        .json(&serde_json::json!({"lease_seconds":60}))
        .send()
        .await
        .map_err(network)?
        .error_for_status()
        .map_err(network)?
        .json()
        .await
        .map_err(network)?;
        if !heartbeat.cancellation_requested_attempt_ids.is_empty() {
            eprintln!(
                "Cancellation requested for {} active attempts",
                heartbeat.cancellation_requested_attempt_ids.len()
            );
        }
        for attempt_id in heartbeat.pending_offer_attempt_ids {
            execute_offer(&client, &config, attempt_id).await?;
        }
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

async fn register_session(client: &Client, config: &Config) -> Result<(), (u8, String)> {
    machine(client.post(url(config, "/api/v1/runners/session")), config).json(&serde_json::json!({"supported_protocol_versions":[1],"software_version":env!("CARGO_PKG_VERSION"),"capabilities":{"docker":true,"concurrency":1,"labels":["docker","linux"]}})).send().await.map_err(network)?.error_for_status().map_err(network)?;
    Ok(())
}

#[allow(clippy::too_many_lines)]
async fn execute_offer(
    client: &Client,
    config: &Config,
    attempt_id: Uuid,
) -> Result<(), (u8, String)> {
    let mut offer: serde_json::Value = machine(
        client.get(url(
            config,
            &format!("/api/v1/runners/attempts/{attempt_id}/offer"),
        )),
        config,
    )
    .send()
    .await
    .map_err(network)?
    .error_for_status()
    .map_err(network)?
    .json()
    .await
    .map_err(network)?;
    let token = offer
        .get("idempotency_token")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| (3, "Offer has no idempotency token".into()))?
        .to_owned();
    machine(
        client.post(url(
            config,
            &format!("/api/v1/runners/attempts/{attempt_id}/accept"),
        )),
        config,
    )
    .json(&serde_json::json!({"message_id":Uuid::new_v4()}))
    .send()
    .await
    .map_err(network)?
    .error_for_status()
    .map_err(network)?;
    event(client, config, &token, 2, "running", None).await?;
    let object = offer
        .as_object_mut()
        .ok_or_else(|| (3, "Invalid offer".into()))?;
    object.insert("attempt_id".into(), serde_json::json!(attempt_id));
    let mut specification: ExecutionSpecification =
        serde_json::from_value(offer).map_err(|error| (3, format!("Invalid offer: {error}")))?;
    let source = machine(
        client.get(url(
            config,
            &format!("/api/v1/runners/attempts/{attempt_id}/source"),
        )),
        config,
    )
    .send()
    .await
    .map_err(network)?;
    if source.status().is_success() {
        specification.source_files = robine_source::extract_tar_gz(
            &source.bytes().await.map_err(network)?,
            robine_source::ArchiveLimits::default(),
        )
        .map_err(|error| (3, error.to_string()))?
        .into_iter()
        .map(|file| robine_execution::SourceFile {
            path: file.path,
            contents: file.contents,
        })
        .collect();
    }
    let secrets = machine(
        client.get(url(
            config,
            &format!("/api/v1/runners/attempts/{attempt_id}/secrets"),
        )),
        config,
    )
    .send()
    .await
    .map_err(network)?;
    if secrets.status().is_success() {
        let values: BTreeMap<String, String> = secrets.json().await.map_err(network)?;
        specification.secrets = values
            .into_iter()
            .map(|(name, value)| (name, Zeroizing::new(value)))
            .collect();
    }
    specification
        .steps
        .retain(|step| step.kind == StepKind::Run);
    let output = RemoteOutput {
        client: client.clone(),
        config: config.clone(),
        attempt_id,
        sequence: AtomicU64::new(0),
    };
    let result = DockerCli::new(DockerConfig::default())
        .run_controlled(
            &specification,
            ExecutionControl {
                output: &output,
                cancellation: &NeverCancel,
                builtins: None,
                last_sequence: 0,
            },
        )
        .await;
    let (status, reason) = match result {
        Ok(result) if result.status == ExecutionStatus::Succeeded => ("succeeded", None),
        Ok(result) => ("failed", Some(format!("{:?}", result.status))),
        Err(error) => ("failed", Some(error.to_string())),
    };
    event(client, config, &token, 3, status, reason.as_deref()).await
}

async fn event(
    client: &Client,
    config: &Config,
    token: &str,
    sequence: i32,
    status: &str,
    reason: Option<&str>,
) -> Result<(), (u8, String)> {
    machine(client.post(url(config, "/api/v1/runners/attempts/events")), config).json(&serde_json::json!({"idempotency_token":token,"message_id":Uuid::new_v4().to_string(),"sequence":sequence,"status":status,"reason":reason})).send().await.map_err(network)?.error_for_status().map_err(network)?;
    Ok(())
}

struct RemoteOutput {
    client: Client,
    config: Config,
    attempt_id: Uuid,
    sequence: AtomicU64,
}
#[async_trait]
impl OutputSink for RemoteOutput {
    async fn append(&self, chunk: OutputChunk) -> Result<(), ExecutionError> {
        let sequence = self.sequence.fetch_add(1, Ordering::SeqCst) + 1;
        let stream = match chunk.channel {
            OutputChannel::Stdout => "stdout",
            OutputChannel::Stderr => "stderr",
            OutputChannel::System => "system",
        };
        machine(self.client.post(url(&self.config, &format!("/api/v1/runners/attempts/{}/logs", self.attempt_id))), &self.config).json(&serde_json::json!({"sequence":sequence,"step_position":chunk.step,"step_name":chunk.step_name,"stream":stream,"content":String::from_utf8_lossy(&chunk.bytes)})).send().await.map_err(|_| ExecutionError::Output)?.error_for_status().map_err(|_| ExecutionError::Output)?;
        print!("{}", String::from_utf8_lossy(&chunk.bytes));
        Ok(())
    }
}
struct NeverCancel;
#[async_trait]
impl CancellationSignal for NeverCancel {
    async fn requested(&self) -> Result<bool, ExecutionError> {
        Ok(false)
    }
}

fn machine(builder: reqwest::RequestBuilder, config: &Config) -> reqwest::RequestBuilder {
    builder
        .header("x-robine-runner-id", config.runner_id.to_string())
        .header("x-robine-runner-credential", &config.credential)
}
fn url(config: &Config, path: &str) -> String {
    format!("{}{}", config.server_url.trim_end_matches('/'), path)
}
fn option(arguments: &[String], name: &str) -> Result<String, (u8, String)> {
    arguments
        .windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].clone())
        .ok_or_else(|| (64, format!("{name} is required")))
}
fn ensure_secure_server(server: &str) -> Result<(), (u8, String)> {
    if server.starts_with("https://")
        || server.starts_with("http://localhost")
        || server.starts_with("http://127.0.0.1")
    {
        Ok(())
    } else {
        Err((2, "TLS is required except for a loopback server.".into()))
    }
}
#[allow(clippy::needless_pass_by_value)]
fn network(error: reqwest::Error) -> (u8, String) {
    (3, format!("Network request failed: {error}"))
}
#[allow(clippy::needless_pass_by_value)]
fn io_error(error: io::Error) -> (u8, String) {
    (3, error.to_string())
}

#[cfg(unix)]
fn write_private(path: &Path, contents: &[u8]) -> io::Result<()> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("tmp");
    fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .and_then(|mut file| {
            use io::Write;
            file.write_all(contents)
        })?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(temporary, path)
}
#[cfg(not(unix))]
fn write_private(path: &Path, contents: &[u8]) -> io::Result<()> {
    fs::write(path, contents)
}
#[cfg(unix)]
fn private_file(path: &Path) -> Result<(), (u8, String)> {
    use std::os::unix::fs::PermissionsExt;
    let metadata = fs::metadata(path).map_err(io_error)?;
    if metadata.permissions().mode().trailing_zeros() >= 6 {
        Ok(())
    } else {
        Err((4, "Runner config must be private (mode 0600).".into()))
    }
}
#[cfg(not(unix))]
fn private_file(path: &Path) -> Result<(), (u8, String)> {
    fs::metadata(path).map(|_| ()).map_err(io_error)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refuses_cleartext_remote_server() {
        assert!(ensure_secure_server("http://example.com").is_err());
        assert!(ensure_secure_server("http://localhost:4000").is_ok());
    }
}
