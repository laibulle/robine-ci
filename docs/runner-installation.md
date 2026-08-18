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

The runner opens an authenticated HTTPS session, heartbeats every ten seconds, polls durable offers and cancellation notifications, and accepts attempt-scoped work. It downloads bounded exact-revision source and selected secrets, executes Docker jobs on Linux or trusted native processes on macOS, streams ordered redacted output, and reports the terminal result. Configure a service manager to restart it after transient network or host failures.

## Dedicated macOS native runner

Build `robine-runner` on the target Mac with the supported Rust toolchain and verify its checksum before installation. The Darwin binary automatically advertises `os=macos`, normalized `arm64` or `amd64`, `native=true`, and `docker=false`; only workflows explicitly requesting matching native labels can be scheduled there. It executes trusted commands directly and therefore requires a dedicated non-administrator account with no personal keychain, unrelated credentials, or interactive administrator access.

```sh
install -d -m 0700 "$HOME/bin" "$HOME/.config/robine-runner" "$HOME/Library/Logs/RobineRunner" "$HOME/Library/LaunchAgents"
install -m 0755 robine-runner "$HOME/bin/robine-runner"
sed "s|__ROBINE_RUNNER_HOME__|$HOME|g" docs/launchd/com.robine.runner.plist > "$HOME/Library/LaunchAgents/com.robine.runner.plist"
plutil -lint "$HOME/Library/LaunchAgents/com.robine.runner.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.robine.runner.plist"
launchctl kickstart -k "gui/$(id -u)/com.robine.runner"
```

Enroll before starting launchd, using `$HOME/.config/robine-runner/config.json`. Native attempts receive a fresh private temporary workspace and a cleared environment containing only the bounded system path, attempt-local `HOME`/`TMPDIR`, workflow variables, build provenance, and declared secrets. Service containers fail preparation explicitly. Cache and artifact transfers retain the same authenticated attempt scope and safe-archive validation as Docker execution.

Inspect and troubleshoot without printing the credential file:

```sh
launchctl print "gui/$(id -u)/com.robine.runner"
tail -n 200 "$HOME/Library/Logs/RobineRunner/stderr.log"
```

To upgrade, verify the new target-native manifest, stop the job with `launchctl bootout`, atomically replace `$HOME/bin/robine-runner`, verify `--version`, then bootstrap it again. To remove it permanently, boot it out, revoke the runner in Robine, and delete only its plist, executable, private configuration, and dedicated logs.

Production server URLs must use HTTPS. Plain HTTP is accepted only on an explicit loopback address for development. The reverse proxy must preserve ordinary `Authorization` headers and allow the runner API under `/api/v1/runners`; no WebSocket upgrade is required by this runner version.

## Recovery and revocation

- Duplicate and replayed attempt messages are checked against durable identities and ordered sequences.
- Credential rotation permits the prior credential for a bounded five-minute overlap.
- Revocation immediately rejects new authenticated requests; durable lease reconciliation recovers interrupted attempts.
- Keep Docker and the runner service account isolated from unrelated credentials and source trees.

To upgrade, verify the new component manifest, stop the service, atomically replace the executable, check `robine-runner --version`, and restart it. Revoke the runner in Robine before permanently deleting its private configuration.
