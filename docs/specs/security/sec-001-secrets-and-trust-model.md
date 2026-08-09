# SEC-001 — Secrets and trust model

## Status

- **State:** Accepted
- **Owner:** Security
- **Target:** MVP
- **Last updated:** 2026-08-09

## Summary

The MVP executes only trusted repository code. Repository and instance secrets are encrypted at rest, scoped explicitly, injected only into eligible jobs, and redacted from logs as defense in depth rather than as a guarantee against deliberate exfiltration.

## Problem

CI necessarily executes repository-controlled commands that may access credentials. Users need understandable boundaries and safe defaults without being misled into believing Docker or log masking can protect a secret from intentionally malicious trusted code.

## Goals

- State the trust model honestly and enforce it consistently.
- Encrypt stored secrets and minimize plaintext lifetime.
- Prevent secret delivery to ineligible triggers, especially forks.
- Mask accidental appearances in logs and UI.

## Non-goals

- Safe execution of adversarial repository code.
- Preventing a trusted job from intentionally transmitting a secret it receives.
- External Vault integrations or secret approval workflows.
- Secret access from public fork pull requests.

## Users and use cases

### Primary user

A maintainer storing credentials required by a trusted build or test job and an operator managing the encryption key.

### Use cases

1. Create, replace, or delete a secret without reading it back.
2. Reference a secret explicitly from a workflow job.
3. Prevent secret injection when trigger policy is not eligible.
4. Rotate the instance encryption key safely.

## Requirements

### Functional requirements

- **FR-1:** Secrets MUST be encrypted with an authenticated encryption algorithm before database persistence.
- **FR-2:** The master key MUST be supplied outside the database, MUST NOT have an insecure built-in default, and MUST be validated at startup.
- **FR-3:** Secret values MUST be write-only in the UI and API after creation.
- **FR-4:** Workflows MUST reference secrets explicitly by name; secrets MUST NOT be injected globally by default.
- **FR-5:** Secret names MUST be unique within their scope and values MUST support safe replacement without changing workflow references.
- **FR-6:** The MVP MUST support repository-scoped and instance-scoped secrets, with instance-secret access explicitly granted to repositories.
- **FR-7:** Fork pull requests MUST NOT receive secrets. Because the MVP trusts repositories, fork execution MUST be disabled by default.
- **FR-8:** Exact secret values and recognized encoded variants within documented bounds MUST be masked from streamed and persisted logs.
- **FR-9:** Values shorter than a safe masking threshold MUST be rejected as secrets or masked using a documented alternative to avoid corrupting logs.
- **FR-10:** Cancellation, retry, and local reproduction MUST NOT expose or print secret plaintext.
- **FR-11:** Key rotation MUST re-encrypt secrets through an auditable, resumable operation.

### UX requirements

- **UX-1:** The creation form MUST explain that secrets cannot be displayed again.
- **UX-2:** Workflow and policy screens MUST show which secret names a job may receive, never their values.
- **UX-3:** The product MUST warn that masking does not prevent deliberate exfiltration by executed code.

### Operational requirements

- **OR-1:** Plaintext secret values MUST not appear in application logs, exception reports, telemetry, or persisted execution specifications.
- **OR-2:** Secret decryption MUST occur as late as practical before dispatch and plaintext references MUST be released promptly after use.
- **OR-3:** Backup and disaster-recovery documentation MUST cover the external master key; a database backup alone is intentionally insufficient.

## Proposed design

Encrypted records contain ciphertext, a unique 96-bit nonce, a 128-bit authentication tag, key version, scope, name, and metadata. The MVP uses versioned direct AES-256-GCM with metadata-bound authenticated additional data. Administrators configure old and current keys outside PostgreSQL, then re-encrypt bounded cursor-based batches. Each successful record update and audit entry is atomic; interruption leaves both old and newly rotated records readable and the returned cursor resumes progress.

The workflow syntax maps a secret to an environment variable explicitly. Eligibility is evaluated before an execution specification is built. The runner receives only the selected values for that attempt. A streaming redactor operates across chunk boundaries before log persistence and broadcast.

Secret values MUST be binary values from 8 bytes through 65,536 bytes inclusive. Larger values are rejected before encryption so memory use and redaction cost remain bounded. The redactor masks the exact literal value, standard Base64 with and without padding, URL-safe Base64 with and without padding, and uppercase byte-wise percent encoding. It does not attempt semantic decoding, Unicode normalization, substring heuristics, or arbitrary transformations.

Complete matches are replaced before the redactor buffers a possible partial suffix. This ordering is required for self-overlapping values such as repeated characters. Patterns are inspected from longest to shortest so padded and unpadded encodings cannot produce partial replacement. Execution specifications omit secret fields from debug inspection, redactor state omits patterns and buffered fragments, and runner-generated exception or built-in diagnostic text passes through the same exact-value policy. Telemetry carries only counts, outcomes, and key version numbers.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Master key missing/wrong | Service refuses secret-dependent operation and reports unhealthy configuration | Restore correct key |
| Secret reference missing | Job does not start; named reference is reported | Create/grant the secret or edit workflow |
| Rotation interrupted | Old key remains usable; progress is recorded | Resume rotation |
| Masking detects a value | Output contains `[REDACTED]` | No recovery needed; review job if unexpected |

## Security and privacy

Docker is not a security boundary for hostile jobs, and masking is not data-loss prevention. The UI and documentation MUST repeat this limitation at secret creation and fork-policy configuration. Secret metadata and audit events are themselves sensitive and follow repository authorization.

## Observability

Audit events record secret creation, replacement, deletion, grants, and key rotation without values. Metrics cover decryption failures, missing references, redaction matches, and rotation progress without secret-dependent labels.

## Acceptance criteria

- [x] Database inspection and database-only backups reveal no secret plaintext.
- [ ] Secrets cannot be retrieved through UI or API after creation.
- [x] A secret split across log chunks is redacted before persistence and broadcast.
- [ ] Fork-triggered work receives no secrets under every event ordering tested.
- [x] Interrupted key rotation resumes without losing access to any secret.
- [x] Application logs, diagnostic output, telemetry payloads, and debug inspection contain no fixture secret values.

## Open questions

None blocking for the MVP.

The AES-256-GCM construction and versioned direct-key lifecycle are accepted in [the focused encryption review](../../security/encryption-review.md). Instance-scoped secrets are included with explicit per-repository grants and administrator-only writes.

## Out of scope / future work

- Vault/KMS integrations, approval gates, secretless OIDC federation, and untrusted-code isolation.
