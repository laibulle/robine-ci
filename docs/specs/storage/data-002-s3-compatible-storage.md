# DATA-002 — S3-compatible blob storage

## Status

- **State:** Shipped
- **Owner:** Storage
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Robine can store cache and artifact blobs in an operator-owned S3-compatible bucket while retaining PostgreSQL as the logical metadata authority. Switching storage backends does not change workflow syntax, use cases, content identities, retention semantics, or runner credentials.

## Problem

Local filesystem storage ties retained CI data to one control-plane host and complicates backup, capacity expansion, and highly available deployments. Self-hosting teams need object storage without granting permanent object-store credentials to runners or coupling application policy to one vendor.

## Goals

- Select local or S3-compatible blob storage through deployment configuration.
- Preserve content-addressed identities and digest verification across backends.
- Stream bounded uploads and downloads without loading configured maximum objects into control-plane memory.
- Keep retention, reconciliation, observability, and health behavior backend-neutral.
- Work with AWS S3 and providers implementing the required S3 API subset.

## Non-goals

- Direct runner access to buckets or presigned upload credentials.
- Cross-instance cache federation, multi-bucket tiering, or cross-region replication policy.
- Managing bucket creation, versioning, encryption keys, lifecycle rules, or provider accounts.
- Treating provider lifecycle deletion as the metadata retention authority.

## Users and use cases

### Primary user

A self-hosting operator deploying Robine on replaceable or horizontally managed control-plane hosts.

### Use cases

1. Configure an existing private bucket and verify readiness before admitting work.
2. Upload, restore, and delete artifacts and caches through existing workflows.
3. Use short-lived workload identity or rotate object-store credentials without changing retained blob identifiers.
4. Reconcile metadata with bucket inventory and retry interrupted garbage collection.
5. Return to local storage only after an explicit, operator-managed migration.

## Requirements

### Functional requirements

- **FR-1:** `ROBINE_BLOB_STORE=local|s3` MUST select exactly one blob-store adapter at startup and MUST default to `local`.
- **FR-2:** S3 mode MUST require an endpoint, region, bucket, and credential-provider configuration resolved only inside the adapter; static keys MUST NOT be mandatory when short-lived workload identity is available. Path-style addressing MUST be configurable for compatible providers.
- **FR-3:** Object keys MUST be derived exclusively from the lowercase SHA-256 digest and an optional normalized deployment prefix; workflow input MUST NOT influence object keys.
- **FR-4:** Publication MUST expose an object as complete only after its streamed content digest and byte count have been finalized and verified.
- **FR-5:** Reads MUST verify the downloaded SHA-256 digest before returning content to a use case and MUST map a missing key to `:not_found`.
- **FR-6:** Repeated publication of identical content and repeated deletion MUST be idempotent.
- **FR-7:** The adapter MUST support bounded multipart upload, abort incomplete multipart uploads after failure, and enforce the configured maximum object size while enumerating the stream.
- **FR-8:** Inventory MUST paginate, remain bounded per provider request, ignore objects outside Robine's normalized prefix, and report malformed in-prefix keys as unsafe.
- **FR-9:** Retention and garbage-collection services MUST depend on `BlobStore`; they MUST NOT name a concrete local or S3 adapter.
- **FR-10:** Backend changes with existing metadata MUST fail startup unless an explicit migration acknowledgement is configured; Robine MUST NOT silently reinterpret missing blobs as a successful migration.

### UX requirements

- **UX-1:** Administration health MUST identify the selected backend and distinguish configuration, authentication, authorization, endpoint, bucket, throttling, and availability failures without exposing credentials.
- **UX-2:** Installation documentation MUST provide least-privilege bucket permissions and configuration examples for AWS S3 and one path-style compatible provider.
- **UX-3:** Cache and artifact UI behavior MUST remain identical across local and S3 modes.

### Operational requirements

- **OR-1:** Every provider request MUST use bounded connect, receive, and total timeouts plus capped exponential retry with jitter only for safe or idempotent operations.
- **OR-2:** Upload memory MUST be bounded by multipart concurrency times part size; download and inventory memory MUST be independently bounded.
- **OR-3:** Server-side encryption MUST be configurable as provider-managed encryption or a named KMS key, and plaintext transport MUST be rejected except for an explicitly enabled loopback test endpoint.
- **OR-4:** Readiness MUST verify configuration and bucket access without writing a user-visible object; a deeper diagnostic MAY perform a private write/read/delete probe.
- **OR-5:** Provider errors MUST be normalized into stable adapter errors so use cases remain provider-neutral.

## Proposed design

