use async_trait::async_trait;
use robine_execution::{
    CancellationSignal, DockerCli, DockerConfig, ExecutionControl, ExecutionError,
    ExecutionSpecification, OutputChunk, OutputSink, SourceFile, StepKind,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    env, fs,
    path::{Path, PathBuf},
    process::{Command, ExitCode},
};
use uuid::Uuid;
use zeroize::Zeroizing;

const DEFAULT_WORKFLOW: &str = ".robine-ci/workflows/ci.yml";
const TEMPLATE: &str = "version: 1\nname: CI\non:\n  push: {}\n  pull_request: {}\njobs:\n  test:\n    image: alpine:3.22\n    steps:\n      - name: test\n        run: echo \"Configure your test command\"\n";

fn main() -> ExitCode {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    match run(
        &arguments,
        &env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    ) {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err((code, message)) => {
            eprintln!("{message}");
            ExitCode::from(code)
        }
    }
}

fn run(arguments: &[String], directory: &Path) -> Result<String, (u8, String)> {
    match arguments {
        [command] if command == "version" || command == "--version" => {
            Ok(format!("robine {}", env!("CARGO_PKG_VERSION")))
        }
        [command, rest @ ..] if command == "validate" => validate(rest, directory),
        [command, rest @ ..] if command == "init" => initialize(rest, directory),
        [command, rest @ ..] if command == "run" => execute(rest, directory),
        [] => Err((64, usage("a command is required"))),
        [command, ..] => Err((64, usage(&format!("unknown command {command}")))),
    }
}

