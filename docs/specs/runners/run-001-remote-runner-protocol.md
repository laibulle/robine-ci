# RUN-001 — Remote runner protocol

## Status

- **State:** Shipped
- **Owner:** Core team
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Robine operators can enroll a worker on another machine and let it execute CI jobs through an outbound, authenticated HTTPS/WebSocket connection. The control plane remains the durable authority for scheduling and attempt state while the protocol is explicit, versioned, resumable, and independent from Erlang Distribution.

## Problem

Local Docker execution ties build capacity, isolation, and operating-system support to the control-plane host. Individuals and startups need to add machines without exposing the Robine server or an Erlang node network to each runner, and without accepting ambiguous job ownership after a network failure.

## Goals

- Enroll a runner in less than five minutes without copying a permanent server credential.
- Support runner-initiated connections through common reverse proxies and outbound-only firewalls.
- Authenticate every protocol session and make runner revocation effective on the next request or reconnect.
- Preserve exactly one durable outcome per attempt despite duplicate or reordered delivery.
- Negotiate protocol compatibility before jobs are offered.

## Non-goals

- Executing untrusted public contributions without an additional isolation boundary.
- Exposing Erlang Distribution, EPMD, or arbitrary remote procedure calls.
- Providing a cloud-specific autoscaler.
- Supporting browsers or third-party agents as runner protocol clients.
- Guaranteeing exactly-once process execution across machine or network failure.

## Users and use cases

### Primary user

A self-hosting administrator who owns the control plane and one or more trusted Linux worker machines.

### Use cases

1. An administrator creates a short-lived, single-use enrollment token and installs a runner with it.
2. The runner exchanges the enrollment token for its own identity and credential, then connects outbound.
3. The control plane offers a compatible job; the runner accepts it and reports ordered lifecycle events.
4. A disconnected runner resumes an active attempt or learns that its lease was lost.
5. An administrator revokes a compromised runner and prevents further connections immediately.

## Requirements

### Functional requirements

- **FR-1:** Only an administrator MUST be able to create an enrollment token.
- **FR-2:** An enrollment token MUST contain at least 256 bits of entropy, expire after 15 minutes by default, be usable once, and be returned in plaintext only at creation.
- **FR-3:** The server MUST store enrollment and runner credentials only as keyed or password-resistant digests suitable for secret verification.
- **FR-4:** Enrollment MUST create a stable runner identifier and a distinct rotatable runner credential.
- **FR-5:** A runner MUST initiate all control connections to the server over TLS-protected HTTPS or WebSocket, except on an explicitly enabled loopback development endpoint.
- **FR-6:** The handshake MUST include the runner identifier, supported protocol versions, runner software version, capabilities, and credential proof.
- **FR-7:** The server MUST reject revoked runners, expired credentials, unsupported protocol versions, oversized messages, and malformed capability documents.
- **FR-8:** Protocol version 1 MUST define `hello`, `welcome`, `heartbeat`, `job_offer`, `job_accept`, `job_reject`, `attempt_event`, `ack`, `cancel`, and `lease_lost` messages.
- **FR-9:** Every state-changing message MUST include a unique message ID. Attempt events MUST additionally include an attempt ID and monotonically increasing sequence number.
- **FR-10:** Delivery MAY be repeated. Both parties MUST process state-changing messages idempotently and acknowledge the highest durably recorded attempt sequence.
- **FR-11:** A job offer MUST have a short acceptance deadline. The scheduler MAY durably reserve capacity and create the attempt before delivery, but job execution MUST NOT start until the control plane durably records the runner's acceptance.
- **FR-12:** A runner MUST heartbeat at least every 20 seconds while connected. The server MUST consider it unavailable after 60 seconds without a valid heartbeat.
- **FR-13:** A reconnecting runner MUST report active attempt IDs and last acknowledged sequences before receiving new work.
- **FR-14:** Source bundles, artifacts, caches, and secrets MUST travel through authenticated, attempt-scoped transfer endpoints or protocol messages; permanent storage credentials MUST NOT be sent to a runner.
- **FR-15:** Secrets MUST be retained in runner memory only for the attempt, masked from logs, and removed from the workspace and process environment when the attempt ends.
- **FR-16:** Credential rotation MUST overlap old and new credentials for a bounded grace period and MUST allow an administrator to revoke all credentials immediately.

### UX requirements

- **UX-1:** Enrollment instructions MUST present a copyable command, token expiry, target server URL, and an explicit warning that the command contains a one-time secret.
- **UX-2:** The token MUST NOT be shown again after leaving the creation result.
- **UX-3:** Connection failures MUST identify whether the cause is DNS/TLS, authentication, revocation, version incompatibility, or server unavailability without printing credentials.
- **UX-4:** The web interface MUST show runner connectivity, software version, last heartbeat, active attempt, and credential age.

### Operational requirements

