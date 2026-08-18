use super::{
    Diagnostic, InputDefinitions, InputKind, PathSegment, SourceIndex, ValidatedWorkflow,
    WorkflowLimits, append, locate_all, parse, trigger_inputs, unlocated_diagnostic,
    valid_workflow_path, yaml_get,
};
use serde_yaml_ng::{Mapping, Value as YamlValue};
use std::collections::{BTreeMap, BTreeSet};

const ROOT_KEYS: &[&str] = &["version", "name", "on", "jobs", "includes"];
const INCLUDE_KEYS: &[&str] = &["path", "inputs"];
const MAX_INCLUDE_DEPTH: usize = 4;
const MAX_INCLUDE_EDGES: usize = 16;

/// A validated composed workflow and the exact reachable included source set.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedWorkflow {
    pub workflow: ValidatedWorkflow,
    pub included_sources: BTreeMap<String, String>,
}

#[derive(Clone)]
struct Include {
    alias: String,
    path: String,
    inputs: Mapping,
}

#[derive(Default)]
struct CompositionState {
    jobs: Mapping,
    origins: BTreeMap<String, (String, String)>,
    included_paths: BTreeSet<String>,
    include_count: usize,
}

/// Resolves one exact-revision source set and validates its final namespaced graph.
///
/// # Errors
///
/// Returns stable source-located diagnostics for malformed sources, include declarations,
/// call inputs, cycles, missing files, bounds, and final workflow invariants.
pub fn resolve(
    entry_path: &str,
    sources: &BTreeMap<String, String>,
    limits: &WorkflowLimits,
) -> Result<ResolvedWorkflow, Vec<Diagnostic>> {
    if !valid_workflow_path(entry_path) {
        return Err(vec![source_diagnostic(
            entry_path,
            "include.entry_path",
            "entry path must be a canonical workflow path",
            Vec::new(),
        )]);
    }
    let Some(entry_source) = sources.get(entry_path) else {
        return Err(vec![source_diagnostic(
            entry_path,
            "include.entry_missing",
            "entry workflow source is missing from the exact revision",
            Vec::new(),
        )]);
    };
    let mut documents = BTreeMap::new();
    let mut indexes = BTreeMap::new();
    let entry = decode(entry_path, entry_source, limits)?;
    indexes.insert(entry_path.to_owned(), SourceIndex::new(entry_source));
    documents.insert(entry_path.to_owned(), entry);
    let mut state = CompositionState::default();
    compose_file(
        entry_path,
        &[],
        &Mapping::new(),
        &[entry_path.to_owned()],
        0,
        true,
        sources,
        limits,
        &mut documents,
        &mut indexes,
        &mut state,
    )?;

    let Some(entry) = documents.get(entry_path) else {
        return Err(vec![source_diagnostic(
            entry_path,
            "include.entry_missing",
            "entry workflow source is unavailable after decoding",
            Vec::new(),
        )]);
    };
    let mut composed = entry.clone();
    let Some(root) = composed.as_mapping_mut() else {
        return Err(vec![source_diagnostic(
            entry_path,
            "workflow.type",
            "entry workflow must be a map",
            Vec::new(),
        )]);
    };
    root.remove(YamlValue::String("includes".into()));
    root.insert(
        YamlValue::String("jobs".into()),
        YamlValue::Mapping(state.jobs),
    );
    let serialized = serde_yaml_ng::to_string(&composed).map_err(|_| {
        vec![source_diagnostic(
            entry_path,
            "include.compose",
            "composed workflow could not be serialized",
            Vec::new(),
        )]
    })?;
    let mut workflow = parse(&serialized, entry_path, limits)
        .map_err(|diagnostics| remap_all(diagnostics, entry_path, &state.origins, &indexes))?;
    workflow.warnings = remap_all(workflow.warnings, entry_path, &state.origins, &indexes);
    let included_sources = state
        .included_paths
        .into_iter()
        .filter_map(|path| sources.get(&path).map(|source| (path, source.clone())))
        .collect();
    Ok(ResolvedWorkflow {
        workflow,
        included_sources,
    })
}

