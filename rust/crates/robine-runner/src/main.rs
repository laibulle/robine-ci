use async_trait::async_trait;
use reqwest::Client;
use robine_execution::{
    BuiltinHandler, BuiltinRestore, CancellationSignal, DockerCli, DockerConfig, ExecutionControl,
    ExecutionError, ExecutionSpecification, ExecutionStatus, ExecutionStep, OutputChannel,
    OutputChunk, OutputSink,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env, fs, io,
    path::{Path, PathBuf},
    process::ExitCode,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
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
    let output = RemoteOutput {
        client: client.clone(),
        config: config.clone(),
        attempt_id,
        sequence: AtomicU64::new(0),
    };
    let cancellation = RemoteCancellation {
        client: client.clone(),
        config: config.clone(),
        attempt_id,
        last_check: Mutex::new(None),
        requested: AtomicBool::new(false),
    };
    let builtins = RemoteBuiltins {
        client: client.clone(),
        config: config.clone(),
        attempt_id,
    };
    let result = DockerCli::new(DockerConfig::default())
        .run_controlled(
            &specification,
            ExecutionControl {
                output: &output,
                cancellation: &cancellation,
                builtins: Some(&builtins),
                last_sequence: 0,
            },
        )
        .await;
    let (status, reason) = remote_outcome(result.as_ref().map(|result| result.status));
    event(client, config, &token, 3, status, reason.as_deref()).await
}

fn remote_outcome(
    result: Result<ExecutionStatus, &ExecutionError>,
) -> (&'static str, Option<String>) {
    match result {
        Ok(ExecutionStatus::Succeeded) => ("succeeded", None),
        Ok(ExecutionStatus::Cancelled) => ("cancelled", Some("cancelled".to_owned())),
        Ok(ExecutionStatus::TimedOut) => ("failed", Some("timeout".to_owned())),
        Ok(ExecutionStatus::ServiceUnavailable) => {
            ("failed", Some("service_unavailable".to_owned()))
        }
        Ok(ExecutionStatus::Failed) => ("failed", Some("command_failed".to_owned())),
        Err(_) => ("failed", Some("system_failure".to_owned())),
    }
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
struct RemoteCancellation {
    client: Client,
    config: Config,
    attempt_id: Uuid,
    last_check: Mutex<Option<Instant>>,
    requested: AtomicBool,
}

#[async_trait]
impl CancellationSignal for RemoteCancellation {
    async fn requested(&self) -> Result<bool, ExecutionError> {
        if self.requested.load(Ordering::Acquire) {
            return Ok(true);
        }
        {
            let mut last_check =
                self.last_check
                    .lock()
                    .map_err(|_| ExecutionError::Unavailable {
                        phase: "cancellation_state",
                    })?;
            if last_check.is_some_and(|instant| instant.elapsed() < Duration::from_secs(2)) {
                return Ok(false);
            }
            *last_check = Some(Instant::now());
        }
        let heartbeat: Heartbeat = machine(
            self.client
                .post(url(&self.config, "/api/v1/runners/heartbeat")),
            &self.config,
        )
        .json(&serde_json::json!({"lease_seconds":60}))
        .send()
        .await
        .map_err(|_| ExecutionError::Unavailable {
            phase: "cancellation_heartbeat",
        })?
        .error_for_status()
        .map_err(|_| ExecutionError::Unavailable {
            phase: "cancellation_heartbeat",
        })?
        .json()
        .await
        .map_err(|_| ExecutionError::Unavailable {
            phase: "cancellation_heartbeat",
        })?;
        let requested = heartbeat
            .cancellation_requested_attempt_ids
            .contains(&self.attempt_id);
        self.requested.store(requested, Ordering::Release);
        Ok(requested)
    }
}

struct RemoteBuiltins {
    client: Client,
    config: Config,
    attempt_id: Uuid,
}

#[async_trait]
impl BuiltinHandler for RemoteBuiltins {
    async fn restore(&self, step: &ExecutionStep) -> Result<BuiltinRestore, ExecutionError> {
        let path = match step.value.as_str() {
            "cache/restore" => format!("/api/v1/runners/attempts/{}/cache", self.attempt_id),
            "artifacts/download" => {
                format!("/api/v1/runners/attempts/{}/artifacts", self.attempt_id)
            }
            _ => return Err(ExecutionError::Unsupported("builtin restore")),
        };
        let mut endpoint = url::Url::parse(&url(&self.config, &path))
            .map_err(|_| ExecutionError::InvalidSpecification("runner URL"))?;
        match step.value.as_str() {
            "cache/restore" => endpoint
                .query_pairs_mut()
                .append_pair("key", step_string(step, "key")?),
            "artifacts/download" => endpoint
                .query_pairs_mut()
                .append_pair("name", step_string(step, "name")?)
                .append_pair("from", step_string(step, "from")?),
            _ => unreachable!(),
        };
        let response = machine(self.client.get(endpoint), &self.config)
            .send()
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "builtin_download",
            })?;
        if response.status() == reqwest::StatusCode::NO_CONTENT {
            return Ok(BuiltinRestore::CacheMiss);
        }
        let response = response
            .error_for_status()
            .map_err(|_| ExecutionError::Runner {
                phase: "builtin_download",
            })?;
        let expected = response
            .headers()
            .get("x-content-sha256")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned)
            .ok_or(ExecutionError::Runner {
                phase: "builtin_digest",
            })?;
        if response
            .content_length()
            .is_some_and(|size| size > 104_857_600)
        {
            return Err(ExecutionError::Runner {
                phase: "builtin_download_size",
            });
        }
        let content = response
            .bytes()
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "builtin_download",
            })?
            .to_vec();
        if content.len() > 104_857_600 || format!("{:x}", Sha256::digest(&content)) != expected {
            return Err(ExecutionError::Runner {
                phase: "builtin_digest",
            });
        }
        Ok(BuiltinRestore::Archive(content))
    }

    async fn publish(&self, step: &ExecutionStep, archive: Vec<u8>) -> Result<(), ExecutionError> {
        if archive.len() > 104_857_600 {
            return Err(ExecutionError::Runner {
                phase: "builtin_upload_size",
            });
        }
        let path = match step.value.as_str() {
            "cache/save" => format!("/api/v1/runners/attempts/{}/cache", self.attempt_id),
            "artifacts/upload" => {
                format!("/api/v1/runners/attempts/{}/artifacts", self.attempt_id)
            }
            _ => return Err(ExecutionError::Unsupported("builtin publish")),
        };
        let mut endpoint = url::Url::parse(&url(&self.config, &path))
            .map_err(|_| ExecutionError::InvalidSpecification("runner URL"))?;
        match step.value.as_str() {
            "cache/save" => endpoint
                .query_pairs_mut()
                .append_pair("key", step_string(step, "key")?),
            "artifacts/upload" => endpoint
                .query_pairs_mut()
                .append_pair("name", step_string(step, "name")?)
                .append_pair(
                    "retention_days",
                    &step
                        .with
                        .get("retention_days")
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(7)
                        .to_string(),
                ),
            _ => unreachable!(),
        };
        machine(self.client.put(endpoint), &self.config)
            .header("content-type", "application/gzip")
            .body(archive)
            .send()
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "builtin_upload",
            })?
            .error_for_status()
            .map_err(|_| ExecutionError::Runner {
                phase: "builtin_upload",
            })?;
        Ok(())
    }
}

