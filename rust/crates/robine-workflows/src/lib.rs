//! Pure parsing and validation for Robine workflow schema version 1.

use serde::{Deserialize, Serialize};
use serde_json::{Map as JsonMap, Value as JsonValue, json};
use serde_yaml_ng::{Mapping, Value as YamlValue};
use std::collections::{BTreeMap, BTreeSet, HashMap};

mod composition;
pub use composition::{ResolvedWorkflow, resolve};

const ROOT_KEYS: &[&str] = &["version", "name", "on", "jobs"];
const JOB_KEYS: &[&str] = &[
    "image", "needs", "steps", "timeout", "shell", "env", "secrets", "services", "runs-on", "if",
    "strategy",
];
const STEP_KEYS: &[&str] = &["name", "run", "uses", "with", "if"];
const SERVICE_KEYS: &[&str] = &[
    "image",
    "user",
    "env",
    "secret-env",
    "command",
    "readiness",
    "privileged",
];
const BUILTINS: &[&str] = &[
    "checkout",
    "cache/restore",
    "cache/save",
    "artifacts/upload",
    "artifacts/download",
];
const BUILD_ENVIRONMENT: &[&str] = &[
    "ROBINE_BUILD_COMMIT_SHA",
    "ROBINE_BUILD_REF_NAME",
    "ROBINE_BUILD_REF_TYPE",
    "ROBINE_BUILD_TIMESTAMP",
    "ROBINE_BUILD_PIPELINE_ID",
    "ROBINE_BUILD_TRIGGER",
];