#[allow(clippy::too_many_arguments)]
fn compose_file(
    path: &str,
    prefix: &[String],
    submitted: &Mapping,
    stack: &[String],
    depth: usize,
    entry: bool,
    sources: &BTreeMap<String, String>,
    limits: &WorkflowLimits,
    documents: &mut BTreeMap<String, YamlValue>,
    indexes: &mut BTreeMap<String, SourceIndex>,
    state: &mut CompositionState,
) -> Result<(), Vec<Diagnostic>> {
    ensure_decoded(path, sources, limits, documents, indexes)?;
    let document = documents.get(path).expect("decoded source");
    let root = root_shape(document, path, indexes)?;
    let inputs = if entry {
        BTreeMap::new()
    } else {
        normalize_call_inputs(root, submitted, path, indexes)?
    };
    add_direct_jobs(root, path, prefix, &inputs, state, indexes)?;
    let includes = parse_includes(root, path, indexes)?;
    let unique_paths = includes
        .iter()
        .map(|include| &include.path)
        .collect::<BTreeSet<_>>();
    if unique_paths.len() != includes.len() {
        return Err(vec![located(
            path,
            indexes,
            "include.duplicate_path",
            "one parent cannot include the same path more than once",
            vec!["includes".into()],
        )]);
    }
    for include in includes {
        let child_depth = depth + 1;
        let include_path = vec!["includes".into(), include.alias.clone().into()];
        if child_depth > MAX_INCLUDE_DEPTH {
            return Err(vec![located(
                path,
                indexes,
                "include.depth",
                "include depth exceeds four",
                include_path,
            )]);
        }
        if state.include_count >= MAX_INCLUDE_EDGES {
            return Err(vec![located(
                path,
                indexes,
                "include.count",
                "transitive includes exceed 16",
                include_path,
            )]);
        }
        if stack.iter().any(|ancestor| ancestor == &include.path) {
            return Err(vec![located(
                path,
                indexes,
                "include.cycle",
                "include graph contains a cycle",
                append(&include_path, "path"),
            )]);
        }
        if !sources.contains_key(&include.path) {
            return Err(vec![located(
                path,
                indexes,
                "include.missing",
                "included workflow is missing from the exact revision",
                append(&include_path, "path"),
            )]);
        }
        state.include_count += 1;
        state.included_paths.insert(include.path.clone());
        let mut child_prefix = prefix.to_vec();
        child_prefix.push(include.alias);
        let mut child_stack = stack.to_vec();
        child_stack.push(include.path.clone());
        compose_file(
            &include.path,
            &child_prefix,
            &include.inputs,
            &child_stack,
            child_depth,
            false,
            sources,
            limits,
            documents,
            indexes,
            state,
        )?;
    }
    Ok(())
}

fn ensure_decoded(
    path: &str,
    sources: &BTreeMap<String, String>,
    limits: &WorkflowLimits,
    documents: &mut BTreeMap<String, YamlValue>,
    indexes: &mut BTreeMap<String, SourceIndex>,
) -> Result<(), Vec<Diagnostic>> {
    if documents.contains_key(path) {
        return Ok(());
    }
    let source = sources.get(path).ok_or_else(|| {
        vec![source_diagnostic(
            path,
            "include.missing",
            "included workflow is missing from the exact revision",
            Vec::new(),
        )]
    })?;
    let document = decode(path, source, limits)?;
    indexes.insert(path.to_owned(), SourceIndex::new(source));
    documents.insert(path.to_owned(), document);
    Ok(())
}

fn decode(path: &str, source: &str, limits: &WorkflowLimits) -> Result<YamlValue, Vec<Diagnostic>> {
    if source.len() > limits.max_bytes {
        return Err(vec![source_diagnostic(
            path,
            "workflow.limit_source_bytes",
            "workflow exceeds its configured byte limit",
            Vec::new(),
        )]);
    }
    serde_yaml_ng::from_str(source).map_err(|error| {
        let location = error.location();
        vec![Diagnostic {
            code: "workflow.yaml".into(),
            message: "workflow YAML is invalid".into(),
            path: Vec::new(),
            line: location.as_ref().map_or(1, serde_yaml_ng::Location::line),
            column: location.as_ref().map_or(1, serde_yaml_ng::Location::column),
            source_path: path.into(),
            severity: super::DiagnosticSeverity::Error,
        }]
    })
}

