# WF-006 — Reusable workflows

## Status

- **State:** Shipped
- **Owner:** Workflows
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

A workflow can include bounded reusable workflow files from the same trusted repository and exact Git revision. Included jobs are statically namespaced, validated, composed before pipeline creation, and optionally receive small typed non-secret call inputs through reserved environment variables.

## Problem

Repositories with several delivery, language, or maintenance workflows otherwise duplicate the same test and policy jobs. Copy-paste drifts, while remote marketplace actions or mutable cross-repository references weaken reviewability, provenance, and local reproduction.

## Goals

- Reuse reviewed workflow jobs across entry workflows without provider-specific APIs.
- Resolve every file from one exact repository SHA before persistence or execution.
- Keep the final graph deterministic, bounded, source-located, and locally reproducible.
- Pass explicitly declared non-secret values without adding an expression language.

## Non-goals

- Cross-repository, URL, branch, tag, marketplace, or mutable references.
- Dynamic includes, conditional includes, output expressions, job templates, inheritance, YAML anchors as an API, or runtime graph mutation.
- Secret call inputs, automatic secret forwarding, provider compatibility, or arbitrary environment injection.

## Users and use cases

### Primary user

A developer maintaining several workflows in one trusted repository and extracting a stable shared job graph.

### Use cases

1. Share lint and test jobs between push, manual, and scheduled entry workflows.
2. Parameterize a reusable job with a declared runtime channel or deployment mode.
3. Depend on a namespaced included job from an entry workflow.
4. Reproduce the exact composed graph with the local CLI.

## Requirements

### Functional requirements

- **FR-1:** Workflow v1 MAY declare root `includes` as a map of one to eight include aliases. An entry without includes retains existing behavior.
- **FR-2:** Include aliases MUST match `^[a-z][a-z0-9-]{0,19}$`. Each definition accepts only `path` and optional `inputs`.
- **FR-3:** Paths MUST be canonical repository-relative `.robine-ci/workflows/*.yml` paths of at most 256 bytes, without backslashes, empty segments, `.` or `..`, and MUST resolve within the same exact source set as the entry workflow.
- **FR-4:** An included file MUST declare `on.workflow_call`; this trigger MAY declare zero to 16 `inputs` using the same bounded string, choice, boolean, required, default, description, and option rules as WF-004.
- **FR-5:** Include `inputs` MUST be a string-keyed map matching that declaration. Missing/default/required/choice/boolean behavior MUST use the same pure normalization policy as manual inputs.
- **FR-6:** Direct jobs from an included workflow receive `ROBINE_CALL_INPUT_<UPPER_ID>`. An explicit environment collision MUST invalidate composition. Values are non-secret and single-line bounded strings.
- **FR-7:** Included job IDs and their internal `needs` references MUST be prefixed deterministically as `<alias>--<job>`. Nested aliases compose left to right. Every generated ID MUST remain within 63 bytes and be unique in the final graph.
- **FR-8:** Entry jobs MAY depend on a generated included ID. Included jobs MUST NOT depend on jobs outside their own reusable subtree.
- **FR-9:** Resolution MUST reject missing files, duplicate paths in one parent, cycles, depth over four, more than 16 transitive includes, and a composed graph exceeding ordinary workflow job/step/depth limits.
- **FR-10:** All included files MUST come from the same exact commit SHA as the entry. The immutable workflow revision MUST retain the entry source plus every included path, source, and digest.
- **FR-11:** Push, pull request, manual, schedule, CLI, local Docker, remote runners, matrices, conditions, services, secrets, caches, and artifacts MUST consume the same final normalized graph.
- **FR-12:** A reusable-only file MUST not independently create a pipeline unless it also declares another matching entry trigger.

### UX requirements

- **UX-1:** Validation diagnostics MUST identify the owning file, source path, line, and column where parser information permits.
- **UX-2:** Workflow revision detail MUST list every included path and digest and distinguish the entry file.
- **UX-3:** Pipeline and job names MUST use the stable generated namespace consistently in the Actix browser, logs, checks, retry, and CLI selection.
- **UX-4:** Local validation and execution MUST discover repository-local workflow sources automatically and fail clearly when invoked outside the source tree required by an include.

### Operational requirements

- **OR-1:** Resolution and composition MUST be pure, deterministic, bounded, and free of filesystem, GitHub, SQLx, Actix, Docker, or worker-runtime dependencies.
- **OR-2:** GitHub delivery, manual launch, and schedule reconciliation MUST fetch the exact workflow source set once per repository/SHA operation and perform no follow-up mutable-ref reads.
- **OR-3:** No pipeline, revision, job, outbox, or audit row may be created when any included source or composed invariant fails.
- **OR-4:** Metrics MUST report bounded include depth, file count, composed job count, duration, and outcome without paths, aliases, input names, values, repository data, or source.

## Proposed design

Entry workflow:

```yaml
version: 1
name: CI
on: {push: {branches: [main]}}
includes:
  quality:
    path: .robine-ci/workflows/quality.yml
    inputs:
      runtime: "3.22"
jobs:
  package:
    image: alpine:3.22
    needs: quality--test
    steps:
      - run: echo package
```

Reusable workflow:

```yaml
version: 1
name: Shared quality
on:
  workflow_call:
    inputs:
      runtime:
        type: choice
        required: true
        options: ["3.21", "3.22"]
jobs:
  test:
    image: alpine:3.22
    steps:
      - run: echo "$ROBINE_CALL_INPUT_RUNTIME"
```

A multi-source resolution use case decodes the exact source map, validates include declarations, recursively resolves reusable files, normalizes edge inputs, prefixes raw job IDs and internal dependencies, and produces one composed raw workflow. The existing validator then owns all ordinary job, matrix, condition, service, secret, artifact, cache, step, graph, and limit rules. Persistence stores the entry source and an immutable included-source map.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Included path missing at exact SHA | Entry is invalid; no pipeline | Add the file in a new commit |
| Include cycle or excessive depth | Source-located bounded error | Break or flatten the include chain |
| Required/choice/boolean call input invalid | Composition fails before graph creation | Correct the include input |
| Generated job ID collision/overflow | Composition fails deterministically | Rename alias or jobs |
| Included file changes | New event/launch resolves the new exact SHA | Existing pipelines keep old source set |
| Local source set incomplete | CLI refuses validation/execution | Restore files or run from repository root |

## Security and privacy

Includes never cross the trusted repository or exact SHA. Call inputs are retained non-secrets and cannot select paths, images, commands, cache keys, artifacts, conditions, labels, or secrets. Included jobs request secrets only through the existing explicit job secret declarations; no caller secret forwarding syntax exists.

## Observability

Emit bounded resolution duration/outcome, included-file count, maximum depth, and composed-job count. Audit entry path, included path digests, SHA, actor, and pipeline without source, input values, repository names, or credentials.

## Acceptance criteria

- [x] Static and nested includes produce one deterministic namespaced graph across server and CLI.
- [x] Typed call inputs normalize identically to manual inputs and reach only the intended direct reusable jobs.
- [x] Missing paths, cycles, depth/count/ID limits, undeclared inputs, collisions, and external dependencies create no pipeline.
- [x] Push, manual, schedule, local Docker, and remote-runner paths execute identical composed contracts.
- [x] Immutable revision UI retains and displays every included source digest.
- [x] Checks, retry, architecture, security scans, release smoke, and full QA remain green (335 tests).

## Open questions

None blocking. Same-repository exact-revision includes and environment-only call inputs are deliberate first-contract limits.

## Out of scope / future work

- Outputs, secret interfaces, cross-repository libraries, version constraints, remote registries, templates, and dynamic graph generation.
