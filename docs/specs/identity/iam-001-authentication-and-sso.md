# IAM-001 — Authentication and SSO

## Status

- **State:** Shipped
- **Owner:** Identity
- **Target:** MVP
- **Last updated:** 2026-08-30

## Summary

Robine supports secure first-admin bootstrap, local authentication for recovery and small installations, and standards-based OpenID Connect SSO as an open-source feature. Authorization remains deliberately simple in the MVP.

## Problem

Self-hosted operators need to secure an instance without paying for basic identity integration. At the same time, supporting SAML, LDAP, SCIM, and complex organization policy in the MVP would expand security-sensitive scope beyond the target audience's immediate needs.

## Goals

- Provide a secure, one-time first-admin setup.
- Support local credentials and one OIDC provider.
- Prevent accidental administrator lockout.
- Enforce clear instance and repository authorization.

## Non-goals

- SAML, LDAP, SCIM, multiple simultaneous OIDC providers, or just-in-time group policy.
- Fine-grained custom roles.
- Billing or commercial entitlement enforcement.

## Users and use cases

### Primary user

An instance administrator configuring identity and developers signing in through a trusted OIDC provider.

### Use cases

1. Bootstrap the first administrator exactly once.
2. Configure and test an OIDC provider.
3. Invite or permit users and assign simple roles.
4. Recover access if the provider is unavailable.

## Requirements

### Functional requirements

- **FR-1:** First-admin bootstrap MUST be available only while no user exists and MUST be protected by a one-time, expiring setup token delivered outside normal web responses.
- **FR-2:** Local passwords MUST be hashed with a current memory-hard password hashing algorithm and configurable safe parameters.
- **FR-3:** The MVP MUST support one OIDC provider using authorization code flow with PKCE, state, and nonce validation.
- **FR-4:** OIDC issuer metadata and signing keys MUST be validated and refreshed according to standards.
- **FR-5:** OIDC account identity MUST use the stable issuer and subject identifier. The first provider-verified email match MAY link to an active local recovery account that has no OIDC identity; subsequent or OIDC-only email collisions MUST fail closed.
- **FR-6:** Roles MUST be `administrator`, `maintainer`, and `viewer`.
- **FR-7:** Administrators MUST manage instance settings and identity; maintainers MUST manage repositories and pipelines; viewers MUST have read-only access to authorized repositories.
- **FR-8:** The last usable administrator MUST NOT be demoted or disabled through the normal UI.
- **FR-9:** Sessions MUST be revocable and use secure, HTTP-only, SameSite cookies.
- **FR-10:** OIDC MAY be enforced for normal users, but an explicitly configured break-glass local administrator path MUST remain available to operators.

### UX requirements

- **UX-1:** OIDC configuration MUST include a preflight test and show the exact redirect URI to register.
- **UX-2:** Authentication failures MUST be useful without disclosing whether an unrelated account exists.
- **UX-3:** Security-sensitive actions MUST require recent authentication when appropriate.

### Operational requirements

- **OR-1:** Instance base URL and proxy headers MUST be validated because they determine secure redirects and cookies.
- **OR-2:** Login endpoints MUST be rate-limited and audited.
- **OR-3:** Clock-skew tolerance MUST be bounded and documented.

## Proposed design

Identity records separate users from authentication identities. A user can hold a local credential and an OIDC identity, allowing an administrator to preserve recovery access. Repository access inherits from the MVP instance role; future repository-specific membership can extend this model without changing identity keys.

The first successful OIDC callback may attach its validated issuer and stable subject to an active local recovery account with the same provider-verified email. This bootstrap bridge preserves the local role and password, and is available only while that user has no OIDC identity. Once linked, email changes or a different subject never select the account.

OIDC is part of the AGPL-licensed self-hosted product. The supported MVP surface is standards-based OIDC only; the product should call it “SSO with OpenID Connect,” not imply SAML or LDAP support.

The OIDC protocol client is selected at the application composition root and consumed through the identity OIDC port. Provider failures MUST remain ordinary use-case errors: the web boundary clears transient OIDC session parameters, creates neither a user, an OIDC identity, nor a local session, and directs the operator to local recovery sign-in. OIDC availability MUST NOT be a dependency of local password authentication, session resolution, or administrator authorization.

### Server-side web authorization matrix

| Surface | Minimum role | Server-side enforcement |
|---|---|---|
| Pipeline, job, workflow revision, repository reads | Viewer | Authenticated LiveView session plus read-use-case policy |
| Cancel pipeline, retry job, check installation permissions | Maintainer | Mutation/use-case role guard; forged LiveView events are refused |
| Repository secrets | Maintainer | Maintainer LiveView session plus secret use-case policy |
| Repository discovery/trust | Administrator | Discovery/trust use-case policy; browser metadata is revalidated against GitHub |
| Identity, health, retention, and instance credentials | Administrator | Administrator LiveView session plus each application use-case policy |

Visibility of a button is never an authorization boundary. Every LiveView event calls a facade use case with the session-derived actor, and tests issue hidden events directly to prove the underlying policy still rejects them.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| OIDC provider unavailable | Existing sessions continue until expiry; new SSO fails clearly | Use break-glass account or restore provider |
| Signing key rotates | Keys refresh safely | Retry validation after metadata refresh |
| Redirect/base URL is wrong | Preflight test fails before enforcement | Correct public URL/proxy configuration |
| Last admin change attempted | Operation is rejected | Create another administrator first |

## Security and privacy

Tokens are encrypted or hashed according to their use, never logged, and retained only as needed. Authentication events include actor, method, result, and source metadata while avoiding raw tokens and unnecessary personal claims.

## Observability

Metrics include login success/failure by method, OIDC discovery/JWKS failures, session revocations, rate limits, and rejected authorization checks. Audit events record identity and role changes.

## Acceptance criteria

- [x] First-admin setup cannot be repeated after the first account exists.
- [x] OIDC login validates issuer, audience, signature, nonce, state, and PKCE.
- [x] Email collision cannot silently take over an existing local account.
- [x] The last usable administrator cannot remove their own recovery path accidentally.
- [x] Every protected LiveView route and action performs server-side authorization, including forged hidden-event coverage.
- [x] A provider outage during authorization or callback creates no partial identity/session, and a local administrator can still sign in and reach instance administration.

## Open questions

None blocking. Any provider-authenticated identity with a verified email may be provisioned as a viewer. The one-use bootstrap token is supplied through `ROBINE_BOOTSTRAP_TOKEN`, expires after 15 minutes, and is rotated by restarting with a fresh value before initial setup. MVP repository access uses the global viewer/maintainer/administrator roles; repository-specific authorization is future work.

## Out of scope / future work

- SAML, LDAP, SCIM, multiple providers, group mapping, and custom roles.
