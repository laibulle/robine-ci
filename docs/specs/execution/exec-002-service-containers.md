# EXEC-002 — Service containers

## Status

- **State:** Shipped
- **Owner:** Execution
- **Target:** Post-MVP
- **Last updated:** 2026-08-09

## Summary

Jobs can declare bounded Docker service containers such as PostgreSQL or Redis. Each attempt receives a private network, deterministic service DNS names, readiness checks, redacted diagnostics, and complete cleanup with identical CI and local-run semantics.

## Problem

Integration tests commonly require databases, queues, and other network services. Requiring developers to pre-provision them outside Robine makes jobs non-reproducible, complicates remote runners, and breaks the promise that the command shown in the UI behaves like local CI execution.

## Goals

- Start declared services before the first job step and make them reachable by stable names.
- Preserve the existing trusted-repository boundary without publishing service ports to the host.
- Bound service count, configuration, startup time, resource use, logs, and cleanup.
- Keep local, control-plane Docker, and remote-runner execution semantics identical.

## Non-goals

- Docker Compose compatibility or arbitrary Compose files.
- Host-port publication, arbitrary privileged services, host networking, devices, host paths, or Docker socket access.
- Kubernetes pods, sidecar injection, service discovery outside one job attempt, or cross-job services.
- Claiming Docker isolates hostile repository code.

## Users and use cases

### Primary user

A developer or startup team running trusted integration tests against disposable infrastructure on local or remote Docker runners.

### Use cases

1. Declare PostgreSQL and Redis beside a test job.
2. Wait for a bounded TCP readiness check before running migrations or tests.
3. Inject a declared secret into a service without persisting or displaying its value.
4. Diagnose image, startup, readiness, or early-exit failures from the job page.
5. Cancel, time out, or interrupt the job and leave no service container or network behind.

## Requirements

### Functional requirements

- **FR-1:** A job MAY declare `services` as a map of one to eight service definitions; service identifiers MUST follow job-identifier rules and be unique within the job.
- **FR-2:** Each service MUST declare an image and MAY declare a bounded container user, literal environment variables, a bounded command vector, declared-secret environment mappings, and one TCP readiness port.
- **FR-3:** Every attempt with services MUST receive a fresh user-defined bridge network. The job container and only that attempt's service containers MUST attach to it.
- **FR-4:** A service MUST be reachable from the job container at its exact service identifier. Robine MUST NOT publish a service port on a host interface.
- **FR-5:** All service images MUST be acquired and containers started before job steps begin. Services MUST remain available until job execution ends or cancellation/timeout begins cleanup.
- **FR-6:** A configured readiness check MUST succeed before the first step. A service without a check is ready when Docker reports it running after a bounded stabilization interval.
- **FR-7:** Service failure during preparation MUST fail the attempt as `service_unavailable`; service exit after preparation MUST fail the running job at the next bounded liveness observation.
- **FR-8:** Service environment secret mappings MUST reference names declared by the job. Plaintext values MUST exist only in the in-memory execution contract and Docker create request.
- **FR-9:** Cancellation, timeout, normal completion, runner restart, and preparation failure MUST remove all attempt-owned job/service containers, volumes, and networks idempotently.
- **FR-10:** CLI, local control-plane execution, and remote-runner execution MUST consume the same normalized service contract.
- **FR-11:** A service MAY request `privileged: true` only when its identifier is exactly `docker` and its image is an official `docker:*dind*` image. This exception MUST NOT make the job container privileged or expose the runner host Docker socket.
- **FR-12:** A privileged DinD service MUST remain attempt-scoped, use the attempt network, inherit resource ceilings and ownership labels, and be removed by normal cleanup and orphan reconciliation.

### UX requirements

- **UX-1:** Workflow validation MUST identify the exact service and invalid image, identifier, environment key, command, secret mapping, port, or timeout.
- **UX-2:** Job progress MUST distinguish service image acquisition, container start, readiness wait, early exit, and cleanup.
- **UX-3:** A readiness failure MUST name the service and elapsed timeout and expose only a bounded, redacted diagnostic tail.
- **UX-4:** Documentation MUST show PostgreSQL and Redis examples and explain that services are addressed by DNS name rather than `localhost`.

### Operational requirements

- **OR-1:** Service count MUST be at most eight; environment entries at most 64; command arguments at most 32 and 4 KiB each; readiness ports 1 through 65535; startup timeout 1 through 120 seconds.
- **OR-2:** Readiness polling MUST use capped intervals, a total deadline, and no unbounded task, socket, response, or log accumulation.
- **OR-3:** Ordinary service containers MUST inherit dropped capabilities and `no-new-privileges`; all services, including the narrowly allowed DinD service, inherit process/memory/CPU ceilings and attempt ownership labels. They MUST NOT receive the job workspace by default.
- **OR-4:** Preparation diagnostics MAY retain at most 64 KiB per failed service and MUST pass through the same streaming secret redactor before persistence.
- **OR-5:** Orphan reconciliation MUST identify attempt networks and service containers exclusively through Robine-owned labels and MUST never remove unlabeled resources.

