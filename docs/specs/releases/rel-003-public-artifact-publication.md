# REL-003 — Public artifact publication

## Status

- **State:** Accepted
- **Owner:** Robine maintainers
- **Target:** Post-MVP
- **Last updated:** 2026-08-27

## Summary

Robine lets an explicitly authorized private or public repository publish immutable build outputs at stable public download URLs without making its source, CI logs, caches, or ordinary artifacts public.

## Problem

Repository visibility and release visibility are separate product decisions. A maintainer of a private repository may distribute public binaries, packages, checksums, or documentation, but Robine currently retains build artifacts only behind repository authorization or publishes them through a source-control provider release.

## Goals

- Publish selected outputs from private repositories without using GitHub Releases.
- Keep ordinary artifacts and caches private by default.
- Provide immutable, content-verified downloads with stable public URLs.
- Retain provenance from the public object back to an exact pipeline, job, attempt, repository revision, and workflow revision.
- Support an operator-owned S3-compatible public store, including Garage.

## Non-goals

- Making an existing CI artifact public by changing its visibility in place.
- Publishing failed, untrusted, pull-request, or fork pipeline output.
- Providing a general file-sharing service, package registry, container registry, or website CMS.
- Exposing source repositories, build logs, cache entries, bucket listings, or arbitrary object keys.
- Mutable replacement of an already published version and filename.

## Users and use cases

### Primary user

A maintainer who builds public downloadable software from a private trusted repository on a self-hosted Robine instance.

### Use cases

1. An administrator enables public publication for one trusted private repository.
2. A version-tag pipeline stages one or more release files while keeping them private during execution.
3. After the complete pipeline succeeds, Robine publishes the staged files and displays stable public download URLs and checksums.
4. Anyone downloads a published file without a Robine account or access to the source repository.
5. An administrator withdraws a compromised publication without deleting its audit and provenance record.

## Requirements

### Functional requirements

- **FR-1:** Public publication MUST be disabled for every repository by default and MUST require explicit administrator enablement.
- **FR-2:** Workflow v1 MUST provide a distinct `publications/stage` built-in; `artifacts/upload` MUST remain private and MUST NOT accept a public visibility option.
- **FR-3:** `publications/stage` MUST require one safe workspace-relative regular file, a safe public filename, and a release identifier. It MAY accept a content type and defaults to `application/octet-stream`.
- **FR-4:** The initial release identifier MUST be derived from an authenticated `vMAJOR.MINOR.PATCH` tag, including an optional prerelease suffix. Arbitrary branches, pull requests, schedules, and manual runs MUST NOT publish publicly.
- **FR-5:** Staging MUST upload through the existing attempt-scoped, digest-verifying private transfer and create a publication intent. It MUST NOT expose public content while the pipeline is non-terminal or unsuccessful.
- **FR-6:** Publication MUST occur only after the entire exact-revision pipeline succeeds, the source repository is trusted, and public publication remains enabled.
- **FR-7:** Every publication MUST record repository, source commit, source tag, workflow revision, pipeline, job, attempt, actor or authenticated trigger, filename, content type, SHA-256 digest, byte size, timestamps, state, and public object identity.
- **FR-8:** The tuple of repository, release identifier, and filename MUST be immutable. Repeating a request with the same digest MUST be idempotent; a different digest MUST return a conflict and MUST NOT replace public content.
- **FR-9:** A published download MUST be readable without authentication and MUST reveal only the published filename, byte size, content type, checksum, release identifier, and explicitly public project identity.
- **FR-10:** Public routes MUST use an opaque repository publication slug chosen by an administrator and MUST NOT expose internal database identifiers, provider installation identifiers, private repository clone URLs, or private owner names.
- **FR-11:** An administrator MUST be able to withdraw a publication. Withdrawal MUST make the object unavailable while preserving metadata, audit history, and its previous digest.
- **FR-12:** Republishing a withdrawn tuple MUST be forbidden. A corrected payload MUST use a new release identifier or filename.
- **FR-13:** The public backend MUST support a dedicated local root or dedicated S3-compatible bucket and prefix. It MUST NOT share the private cache/artifact namespace.
- **FR-14:** When direct public object delivery is not configured, Robine MUST provide a streaming public download controller with digest-safe immutable objects and bounded memory.
- **FR-15:** When direct delivery is configured, Robine MUST generate URLs only below one validated HTTPS public base URL and MUST never generate signed URLs containing credentials.
- **FR-16:** Every published filename MUST expose `/downloads/{public_repository_slug}/latest/{filename}` as a mutable convenience alias resolving to the most recently published stable semantic-version release containing that exact filename.
- **FR-17:** The `latest` alias MUST exclude prerelease tags, withdrawn and non-published records, MUST return HTTP 302 to the immutable public URL, and MUST send `Cache-Control: no-store` so clients and intermediaries re-resolve it.