#[derive(Clone, Debug, Eq, PartialEq)]
struct InputDefinition {
    kind: InputKind,
    required: bool,
    default: Option<String>,
    options: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InputKind {
    String,
    Choice,
    Boolean,
}

type InputDefinitions = BTreeMap<String, InputDefinition>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkflowLimits {
    pub max_bytes: usize,
    pub max_jobs: usize,
    pub max_steps_per_job: usize,
    pub max_total_steps: usize,
    pub max_graph_depth: usize,
}

impl Default for WorkflowLimits {
    fn default() -> Self {
        Self {
            max_bytes: 262_144,
            max_jobs: 64,
            max_steps_per_job: 128,
            max_total_steps: 512,
            max_graph_depth: 16,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(untagged)]
pub enum PathSegment {
    Key(String),
    Index(usize),
}

impl From<&str> for PathSegment {
    fn from(value: &str) -> Self {
        Self::Key(value.into())
    }
}

impl From<String> for PathSegment {
    fn from(value: String) -> Self {
        Self::Key(value)
    }
}

impl From<usize> for PathSegment {
    fn from(value: usize) -> Self {
        Self::Index(value)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Diagnostic {
    pub code: String,
    pub message: String,
    pub path: Vec<PathSegment>,
    pub line: usize,
    pub column: usize,
    pub source_path: String,
    pub severity: DiagnosticSeverity,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSeverity {
    Error,
    Warning,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PipelineJob {
    pub needs: Vec<String>,
    pub execution: JsonValue,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedWorkflow {
    pub version: u64,
    pub name: String,
    pub triggers: JsonValue,
    pub jobs: BTreeMap<String, PipelineJob>,
    pub order: Vec<String>,
    pub warnings: Vec<Diagnostic>,
    dispatch_inputs: InputDefinitions,
    call_inputs: InputDefinitions,
}

impl ValidatedWorkflow {
    /// Normalizes submitted values for the selected trigger, including defaults.
    ///
    /// # Errors
    ///
    /// Returns a stable diagnostic for an undeclared trigger or invalid submitted value.
    pub fn normalized_inputs(
        &self,
        trigger: &str,
        inputs: &BTreeMap<String, String>,
    ) -> Result<BTreeMap<String, String>, Diagnostic> {
        let definitions = match trigger {
            "manual" | "workflow_dispatch" => &self.dispatch_inputs,
            "workflow_call" => &self.call_inputs,
            _ if inputs.is_empty() => return Ok(BTreeMap::new()),
            _ => {
                return Err(unlocated_diagnostic(
                    "manual_input.trigger",
                    "inputs are accepted only by an input-bearing trigger",
                    vec!["on".into()],
                ));
            }
        };
        normalize_submitted_inputs(definitions, inputs, trigger == "workflow_call")
    }

    /// Produces pipeline job inputs and injects only declared trigger input environments.
    ///
    /// # Errors
    ///
    /// Returns a stable diagnostic when a supplied input is not declared for the selected trigger.
    pub fn pipeline_jobs(
        &self,
        trigger: &str,
        inputs: &BTreeMap<String, String>,
    ) -> Result<BTreeMap<String, PipelineJob>, Diagnostic> {
        let trigger_key = match trigger {
            "manual" | "workflow_dispatch" => "workflow_dispatch",
            other => other,
        };
        if self.triggers.get(trigger_key).is_none() {
            return Err(unlocated_diagnostic(
                "workflow.trigger",
                "workflow does not declare the selected trigger",
                vec!["on".into()],
            ));
        }
        let prefix = match trigger {
            "manual" | "workflow_dispatch" => "ROBINE_INPUT_",
            "workflow_call" => "ROBINE_CALL_INPUT_",
            _ => return Ok(self.jobs.clone()),
        };
        let normalized = self.normalized_inputs(trigger, inputs)?;
        let mut jobs = self.jobs.clone();
        for job in jobs.values_mut() {
            let Some(execution) = job.execution.as_object_mut() else {
                return Err(unlocated_diagnostic(
                    "workflow.internal",
                    "validated job execution is invalid",
                    vec!["jobs".into()],
                ));
            };
            let Some(environment) = execution
                .entry("env")
                .or_insert_with(|| json!({}))
                .as_object_mut()
            else {
                return Err(unlocated_diagnostic(
                    "workflow.internal",
                    "validated job environment is invalid",
                    vec!["jobs".into()],
                ));
            };
            for (name, value) in &normalized {
                environment.insert(
                    format!("{prefix}{}", name.to_ascii_uppercase()),
                    JsonValue::String(value.clone()),
                );
            }
        }
        Ok(jobs)
    }
}

/// Reports whether a path is a canonical, directly nested Robine workflow path.
#[must_use]
pub fn valid_workflow_path(path: &str) -> bool {
    let Some(file_name) = path.strip_prefix(".robine-ci/workflows/") else {
        return false;
    };
    !file_name.is_empty()
        && file_name.len() <= 256 - ".robine-ci/workflows/".len()
        && !file_name.contains(['/', '\\'])
        && matches!(
            std::path::Path::new(file_name)
                .extension()
                .and_then(std::ffi::OsStr::to_str),
            Some("yml" | "yaml")
        )
}

#[derive(Clone)]
struct Job {
    id: String,
    base_id: String,
    image: String,
    needs: Vec<String>,
    condition: String,
    shell: String,
    timeout_ms: Option<u64>,
    env: BTreeMap<String, String>,
    secrets: Vec<String>,
    services: BTreeMap<String, JsonValue>,
    runs_on: Vec<String>,
    steps: Vec<JsonValue>,
    matrix: BTreeMap<String, Vec<String>>,
    matrix_values: BTreeMap<String, String>,
}

/// Parses and validates one immutable workflow revision without executing code or resolving I/O.
///
/// # Errors
///
/// Returns source-located, stable diagnostics for YAML, schema, semantic, graph, and limit errors.
pub fn parse(
    source: &str,
    source_path: &str,
    limits: &WorkflowLimits,
) -> Result<ValidatedWorkflow, Vec<Diagnostic>> {
    let index = SourceIndex::new(source);
    if source.len() > limits.max_bytes {
        return Err(vec![index.diagnostic(
            source_path,
            "workflow.limit_bytes",
            "workflow exceeds its configured byte limit",
            &[],
        )]);
    }
    let document: YamlValue = serde_yaml_ng::from_str(source).map_err(|error| {
        let location = error.location();
        vec![Diagnostic {
            code: "workflow.yaml".into(),
            message: "workflow YAML is invalid".into(),
            path: Vec::new(),
            line: location.as_ref().map_or(1, serde_yaml_ng::Location::line),
            column: location.as_ref().map_or(1, serde_yaml_ng::Location::column),
            source_path: source_path.into(),
            severity: DiagnosticSeverity::Error,
        }]
    })?;
    validate_document(&document, source_path, limits, &index)
}

#[allow(clippy::too_many_lines)]
fn validate_document(
    document: &YamlValue,
    source_path: &str,
    limits: &WorkflowLimits,
    index: &SourceIndex,
) -> Result<ValidatedWorkflow, Vec<Diagnostic>> {
    let root = document.as_mapping().ok_or_else(|| {
        vec![index.diagnostic(source_path, "workflow.type", "workflow must be a map", &[])]
    })?;
    let unknown = unknown_keys(root, ROOT_KEYS, &[]);
    if !unknown.is_empty() {
        return Err(locate_all(index, source_path, unknown));
    }
    if yaml_u64(root, "version") != Some(1) {
        return Err(vec![index.diagnostic(
            source_path,
            "workflow.version",
            "version must be 1",
            &["version".into()],
        )]);
    }
    let Some(name) = yaml_string(root, "name").filter(|name| !name.is_empty()) else {
        return Err(vec![index.diagnostic(
            source_path,
            "workflow.name",
            "name must be a non-empty string",
            &["name".into()],
        )]);
    };
    let triggers = yaml_get(root, "on")
        .and_then(YamlValue::as_mapping)
        .ok_or_else(|| {
            vec![index.diagnostic(
                source_path,
                "workflow.triggers",
                "on must contain a trigger",
                &["on".into()],
            )]
        })?;
    if triggers.is_empty() {
        return Err(vec![index.diagnostic(
            source_path,
            "workflow.triggers",
            "on must contain a trigger",
            &["on".into()],
        )]);
    }
    let (dispatch_inputs, call_inputs) = validate_triggers(triggers)
        .map_err(|diagnostics| locate_all(index, source_path, diagnostics))?;
    let jobs_value = yaml_get(root, "jobs")
        .and_then(YamlValue::as_mapping)
        .ok_or_else(|| {
            vec![index.diagnostic(
                source_path,
                "workflow.jobs",
                "jobs must be a non-empty map",
                &["jobs".into()],
            )]
        })?;
    if jobs_value.is_empty() {
        return Err(vec![index.diagnostic(
            source_path,
            "workflow.jobs",
            "jobs must be a non-empty map",
            &["jobs".into()],
        )]);
    }
    if jobs_value.len() > limits.max_jobs {
        return Err(vec![index.diagnostic(
            source_path,
            "workflow.limit_jobs",
            "workflow exceeds its configured job limit",
            &["jobs".into()],
        )]);
    }
    let mut jobs = BTreeMap::new();
    let mut warnings = Vec::new();
    let mut errors = Vec::new();
    for (id, definition) in string_entries(jobs_value) {
        match validate_job(&id, definition, limits) {
            Ok((job, mut job_warnings)) => {
                warnings.append(&mut job_warnings);
                jobs.insert(id, job);
            }
            Err(mut job_errors) => errors.append(&mut job_errors),
        }
    }
    if !errors.is_empty() {
        return Err(locate_all(index, source_path, errors));
    }
    for (id, job) in &jobs {
        for dependency in &job.needs {
            if !jobs.contains_key(dependency) {
                errors.push(unlocated_diagnostic(
                    "job.need_unknown",
                    "needs references an unknown job",
                    vec!["jobs".into(), id.clone().into(), "needs".into()],
                ));
            }
        }
    }
    validate_artifact_dependencies(&jobs, &mut errors);
    validate_reserved_environments(&jobs, &dispatch_inputs, &call_inputs, &mut errors);
    if !errors.is_empty() {
        return Err(locate_all(index, source_path, errors));
    }
    let expanded = expand_matrices(&jobs, limits)
        .map_err(|diagnostics| locate_all(index, source_path, diagnostics))?;
    let order = topological_order(&expanded)
        .map_err(|diagnostics| locate_all(index, source_path, diagnostics))?;
    validate_graph_limits(&expanded, &order, limits)
        .map_err(|diagnostic| vec![index.locate(source_path, diagnostic)])?;
    let jobs = expanded
        .into_iter()
        .map(|(id, job)| {
            let needs = job.needs.clone();
            (
                id,
                PipelineJob {
                    needs,
                    execution: job_execution(&job),
                },
            )
        })
        .collect();
    let warnings = locate_all(index, source_path, warnings);
    Ok(ValidatedWorkflow {
        version: 1,
        name: name.to_owned(),
        triggers: yaml_to_json(&YamlValue::Mapping(triggers.clone())),
        jobs,
        order,
        warnings,
        dispatch_inputs,
        call_inputs,
    })
}

fn validate_triggers(
    triggers: &Mapping,
) -> Result<(InputDefinitions, InputDefinitions), Vec<Diagnostic>> {
    let supported = [
        "push",
        "pull_request",
        "workflow_dispatch",
        "workflow_call",
        "schedule",
    ];
    let unknown = unknown_keys(triggers, &supported, &["on".into()]);
    if !unknown.is_empty() {
        return Err(unknown);
    }
    if let Some(schedule) = yaml_get(triggers, "schedule") {
        let Some(entries) = schedule
            .as_sequence()
            .filter(|entries| (1..=8).contains(&entries.len()))
        else {
            return Err(vec![unlocated_diagnostic(
                "schedule.type",
                "schedule must contain one to eight entries",
                vec!["on".into(), "schedule".into()],
            )]);
        };
        for (position, entry) in entries.iter().enumerate() {
            let cron = entry
                .as_mapping()
                .and_then(|mapping| yaml_string(mapping, "cron"));
            if cron.is_none_or(|cron| !valid_cron(cron)) {
                return Err(vec![unlocated_diagnostic(
                    "schedule.cron",
                    "cron must be a valid bounded five-field UTC expression",
                    vec![
                        "on".into(),
                        "schedule".into(),
                        position.into(),
                        "cron".into(),
                    ],
                )]);
            }
        }
    }
    let dispatch = trigger_inputs(triggers, "workflow_dispatch")?;
    let call = trigger_inputs(triggers, "workflow_call")?;
    Ok((dispatch, call))
}

fn trigger_inputs(triggers: &Mapping, trigger: &str) -> Result<InputDefinitions, Vec<Diagnostic>> {
    let Some(definition) = yaml_get(triggers, trigger) else {
        return Ok(BTreeMap::new());
    };
    let Some(definition) = definition.as_mapping() else {
        return Err(vec![unlocated_diagnostic(
            "workflow.manual_trigger",
            "input-bearing trigger must be a map",
            vec!["on".into(), trigger.into()],
        )]);
    };
    let unknown = unknown_keys(definition, &["inputs"], &["on".into(), trigger.into()]);
    if !unknown.is_empty() {
        return Err(unknown);
    }
    let Some(inputs) = yaml_get(definition, "inputs") else {
        return Ok(BTreeMap::new());
    };
    let Some(inputs) = inputs.as_mapping().filter(|inputs| inputs.len() <= 16) else {
        return Err(vec![unlocated_diagnostic(
            "workflow.manual_inputs",
            "inputs must be a map of at most 16 definitions",
            vec!["on".into(), trigger.into(), "inputs".into()],
        )]);
    };
    let mut definitions = BTreeMap::new();
    for (name, definition) in string_entries(inputs) {
        let path = vec![
            "on".into(),
            trigger.into(),
            "inputs".into(),
            name.clone().into(),
        ];
        definitions.insert(
            name.clone(),
            parse_input_definition(&name, definition, &path)?,
        );
    }
    Ok(definitions)
}

#[allow(clippy::too_many_lines)]
fn parse_input_definition(
    name: &str,
    value: &YamlValue,
    path: &[PathSegment],
) -> Result<InputDefinition, Vec<Diagnostic>> {
    if !valid_input_id(name) {
        return Err(vec![unlocated_diagnostic(
            "manual_input.id",
            "invalid input identifier",
            path.to_vec(),
        )]);
    }
    let Some(definition) = value.as_mapping() else {
        return Err(vec![unlocated_diagnostic(
            "manual_input.type",
            "input definition must be a map",
            path.to_vec(),
        )]);
    };
    let unknown = unknown_keys(
        definition,
        &["description", "type", "required", "default", "options"],
        path,
    );
    if !unknown.is_empty() {
        return Err(unknown);
    }
    if yaml_get(definition, "description").is_some_and(|description| {
        description
            .as_str()
            .is_none_or(|description| description.len() > 256)
    }) {
        return Err(vec![unlocated_diagnostic(
            "manual_input.description",
            "description must be a string of at most 256 bytes",
            append(path, "description"),
        )]);
    }
    let kind = match yaml_string(definition, "type").unwrap_or("string") {
        "string" => InputKind::String,
        "choice" => InputKind::Choice,
        "boolean" => InputKind::Boolean,
        _ => {
            return Err(vec![unlocated_diagnostic(
                "manual_input.type",
                "type must be string, choice, or boolean",
                append(path, "type"),
            )]);
        }
    };
    let required = match yaml_get(definition, "required") {
        None => false,
        Some(YamlValue::Bool(required)) => *required,
        Some(_) => {
            return Err(vec![unlocated_diagnostic(
                "manual_input.required",
                "required must be boolean",
                append(path, "required"),
            )]);
        }
    };
    let options = match (kind, yaml_get(definition, "options")) {
        (InputKind::Choice, Some(YamlValue::Sequence(options)))
            if (2..=32).contains(&options.len()) =>
        {
            let Some(options) = options
                .iter()
                .map(YamlValue::as_str)
                .map(|value| {
                    value
                        .filter(|value| bounded_input_string(value))
                        .map(str::to_owned)
                })
                .collect::<Option<Vec<_>>>()
            else {
                return Err(vec![input_options_diagnostic(path)]);
            };
            if options.iter().collect::<BTreeSet<_>>().len() != options.len() {
                return Err(vec![input_options_diagnostic(path)]);
            }
            options
        }
        (InputKind::Choice, _) | (_, Some(_)) => {
            return Err(vec![input_options_diagnostic(path)]);
        }
        (_, None) => Vec::new(),
    };
    let default = match yaml_get(definition, "default") {
        None => None,
        Some(YamlValue::Bool(value)) if kind == InputKind::Boolean => Some(value.to_string()),
        Some(YamlValue::String(value))
            if kind != InputKind::Boolean
                && bounded_input_string(value)
                && (kind != InputKind::Choice || options.contains(value)) =>
        {
            Some(value.clone())
        }
        Some(_) => {
            return Err(vec![unlocated_diagnostic(
                "manual_input.default",
                "default does not match the declared input type",
                append(path, "default"),
            )]);
        }
    };
    Ok(InputDefinition {
        kind,
        required,
        default,
        options,
    })
}

fn input_options_diagnostic(path: &[PathSegment]) -> Diagnostic {
    unlocated_diagnostic(
        "manual_input.options",
        "choice inputs require 2 to 32 unique bounded options and other inputs accept none",
        append(path, "options"),
    )
}

fn normalize_submitted_inputs(
    definitions: &InputDefinitions,
    submitted: &BTreeMap<String, String>,
    call: bool,
) -> Result<BTreeMap<String, String>, Diagnostic> {
    if submitted.keys().any(|name| !definitions.contains_key(name)) {
        return Err(unlocated_diagnostic(
            if call {
                "call_input.undeclared"
            } else {
                "manual_input.undeclared"
            },
            "input is not declared by the workflow trigger",
            vec!["on".into()],
        ));
    }
    definitions
        .iter()
        .map(|(name, definition)| {
            let value = submitted
                .get(name)
                .cloned()
                .or_else(|| definition.default.clone());
            let value = match value {
                Some(value) if valid_input_value(definition, &value) => value,
                Some(_) => return Err(input_value_diagnostic(name, definition, call)),
                None if definition.required => {
                    return Err(unlocated_diagnostic(
                        if call {
                            "call_input.required"
                        } else {
                            "manual_input.required"
                        },
                        "required input is missing",
                        vec!["on".into(), name.clone().into()],
                    ));
                }
                None => String::new(),
            };
            Ok((name.clone(), value))
        })
        .collect()
}

fn valid_input_value(definition: &InputDefinition, value: &str) -> bool {
    match definition.kind {
        InputKind::String => bounded_input_string(value),
        InputKind::Choice => {
            bounded_input_string(value) && definition.options.iter().any(|item| item == value)
        }
        InputKind::Boolean => matches!(value, "true" | "false"),
    }
}

fn input_value_diagnostic(name: &str, definition: &InputDefinition, call: bool) -> Diagnostic {
    let reason = match definition.kind {
        InputKind::Choice => "invalid_choice",
        InputKind::Boolean => "invalid_boolean",
        InputKind::String => "invalid_string",
    };
    unlocated_diagnostic(
        &format!("{}_input.{reason}", if call { "call" } else { "manual" }),
        "input value does not match its declaration",
        vec!["on".into(), name.to_owned().into()],
    )
}

fn bounded_input_string(value: &str) -> bool {
    value.len() <= 1_024 && !value.contains(['\n', '\r', '\0'])
}

fn validate_job(
    id: &str,
    definition: &YamlValue,
    limits: &WorkflowLimits,
) -> Result<(Job, Vec<Diagnostic>), Vec<Diagnostic>> {
    let path = vec!["jobs".into(), id.into()];
    if !valid_job_id(id) {
        return Err(vec![unlocated_diagnostic(
            "job.id",
            "invalid job identifier",
            path,
        )]);
    }
    let Some(definition) = definition.as_mapping() else {
        return Err(vec![unlocated_diagnostic(
            "job.type",
            "job must be a map",
            path,
        )]);
    };
    let unknown = unknown_keys(definition, JOB_KEYS, &path);
    if !unknown.is_empty() {
        return Err(unknown);
    }
    let Some(image) = yaml_string(definition, "image").filter(|image| !image.is_empty()) else {
        return Err(vec![unlocated_diagnostic(
            "job.image",
            "image must be a non-empty string",
            append(&path, "image"),
        )]);
    };
    let needs = parse_needs(definition, id)?;
    let condition = parse_condition(definition, &append(&path, "if"))?;
    if condition == "failure" && needs.is_empty() {
        return Err(vec![unlocated_diagnostic(
            "job.condition_dependencies",
            "a failure job must declare a dependency",
            append(&path, "if"),
        )]);
    }
    let shell = yaml_string(definition, "shell").unwrap_or("/bin/sh");
    if !matches!(shell, "/bin/sh" | "/bin/bash") {
        return Err(vec![unlocated_diagnostic(
            "job.shell",
            "shell must be /bin/sh or /bin/bash",
            append(&path, "shell"),
        )]);
    }
    let env = string_map(yaml_get(definition, "env"), 256).ok_or_else(|| {
        vec![unlocated_diagnostic(
            "job.env",
            "environment keys and values must be strings",
            append(&path, "env"),
        )]
    })?;
    let secrets = string_list(yaml_get(definition, "secrets"), true).ok_or_else(|| {
        vec![unlocated_diagnostic(
            "job.secrets",
            "secrets must contain valid secret names",
            append(&path, "secrets"),
        )]
    })?;
    let matrix = parse_matrix(definition, id, &env)?;
    let runs_on = parse_runs_on(definition, id)?;
    let services = parse_services(definition, id, &secrets)?;
    let steps = parse_steps(definition, id, limits)?;
    let timeout_ms = yaml_get(definition, "timeout")
        .map(|value| {
            value.as_str().and_then(parse_duration_ms).ok_or_else(|| {
                vec![unlocated_diagnostic(
                    "job.timeout",
                    "timeout must be a bounded duration",
                    append(&path, "timeout"),
                )]
            })
        })
        .transpose()?;
    let warnings = if image.contains("@sha256:") {
        Vec::new()
    } else {
        vec![unlocated_warning(
            "job.image_mutable",
            "image tag is mutable; prefer a digest",
            append(&path, "image"),
        )]
    };
    Ok((
        Job {
            id: id.into(),
            base_id: id.into(),
            image: image.into(),
            needs,
            condition,
            shell: shell.into(),
            timeout_ms,
            env,
            secrets,
            services,
            runs_on,
            steps,
            matrix,
            matrix_values: BTreeMap::new(),
        },
        warnings,
    ))
}

fn parse_needs(definition: &Mapping, id: &str) -> Result<Vec<String>, Vec<Diagnostic>> {
    let path = vec!["jobs".into(), id.into(), "needs".into()];
    let Some(value) = yaml_get(definition, "needs") else {
        return Ok(Vec::new());
    };
    let needs = if let Some(value) = value.as_str() {
        vec![value.to_owned()]
    } else if let Some(values) = value.as_sequence() {
        values
            .iter()
            .map(YamlValue::as_str)
            .map(|value| value.map(str::to_owned))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| {
                vec![unlocated_diagnostic(
                    "job.needs",
                    "needs must contain job IDs",
                    path.clone(),
                )]
            })?
    } else {
        return Err(vec![unlocated_diagnostic(
            "job.needs",
            "needs must be a job ID or list",
            path,
        )]);
    };
    Ok(needs
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect())
}

fn parse_condition(definition: &Mapping, path: &[PathSegment]) -> Result<String, Vec<Diagnostic>> {
    let condition = yaml_string(definition, "if").unwrap_or("success");
    if matches!(condition, "success" | "failure" | "always") {
        Ok(condition.into())
    } else {
        Err(vec![unlocated_diagnostic(
            "condition.value",
            "if must be success, failure, or always",
            path.to_vec(),
        )])
    }
}

fn parse_matrix(
    definition: &Mapping,
    id: &str,
    env: &BTreeMap<String, String>,
) -> Result<BTreeMap<String, Vec<String>>, Vec<Diagnostic>> {
    let Some(strategy) = yaml_get(definition, "strategy") else {
        return Ok(BTreeMap::new());
    };
    let path = vec!["jobs".into(), id.into(), "strategy".into(), "matrix".into()];
    let Some(matrix) = strategy
        .as_mapping()
        .and_then(|strategy| yaml_get(strategy, "matrix"))
        .and_then(YamlValue::as_mapping)
        .filter(|matrix| (1..=4).contains(&matrix.len()))
    else {
        return Err(vec![unlocated_diagnostic(
            "matrix.axes",
            "matrix must contain one to four axes",
            path,
        )]);
    };
    let mut axes = BTreeMap::new();
    let mut product = 1_usize;
    for (axis, values) in string_entries(matrix) {
        let axis_path = vec![
            "jobs".into(),
            id.into(),
            "strategy".into(),
            "matrix".into(),
            axis.clone().into(),
        ];
        if !valid_input_id(&axis) {
            return Err(vec![unlocated_diagnostic(
                "matrix.axis",
                "invalid matrix axis",
                axis_path,
            )]);
        }
        let Some(values) = values
            .as_sequence()
            .filter(|values| (1..=8).contains(&values.len()))
        else {
            return Err(vec![unlocated_diagnostic(
                "matrix.values",
                "matrix axis must contain one to eight values",
                axis_path,
            )]);
        };
        let values = values
            .iter()
            .map(YamlValue::as_str)
            .map(|value| value.map(str::to_owned))
            .collect::<Option<Vec<_>>>()
            .filter(|values| values.iter().all(|value| valid_matrix_value(value)))
            .ok_or_else(|| {
                vec![unlocated_diagnostic(
                    "matrix.value",
                    "matrix values must be bounded safe strings",
                    axis_path.clone(),
                )]
            })?;
        if values.iter().collect::<BTreeSet<_>>().len() != values.len() {
            return Err(vec![unlocated_diagnostic(
                "matrix.value_duplicate",
                "matrix values must be unique",
                axis_path,
            )]);
        }
        let environment = format!("ROBINE_MATRIX_{}", axis.to_ascii_uppercase());
        if env.contains_key(&environment) {
            return Err(vec![unlocated_diagnostic(
                "matrix.env_collision",
                "matrix environment is reserved",
                vec!["jobs".into(), id.into(), "env".into(), environment.into()],
            )]);
        }
        product = product.saturating_mul(values.len());
        axes.insert(axis, values);
    }
    if product > 32 {
        return Err(vec![unlocated_diagnostic(
            "matrix.limit_variants",
            "matrix exceeds 32 variants",
            path,
        )]);
    }
    Ok(axes)
}

fn parse_runs_on(definition: &Mapping, id: &str) -> Result<Vec<String>, Vec<Diagnostic>> {
    let Some(value) = yaml_get(definition, "runs-on") else {
        return Ok(vec!["docker".into()]);
    };
    let labels = value
        .as_sequence()
        .and_then(|values| {
            values
                .iter()
                .map(YamlValue::as_str)
                .map(|value| value.map(str::to_owned))
                .collect::<Option<Vec<_>>>()
        })
        .filter(|labels| {
            (1..=16).contains(&labels.len()) && labels.iter().all(|label| valid_runner_label(label))
        })
        .ok_or_else(|| {
            vec![unlocated_diagnostic(
                "job.runs_on",
                "runs-on must contain bounded labels",
                vec!["jobs".into(), id.into(), "runs-on".into()],
            )]
        })?;
    Ok(labels
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect())
}

#[allow(clippy::too_many_lines)]
fn parse_services(
    definition: &Mapping,
    job_id: &str,
    declared_secrets: &[String],
) -> Result<BTreeMap<String, JsonValue>, Vec<Diagnostic>> {
    let Some(value) = yaml_get(definition, "services") else {
        return Ok(BTreeMap::new());
    };
    let Some(services) = value.as_mapping().filter(|services| services.len() <= 8) else {
        return Err(vec![unlocated_diagnostic(
            "job.services",
            "services must be a map of at most eight definitions",
            vec!["jobs".into(), job_id.into(), "services".into()],
        )]);
    };
    let mut normalized = BTreeMap::new();
    for (id, value) in string_entries(services) {
        let path = vec![
            "jobs".into(),
            job_id.into(),
            "services".into(),
            id.clone().into(),
        ];
        if !valid_job_id(&id) {
            return Err(vec![unlocated_diagnostic(
                "service.id",
                "invalid service identifier",
                path,
            )]);
        }
        let Some(service) = value.as_mapping() else {
            return Err(vec![unlocated_diagnostic(
                "service.type",
                "service must be a map",
                path,
            )]);
        };
        let unknown = unknown_keys(service, SERVICE_KEYS, &path);
        if !unknown.is_empty() {
            return Err(unknown);
        }
        let Some(image) = yaml_string(service, "image").filter(|image| !image.is_empty()) else {
            return Err(vec![unlocated_diagnostic(
                "service.image",
                "service image is required",
                append(&path, "image"),
            )]);
        };
        let env = string_map(yaml_get(service, "env"), 64).ok_or_else(|| {
            vec![unlocated_diagnostic(
                "service.env",
                "service environment is invalid",
                append(&path, "env"),
            )]
        })?;
        let secret_env = string_map(yaml_get(service, "secret-env"), 64).ok_or_else(|| {
            vec![unlocated_diagnostic(
                "service.secret_env",
                "service secret environment is invalid",
                append(&path, "secret-env"),
            )]
        })?;
        if secret_env
            .values()
            .any(|name| !declared_secrets.contains(name))
            || secret_env.keys().any(|name| env.contains_key(name))
        {
            return Err(vec![unlocated_diagnostic(
                "service.secret_env",
                "service secret environment must reference declared secrets",
                append(&path, "secret-env"),
            )]);
        }
        let command = string_list(yaml_get(service, "command"), false)
            .filter(|command| {
                command.len() <= 32
                    && command
                        .iter()
                        .all(|value| (1..=4_096).contains(&value.len()))
            })
            .ok_or_else(|| {
                vec![unlocated_diagnostic(
                    "service.command",
                    "service command is invalid",
                    append(&path, "command"),
                )]
            })?;
        let readiness = yaml_get(service, "readiness").and_then(|readiness| {
            let readiness = readiness.as_mapping()?;
            let tcp = yaml_u64(readiness, "tcp")
                .and_then(|value| u16::try_from(value).ok())
                .filter(|value| *value > 0)?;
            let timeout = yaml_string(readiness, "timeout").unwrap_or("30s");
            let timeout_ms = parse_service_timeout(timeout)?;
            Some(json!({"tcp": tcp, "timeout_ms": timeout_ms}))
        });
        if yaml_get(service, "readiness").is_some() && readiness.is_none() {
            return Err(vec![unlocated_diagnostic(
                "service.readiness",
                "service readiness is invalid",
                append(&path, "readiness"),
            )]);
        }
        let privileged = yaml_bool(service, "privileged").unwrap_or(false);
        if privileged && !(id == "docker" && image.starts_with("docker:") && image.contains("dind"))
        {
            return Err(vec![unlocated_diagnostic(
                "service.privileged",
                "privileged service is not allowed",
                append(&path, "privileged"),
            )]);
        }
        normalized.insert(
            id.clone(),
            json!({
                "id": id,
                "image": image,
                "user": yaml_string(service, "user"),
                "env": env,
                "secret_env": secret_env,
                "command": command,
                "readiness": readiness,
                "privileged": privileged,
            }),
        );
    }
    Ok(normalized)
}

fn parse_steps(
    definition: &Mapping,
    job_id: &str,
    limits: &WorkflowLimits,
) -> Result<Vec<JsonValue>, Vec<Diagnostic>> {
    let path = vec!["jobs".into(), job_id.into(), "steps".into()];
    let Some(steps) = yaml_get(definition, "steps")
        .and_then(YamlValue::as_sequence)
        .filter(|steps| !steps.is_empty())
    else {
        return Err(vec![unlocated_diagnostic(
            "job.steps",
            "steps must be a non-empty list",
            path,
        )]);
    };
    if steps.len() > limits.max_steps_per_job {
        return Err(vec![unlocated_diagnostic(
            "workflow.limit_steps_per_job",
            "job exceeds its step limit",
            path,
        )]);
    }
    let mut normalized = Vec::new();
    let mut names = BTreeSet::new();
    for (position, value) in steps.iter().enumerate() {
        let step_path = vec![
            "jobs".into(),
            job_id.into(),
            "steps".into(),
            position.into(),
        ];
        let Some(step) = value.as_mapping() else {
            return Err(vec![unlocated_diagnostic(
                "step.type",
                "step must be a map",
                step_path,
            )]);
        };
        let unknown = unknown_keys(step, STEP_KEYS, &step_path);
        if !unknown.is_empty() {
            return Err(unknown);
        }
        let run = yaml_string(step, "run");
        let builtin = yaml_string(step, "uses");
        let (kind, value) = match (run, builtin) {
            (Some(run), None) if !run.is_empty() => ("run", run),
            (None, Some(builtin)) if BUILTINS.contains(&builtin) => ("builtin", builtin),
            (None, Some(_)) => {
                return Err(vec![unlocated_diagnostic(
                    "step.builtin",
                    "unsupported built-in",
                    append(&step_path, "uses"),
                )]);
            }
            _ => {
                return Err(vec![unlocated_diagnostic(
                    "step.action",
                    "step must contain exactly one action",
                    step_path,
                )]);
            }
        };
        let condition = parse_condition(step, &append(&step_path, "if"))?;
        let with = yaml_get(step, "with").map_or_else(|| json!({}), yaml_to_json);
        validate_step_options(kind, value, &with, &step_path)?;
        let name = yaml_string(step, "name").map_or_else(
            || {
                if kind == "run" {
                    format!("Run {}", position + 1)
                } else {
                    value.into()
                }
            },
            str::to_owned,
        );
        if !names.insert(name.clone()) {
            return Err(vec![unlocated_diagnostic(
                "step.name_duplicate",
                "step names must be unique",
                path,
            )]);
        }
        normalized.push(json!({"name": name, "kind": kind, "value": value, "condition": condition, "with": with}));
    }
    Ok(normalized)
}

fn validate_step_options(
    kind: &str,
    value: &str,
    with: &JsonValue,
    path: &[PathSegment],
) -> Result<(), Vec<Diagnostic>> {
    let options = with.as_object().ok_or_else(|| {
        vec![unlocated_diagnostic(
            "step.with",
            "with must be a map",
            append(path, "with"),
        )]
    })?;
    if kind == "run" {
        return if options.is_empty() {
            Ok(())
        } else {
            Err(vec![unlocated_diagnostic(
                "step.with",
                "run steps do not accept with",
                append(path, "with"),
            )])
        };
    }
    let string = |key: &str| options.get(key).and_then(JsonValue::as_str);
    let allowed: &[&str] = match value {
        "cache/restore" | "cache/save" => &["key", "paths"],
        "artifacts/upload" => &["name", "paths", "retention-days"],
        "artifacts/download" => &["name", "from", "path"],
        _ => &[][..],
    };
    if options.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(vec![unlocated_diagnostic(
            if value.starts_with("cache/") {
                "step.cache_inputs"
            } else {
                "step.artifact_inputs"
            },
            "built-in contains an unknown input",
            append(path, "with"),
        )]);
    }
    let paths = || {
        options
            .get("paths")
            .and_then(JsonValue::as_array)
            .filter(|paths| (1..=32).contains(&paths.len()))
            .is_some_and(|paths| {
                paths
                    .iter()
                    .all(|path| path.as_str().is_some_and(valid_workspace_path))
            })
    };
    let valid = match value {
        "checkout" => options.is_empty(),
        "cache/restore" | "cache/save" => {
            string("key").is_some_and(|key| (1..=512).contains(&key.len())) && paths()
        }
        "artifacts/upload" => {
            string("name").is_some_and(valid_artifact_name)
                && paths()
                && options
                    .get("retention-days")
                    .and_then(JsonValue::as_u64)
                    .is_none_or(|days| (1..=90).contains(&days))
        }
        "artifacts/download" => {
            string("name").is_some_and(valid_artifact_name)
                && string("from").is_some_and(valid_job_id)
                && string("path").is_none_or(valid_workspace_path)
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        let code = if value.starts_with("cache/") {
            "step.cache_inputs"
        } else {
            "step.artifact_inputs"
        };
        Err(vec![unlocated_diagnostic(
            code,
            "built-in inputs are invalid",
            append(path, "with"),
        )])
    }
}

fn validate_artifact_dependencies(jobs: &BTreeMap<String, Job>, errors: &mut Vec<Diagnostic>) {
    for (id, job) in jobs {
        for (position, step) in job.steps.iter().enumerate() {
            if step.get("kind").and_then(JsonValue::as_str) != Some("builtin")
                || step.get("value").and_then(JsonValue::as_str) != Some("artifacts/download")
            {
                continue;
            }
            let source = step
                .get("with")
                .and_then(|options| options.get("from"))
                .and_then(JsonValue::as_str)
                .unwrap_or_default();
            let path = vec![
                "jobs".into(),
                id.clone().into(),
                "steps".into(),
                position.into(),
                "with".into(),
                "from".into(),
            ];
            if !job.needs.iter().any(|dependency| dependency == source) {
                errors.push(unlocated_diagnostic(
                    "step.artifact_dependency",
                    "artifact source must be declared in job needs",
                    path,
                ));
            } else if jobs.get(source).is_some_and(|producer| {
                producer.matrix.values().map(Vec::len).product::<usize>() > 1
            }) {
                errors.push(unlocated_diagnostic(
                    "matrix.artifact_ambiguous",
                    "artifact source expands to multiple variants",
                    path,
                ));
            }
        }
    }
}

fn validate_reserved_environments(
    jobs: &BTreeMap<String, Job>,
    dispatch: &InputDefinitions,
    call: &InputDefinitions,
    errors: &mut Vec<Diagnostic>,
) {
    for (id, job) in jobs {
        for name in BUILD_ENVIRONMENT {
            if job.env.contains_key(*name) {
                errors.push(unlocated_diagnostic(
                    "build_provenance.env_collision",
                    "build environment is reserved",
                    vec![
                        "jobs".into(),
                        id.clone().into(),
                        "env".into(),
                        (*name).into(),
                    ],
                ));
            }
        }
        for (inputs, prefix, code) in [
            (dispatch, "ROBINE_INPUT_", "manual_input.env_collision"),
            (call, "ROBINE_CALL_INPUT_", "call_input.env_collision"),
        ] {
            for input in inputs.keys() {
                let name = format!("{prefix}{}", input.to_ascii_uppercase());
                if job.env.contains_key(&name) {
                    errors.push(unlocated_diagnostic(
                        code,
                        "trigger input environment is reserved",
                        vec!["jobs".into(), id.clone().into(), "env".into(), name.into()],
                    ));
                }
            }
        }
    }
}

fn expand_matrices(
    jobs: &BTreeMap<String, Job>,
    limits: &WorkflowLimits,
) -> Result<BTreeMap<String, Job>, Vec<Diagnostic>> {
    let variants = jobs
        .iter()
        .map(|(id, job)| (id.clone(), matrix_variants(job)))
        .collect::<BTreeMap<_, _>>();
    if variants
        .values()
        .flatten()
        .any(|variant| variant.id.len() > 255)
    {
        return Err(vec![unlocated_diagnostic(
            "matrix.generated_id",
            "generated matrix job key exceeds 255 bytes",
            vec!["jobs".into()],
        )]);
    }
    if variants.values().map(Vec::len).sum::<usize>() > limits.max_jobs {
        return Err(vec![unlocated_diagnostic(
            "workflow.limit_jobs",
            "expanded workflow exceeds its job limit",
            vec!["jobs".into()],
        )]);
    }
    let mut expanded = BTreeMap::new();
    for job_variants in variants.values() {
        for mut job in job_variants.clone() {
            job.needs = job
                .needs
                .iter()
                .flat_map(|dependency| {
                    variants
                        .get(dependency)
                        .into_iter()
                        .flatten()
                        .map(|variant| variant.id.clone())
                })
                .collect();
            for step in &mut job.steps {
                if step.get("value").and_then(JsonValue::as_str) != Some("artifacts/download") {
                    continue;
                }
                let Some(source) = step
                    .get("with")
                    .and_then(|options| options.get("from"))
                    .and_then(JsonValue::as_str)
                else {
                    continue;
                };
                if let Some([variant]) = variants.get(source).map(Vec::as_slice) {
                    step["with"]["from"] = JsonValue::String(variant.id.clone());
                }
            }
            job.image = interpolate_matrix(&job.image, &job.matrix_values).ok_or_else(|| {
                vec![unlocated_diagnostic(
                    "matrix.interpolation",
                    "image contains an invalid or unknown matrix token",
                    vec!["jobs".into(), job.base_id.clone().into(), "image".into()],
                )]
            })?;
            for service in job.services.values_mut() {
                if let Some(image) = service.get("image").and_then(JsonValue::as_str) {
                    let image = interpolate_matrix(image, &job.matrix_values).ok_or_else(|| {
                        vec![unlocated_diagnostic(
                            "matrix.interpolation",
                            "service image contains an invalid matrix token",
                            vec!["jobs".into(), job.base_id.clone().into(), "services".into()],
                        )]
                    })?;
                    service["image"] = JsonValue::String(image);
                }
            }
            expanded.insert(job.id.clone(), job);
        }
    }
    Ok(expanded)
}

fn matrix_variants(job: &Job) -> Vec<Job> {
    if job.matrix.is_empty() {
        return vec![job.clone()];
    }
    let combinations =
        job.matrix
            .iter()
            .fold(vec![BTreeMap::new()], |combinations, (axis, values)| {
                combinations
                    .into_iter()
                    .flat_map(|combination| {
                        values.iter().map(move |value| {
                            let mut next = combination.clone();
                            next.insert(axis.clone(), value.clone());
                            next
                        })
                    })
                    .collect()
            });
    combinations
        .into_iter()
        .map(|values| {
            let mut variant = job.clone();
            let suffix = values
                .iter()
                .map(|(axis, value)| format!("{axis}={value}"))
                .collect::<Vec<_>>()
                .join(",");
            variant.id = format!("{}[{suffix}]", job.id);
            for (axis, value) in &values {
                variant.env.insert(
                    format!("ROBINE_MATRIX_{}", axis.to_ascii_uppercase()),
                    value.clone(),
                );
            }
            variant.matrix.clear();
            variant.matrix_values = values;
            variant
        })
        .collect()
}

fn interpolate_matrix(image: &str, values: &BTreeMap<String, String>) -> Option<String> {
    let mut result = image.to_owned();
    while let Some(start) = result.find("${{") {
        let end = result[start + 3..].find("}}").map(|end| start + 3 + end)?;
        let token = result[start + 3..end].trim();
        let axis = token.strip_prefix("matrix.")?.trim();
        if !valid_input_id(axis) {
            return None;
        }
        let value = values.get(axis)?;
        result.replace_range(start..end + 2, value);
    }
    Some(result)
}

fn topological_order(jobs: &BTreeMap<String, Job>) -> Result<Vec<String>, Vec<Diagnostic>> {
    let mut indegrees = jobs
        .iter()
        .map(|(id, job)| (id.clone(), job.needs.len()))
        .collect::<BTreeMap<_, _>>();
    let mut ready = indegrees
        .iter()
        .filter(|(_, count)| **count == 0)
        .map(|(id, _)| id.clone())
        .collect::<BTreeSet<_>>();
    let mut order = Vec::new();
    while let Some(id) = ready.pop_first() {
        indegrees.remove(&id);
        order.push(id.clone());
        for (candidate, job) in jobs {
            if job.needs.contains(&id)
                && let Some(count) = indegrees.get_mut(candidate)
            {
                *count -= 1;
                if *count == 0 {
                    ready.insert(candidate.clone());
                }
            }
        }
    }
    if indegrees.is_empty() {
        return Ok(order);
    }
    Err(indegrees
        .keys()
        .map(|id| {
            unlocated_diagnostic(
                "workflow.cycle",
                "job participates in a dependency cycle",
                vec!["jobs".into(), id.clone().into(), "needs".into()],
            )
        })
        .collect())
}

fn validate_graph_limits(
    jobs: &BTreeMap<String, Job>,
    order: &[String],
    limits: &WorkflowLimits,
) -> Result<(), Diagnostic> {
    if jobs.values().map(|job| job.steps.len()).sum::<usize>() > limits.max_total_steps {
        return Err(unlocated_diagnostic(
            "workflow.limit_total_steps",
            "workflow exceeds its total step limit",
            vec!["jobs".into()],
        ));
    }
    let mut depths = HashMap::new();
    for id in order {
        let depth = jobs[id]
            .needs
            .iter()
            .map(|dependency| depths.get(dependency).copied().unwrap_or(0))
            .max()
            .unwrap_or(0)
            + 1;
        if depth > limits.max_graph_depth {
            return Err(unlocated_diagnostic(
                "workflow.limit_graph_depth",
                "workflow exceeds its graph depth limit",
                vec!["jobs".into(), id.clone().into(), "needs".into()],
            ));
        }
        depths.insert(id.clone(), depth);
    }
    Ok(())
}

fn job_execution(job: &Job) -> JsonValue {
    let mut execution = json!({
        "image": job.image,
        "shell": job.shell,
        "env": job.env,
        "secret_names": job.secrets,
        "services": job.services,
        "steps": job.steps,
        "runs_on": job.runs_on,
        "base_id": job.base_id,
        "matrix_values": job.matrix_values,
        "condition": job.condition,
    });
    if let Some(timeout_ms) = job.timeout_ms {
        execution["timeout_ms"] = json!(timeout_ms);
    }
    execution
}

fn valid_cron(raw: &str) -> bool {
    if raw.is_empty() || raw.len() > 100 {
        return false;
    }
    let fields = raw.split_whitespace().collect::<Vec<_>>();
    fields.len() == 5
        && fields
            .iter()
            .zip([(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)])
            .all(|(field, bounds)| valid_cron_field(field, bounds.0, bounds.1))
}

fn valid_cron_field(field: &str, minimum: u32, maximum: u32) -> bool {
    !field.is_empty()
        && field.split(',').all(|segment| {
            let (base, step) = segment
                .split_once('/')
                .map_or((segment, None), |(base, step)| (base, Some(step)));
            let step_valid = step.is_none_or(|step| step.parse::<u32>().is_ok_and(|step| step > 0));
            let base_valid = if base == "*" {
                true
            } else if let Some((first, last)) = base.split_once('-') {
                first
                    .parse::<u32>()
                    .is_ok_and(|value| (minimum..=maximum).contains(&value))
                    && last
                        .parse::<u32>()
                        .is_ok_and(|value| (minimum..=maximum).contains(&value))
                    && first.parse::<u32>().unwrap_or(maximum)
                        <= last.parse::<u32>().unwrap_or(minimum)
            } else {
                base.parse::<u32>()
                    .is_ok_and(|value| (minimum..=maximum).contains(&value))
            };
            step_valid && base_valid
        })
}

fn parse_duration_ms(value: &str) -> Option<u64> {
    let (number, multiplier) = if let Some(value) = value.strip_suffix('s') {
        (value, 1_000)
    } else if let Some(value) = value.strip_suffix('m') {
        (value, 60_000)
    } else {
        (value.strip_suffix('h')?, 3_600_000)
    };
    number
        .parse::<u64>()
        .ok()?
        .checked_mul(multiplier)
        .filter(|value| *value > 0)
}

fn parse_service_timeout(value: &str) -> Option<u64> {
    let seconds = value.strip_suffix('s')?.parse::<u64>().ok()?;
    (1..=120).contains(&seconds).then_some(seconds * 1_000)
}

fn valid_job_id(value: &str) -> bool {
    (1..=63).contains(&value.len())
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || (index > 0 && (byte.is_ascii_digit() || matches!(byte, b'_' | b'-')))
        })
}

fn valid_input_id(value: &str) -> bool {
    (1..=31).contains(&value.len())
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || (index > 0 && (byte.is_ascii_digit() || byte == b'_'))
        })
}

fn valid_matrix_value(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphanumeric() || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        })
}

fn valid_runner_label(value: &str) -> bool {
    (1..=63).contains(&value.len())
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        })
}
fn valid_secret_name(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_uppercase() || byte == b'_' || (index > 0 && byte.is_ascii_digit())
        })
}
fn valid_workspace_path(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 1_024
        && !value.contains('\0')
        && std::path::Path::new(value).components().all(|component| {
            matches!(
                component,
                std::path::Component::Normal(_) | std::path::Component::CurDir
            )
        })
}
fn valid_artifact_name(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphanumeric() || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        })
}

