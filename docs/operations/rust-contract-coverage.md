# Rust contract coverage index

This index is the executable witness for PLAT-004's cross-specification coverage gate. Each accepted, implementing, or shipped contract names a focused Rust unit-test source and a boundary or persistence integration-test source. The `robine-package` test suite fails when a governed specification is absent, a referenced source disappears, or a referenced source contains no Rust test.

The index proves traceability and prevents silent coverage loss. Behavioral assertions remain authoritative in the named test sources. GitLab and Forgejo outbound status projection is excluded by the explicit PLAT-004 cutover amendment; provider-neutral ingestion and exact-SHA behavior remain covered under SCM-001.

| Contract | Unit-test source | Integration-test source |
|---|---|---|
| CLI-001 | rust/crates/robine-cli/src/main.rs | rust/crates/robine-server/src/lib.rs |
| DATA-001 | rust/crates/robine-storage/src/lib.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| DATA-002 | rust/crates/robine-storage/src/lib.rs | rust/crates/robine-storage/tests/s3_integration.rs |
| EXEC-001 | rust/crates/robine-execution/src/lib.rs | rust/crates/robine-application/src/lib.rs |
| EXEC-002 | rust/crates/robine-execution/src/docker.rs | rust/crates/robine-application/src/lib.rs |
| GH-001 | rust/crates/robine-source/src/lib.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| IAM-001 | rust/crates/robine-oidc/src/lib.rs | rust/crates/robine-server/src/lib.rs |
| OPS-001 | rust/crates/robine-application/src/lib.rs | rust/crates/robine-server/src/lib.rs |
| PLAT-001 | rust/crates/robine-core/src/execution_context.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| PLAT-002 | rust/crates/robine-core/src/execution_context.rs | rust/crates/robine-application/src/lib.rs |
| PLAT-003 | rust/crates/robine-application/src/lib.rs | rust/crates/robine-server/src/lib.rs |
| PLAT-004 | rust/crates/robine-core/src/pipelines.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| PROD-001 | rust/crates/robine-workflows/src/lib.rs | rust/crates/robine-server/src/lib.rs |
| QUAL-001 | rust/crates/robine-persistence/src/lib.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| REL-002 | rust/crates/robine-package/src/main.rs | rust/crates/robine-server/src/lib.rs |
| RUN-001 | rust/crates/robine-core/src/pipelines.rs | rust/crates/robine-server/src/lib.rs |
| RUN-002 | rust/crates/robine-core/src/pipelines.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| RUN-003 | rust/crates/robine-runner/src/main.rs | rust/crates/robine-application/src/lib.rs |
| SCM-001 | rust/crates/robine-source/src/lib.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| SEC-001 | rust/crates/robine-secrets/src/lib.rs | rust/crates/robine-application/src/lib.rs |
| WEB-001 | rust/crates/robine-server/src/lib.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| WF-001 | rust/crates/robine-workflows/src/lib.rs | rust/crates/robine-workflows/tests/fixture_corpus.rs |
| WF-002 | rust/crates/robine-workflows/src/lib.rs | rust/crates/robine-application/src/lib.rs |
| WF-003 | rust/crates/robine-workflows/src/lib.rs | rust/crates/robine-workflows/tests/fixture_corpus.rs |
| WF-004 | rust/crates/robine-workflows/src/lib.rs | rust/crates/robine-server/src/lib.rs |
| WF-005 | rust/crates/robine-workflows/tests/cron.rs | rust/crates/robine-persistence/tests/existing_schema.rs |
| WF-006 | rust/crates/robine-workflows/tests/composition.rs | rust/crates/robine-application/src/lib.rs |