fn execute(arguments: &[String], directory: &Path) -> Result<String, (u8, String)> {
    let options = parse_run_arguments(arguments)?;
    let (resolved, sources) = resolve_workflow(directory, &options.workflow_path)?;
    let jobs = resolved
        .workflow
        .pipeline_jobs("workflow_dispatch", &options.inputs)
        .map_err(|diagnostic| (2, format!("[{}] {}", diagnostic.code, diagnostic.message)))?;
    let selected = select_jobs(&jobs, options.selected_job.as_deref(), options.no_deps)?;
    let source_files = snapshot(directory)?;
    let local_secrets = options
        .env_file
        .as_deref()
        .map(|path| load_local_secrets(directory, path))
        .transpose()?;
    let plans = build_local_plans(
        &jobs,
        &selected,
        &options,
        &source_files,
        local_secrets.as_ref(),
    )?;
    let input_summary = if options.inputs.is_empty() {
        "none".into()
    } else {
        options
            .inputs
            .iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    println!(
        "Workflow revision: {}\nWorking directory: {}\nSelected jobs: {}\nInputs: {input_summary}\nLocal secrets loaded: {}\n{}CI-only cache/artifact operations and provider metadata are omitted locally. Server-held secrets are never downloaded.",
        options.workflow_path,
        directory.display(),
        selected.join(", "),
        plans.injected_secret_count,
        options.step.as_ref().map_or_else(String::new, |step| format!("Selected step: {step}. Earlier run steps are included to reconstruct workspace state.\n"))
    );
    if options.verbose {
        for (job_id, specification) in &plans.jobs {
            let normalized = serde_json::to_string_pretty(specification)
                .map_err(|_| (2, format!("Cannot render normalized plan for {job_id}")))?;
            println!("Normalized local plan for {job_id}:\n{normalized}");
        }
    }
    let runtime = tokio::runtime::Runtime::new()
        .map_err(|error| (3, format!("Cannot start async runtime: {error}")))?;
    runtime.block_on(async {
        let runner = DockerCli::new(DockerConfig::default());
        for (job_id, specification) in plans.jobs {
            println!("Running {job_id} with image {}", specification.image);
            let result = runner
                .run_controlled(
                    &specification,
                    ExecutionControl {
                        output: &ConsoleOutput,
                        cancellation: &NeverCancel,
                        builtins: None,
                        last_sequence: 0,
                    },
                )
                .await
                .map_err(|error| (3, format!("Docker execution failed: {error}")))?;
            if !matches!(result.status, robine_execution::ExecutionStatus::Succeeded) {
                return Err((5, format!("Job {job_id} failed ({:?})", result.status)));
            }
        }
        let _ = sources;
        Ok("Local workflow succeeded".into())
    })
}

#[derive(Debug)]
struct LocalPlans {
    jobs: Vec<(String, ExecutionSpecification)>,
    injected_secret_count: usize,
}

fn build_local_plans(
    jobs: &BTreeMap<String, robine_workflows::PipelineJob>,
    selected: &[String],
    options: &RunOptions,
    source_files: &[SourceFile],
    local_secrets: Option<&BTreeMap<String, Zeroizing<String>>>,
) -> Result<LocalPlans, (u8, String)> {
    let mut plans = Vec::new();
    let mut injected_names = BTreeSet::new();
    for job_id in selected {
        let job = jobs
            .get(job_id)
            .ok_or_else(|| (2, format!("Unknown job {job_id}")))?;
        let mut raw = job.execution.clone();
        let object = raw
            .as_object_mut()
            .ok_or_else(|| (2, format!("Invalid execution for {job_id}")))?;
        object.insert("attempt_id".into(), serde_json::json!(Uuid::new_v4()));
        object.insert(
            "build_env".into(),
            serde_json::json!({
                "ROBINE_BUILD_COMMIT_SHA": "local",
                "ROBINE_BUILD_REF_NAME": "local",
                "ROBINE_BUILD_REF_TYPE": "local",
                "ROBINE_BUILD_TIMESTAMP": "local",
                "ROBINE_BUILD_PIPELINE_ID": "local",
                "ROBINE_BUILD_TRIGGER": "manual"
            }),
        );
        let mut specification: ExecutionSpecification = serde_json::from_value(raw)
            .map_err(|error| (2, format!("Invalid execution for {job_id}: {error}")))?;
        specification.source_files = source_files.to_vec();
        specification
            .steps
            .retain(|step| step.kind == StepKind::Run);
        if options.selected_job.as_deref() == Some(job_id)
            && let Some(step) = options.step.as_deref()
        {
            retain_steps_through(&mut specification.steps, step)?;
        }
        injected_names.extend(specification.secret_names.iter().cloned());
        resolve_local_secrets(&mut specification, local_secrets)?;
        if !specification.steps.is_empty() {
            plans.push((job_id.clone(), specification));
        }
    }
    Ok(LocalPlans {
        jobs: plans,
        injected_secret_count: injected_names.len(),
    })
}

#[derive(Debug, Eq, PartialEq)]
struct RunOptions {
    workflow_path: String,
    selected_job: Option<String>,
    no_deps: bool,
    inputs: BTreeMap<String, String>,
    step: Option<String>,
    env_file: Option<PathBuf>,
    verbose: bool,
}

fn parse_run_arguments(arguments: &[String]) -> Result<RunOptions, (u8, String)> {
    let mut options = RunOptions {
        workflow_path: DEFAULT_WORKFLOW.to_owned(),
        selected_job: None,
        no_deps: false,
        inputs: BTreeMap::new(),
        step: None,
        env_file: None,
        verbose: false,
    };
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--workflow" | "-w" => {
                index += 1;
                options.workflow_path = arguments
                    .get(index)
                    .cloned()
                    .ok_or_else(|| (64, usage("--workflow requires a path")))?;
            }
            "--input" => {
                index += 1;
                let value = arguments
                    .get(index)
                    .ok_or_else(|| (64, usage("--input requires name=value")))?;
                let (name, value) = value
                    .split_once('=')
                    .filter(|(name, _)| !name.is_empty())
                    .ok_or_else(|| (64, usage("--input requires name=value")))?;
                if options.inputs.insert(name.into(), value.into()).is_some() {
                    return Err((64, usage(&format!("duplicate input {name}"))));
                }
            }
            "--step" => {
                index += 1;
                let step = arguments
                    .get(index)
                    .filter(|value| !value.is_empty())
                    .cloned()
                    .ok_or_else(|| (64, usage("--step requires a name or 1-based index")))?;
                if options.step.replace(step).is_some() {
                    return Err((64, usage("--step may be provided only once")));
                }
            }
            "--env-file" => {
                index += 1;
                let path = arguments
                    .get(index)
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
                    .ok_or_else(|| (64, usage("--env-file requires a relative path")))?;
                if options.env_file.replace(path).is_some() {
                    return Err((64, usage("--env-file may be provided only once")));
                }
            }
            "--verbose" => options.verbose = true,
            "--no-deps" => options.no_deps = true,
            value if value.starts_with('-') => return Err((64, usage("unknown run option"))),
            value if options.selected_job.is_none() => {
                options.selected_job = Some(value.to_owned());
            }
            _ => return Err((64, usage("run accepts at most one job ID"))),
        }
        index += 1;
    }
    if options.step.is_some() && options.selected_job.is_none() {
        return Err((64, usage("--step requires an explicit job ID")));
    }
    Ok(options)
}

