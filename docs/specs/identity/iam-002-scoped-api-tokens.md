# IAM-002 — Scoped API tokens

## Status

- **State:** Shipped
- **Owner:** Identity
- **Target:** Post-MVP
- **Last updated:** 2026-08-28

## Summary

Robine lets maintainers create revocable, expiring repository-scoped API tokens with an explicit `artifacts:write` permission so local release automation can upload a produced binary without retaining a user password or a broad web session.

## Problem

The manual artifact API currently authenticates with a seven-day user session. Release automation needs a purpose-built credential whose authority, repository scope, lifetime, and revocation state are visible and independently manageable.

## Goals

- Issue an opaque automation token for one trusted repository and one explicit permission.
- Limit the token to manual artifact upload and reject every unrelated API operation.
- Make creation, expiration, last use, and revocation visible to maintainers.
- Store no recoverable token value.

## Non-goals

- Replacing interactive browser sessions or OIDC.
- General-purpose personal access tokens with arbitrary product permissions.
- Organization-wide, multi-repository, runner, or deployment credentials.
- Token rotation with an overlap window in the initial increment.

## Users and use cases

### Primary user

A repository maintainer automating upload of a locally signed and notarized release artifact.

### Use cases

1. Create a 90-day token for one repository, copy it once into a local secret store, and upload a DMG with `curl`.
2. Review token metadata and revoke a credential after release automation changes or a suspected disclosure.

## Requirements

### Functional requirements

- **FR-1:** Only maintainers and administrators MUST create, list, or revoke repository API tokens.
- **FR-2:** Every token MUST belong to exactly one trusted repository, one creating user, a bounded display name, an expiration, and a non-empty allowlisted permission set.
- **FR-3:** The initial permission catalogue MUST contain only `artifacts:write`.
- **FR-4:** An `artifacts:write` token MUST authorize only manual artifact upload for its exact repository. It MUST NOT authorize listing, downloading, pipeline execution, secret management, token management, or deployment.
- **FR-5:** Token plaintext MUST be returned only by successful creation. Robine MUST persist only a SHA-256 digest and a non-secret identifying prefix.
- **FR-6:** Revoked, expired, malformed, unknown, disabled-owner, or authorization-lost tokens MUST fail authentication immediately.
- **FR-7:** Listing MUST return metadata only: ID, name, prefix, permissions, creator, created time, expiration, last use, and revocation time.
- **FR-8:** A successful token-authenticated upload MUST retain the creating user as uploader provenance and the token ID as request actor metadata.
- **FR-9:** Existing revocable session Bearer authentication MUST remain supported and behaviorally unchanged.

### UX requirements

- **UX-1:** The repository token page MUST explain the exact authority granted and provide name and expiration controls.
- **UX-2:** The plaintext token MUST appear in a copyable one-time reveal with an explicit warning that Robine cannot show it again.
- **UX-3:** Active and revoked/expired tokens MUST have distinct status labels, and revocation MUST require an explicit action.
- **UX-4:** Viewers MUST not see token controls or access the token-management route.

### Operational requirements

- **OR-1:** Names MUST be at most 64 characters, tokens MUST contain at least 256 bits of randomness, and expiration MUST be between 1 and 365 days.
- **OR-2:** Authentication MUST use a recognizable token prefix before digest lookup and MUST never log the raw Authorization header or plaintext token.
- **OR-3:** Successful use SHOULD update `last_used_at`; authentication failure MUST not disclose whether a token exists, expired, was revoked, or has a disabled owner.
- **OR-4:** Authentication and lifecycle telemetry MUST use bounded permission/outcome labels only.

## Proposed design

The Identities context owns an `ApiToken` credential and create, list, revoke, and resolve use cases. The opaque value uses a `rbn_art_` prefix plus 32 random bytes encoded without padding. The PostgreSQL adapter stores its SHA-256 digest, short display prefix, repository and user IDs, the allowlisted permission array, timestamps, and revocation state.

The API authentication plug routes `rbn_art_` Bearer credentials to `Identities.resolve_api_token/2`; ordinary values continue through session resolution. A resolved credential becomes an `artifact_uploader` actor carrying its repository ID, creator ID, token ID, and permission list. `Storage.upload_manual_artifact/2` accepts that actor only when both repository scope and `artifacts:write` match. Other Storage use cases do not accept that role.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Token is lost after creation | Plaintext cannot be recovered | Revoke metadata entry and create a replacement |
| Token expired or revoked | API returns the same 401 as an unknown token | Create a new token if still required |
| Token used for another repository | Upload returns 403 and stores nothing | Use a token issued for that repository |
| Permission absent or forged | Authentication or upload fails closed | Create an allowlisted token through Robine |
| Owner disabled or demoted to viewer | Token stops authenticating | Restore maintainer authority deliberately or create a credential owned by an active maintainer |

## Security and privacy

The token is a bearer secret and grants write-only access to private storage for one repository. Operators must store it in a local keychain or secret manager and transmit it only over TLS. Robine never persists plaintext, includes it in HTML after the creation view is replaced, or returns it from list operations. Repository IDs, token IDs, and user IDs may be retained for audit correlation but are forbidden metric labels.

## Observability

Emit bounded token lifecycle and authentication counts with action, permission class, and normalized outcome. Structured events may correlate token, actor, repository, and request IDs but omit token prefix, name, digest, raw token, filename, and request body.

## Acceptance criteria

- [x] A maintainer creates an `artifacts:write` token and sees its plaintext exactly once.
- [x] The persisted credential contains a digest but never the plaintext token.
- [x] The token uploads an artifact to its repository and the artifact records manual provenance and the creating user.
- [x] The same token cannot upload to another repository or list/download artifacts.
- [x] Revoked, expired, malformed, unknown, and disabled-owner tokens return 401 and create no artifact.
- [x] A viewer cannot create, list, or revoke tokens through direct use-case or forged LiveView calls.
- [x] Existing user-session API uploads continue to pass unchanged.

## Open questions

None blocking.

## Out of scope / future work

- Additional permissions, multi-repository service accounts, and organization policy.
- Rotation overlap, usage IP summaries, and administrator-enforced maximum lifetime below 365 days.
- OIDC workload identity federation and short-lived token exchange.
