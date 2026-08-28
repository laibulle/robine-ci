# IAM-002 — Permission-scoped global API tokens

## Status

- **State:** Shipped
- **Owner:** Identity
- **Target:** Post-MVP
- **Last updated:** 2026-08-28

## Summary

Robine lets administrators create revocable, expiring API tokens that are global to the instance and carry only the explicit `artifacts:write` permission. Local release automation can therefore upload a produced binary to any trusted repository without retaining a user password or a broad web session.

## Problem

The manual artifact API currently authenticates with a seven-day user session. Release automation needs a purpose-built credential whose narrow authority, lifetime, and revocation state are visible and independently manageable without provisioning one credential per repository.

## Goals

- Issue an opaque instance-global automation token with one explicit permission.
- Limit the token to manual artifact upload and reject every unrelated API operation.
- Make creation, expiration, last use, and revocation visible to administrators.
- Store no recoverable token value.

## Non-goals

- Replacing interactive browser sessions or OIDC.
- General-purpose personal access tokens with arbitrary product permissions.
- General-purpose runner or deployment credentials.
- Repository-scoped API tokens in the initial increment.
- Token rotation with an overlap window in the initial increment.

## Users and use cases

### Primary user

An instance administrator enabling upload of locally signed and notarized release artifacts.

### Use cases

1. Create a 90-day global token, copy it once into a local secret store, and upload DMGs for trusted repositories with `curl`.
2. Review token metadata and revoke a credential after release automation changes or a suspected disclosure.

## Requirements

### Functional requirements

- **FR-1:** Only administrators MUST create, list, or revoke API tokens.
- **FR-2:** Every token MUST belong to one creating administrator and have a bounded display name, an expiration, and a non-empty allowlisted permission set. It MUST NOT be tied to one repository.
- **FR-3:** The initial permission catalogue MUST contain only `artifacts:write`.
- **FR-4:** An `artifacts:write` token MUST authorize only manual artifact upload to any trusted repository in the instance. It MUST NOT authorize listing, downloading, pipeline execution, secret management, token management, or deployment.
- **FR-5:** Token plaintext MUST be returned only by successful creation. Robine MUST persist only a SHA-256 digest and a non-secret identifying prefix.
- **FR-6:** Revoked, expired, malformed, unknown, disabled-owner, or authorization-lost tokens MUST fail authentication immediately.
- **FR-7:** Listing MUST return metadata only: ID, name, prefix, permissions, creator, created time, expiration, last use, and revocation time.
- **FR-8:** A successful token-authenticated upload MUST retain the creating user as uploader provenance and the token ID as request actor metadata.
- **FR-9:** Existing revocable session Bearer authentication MUST remain supported and behaviorally unchanged.

### UX requirements

- **UX-1:** The Admin token page MUST explain its global repository reach and exact authority, and provide name and expiration controls.
- **UX-2:** The plaintext token MUST appear in a copyable one-time reveal with an explicit warning that Robine cannot show it again.
- **UX-3:** Active and revoked/expired tokens MUST have distinct status labels, and revocation MUST require an explicit action.
- **UX-4:** Maintainers and viewers MUST not see token controls or access the token-management route.

### Operational requirements

- **OR-1:** Names MUST be at most 64 characters, tokens MUST contain at least 256 bits of randomness, and expiration MUST be between 1 and 365 days.
- **OR-2:** Authentication MUST use a recognizable token prefix before digest lookup and MUST never log the raw Authorization header or plaintext token.
- **OR-3:** Successful use SHOULD update `last_used_at`; authentication failure MUST not disclose whether a token exists, expired, was revoked, or has a disabled owner.
- **OR-4:** Authentication and lifecycle telemetry MUST use bounded permission/outcome labels only.

## Proposed design

The Identities context owns an `ApiToken` credential and create, list, revoke, and resolve use cases. The opaque value uses a `rbn_art_` prefix plus 32 random bytes encoded without padding. The PostgreSQL adapter stores its SHA-256 digest, short display prefix, creator user ID, the allowlisted permission array, timestamps, and revocation state.

The API authentication plug routes `rbn_art_` Bearer credentials to `Identities.resolve_api_token/2`; ordinary values continue through session resolution. A resolved credential becomes an `artifact_uploader` actor carrying its creator ID, token ID, and permission list. `Storage.upload_manual_artifact/2` accepts that actor only with `artifacts:write`, then independently verifies that the target repository exists and is trusted. Other Storage use cases do not accept that role.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Token is lost after creation | Plaintext cannot be recovered | Revoke metadata entry and create a replacement |
| Token expired or revoked | API returns the same 401 as an unknown token | Create a new token if still required |
| Token targets a missing or untrusted repository | Upload returns 404 and stores nothing | Trust the repository or correct its ID |
| Permission absent or forged | Authentication or upload fails closed | Create an allowlisted token through Robine |
| Owner disabled or demoted from administrator | Token stops authenticating | Restore administrator authority deliberately or create a credential owned by an active administrator |

## Security and privacy

The token is a bearer secret and grants write-only access to private storage across every trusted repository in the instance. Operators must store it in a local keychain or secret manager and transmit it only over TLS. Robine never persists plaintext, includes it in HTML after the creation view is replaced, or returns it from list operations. Target repository IDs, token IDs, and user IDs may be retained for audit correlation but are forbidden metric labels.

## Observability

Emit bounded token lifecycle and authentication counts with action, permission class, and normalized outcome. Structured events may correlate token, actor, repository, and request IDs but omit token prefix, name, digest, raw token, filename, and request body.

## Acceptance criteria

- [x] An administrator creates an `artifacts:write` token and sees its plaintext exactly once.
- [x] The persisted credential contains a digest but never the plaintext token.
- [x] The token uploads artifacts to multiple trusted repositories and each artifact records manual provenance and the creating user.
- [x] The token cannot list or download artifacts and cannot target a missing or untrusted repository.
- [x] Revoked, expired, malformed, unknown, and disabled-owner tokens return 401 and create no artifact.
- [x] A maintainer or viewer cannot create, list, or revoke tokens through direct use-case or forged LiveView calls.
- [x] Existing user-session API uploads continue to pass unchanged.

## Open questions

None blocking.

## Out of scope / future work

- Additional permissions, repository-scoped credentials, and organization policy.
- Rotation overlap, usage IP summaries, and administrator-enforced maximum lifetime below 365 days.
- OIDC workload identity federation and short-lived token exchange.
