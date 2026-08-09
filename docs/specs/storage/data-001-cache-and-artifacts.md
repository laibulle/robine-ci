# DATA-001 — Cache and artifacts

## Status

- **State:** Shipped
- **Owner:** Storage
- **Target:** MVP
- **Last updated:** 2026-08-09

## Summary

Robine provides explicit dependency caches and immutable job artifacts on local filesystem storage, with database metadata and a storage interface that can support object storage later. Cache improves speed; artifacts preserve declared outputs and enable job retries.

## Problem

Containerized jobs begin with empty writable filesystems. Developers need to reuse dependencies and transfer outputs without accidental cross-job filesystem sharing. Retrying downstream work also requires stable prerequisite artifacts.

## Goals

- Make caches fast, optional, and safe to miss.
- Make artifacts immutable, content-addressed, and attributable to one attempt.
- Support downstream jobs and failed-job retry semantics.
- Keep local storage bounded through retention and quotas.

## Non-goals

- Distributed object storage in the MVP.
- Using caches as guaranteed build outputs.
- Cross-instance cache federation.
- Permanent package or release hosting.

## Users and use cases

### Primary user

A developer caching dependencies, transferring build outputs, downloading diagnostics, or retrying a failed downstream job.

### Use cases

1. Restore the newest compatible cache by exact key.
2. Save selected dependency paths after a successful step.
3. Upload named artifacts and download them in dependent jobs.
4. Retry a job while required dependency artifacts still exist.

## Requirements

### Functional requirements

- **FR-1:** Cache and artifact paths MUST resolve below the job workspace and MUST reject path traversal, absolute paths, devices, and unsafe symbolic-link targets.
- **FR-2:** Cache entries MUST be scoped to an instance and repository and addressed by a normalized user key plus implementation version.
- **FR-3:** An exact cache-key hit MUST restore the newest complete entry; cache misses MUST NOT fail a job.
- **FR-4:** Cache writes MUST be atomic and incomplete writes MUST never become restorable.
- **FR-5:** Artifact names MUST be unique within an attempt and immutable after successful upload.
- **FR-6:** Artifact archives MUST include a cryptographic digest verified on upload completion and every restore.
- **FR-7:** Downstream artifact download MUST require an explicit dependency and named artifact.
- **FR-8:** Retrying a job MUST use artifacts from the selected successful dependency attempts; if any required artifact expired, the retry MUST be refused with a rerun-dependencies option.
- **FR-9:** Users MUST be able to download authorized artifacts through expiring, access-controlled responses or streams.
- **FR-10:** Instance and repository quotas and retention periods MUST be configurable.
- **FR-11:** Eviction MUST prefer expired caches, then least-recently-restored caches; artifacts MUST follow retention policy and MUST NOT be silently evicted before their declared expiry unless the instance is in an explicit emergency state.

### UX requirements

- **UX-1:** Every restore MUST visibly report hit, miss, restored key, size, and duration.
- **UX-2:** Artifact pages MUST show source job, attempt, digest, size, creation time, and expiry.
- **UX-3:** A refused retry MUST name each unavailable input and offer the smallest valid rerun scope.

### Operational requirements

- **OR-1:** Archive extraction MUST enforce limits on expanded size, file count, compression ratio, and extraction time.
- **OR-2:** Storage writes MUST use temporary files and atomic finalization on the same filesystem.
- **OR-3:** Database metadata and filesystem objects MUST be reconciled periodically.
- **OR-4:** The storage interface MUST not expose local paths to callers, enabling a later object-storage implementation.

## Proposed design

The database records logical cache entries and immutable artifacts. Blobs use content-derived paths below a configured storage root, never user-provided path components. Uploads accept lazy binary chunk streams, write a hidden same-filesystem temporary object while incrementally hashing and enforcing the object-size limit, then atomically finalize and commit metadata. Enumeration stops as soon as the limit or an invalid chunk is observed. A failed or interrupted stream removes its temporary object and can never expose a final content address.

The MVP defaults artifact and cache declarations to seven days and log retention to 30 days. An hourly durable worker removes expired metadata in batches of 1,000 and places possible orphan blobs into a persistent garbage-collection queue. It waits one hour, rechecks references across artifacts and caches, deletes the blob, and acknowledges the candidate only after filesystem deletion succeeds. The same pass inventories content-addressed objects, compares them with cache and artifact references, stages bounded orphan batches, reports missing and unsafe objects, and deletes abandoned temporary files older than the grace interval. Operators may configure log retention, grace, and batch size through environment variables.

The initial storage ceilings are 50 GiB of logical retained content for the instance and 10 GiB per repository. TAR with gzip compression is the sole MVP archive format. An artifact that completed publication before its job later failed keeps its declared retention; the MVP does not run implicit post-failure artifact collection after command execution stops.

Cache restore extracts into the job workspace before user steps that depend on it. Artifact download follows explicit built-in steps. Cache and artifact archives use one documented format and normalized metadata to avoid owner and timestamp surprises.

Runner-owned built-ins create gzip-compressed TAR archives inside the isolated job container, copy them through Docker's archive API, and validate them before publication. Restore inputs are digest-verified by storage and preflighted again before extraction. A cache miss succeeds visibly. Artifact downloads resolve by pipeline, declared dependency job, successful attempt, and artifact name; callers cannot bypass the dependency graph with an arbitrary artifact identifier.

Source TAR archives are inspected before in-memory extraction. Only directories and regular files below a single archive root are accepted; traversal, links, devices, FIFOs, excessive paths, more than 10,000 files, more than 1 GB expanded content, a compression ratio above 100:1, or parsing beyond ten seconds are rejected. Cache and artifact archive extraction MUST reuse the same policy when their runner built-ins are implemented.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Cache missing/corrupt | Cache is skipped with a warning and quarantined if corrupt | Job rebuilds and may save a new cache |
| Artifact upload fails | Built-in step fails; incomplete object is unavailable | Retry step/job |
| Required artifact expired | Downstream retry is refused | Rerun producing dependency |
| Filesystem is full | New writes fail cleanly; new jobs may be blocked | Evict eligible data or expand storage |
| Metadata/blob mismatch | Object is quarantined or metadata marked unavailable | Reconciliation and operator alert |

## Security and privacy

Caches and artifacts are untrusted archives. Collection and extraction prevent path escape and unsafe special files. Access uses repository authorization. Secret values MUST NOT appear in cache keys or artifact metadata; content is not automatically guaranteed secret-free.

## Observability

Metrics include streamed blob-write bytes and outcomes, logical and physical retained bytes, reconciliation orphan/missing/unsafe differences, abandoned temporary deletion, and periodic disk available bytes and used percentage. Cache hit ratio, request latency, quota denials, eviction, corruption, and retry failures remain part of the complete operations metric catalogue.

## Acceptance criteria

- [x] Cache miss does not fail a representative job.
- [x] Interrupted uploads never become visible as complete objects.
- [x] Traversal, symlink escape, archive bomb, and special-file fixtures are rejected for source, cache, and artifact archives.
- [x] An artifact digest mismatch is detected before extraction.
- [x] A failed job can be retried using retained dependency artifacts.
- [x] When an input artifact has expired, the UI offers the smallest dependency rerun that can recreate it.

## Open questions

None blocking.

## Decisions

- Default logical quotas are 50 GiB per instance and 10 GiB per repository.
- Cache and artifact archives use TAR with gzip compression.
- Successfully published artifacts are retained for their declared duration even if a later step makes the job fail. No unrequested post-failure collection occurs.

## Out of scope / future work

- S3-compatible storage, remote cache services, deduplication garbage collection across repositories, and release assets.