### UX requirements

- **UX-1:** Repository settings MUST explain that public outputs are downloadable by anyone even when the repository is private.
- **UX-2:** Enabling publication MUST require confirmation of the public slug and show the resulting URL prefix.
- **UX-3:** A successful pipeline and repository release page MUST show filename, release, size, SHA-256 checksum, provenance, and copyable public URL.
- **UX-4:** Staged, publishing, published, failed, and withdrawn states MUST be visually and textually distinct.
- **UX-5:** Publication conflicts and backend failures MUST provide a safe retry or correction path without suggesting replacement of immutable content.
- **UX-6:** Public download and metadata pages MUST not render authenticated repository navigation or leak repository existence beyond the configured public identity.
- **UX-7:** The authenticated release history MUST display both the immutable versioned URL and the mutable `latest` alias for every published file.

### Operational requirements

- **OR-1:** Public publication MUST use an independently configured storage dependency and backend namespace.
- **OR-2:** Bytes MUST be SHA-256 verified when accepted from the runner, when copied into the public namespace, and when served through Robine.
- **OR-3:** Publication metadata and public object creation MUST use a durable idempotent intent so restart or timeout cannot silently lose or duplicate publication.
- **OR-4:** Public object keys MUST be derived from the publication ID and digest, never directly from untrusted paths or private repository names.
- **OR-5:** Public responses MUST include an immutable `ETag`, `Digest`, `Content-Length`, safe `Content-Type`, `Content-Disposition`, `X-Content-Type-Options: nosniff`, and a long-lived immutable cache policy.
- **OR-6:** Public downloads MUST support bounded streaming and byte ranges needed for large binary downloads without loading the object into LiveView or control-plane memory.
- **OR-7:** Publication count, individual object size, aggregate public bytes, and publication rate MUST be bounded by administrator configuration independently from private artifact quotas.
- **OR-8:** Public delivery MUST be rate-limitable and MUST expose bounded download and error metrics without client identifiers or object names as labels.

## Proposed design

`Robine.Publications` is a bounded context with a facade and pure `Publication`, `RepositoryPolicy`, and transition modules. Use cases coordinate publication metadata, private artifact reads through the `Robine.Storage` facade, a context-owned public object-store port, audit, clock, identifiers, and a durable outbox. Concrete local and S3-compatible public stores live under `Robine.Adapters` and are assembled only by `Robine.Runtime.Dependencies`.

The `publications/stage` runner built-in uses the existing archive and upload safety boundary but marks the resulting private object as a publication intent rather than an ordinary downloadable artifact. Terminal pipeline projection emits an idempotent publication event only after overall success. The delivery use case rechecks repository policy, reads digest-verified private content, writes it to the separate public backend, verifies the resulting object, and then atomically marks metadata `published`. A failed copy remains retryable and never creates a public metadata projection that claims success.