fn string_map(value: Option<&YamlValue>, limit: usize) -> Option<BTreeMap<String, String>> {
    let Some(value) = value else {
        return Some(BTreeMap::new());
    };
    let mapping = value
        .as_mapping()
        .filter(|mapping| mapping.len() <= limit)?;
    string_entries(mapping)
        .into_iter()
        .map(|(key, value)| value.as_str().map(|value| (key, value.to_owned())))
        .collect()
}

fn string_list(value: Option<&YamlValue>, secrets: bool) -> Option<Vec<String>> {
    let Some(value) = value else {
        return Some(Vec::new());
    };
    let values = value.as_sequence()?;
    let values = values
        .iter()
        .map(YamlValue::as_str)
        .map(|value| value.map(str::to_owned))
        .collect::<Option<Vec<_>>>()?;
    (!secrets || values.iter().all(|value| valid_secret_name(value))).then_some(values)
}

fn yaml_get<'a>(mapping: &'a Mapping, key: &str) -> Option<&'a YamlValue> {
    mapping.get(YamlValue::String(key.into()))
}
fn yaml_string<'a>(mapping: &'a Mapping, key: &str) -> Option<&'a str> {
    yaml_get(mapping, key).and_then(YamlValue::as_str)
}
fn yaml_u64(mapping: &Mapping, key: &str) -> Option<u64> {
    yaml_get(mapping, key).and_then(YamlValue::as_u64)
}
fn yaml_bool(mapping: &Mapping, key: &str) -> Option<bool> {
    yaml_get(mapping, key).and_then(YamlValue::as_bool)
}
fn string_entries(mapping: &Mapping) -> Vec<(String, &YamlValue)> {
    mapping
        .iter()
        .filter_map(|(key, value)| key.as_str().map(|key| (key.to_owned(), value)))
        .collect()
}

