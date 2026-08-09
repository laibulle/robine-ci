# Remote runner installation

Remote runners are a post-MVP feature under active development. They connect outbound to the Robine control plane over an authenticated Phoenix WebSocket; they never expose Erlang Distribution, EPMD, Docker, or an inbound runner port.

## Build the runner

From the matching Robine source release:

```sh
mix deps.get
mix robine.runner_release --output dist/runner
cd dist/runner
sha256sum --check RUNNER_SHA256SUMS
```

Install the versioned escript on a supported Linux worker with Erlang/OTP 29 and Docker Engine 29.x:

```sh
sudo install -m 0755 robine-runner-0.1.0.escript /usr/local/bin/robine-runner
sudo install -d -m 0700 /etc/robine-runner
```

The release artifact is verified by `mix robine.runner_release_smoke`. Do not combine a runner executable with native runtime files from another operating system or architecture once remote Docker execution is enabled.

## Enroll once

In Robine, sign in as an administrator, open **Administration**, and select **Generate enrollment command**. The displayed token expires after 15 minutes, can be consumed once, and is not recoverable from the database.

Run the displayed command on the trusted worker. The token is accepted only through `ROBINE_RUNNER_ENROLLMENT_TOKEN`; it is intentionally not accepted as a command-line option.

```sh
ROBINE_RUNNER_ENROLLMENT_TOKEN='rbe_…' \
  robine-runner enroll \
  --server 'https://ci.example.com' \
  --name 'builder-eu-1' \
  --config /etc/robine-runner/config.json
```

The resulting file contains the machine credential, is written atomically with mode `0600`, and must be readable only by the runner service account. Robine stores only a keyed digest of both enrollment and runner credentials. Reusing the enrollment command fails without revealing whether the token expired or was already consumed.

## Start the connection

```sh
robine-runner start --config /etc/robine-runner/config.json
```

Production server URLs must use HTTPS. Plain HTTP/WebSocket is accepted only for an explicit loopback URL during development. The runner validates the server certificate against the operating-system CA set, authenticates in WebSocket upgrade headers rather than URL parameters, negotiates protocol v1, heartbeats every 20 seconds, and reconnects with capped exponential backoff and full jitter.

The reverse proxy must support WebSocket upgrade for `/runner/socket/websocket`, preserve the `x-robine-runner-id` and `x-robine-runner-credential` request headers, allow at least 75 seconds of idle time, and enforce TLS. Attempt-scoped HTTP transfers use `Authorization: Bearer` plus the runner ID. Control frames are capped at 256 KiB.

## Recovery and revocation

- A reconnect reports active attempt IDs. The server returns the highest durably acknowledged sequence and identifies attempts whose lease was lost.
- Duplicate messages are safe. Reusing one message ID with different content is rejected.
- Credential rotation creates a new credential and accepts the prior credential for five minutes. This overlap supports orderly replacement without an avoidable disconnect.
- Revocation disables every credential immediately, pushes cancellation to an already connected runner, and rejects its next authenticated request or reconnect. Attempt leases remain protected by durable reconciliation if delivery is interrupted.
- Never paste a runner config, enrollment token, credential, job secret, or full environment into logs or support tickets.

The runner accepts durably acknowledged job offers, downloads attempt-scoped source and secrets, executes Docker jobs, streams redacted logs, supports cancellation, and transfers caches and artifacts through authenticated endpoints. Control frames are bounded, log delivery blocks on socket writes, file responses use 64 KiB chunks, and uploads stream into blob storage under a cumulative 100 MiB transfer limit. Archive validation and extraction still require a bounded in-memory representation on the runner.
