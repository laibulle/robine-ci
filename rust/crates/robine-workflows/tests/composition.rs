use robine_workflows::{WorkflowLimits, resolve};
use std::collections::BTreeMap;

const ENTRY: &str = ".robine-ci/workflows/ci.yml";
const QUALITY: &str = ".robine-ci/workflows/quality.yml";
const SECURITY: &str = ".robine-ci/workflows/security.yml";

#[test]
fn nested_includes_namespace_jobs_and_isolate_typed_inputs() {
    let resolved =
        resolve(ENTRY, &valid_sources(), &WorkflowLimits::default()).expect("valid graph");

    assert_eq!(
        resolved.workflow.order,
        ["quality--security--scan", "quality--test", "package"]
    );
    let scan = &resolved.workflow.jobs["quality--security--scan"];
    let test = &resolved.workflow.jobs["quality--test"];
    let package = &resolved.workflow.jobs["package"];
    assert_eq!(scan.execution["env"]["ROBINE_CALL_INPUT_STRICT"], "true");
    assert!(
        scan.execution["env"]
            .get("ROBINE_CALL_INPUT_RUNTIME")
            .is_none()
    );
    assert_eq!(test.execution["env"]["ROBINE_CALL_INPUT_RUNTIME"], "3.22");
    assert!(
        test.execution["env"]
            .get("ROBINE_CALL_INPUT_STRICT")
            .is_none()
    );
    assert_eq!(test.needs, ["quality--security--scan"]);
    assert_eq!(package.needs, ["quality--test"]);
    assert_eq!(
        resolved
            .included_sources
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        [QUALITY, SECURITY]
    );
}

#[test]
fn composition_errors_are_stable_and_owned_by_the_correct_source() {
    let mut collision = valid_sources();
    collision.insert(
        QUALITY.into(),
        collision[QUALITY].replace("EXISTING: safe", "ROBINE_CALL_INPUT_RUNTIME: forged"),
    );
    assert_error(&collision, "call_input.env_collision", QUALITY);

    let mut missing = valid_sources();
    missing.remove(SECURITY);
    assert_error(&missing, "include.missing", QUALITY);

    let mut undeclared = valid_sources();
    undeclared.insert(
        ENTRY.into(),
        undeclared[ENTRY].replace(
            "runtime: \"3.22\"",
            "runtime: \"3.22\"\n      forged: value",
        ),
    );
    assert_error(&undeclared, "call_input.undeclared", QUALITY);

    let mut cycle = valid_sources();
    cycle.insert(
        SECURITY.into(),
        cycle[SECURITY].replace(
            "jobs:",
            &format!("includes:\n  root:\n    path: {QUALITY}\njobs:"),
        ),
    );
    assert_error(&cycle, "include.cycle", SECURITY);
}

#[test]
fn manual_input_policy_applies_defaults_required_choices_and_booleans() {
    let source = r#"
version: 1
name: Release
on:
  workflow_dispatch:
    inputs:
      target:
        type: choice
        required: true
        options: [staging, production]
      dry_run:
        type: boolean
        default: true
      note:
        type: string
jobs:
  release:
    image: alpine:3.22
    steps: [{run: echo release}]
"#;
    let workflow = robine_workflows::parse(
        source,
        ".robine-ci/workflows/release.yml",
        &WorkflowLimits::default(),
    )
    .expect("valid manual workflow");
    let inputs = BTreeMap::from([("target".into(), "production".into())]);
    let jobs = workflow
        .pipeline_jobs("manual", &inputs)
        .expect("normalized inputs");
    let env = &jobs["release"].execution["env"];
    assert_eq!(env["ROBINE_INPUT_TARGET"], "production");
    assert_eq!(env["ROBINE_INPUT_DRY_RUN"], "true");
    assert_eq!(env["ROBINE_INPUT_NOTE"], "");

    assert!(workflow.pipeline_jobs("manual", &BTreeMap::new()).is_err());
    assert!(
        workflow
            .pipeline_jobs(
                "manual",
                &BTreeMap::from([("target".into(), "invalid".into())])
            )
            .is_err()
    );
}

fn assert_error(sources: &BTreeMap<String, String>, code: &str, source_path: &str) {
    let diagnostics = resolve(ENTRY, sources, &WorkflowLimits::default()).expect_err(code);
    assert!(
        diagnostics.iter().any(|diagnostic| {
            diagnostic.code == code
                && diagnostic.source_path == source_path
                && diagnostic.line > 0
                && diagnostic.column > 0
        }),
        "{diagnostics:#?}"
    );
}

fn valid_sources() -> BTreeMap<String, String> {
    BTreeMap::from([
        (
            ENTRY.into(),
            format!(
                r#"version: 1
name: CI
on: {{push: {{branches: [main]}}}}
includes:
  quality:
    path: {QUALITY}
    inputs:
      runtime: "3.22"
jobs:
  package:
    image: alpine:3.22
    needs: quality--test
    steps:
      - run: echo package
"#
            ),
        ),
        (
            QUALITY.into(),
            format!(
                r#"version: 1
name: Quality
on:
  workflow_call:
    inputs:
      runtime:
        type: choice
        required: true
        options: ["3.21", "3.22"]
includes:
  security:
    path: {SECURITY}
    inputs:
      strict: true
jobs:
  test:
    image: alpine:3.22
    needs: security--scan
    env:
      EXISTING: safe
    steps:
      - run: echo test
"#
            ),
        ),
        (
            SECURITY.into(),
            r#"version: 1
name: Security
on:
  workflow_call:
    inputs:
      strict:
        type: boolean
        required: true
jobs:
  scan:
    image: alpine:3.22
    steps:
      - run: echo scan
"#
            .into(),
        ),
    ])
}
