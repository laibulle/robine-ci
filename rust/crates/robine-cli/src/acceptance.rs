use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs, path::Path};
use url::Url;

const MAX_FILE_BYTES: u64 = 1_048_576;
const JOURNEYS: [&str; 6] = [
    "first_run_setup",
    "sign_in",
    "connect_repository",
    "inspect_running_pipeline",
    "diagnose_failed_job",
    "cancel_and_retry",
];

pub(crate) fn verify_command(
    arguments: &[String],
    directory: &Path,
) -> Result<String, (u8, String)> {
    let mut first_pipeline = None;
    let mut accessibility = None;
    let mut manifest = None;
    let mut json_output = false;
    let mut index = 0;
    while index < arguments.len() {
        let option = &arguments[index];
        if option == "--format" {
            index += 1;
            json_output = match arguments.get(index).map(String::as_str) {
                Some("human") => false,
                Some("json") => true,
                _ => return Err(usage("--format requires human or json")),
            };
        } else {
            let target = match option.as_str() {
                "--first-pipeline" => &mut first_pipeline,
                "--accessibility" => &mut accessibility,
                "--artifact-manifest" => &mut manifest,
                _ => return Err(usage(&format!("unknown option {option}"))),
            };
            index += 1;
            let value = arguments
                .get(index)
                .ok_or_else(|| usage(&format!("{option} requires a file")))?;
            if target.replace(directory.join(value)).is_some() {
                return Err(usage(&format!("duplicate option {option}")));
            }
        }
        index += 1;
    }
    let first_pipeline = first_pipeline.ok_or_else(|| usage("--first-pipeline is required"))?;
    let accessibility = accessibility.ok_or_else(|| usage("--accessibility is required"))?;
    let manifest = manifest.ok_or_else(|| usage("--artifact-manifest is required"))?;
    let report = verify_files(&first_pipeline, &accessibility, &manifest)
        .map_err(|error| (2, format!("External acceptance evidence failed: {error}")))?;
    if json_output {
        serde_json::to_string(&report).map_err(|error| (2, error.to_string()))
    } else {
        Ok(format!(
            "External MVP acceptance evidence passed\nFirst pipeline: {}s measured ({}s excluded)\nAccessibility: {} journeys with {}",
            report["first_pipeline"]["measured_seconds"],
            report["first_pipeline"]["excluded_seconds"],
            report["accessibility"]["journeys"]
                .as_array()
                .map_or(0, Vec::len),
            report["accessibility"]["screen_reader"]
                .as_str()
                .unwrap_or("unknown")
        ))
    }
}

fn usage(message: &str) -> (u8, String) {
    (
        64,
        format!(
            "{message}\nusage: robine verify-acceptance --first-pipeline FILE --accessibility FILE --artifact-manifest FILE [--format human|json]"
        ),
    )
}

fn verify_files(first: &Path, accessibility: &Path, manifest: &Path) -> Result<Value, String> {
    let first = read_json(first)?;
    let first_report = verify_first_pipeline(&first)?;
    let manifest_content = read_regular(manifest, "artifact manifest")?;
    let manifest_digest = format!("{:x}", Sha256::digest(&manifest_content));
    if field_string(&first, "artifact_manifest_sha256")? != manifest_digest {
        return Err("artifact manifest digest mismatch".to_owned());
    }
    let artifacts = validate_manifest(&manifest_content)?;
    let accessibility_report = verify_accessibility(&read_json(accessibility)?)?;
    Ok(json!({
        "schema_version": 1,
        "mvp_external_acceptance": "passed",
        "first_pipeline": first_report,
        "accessibility": accessibility_report,
        "artifact_manifest": {"sha256": manifest_digest, "artifacts": artifacts}
    }))
}

fn read_regular(path: &Path, kind: &str) -> Result<Vec<u8>, String> {
    let metadata =
        fs::symlink_metadata(path).map_err(|error| format!("cannot read {kind}: {error}"))?;
    if !metadata.file_type().is_file() {
        return Err(format!("{kind} must be a regular file"));
    }
    if metadata.len() > MAX_FILE_BYTES {
        return Err(format!("{kind} exceeds 1 MiB"));
    }
    fs::read(path).map_err(|error| format!("cannot read {kind}: {error}"))
}

