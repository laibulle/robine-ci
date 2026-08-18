use crate::{
    CancellationSignal, ExecutionControl, ExecutionError, ExecutionResult, ExecutionRunner,
    ExecutionSpecification, ExecutionStatus, OutputChannel, OutputChunk, OutputSink, StepCondition,
    StepKind,
};
use async_trait::async_trait;
use std::collections::HashSet;
use std::process::Output;
use std::process::Stdio;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

const READINESS_IMAGE: &str =
    "alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce";

#[derive(Clone, Debug)]
pub struct DockerConfig {
    pub executable: String,
    pub instance: String,
    pub cpu_millis: u32,
    pub memory_bytes: u64,
    pub pids_limit: u32,
}

impl Default for DockerConfig {
    fn default() -> Self {
        Self {
            executable: "docker".into(),
            instance: "rust".into(),
            cpu_millis: 2_000,
            memory_bytes: 4 * 1_024 * 1_024 * 1_024,
            pids_limit: 512,
        }
    }
}

#[derive(Clone, Debug)]
pub struct DockerCli {
    config: DockerConfig,
}

impl DockerCli {
    #[must_use]
    pub const fn new(config: DockerConfig) -> Self {
        Self { config }
    }

    /// Removes only inactive resources carrying this runner instance's ownership labels.
    ///
    /// # Errors
    ///
    /// Returns an availability error when owned resources cannot be listed or removed.
    pub async fn reconcile_orphans(
        &self,
        active_attempts: &HashSet<uuid::Uuid>,
    ) -> Result<u64, ExecutionError> {
        let instance_filter = format!("label=io.robine.instance={}", self.config.instance);
        let containers = self
            .command(&[
                "ps",
                "--all",
                "--quiet",
                "--filter",
                &instance_filter,
                "--format",
                "{{.ID}} {{.Label \"io.robine.attempt\"}}",
            ])
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "orphan_list",
            })?;
        if !containers.status.success() || containers.stdout.len() > 1_048_576 {
            return Err(ExecutionError::Runner {
                phase: "orphan_list",
            });
        }
        let orphans = inactive_resource_ids(&containers.stdout, active_attempts)?;
        let mut removed = 0_u64;
        for resource in orphans {
            self.checked(&["rm", "--force", "--volumes", &resource], "orphan_cleanup")
                .await?;
            removed += 1;
        }
        let volumes = self
            .command(&[
                "volume",
                "ls",
                "--quiet",
                "--filter",
                &instance_filter,
                "--format",
                "{{.Name}} {{.Label \"io.robine.attempt\"}}",
            ])
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "orphan_list",
            })?;
        if !volumes.status.success() || volumes.stdout.len() > 1_048_576 {
            return Err(ExecutionError::Runner {
                phase: "orphan_list",
            });
        }
        for resource in inactive_resource_ids(&volumes.stdout, active_attempts)? {
            self.checked(&["volume", "rm", "--force", &resource], "orphan_cleanup")
                .await?;
            removed += 1;
        }
        let networks = self
            .command(&[
                "network",
                "ls",
                "--quiet",
                "--filter",
                &instance_filter,
                "--format",
                "{{.ID}} {{.Label \"io.robine.attempt\"}}",
            ])
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "orphan_list",
            })?;
        if !networks.status.success() || networks.stdout.len() > 1_048_576 {
            return Err(ExecutionError::Runner {
                phase: "orphan_list",
            });
        }
        for resource in inactive_resource_ids(&networks.stdout, active_attempts)? {
            self.checked(&["network", "rm", &resource], "orphan_cleanup")
                .await?;
            removed += 1;
        }
        Ok(removed)
    }

    /// Runs sequential command steps in one hardened attempt container.
    ///
    /// Cleanup is attempted after every result. The durable caller remains responsible for
    /// retrying label-scoped orphan reconciliation after process interruption.
    ///
    /// # Errors
    ///
    /// Returns validation, Docker availability, preparation, or cleanup errors.
    pub async fn run(
        &self,
        specification: &ExecutionSpecification,
    ) -> Result<ExecutionResult, ExecutionError> {
        self.run_controlled(
            specification,
            ExecutionControl {
                output: &DiscardOutput,
                cancellation: &NeverCancel,
                last_sequence: 0,
            },
        )
        .await
    }

    /// Runs with a durable output sink and cancellation projection.
    ///
    /// # Errors
    ///
    /// Returns validation, Docker, output persistence, or cancellation polling errors.
    pub async fn run_controlled(
        &self,
        specification: &ExecutionSpecification,
        control: ExecutionControl<'_>,
    ) -> Result<ExecutionResult, ExecutionError> {
        specification.validate()?;
        let suffix = specification.attempt_id.simple();
        let container = format!("robine-job-{suffix}");
        let volume = format!("robine-workspace-{suffix}");
        let network = (!specification.services.is_empty()).then(|| format!("robine-net-{suffix}"));
        let attempt_label = format!("io.robine.attempt={}", specification.attempt_id);
        let instance_label = format!("io.robine.instance={}", self.config.instance);
        self.checked(
            &[
                "volume",
                "create",
                "--label",
                &attempt_label,
                "--label",
                &instance_label,
                &volume,
            ],
            "volume_create",
        )
        .await?;
        let execution = match tokio::time::timeout(
            std::time::Duration::from_millis(specification.timeout_ms),
            self.run_container(specification, &container, &volume, &control),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Ok(ExecutionResult {
                status: ExecutionStatus::TimedOut,
                exit_code: None,
            }),
        };
        let cleanup = self
            .command(&["rm", "--force", "--volumes", &container])
            .await;
        let volume_cleanup = self.command(&["volume", "rm", "--force", &volume]).await;
        for service in &specification.services {
            let service_name = format!("robine-service-{suffix}-{}", service.id);
            let _ = self
                .command(&["rm", "--force", "--volumes", &service_name])
                .await;
        }
        if let Some(network) = &network {
            let _ = self.command(&["network", "rm", network]).await;
        }
        if cleanup.is_err() || volume_cleanup.is_err() {
            return Err(ExecutionError::Unavailable { phase: "cleanup" });
        }
        execution
    }

    async fn run_container(
        &self,
        specification: &ExecutionSpecification,
        container: &str,
        volume: &str,
        control: &ExecutionControl<'_>,
    ) -> Result<ExecutionResult, ExecutionError> {
        self.ensure_image(&specification.image).await?;
        let network = if specification.services.is_empty() {
            None
        } else {
            let network = format!("robine-net-{}", specification.attempt_id.simple());
            self.create_network(specification, &network).await?;
            self.start_services(specification, &network).await?;
            Some(network)
        };
        self.checked_with_environment(
            &self.create_args(specification, container, volume, network.as_deref()),
            &specification.secrets,
            "container_create",
        )
        .await?;
        self.checked(&["start", container], "container_start")
            .await?;
        let mut failed = false;
        let mut exit_code = Some(0);
        let mut sequence = control.last_sequence;
        for (step_index, step) in specification.steps.iter().enumerate() {
            if step.kind != StepKind::Run {
                return Err(ExecutionError::Unsupported("builtin step"));
            }
            let should_run = match step.condition {
                StepCondition::Success => !failed,
                StepCondition::Failure => failed,
                StepCondition::Always => true,
            };
            if !should_run {
                continue;
            }
            let result = self
                .execute_step(
                    specification,
                    container,
                    step_index,
                    &step.name,
                    &step.value,
                    &mut sequence,
                    control,
                )
                .await?;
            if matches!(
                result.status,
                ExecutionStatus::Cancelled | ExecutionStatus::ServiceUnavailable
            ) {
                return Ok(result);
            }
            if result.status == ExecutionStatus::Failed {
                failed = true;
                exit_code = result.exit_code;
            }
        }
        Ok(ExecutionResult {
            status: if failed {
                ExecutionStatus::Failed
            } else {
                ExecutionStatus::Succeeded
            },
            exit_code,
        })
    }

    async fn create_network(
        &self,
        specification: &ExecutionSpecification,
        network: &str,
    ) -> Result<(), ExecutionError> {
        self.checked(
            &[
                "network",
                "create",
                "--label",
                &format!("io.robine.attempt={}", specification.attempt_id),
                "--label",
                &format!("io.robine.instance={}", self.config.instance),
                network,
            ],
            "service_network_create",
        )
        .await
    }

    async fn start_services(
        &self,
        specification: &ExecutionSpecification,
        network: &str,
    ) -> Result<(), ExecutionError> {
        for service in &specification.services {
            self.ensure_image(&service.image).await?;
            let name = format!(
                "robine-service-{}-{}",
                specification.attempt_id.simple(),
                service.id
            );
            self.checked_with_environment(
                &self.service_create_args(specification, service, network, &name),
                &service.secrets,
                "service_create",
            )
            .await?;
            self.checked(&["start", &name], "service_start").await?;
            self.wait_for_service(specification, service, network, &name)
                .await?;
        }
        Ok(())
    }

    fn service_create_args(
        &self,
        specification: &ExecutionSpecification,
        service: &crate::ServiceSpecification,
        network: &str,
        name: &str,
    ) -> Vec<String> {
        let mut args = vec![
            "create".into(),
            "--name".into(),
            name.into(),
            "--network".into(),
            network.into(),
            "--network-alias".into(),
            service.id.clone(),
            "--label".into(),
            format!("io.robine.attempt={}", specification.attempt_id),
            "--label".into(),
            format!("io.robine.instance={}", self.config.instance),
            "--cpus".into(),
            format!("{:.3}", f64::from(self.config.cpu_millis) / 1_000.0),
            "--memory".into(),
            self.config.memory_bytes.to_string(),
            "--memory-swap".into(),
            self.config.memory_bytes.to_string(),
            "--pids-limit".into(),
            self.config.pids_limit.to_string(),
        ];
        if service.privileged {
            args.push("--privileged".into());
        } else {
            args.extend([
                "--cap-drop".into(),
                "ALL".into(),
                "--security-opt".into(),
                "no-new-privileges".into(),
            ]);
        }
        if let Some(user) = &service.user {
            args.extend(["--user".into(), user.clone()]);
        }
        for (name, value) in &service.env {
            args.extend(["--env".into(), format!("{name}={value}")]);
        }
        for name in service.secrets.keys() {
            args.extend(["--env".into(), name.clone()]);
        }
        args.push(service.image.clone());
        args.extend(service.command.clone());
        args
    }

    async fn wait_for_service(
        &self,
        specification: &ExecutionSpecification,
        service: &crate::ServiceSpecification,
        network: &str,
        name: &str,
    ) -> Result<(), ExecutionError> {
        let Some(readiness) = &service.readiness else {
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            let output = self
                .command(&["inspect", "--format", "{{.State.Running}}", name])
                .await
                .map_err(|_| ExecutionError::Unavailable {
                    phase: "service_readiness",
                })?;
            return if output.status.success() && output.stdout == b"true\n" {
                Ok(())
            } else {
                Err(ExecutionError::Runner {
                    phase: "service_readiness",
                })
            };
        };
        self.ensure_image(READINESS_IMAGE).await?;
        let deadline =
            tokio::time::Instant::now() + std::time::Duration::from_millis(readiness.timeout_ms);
        loop {
            let probe_name = format!(
                "robine-probe-{}-{}",
                specification.attempt_id.simple(),
                service.id
            );
            let output = self
                .command(&[
                    "run",
                    "--rm",
                    "--name",
                    &probe_name,
                    "--network",
                    network,
                    "--label",
                    &format!("io.robine.attempt={}", specification.attempt_id),
                    "--label",
                    &format!("io.robine.instance={}", self.config.instance),
                    "--cap-drop",
                    "ALL",
                    "--security-opt",
                    "no-new-privileges",
                    READINESS_IMAGE,
                    "nc",
                    "-z",
                    "-w",
                    "1",
                    &service.id,
                    &readiness.tcp.to_string(),
                ])
                .await
                .map_err(|_| ExecutionError::Unavailable {
                    phase: "service_readiness",
                })?;
            if output.status.success() {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(ExecutionError::Runner {
                    phase: "service_readiness",
                });
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
    }

    #[allow(clippy::too_many_arguments)]
    async fn execute_step(
        &self,
        specification: &ExecutionSpecification,
        container: &str,
        step_index: usize,
        step_name: &str,
        value: &str,
        sequence: &mut u64,
        control: &ExecutionControl<'_>,
    ) -> Result<ExecutionResult, ExecutionError> {
        let mut command = Command::new(&self.config.executable);
        command.args([
            "exec",
            "--workdir",
            &specification.workspace,
            container,
            &specification.shell,
            "-e",
            "-c",
            value,
        ]);
        command
            .kill_on_drop(true)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().map_err(|_| ExecutionError::Unavailable {
            phase: "step_execute",
        })?;
        let mut stdout = child.stdout.take().ok_or(ExecutionError::Unavailable {
            phase: "step_execute",
        })?;
        let mut stderr = child.stderr.take().ok_or(ExecutionError::Unavailable {
            phase: "step_execute",
        })?;
        let mut stdout_open = true;
        let mut stderr_open = true;
        let mut stdout_buffer = vec![0_u8; 16_384];
        let mut stderr_buffer = vec![0_u8; 16_384];
        let secret_values = specification
            .secrets
            .values()
            .map(|value| value.as_bytes().to_vec())
            .collect::<Vec<_>>();
        let mut stdout_redactor = StreamingRedactor::new(&secret_values);
        let mut stderr_redactor = StreamingRedactor::new(&secret_values);
        let mut cancellation = tokio::time::interval(std::time::Duration::from_millis(250));
        while stdout_open || stderr_open {
            tokio::select! {
                read = stdout.read(&mut stdout_buffer), if stdout_open => {
                    let size = read.map_err(|_| ExecutionError::Unavailable { phase: "step_output" })?;
                    stdout_open = size != 0;
                    let redacted = stdout_redactor.push(&stdout_buffer[..size], size == 0);
                    if !redacted.is_empty() {
                        emit_chunk(control.output, sequence, step_index, step_name, OutputChannel::Stdout, &redacted).await?;
                    }
                }
                read = stderr.read(&mut stderr_buffer), if stderr_open => {
                    let size = read.map_err(|_| ExecutionError::Unavailable { phase: "step_output" })?;
                    stderr_open = size != 0;
                    let redacted = stderr_redactor.push(&stderr_buffer[..size], size == 0);
                    if !redacted.is_empty() {
                        emit_chunk(control.output, sequence, step_index, step_name, OutputChannel::Stderr, &redacted).await?;
                    }
                }
                _ = cancellation.tick() => {
                    if control.cancellation.requested().await? {
                        let _ = self.command(&["stop", "--time", "5", container]).await;
                        let _ = child.wait().await;
                        return Ok(ExecutionResult { status: ExecutionStatus::Cancelled, exit_code: None });
                    }
                    if !self.services_healthy(specification).await? {
                        let _ = self.command(&["stop", "--time", "5", container]).await;
                        let _ = child.wait().await;
                        return Ok(ExecutionResult { status: ExecutionStatus::ServiceUnavailable, exit_code: None });
                    }
                }
            }
        }
        let status = child
            .wait()
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "step_execute",
            })?;
        Ok(ExecutionResult {
            status: if status.success() {
                ExecutionStatus::Succeeded
            } else {
                ExecutionStatus::Failed
            },
            exit_code: status.code(),
        })
    }

    async fn services_healthy(
        &self,
        specification: &ExecutionSpecification,
    ) -> Result<bool, ExecutionError> {
        for service in &specification.services {
            let name = format!(
                "robine-service-{}-{}",
                specification.attempt_id.simple(),
                service.id
            );
            let output = self
                .command(&["inspect", "--format", "{{.State.Running}}", &name])
                .await
                .map_err(|_| ExecutionError::Unavailable {
                    phase: "service_liveness",
                })?;
            if !output.status.success() || output.stdout != b"true\n" {
                return Ok(false);
            }
        }
        Ok(true)
    }

    async fn ensure_image(&self, image: &str) -> Result<(), ExecutionError> {
        let inspected = self
            .command(&["image", "inspect", image])
            .await
            .map_err(|_| ExecutionError::Unavailable {
                phase: "image_inspect",
            })?;
        if inspected.status.success() {
            return Ok(());
        }
        self.checked(&["pull", image], "image_pull").await
    }

    fn create_args(
        &self,
        specification: &ExecutionSpecification,
        container: &str,
        volume: &str,
        network: Option<&str>,
    ) -> Vec<String> {
        let mut args = vec![
            "create".into(),
            "--name".into(),
            container.into(),
            "--label".into(),
            format!("io.robine.attempt={}", specification.attempt_id),
            "--label".into(),
            format!("io.robine.instance={}", self.config.instance),
            "--cap-drop".into(),
            "ALL".into(),
            "--security-opt".into(),
            "no-new-privileges".into(),
            "--cpus".into(),
            format!("{:.3}", f64::from(self.config.cpu_millis) / 1_000.0),
            "--memory".into(),
            self.config.memory_bytes.to_string(),
            "--memory-swap".into(),
            self.config.memory_bytes.to_string(),
            "--pids-limit".into(),
            self.config.pids_limit.to_string(),
            "--volume".into(),
            format!("{volume}:{}", specification.workspace),
            "--workdir".into(),
            specification.workspace.clone(),
        ];
        if let Some(network) = network {
            args.extend(["--network".into(), network.into()]);
        }
        for (name, value) in specification.env.iter().chain(&specification.build_env) {
            args.extend(["--env".into(), format!("{name}={value}")]);
        }
        for name in specification.secrets.keys() {
            args.extend(["--env".into(), name.clone()]);
        }
        args.extend([
            specification.image.clone(),
            specification.shell.clone(),
            "-c".into(),
            "trap 'exit 0' TERM INT; while :; do sleep 3600; done".into(),
        ]);
        args
    }

    async fn checked(
        &self,
        args: &[impl AsRef<str>],
        phase: &'static str,
    ) -> Result<(), ExecutionError> {
        let output = self
            .command(args)
            .await
            .map_err(|_| ExecutionError::Unavailable { phase })?;
        if output.status.success() {
            Ok(())
        } else {
            Err(ExecutionError::Runner { phase })
        }
    }

    async fn checked_with_environment(
        &self,
        args: &[impl AsRef<str>],
        environment: &std::collections::BTreeMap<String, zeroize::Zeroizing<String>>,
        phase: &'static str,
    ) -> Result<(), ExecutionError> {
        let mut command = Command::new(&self.config.executable);
        command.args(args.iter().map(AsRef::as_ref));
        for (name, value) in environment {
            command.env(name, value.as_str());
        }
        let output = command
            .kill_on_drop(true)
            .output()
            .await
            .map_err(|_| ExecutionError::Unavailable { phase })?;
        if output.status.success() {
            Ok(())
        } else {
            Err(ExecutionError::Runner { phase })
        }
    }

    async fn command(&self, args: &[impl AsRef<str>]) -> std::io::Result<Output> {
        let mut command = Command::new(&self.config.executable);
        command.args(args.iter().map(AsRef::as_ref));
        command.kill_on_drop(true).output().await
    }
}

