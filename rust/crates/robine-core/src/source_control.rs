//! Pure normalization of authenticated source-control deliveries into pipeline triggers.

use serde::Serialize;
use serde_json::Value;

use crate::pipelines::SourceControlDelivery;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceControlTrigger {
    Push,
    Tag,
    PullRequest,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NormalizedSourceControlEvent {
    pub trigger: SourceControlTrigger,
    pub repository_provider_id: i64,
    pub commit_sha: String,
    pub source_ref: String,
    pub actor: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NormalizationOutcome {
    Event(NormalizedSourceControlEvent),
    Ignored(&'static str),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NormalizationError {
    InvalidPayload,
    InvalidCommit,
}

/// Converts one authenticated provider payload into a provider-neutral exact-SHA event.
///
/// # Errors
///
/// Returns an error when a supported event has malformed fields or a non-canonical commit/ref.
pub fn normalize(
    delivery: &SourceControlDelivery,
) -> Result<NormalizationOutcome, NormalizationError> {
    match delivery.provider.as_str() {
        "github" => github(&delivery.event, &delivery.payload),
        "gitlab" => gitlab(&delivery.event, &delivery.payload),
        "forgejo" => forgejo(&delivery.event, &delivery.payload),
        _ => Ok(NormalizationOutcome::Ignored("unsupported_provider")),
    }
}

fn github(event: &str, payload: &Value) -> Result<NormalizationOutcome, NormalizationError> {
    match event {
        "push" => push_event(payload, "github", true),
        "pull_request" => pull_request_event(
            payload,
            "github",
            &["opened", "reopened", "synchronize", "ready_for_review"],
        ),
        _ => Ok(NormalizationOutcome::Ignored("unsupported_event")),
    }
}

fn gitlab(event: &str, payload: &Value) -> Result<NormalizationOutcome, NormalizationError> {
    match event {
        "push" | "Push Hook" => push_event(payload, "gitlab", false),
        "merge_request" | "Merge Request Hook" => gitlab_merge_request(payload),
        _ => Ok(NormalizationOutcome::Ignored("unsupported_event")),
    }
}

fn forgejo(event: &str, payload: &Value) -> Result<NormalizationOutcome, NormalizationError> {
    match event {
        "push" => push_event(payload, "forgejo", false),
        "pull_request" => pull_request_event(
            payload,
            "forgejo",
            &["opened", "reopened", "synchronize", "synchronized"],
        ),
        _ => Ok(NormalizationOutcome::Ignored("unsupported_event")),
    }
}

fn push_event(
    payload: &Value,
    provider: &str,
    tags: bool,
) -> Result<NormalizationOutcome, NormalizationError> {
    let repository_id = integer_at(payload, &["repository", "id"])
        .or_else(|| integer_at(payload, &["project", "id"]))
        .ok_or(NormalizationError::InvalidPayload)?;
    let source_ref = string_at(payload, &["ref"]).ok_or(NormalizationError::InvalidPayload)?;
    let (trigger, source_ref) = if let Some(branch) = source_ref.strip_prefix("refs/heads/") {
        (SourceControlTrigger::Push, branch)
    } else if tags {
        let tag = source_ref
            .strip_prefix("refs/tags/")
            .ok_or(NormalizationError::InvalidPayload)?;
        (SourceControlTrigger::Tag, tag)
    } else {
        return Ok(NormalizationOutcome::Ignored("unsupported_ref"));
    };
    let commit_sha = if trigger == SourceControlTrigger::Tag {
        string_at(payload, &["head_commit", "id"]).or_else(|| string_at(payload, &["after"]))
    } else {
        string_at(payload, &["after"])
    }
    .ok_or(NormalizationError::InvalidPayload)?;
    event(
        trigger,
        repository_id,
        commit_sha,
        source_ref,
        actor(provider, payload),
    )
}

fn pull_request_event(
    payload: &Value,
    provider: &str,
    allowed_actions: &[&str],
) -> Result<NormalizationOutcome, NormalizationError> {
    let action = string_at(payload, &["action"]).ok_or(NormalizationError::InvalidPayload)?;
    if !allowed_actions.contains(&action) {
        return Ok(NormalizationOutcome::Ignored("pull_request_action"));
    }
    if payload
        .pointer("/pull_request/draft")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return Ok(NormalizationOutcome::Ignored("draft_pull_request"));
    }
    let repository_id =
        integer_at(payload, &["repository", "id"]).ok_or(NormalizationError::InvalidPayload)?;
    let head_name = string_at(payload, &["pull_request", "head", "repo", "full_name"])
        .ok_or(NormalizationError::InvalidPayload)?;
    let base_name = string_at(payload, &["pull_request", "base", "repo", "full_name"])
        .ok_or(NormalizationError::InvalidPayload)?;
    if head_name != base_name {
        return Ok(NormalizationOutcome::Ignored("fork_pull_request"));
    }
    let sha = string_at(payload, &["pull_request", "head", "sha"])
        .ok_or(NormalizationError::InvalidPayload)?;
    let branch = string_at(payload, &["pull_request", "base", "ref"])
        .ok_or(NormalizationError::InvalidPayload)?;
    event(
        SourceControlTrigger::PullRequest,
        repository_id,
        sha,
        branch,
        actor(provider, payload),
    )
}

fn gitlab_merge_request(payload: &Value) -> Result<NormalizationOutcome, NormalizationError> {
    let attributes = payload
        .get("object_attributes")
        .ok_or(NormalizationError::InvalidPayload)?;
    let action = string_at(attributes, &["action"]).ok_or(NormalizationError::InvalidPayload)?;
    if !["open", "reopen", "update"].contains(&action) {
        return Ok(NormalizationOutcome::Ignored("pull_request_action"));
    }
    let title = string_at(attributes, &["title"]).unwrap_or_default();
    let draft_title = {
        let lower = title.to_ascii_lowercase();
        lower.starts_with("draft:") || lower.starts_with("wip:")
    };
    if attributes.get("draft").and_then(Value::as_bool) == Some(true) || draft_title {
        return Ok(NormalizationOutcome::Ignored("draft_pull_request"));
    }
    let source =
        integer_at(attributes, &["source_project_id"]).ok_or(NormalizationError::InvalidPayload)?;
    let target =
        integer_at(attributes, &["target_project_id"]).ok_or(NormalizationError::InvalidPayload)?;
    if source != target {
        return Ok(NormalizationOutcome::Ignored("fork_pull_request"));
    }
    event(
        SourceControlTrigger::PullRequest,
        integer_at(payload, &["project", "id"]).ok_or(NormalizationError::InvalidPayload)?,
        string_at(attributes, &["last_commit", "id"]).ok_or(NormalizationError::InvalidPayload)?,
        string_at(attributes, &["target_branch"]).ok_or(NormalizationError::InvalidPayload)?,
        actor("gitlab", payload),
    )
}

fn event(
    trigger: SourceControlTrigger,
    repository_provider_id: i64,
    commit_sha: &str,
    source_ref: &str,
    actor: String,
) -> Result<NormalizationOutcome, NormalizationError> {
    if commit_sha.len() != 40
        || !commit_sha
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || source_ref.is_empty()
        || source_ref.len() > 255
    {
        return Err(NormalizationError::InvalidCommit);
    }
    Ok(NormalizationOutcome::Event(NormalizedSourceControlEvent {
        trigger,
        repository_provider_id,
        commit_sha: commit_sha.into(),
        source_ref: source_ref.into(),
        actor,
    }))
}

fn actor(provider: &str, payload: &Value) -> String {
    let value = match provider {
        "github" | "forgejo" => string_at(payload, &["sender", "login"])
            .or_else(|| string_at(payload, &["pusher", "name"])),
        "gitlab" => string_at(payload, &["user_username"])
            .or_else(|| string_at(payload, &["user", "username"])),
        _ => None,
    };
    let value = value.filter(|value| !value.is_empty()).unwrap_or("unknown");
    format!("{provider}:{}", value.chars().take(240).collect::<String>())
}

fn integer_at(value: &Value, path: &[&str]) -> Option<i64> {
    path.iter()
        .try_fold(value, |current, key| current.get(key))?
        .as_i64()
}

fn string_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter()
        .try_fold(value, |current, key| current.get(key))?
        .as_str()
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use serde_json::json;

    use super::*;

    fn delivery(provider: &str, event: &str, payload: Value) -> SourceControlDelivery {
        SourceControlDelivery {
            id: "delivery".into(),
            provider: provider.into(),
            provider_instance: "default".into(),
            provider_delivery_id: "provider-delivery".into(),
            event: event.into(),
            payload,
            received_at: Utc::now(),
        }
    }

    #[test]
    fn normalizes_pushes_tags_and_change_requests_at_exact_shas() {
        let sha = "a".repeat(40);
        let github = normalize(&delivery(
            "github",
            "push",
            json!({"repository":{"id":1},"after":sha,"ref":"refs/tags/v1","head_commit":{"id":"b".repeat(40)},"sender":{"login":"octo"}}),
        ))
        .expect("github tag");
        assert!(
            matches!(github, NormalizationOutcome::Event(NormalizedSourceControlEvent { trigger: SourceControlTrigger::Tag, commit_sha, source_ref, .. }) if commit_sha == "b".repeat(40) && source_ref == "v1")
        );

        let gitlab = normalize(&delivery(
            "gitlab",
            "Merge Request Hook",
            json!({"project":{"id":2},"object_attributes":{"action":"update","source_project_id":2,"target_project_id":2,"last_commit":{"id":sha},"target_branch":"main"},"user_username":"alice"}),
        ))
        .expect("gitlab merge request");
        assert!(matches!(
            gitlab,
            NormalizationOutcome::Event(NormalizedSourceControlEvent {
                trigger: SourceControlTrigger::PullRequest,
                repository_provider_id: 2,
                ..
            })
        ));

        let forgejo = normalize(&delivery(
            "forgejo",
            "push",
            json!({"repository":{"id":3},"after":sha,"ref":"refs/heads/main"}),
        ))
        .expect("forgejo push");
        assert!(matches!(
            forgejo,
            NormalizationOutcome::Event(NormalizedSourceControlEvent {
                trigger: SourceControlTrigger::Push,
                repository_provider_id: 3,
                ..
            })
        ));
    }

    #[test]
    fn ignores_drafts_forks_and_irrelevant_actions() {
        let sha = "a".repeat(40);
        for payload in [
            json!({"action":"closed"}),
            json!({"action":"opened","pull_request":{"draft":true}}),
            json!({"action":"opened","repository":{"id":1},"pull_request":{"draft":false,"head":{"sha":sha,"repo":{"full_name":"fork/repo"}},"base":{"ref":"main","repo":{"full_name":"upstream/repo"}}}}),
        ] {
            assert!(matches!(
                normalize(&delivery("github", "pull_request", payload)).expect("ignored event"),
                NormalizationOutcome::Ignored(_)
            ));
        }
    }

    #[test]
    fn rejects_noncanonical_commits_and_oversized_refs() {
        let payload = json!({"repository":{"id":1},"after":"A".repeat(40),"ref":"refs/heads/main"});
        assert_eq!(
            normalize(&delivery("github", "push", payload)),
            Err(NormalizationError::InvalidCommit)
        );
    }
}
