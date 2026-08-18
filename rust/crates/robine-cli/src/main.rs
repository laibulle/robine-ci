use async_trait::async_trait;
use robine_execution::{
    CancellationSignal, DockerCli, DockerConfig, ExecutionControl, ExecutionError,
    ExecutionSpecification, OutputChunk, OutputSink, SourceFile, StepKind,
};
use std::{
    collections::BTreeMap,
    env, fs,
    path::{Path, PathBuf},
    process::ExitCode,
};
use uuid::Uuid;

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
    let mut workflow_path = DEFAULT_WORKFLOW.to_owned();
    let mut selected_job = None;
    let mut no_deps = false;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--workflow" | "-w" => {
                index += 1;
                workflow_path = arguments
                    .get(index)
                    .cloned()
                    .ok_or_else(|| (64, usage("--workflow requires a path")))?;
            }
            "--no-deps" => no_deps = true,
            value if value.starts_with('-') => return Err((64, usage("unknown run option"))),
            value if selected_job.is_none() => selected_job = Some(value.to_owned()),
            _ => return Err((64, usage("run accepts at most one job ID"))),
        }
        index += 1;
    }
    let (resolved, sources) = resolve_workflow(directory, &workflow_path)?;
    let jobs = resolved
        .workflow
        .pipeline_jobs("workflow_dispatch", &BTreeMap::new())
        .map_err(|diagnostic| (2, format!("[{}] {}", diagnostic.code, diagnostic.message)))?;
    let selected = select_jobs(&jobs, selected_job.as_deref(), no_deps)?;
    let source_files = snapshot(directory)?;
    println!(
        "Workflow revision: {workflow_path}\nWorking directory: {}\nSelected jobs: {}\nCI-only cache/artifact operations are omitted locally.",
        directory.display(),
        selected.join(", ")
    );
    let runtime = tokio::runtime::Runtime::new()
        .map_err(|error| (3, format!("Cannot start async runtime: {error}")))?;
    runtime.block_on(async {
        let runner = DockerCli::new(DockerConfig::default());
        for job_id in selected {
            let job = jobs
                .get(&job_id)
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
            specification.source_files = source_files.clone();
            specification
                .steps
                .retain(|step| step.kind == StepKind::Run);
            if specification.steps.is_empty() {
                continue;
            }
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
    format!("{reason}\nUsage: robine <version|init|validate|run> [options]")
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
}
