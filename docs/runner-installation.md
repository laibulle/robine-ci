# Remote runner installation

The standalone runner is a native Rust executable. It makes outbound HTTPS requests to the Robine control plane and requires no inbound port, Erlang runtime, or access to the control-plane database.

## Build and verify

From the matching source release:

```sh
ROBINE_DOCKER_CLI=/usr/bin/docker cargo run -p robine-package -- --output dist
cd dist/runner
sha256sum --check SHA256SUMS
./robine-runner --version
```

Install it on a trusted Linux worker with Docker Engine 29.x:

```sh
sudo install -m 0755 robine-runner /usr/local/bin/robine-runner
sudo install -d -m 0700 /etc/robine-runner
```

Release artifacts are platform-specific native binaries. Do not copy a binary between operating systems or CPU architectures.

## Enroll once

As an administrator, create a runner enrollment token from the runner-fleet page. The token expires after 15 minutes, can be consumed once, and is never stored in recoverable form.

Pass it only through the environment:

```sh
ROBINE_RUNNER_ENROLLMENT_TOKEN='rbe_…' \
  robine-runner enroll \
  --server 'https://ci.example.com' \
  --name 'builder-eu-1' \
  --config /etc/robine-runner/config.json
```

The runner writes the credential atomically to a mode-`0600` file. Enrollment refuses to replace an existing configuration unless `--force` is explicitly supplied. Never paste this file, an enrollment token, a job secret, or a full environment into logs or support tickets.

## Start the runner

```sh
robine-runner start --config /etc/robine-runner/config.json
```

The current native runner opens an authenticated HTTPS session, heartbeats every ten seconds, polls durable offers and cancellation notifications, and accepts attempt-scoped work. It downloads bounded exact-revision source and selected secrets, executes Docker jobs, streams ordered redacted output, and reports the terminal result. Configure a service manager to restart it after transient network or host failures.

Production server URLs must use HTTPS. Plain HTTP is accepted only on an explicit loopback address for development. The reverse proxy must preserve ordinary `Authorization` headers and allow the runner API under `/api/v1/runners`; no WebSocket upgrade is required by this runner version.

## Recovery and revocation

- Duplicate and replayed attempt messages are checked against durable identities and ordered sequences.
- Credential rotation permits the prior credential for a bounded five-minute overlap.
- Revocation immediately rejects new authenticated requests; durable lease reconciliation recovers interrupted attempts.
- Keep Docker and the runner service account isolated from unrelated credentials and source trees.

To upgrade, verify the new component manifest, stop the service, atomically replace the executable, check `robine-runner --version`, and restart it. Revoke the runner in Robine before permanently deleting its private configuration.