#[async_trait]
impl ExecutionRunner for DockerCli {
    async fn run(
        &self,
        specification: &ExecutionSpecification,
        control: ExecutionControl<'_>,
    ) -> Result<ExecutionResult, ExecutionError> {
        self.run_controlled(specification, control).await
    }
}

async fn emit_chunk(
    output: &dyn OutputSink,
    sequence: &mut u64,
    step: usize,
    step_name: &str,
    channel: OutputChannel,
    bytes: &[u8],
) -> Result<(), ExecutionError> {
    *sequence += 1;
    output
        .append(OutputChunk {
            sequence: *sequence,
            step,
            step_name: step_name.into(),
            channel,
            bytes: bytes.to_vec(),
        })
        .await
}

struct DiscardOutput;

#[async_trait]
impl OutputSink for DiscardOutput {
    async fn append(&self, _chunk: OutputChunk) -> Result<(), ExecutionError> {
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

struct StreamingRedactor {
    secrets: Vec<Vec<u8>>,
    pending: Vec<u8>,
    retain: usize,
}

impl StreamingRedactor {
    fn new(secrets: &[Vec<u8>]) -> Self {
        let mut secrets = secrets
            .iter()
            .filter(|secret| !secret.is_empty())
            .cloned()
            .collect::<Vec<_>>();
        secrets.sort_by_key(|secret| std::cmp::Reverse(secret.len()));
        let retain = secrets.iter().map(Vec::len).max().unwrap_or(1) - 1;
        Self {
            secrets,
            pending: Vec::new(),
            retain,
        }
    }

    fn push(&mut self, bytes: &[u8], finish: bool) -> Vec<u8> {
        self.pending.extend_from_slice(bytes);
        let mut output = Vec::new();
        let mut consumed = 0;
        while consumed < self.pending.len()
            && (finish || self.pending.len() - consumed > self.retain)
        {
            let remaining = &self.pending[consumed..];
            if let Some(secret) = self
                .secrets
                .iter()
                .find(|secret| remaining.starts_with(secret))
            {
                output.extend_from_slice(b"[REDACTED]");
                consumed += secret.len();
            } else {
                output.push(self.pending[consumed]);
                consumed += 1;
            }
        }
        self.pending.drain(..consumed);
        output
    }
}

fn inactive_resource_ids(
    output: &[u8],
    active_attempts: &HashSet<uuid::Uuid>,
) -> Result<Vec<String>, ExecutionError> {
    let output = std::str::from_utf8(output).map_err(|_| ExecutionError::Runner {
        phase: "orphan_list",
    })?;
    let mut inactive = Vec::new();
    for line in output.lines() {
        let (resource, attempt) = line.split_once(' ').ok_or(ExecutionError::Runner {
            phase: "orphan_list",
        })?;
        let attempt = uuid::Uuid::parse_str(attempt).map_err(|_| ExecutionError::Runner {
            phase: "orphan_list",
        })?;
        if !active_attempts.contains(&attempt) {
            inactive.push(resource.into());
        }
    }
    Ok(inactive)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ExecutionStep, ServiceReadiness, ServiceSpecification};
    use std::collections::BTreeMap;
    use std::sync::Mutex;
    use uuid::Uuid;

    #[derive(Default)]
    struct RecordingControl {
        chunks: Mutex<Vec<OutputChunk>>,
        cancel: bool,
    }

    #[async_trait]
    impl OutputSink for RecordingControl {
        async fn append(&self, chunk: OutputChunk) -> Result<(), ExecutionError> {
            self.chunks.lock().expect("output lock").push(chunk);
            Ok(())
        }
    }

    #[async_trait]
    impl CancellationSignal for RecordingControl {
        async fn requested(&self) -> Result<bool, ExecutionError> {
            Ok(self.cancel)
        }
    }

    #[test]
    fn container_creation_is_labeled_bounded_and_hardened() {
        let runner = DockerCli::new(DockerConfig::default());
        let specification = ExecutionSpecification {
            attempt_id: Uuid::new_v4(),
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 1_000,
            env: BTreeMap::from([("USER_VALUE".into(), "hello".into())]),
            build_env: BTreeMap::from([("ROBINE_BUILD_COMMIT_SHA".into(), "abc".into())]),
            secret_names: Vec::new(),
            secrets: BTreeMap::from([(
                "TOKEN".into(),
                zeroize::Zeroizing::new("super-secret".into()),
            )]),
            services: Vec::new(),
            steps: vec![ExecutionStep {
                name: "test".into(),
                kind: StepKind::Run,
                value: "true".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            }],
        };
        let arguments = runner.create_args(&specification, "job", "workspace", None);
        let joined = arguments.join(" ");
        assert!(joined.contains("--cap-drop ALL"));
        assert!(joined.contains("--security-opt no-new-privileges"));
        assert!(joined.contains("--memory 4294967296 --memory-swap 4294967296"));
        assert!(joined.contains("--pids-limit 512"));
        assert!(joined.contains("io.robine.attempt="));
        assert!(joined.contains("io.robine.instance=rust"));
        assert!(!joined.contains("--privileged"));
        assert!(!joined.contains("docker.sock"));
        assert!(!joined.contains("--network host"));
        assert!(!joined.contains("super-secret"));
    }

    #[test]
    fn orphan_selection_preserves_active_and_rejects_unowned_shape() {
        let active = Uuid::new_v4();
        let inactive = Uuid::new_v4();
        let output = format!("active-container {active}\norphan-container {inactive}\n");
        assert_eq!(
            inactive_resource_ids(output.as_bytes(), &HashSet::from([active])).expect("labels"),
            vec!["orphan-container"]
        );
        assert!(inactive_resource_ids(b"unlabeled\n", &HashSet::new()).is_err());
    }

    #[test]
    fn streaming_redaction_masks_values_split_across_chunks() {
        let mut redactor = StreamingRedactor::new(&[b"super-secret".to_vec(), b"secret".to_vec()]);
        let mut output = redactor.push(b"before super-", false);
        output.extend(redactor.push(b"secret after", false));
        output.extend(redactor.push(b"", true));
        assert_eq!(output, b"before [REDACTED] after");
    }

    #[tokio::test]
    async fn docker_steps_share_workspace_and_cleanup_when_enabled() {
        if std::env::var_os("ROBINE_DOCKER_INTEGRATION").is_none() {
            return;
        }
        let mut specification = ExecutionSpecification {
            attempt_id: Uuid::new_v4(),
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 10_000,
            env: BTreeMap::new(),
            build_env: BTreeMap::new(),
            secret_names: Vec::new(),
            secrets: BTreeMap::from([(
                "TOKEN".into(),
                zeroize::Zeroizing::new("super-secret".into()),
            )]),
            services: Vec::new(),
            steps: Vec::new(),
        };
        specification.steps = vec![
            ExecutionStep {
                name: "write".into(),
                kind: StepKind::Run,
                value: "printf shared > continuity; printf \"%s\" \"$TOKEN\"; printf \"%s\" \"$TOKEN\" >&2"
                    .into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            },
            ExecutionStep {
                name: "read".into(),
                kind: StepKind::Run,
                value: "test \"$(cat continuity)\" = shared".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            },
        ];
        let runner = DockerCli::new(DockerConfig {
            instance: format!("rust-test-{}", specification.attempt_id),
            ..DockerConfig::default()
        });
        let control = RecordingControl::default();
        let result = runner
            .run_controlled(
                &specification,
                ExecutionControl {
                    output: &control,
                    cancellation: &control,
                    last_sequence: 40,
                },
            )
            .await
            .expect("Docker execution");
        assert_eq!(result.status, ExecutionStatus::Succeeded);
        let chunks = control.chunks.lock().expect("output lock").clone();
        assert!(
            chunks
                .iter()
                .any(|chunk| chunk.channel == OutputChannel::Stdout)
        );
        assert!(
            chunks
                .iter()
                .any(|chunk| chunk.channel == OutputChannel::Stderr)
        );
        assert_eq!(chunks.first().expect("first chunk").sequence, 41);
        assert!(
            chunks
                .windows(2)
                .all(|pair| pair[1].sequence == pair[0].sequence + 1)
        );
        assert!(chunks.iter().all(|chunk| chunk.bytes.len() <= 16_384));
        assert!(chunks.iter().all(|chunk| {
            !chunk
                .bytes
                .windows(12)
                .any(|window| window == b"super-secret")
        }));
        assert_eq!(
            chunks
                .iter()
                .filter(|chunk| chunk.bytes == b"[REDACTED]")
                .count(),
            2
        );
        assert_job_resources_cleaned(&runner, specification.attempt_id).await;
    }

    async fn assert_job_resources_cleaned(runner: &DockerCli, attempt_id: Uuid) {
        let container = format!("robine-job-{}", attempt_id.simple());
        let volume = format!("robine-workspace-{}", attempt_id.simple());
        assert!(
            !runner
                .command(&["container", "inspect", &container])
                .await
                .expect("inspect container")
                .status
                .success()
        );
        assert!(
            !runner
                .command(&["volume", "inspect", &volume])
                .await
                .expect("inspect volume")
                .status
                .success()
        );
    }

    #[tokio::test]
    async fn cancellation_stops_the_active_container_when_enabled() {
        if std::env::var_os("ROBINE_DOCKER_INTEGRATION").is_none() {
            return;
        }
        let specification = ExecutionSpecification {
            attempt_id: Uuid::new_v4(),
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 30_000,
            env: BTreeMap::new(),
            build_env: BTreeMap::new(),
            secret_names: Vec::new(),
            secrets: BTreeMap::new(),
            services: Vec::new(),
            steps: vec![ExecutionStep {
                name: "wait".into(),
                kind: StepKind::Run,
                value: "sleep 30".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            }],
        };
        let runner = DockerCli::new(DockerConfig {
            instance: format!("rust-test-{}", specification.attempt_id),
            ..DockerConfig::default()
        });
        let control = RecordingControl {
            cancel: true,
            ..RecordingControl::default()
        };
        let started = std::time::Instant::now();
        let result = runner
            .run_controlled(
                &specification,
                ExecutionControl {
                    output: &control,
                    cancellation: &control,
                    last_sequence: 0,
                },
            )
            .await
            .expect("cancel Docker execution");
        assert_eq!(result.status, ExecutionStatus::Cancelled);
        assert!(started.elapsed() < std::time::Duration::from_secs(10));
    }

    #[tokio::test]
    async fn private_service_is_ready_reachable_and_cleaned_when_enabled() {
        if std::env::var_os("ROBINE_DOCKER_INTEGRATION").is_none() {
            return;
        }
        let attempt_id = Uuid::new_v4();
        let specification = ExecutionSpecification {
            attempt_id,
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 20_000,
            env: BTreeMap::new(),
            build_env: BTreeMap::new(),
            secret_names: Vec::new(),
            secrets: BTreeMap::new(),
            services: vec![ServiceSpecification {
                id: "database".into(),
                image: "alpine:3.22".into(),
                user: None,
                env: BTreeMap::new(),
                secret_references: BTreeMap::new(),
                secrets: BTreeMap::new(),
                command: vec![
                    "sh".into(),
                    "-c".into(),
                    "while true; do nc -l -p 8080; done".into(),
                ],
                readiness: Some(ServiceReadiness {
                    tcp: 8080,
                    timeout_ms: 5_000,
                }),
                privileged: false,
            }],
            steps: vec![ExecutionStep {
                name: "connect".into(),
                kind: StepKind::Run,
                value: "i=0; until nc -z -w 1 database 8080; do i=$((i+1)); test $i -lt 20; sleep 0.1; done".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            }],
        };
        let runner = DockerCli::new(DockerConfig {
            instance: format!("rust-test-{attempt_id}"),
            ..DockerConfig::default()
        });
        let service_args = runner.service_create_args(
            &specification,
            &specification.services[0],
            "private-network",
            "service",
        );
        let service_command = service_args.join(" ");
        assert!(!service_command.contains("--publish"));
        assert!(!service_command.contains("/workspace"));
        assert!(!service_command.contains("docker.sock"));
        let result = runner.run(&specification).await.expect("service execution");
        assert_eq!(result.status, ExecutionStatus::Succeeded);
        let service = format!("robine-service-{}-database", attempt_id.simple());
        let network = format!("robine-net-{}", attempt_id.simple());
        assert!(
            !runner
                .command(&["container", "inspect", &service])
                .await
                .expect("inspect service")
                .status
                .success()
        );
        assert!(
            !runner
                .command(&["network", "inspect", &network])
                .await
                .expect("inspect network")
                .status
                .success()
        );
    }

    #[tokio::test]
    async fn service_exit_stops_a_running_job_when_enabled() {
        if std::env::var_os("ROBINE_DOCKER_INTEGRATION").is_none() {
            return;
        }
        let attempt_id = Uuid::new_v4();
        let specification = ExecutionSpecification {
            attempt_id,
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 30_000,
            env: BTreeMap::new(),
            build_env: BTreeMap::new(),
            secret_names: Vec::new(),
            secrets: BTreeMap::new(),
            services: vec![ServiceSpecification {
                id: "short-lived".into(),
                image: "alpine:3.22".into(),
                user: None,
                env: BTreeMap::new(),
                secret_references: BTreeMap::new(),
                secrets: BTreeMap::new(),
                command: vec!["sleep".into(), "1".into()],
                readiness: None,
                privileged: false,
            }],
            steps: vec![ExecutionStep {
                name: "long-job".into(),
                kind: StepKind::Run,
                value: "sleep 30".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            }],
        };
        let runner = DockerCli::new(DockerConfig {
            instance: format!("rust-test-{attempt_id}"),
            ..DockerConfig::default()
        });
        let started = std::time::Instant::now();
        let result = runner.run(&specification).await.expect("service liveness");
        assert_eq!(result.status, ExecutionStatus::ServiceUnavailable);
        assert!(started.elapsed() < std::time::Duration::from_secs(10));
    }
}
