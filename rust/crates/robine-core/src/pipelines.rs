use chrono::{DateTime, Utc};
use serde::Serialize;
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
            (State::Cancelling, Event::Cancel) => Ok(State::Cancelled),
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
            Self::Running => Ok(Self::Cancelling),
            Self::Cancelling => Ok(Self::Cancelling),
            terminal => Err(InvalidTransition {
                state: terminal,
                event: PipelineEvent::RequestCancellation,
            }),
        }
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
    pub const fn cancellation_target(self) -> Option<Self> {
        match self {
            Self::Blocked | Self::Queued => Some(Self::Cancelled),
            Self::Running => Some(Self::Cancelling),
            Self::Cancelling | Self::Succeeded | Self::Failed | Self::Cancelled | Self::Skipped => {
                None
            }
        }
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
}