fn root_shape<'a>(
    document: &'a YamlValue,
    path: &str,
    indexes: &BTreeMap<String, SourceIndex>,
) -> Result<&'a Mapping, Vec<Diagnostic>> {
    let Some(root) = document.as_mapping() else {
        return Err(vec![located(
            path,
            indexes,
            "workflow.type",
            "workflow must be a map",
            Vec::new(),
        )]);
    };
    let unknown = root
        .keys()
        .filter_map(YamlValue::as_str)
        .filter(|key| !ROOT_KEYS.contains(key) && !key.starts_with("x-"))
        .collect::<Vec<_>>();
    if let Some(key) = unknown.first() {
        return Err(vec![located(
            path,
            indexes,
            "workflow.unknown_key",
            "unknown workflow key",
            vec![(*key).into()],
        )]);
    }
    if yaml_get(root, "version").and_then(YamlValue::as_u64) != Some(1) {
        return Err(vec![located(
            path,
            indexes,
            "workflow.version",
            "version must be 1",
            vec!["version".into()],
        )]);
    }
    if yaml_get(root, "name")
        .and_then(YamlValue::as_str)
        .is_none_or(str::is_empty)
    {
        return Err(vec![located(
            path,
            indexes,
            "workflow.name",
            "name must be a non-empty string",
            vec!["name".into()],
        )]);
    }
    if yaml_get(root, "on")
        .and_then(YamlValue::as_mapping)
        .is_none()
    {
        return Err(vec![located(
            path,
            indexes,
            "workflow.triggers",
            "on must be a map",
            vec!["on".into()],
        )]);
    }
    if yaml_get(root, "jobs")
        .and_then(YamlValue::as_mapping)
        .is_none()
    {
        return Err(vec![located(
            path,
            indexes,
            "workflow.jobs",
            "jobs must be a map",
            vec!["jobs".into()],
        )]);
    }
    Ok(root)
}

fn normalize_call_inputs(
    root: &Mapping,
    submitted: &Mapping,
    path: &str,
    indexes: &BTreeMap<String, SourceIndex>,
) -> Result<BTreeMap<String, String>, Vec<Diagnostic>> {
    let triggers = yaml_get(root, "on")
        .and_then(YamlValue::as_mapping)
        .expect("root shape");
    if yaml_get(triggers, "workflow_call").is_none() {
        return Err(vec![located(
            path,
            indexes,
            "include.not_reusable",
            "included workflow must declare on.workflow_call",
            vec!["on".into(), "workflow_call".into()],
        )]);
    }
    let definitions = trigger_inputs(triggers, "workflow_call")
        .map_err(|errors| locate_all(indexes.get(path).expect("source index"), path, errors))?;
    normalize_yaml_inputs(&definitions, submitted).map_err(|diagnostic| {
        vec![
            indexes
                .get(path)
                .expect("source index")
                .locate(path, diagnostic),
        ]
    })
}

fn normalize_yaml_inputs(
    definitions: &InputDefinitions,
    submitted: &Mapping,
) -> Result<BTreeMap<String, String>, Diagnostic> {
    let mut values = BTreeMap::new();
    for (key, value) in submitted {
        let Some(name) = key.as_str() else {
            return Err(call_diagnostic(
                "undeclared",
                "workflow call input name is invalid",
            ));
        };
        let Some(definition) = definitions.get(name) else {
            return Err(call_diagnostic(
                "undeclared",
                "workflow call input is undeclared",
            ));
        };
        let normalized = match (definition.kind, value) {
            (InputKind::Boolean, YamlValue::Bool(value)) => value.to_string(),
            (_, YamlValue::String(value)) => value.clone(),
            _ => {
                return Err(call_diagnostic(
                    "invalid",
                    "workflow call input has invalid type",
                ));
            }
        };
        values.insert(name.to_owned(), normalized);
    }
    super::normalize_submitted_inputs(definitions, &values, true)
}

fn call_diagnostic(reason: &str, message: &str) -> Diagnostic {
    unlocated_diagnostic(
        &format!("call_input.{reason}"),
        message,
        vec!["on".into(), "workflow_call".into(), "inputs".into()],
    )
}