fn read_json(path: &Path) -> Result<Value, String> {
    let bytes = read_regular(path, "evidence file")?;
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| "invalid evidence JSON".to_owned())?;
    value
        .as_object()
        .ok_or_else(|| "evidence must be a JSON object".to_owned())?;
    Ok(value)
}

fn verify_first_pipeline(value: &Value) -> Result<Value, String> {
    exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "operator",
            "host",
            "started_at",
            "green_check_at",
            "excluded_intervals",
            "repository",
            "commit_sha",
            "check_url",
            "artifact_manifest_sha256",
        ],
        &["notes"],
    )?;
    exact(value, "schema_version", &json!(1))?;
    exact(value, "kind", &json!("first_pipeline"))?;
    let operator = field_object(value, "operator")?;
    exact_map_keys(operator, &["id", "new_to_robine"], &[])?;
    evidence_text(operator.get("id"), "operator.id")?;
    exact_map(operator, "new_to_robine", &json!(true))?;
    let host = field_object(value, "host")?;
    exact_map_keys(
        host,
        &["started_empty", "operating_system", "architecture"],
        &[],
    )?;
    exact_map(host, "started_empty", &json!(true))?;
    member(
        host.get("operating_system"),
        &["Ubuntu Server 24.04 LTS", "Ubuntu Server 26.04 LTS"],
        "host.operating_system",
    )?;
    member(
        host.get("architecture"),
        &["x86_64", "arm64"],
        "host.architecture",
    )?;
    let started = timestamp(field_string(value, "started_at"), "started_at")?;
    let green = timestamp(field_string(value, "green_check_at"), "green_check_at")?;
    if green < started {
        return Err("green_check_at precedes started_at".into());
    }
    let excluded = excluded_seconds(value.get("excluded_intervals"), started, green)?;
    let repository = field_string(value, "repository")?;
    if repository == "owner/repository" || !repository_slug(repository) {
        return Err("invalid repository".into());
    }
    let commit = field_string(value, "commit_sha")?;
    if !hex(commit, 40) || commit.bytes().all(|byte| byte == b'0') {
        return Err("invalid commit_sha".into());
    }
    let check_url = field_string(value, "check_url")?;
    validate_check_url(check_url, repository)?;
    let digest = field_string(value, "artifact_manifest_sha256")?;
    if !hex(digest, 64) || digest.bytes().all(|byte| byte == b'0') {
        return Err("invalid artifact_manifest_sha256".into());
    }
    let gross = (green - started).num_seconds();
    let measured = gross - excluded;
    if measured > 600 {
        return Err(format!("first pipeline took {measured}s (limit 600s)"));
    }
    Ok(
        json!({"result":"passed", "measured_seconds":measured, "gross_seconds":gross, "excluded_seconds":excluded, "repository":repository, "commit_sha":commit, "check_url":check_url}),
    )
}

fn excluded_seconds(
    value: Option<&Value>,
    started: DateTime<Utc>,
    green: DateTime<Utc>,
) -> Result<i64, String> {
    let intervals = value
        .and_then(Value::as_array)
        .ok_or_else(|| "excluded_intervals must be an array".to_owned())?;
    let mut parsed = Vec::new();
    for interval in intervals {
        exact_keys(
            interval,
            &["category", "started_at", "finished_at"],
            &["notes"],
        )?;
        member(
            interval.get("category"),
            &["external_approval", "image_download"],
            "excluded.category",
        )?;
        let from = timestamp(field_string(interval, "started_at"), "excluded.started_at")?;
        let to = timestamp(
            field_string(interval, "finished_at"),
            "excluded.finished_at",
        )?;
        if to < from || from < started || to > green {
            return Err("excluded interval outside measurement".into());
        }
        parsed.push((from, to));
    }
    parsed.sort_by_key(|(from, _)| *from);
    let mut end = None;
    let mut seconds = 0;
    for (from, to) in parsed {
        if end.is_some_and(|prior| from < prior) {
            return Err("excluded intervals overlap".into());
        }
        seconds += (to - from).num_seconds();
        end = Some(to);
    }
    Ok(seconds)
}

