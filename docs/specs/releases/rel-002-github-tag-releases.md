# REL-002 — GitHub tag releases

## Status

- **State:** Shipped
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Robine turns a trusted `v*` Git tag into an immutable CI build and, only after success, creates the matching GitHub Release with the retained build payload attached.

## Problem

Maintainers currently build release bundles but must create GitHub Releases and transfer assets manually, which is slow and can associate an asset with the wrong revision.

## Goals

- Trigger a dedicated workflow from an exact tag revision.
- Publish the retained build payload without exposing GitHub credentials to the job.
- Make retries and reconciliation idempotent.

## Non-goals

- Publishing releases for GitLab or Forgejo in this increment.
- Replacing or deleting an existing GitHub release asset.
- Signing assets or publishing container images.

## Users and use cases

### Primary user

A Robine maintainer publishing a versioned GitHub release.

### Use cases

1. Push `v0.1.0`, observe the tag workflow, and download its generated payload from the resulting GitHub Release.

## Requirements

### Functional requirements

- **FR-1:** GitHub tag push payloads MUST resolve workflows at the tag's exact commit SHA.
- **FR-2:** `push.tags` MUST support bounded `*` glob matching and MUST remain distinct from branch filters.
- **FR-3:** Only a successful tag pipeline carrying one or more retained `github-release` artifacts MAY publish a release, and every matching artifact MUST become a distinct release asset.
- **FR-4:** The GitHub release tag and target SHA MUST equal the authenticated webhook event.
- **FR-5:** Reconciliation MUST reuse an existing release and asset rather than create duplicates.
- **FR-6:** Artifact names MAY use the allowlisted `${{ runner.os }}` and `${{ runner.arch }}` variables, resolved by the executing runner before publication.
- **FR-7:** A retained artifact MAY place a project-specific asset prefix between `github-release-` and the final OS/architecture pair; absence MUST preserve the historical `robine` prefix.
- **FR-8:** The GitHub asset filename MUST omit the version already represented by its immutable release tag.

### UX requirements

- **UX-1:** Setup MUST state that Contents write is required for tag-release publication.
- **UX-2:** Release failures MUST remain visible through the existing failed projection/retry path.

### Operational requirements

- **OR-1:** Provider credentials MUST remain in the control plane.
- **OR-2:** Tags MUST match `vMAJOR.MINOR.PATCH` with an optional prerelease suffix before publication.
- **OR-3:** The retained release payload MUST have an explicit expiry.

## Proposed design

The authenticated push normalizer distinguishes `refs/tags/*` from branches, resolves annotated tags to `head_commit.id`, and stores the tag in immutable pipeline inputs. A dedicated Ubuntu 26.04 workflow packages the production OTP server, CLI, and standalone runner independently, then uploads them as `github-release-robine-server-${{ runner.os }}-${{ runner.arch }}`, `github-release-robine-cli-${{ runner.os }}-${{ runner.arch }}`, and `github-release-robine-runner-${{ runner.os }}-${{ runner.arch }}`. Other projects MAY use a name such as `github-release-robine_nas-${{ runner.os }}-${{ runner.arch }}` to select their GitHub asset prefix. The executing runner resolves these two allowlisted variables to normalized values such as `linux` and `amd64`; unresolved or arbitrary expressions are rejected. Terminal projection publishes the release before checks so already-retained payloads remain recoverable even when a legacy tag pipeline used an object SHA. It downloads every digest-verified retained release artifact through the Storage facade and calls a provider capability using the GitHub App installation token once per asset. GitHub release creation requests generated notes; asset publication attaches each immutable archive with its project prefix, OS, and architecture in its name. The immutable GitHub release tag remains the sole version identifier. Existing matching releases and assets are treated as success.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Build fails | No GitHub Release is created | Fix and push a new version tag |
| Contents write is missing | Publication retries and installation health is degraded | Update the App permission and approve the installation |
| Release already exists | Robine reuses it | Reconciliation continues idempotently |
| Asset expired before publication | Publication fails without an empty release asset | Rerun from a new tag |

## Security and privacy

The job receives neither an installation token nor GitHub API access. Only trusted repositories and authenticated tag webhooks can select the tag and SHA. Release publication accepts a fixed artifact name and a strict semantic-version tag.

## Observability

Pipeline logs retain package generation and upload output. GitHub API telemetry and the existing reconciliation worker expose provider failures without recording asset content or credentials.

## Acceptance criteria

- [x] Branch and tag filters select only their matching push kind.
- [x] A successful tag workflow retains a `github-release` payload.
- [x] Publication is strict, credential-isolated, and idempotent in tests.
- [x] A real annotated tag creates a GitHub Release and attached payload after Contents write is approved.
- [x] Release artifact templates resolve OS and architecture while rejecting arbitrary variables.
- [x] Project-specific release artifacts retain their own GitHub asset prefix.
- [x] Server, CLI, and runner distributions publish as three distinct stable, versionless assets.

## Open questions

- None.

## Out of scope / future work

- Server bundles on a dedicated supported Ubuntu release runner.
- Asset signing, provenance attestations, changelog templates, and provider parity.