fn unknown_keys(mapping: &Mapping, allowed: &[&str], path: &[PathSegment]) -> Vec<Diagnostic> {
    string_entries(mapping)
        .into_iter()
        .filter(|(key, _)| !allowed.contains(&key.as_str()) && !key.starts_with("x-"))
        .map(|(key, _)| {
            unlocated_diagnostic("workflow.unknown_key", "unknown key", append(path, key))
        })
        .collect()
}

fn yaml_to_json(value: &YamlValue) -> JsonValue {
    match value {
        YamlValue::Null => JsonValue::Null,
        YamlValue::Bool(value) => JsonValue::Bool(*value),
        YamlValue::Number(value) => value.as_i64().map_or_else(
            || value.as_u64().map_or(JsonValue::Null, JsonValue::from),
            JsonValue::from,
        ),
        YamlValue::String(value) => JsonValue::String(value.clone()),
        YamlValue::Sequence(values) => JsonValue::Array(values.iter().map(yaml_to_json).collect()),
        YamlValue::Mapping(mapping) => JsonValue::Object(
            mapping
                .iter()
                .filter_map(|(key, value)| {
                    key.as_str()
                        .map(|key| (key.to_owned(), yaml_to_json(value)))
                })
                .collect::<JsonMap<_, _>>(),
        ),
        YamlValue::Tagged(value) => yaml_to_json(&value.value),
    }
}

