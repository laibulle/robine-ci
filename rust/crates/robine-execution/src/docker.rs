use crate::{
    ExecutionError, ExecutionResult, ExecutionRunner, ExecutionSpecification, ExecutionStatus,
    StepCondition, StepKind,
};
use async_trait::async_trait;
use std::collections::HashSet;
use std::process::Output;
use tokio::process::Command;

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
        specification.validate()?;
        let suffix = specification.attempt_id.simple();
        let container = format!("robine-job-{suffix}");
        let volume = format!("robine-workspace-{suffix}");
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
            self.run_container(specification, &container, &volume),
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
    ) -> Result<ExecutionResult, ExecutionError> {
        self.checked(
            &self.create_args(specification, container, volume),
            "container_create",
        )
        .await?;
        self.checked(&["start", container], "container_start")
            .await?;
        let mut failed = false;
        let mut exit_code = Some(0);
        for step in &specification.steps {
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
            let output = self
                .command(&[
                    "exec",
                    "--workdir",
                    &specification.workspace,
                    container,
                    &specification.shell,
                    "-e",
                    "-c",
                    &step.value,
                ])
                .await
                .map_err(|_| ExecutionError::Unavailable {
                    phase: "step_execute",
                })?;
            if !output.status.success() {
                failed = true;
                exit_code = output.status.code();
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

    fn create_args(
        &self,
        specification: &ExecutionSpecification,
        container: &str,
        volume: &str,
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
        for (name, value) in specification.env.iter().chain(&specification.build_env) {
            args.extend(["--env".into(), format!("{name}={value}")]);
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
    ) -> Result<ExecutionResult, ExecutionError> {
        Self::run(self, specification).await
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
    use crate::ExecutionStep;
    use std::collections::BTreeMap;
    use uuid::Uuid;

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
            steps: vec![ExecutionStep {
                name: "test".into(),
                kind: StepKind::Run,
                value: "true".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            }],
        };
        let arguments = runner.create_args(&specification, "job", "workspace");
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
            steps: Vec::new(),
        };
        specification.steps = vec![
            ExecutionStep {
                name: "write".into(),
                kind: StepKind::Run,
                value: "printf shared > continuity".into(),
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
        let result = runner.run(&specification).await.expect("Docker execution");
        assert_eq!(result.status, ExecutionStatus::Succeeded);
        let container = format!("robine-job-{}", specification.attempt_id.simple());
        let volume = format!("robine-workspace-{}", specification.attempt_id.simple());
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
}
