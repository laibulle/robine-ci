# DATA-003 — Manual artifact uploads

## Status

- **State:** Shipped
- **Owner:** Storage
- **Target:** Post-MVP
- **Last updated:** 2026-08-28

## Summary

Robine lets maintainers upload a locally produced immutable binary, such as a signed and notarized macOS DMG, directly to a trusted repository through the authenticated UI or HTTP API without creating a synthetic CI attempt.

## Problem

Some release outputs must be built, signed, or notarized on operator-controlled hardware outside Robine. Robine currently accepts artifact uploads only from an authenticated runner attempt, which forces operators to create an upload-only pipeline that performs no build and misrepresents the artifact's provenance.

## Goals

- Upload an already-produced file through the repository UI or API.
- Preserve immutable content identity, quotas, retention, and backend-neutral storage.
- Distinguish manual uploads from CI-attempt artifacts in persisted metadata and UI.
- Make the same digest-verified object downloadable by authorized repository users.

## Non-goals

- Executing local build, signing, or notarization commands.
- Pretending that a manual artifact was produced by a successful pipeline.
- Automatically publishing a manual artifact publicly or attaching it to a provider release.
- Resumable, multipart, or presigned browser uploads in the initial increment.

## Users and use cases

### Primary user

A repository maintainer who builds and signs a release binary on trusted local hardware.

### Use cases

1. Sign and notarize a DMG locally, then upload it from the repository artifact page.
2. Authenticate a local account through the API and upload the same file with `curl` or release automation.
3. Verify the server-calculated SHA-256 digest and download the retained object later.

## Requirements

### Functional requirements

- **FR-1:** Robine MUST accept manual artifact uploads only for an existing trusted repository and only from a maintainer or administrator.
- **FR-2:** UI and API uploads MUST call the same Storage facade use case and preserve identical validation, quota, digest, and retention behavior.
- **FR-3:** A manual artifact MUST record `source=manual`, the uploader actor ID, original safe filename, content type, digest, size, creation time, and expiration time; it MUST NOT carry an attempt ID.
- **FR-4:** Existing runner uploads MUST continue to record `source=ci`, an attempt ID, and no manual uploader.
- **FR-5:** Robine MUST calculate SHA-256 while streaming the content into the configured blob store and MUST return the resulting digest and size.
- **FR-6:** A completed manual artifact MUST be immutable. Re-uploading a filename MUST create a distinct retained record and MUST NOT replace prior content.
- **FR-7:** Authenticated viewers, maintainers, and administrators MUST be able to list and download unexpired manual artifacts for an authorized repository.
- **FR-8:** The API MUST accept a bounded raw request body and authenticate either a revocable Bearer session or a repository-scoped `artifacts:write` token. A local session endpoint MUST issue the same seven-day session used by the web application without introducing a second password policy.
- **FR-9:** Manual artifacts MUST remain private ordinary artifacts. Public publication requires a future explicit promotion workflow.

### UX requirements

- **UX-1:** The repository artifact page MUST show an upload drop zone, filename, progress, retention choice, completion digest, and actionable validation errors.
- **UX-2:** The artifact list MUST show filename, size, SHA-256, uploader, upload time, expiration, and a private download action.
- **UX-3:** Viewers MUST never see or activate upload controls.
- **UX-4:** The page MUST explain that Robine stores the supplied bytes but does not perform or verify Apple signing or notarization.

### Operational requirements

- **OR-1:** Upload size MUST be bounded by `storage_max_object_bytes`; the delivery layer MUST spool or stream rather than retain the complete request in process memory.
- **OR-2:** Interrupted, oversized, invalid, quota-rejected, or persistence-failed uploads MUST leave no visible artifact and MUST reuse existing temporary-object garbage collection.
- **OR-3:** API responses MUST disable caching and MUST not expose filesystem paths, session tokens, object-store credentials, or artifact bytes in logs.
- **OR-4:** Upload telemetry MUST use bounded source/outcome labels and byte counts only.

## Proposed design

The Storage artifact model gains explicit provenance fields. Attempt artifacts retain their existing attempt-scoped uniqueness and dependency semantics; manual artifacts have a nullable attempt ID plus a required uploader ID. Separate `upload_manual_artifact` and `list_manual_artifacts` use cases enforce the two provenance shapes while sharing the blob store, quota transaction, download path, and retention worker.

`RepositoryLive.Artifacts` uses LiveView uploads, consumes the server-spooled temporary file as a lazy file stream, and calls `Robine.Storage`. The HTTP API accepts a raw body at `POST /api/v1/repositories/:repository_id/artifacts`, authenticates `Authorization: Bearer <credential>` as either a user session or the scoped token defined by [IAM-002](../identity/iam-002-scoped-api-tokens.md), spools the bounded body to a temporary file, and calls the same facade. `POST /api/v1/session` remains available for short-lived local user authentication.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Missing or expired Bearer session | API returns 401 and stores nothing | Authenticate again |
| Viewer attempts upload | API/UI returns 403 and stores nothing | Use a maintainer account |
| File exceeds configured maximum | Upload stops with 413 or a visible size error | Reduce or split the file, or raise the operator limit |
| Repository or storage quota exceeded | Upload fails without visible metadata | Remove expired content or raise the quota |
| Connection interrupted | No complete artifact is listed | Retry the upload |
| Artifact expires | Download returns 404 and retention removes metadata safely | Upload a new immutable artifact |

## Security and privacy

Manual files are untrusted private binary content. Filename normalization prevents header and path injection; repository authorization is checked before storage and download. Passwords and Bearer sessions are accepted only by authenticated transport boundaries and are never logged. Artifact contents are not inspected for secrets, malware, signing identity, or notarization validity.

## Observability

Emit bounded upload request count, duration, byte count, source (`manual`), and normalized outcome. Retain uploader ID and correlation ID in metadata or audit-safe structured events without filenames, repository names, tokens, paths, or content.

## Acceptance criteria

- [x] A maintainer uploads a DMG through LiveView and sees the server-calculated digest in the repository list.
- [x] A local API session uploads the same bytes through a raw request and receives matching ID, digest, size, expiration, and download URL.
- [x] Viewer, anonymous, expired-session, unknown-repository, oversized, invalid-name, and quota-exceeded requests create no artifact.
- [x] Manual metadata has no attempt ID; existing runner artifacts retain their attempt provenance and dependency behavior.
- [x] Authorized download returns the exact original bytes with private cache headers and a safe filename.
- [x] Local and S3 blob adapters require no manual-upload-specific branch.

## Open questions

None blocking.

## Out of scope / future work

- General-purpose personal access tokens and OIDC device authorization.
- Resumable uploads and direct-to-object-store presigned transfers.
- Explicit promotion of a manual artifact into a public or source-control-provider release.
- Signature, notarization-ticket, SBOM, or provenance attestation verification.