fn append(path: &[PathSegment], segment: impl Into<PathSegment>) -> Vec<PathSegment> {
    let mut path = path.to_vec();
    path.push(segment.into());
    path
}
fn unlocated_diagnostic(code: &str, message: &str, path: Vec<PathSegment>) -> Diagnostic {
    Diagnostic {
        code: code.into(),
        message: message.into(),
        path,
        line: 1,
        column: 1,
        source_path: String::new(),
        severity: DiagnosticSeverity::Error,
    }
}
fn unlocated_warning(code: &str, message: &str, path: Vec<PathSegment>) -> Diagnostic {
    Diagnostic {
        severity: DiagnosticSeverity::Warning,
        ..unlocated_diagnostic(code, message, path)
    }
}
fn locate_all(
    index: &SourceIndex,
    source_path: &str,
    diagnostics: Vec<Diagnostic>,
) -> Vec<Diagnostic> {
    diagnostics
        .into_iter()
        .map(|diagnostic| index.locate(source_path, diagnostic))
        .collect()
}

struct SourceIndex {
    locations: BTreeMap<Vec<PathSegment>, (usize, usize)>,
}

impl SourceIndex {
    fn new(source: &str) -> Self {
        let mut locations = BTreeMap::new();
        let mut stack: Vec<(usize, Vec<PathSegment>)> = Vec::new();
        let mut sequence_counts: BTreeMap<Vec<PathSegment>, usize> = BTreeMap::new();
        locations.insert(Vec::new(), (1, 1));
        for (line_index, raw) in source.lines().enumerate() {
            let trimmed = raw.trim_start();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let indent = raw.len() - trimmed.len();
            while stack.last().is_some_and(|(level, _)| *level >= indent) {
                stack.pop();
            }
            let parent = stack.last().map_or_else(Vec::new, |(_, path)| path.clone());
            if let Some(rest) = trimmed.strip_prefix("- ") {
                let position = sequence_counts.entry(parent.clone()).or_default();
                let item_path = append(&parent, *position);
                *position += 1;
                locations.insert(item_path.clone(), (line_index + 1, indent + 1));
                stack.push((indent, item_path.clone()));
                if let Some((key, value)) = yaml_line_key(rest) {
                    let path = append(&item_path, key);
                    locations.insert(path.clone(), (line_index + 1, indent + 3));
                    if value.is_empty() {
                        stack.push((indent + 2, path));
                    }
                }
            } else if let Some((key, value)) = yaml_line_key(trimmed) {
                let path = append(&parent, key);
                locations.insert(path.clone(), (line_index + 1, indent + 1));
                if value.is_empty() {
                    stack.push((indent, path));
                }
            }
        }
        Self { locations }
    }

    fn diagnostic(
        &self,
        source_path: &str,
        code: &str,
        message: &str,
        path: &[PathSegment],
    ) -> Diagnostic {
        self.locate(
            source_path,
            unlocated_diagnostic(code, message, path.to_vec()),
        )
    }

    fn locate(&self, source_path: &str, mut diagnostic: Diagnostic) -> Diagnostic {
        let mut path = diagnostic.path.clone();
        let location = loop {
            if let Some(location) = self.locations.get(&path) {
                break *location;
            }
            if path.pop().is_none() {
                break (1, 1);
            }
        };
        diagnostic.line = location.0;
        diagnostic.column = location.1;
        diagnostic.source_path = source_path.into();
        diagnostic
    }
}

fn yaml_line_key(line: &str) -> Option<(&str, &str)> {
    let (key, value) = line.split_once(':')?;
    let key = key.trim().trim_matches(['\'', '"']);
    (!key.is_empty()).then_some((key, value.trim()))
}
