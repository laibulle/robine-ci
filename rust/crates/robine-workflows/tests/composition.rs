use robine_workflows::{WorkflowLimits, resolve};
use std::{collections::BTreeMap, fmt::Write as _};

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
    let source = r"
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
";
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

#[test]
fn artifact_downloads_require_unambiguous_declared_dependencies() {
    let invalid = r"
version: 1
name: Artifacts
on: {push: {}}
jobs:
  build:
    strategy:
      matrix:
        version: [one, two]
    image: alpine:3.22
    steps:
      - uses: artifacts/upload
        with: {name: report, paths: [report]}
  consume:
    image: alpine:3.22
    needs: build
    steps:
      - uses: artifacts/download
        with: {name: report, from: build}
";
    let diagnostics = robine_workflows::parse(
        invalid,
        ".robine-ci/workflows/artifacts.yml",
        &WorkflowLimits::default(),
    )
    .expect_err("ambiguous matrix artifact");
    assert_eq!(diagnostics[0].code, "matrix.artifact_ambiguous");

    let undeclared = invalid
        .replace("needs: build", "needs: []")
        .replace("version: [one, two]", "version: [one]");
    let diagnostics = robine_workflows::parse(
        &undeclared,
        ".robine-ci/workflows/artifacts.yml",
        &WorkflowLimits::default(),
    )
    .expect_err("artifact source must be a dependency");
    assert_eq!(diagnostics[0].code, "step.artifact_dependency");
}

#[test]
fn composition_rejects_excessive_depth_and_external_dependencies() {
    let paths = (1..=5)
        .map(|index| format!(".robine-ci/workflows/depth-{index}.yml"))
        .collect::<Vec<_>>();
    let mut sources = BTreeMap::new();
    sources.insert(
        ENTRY.into(),
        reusable_entry("next", paths.first().expect("first path")),
    );
    for (index, path) in paths.iter().enumerate() {
        let includes = paths
            .get(index + 1)
            .map_or_else(String::new, |next| include_yaml("next", next));
        sources.insert(path.clone(), reusable_source(&includes, "test", None));
    }
    assert_error(&sources, "include.depth", &paths[3]);

    let mut external = valid_sources();
    external.insert(
        QUALITY.into(),
        external[QUALITY].replace("needs: security--scan", "needs: package"),
    );
    assert_error(&external, "job.need_unknown", QUALITY);
}

#[test]
fn composition_enforces_transitive_count_and_generated_identifier_bounds() {
    let children = (1..=8)
        .map(|index| format!(".robine-ci/workflows/child-{index}.yml"))
        .collect::<Vec<_>>();
    let mut sources = BTreeMap::new();
    let mut entry_includes = String::new();
    for (index, path) in children.iter().enumerate() {
        let _ = writeln!(entry_includes, "  c{}:\n    path: {path}", index + 1);
    }
    sources.insert(
        ENTRY.into(),
        format!(
            "version: 1\nname: Entry\non: {{push: {{}}}}\nincludes:\n{entry_includes}jobs: {{}}\n"
        ),
    );
    for (index, child) in children.iter().enumerate() {
        let first = format!(".robine-ci/workflows/leaf-{index}-a.yml");
        let second = format!(".robine-ci/workflows/leaf-{index}-b.yml");
        let includes = format!("includes:\n  a:\n    path: {first}\n  b:\n    path: {second}\n");
        sources.insert(child.clone(), reusable_source(&includes, "test", None));
        sources.insert(first, reusable_source("", "test", None));
        sources.insert(second, reusable_source("", "test", None));
    }
    let diagnostics = resolve(ENTRY, &sources, &WorkflowLimits::default())
        .expect_err("more than 16 include edges");
    assert!(
        diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "include.count")
    );

    let alias = "a1234567890123456789";
    let long_job = "j1234567890123456789012345678901234567890123456789";
    let reusable = ".robine-ci/workflows/long.yml";
    let overflow = BTreeMap::from([
        (ENTRY.into(), reusable_entry(alias, reusable)),
        (reusable.into(), reusable_source("", long_job, None)),
    ]);
    assert_error(&overflow, "include.job_id", reusable);
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
            r"version: 1
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
"
            .into(),
        ),
    ])
}

fn reusable_entry(alias: &str, path: &str) -> String {
    format!(
        "version: 1\nname: Entry\non: {{push: {{}}}}\n{}jobs: {{}}\n",
        include_yaml(alias, path)
    )
}

fn include_yaml(alias: &str, path: &str) -> String {
    format!("includes:\n  {alias}:\n    path: {path}\n")
}

fn reusable_source(includes: &str, job: &str, needs: Option<&str>) -> String {
    let needs = needs.map_or_else(String::new, |needs| format!("    needs: {needs}\n"));
    format!(
        "version: 1\nname: Reusable\non: {{workflow_call: {{}}}}\n{includes}jobs:\n  {job}:\n    image: alpine:3.22\n{needs}    steps: [{{run: echo ok}}]\n"
    )
}