fn retain_steps_through(
    steps: &mut Vec<robine_execution::ExecutionStep>,
    selected: &str,
) -> Result<(), (u8, String)> {
    let position = selected
        .parse::<usize>()
        .ok()
        .filter(|index| *index > 0)
        .and_then(|index| index.checked_sub(1))
        .filter(|index| *index < steps.len())
        .or_else(|| steps.iter().position(|step| step.name == selected))
        .ok_or_else(|| {
            (
                2,
                format!(
                    "Unknown step {selected}. Valid steps: {}",
                    steps
                        .iter()
                        .enumerate()
                        .map(|(index, step)| format!("{}:{}", index + 1, step.name))
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            )
        })?;
    steps.truncate(position + 1);
    Ok(())
}

fn load_local_secrets(
    directory: &Path,
    relative: &Path,
) -> Result<BTreeMap<String, Zeroizing<String>>, (u8, String)> {
    if relative.is_absolute()
        || relative.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir
                    | std::path::Component::RootDir
                    | std::path::Component::Prefix(_)
            )
        })
    {
        return Err((
            3,
            "Secret env file must be a relative path inside the Git worktree".into(),
        ));
    }
    let root_output = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|_| (3, "Git is required to validate the secret env file".into()))?;
    if !root_output.status.success() {
        return Err((3, "Current directory is not inside a Git worktree".into()));
    }
    let root = PathBuf::from(String::from_utf8_lossy(&root_output.stdout).trim())
        .canonicalize()
        .map_err(|_| (3, "Cannot resolve the Git worktree root".into()))?;
    let lexical = directory.join(relative);
    let mut cursor = directory.to_path_buf();
    for component in relative.components() {
        cursor.push(component);
        if fs::symlink_metadata(&cursor).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
            return Err((
                3,
                "Secret env file path must not contain symbolic links".into(),
            ));
        }
    }
    let path = lexical
        .canonicalize()
        .map_err(|_| (3, "Secret env file does not exist".into()))?;
    if !path.starts_with(&root) {
        return Err((3, "Secret env file is outside the Git worktree".into()));
    }
    let metadata = fs::metadata(&path).map_err(|_| (3, "Cannot inspect secret env file".into()))?;
    if !metadata.is_file() || metadata.len() > 1_048_576 {
        return Err((
            3,
            "Secret env file must be a regular file no larger than 1 MiB".into(),
        ));
    }
    let relative_to_root = path
        .strip_prefix(&root)
        .map_err(|_| (3, "Secret env file is outside the Git worktree".into()))?;
    let ignored = Command::new("git")
        .arg("-C")
        .arg(&root)
        .args(["check-ignore", "--quiet", "--"])
        .arg(relative_to_root)
        .status()
        .map_err(|_| {
            (
                3,
                "Cannot verify that the secret env file is ignored".into(),
            )
        })?;
    if !ignored.success() {
        return Err((
            4,
            "Secret env file must be untracked and matched by .gitignore".into(),
        ));
    }
    let contents = fs::read_to_string(&path)
        .map(Zeroizing::new)
        .map_err(|_| (3, "Secret env file must be valid UTF-8".into()))?;
    parse_secret_env(&contents)
}