## Proposed design

Workflow v1 gains an optional `services` map under each job:

```yaml
jobs:
  test:
    image: hexpm/elixir:1.20.0-erlang-29.0
    secrets: [TEST_DB_PASSWORD]
    services:
      postgres:
        image: postgres:18-alpine
        user: postgres
        env:
          POSTGRES_USER: robine
          POSTGRES_DB: app_test
        secret-env:
          POSTGRES_PASSWORD: TEST_DB_PASSWORD
        readiness:
          tcp: 5432
          timeout: 45s
    steps:
      - run: mix test
```

`Robine.Workflows.Domain.Service` owns normalized workflow policy. `Robine.Execution.Contracts.Service` is embedded in the versioned `Specification`; it contains resolved service secret values only at execution time and excludes them from inspection. The existing workflow and execution facades remain the entry points.

The Docker adapter creates one labeled network named from the opaque attempt identifier, starts labeled service containers with network aliases, observes readiness from the runner host against the container's network address, then starts the job container on the same network. It never binds `-p`/`--publish`. Cleanup removes the job container, service containers, workspace volume, and finally the network. Restart reconciliation extends the existing label-owned resource scan to networks and services.

TCP readiness is intentionally the first contract. Arbitrary shell probes would require every image to contain a shell and would execute another repository-controlled language; HTTP semantics and Docker-native health checks can be added later without changing service identity or lifecycle.

Docker-dependent jobs use an isolated daemon rather than the runner host socket:

```yaml
env:
  DOCKER_HOST: tcp://docker:2375
  DOCKER_TLS_CERTDIR: ""
services:
  docker:
    image: docker:28-dind
    privileged: true
    env: {DOCKER_TLS_CERTDIR: ""}
    command: ["--tls=false"]
    readiness: {tcp: 2375, timeout: 60s}
```

The job image must contain the Docker CLI. The daemon is reachable only over the private attempt network and is destroyed with that attempt.

A pinned Redis service uses the same contract:

```yaml
services:
  redis:
    image: redis@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    user: redis
    readiness: {tcp: 6379, timeout: 15s}
```

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Service image cannot be acquired | Preparation fails naming the service and image class | Fix registry/image access and retry |
| Container exits before readiness | Attempt fails as `service_unavailable` with redacted tail | Fix service configuration and retry |
| TCP port never becomes ready | Attempt fails after the declared timeout | Correct port/startup configuration or increase timeout |
| Service exits during steps | Job fails as an infrastructure service loss | Inspect service diagnostic and retry after correction |
| Docker disappears during cleanup | Durable result remains and orphan cleanup is retried | Restore Docker; reconciler removes labeled resources |
| Network name collision | Opaque attempt ownership prevents adoption; preparation fails safely | Reconcile the prior labeled attempt resource and retry |

## Security and privacy

Services execute trusted repository configuration and share an isolated attempt network with the job, so they are not a security boundary from that job. They receive no Docker socket, host mount, job workspace, unrelated secret, or host-published port. Secret values are redacted from service logs, exceptions, telemetry, inspect output, and persisted execution metadata. Image registry credentials remain runner-owned.

## Observability

Record service count, image-acquisition duration, startup/readiness duration, readiness outcome, early exits, cleanup failures, and orphan counts with bounded service identifiers. Structured events correlate pipeline, job, attempt, runner, and service identifier without environment values, commands, container IPs, or secret material.

## Acceptance criteria

- [x] PostgreSQL and Redis fixtures become reachable by service DNS name in both local CLI and remote-runner jobs.
- [x] No service port is bound on the Docker host and no service receives the workspace or Docker socket.
- [x] Invalid service configuration produces stable source-located CLI/server diagnostics.
- [x] A readiness timeout and an early container exit fail before the first user command with a bounded redacted diagnostic.
- [x] Cancellation and forced process interruption leave no labeled job container, service container, volume, or network after reconciliation.
- [x] Service secret values are absent from persisted specifications, logs, telemetry, exception inspection, and runner control messages.
- [x] Architecture tests preserve the use-case, port, adapter, and facade dependency rules.

## Open questions

None blocking. TCP readiness, eight services, no host publication, and no shared workspace are deliberate first-release constraints.

## Out of scope / future work

- HTTP readiness, Docker-native health checks, service volumes, host port publication, dependency ordering, reusable service bundles, and non-Docker runtimes.