fn add_direct_jobs(
    root: &Mapping,
    source_path: &str,
    prefix: &[String],
    inputs: &BTreeMap<String, String>,
    state: &mut CompositionState,
    indexes: &BTreeMap<String, SourceIndex>,
) -> Result<(), Vec<Diagnostic>> {
    let jobs = yaml_get(root, "jobs")
        .and_then(YamlValue::as_mapping)
        .expect("root shape");
    for (raw_id, definition) in jobs {
        let Some(id) = raw_id.as_str() else {
            return Err(vec![located(
                source_path,
                indexes,
                "job.id",
                "job identifier must be a string",
                vec!["jobs".into()],
            )]);
        };
        let generated = generated_id(prefix, id);
        if generated.len() > 63 || !valid_generated_id(&generated) {
            return Err(vec![located(
                source_path,
                indexes,
                "include.job_id",
                "generated job ID is invalid or exceeds 63 bytes",
                vec!["jobs".into(), id.to_owned().into()],
            )]);
        }
        if state
            .jobs
            .contains_key(YamlValue::String(generated.clone()))
        {
            return Err(vec![located(
                source_path,
                indexes,
                "include.job_collision",
                "generated job ID collides with another job",
                vec!["jobs".into(), id.to_owned().into()],
            )]);
        }
        let transformed = transform_job(definition, prefix, inputs, source_path, id, indexes)?;
        state
            .jobs
            .insert(YamlValue::String(generated.clone()), transformed);
        state
            .origins
            .insert(generated, (source_path.to_owned(), id.to_owned()));
    }
    Ok(())
}

fn transform_job(
    definition: &YamlValue,
    prefix: &[String],
    inputs: &BTreeMap<String, String>,
    source_path: &str,
    id: &str,
    indexes: &BTreeMap<String, SourceIndex>,
) -> Result<YamlValue, Vec<Diagnostic>> {
    let mut transformed = definition.clone();
    let Some(job) = transformed.as_mapping_mut() else {
        return Ok(transformed);
    };
    if !inputs.is_empty() {
        let env_key = YamlValue::String("env".into());
        let env = job
            .entry(env_key)
            .or_insert_with(|| YamlValue::Mapping(Mapping::new()));
        if let Some(env) = env.as_mapping_mut() {
            for (name, value) in inputs {
                let environment_name = format!("ROBINE_CALL_INPUT_{}", name.to_ascii_uppercase());
                if env.contains_key(YamlValue::String(environment_name.clone())) {
                    return Err(vec![located(
                        source_path,
                        indexes,
                        "call_input.env_collision",
                        "environment is reserved for a workflow call input",
                        vec![
                            "jobs".into(),
                            id.to_owned().into(),
                            "env".into(),
                            environment_name.into(),
                        ],
                    )]);
                }
                env.insert(
                    YamlValue::String(environment_name),
                    YamlValue::String(value.clone()),
                );
            }
        }
    }
    if !prefix.is_empty() {
        if let Some(needs) = job.get_mut(YamlValue::String("needs".into())) {
            prefix_needs(needs, prefix);
        }
        if let Some(steps) = job
            .get_mut(YamlValue::String("steps".into()))
            .and_then(YamlValue::as_sequence_mut)
        {
            rewrite_artifact_sources(steps, prefix);
        }
    }
    Ok(transformed)
}

fn prefix_needs(needs: &mut YamlValue, prefix: &[String]) {
    match needs {
        YamlValue::String(id) => *id = generated_id(prefix, id),
        YamlValue::Sequence(ids) => {
            for id in ids {
                if let YamlValue::String(id) = id {
                    *id = generated_id(prefix, id);
                }
            }
        }
        _ => {}
    }
}

fn rewrite_artifact_sources(steps: &mut [YamlValue], prefix: &[String]) {
    for step in steps {
        let Some(step) = step.as_mapping_mut() else {
            continue;
        };
        if yaml_get(step, "uses").and_then(YamlValue::as_str) != Some("artifacts/download") {
            continue;
        }
        let Some(options) = step
            .get_mut(YamlValue::String("with".into()))
            .and_then(YamlValue::as_mapping_mut)
        else {
            continue;
        };
        if let Some(YamlValue::String(source)) = options.get_mut(YamlValue::String("from".into())) {
            *source = generated_id(prefix, source);
        }
    }
}