fn parse_secret_env(contents: &str) -> Result<BTreeMap<String, Zeroizing<String>>, (u8, String)> {
    let mut secrets = BTreeMap::new();
    for (index, line) in contents.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (name, raw_value) = line
            .split_once('=')
            .ok_or_else(|| (2, format!("Malformed secret env line {}", index + 1)))?;
        let name = name.trim();
        if name.is_empty()
            || name.len() > 255
            || !name.bytes().enumerate().all(|(position, byte)| {
                byte.is_ascii_uppercase() || byte == b'_' || (position > 0 && byte.is_ascii_digit())
            })
        {
            return Err((2, format!("Invalid secret name on line {}", index + 1)));
        }
        let raw_value = raw_value.trim();
        let value = match (raw_value.as_bytes().first(), raw_value.as_bytes().last()) {
            (Some(first @ (b'\'' | b'"')), Some(last)) if first == last && raw_value.len() >= 2 => {
                &raw_value[1..raw_value.len() - 1]
            }
            (Some(b'\'' | b'"'), _) | (_, Some(b'\'' | b'"')) => {
                return Err((
                    2,
                    format!("Unmatched quote on secret env line {}", index + 1),
                ));
            }
            _ => raw_value,
        };
        if !(8..=65_536).contains(&value.len()) || value.contains('\0') {
            return Err((
                2,
                format!(
                    "Secret value on line {} must contain 8 to 65536 bytes",
                    index + 1
                ),
            ));
        }
        if secrets
            .insert(name.into(), Zeroizing::new(value.into()))
            .is_some()
        {
            return Err((2, format!("Duplicate secret {name}")));
        }
    }
    Ok(secrets)
}

fn resolve_local_secrets(
    specification: &mut ExecutionSpecification,
    available: Option<&BTreeMap<String, Zeroizing<String>>>,
) -> Result<(), (u8, String)> {
    if specification.secret_names.is_empty() {
        return Ok(());
    }
    let available = available.ok_or_else(|| {
        (
            2,
            "This job declares secrets. Pass an ignored --env-file containing every required name"
                .into(),
        )
    })?;
    let mut resolved = BTreeMap::new();
    for name in &specification.secret_names {
        let value = available.get(name).ok_or_else(|| {
            (
                2,
                format!("Required local secret {name} is missing from --env-file"),
            )
        })?;
        resolved.insert(name.clone(), value.clone());
    }
    for service in &mut specification.services {
        for (environment_name, secret_name) in &service.secret_references {
            let value = resolved.get(secret_name).ok_or_else(|| {
                (
                    2,
                    format!("Required service secret {secret_name} is missing from --env-file"),
                )
            })?;
            service
                .secrets
                .insert(environment_name.clone(), value.clone());
        }
        service.secret_references.clear();
    }
    specification.secret_names.clear();
    specification.secrets = resolved;
    Ok(())
}

fn resolve_workflow(
    directory: &Path,
    workflow_path: &str,
) -> Result<(robine_workflows::ResolvedWorkflow, BTreeMap<String, String>), (u8, String)> {
    let entry = directory.join(workflow_path);
    let root = entry
        .parent()
        .ok_or_else(|| (3, "Invalid workflow path".into()))?;
    let mut sources = BTreeMap::new();
    for item in
        fs::read_dir(root).map_err(|error| (3, format!("Cannot read workflows: {error}")))?
    {
        let path = item.map_err(|error| (3, error.to_string()))?.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let relative = format!(".robine-ci/workflows/{name}");
        if robine_workflows::valid_workflow_path(&relative) && path.is_file() {
            sources.insert(
                relative,
                fs::read_to_string(&path).map_err(|error| (3, error.to_string()))?,
            );
        }
    }
    let resolved = robine_workflows::resolve(
        workflow_path,
        &sources,
        &robine_workflows::WorkflowLimits::default(),
    )
    .map_err(|diagnostics| {
        (
            2,
            diagnostics
                .iter()
                .map(|item| format!("[{}] {}", item.code, item.message))
                .collect::<Vec<_>>()
                .join("\n"),
        )
    })?;
    Ok((resolved, sources))
}

fn select_jobs(
    jobs: &BTreeMap<String, robine_workflows::PipelineJob>,
    selected: Option<&str>,
    no_deps: bool,
) -> Result<Vec<String>, (u8, String)> {
    let Some(selected) = selected else {
        return Ok(jobs.keys().cloned().collect());
    };
    if !jobs.contains_key(selected) {
        return Err((
            2,
            format!(
                "Unknown job {selected}. Valid jobs: {}",
                jobs.keys().cloned().collect::<Vec<_>>().join(", ")
            ),
        ));
    }
    let mut selected_jobs = Vec::new();
    visit_job(selected, jobs, &mut selected_jobs, !no_deps);
    Ok(selected_jobs)
}

fn visit_job(
    id: &str,
    jobs: &BTreeMap<String, robine_workflows::PipelineJob>,
    output: &mut Vec<String>,
    dependencies: bool,
) {
    if output.iter().any(|known| known == id) {
        return;
    }
    if dependencies {
        for dependency in &jobs[id].needs {
            visit_job(dependency, jobs, output, true);
        }
    }
    output.push(id.into());
}