`Robine.Storage.Ports.BlobStore` remains the application boundary. Runtime dependency assembly selects `LocalBlobStore` or `S3BlobStore`; use cases and the `Robine.Storage` facade remain unchanged. Retention and reconciliation receive the selected port implementation through explicit dependencies rather than aliasing `LocalBlobStore`.

The S3 adapter maps digest `abcdef…` below an optional prefix to `objects/ab/abcdef…`. Because the final key is unknown until SHA-256 hashing completes, a streamed write first creates a private local spool file while incrementally hashing, counting, and enforcing the object limit. It then uploads that immutable spool to the final digest-derived key with bounded multipart parts, records uploaded part identifiers in process memory, and aborts on transport or completion failure. Small objects may use one conditional `PutObject`. The spool is removed after verified publication or failure and is covered by abandoned-temporary reconciliation. Identical keys are safe because content identity is the digest; a post-write metadata or checksum verification guards incompatible endpoints.

Reads use bounded response streaming into the existing control-plane transfer boundary while incrementally verifying SHA-256. The initial port currently returns a binary, so implementation MAY first retain the existing maximum-bounded return contract; completing this spec requires extending the port and controllers to expose a verified lazy stream or a verified temporary spool for large objects.

PostgreSQL remains authoritative for artifact/cache ownership, authorization, quota, retention, and garbage-collection intent. Bucket lifecycle rules may clean abandoned multipart uploads but MUST NOT delete retained `objects/` keys earlier than Robine policy. Inventory is an operational reconciliation input, not an authorization source.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Invalid endpoint or credentials | Readiness is degraded; new work requiring storage is not admitted | Correct configuration or rotate credentials |
| Upload interrupted | No metadata becomes complete; multipart upload is aborted or later expired | Retry the use case |
| Completion outcome unknown | Adapter verifies the final key before retrying completion/publication | Automatic idempotent retry |
| Object missing or digest differs | Restore fails safely and reconciliation reports corruption | Restore provider backup or rerun producer |
| Provider throttles requests | Bounded retries occur and degraded health is visible | Reduce concurrency or increase provider quota |
| Inventory is truncated or fails | No deletion decision is made from partial inventory | Retry from the last durable reconciliation cycle |
| Backend changed without migration | Startup/readiness fails with an actionable mismatch | Migrate objects and acknowledge the backend change |

## Security and privacy

Bucket credentials, workload-identity tokens, and KMS identifiers are deployment secrets and never enter execution contexts, runner messages, logs, audit metadata, or browser payloads. Short-lived workload identity SHOULD be preferred over static keys. The documented policy grants only the required bucket/prefix operations and multipart controls. Public ACLs are never requested. TLS hostname and certificate verification are mandatory outside loopback tests. Object keys contain digests only and disclose no repository, branch, actor, cache key, or artifact name.

## Observability

Metrics include request count and latency by normalized operation/outcome, bytes transferred, multipart parts and aborts, retry/throttle count, inventory pages, missing/unsafe objects, and backend readiness. Structured logs include provider type, operation, request correlation, bucket hash, and normalized error class but exclude endpoint credentials, authorization headers, signed URLs, object content, and raw provider response bodies.

## Acceptance criteria

- [x] The same storage contract suite passes against local storage and an S3-compatible integration fixture.
- [x] A multipart streamed upload never exceeds the configured memory envelope and restores with the expected digest.
- [x] Interrupted enumeration and failed part upload leave no complete metadata and abort the multipart upload.
- [x] Missing, corrupt, throttled, forbidden, and unavailable provider responses map to documented stable errors.
- [x] Reconciliation paginates more than 1,000 objects and never deletes from a partial inventory.
- [x] Runners complete cache and artifact journeys without receiving bucket credentials.
- [x] Runtime startup rejects unsafe HTTP endpoints.
- [x] Runtime startup rejects unacknowledged backend changes when retained metadata exists.
- [x] Architecture tests prove use cases and retention logic do not depend on a concrete blob-store adapter.

## Open questions

None blocking. The implementation must choose an S3 client only after validating its streaming, multipart-abort, checksum, path-style, timeout, and telemetry behavior against this contract.

## Out of scope / future work

- Direct-to-object-store runner transfers, cross-region replication orchestration, storage-class tiering, and a built-in local-to-S3 migration command.

## References

- [Amazon S3 multipart upload overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
- [Amazon S3 upload integrity and checksum behavior](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity-upload.html)
- [AWS standardized credential providers](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html)
- [ExAws S3 multipart streaming contract](https://hexdocs.pm/ex_aws_s3/ExAws.S3.html#upload/4)