fn verify_accessibility(value: &Value) -> Result<Value, String> {
    exact_keys(
        value,
        &[
            "schema_version",
            "kind",
            "tested_at",
            "tester",
            "environment",
            "journeys",
            "issues",
        ],
        &["notes"],
    )?;
    exact(value, "schema_version", &json!(1))?;
    exact(value, "kind", &json!("accessibility_smoke"))?;
    let session_time = timestamp(field_string(value, "tested_at"), "tested_at")?;
    let tester = field_object(value, "tester")?;
    exact_map_keys(tester, &["id", "unfamiliar_with_implementation"], &[])?;
    evidence_text(tester.get("id"), "tester.id")?;
    exact_map(tester, "unfamiliar_with_implementation", &json!(true))?;
    let environment = field_object(value, "environment")?;
    exact_map_keys(
        environment,
        &["screen_reader", "browser", "operating_system"],
        &[],
    )?;
    for field in ["screen_reader", "browser", "operating_system"] {
        evidence_text(environment.get(field), &format!("environment.{field}"))?;
    }
    let journeys = value
        .get("journeys")
        .and_then(Value::as_array)
        .ok_or_else(|| "journeys must be an array".to_owned())?;
    if journeys.len() != JOURNEYS.len() {
        return Err("incomplete accessibility journeys".into());
    }
    let mut ids = BTreeSet::new();
    for journey in journeys {
        exact_keys(
            journey,
            &[
                "id",
                "completed",
                "keyboard_only",
                "announcements_understood",
                "focus_order_logical",
                "blocking_issues",
            ],
            &["notes"],
        )?;
        let id = field_string(journey, "id")?;
        if !JOURNEYS.contains(&id) || !ids.insert(id) {
            return Err("invalid or duplicate accessibility journey".into());
        }
        for field in [
            "completed",
            "keyboard_only",
            "announcements_understood",
            "focus_order_logical",
        ] {
            exact(journey, field, &json!(true))?;
        }
        if journey
            .get("blocking_issues")
            .and_then(Value::as_array)
            .is_none_or(|issues| !issues.is_empty())
        {
            return Err(format!("blocking accessibility issues in {id}"));
        }
    }
    let issues = value
        .get("issues")
        .and_then(Value::as_array)
        .ok_or_else(|| "issues must be an array".to_owned())?;
    for issue in issues {
        exact_keys(
            issue,
            &["severity", "description", "resolution", "reference"],
            &[],
        )?;
        let severity = field_string(issue, "severity")?;
        member(
            issue.get("severity"),
            &["minor", "moderate", "major", "critical"],
            "issue.severity",
        )?;
        evidence_text(issue.get("description"), "issue.description")?;
        evidence_text(issue.get("reference"), "issue.reference")?;
        let resolution = field_string(issue, "resolution")?;
        if resolution != "fixed"
            && !(resolution == "accepted" && matches!(severity, "minor" | "moderate"))
        {
            return Err("invalid issue resolution".into());
        }
    }
    Ok(
        json!({"result":"passed", "tested_at":session_time.to_rfc3339(), "tester_id":field_string(&Value::Object(tester.clone()), "id")?, "screen_reader":field_string(&Value::Object(environment.clone()), "screen_reader")?, "journeys":JOURNEYS}),
    )
}

fn validate_manifest(content: &[u8]) -> Result<Vec<String>, String> {
    let text =
        std::str::from_utf8(content).map_err(|_| "artifact manifest is not UTF-8".to_owned())?;
    let version = env!("CARGO_PKG_VERSION");
    let expected = [
        format!("robine-{version}"),
        format!("robine-server-{version}"),
        format!("robine-runner-{version}"),
    ];
    let mut names = Vec::new();
    for line in text.lines() {
        let (digest, name) = line
            .split_once("  ")
            .ok_or_else(|| "invalid artifact manifest line".to_owned())?;
        if !hex(digest, 64)
            || digest.bytes().all(|byte| byte == b'0')
            || !expected.iter().any(|expected| expected == name)
            || names.iter().any(|prior| prior == name)
        {
            return Err("invalid artifact manifest".into());
        }
        names.push(name.to_owned());
    }
    if names.len() != expected.len() || expected.iter().any(|name| !names.contains(name)) {
        return Err(
            "artifact manifest must contain exactly the CLI, server, and runner release binaries"
                .into(),
        );
    }
    Ok(names)
}

fn validate_check_url(raw: &str, repository: &str) -> Result<(), String> {
    let url = Url::parse(raw).map_err(|_| "invalid check_url".to_owned())?;
    let parts = url
        .path_segments()
        .map(Iterator::collect::<Vec<_>>)
        .unwrap_or_default();
    let repository_parts = repository.split('/').collect::<Vec<_>>();
    if url.scheme() != "https"
        || url.host_str() != Some("github.com")
        || url.query().is_some()
        || url.fragment().is_some()
        || parts.len() != 4
        || parts[..2] != repository_parts
        || parts[2] != "runs"
        || parts[3].parse::<u64>().ok().is_none_or(|id| id == 0)
    {
        return Err("invalid check_url".into());
    }
    Ok(())
}

