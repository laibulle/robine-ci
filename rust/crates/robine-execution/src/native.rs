use crate::{
    BuiltinRestore, ExecutionControl, ExecutionError, ExecutionResult, ExecutionRunner,
    ExecutionSpecification, ExecutionStatus, ExecutionStep, OutputChannel, OutputChunk,
    StepCondition, StepKind, docker::StreamingRedactor,
};
use async_trait::async_trait;
use flate2::{Compression, read::GzDecoder, write::GzEncoder};
use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::Write,
    path::{Component, Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::{
    io::AsyncReadExt,
    process::{Child, Command},
    sync::mpsc,
    time::{Instant, interval},
};

const STREAM_CHUNK_BYTES: usize = 8 * 1024;

/// Direct trusted-host process executor used by dedicated native macOS runners.
#[derive(Clone, Copy, Debug, Default)]
pub struct NativeProcessRunner;

struct Workspace(PathBuf);

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[async_trait]
impl ExecutionRunner for NativeProcessRunner {
    async fn run(
        &self,
        specification: &ExecutionSpecification,
        control: ExecutionControl<'_>,
    ) -> Result<ExecutionResult, ExecutionError> {
        specification.validate()?;
        if !specification.services.is_empty() {
            return Err(ExecutionError::Unsupported("native service containers"));
        }
        let workspace = prepare_workspace(specification)?;
        let deadline = Instant::now() + Duration::from_millis(specification.timeout_ms);
        let mut sequence = control.last_sequence;
        let mut failed = false;
        let mut exit_code = Some(0);
        for (position, step) in specification.steps.iter().enumerate() {
            let should_run = match step.condition {
                StepCondition::Success => !failed,
                StepCondition::Failure => failed,
                StepCondition::Always => true,
            };
            if !should_run {
                continue;
            }
            let result = match step.kind {
                StepKind::Run => {
                    run_step(
                        specification,
                        &workspace.0,
                        position,
                        step,
                        &mut sequence,
                        deadline,
                        &control,
                    )
                    .await?
                }
                StepKind::Builtin => {
                    run_builtin(&workspace.0, position, step, &mut sequence, &control).await?
                }
            };
            match result.status {
                ExecutionStatus::Cancelled | ExecutionStatus::TimedOut => return Ok(result),
                ExecutionStatus::Failed => {
                    failed = true;
                    exit_code = result.exit_code;
                }
                ExecutionStatus::Succeeded => {}
                ExecutionStatus::ServiceUnavailable => {
                    return Err(ExecutionError::Unsupported("native service containers"));
                }
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
}

fn prepare_workspace(specification: &ExecutionSpecification) -> Result<Workspace, ExecutionError> {
    let root = std::env::temp_dir().join(format!(
        "robine-native-{}-{}",
        specification.attempt_id,
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&root).map_err(|_| ExecutionError::Unavailable {
        phase: "native_workspace",
    })?;
    let workspace = Workspace(root);
    fs::create_dir(workspace.0.join(".tmp")).map_err(|_| ExecutionError::Unavailable {
        phase: "native_workspace",
    })?;
    write_source_files(&workspace.0, &specification.source_files)?;
    Ok(workspace)
}

fn write_source_files(root: &Path, files: &[crate::SourceFile]) -> Result<(), ExecutionError> {
    let mut seen = BTreeSet::new();
    for source in files {
        let relative = safe_relative(&source.path)?;
        if !seen.insert(relative.clone()) {
            return Err(ExecutionError::InvalidSpecification(
                "duplicate source path",
            ));
        }
        let destination = root.join(&relative);
        create_safe_parents(root, &destination)?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(destination)
            .map_err(|_| ExecutionError::InvalidSpecification("source file"))?;
        file.write_all(&source.contents)
            .map_err(|_| ExecutionError::Unavailable {
                phase: "native_source",
            })?;
    }
    Ok(())
}

fn safe_relative(path: &Path) -> Result<PathBuf, ExecutionError> {
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(ExecutionError::InvalidSpecification("workspace path"));
    }
    Ok(path.to_path_buf())
}

fn create_safe_parents(root: &Path, destination: &Path) -> Result<(), ExecutionError> {
    let parent = destination
        .parent()
        .filter(|parent| parent.starts_with(root))
        .ok_or(ExecutionError::InvalidSpecification("workspace path"))?;
    let mut current = root.to_path_buf();
    for component in parent
        .strip_prefix(root)
        .map_err(|_| ExecutionError::InvalidSpecification("workspace path"))?
        .components()
    {
        current.push(component);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
            Ok(_) => return Err(ExecutionError::InvalidSpecification("workspace symlink")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current).map_err(|_| ExecutionError::Unavailable {
                    phase: "native_workspace",
                })?;
            }
            Err(_) => {
                return Err(ExecutionError::Unavailable {
                    phase: "native_workspace",
                });
            }
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_step(
    specification: &ExecutionSpecification,
    workspace: &Path,
    position: usize,
    step: &ExecutionStep,
    sequence: &mut u64,
    deadline: Instant,
    control: &ExecutionControl<'_>,
) -> Result<ExecutionResult, ExecutionError> {
    if Instant::now() >= deadline {
        return Ok(ExecutionResult {
            status: ExecutionStatus::TimedOut,
            exit_code: None,
        });
    }
    let mut command = Command::new(&specification.shell);
    command
        .arg("-c")
        .arg(&step.value)
        .current_dir(workspace)
        .env_clear()
        .env("HOME", workspace)
        .env("TMPDIR", workspace.join(".tmp"))
        .env(
            "PATH",
            std::env::var_os("PATH").unwrap_or_else(|| "/usr/bin:/bin".into()),
        )
        .envs(&specification.env)
        .envs(&specification.build_env)
        .envs(
            specification
                .secrets
                .iter()
                .map(|(name, value)| (name, value.as_str())),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn().map_err(|_| ExecutionError::Unavailable {
        phase: "native_command",
    })?;
    let stdout = child.stdout.take().ok_or(ExecutionError::Unavailable {
        phase: "native_stdout",
    })?;
    let stderr = child.stderr.take().ok_or(ExecutionError::Unavailable {
        phase: "native_stderr",
    })?;
    let (sender, mut receiver) = mpsc::channel(32);
    let stdout_reader = tokio::spawn(read_stream(stdout, OutputChannel::Stdout, sender.clone()));
    let stderr_reader = tokio::spawn(read_stream(stderr, OutputChannel::Stderr, sender));
    let secrets = specification
        .secrets
        .values()
        .map(|value| value.as_bytes().to_vec())
        .collect::<Vec<_>>();
    let mut stdout_redactor = StreamingRedactor::new(&secrets);
    let mut stderr_redactor = StreamingRedactor::new(&secrets);
    let mut ticker = interval(Duration::from_millis(100));
    let status = loop {
        tokio::select! {
            chunk = receiver.recv() => {
                if let Some((channel, bytes)) = chunk {
                    let redacted = match channel {
                        OutputChannel::Stdout => stdout_redactor.push(&bytes, false),
                        OutputChannel::Stderr => stderr_redactor.push(&bytes, false),
                        OutputChannel::System => bytes,
                    };
                    append_chunk(control, sequence, position, step, channel, redacted).await?;
                }
            }
            _ = ticker.tick() => {
                if let Some(status) = child.try_wait().map_err(|_| ExecutionError::Runner { phase: "native_wait" })? {
                    break NativeExit::Status(status.code());
                }
                if control.cancellation.requested().await? {
                    terminate(&mut child).await;
                    break NativeExit::Cancelled;
                }
                if Instant::now() >= deadline {
                    terminate(&mut child).await;
                    break NativeExit::TimedOut;
                }
            }
        }
    };
    stdout_reader.await.map_err(|_| ExecutionError::Runner {
        phase: "native_stdout",
    })??;
    stderr_reader.await.map_err(|_| ExecutionError::Runner {
        phase: "native_stderr",
    })??;
    while let Some((channel, bytes)) = receiver.recv().await {
        let redacted = match channel {
            OutputChannel::Stdout => stdout_redactor.push(&bytes, false),
            OutputChannel::Stderr => stderr_redactor.push(&bytes, false),
            OutputChannel::System => bytes,
        };
        append_chunk(control, sequence, position, step, channel, redacted).await?;
    }
    append_chunk(
        control,
        sequence,
        position,
        step,
        OutputChannel::Stdout,
        stdout_redactor.push(&[], true),
    )
    .await?;
    append_chunk(
        control,
        sequence,
        position,
        step,
        OutputChannel::Stderr,
        stderr_redactor.push(&[], true),
    )
    .await?;
    Ok(match status {
        NativeExit::Status(Some(0)) => ExecutionResult {
            status: ExecutionStatus::Succeeded,
            exit_code: Some(0),
        },
        NativeExit::Status(code) => ExecutionResult {
            status: ExecutionStatus::Failed,
            exit_code: code,
        },
        NativeExit::Cancelled => ExecutionResult {
            status: ExecutionStatus::Cancelled,
            exit_code: None,
        },
        NativeExit::TimedOut => ExecutionResult {
            status: ExecutionStatus::TimedOut,
            exit_code: None,
        },
    })
}

enum NativeExit {
    Status(Option<i32>),
    Cancelled,
    TimedOut,
}

async fn read_stream(
    mut stream: impl tokio::io::AsyncRead + Unpin,
    channel: OutputChannel,
    sender: mpsc::Sender<(OutputChannel, Vec<u8>)>,
) -> Result<(), ExecutionError> {
    let mut buffer = vec![0; STREAM_CHUNK_BYTES];
    loop {
        let count = stream
            .read(&mut buffer)
            .await
            .map_err(|_| ExecutionError::Runner {
                phase: "native_output",
            })?;
        if count == 0 {
            break;
        }
        sender
            .send((channel, buffer[..count].to_vec()))
            .await
            .map_err(|_| ExecutionError::Output)?;
    }
    Ok(())
}

async fn append_chunk(
    control: &ExecutionControl<'_>,
    sequence: &mut u64,
    position: usize,
    step: &ExecutionStep,
    channel: OutputChannel,
    bytes: Vec<u8>,
) -> Result<(), ExecutionError> {
    if bytes.is_empty() {
        return Ok(());
    }
    *sequence = sequence.saturating_add(1);
    control
        .output
        .append(OutputChunk {
            sequence: *sequence,
            step: position,
            step_name: step.name.clone(),
            channel,
            bytes,
        })
        .await
}

async fn terminate(child: &mut Child) {
    #[cfg(unix)]
    if let Some(id) = child.id() {
        let _ = Command::new("/bin/kill")
            .args(["-TERM", &format!("-{id}")])
            .status()
            .await;
    }
    let _ = child.kill().await;
    let _ = child.wait().await;
}

async fn run_builtin(
    workspace: &Path,
    position: usize,
    step: &ExecutionStep,
    sequence: &mut u64,
    control: &ExecutionControl<'_>,
) -> Result<ExecutionResult, ExecutionError> {
    let handler = control
        .builtins
        .ok_or(ExecutionError::Unsupported("builtin handler"))?;
    let outcome = match step.value.as_str() {
        "checkout" => Ok("Source already materialized"),
        "cache/restore" | "artifacts/download" => match handler.restore(step).await? {
            BuiltinRestore::CacheMiss => Ok("Cache miss"),
            BuiltinRestore::Archive(bytes) => {
                restore_archive(workspace, step, &bytes)?;
                Ok("Restored archive")
            }
        },
        "cache/save" | "artifacts/upload" => {
            let archive = publish_archive(workspace, step)?;
            handler.publish(step, archive).await?;
            Ok("Published archive")
        }
        _ => Err(ExecutionError::Unsupported("builtin step")),
    };
    let (status, exit_code, message) = match outcome {
        Ok(message) => (ExecutionStatus::Succeeded, Some(0), message),
        Err(_) => (ExecutionStatus::Failed, Some(1), "Built-in step failed"),
    };
    append_chunk(
        control,
        sequence,
        position,
        step,
        OutputChannel::System,
        message.as_bytes().to_vec(),
    )
    .await?;
    Ok(ExecutionResult { status, exit_code })
}

fn restore_archive(
    workspace: &Path,
    step: &ExecutionStep,
    compressed: &[u8],
) -> Result<(), ExecutionError> {
    robine_source::validate_workspace_tar_gz(compressed, robine_source::ArchiveLimits::default())
        .map_err(|_| ExecutionError::Runner {
        phase: "native_archive_validation",
    })?;
    let relative = if step.value == "artifacts/download" {
        step.with
            .get("path")
            .and_then(serde_json::Value::as_str)
            .unwrap_or(".")
    } else {
        "."
    };
    let target = if relative == "." {
        workspace.to_path_buf()
    } else {
        workspace.join(safe_relative(Path::new(relative))?)
    };
    fs::create_dir_all(&target).map_err(|_| ExecutionError::Unavailable {
        phase: "native_archive_restore",
    })?;
    let decoder = GzDecoder::new(compressed);
    let mut archive = tar::Archive::new(decoder);
    for entry in archive.entries().map_err(|_| ExecutionError::Runner {
        phase: "native_archive_restore",
    })? {
        let mut entry = entry.map_err(|_| ExecutionError::Runner {
            phase: "native_archive_restore",
        })?;
        let kind = entry.header().entry_type();
        if !(kind.is_file() || kind.is_dir()) {
            return Err(ExecutionError::InvalidSpecification("archive entry"));
        }
        let path = entry
            .path()
            .map_err(|_| ExecutionError::InvalidSpecification("archive path"))?;
        let relative = safe_relative(&path)?;
        let destination = target.join(relative);
        create_safe_parents(&target, &destination)?;
        if kind.is_dir() {
            fs::create_dir_all(destination).map_err(|_| ExecutionError::Unavailable {
                phase: "native_archive_restore",
            })?;
        } else {
            if fs::symlink_metadata(&destination)
                .is_ok_and(|metadata| metadata.file_type().is_symlink())
            {
                return Err(ExecutionError::InvalidSpecification("workspace symlink"));
            }
            let mut output = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(destination)
                .map_err(|_| ExecutionError::Unavailable {
                    phase: "native_archive_restore",
                })?;
            std::io::copy(&mut entry, &mut output).map_err(|_| ExecutionError::Unavailable {
                phase: "native_archive_restore",
            })?;
        }
    }
    Ok(())
}

fn publish_archive(workspace: &Path, step: &ExecutionStep) -> Result<Vec<u8>, ExecutionError> {
    let paths = step
        .with
        .get("paths")
        .and_then(serde_json::Value::as_array)
        .ok_or(ExecutionError::InvalidSpecification("builtin paths"))?;
    let mut files = Vec::new();
    for path in paths {
        let relative = safe_relative(Path::new(
            path.as_str()
                .ok_or(ExecutionError::InvalidSpecification("builtin path"))?,
        ))?;
        collect_files(workspace, &relative, &mut files)?;
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    files.dedup_by(|left, right| left.path == right.path);
    let encoder = GzEncoder::new(Vec::new(), Compression::default());
    let mut archive = tar::Builder::new(encoder);
    for file in files {
        let mut header = tar::Header::new_gnu();
        header.set_size(u64::try_from(file.contents.len()).map_err(|_| {
            ExecutionError::Runner {
                phase: "native_archive_publish",
            }
        })?);
        header.set_mode(0o644);
        header.set_mtime(0);
        header.set_cksum();
        archive
            .append_data(&mut header, &file.path, file.contents.as_slice())
            .map_err(|_| ExecutionError::Runner {
                phase: "native_archive_publish",
            })?;
    }
    let encoder = archive.into_inner().map_err(|_| ExecutionError::Runner {
        phase: "native_archive_publish",
    })?;
    let bytes = encoder.finish().map_err(|_| ExecutionError::Runner {
        phase: "native_archive_publish",
    })?;
    robine_source::validate_workspace_tar_gz(&bytes, robine_source::ArchiveLimits::default())
        .map_err(|_| ExecutionError::Runner {
            phase: "native_archive_validation",
        })?;
    Ok(bytes)
}

fn collect_files(
    root: &Path,
    relative: &Path,
    output: &mut Vec<crate::SourceFile>,
) -> Result<(), ExecutionError> {
    let path = root.join(relative);
    let metadata = fs::symlink_metadata(&path)
        .map_err(|_| ExecutionError::InvalidSpecification("builtin path"))?;
    if metadata.file_type().is_symlink() {
        return Err(ExecutionError::InvalidSpecification("workspace symlink"));
    }
    if metadata.is_file() {
        output.push(crate::SourceFile {
            path: relative.to_path_buf(),
            contents: fs::read(path).map_err(|_| ExecutionError::Unavailable {
                phase: "native_archive_publish",
            })?,
        });
    } else if metadata.is_dir() {
        for entry in fs::read_dir(path).map_err(|_| ExecutionError::Unavailable {
            phase: "native_archive_publish",
        })? {
            let entry = entry.map_err(|_| ExecutionError::Unavailable {
                phase: "native_archive_publish",
            })?;
            collect_files(root, &relative.join(entry.file_name()), output)?;
        }
    } else {
        return Err(ExecutionError::InvalidSpecification("workspace entry"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{BuiltinHandler, CancellationSignal, OutputSink, ServiceSpecification};
    use std::{
        collections::BTreeMap,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, Ordering},
        },
    };
    use zeroize::Zeroizing;

    #[derive(Default)]
    struct Harness {
        chunks: Mutex<Vec<OutputChunk>>,
        cancelled: AtomicBool,
        archive: Mutex<Option<Vec<u8>>>,
    }

    #[async_trait]
    impl OutputSink for Harness {
        async fn append(&self, chunk: OutputChunk) -> Result<(), ExecutionError> {
            self.chunks.lock().unwrap().push(chunk);
            Ok(())
        }
    }

    #[async_trait]
    impl CancellationSignal for Harness {
        async fn requested(&self) -> Result<bool, ExecutionError> {
            Ok(self.cancelled.load(Ordering::SeqCst))
        }
    }

    #[async_trait]
    impl BuiltinHandler for Harness {
        async fn restore(&self, _step: &ExecutionStep) -> Result<BuiltinRestore, ExecutionError> {
            Ok(self
                .archive
                .lock()
                .unwrap()
                .clone()
                .map_or(BuiltinRestore::CacheMiss, BuiltinRestore::Archive))
        }

        async fn publish(
            &self,
            _step: &ExecutionStep,
            archive: Vec<u8>,
        ) -> Result<(), ExecutionError> {
            *self.archive.lock().unwrap() = Some(archive);
            Ok(())
        }
    }

    fn specification(steps: Vec<ExecutionStep>) -> ExecutionSpecification {
        ExecutionSpecification {
            attempt_id: uuid::Uuid::new_v4(),
            image: "native".into(),
            workspace: "/workspace".into(),
            shell: "/bin/sh".into(),
            timeout_ms: 5_000,
            env: BTreeMap::new(),
            build_env: BTreeMap::new(),
            secret_names: Vec::new(),
            secrets: BTreeMap::new(),
            source_files: Vec::new(),
            services: Vec::new(),
            steps,
        }
    }

    fn run_step(name: &str, value: &str, condition: StepCondition) -> ExecutionStep {
        ExecutionStep {
            name: name.into(),
            kind: StepKind::Run,
            value: value.into(),
            condition,
            with: BTreeMap::new(),
        }
    }

    #[tokio::test]
    async fn native_steps_share_workspace_redact_streams_and_preserve_failure_conditions() {
        let harness = Harness::default();
        let mut specification = specification(vec![
            run_step("prepare", "printf shared > state", StepCondition::Success),
            run_step(
                "fail",
                "printf token-123 >&2; exit 7",
                StepCondition::Success,
            ),
            run_step("skipped", "printf wrong", StepCondition::Success),
            run_step(
                "recover",
                "cat state; printf token-123",
                StepCondition::Failure,
            ),
            run_step("always", "printf always", StepCondition::Always),
        ]);
        specification
            .secrets
            .insert("TOKEN".into(), Zeroizing::new("token-123".into()));
        let result = NativeProcessRunner
            .run(
                &specification,
                ExecutionControl {
                    output: &harness,
                    cancellation: &harness,
                    builtins: None,
                    last_sequence: 0,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.status, ExecutionStatus::Failed);
        assert_eq!(result.exit_code, Some(7));
        let output = harness
            .chunks
            .lock()
            .unwrap()
            .iter()
            .flat_map(|chunk| chunk.bytes.clone())
            .collect::<Vec<_>>();
        let output = String::from_utf8(output).unwrap();
        assert!(output.contains("shared"));
        assert!(output.contains("always"));
        assert!(output.contains("[REDACTED]"));
        assert!(!output.contains("token-123"));
        assert!(!output.contains("wrong"));
    }

    #[tokio::test]
    async fn native_timeout_cancellation_services_and_cleanup_fail_closed() {
        let before = native_workspaces();
        let harness = Arc::new(Harness::default());
        let mut timed = specification(vec![run_step("slow", "sleep 2", StepCondition::Success)]);
        timed.timeout_ms = 100;
        let result = NativeProcessRunner
            .run(
                &timed,
                ExecutionControl {
                    output: harness.as_ref(),
                    cancellation: harness.as_ref(),
                    builtins: None,
                    last_sequence: 0,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.status, ExecutionStatus::TimedOut);
        harness.cancelled.store(true, Ordering::SeqCst);
        let cancelled = specification(vec![run_step("slow", "sleep 2", StepCondition::Success)]);
        let result = NativeProcessRunner
            .run(
                &cancelled,
                ExecutionControl {
                    output: harness.as_ref(),
                    cancellation: harness.as_ref(),
                    builtins: None,
                    last_sequence: 0,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.status, ExecutionStatus::Cancelled);
        let mut services = specification(vec![run_step("test", "true", StepCondition::Success)]);
        services.services.push(ServiceSpecification {
            id: "redis".into(),
            image: "redis".into(),
            user: None,
            env: BTreeMap::new(),
            secret_references: BTreeMap::new(),
            secrets: BTreeMap::new(),
            command: Vec::new(),
            readiness: None,
            privileged: false,
        });
        assert!(matches!(
            NativeProcessRunner
                .run(
                    &services,
                    ExecutionControl {
                        output: harness.as_ref(),
                        cancellation: harness.as_ref(),
                        builtins: None,
                        last_sequence: 0
                    }
                )
                .await,
            Err(ExecutionError::Unsupported("native service containers"))
        ));
        assert_eq!(native_workspaces(), before);
    }

    #[tokio::test]
    async fn native_builtins_publish_and_restore_attempt_scoped_archives() {
        let harness = Harness::default();
        let mut upload = ExecutionStep {
            name: "upload".into(),
            kind: StepKind::Builtin,
            value: "artifacts/upload".into(),
            condition: StepCondition::Success,
            with: BTreeMap::new(),
        };
        upload
            .with
            .insert("paths".into(), serde_json::json!(["result.txt"]));
        let first = specification(vec![
            run_step(
                "create",
                "printf artifact > result.txt",
                StepCondition::Success,
            ),
            upload,
        ]);
        let result = NativeProcessRunner
            .run(
                &first,
                ExecutionControl {
                    output: &harness,
                    cancellation: &harness,
                    builtins: Some(&harness),
                    last_sequence: 0,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.status, ExecutionStatus::Succeeded);
        assert!(harness.archive.lock().unwrap().is_some());
        let mut download = ExecutionStep {
            name: "download".into(),
            kind: StepKind::Builtin,
            value: "artifacts/download".into(),
            condition: StepCondition::Success,
            with: BTreeMap::new(),
        };
        download
            .with
            .insert("path".into(), serde_json::json!("restored"));
        let second = specification(vec![
            download,
            run_step("read", "cat restored/result.txt", StepCondition::Success),
        ]);
        let result = NativeProcessRunner
            .run(
                &second,
                ExecutionControl {
                    output: &harness,
                    cancellation: &harness,
                    builtins: Some(&harness),
                    last_sequence: 100,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.status, ExecutionStatus::Succeeded);
        assert!(
            harness
                .chunks
                .lock()
                .unwrap()
                .iter()
                .any(|chunk| chunk.bytes == b"artifact")
        );
    }

    fn native_workspaces() -> BTreeSet<PathBuf> {
        fs::read_dir(std::env::temp_dir())
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("robine-native-"))
            })
            .collect()
    }
}