fn snapshot(directory: &Path) -> Result<Vec<SourceFile>, (u8, String)> {
    fn walk(root: &Path, path: &Path, files: &mut Vec<SourceFile>) -> Result<(), (u8, String)> {
        for item in fs::read_dir(path).map_err(|error| (3, error.to_string()))? {
            let item = item.map_err(|error| (3, error.to_string()))?;
            let path = item.path();
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default();
            if matches!(name, ".git" | "target" | "deps" | "_build" | "node_modules") {
                continue;
            }
            let metadata = fs::symlink_metadata(&path).map_err(|error| (3, error.to_string()))?;
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                walk(root, &path, files)?;
            } else if metadata.is_file() {
                if files.len() >= 10_000 {
                    return Err((3, "Repository contains more than 10,000 files".into()));
                }
                files.push(SourceFile {
                    path: path
                        .strip_prefix(root)
                        .map_err(|_| (3, "Invalid repository path".into()))?
                        .to_path_buf(),
                    contents: fs::read(&path).map_err(|error| (3, error.to_string()))?,
                });
            }
        }
        Ok(())
    }
    let mut files = Vec::new();
    walk(directory, directory, &mut files)?;
    Ok(files)
}

struct ConsoleOutput;
#[async_trait]
impl OutputSink for ConsoleOutput {
    async fn append(&self, chunk: OutputChunk) -> Result<(), ExecutionError> {
        print!("{}", String::from_utf8_lossy(&chunk.bytes));
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

fn validate(arguments: &[String], directory: &Path) -> Result<String, (u8, String)> {
    let mut json = false;
    let mut path = None;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--format" | "-f" => {
                index += 1;
                json = arguments.get(index).is_some_and(|value| value == "json");
                if !json && arguments.get(index).is_none_or(|value| value != "human") {
                    return Err((64, usage("format must be human or json")));
                }
            }
            value if value.starts_with('-') => return Err((64, usage("unknown option"))),
            value if path.is_none() => path = Some(value),
            _ => return Err((64, usage("validate accepts at most one path"))),
        }
        index += 1;
    }
    let entry = directory.join(path.unwrap_or(DEFAULT_WORKFLOW));
    let source_root = entry
        .parent()
        .ok_or_else(|| (3, "Invalid workflow path".into()))?;
    let mut sources = BTreeMap::new();
    for item in
        fs::read_dir(source_root).map_err(|error| (3, format!("Cannot read workflows: {error}")))?
    {
        let item = item.map_err(|error| (3, format!("Cannot read workflow: {error}")))?;
        let item_path = item.path();
        let Some(name) = item_path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let relative = format!(".robine-ci/workflows/{name}");
        if robine_workflows::valid_workflow_path(&relative) && item_path.is_file() {
            let source = fs::read_to_string(&item_path)
                .map_err(|error| (3, format!("Cannot read {}: {error}", item_path.display())))?;
            sources.insert(relative, source);
        }
    }
    let entry = entry
        .strip_prefix(directory)
        .ok()
        .and_then(Path::to_str)
        .unwrap_or(DEFAULT_WORKFLOW);
    match robine_workflows::resolve(entry, &sources, &robine_workflows::WorkflowLimits::default()) {
        Ok(workflow) if json => Ok(serde_json::json!({"valid":true,"path":entry,"jobs":workflow.workflow.order,"warnings":workflow.workflow.warnings}).to_string()),
        Ok(workflow) => Ok(format!("Valid workflow: {entry}\nExpanded jobs ({}):\n{}", workflow.workflow.order.len(), workflow.workflow.order.iter().map(|job| format!("  - {job}")).collect::<Vec<_>>().join("\n"))),
        Err(diagnostics) if json => Err((2, serde_json::json!({"valid":false,"diagnostics":diagnostics}).to_string())),
        Err(diagnostics) => Err((2, format!("Invalid workflow\n{}\nFix these errors and run `robine validate` again.", diagnostics.iter().map(|item| format!("{}:{}:{} [{}] {}", item.source_path, item.line, item.column, item.code, item.message)).collect::<Vec<_>>().join("\n")))),
    }
}

