use chrono::{DateTime, Utc};
use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PipelineProjection {
    pub id: Uuid,
    pub repository_id: Uuid,
    pub workflow_name: String,
    pub commit_sha: String,
    pub status: String,
    pub inserted_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CreatePipelineInput {
    pub repository_id: Uuid,
    #[serde(default)]
    pub workflow_name: String,
    pub commit_sha: String,
    #[serde(default)]
    pub source_ref: Option<String>,
    #[serde(default = "default_trigger")]
    pub trigger: String,
    #[serde(default)]
    pub inputs: BTreeMap<String, String>,
    #[serde(default)]
    pub scheduled_for: Option<DateTime<Utc>>,
    #[serde(default)]
    pub idempotency_key: Option<String>,
    #[serde(default)]
    pub jobs: BTreeMap<String, CreateJobInput>,
    pub workflow_revision: Option<CreateWorkflowRevisionInput>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CreateJobInput {
    #[serde(default)]
    pub needs: Vec<String>,
    #[serde(default)]
    pub execution: serde_json::Value,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CreateWorkflowRevisionInput {
    pub path: String,
    pub source: String,
    #[serde(default)]
    pub sources: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
pub struct NewPipeline {
    pub id: Uuid,
    pub repository_id: Uuid,
    pub workflow_name: String,
    pub commit_sha: String,
    pub source_ref: Option<String>,
    pub trigger: String,
    pub actor: String,
    pub correlation_id: Uuid,
    pub inserted_at: DateTime<Utc>,
    pub scheduled_for: Option<DateTime<Utc>>,
    pub inputs: BTreeMap<String, String>,
    pub revision: NewWorkflowRevision,
    pub jobs: Vec<NewJob>,
    pub event_id: Uuid,
}

#[derive(Clone, Debug)]
pub struct NewWorkflowRevision {
    pub id: Uuid,
    pub path: String,
    pub source: String,
    pub digest: String,
    pub normalized_graph: serde_json::Value,
    pub included_sources: serde_json::Value,
}

#[derive(Clone, Debug)]
pub struct NewJob {
    pub id: Uuid,
    pub key: String,
    pub status: JobState,
    pub needs: Vec<String>,
    pub position: i32,
    pub execution: serde_json::Value,
}

fn default_trigger() -> String {
    "manual".into()
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum InvalidPipelineInput {
    #[error("workflow name is required")]
    WorkflowName,
    #[error("commit SHA must contain 40 lowercase hexadecimal characters")]
    CommitSha,
    #[error("pipeline metadata exceeds its bound")]
    Metadata,
    #[error("manual inputs violate their bounds")]
    Inputs,
    #[error("pipeline must contain at most 64 jobs")]
    JobLimit,
    #[error("job identifier is invalid")]
    JobIdentifier,
    #[error("job dependency is invalid")]
    JobDependency,
    #[error("job graph contains a cycle")]
    JobCycle,
    #[error("workflow revision is invalid")]
    WorkflowRevision,
}

impl CreatePipelineInput {
    /// Validates delivery-independent pipeline creation bounds and graph invariants.
    ///
    /// # Errors
    ///
    /// Returns a stable [`InvalidPipelineInput`] category for malformed metadata,
    /// jobs, dependencies, cycles, inputs, or immutable revision sources.
    pub fn validate(&self) -> Result<(), InvalidPipelineInput> {
        if self.workflow_name.is_empty() || self.workflow_name.len() > 255 {
            return Err(InvalidPipelineInput::WorkflowName);
        }
        if self.commit_sha.len() != 40
            || !self
                .commit_sha
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(InvalidPipelineInput::CommitSha);
        }
        if self.trigger.is_empty()
            || self.trigger.len() > 255
            || self
                .source_ref
                .as_ref()
                .is_some_and(|value| value.len() > 255)
        {
            return Err(InvalidPipelineInput::Metadata);
        }
        if self.inputs.len() > 16
            || self
                .inputs
                .iter()
                .any(|(key, value)| key.len() > 31 || value.len() > 1_024)
        {
            return Err(InvalidPipelineInput::Inputs);
        }
        validate_jobs(&self.jobs)?;
        if let Some(revision) = &self.workflow_revision {
            validate_revision(revision)?;
        }
        Ok(())
    }
}

fn validate_jobs(jobs: &BTreeMap<String, CreateJobInput>) -> Result<(), InvalidPipelineInput> {
    if jobs.len() > 64 {
        return Err(InvalidPipelineInput::JobLimit);
    }
    for (key, job) in jobs {
        if !valid_job_key(key) {
            return Err(InvalidPipelineInput::JobIdentifier);
        }
        let unique = job.needs.iter().collect::<HashSet<_>>();
        if unique.len() != job.needs.len()
            || job
                .needs
                .iter()
                .any(|dependency| dependency == key || !jobs.contains_key(dependency.as_str()))
        {
            return Err(InvalidPipelineInput::JobDependency);
        }
        if !job.execution.is_null() && !job.execution.is_object() {
            return Err(InvalidPipelineInput::JobDependency);
        }
        let condition = job
            .execution
            .get("condition")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("success");
        if !matches!(condition, "success" | "failure" | "always")
            || (condition == "failure" && job.needs.is_empty())
        {
            return Err(InvalidPipelineInput::JobDependency);
        }
    }
    let mut marks = HashMap::new();
    for key in jobs.keys() {
        visit_job(key, jobs, &mut marks)?;
    }
    Ok(())
}

fn visit_job<'a>(
    key: &'a str,
    jobs: &'a BTreeMap<String, CreateJobInput>,
    marks: &mut HashMap<&'a str, u8>,
) -> Result<(), InvalidPipelineInput> {
    match marks.get(key) {
        Some(1) => return Err(InvalidPipelineInput::JobCycle),
        Some(2) => return Ok(()),
        _ => {}
    }
    marks.insert(key, 1);
    for dependency in &jobs[key].needs {
        visit_job(dependency, jobs, marks)?;
    }
    marks.insert(key, 2);
    Ok(())
}

fn valid_job_key(key: &str) -> bool {
    let (base, matrix) = key
        .strip_suffix(']')
        .and_then(|key| key.split_once('['))
        .map_or((key, None), |(base, matrix)| (base, Some(matrix)));
    valid_base_job_key(base)
        && key.len() <= 255
        && matrix.is_none_or(|matrix| {
            !matrix.is_empty()
                && matrix.split(',').all(|entry| {
                    entry.split_once('=').is_some_and(|(axis, value)| {
                        valid_matrix_axis(axis) && valid_matrix_value(value)
                    })
                })
        })
}

fn valid_base_job_key(key: &str) -> bool {
    (1..=63).contains(&key.len())
        && key.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && key
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"_-".contains(&byte))
}

fn valid_matrix_axis(value: &str) -> bool {
    (1..=31).contains(&value.len())
        && value.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn valid_matrix_value(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn validate_revision(revision: &CreateWorkflowRevisionInput) -> Result<(), InvalidPipelineInput> {
    if revision.path.is_empty()
        || revision.path.len() > 255
        || revision.source.len() > 262_144
        || revision.sources.len() > 16
        || revision
            .sources
            .iter()
            .any(|(path, source)| path.is_empty() || path.len() > 256 || source.len() > 262_144)
        || revision.sources.values().map(String::len).sum::<usize>() > 4_194_304
    {
        Err(InvalidPipelineInput::WorkflowRevision)
    } else {
        Ok(())
    }
}

#[must_use]
pub fn source_digest(source: &str) -> String {
    format!("{:x}", Sha256::digest(source.as_bytes()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PipelineState {
    Created,
    Queued,
    Running,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled,
    Invalid,
}

impl PipelineState {
    /// Queues a created pipeline and treats already dispatched states idempotently.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidTransition`] for cancelling or terminal pipelines.
    pub fn queue(self) -> Result<Self, InvalidTransition> {
        match self {
            Self::Created => Ok(Self::Queued),
            Self::Queued | Self::Running => Ok(self),
            state => Err(InvalidTransition {
                state,
                event: PipelineEvent::Queue,
            }),
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Cancelling => "cancelling",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Invalid => "invalid",
        }
    }
}

impl TryFrom<&str> for PipelineState {
    type Error = UnknownPipelineState;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "created" => Ok(Self::Created),
            "queued" => Ok(Self::Queued),
            "running" => Ok(Self::Running),
            "cancelling" => Ok(Self::Cancelling),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            "invalid" => Ok(Self::Invalid),
            unknown => Err(UnknownPipelineState(unknown.into())),
        }
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
#[error("unknown pipeline state: {0}")]
pub struct UnknownPipelineState(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PipelineEvent {
    Queue,
    Start,
    RequestCancellation,
    Succeed,
    Fail,
    Cancel,
    Invalidate,
}

#[derive(Debug, Error, Eq, PartialEq)]
#[error("pipeline cannot apply {event:?} while {state:?}")]
pub struct InvalidTransition {
    pub state: PipelineState,
    pub event: PipelineEvent,
}

impl PipelineState {
    /// Applies one domain event to the current pipeline state.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidTransition`] when the event is not valid for the
    /// current state, including every transition from a terminal state.
    pub fn transition(self, event: PipelineEvent) -> Result<Self, InvalidTransition> {
        use PipelineEvent as Event;
        use PipelineState as State;

        match (self, event) {
            (State::Created, Event::Queue) => Ok(State::Queued),
            (State::Created, Event::Invalidate) => Ok(State::Invalid),
            (State::Queued, Event::Start) => Ok(State::Running),
            (State::Queued | State::Running, Event::RequestCancellation) => Ok(State::Cancelling),
            (State::Running, Event::Succeed) => Ok(State::Succeeded),
            (State::Running, Event::Fail) => Ok(State::Failed),
            (State::Running | State::Cancelling, Event::Cancel) => Ok(State::Cancelled),
            _ => Err(InvalidTransition { state: self, event }),
        }
    }

    /// Applies the idempotent user cancellation policy.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidTransition`] when the pipeline is already terminal.
    pub fn request_cancellation(self) -> Result<Self, InvalidTransition> {
        match self {
            Self::Created | Self::Queued => Ok(Self::Cancelled),
            Self::Running | Self::Cancelling => Ok(Self::Cancelling),
            terminal => Err(InvalidTransition {
                state: terminal,
                event: PipelineEvent::RequestCancellation,
            }),
        }
    }

    /// Reopens only a failed or cancelled pipeline for a deliberate retry.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidTransition`] for every non-retryable state.
    pub fn reopen_for_retry(self) -> Result<Self, InvalidTransition> {
        match self {
            Self::Failed | Self::Cancelled => Ok(Self::Running),
            state => Err(InvalidTransition {
                state,
                event: PipelineEvent::Start,
            }),
        }
    }

    /// Derives the terminal pipeline result once every job is terminal.
    ///
    /// # Errors
    ///
    /// Returns [`InvalidTransition`] only when the derived transition is inconsistent.
    pub fn complete_from_jobs(self, jobs: &[JobState]) -> Result<Self, InvalidTransition> {
        if !matches!(self, Self::Running | Self::Cancelling)
            || jobs.is_empty()
            || jobs.iter().any(|state| !state.terminal())
        {
            return Ok(self);
        }
        let target = if self == Self::Cancelling {
            Self::Cancelled
        } else if jobs.contains(&JobState::Failed) {
            Self::Failed
        } else if jobs.contains(&JobState::Cancelled) {
            Self::Cancelled
        } else {
            Self::Succeeded
        };
        let event = match target {
            Self::Succeeded => PipelineEvent::Succeed,
            Self::Failed => PipelineEvent::Fail,
            Self::Cancelled => PipelineEvent::Cancel,
            _ => unreachable!("terminal aggregate has a terminal target"),
        };
        self.transition(event)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JobState {
    Blocked,
    Queued,
    Running,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled,
    Skipped,
}

impl JobState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Blocked => "blocked",
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Cancelling => "cancelling",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Skipped => "skipped",
        }
    }

    #[must_use]
    pub const fn cancellation_target(self) -> Option<Self> {
        match self {
            Self::Blocked | Self::Queued => Some(Self::Cancelled),
            Self::Running => Some(Self::Cancelling),
            Self::Cancelling | Self::Succeeded | Self::Failed | Self::Cancelled | Self::Skipped => {
                None
            }
        }
    }

    /// Requeues only failed or cancelled jobs.
    ///
    /// # Errors
    ///
    /// Returns [`UnknownJobState`] with the current state when retry is not allowed.
    pub fn retry(self) -> Result<Self, UnknownJobState> {
        match self {
            Self::Failed | Self::Cancelled => Ok(Self::Queued),
            state => Err(UnknownJobState(state.as_str().into())),
        }
    }

    #[must_use]
    pub const fn terminal(self) -> bool {
        matches!(
            self,
            Self::Succeeded | Self::Failed | Self::Cancelled | Self::Skipped
        )
    }

    /// Resolves a blocked job against a terminal dependency snapshot.
    #[must_use]
    pub fn release(self, condition: &str, dependencies: &[Self]) -> Self {
        if self != Self::Blocked || dependencies.iter().any(|state| !state.terminal()) {
            return self;
        }
        if dependencies.contains(&Self::Cancelled) {
            return Self::Skipped;
        }
        match condition {
            "success" if dependencies.iter().all(|state| *state == Self::Succeeded) => Self::Queued,
            "failure" if dependencies.contains(&Self::Failed) => Self::Queued,
            "always" => Self::Queued,
            "success" | "failure" => Self::Skipped,
            _ => self,
        }
    }
}

impl TryFrom<&str> for JobState {
    type Error = UnknownJobState;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "blocked" => Ok(Self::Blocked),
            "queued" => Ok(Self::Queued),
            "running" => Ok(Self::Running),
            "cancelling" => Ok(Self::Cancelling),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            "skipped" => Ok(Self::Skipped),
            unknown => Err(UnknownJobState(unknown.into())),
        }
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
#[error("unknown or non-retryable job state: {0}")]
pub struct UnknownJobState(String);

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RetryProjection {
    pub pipeline_id: Uuid,
    pub job_id: Uuid,
    pub status: String,
    pub rerun_jobs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct AttemptProjection {
    pub id: Uuid,
    pub job_id: Uuid,
    pub number: i32,
    pub idempotency_token: Uuid,
    pub status: String,
    pub lease_expires_at: DateTime<Utc>,
    pub last_sequence: i32,
    pub result_reason: Option<String>,
}

impl AttemptProjection {
    /// Extends an active attempt lease monotonically.
    ///
    /// # Errors
    ///
    /// Returns [`AttemptHeartbeatError`] for a terminal/unknown state or invalid duration.
    pub fn heartbeat(
        &self,
        now: DateTime<Utc>,
        lease_seconds: i64,
    ) -> Result<DateTime<Utc>, AttemptHeartbeatError> {
        let state =
            AttemptState::try_from(self.status.as_str()).map_err(|_| AttemptHeartbeatError)?;
        if state.terminal() || lease_seconds <= 0 {
            return Err(AttemptHeartbeatError);
        }
        Ok(self
            .lease_expires_at
            .max(now + chrono::Duration::seconds(lease_seconds)))
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
#[error("attempt lease cannot be renewed")]
pub struct AttemptHeartbeatError;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RunnerLeaseHeartbeat {
    pub renewed_attempts: u64,
    pub pending_offer_attempt_ids: Vec<Uuid>,
    pub cancellation_requested_attempt_ids: Vec<Uuid>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunnerAuthenticationMaterial {
    pub id: Uuid,
    pub name: String,
    pub admin_state: String,
    pub credential_digests: Vec<Vec<u8>>,
}

#[derive(Clone, Debug)]
pub struct NewRunnerEnrollment {
    pub id: Uuid,
    pub token_digest: Vec<u8>,
    pub expires_at: DateTime<Utc>,
    pub created_by: Uuid,
    pub audit_id: Uuid,
    pub correlation_id: Uuid,
    pub inserted_at: DateTime<Utc>,
}

#[derive(Clone, Debug)]
pub struct ConsumeRunnerEnrollment {
    pub token_digest: Vec<u8>,
    pub runner_id: Uuid,
    pub runner_name: String,
    pub credential_id: Uuid,
    pub credential_digest: Vec<u8>,
    pub audit_id: Uuid,
    pub correlation_id: Uuid,
    pub now: DateTime<Utc>,
}

#[derive(Clone, Debug)]
pub struct RotateRunnerCredential {
    pub runner_id: Uuid,
    pub credential_id: Uuid,
    pub credential_digest: Vec<u8>,
    pub overlap_expires_at: DateTime<Utc>,
    pub actor_id: Uuid,
    pub audit_id: Uuid,
    pub correlation_id: Uuid,
    pub now: DateTime<Utc>,
}

#[derive(Clone, Debug)]
pub struct RevokeRunner {
    pub runner_id: Uuid,
    pub actor_id: Uuid,
    pub audit_id: Uuid,
    pub correlation_id: Uuid,
    pub now: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RunnerFleetEntry {
    pub id: Uuid,
    pub name: String,
    pub admin_state: String,
    pub connectivity: String,
    pub labels: Vec<String>,
    pub capabilities: serde_json::Value,
    pub protocol_version: Option<i32>,
    pub software_version: Option<String>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub active_attempts: i64,
    pub concurrency: i64,
    pub available_slots: i64,
}

#[derive(Clone, Debug)]
pub struct ConfigureRunner {
    pub runner_id: Uuid,
    pub name: String,
    pub labels: Vec<String>,
    pub admin_state: String,
    pub actor_id: Uuid,
    pub audit_id: Uuid,
    pub correlation_id: Uuid,
    pub now: DateTime<Utc>,
}

#[derive(Clone, Debug)]
pub struct SourceControlDelivery {
    pub id: String,
    pub provider: String,
    pub provider_instance: String,
    pub provider_delivery_id: String,
    pub event: String,
    pub payload: serde_json::Value,
    pub received_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RunnerCredentialProjection {
    pub runner_id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RunnerResume {
    pub attempt_id: Uuid,
    pub acknowledged_sequence: i32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RunnerReconciliation {
    pub resume: Vec<RunnerResume>,
    pub lease_lost: Vec<Uuid>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct OutboxDelivery {
    pub event_id: Uuid,
    pub dispatch_enqueued: bool,
    pub delivered: bool,
    pub attempt: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DurableJobClaim {
    pub id: Uuid,
    pub source_event_id: Uuid,
    pub kind: String,
    pub payload: serde_json::Value,
    pub claim_token: Uuid,
    pub attempt: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LocalExecutionWork {
    pub attempt: AttemptProjection,
    pub specification: serde_json::Value,
    pub last_log_sequence: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionLogChunk {
    pub id: Uuid,
    pub attempt_id: Uuid,
    pub sequence: i64,
    pub step_position: i32,
    pub step_name: String,
    pub stream: String,
    pub content: Vec<u8>,
    pub inserted_at: DateTime<Utc>,
}

#[must_use]
pub fn outbox_backoff_seconds(attempt: i32, event_id: Uuid) -> i64 {
    let exponent = u32::try_from((attempt - 1).clamp(0, 30)).unwrap_or(0);
    let base = 15_i64
        .saturating_mul(2_i64.saturating_pow(exponent))
        .min(1_790);
    let jitter = i64::from(event_id.as_bytes()[0] % 11);
    base + jitter
}

#[derive(Clone, Debug)]
pub struct SchedulerClaim {
    pub global_limit: i64,
    pub repository_limit: i64,
    pub lease_seconds: i64,
    pub attempt_id: Uuid,
    pub idempotency_token: Uuid,
    pub event_id: Uuid,
    pub now: DateTime<Utc>,
    pub runner_id: Option<Uuid>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RecordAttemptEvent {
    pub idempotency_token: Uuid,
    pub sequence: i32,
    pub status: String,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RecordRemoteAttemptEvent {
    pub idempotency_token: Uuid,
    pub message_id: String,
    pub sequence: i32,
    pub status: String,
    #[serde(default)]
    pub reason: Option<String>,
}

impl RecordRemoteAttemptEvent {
    #[must_use]
    pub fn attempt_event(&self) -> RecordAttemptEvent {
        RecordAttemptEvent {
            idempotency_token: self.idempotency_token,
            sequence: self.sequence,
            status: self.status.clone(),
            reason: self.reason.clone(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttemptState {
    Queued,
    Preparing,
    Running,
    Cancelling,
    Succeeded,
    Failed,
    Cancelled,
}

impl AttemptState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Preparing => "preparing",
            Self::Running => "running",
            Self::Cancelling => "cancelling",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    #[must_use]
    pub const fn terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Cancelled)
    }

    /// Applies one ordered runner event, returning `None` for an already-seen sequence.
    ///
    /// # Errors
    ///
    /// Returns [`AttemptEventError`] for a sequence gap, invalid reason, or transition.
    pub fn apply(
        self,
        last_sequence: i32,
        event: &RecordAttemptEvent,
    ) -> Result<Option<Self>, AttemptEventError> {
        if event.sequence <= last_sequence {
            return Ok(None);
        }
        if event.sequence != last_sequence + 1 {
            return Err(AttemptEventError::Gap {
                expected: last_sequence + 1,
                actual: event.sequence,
            });
        }
        let target = Self::try_from(event.status.as_str())
            .map_err(|_| AttemptEventError::InvalidTransition)?;
        if !valid_attempt_reason(target, event.reason.as_deref()) {
            return Err(AttemptEventError::InvalidReason);
        }
        let allowed = match self {
            Self::Queued => matches!(target, Self::Preparing | Self::Cancelled | Self::Failed),
            Self::Preparing => matches!(
                target,
                Self::Running | Self::Cancelling | Self::Cancelled | Self::Failed
            ),
            Self::Running => matches!(
                target,
                Self::Cancelling | Self::Succeeded | Self::Failed | Self::Cancelled
            ),
            Self::Cancelling => matches!(target, Self::Cancelled | Self::Failed),
            Self::Succeeded | Self::Failed | Self::Cancelled => false,
        };
        allowed
            .then_some(Some(target))
            .ok_or(AttemptEventError::InvalidTransition)
    }
}

impl TryFrom<&str> for AttemptState {
    type Error = AttemptEventError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "queued" => Ok(Self::Queued),
            "preparing" => Ok(Self::Preparing),
            "running" => Ok(Self::Running),
            "cancelling" => Ok(Self::Cancelling),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            _ => Err(AttemptEventError::InvalidTransition),
        }
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum AttemptEventError {
    #[error("attempt event sequence gap: expected {expected}, got {actual}")]
    Gap { expected: i32, actual: i32 },
    #[error("attempt event transition is invalid")]
    InvalidTransition,
    #[error("attempt result reason is invalid")]
    InvalidReason,
}

fn valid_attempt_reason(state: AttemptState, reason: Option<&str>) -> bool {
    match (state, reason) {
        (AttemptState::Failed, Some(reason)) => matches!(
            reason,
            "command_failed" | "timeout" | "runner_lost" | "service_unavailable" | "system_failure"
        ),
        (AttemptState::Cancelled, Some("cancelled")) | (_, None) => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_the_success_path() {
        let state = PipelineState::Created
            .transition(PipelineEvent::Queue)
            .and_then(|state| state.transition(PipelineEvent::Start))
            .and_then(|state| state.transition(PipelineEvent::Succeed));

        assert_eq!(state, Ok(PipelineState::Succeeded));
    }

    #[test]
    fn terminal_states_reject_transitions() {
        assert_eq!(
            PipelineState::Succeeded.transition(PipelineEvent::Start),
            Err(InvalidTransition {
                state: PipelineState::Succeeded,
                event: PipelineEvent::Start,
            })
        );
    }

    #[test]
    fn database_values_round_trip() {
        for state in [
            PipelineState::Created,
            PipelineState::Queued,
            PipelineState::Running,
            PipelineState::Cancelling,
            PipelineState::Succeeded,
            PipelineState::Failed,
            PipelineState::Cancelled,
            PipelineState::Invalid,
        ] {
            assert_eq!(PipelineState::try_from(state.as_str()), Ok(state));
        }
    }

    #[test]
    fn cancellation_is_immediate_before_dispatch_and_idempotent_while_cancelling() {
        assert_eq!(
            PipelineState::Queued.request_cancellation(),
            Ok(PipelineState::Cancelled)
        );
        assert_eq!(
            PipelineState::Running.request_cancellation(),
            Ok(PipelineState::Cancelling)
        );
        assert_eq!(
            PipelineState::Cancelling.request_cancellation(),
            Ok(PipelineState::Cancelling)
        );
        assert!(PipelineState::Succeeded.request_cancellation().is_err());
    }

    #[test]
    fn cancellation_targets_only_jobs_that_can_still_do_work() {
        assert_eq!(
            JobState::Blocked.cancellation_target(),
            Some(JobState::Cancelled)
        );
        assert_eq!(
            JobState::Running.cancellation_target(),
            Some(JobState::Cancelling)
        );
        assert_eq!(JobState::Succeeded.cancellation_target(), None);
    }

    #[test]
    fn retry_reopens_only_failed_or_cancelled_work() {
        assert_eq!(
            PipelineState::Failed.reopen_for_retry(),
            Ok(PipelineState::Running)
        );
        assert!(PipelineState::Succeeded.reopen_for_retry().is_err());
        assert_eq!(JobState::Cancelled.retry(), Ok(JobState::Queued));
        assert!(JobState::Succeeded.retry().is_err());
    }

    #[test]
    fn queue_is_idempotent_after_dispatch_but_rejects_terminal_work() {
        assert_eq!(PipelineState::Created.queue(), Ok(PipelineState::Queued));
        assert_eq!(PipelineState::Queued.queue(), Ok(PipelineState::Queued));
        assert_eq!(PipelineState::Running.queue(), Ok(PipelineState::Running));
        assert!(PipelineState::Failed.queue().is_err());
    }

    #[test]
    fn creation_validation_rejects_bad_sha_dependencies_and_cycles() {
        let mut input: CreatePipelineInput = serde_json::from_value(serde_json::json!({
            "repository_id": Uuid::nil(),
            "workflow_name": "CI",
            "commit_sha": "a".repeat(40),
            "jobs": {
                "build": {"execution": {}},
                "test": {"needs": ["build"], "execution": {}}
            }
        }))
        .expect("valid creation shape");
        assert_eq!(input.validate(), Ok(()));

        input.commit_sha = "ABC".into();
        assert_eq!(input.validate(), Err(InvalidPipelineInput::CommitSha));
        input.commit_sha = "a".repeat(40);
        input.jobs.get_mut("build").expect("build").needs = vec!["test".into()];
        assert_eq!(input.validate(), Err(InvalidPipelineInput::JobCycle));
        input.jobs.get_mut("build").expect("build").needs = vec!["missing".into()];
        assert_eq!(input.validate(), Err(InvalidPipelineInput::JobDependency));
    }

    #[test]
    fn creation_validation_accepts_only_canonical_expanded_matrix_keys() {
        assert!(valid_job_key("test[otp=27,elixir=1.18]"));
        assert!(!valid_job_key("test[]"));
        assert!(!valid_job_key("test[Bad=27]"));
        assert!(!valid_job_key("test[otp=bad value]"));
        assert!(!valid_job_key("test[otp=27"));
    }

    #[test]
    fn attempt_events_are_ordered_idempotent_and_reason_checked() {
        let preparing = RecordAttemptEvent {
            idempotency_token: Uuid::nil(),
            sequence: 1,
            status: "preparing".into(),
            reason: None,
        };
        assert_eq!(
            AttemptState::Queued.apply(0, &preparing),
            Ok(Some(AttemptState::Preparing))
        );
        assert_eq!(AttemptState::Preparing.apply(1, &preparing), Ok(None));
        let gap = RecordAttemptEvent {
            sequence: 3,
            status: "running".into(),
            ..preparing.clone()
        };
        assert_eq!(
            AttemptState::Preparing.apply(1, &gap),
            Err(AttemptEventError::Gap {
                expected: 2,
                actual: 3
            })
        );
        let failed = RecordAttemptEvent {
            sequence: 2,
            status: "failed".into(),
            reason: Some("command_failed".into()),
            ..preparing
        };
        assert_eq!(
            AttemptState::Preparing.apply(1, &failed),
            Ok(Some(AttemptState::Failed))
        );
    }

    #[test]
    fn dependency_release_and_pipeline_aggregation_match_terminal_outcomes() {
        assert_eq!(
            JobState::Blocked.release("success", &[JobState::Succeeded]),
            JobState::Queued
        );
        assert_eq!(
            JobState::Blocked.release("success", &[JobState::Failed]),
            JobState::Skipped
        );
        assert_eq!(
            JobState::Blocked.release("always", &[JobState::Cancelled]),
            JobState::Skipped
        );
        assert_eq!(
            PipelineState::Running.complete_from_jobs(&[JobState::Succeeded, JobState::Skipped]),
            Ok(PipelineState::Succeeded)
        );
        assert_eq!(
            PipelineState::Running.complete_from_jobs(&[JobState::Failed]),
            Ok(PipelineState::Failed)
        );
    }

    #[test]
    fn heartbeat_is_monotonic_sequence_neutral_and_rejects_terminal_attempts() {
        let now = Utc::now();
        let attempt = AttemptProjection {
            id: Uuid::new_v4(),
            job_id: Uuid::new_v4(),
            number: 1,
            idempotency_token: Uuid::new_v4(),
            status: "running".into(),
            lease_expires_at: now + chrono::Duration::seconds(120),
            last_sequence: 4,
            result_reason: None,
        };
        assert_eq!(attempt.heartbeat(now, 60), Ok(attempt.lease_expires_at));
        assert_eq!(
            attempt.heartbeat(now, 180),
            Ok(now + chrono::Duration::seconds(180))
        );
        let terminal = AttemptProjection {
            status: "succeeded".into(),
            ..attempt
        };
        assert_eq!(terminal.heartbeat(now, 60), Err(AttemptHeartbeatError));
    }

    #[test]
    fn outbox_backoff_is_exponential_capped_and_stably_jittered() {
        let event_id = Uuid::from_bytes([0; 16]);
        assert_eq!(outbox_backoff_seconds(1, event_id), 15);
        assert_eq!(outbox_backoff_seconds(5, event_id), 240);
        assert_eq!(outbox_backoff_seconds(20, event_id), 1_790);
        let jittered = Uuid::from_bytes([10; 16]);
        assert_eq!(outbox_backoff_seconds(1, jittered), 25);
    }
}
