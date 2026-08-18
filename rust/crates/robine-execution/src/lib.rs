//! Framework-independent execution contracts and runner adapters.

mod docker;

use async_trait::async_trait;
pub use docker::{DockerCli, DockerConfig};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StepKind {
    Run,
    Builtin,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StepCondition {
    Success,
    Failure,
    Always,
}

fn success_condition() -> StepCondition {
    StepCondition::Success
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ExecutionStep {
    pub name: String,
    pub kind: StepKind,
    pub value: String,
    #[serde(default = "success_condition")]
    pub condition: StepCondition,
    #[serde(default)]
    pub with: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ExecutionSpecification {
    pub attempt_id: Uuid,
    pub image: String,
    #[serde(default = "default_workspace")]
    pub workspace: String,
    #[serde(default = "default_shell")]
    pub shell: String,
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub build_env: BTreeMap<String, String>,
    #[serde(default)]
    pub secret_names: Vec<String>,
    #[serde(skip)]
    pub secrets: BTreeMap<String, Zeroizing<String>>,
    #[serde(default)]
    pub services: Vec<ServiceSpecification>,
    pub steps: Vec<ExecutionStep>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ServiceSpecification {
    pub id: String,
    pub image: String,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default, rename = "secret_env")]
    pub secret_references: BTreeMap<String, String>,
    #[serde(skip)]
    pub secrets: BTreeMap<String, Zeroizing<String>>,
    #[serde(default)]
    pub command: Vec<String>,
    #[serde(default)]
    pub readiness: Option<ServiceReadiness>,
    #[serde(default)]
    pub privileged: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ServiceReadiness {
    pub tcp: u16,
    pub timeout_ms: u64,
}

fn default_workspace() -> String {
    "/workspace".into()
}

fn default_shell() -> String {
    "/bin/sh".into()
}

const fn default_timeout_ms() -> u64 {
    1_200_000
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutputChunk {
    pub sequence: u64,
    pub step: usize,
    pub step_name: String,
    pub channel: OutputChannel,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputChannel {
    Stdout,
    Stderr,
    System,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionResult {
    pub status: ExecutionStatus,
    pub exit_code: Option<i32>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionStatus {
    Succeeded,
    Failed,
    Cancelled,
    TimedOut,
    ServiceUnavailable,
}

#[derive(Debug, Error)]
pub enum ExecutionError {
    #[error("invalid execution specification: {0}")]
    InvalidSpecification(&'static str),
    #[error("unsupported execution capability: {0}")]
    Unsupported(&'static str),
    #[error("runner command failed during {phase}")]
    Runner { phase: &'static str },
    #[error("runner command could not be started during {phase}")]
    Unavailable { phase: &'static str },
    #[error("execution output could not be persisted")]
    Output,
}

#[async_trait]
pub trait OutputSink: Send + Sync {
    async fn append(&self, chunk: OutputChunk) -> Result<(), ExecutionError>;
}

#[async_trait]
pub trait CancellationSignal: Send + Sync {
    async fn requested(&self) -> Result<bool, ExecutionError>;
}

pub struct ExecutionControl<'a> {
    pub output: &'a dyn OutputSink,
    pub cancellation: &'a dyn CancellationSignal,
    pub last_sequence: u64,
}

#[async_trait]
pub trait ExecutionRunner: Send + Sync {
    async fn run(
        &self,
        specification: &ExecutionSpecification,
        control: ExecutionControl<'_>,
    ) -> Result<ExecutionResult, ExecutionError>;
}

impl ExecutionSpecification {
    /// Validates the stable execution boundary before any runner effect occurs.
    ///
    /// # Errors
    ///
    /// Rejects empty or unsafe boundary values and currently unsupported built-ins.
    pub fn validate(&self) -> Result<(), ExecutionError> {
        if self.image.trim().is_empty() {
            return Err(ExecutionError::InvalidSpecification("image"));
        }
        if self.workspace != "/workspace" {
            return Err(ExecutionError::InvalidSpecification("workspace"));
        }
        if self.shell.is_empty() || !self.shell.starts_with('/') {
            return Err(ExecutionError::InvalidSpecification("shell"));
        }
        if self.timeout_ms == 0 || self.steps.is_empty() {
            return Err(ExecutionError::InvalidSpecification("steps or timeout"));
        }
        if self.steps.iter().any(|step| step.name.is_empty()) {
            return Err(ExecutionError::InvalidSpecification("step name"));
        }
        if self
            .env
            .keys()
            .chain(self.build_env.keys())
            .any(|name| name.is_empty() || name.contains('=') || name.contains('\0'))
        {
            return Err(ExecutionError::InvalidSpecification("environment"));
        }
        if self
            .env
            .keys()
            .any(|name| self.build_env.contains_key(name))
        {
            return Err(ExecutionError::InvalidSpecification("reserved environment"));
        }
        if self.steps.iter().any(|step| step.kind == StepKind::Builtin) {
            return Err(ExecutionError::Unsupported("builtin step"));
        }
        if !self.secret_names.is_empty() {
            return Err(ExecutionError::Unsupported("secret resolution"));
        }
        if self.secrets.len() > 64
            || self
                .secrets
                .iter()
                .any(|(name, value)| name.is_empty() || value.is_empty() || value.len() > 65_536)
        {
            return Err(ExecutionError::InvalidSpecification("secrets"));
        }
        if self.services.len() > 8 {
            return Err(ExecutionError::InvalidSpecification("services"));
        }
        let mut service_ids = BTreeSet::new();
        for service in &self.services {
            if service.id.is_empty()
                || service.id.len() > 63
                || !service_ids.insert(&service.id)
                || !service.id.bytes().enumerate().all(|(index, byte)| {
                    byte.is_ascii_lowercase()
                        || (index > 0 && (byte.is_ascii_digit() || byte == b'-' || byte == b'_'))
                })
                || service.image.is_empty()
                || service.env.len() > 64
                || service.env.iter().any(|(name, value)| {
                    name.is_empty()
                        || name.len() > 255
                        || !name.bytes().all(|byte| {
                            byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_'
                        })
                        || value.len() > 65_536
                })
                || service.command.len() > 32
                || service
                    .command
                    .iter()
                    .any(|argument| argument.is_empty() || argument.len() > 4_096)
                || service
                    .readiness
                    .as_ref()
                    .is_some_and(|readiness| readiness.tcp == 0 || readiness.timeout_ms == 0)
            {
                return Err(ExecutionError::InvalidSpecification("service"));
            }
            if service.privileged
                && (service.id != "docker"
                    || !service.image.starts_with("docker:")
                    || !service.image.contains("dind"))
            {
                return Err(ExecutionError::InvalidSpecification("privileged service"));
            }
            if !service.secret_references.is_empty() {
                return Err(ExecutionError::Unsupported("service secret resolution"));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authoritative_environment_cannot_be_overridden() {
        let specification = ExecutionSpecification {
            attempt_id: Uuid::new_v4(),
            image: "alpine:3.22".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 1_000,
            env: BTreeMap::from([("ROBINE_BUILD_COMMIT_SHA".into(), "forged".into())]),
            build_env: BTreeMap::from([("ROBINE_BUILD_COMMIT_SHA".into(), "real".into())]),
            secret_names: Vec::new(),
            secrets: BTreeMap::new(),
            services: Vec::new(),
            steps: vec![ExecutionStep {
                name: "test".into(),
                kind: StepKind::Run,
                value: "true".into(),
                condition: StepCondition::Success,
                with: BTreeMap::new(),
            }],
        };
        assert!(matches!(
            specification.validate(),
            Err(ExecutionError::InvalidSpecification("reserved environment"))
        ));
    }
}