fn initialize(arguments: &[String], directory: &Path) -> Result<String, (u8, String)> {
    let yes = arguments.iter().any(|argument| argument == "--yes");
    let force = arguments.iter().any(|argument| argument == "--force");
    if arguments
        .iter()
        .any(|argument| !matches!(argument.as_str(), "--yes" | "--force"))
    {
        return Err((64, usage("unknown init option")));
    }
    let path = directory.join(DEFAULT_WORKFLOW);
    if path.exists() && !force {
        return Err((
            4,
            format!(
                "Refusing to overwrite {}. Pass --force explicitly.",
                path.display()
            ),
        ));
    }
    if !yes {
        return Ok(format!(
            "Would create {}:\n\n{TEMPLATE}\nRun `robine init --yes` to write it.",
            path.display()
        ));
    }
    fs::create_dir_all(path.parent().unwrap_or(directory))
        .map_err(|error| (3, format!("Cannot create workflow directory: {error}")))?;
    fs::write(&path, TEMPLATE)
        .map_err(|error| (3, format!("Cannot create {}: {error}", path.display())))?;
    Ok(format!(
        "Created {}\nNext: run `robine validate`.",
        path.display()
    ))
}

fn usage(reason: &str) -> String {
    format!(
        "{reason}\nUsage: robine <version|init|validate|run> [options]\n       robine run [job-id] [--workflow path] [--input name=value]... [--step name-or-index] [--env-file path] [--no-deps] [--verbose]"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_and_usage_are_stable() {
        assert!(
            run(&["version".into()], Path::new("."))
                .unwrap()
                .starts_with("robine ")
        );
        assert_eq!(run(&[], Path::new(".")).unwrap_err().0, 64);
    }

    #[test]
    fn run_arguments_preserve_exact_manual_inputs() {
        let options = parse_run_arguments(&[
            "release".into(),
            "--workflow".into(),
            ".robine-ci/workflows/release.yml".into(),
            "--input".into(),
            "environment=staging".into(),
            "--input".into(),
            "dry_run=true".into(),
            "--step".into(),
            "package".into(),
            "--env-file".into(),
            ".robine.env".into(),
            "--verbose".into(),
            "--no-deps".into(),
        ])
        .expect("valid run options");
        assert_eq!(options.selected_job.as_deref(), Some("release"));
        assert_eq!(options.workflow_path, ".robine-ci/workflows/release.yml");
        assert!(options.no_deps);
        assert_eq!(options.step.as_deref(), Some("package"));
        assert_eq!(options.env_file.as_deref(), Some(Path::new(".robine.env")));
        assert!(options.verbose);
        assert_eq!(options.inputs["environment"], "staging");
        assert_eq!(options.inputs["dry_run"], "true");
    }

    #[test]
    fn run_arguments_reject_missing_and_duplicate_inputs() {
        assert_eq!(
            parse_run_arguments(&["--input".into(), "invalid".into()])
                .expect_err("missing equals")
                .0,
            64
        );
        assert_eq!(
            parse_run_arguments(&[
                "--input".into(),
                "environment=staging".into(),
                "--input".into(),
                "environment=production".into(),
            ])
            .expect_err("duplicate input")
            .0,
            64
        );
        assert_eq!(
            parse_run_arguments(&["--step".into(), "test".into()])
                .expect_err("step without job")
                .0,
            64
        );
    }

    #[test]
    fn step_selection_includes_prior_run_steps_by_name_or_index() {
        let step = |name: &str| robine_execution::ExecutionStep {
            name: name.into(),
            kind: StepKind::Run,
            value: format!("echo {name}"),
            condition: robine_execution::StepCondition::Success,
            with: BTreeMap::new(),
        };
        let mut by_name = vec![step("checkout"), step("compile"), step("test")];
        retain_steps_through(&mut by_name, "compile").expect("named step");
        assert_eq!(
            by_name
                .iter()
                .map(|step| step.name.as_str())
                .collect::<Vec<_>>(),
            ["checkout", "compile"]
        );
        let mut by_index = vec![step("checkout"), step("compile"), step("test")];
        retain_steps_through(&mut by_index, "3").expect("indexed step");
        assert_eq!(by_index.len(), 3);
        assert_eq!(
            retain_steps_through(&mut by_index, "missing")
                .expect_err("unknown step")
                .0,
            2
        );
    }

    #[test]
    fn secret_env_parser_is_literal_bounded_and_duplicate_safe() {
        let secrets =
            parse_secret_env("# local only\nTOKEN='12345678'\nCOMMAND=literal-$(never-executed)\n")
                .expect("literal secrets");
        assert_eq!(secrets["TOKEN"].as_str(), "12345678");
        assert_eq!(secrets["COMMAND"].as_str(), "literal-$(never-executed)");
        assert_eq!(
            parse_secret_env("TOKEN=short\n")
                .expect_err("short secret")
                .0,
            2
        );
        assert_eq!(
            parse_secret_env("TOKEN=12345678\nTOKEN=abcdefgh\n")
                .expect_err("duplicate secret")
                .0,
            2
        );
    }

    #[test]
    fn local_secret_file_must_be_ignored_regular_and_inside_worktree() {
        let root = env::temp_dir().join(format!("robine-cli-secrets-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temporary repository");
        assert!(
            Command::new("git")
                .arg("init")
                .arg("--quiet")
                .arg(&root)
                .status()
                .expect("git init")
                .success()
        );
        fs::write(root.join(".gitignore"), ".robine.env\n").expect("gitignore");
        fs::write(
            root.join(".robine.env"),
            "TOKEN=12345678\nUNUSED=abcdefgh\n",
        )
        .expect("secret file");
        let secrets =
            load_local_secrets(&root, Path::new(".robine.env")).expect("ignored secret file");
        assert_eq!(secrets.len(), 2);
        assert_eq!(
            load_local_secrets(&root, Path::new("../outside.env"))
                .expect_err("outside file")
                .0,
            3
        );
        fs::write(root.join("visible.env"), "TOKEN=12345678\n").expect("visible file");
        assert_eq!(
            load_local_secrets(&root, Path::new("visible.env"))
                .expect_err("visible file")
                .0,
            4
        );
        fs::remove_dir_all(&root).expect("remove temporary repository");
    }

    #[test]
    fn every_selected_job_is_secret_preflighted_before_execution() {
        let execution = |secret: &str| {
            serde_json::json!({
                "image": "alpine:3.22",
                "secret_names": [secret],
                "steps": [{"name":"run","kind":"run","value":"true"}]
            })
        };
        let jobs = BTreeMap::from([
            (
                "dependency".into(),
                robine_workflows::PipelineJob {
                    needs: Vec::new(),
                    execution: execution("FIRST_SECRET"),
                },
            ),
            (
                "target".into(),
                robine_workflows::PipelineJob {
                    needs: vec!["dependency".into()],
                    execution: execution("MISSING_SECRET"),
                },
            ),
        ]);
        let options = parse_run_arguments(&["target".into()]).expect("target selection");
        let available =
            BTreeMap::from([("FIRST_SECRET".into(), Zeroizing::new("12345678".into()))]);
        let error = build_local_plans(
            &jobs,
            &["dependency".into(), "target".into()],
            &options,
            &[],
            Some(&available),
        )
        .expect_err("all secrets must resolve before execution");
        assert_eq!(error.0, 2);
        assert!(error.1.contains("MISSING_SECRET"));
    }

    #[test]
    fn normalized_verbose_plan_never_serializes_secrets_or_source_content() {
        let jobs = BTreeMap::from([(
            "test".into(),
            robine_workflows::PipelineJob {
                needs: Vec::new(),
                execution: serde_json::json!({
                    "image": "alpine:3.22",
                    "secret_names": ["TOKEN"],
                    "steps": [{"name":"run","kind":"run","value":"true"}]
                }),
            },
        )]);
        let options =
            parse_run_arguments(&["test".into(), "--verbose".into()]).expect("verbose target");
        let available =
            BTreeMap::from([("TOKEN".into(), Zeroizing::new("super-secret-value".into()))]);
        let source = SourceFile {
            path: "private.txt".into(),
            contents: b"private-source-content".to_vec(),
        };
        let plans = build_local_plans(
            &jobs,
            &["test".into()],
            &options,
            &[source],
            Some(&available),
        )
        .expect("safe normalized plan");
        let serialized = serde_json::to_string_pretty(&plans.jobs[0].1).expect("serialize plan");
        assert!(!serialized.contains("super-secret-value"));
        assert!(!serialized.contains("private-source-content"));
        assert!(!serialized.contains("TOKEN"));
    }
}