The canonical URL is `/downloads/{public_repository_slug}/{release}/{filename}`. In proxy mode the Phoenix controller resolves only published metadata and streams from the public store. In direct mode it redirects to the same immutable object below an operator-controlled HTTPS base URL. Garage deployments use a separate bucket or bucket alias with public read delivery and a Robine key restricted to that bucket; private artifacts and caches remain in the existing private bucket.

`/downloads/{public_repository_slug}/latest/{filename}` is deliberately mutable and resolves by publication time among stable `vMAJOR.MINOR.PATCH` releases containing the exact filename. It responds with a temporary redirect to the immutable canonical object and is never cached. Prerelease channels require separate aliases rather than changing stable `latest` semantics.

The lifecycle is `staged -> publishing -> published -> withdrawn`, with `publishing -> failed -> publishing` retry. `withdrawn` is terminal. Publication records are append-only apart from these controlled state transitions.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Pipeline or a later job fails | Intent remains private and expires under staging retention | Fix the pipeline and publish from a new successful tag |
| Public publishing is disabled before delivery | Intent fails closed without creating a public record | Re-enable intentionally and retry delivery |
| Public backend is unavailable | Publication remains retryable and no success URL is advertised | Restore the backend; durable delivery retries |
| Copy outcome is unknown | Robine verifies the digest at the deterministic object key | Mark success if identical or retry idempotently |
| Same release and filename has different bytes | Publication reports immutable conflict | Use a new release identifier or filename |
| Published content is compromised | Administrator withdraws public access | Publish corrected content under a new immutable identity |

## Security and privacy

Public publication is a deliberate declassification boundary. Only trusted tag-triggered code may stage content, and repository policy independently authorizes release. Public metadata is allowlisted and never inherits provider repository data automatically. Filenames, release identifiers, content types, and slugs are normalized; HTML and SVG default to attachment delivery and cannot execute in the Robine origin. Public storage credentials remain in the control plane and are never sent to runners. Private and public stores use separate namespaces and SHOULD use separate credentials. Withdrawal is audited but is not a substitute for key rotation or incident response after content has been downloaded.

## Observability

Bounded metrics cover staged, published, failed, conflicted, and withdrawn outcomes; publication latency; public stored bytes; downloads; transferred bytes; range responses; throttling; and backend errors. Labels are restricted to state, outcome, backend kind, and response class. Repository names, public slugs, releases, filenames, digests, actors, URLs, client addresses, and user agents are forbidden metric labels. Structured events correlate publication, pipeline, job, attempt, and durable delivery identifiers without logging content or private source identity.

## Acceptance criteria

- [ ] A private trusted repository can publish a tagged binary that an unauthenticated client downloads from a stable URL.
- [ ] Ordinary artifacts, caches, logs, source metadata, and bucket inventory remain private.
- [ ] Failed pipelines, untrusted sources, pull requests, branches, schedules, and manual runs cannot publish.
- [ ] Repeated identical delivery is idempotent and different content cannot replace an existing release filename.
- [ ] Local proxy delivery and a real Garage-backed direct-delivery fixture pass the same publication contract.
- [ ] Large and ranged downloads remain bounded and return checksum, disposition, content type, nosniff, caching, and range headers correctly.
- [ ] Tests prove explicit enablement, public-slug isolation, path safety, MIME safety, quota enforcement, durable retry, withdrawal, audit, and absence of private metadata.
- [ ] The repository UI exposes policy and provenance while the public page remains independent from authenticated navigation.
- [x] A non-cached `latest` alias selects the newest published stable release for an exact filename and never selects prerelease, failed, staged, or withdrawn content.

## Open questions

None blocking. The initial contract permits immutable public downloads and one narrowly defined stable `latest` alias. Authenticated external downloads and additional mutable channels require separate specifications.

## Out of scope / future work

- Package-manager indexes, OCI images, container registries, and repository signing metadata.
- Additional mutable `stable`, prerelease, beta, or custom channel aliases.
- Custom domains per repository.
- Public directory listing and full-text discovery.
- Download analytics tied to individual visitors.
- Authenticated public-link sharing and expiring signed URLs.