fn exact_keys(value: &Value, required: &[&str], optional: &[&str]) -> Result<(), String> {
    exact_map_keys(
        value
            .as_object()
            .ok_or_else(|| "expected object".to_owned())?,
        required,
        optional,
    )
}
fn exact_map_keys(
    map: &Map<String, Value>,
    required: &[&str],
    optional: &[&str],
) -> Result<(), String> {
    if required.iter().any(|key| !map.contains_key(*key)) {
        return Err("missing evidence field".into());
    }
    if map
        .keys()
        .any(|key| !required.contains(&key.as_str()) && !optional.contains(&key.as_str()))
    {
        return Err("unknown evidence field".into());
    }
    Ok(())
}
fn exact(value: &Value, field: &str, expected: &Value) -> Result<(), String> {
    if value.get(field) == Some(expected) {
        Ok(())
    } else {
        Err(format!("invalid {field}"))
    }
}
fn exact_map(map: &Map<String, Value>, field: &str, expected: &Value) -> Result<(), String> {
    if map.get(field) == Some(expected) {
        Ok(())
    } else {
        Err(format!("invalid {field}"))
    }
}
fn field_object<'a>(value: &'a Value, field: &str) -> Result<&'a Map<String, Value>, String> {
    value
        .get(field)
        .and_then(Value::as_object)
        .ok_or_else(|| format!("invalid {field}"))
}
fn field_string<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("invalid {field}"))
}
fn evidence_text(value: Option<&Value>, field: &str) -> Result<(), String> {
    let text = value
        .and_then(Value::as_str)
        .ok_or_else(|| format!("invalid {field}"))?;
    if text.is_empty() || text.len() > 512 || text.starts_with("replace-") {
        Err(format!("placeholder or invalid {field}"))
    } else {
        Ok(())
    }
}
fn member(value: Option<&Value>, allowed: &[&str], field: &str) -> Result<(), String> {
    if value
        .and_then(Value::as_str)
        .is_some_and(|value| allowed.contains(&value))
    {
        Ok(())
    } else {
        Err(format!("invalid {field}"))
    }
}
fn timestamp(value: Result<&str, String>, field: &str) -> Result<DateTime<Utc>, String> {
    value?
        .parse::<DateTime<Utc>>()
        .map_err(|_| format!("invalid timestamp {field}"))
}
fn hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}
fn repository_slug(value: &str) -> bool {
    let parts = value.split('/').collect::<Vec<_>>();
    parts.len() == 2
        && parts.iter().all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn first_pipeline() -> Value {
        json!({
            "schema_version": 1, "kind": "first_pipeline",
            "operator": {"id":"external-tester-01", "new_to_robine":true},
            "host": {"started_empty":true, "operating_system":"Ubuntu Server 24.04 LTS", "architecture":"x86_64"},
            "started_at":"2026-08-09T10:00:00Z", "green_check_at":"2026-08-09T10:12:00Z",
            "excluded_intervals":[
                {"category":"external_approval", "started_at":"2026-08-09T10:02:00Z", "finished_at":"2026-08-09T10:03:00Z"},
                {"category":"image_download", "started_at":"2026-08-09T10:07:00Z", "finished_at":"2026-08-09T10:08:30Z"}
            ],
            "repository":"acme/widget", "commit_sha":"a".repeat(40),
            "check_url":"https://github.com/acme/widget/runs/42",
            "artifact_manifest_sha256":"b".repeat(64), "notes":"Fresh-host session"
        })
    }

    fn accessibility() -> Value {
        let journeys = JOURNEYS
            .iter()
            .map(|id| {
                json!({
                    "id":id, "completed":true, "keyboard_only":true,
                    "announcements_understood":true, "focus_order_logical":true,
                    "blocking_issues":[]
                })
            })
            .collect::<Vec<_>>();
        json!({
            "schema_version":1, "kind":"accessibility_smoke", "tested_at":"2026-08-09T12:00:00Z",
            "tester":{"id":"external-tester-02", "unfamiliar_with_implementation":true},
            "environment":{"screen_reader":"NVDA 2026.1", "browser":"Firefox 142", "operating_system":"Windows 11"},
            "journeys":journeys, "issues":[], "notes":"Completed without coaching"
        })
    }

    #[test]
    fn accepts_complete_bounded_external_evidence() {
        let report = verify_first_pipeline(&first_pipeline()).unwrap();
        assert_eq!(report["gross_seconds"], 720);
        assert_eq!(report["excluded_seconds"], 150);
        assert_eq!(report["measured_seconds"], 570);
        let report = verify_accessibility(&accessibility()).unwrap();
        assert_eq!(report["journeys"].as_array().unwrap().len(), 6);
        assert_eq!(report["screen_reader"], "NVDA 2026.1");
    }

    #[test]
    fn rejects_slow_overlapping_untrusted_and_blocking_evidence() {
        let mut slow = first_pipeline();
        slow["excluded_intervals"] = json!([]);
        assert!(verify_first_pipeline(&slow).unwrap_err().contains("720s"));
        let mut overlapping = first_pipeline();
        overlapping["excluded_intervals"][1]["started_at"] = json!("2026-08-09T10:02:30Z");
        assert!(
            verify_first_pipeline(&overlapping)
                .unwrap_err()
                .contains("overlap")
        );
        let mut wrong_url = first_pipeline();
        wrong_url["check_url"] = json!("https://example.com/acme/widget/runs/42");
        assert_eq!(
            verify_first_pipeline(&wrong_url).unwrap_err(),
            "invalid check_url"
        );
        let mut blocked = accessibility();
        blocked["journeys"][0]["blocking_issues"] = json!(["Focus is trapped"]);
        assert!(
            verify_accessibility(&blocked)
                .unwrap_err()
                .contains("first_run_setup")
        );
        let mut accepted_major = accessibility();
        accepted_major["issues"] = json!([{"severity":"major", "description":"Status is not announced", "resolution":"accepted", "reference":"issue-42"}]);
        assert_eq!(
            verify_accessibility(&accepted_major).unwrap_err(),
            "invalid issue resolution"
        );
    }

    #[test]
    fn files_are_digest_bound_to_the_exact_native_manifest() {
        let directory =
            std::env::temp_dir().join(format!("robine-acceptance-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&directory).unwrap();
        let version = env!("CARGO_PKG_VERSION");
        let manifest = format!(
            "{}  robine-{version}\n{}  robine-server-{version}\n{}  robine-runner-{version}\n",
            "1".repeat(64),
            "2".repeat(64),
            "3".repeat(64)
        );
        let digest = format!("{:x}", Sha256::digest(manifest.as_bytes()));
        let mut first = first_pipeline();
        first["artifact_manifest_sha256"] = json!(digest);
        fs::write(
            directory.join("first.json"),
            serde_json::to_vec(&first).unwrap(),
        )
        .unwrap();
        fs::write(
            directory.join("accessibility.json"),
            serde_json::to_vec(&accessibility()).unwrap(),
        )
        .unwrap();
        fs::write(directory.join("SHA256SUMS"), manifest).unwrap();
        let report = verify_files(
            &directory.join("first.json"),
            &directory.join("accessibility.json"),
            &directory.join("SHA256SUMS"),
        )
        .unwrap();
        assert_eq!(report["mvp_external_acceptance"], "passed");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn templates_are_rejected_as_placeholders() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .unwrap();
        let evidence =
            read_json(&root.join("docs/acceptance/first-pipeline.template.json")).unwrap();
        assert!(
            verify_first_pipeline(&evidence)
                .unwrap_err()
                .contains("placeholder")
        );
        let evidence =
            read_json(&root.join("docs/acceptance/accessibility.template.json")).unwrap();
        assert!(
            verify_accessibility(&evidence)
                .unwrap_err()
                .contains("placeholder")
        );
    }

    #[test]
    fn manifest_requires_the_exact_native_release_set() {
        let version = env!("CARGO_PKG_VERSION");
        let manifest = format!(
            "{}  robine-{version}\n{}  robine-server-{version}\n{}  robine-runner-{version}\n",
            "1".repeat(64),
            "2".repeat(64),
            "3".repeat(64)
        );
        assert_eq!(validate_manifest(manifest.as_bytes()).unwrap().len(), 3);
        assert!(
            validate_manifest(format!("{}  robine-server-{version}\n", "1".repeat(64)).as_bytes())
                .is_err()
        );
    }
}