- **OR-1:** The protocol MUST work behind a reverse proxy that supports WebSocket upgrade and standard idle timeouts of at least 75 seconds.
- **OR-2:** Control messages MUST be bounded to 256 KiB. Bulk log and file data MUST use bounded chunks and backpressure.
- **OR-3:** The server MUST rate-limit enrollment and authentication failures per source address and runner identifier.
- **OR-4:** Runner loss MUST never leave a lease permanently active; the existing lease reconciler MUST make the attempt retryable or failed according to pipeline policy.
- **OR-5:** A rolling server upgrade MUST continue accepting the previous protocol version for at least one documented minor release.

## Proposed design

`Robine.Runners` is a clean-architecture context. Its facade exposes use cases with exact `defdelegate` functions. Domain modules own enrollment expiry, credential rotation, runner lifecycle, and protocol compatibility. Ports describe a runner registry, credential digester, clock, ID generator, and session publisher. PostgreSQL, Phoenix HTTP/WebSocket, and the standalone runner executable are adapters assembled in `Robine.Runtime.Dependencies`.

The first implementation uses an opaque random runner credential because it is practical for small self-hosted installations. The server stores only a digest. A later mTLS adapter may replace the credential proof without changing use cases or the protocol identity.

The connection lifecycle is:

1. An administrator creates a single-use enrollment token.
2. `POST /api/v1/runners/enroll` atomically consumes it and returns a runner ID plus credential once.
3. The runner connects to `/runner/socket`, authenticates with `x-robine-runner-id` and `x-robine-runner-credential` upgrade headers, and negotiates a protocol version.
4. The scheduler records a bounded attempt reservation, then the server offers work only after receiving current capabilities and reconciliation state.
5. Job acceptance durably advances the reserved attempt to preparation before execution begins; rejection or lease expiry closes the reservation as an infrastructure failure.
6. Attempt events are durably recorded before acknowledgement.

The WebSocket is a delivery adapter, not the source of truth. Disconnecting a socket does not itself decide an attempt outcome. Erlang Distribution is explicitly disabled for released single-node deployments and is not part of the runner protocol.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Enrollment token expired or already consumed | Enrollment returns a generic invalid-token response | Administrator creates a new token |
| Runner credential leaked | Authentication continues only until revocation is recorded | Administrator revokes the runner or rotates its credential |
| WebSocket disconnects during a job | Local process may continue for the lease window; no new job is offered | Runner reconnects and reconciles, or lease expiry triggers recovery |
| Duplicate attempt event | Server returns the prior acknowledgement without duplicating state | Runner advances from acknowledged sequence |
| Protocol versions do not overlap | Connection closes with a machine-readable incompatibility code | Upgrade runner or server according to compatibility documentation |
| Control plane restarts | Durable runner and attempt state is retained | Runner reconnects with bounded exponential backoff and jitter |
| Runner disappears permanently | Heartbeat and attempt lease expire | Reconciler marks the attempt lost and applies retry policy |

## Security and privacy

The enrollment token grants creation of one runner identity and is therefore an administrator secret. It MUST be redacted from URLs, logs, telemetry, crash reports, and shell tracing guidance. Runner credentials authenticate machines, not people, and MUST NOT authorize browser administration APIs. Revocation, enrollment, rotation, protocol authentication failure, and job assignment are audited. Capability input is untrusted and bounded. Job payloads are limited to trusted repositories under SEC-001 until stronger workload isolation is specified.

## Observability

Emit structured events and metrics for enrollment creation/consumption, authentication outcome, connected runners, connection duration, heartbeat lag, protocol version, message rejection, job-offer latency, acknowledgement lag, reconnect count, and lost leases. Logs correlate `runner_id`, `connection_id`, `job_id`, and `attempt_id`, but never include credentials, enrollment tokens, secrets, or raw job environment values.

## Acceptance criteria

- [x] An administrator can generate a token and enroll a fresh runner through documented commands in under five minutes.
- [x] Reusing or using an expired enrollment token fails and creates no runner.
- [x] Database inspection confirms that no plaintext enrollment or runner credential is retained.
- [x] A revoked runner is rejected on its next authenticated request or reconnect.
- [x] A runner behind an outbound-only firewall connects through a real reverse proxy and completes a Docker job.
- [x] Forced duplicate and reordered attempt events produce one valid durable attempt history.
- [x] A control-plane restart during execution reconciles the runner without assigning the job twice.
- [x] A client with no compatible protocol version receives an actionable incompatibility error.
- [x] Architecture tests prove that use cases depend only on domain, contracts, ports, and injected dependencies.

## Open questions

- None blocking. The opaque credential may later be replaced by mTLS through an adapter-compatible design.

## Out of scope / future work

- Certificate-backed runner identity and hardware-bound keys.
- End-to-end payload encryption independent of TLS termination.
- Multi-region control planes and relay servers.
- Micro-VM execution for untrusted workloads.
