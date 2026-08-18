use robine_workflows::{WorkflowLimits, parse, valid_workflow_path};
use serde::Deserialize;
use std::{collections::BTreeMap, fs, path::PathBuf};

#[derive(Deserialize)]
struct Expectation {
    valid: bool,
    #[serde(default)]
    codes: Vec<String>,
}

#[test]
fn canonical_workflow_paths_are_direct_yaml_children() {
    assert!(valid_workflow_path(".robine-ci/workflows/ci.yml"));
    assert!(valid_workflow_path(".robine-ci/workflows/release.yaml"));
    assert!(!valid_workflow_path("workflows/ci.yml"));
    assert!(!valid_workflow_path(".robine-ci/workflows/nested/ci.yml"));
    assert!(!valid_workflow_path(".robine-ci/workflows/ci.json"));
}

fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../test/fixtures/workflows")
}

#[test]
fn shared_fixture_manifest_has_exact_validation_parity() {
    let root = corpus_root();
    let manifest = fs::read_to_string(root.join("manifest.json")).expect("fixture manifest");
    let expectations: BTreeMap<String, Expectation> =
        serde_json::from_str(&manifest).expect("valid fixture manifest");

    for (relative_path, expectation) in expectations {
        let source = fs::read_to_string(root.join(&relative_path)).expect("workflow fixture");
        let result = parse(&source, &relative_path, &WorkflowLimits::default());

        if expectation.valid {
            assert!(result.is_ok(), "{relative_path}: {result:?}");
        } else {
            let diagnostics = result.expect_err(&relative_path);
            let codes = diagnostics
                .iter()
                .map(|diagnostic| diagnostic.code.clone())
                .collect::<Vec<_>>();
            assert_eq!(codes, expectation.codes, "{relative_path}");
            assert!(diagnostics.iter().all(|diagnostic| {
                diagnostic.source_path == relative_path
                    && diagnostic.line > 0
                    && diagnostic.column > 0
            }));
        }
    }
}

#[test]
fn matrix_jobs_expand_and_dependencies_follow_every_variant() {
    let relative_path = "valid/matrix.yml";
    let source = fs::read_to_string(corpus_root().join(relative_path)).expect("matrix fixture");
    let workflow = parse(&source, relative_path, &WorkflowLimits::default()).expect("valid matrix");

    assert_eq!(
        workflow.order,
        ["test[version=3.21]", "test[version=3.22]", "summarize"]
    );
    assert_eq!(
        workflow.jobs["summarize"].needs,
        ["test[version=3.21]", "test[version=3.22]"]
    );
    assert_eq!(
        workflow.jobs["test[version=3.21]"].execution["image"],
        "alpine:3.21"
    );
    assert_eq!(
        workflow.jobs["test[version=3.22]"].execution["env"]["ROBINE_MATRIX_VERSION"],
        "3.22"
    );
}