fn parse_includes(
    root: &Mapping,
    source_path: &str,
    indexes: &BTreeMap<String, SourceIndex>,
) -> Result<Vec<Include>, Vec<Diagnostic>> {
    let Some(value) = yaml_get(root, "includes") else {
        return Ok(Vec::new());
    };
    let Some(includes) = value
        .as_mapping()
        .filter(|includes| (1..=8).contains(&includes.len()))
    else {
        return Err(vec![located(
            source_path,
            indexes,
            "include.type",
            "includes must be a map of one to eight entries",
            vec!["includes".into()],
        )]);
    };
    let mut normalized = Vec::with_capacity(includes.len());
    for (alias, definition) in includes {
        let Some(alias) = alias.as_str().filter(|alias| valid_alias(alias)) else {
            return Err(vec![located(
                source_path,
                indexes,
                "include.alias",
                "invalid include alias",
                vec!["includes".into()],
            )]);
        };
        let base = vec!["includes".into(), alias.to_owned().into()];
        let Some(definition) = definition.as_mapping() else {
            return Err(vec![located(
                source_path,
                indexes,
                "include.definition",
                "include definition must be a map",
                base,
            )]);
        };
        if let Some(key) = definition
            .keys()
            .filter_map(YamlValue::as_str)
            .find(|key| !INCLUDE_KEYS.contains(key))
        {
            return Err(vec![located(
                source_path,
                indexes,
                "include.unknown_key",
                "unknown include key",
                append(&base, key),
            )]);
        }
        let Some(path) = yaml_get(definition, "path")
            .and_then(YamlValue::as_str)
            .filter(|path| valid_workflow_path(path))
        else {
            return Err(vec![located(
                source_path,
                indexes,
                "include.path",
                "include path must be canonical",
                append(&base, "path"),
            )]);
        };
        let inputs = match yaml_get(definition, "inputs") {
            None => Mapping::new(),
            Some(YamlValue::Mapping(inputs)) => inputs.clone(),
            Some(_) => {
                return Err(vec![located(
                    source_path,
                    indexes,
                    "include.inputs",
                    "include inputs must be a map",
                    append(&base, "inputs"),
                )]);
            }
        };
        normalized.push(Include {
            alias: alias.to_owned(),
            path: path.to_owned(),
            inputs,
        });
    }
    normalized.sort_by(|left, right| left.alias.cmp(&right.alias));
    Ok(normalized)
}

fn remap_all(
    diagnostics: Vec<Diagnostic>,
    entry_path: &str,
    origins: &BTreeMap<String, (String, String)>,
    indexes: &BTreeMap<String, SourceIndex>,
) -> Vec<Diagnostic> {
    diagnostics
        .into_iter()
        .map(|mut diagnostic| {
            let (source_path, index) = match diagnostic.path.as_slice() {
                [PathSegment::Key(root), PathSegment::Key(job), rest @ ..] if root == "jobs" => {
                    if let Some((source_path, original)) = origins.get(job) {
                        let mut path = vec!["jobs".into(), original.clone().into()];
                        path.extend_from_slice(rest);
                        diagnostic.path = path;
                        (source_path.as_str(), indexes.get(source_path))
                    } else {
                        (entry_path, indexes.get(entry_path))
                    }
                }
                _ => (entry_path, indexes.get(entry_path)),
            };
            index.map_or(diagnostic.clone(), |index| {
                index.locate(source_path, diagnostic)
            })
        })
        .collect()
}

fn located(
    source_path: &str,
    indexes: &BTreeMap<String, SourceIndex>,
    code: &str,
    message: &str,
    path: Vec<PathSegment>,
) -> Diagnostic {
    let diagnostic = unlocated_diagnostic(code, message, path);
    indexes.get(source_path).map_or_else(
        || source_diagnostic(source_path, code, message, Vec::new()),
        |index| index.locate(source_path, diagnostic),
    )
}

fn source_diagnostic(
    source_path: &str,
    code: &str,
    message: &str,
    path: Vec<PathSegment>,
) -> Diagnostic {
    let mut diagnostic = unlocated_diagnostic(code, message, path);
    diagnostic.source_path = source_path.into();
    diagnostic.line = 1;
    diagnostic.column = 1;
    diagnostic
}

fn generated_id(prefix: &[String], id: &str) -> String {
    if prefix.is_empty() {
        id.to_owned()
    } else {
        format!("{}--{id}", prefix.join("--"))
    }
}

fn valid_alias(alias: &str) -> bool {
    (1..=20).contains(&alias.len())
        && alias.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && alias
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn valid_generated_id(id: &str) -> bool {
    id.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && id.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
}