fn step_string<'a>(step: &'a ExecutionStep, key: &str) -> Result<&'a str, ExecutionError> {
    step.with
        .get(key)
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(ExecutionError::InvalidSpecification("builtin parameter"))
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
    use robine_execution::StepCondition;
    use wiremock::{
        Mock, MockServer, ResponseTemplate,
        matchers::{header, method, path, query_param},
    };

    fn test_config(server_url: String) -> Config {
        Config {
            server_url,
            runner_id: Uuid::new_v4(),
            credential: format!("rrc_{}", "a".repeat(43)),
            name: "test-runner".into(),
        }
    }

    fn builtin(value: &str, with: &[(&str, serde_json::Value)]) -> ExecutionStep {
        ExecutionStep {
            name: value.into(),
            kind: robine_execution::StepKind::Builtin,
            value: value.into(),
            condition: StepCondition::Success,
            with: with
                .iter()
                .map(|(key, value)| ((*key).to_owned(), value.clone()))
                .collect(),
        }
    }
    #[test]
    fn refuses_cleartext_remote_server() {
        assert!(ensure_secure_server("http://example.com").is_err());
        assert!(ensure_secure_server("http://localhost:4000").is_ok());
    }

    #[test]
    fn remote_terminal_outcomes_use_protocol_reasons() {
        assert_eq!(
            remote_outcome(Ok(ExecutionStatus::Succeeded)),
            ("succeeded", None)
        );
        assert_eq!(
            remote_outcome(Ok(ExecutionStatus::Cancelled)),
            ("cancelled", Some("cancelled".into()))
        );
        assert_eq!(
            remote_outcome(Ok(ExecutionStatus::TimedOut)),
            ("failed", Some("timeout".into()))
        );
        assert_eq!(
            remote_outcome(Ok(ExecutionStatus::ServiceUnavailable)),
            ("failed", Some("service_unavailable".into()))
        );
        assert_eq!(
            remote_outcome(Ok(ExecutionStatus::Failed)),
            ("failed", Some("command_failed".into()))
        );
    }

    #[tokio::test]
    async fn remote_cancellation_renews_and_observes_the_owned_attempt() {
        let server = MockServer::start().await;
        let config = test_config(server.uri());
        let attempt_id = Uuid::new_v4();
        Mock::given(method("POST"))
            .and(path("/api/v1/runners/heartbeat"))
            .and(header("x-robine-runner-id", config.runner_id.to_string()))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "renewed_attempts": 1,
                "pending_offer_attempt_ids": [],
                "cancellation_requested_attempt_ids": [attempt_id]
            })))
            .expect(1)
            .mount(&server)
            .await;
        let cancellation = RemoteCancellation {
            client: Client::new(),
            config,
            attempt_id,
            last_check: Mutex::new(None),
            requested: AtomicBool::new(false),
        };
        assert!(cancellation.requested().await.expect("heartbeat"));
        assert!(cancellation.requested().await.expect("cached cancellation"));
    }

    #[tokio::test]
    async fn remote_cache_restore_is_scoped_bounded_and_digest_verified() {
        let server = MockServer::start().await;
        let config = test_config(server.uri());
        let attempt_id = Uuid::new_v4();
        let archive = b"bounded archive".to_vec();
        let digest = format!("{:x}", Sha256::digest(&archive));
        Mock::given(method("GET"))
            .and(path(format!("/api/v1/runners/attempts/{attempt_id}/cache")))
            .and(query_param("key", "cargo lock"))
            .and(header("x-robine-runner-id", config.runner_id.to_string()))
            .respond_with(
                ResponseTemplate::new(200)
                    .insert_header("x-content-sha256", digest)
                    .set_body_bytes(archive.clone()),
            )
            .expect(1)
            .mount(&server)
            .await;
        let handler = RemoteBuiltins {
            client: Client::new(),
            config,
            attempt_id,
        };
        let result = handler
            .restore(&builtin(
                "cache/restore",
                &[("key", serde_json::json!("cargo lock"))],
            ))
            .await
            .expect("restore cache");
        assert_eq!(result, BuiltinRestore::Archive(archive));
    }
}
