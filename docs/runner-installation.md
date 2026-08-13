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

## Native macOS runner

Build the runner on the target Mac so its Erlang/OTP and Exile runtime files match that operating system and architecture. Install current project-supported Erlang/OTP and Elixir versions, Xcode Command Line Tools, and any project-specific Apple SDKs first. The provided launchd plist invokes the escript through `~/.local/bin/mise exec`, so install the runtimes with mise at that location or adapt `ProgramArguments` to an equivalent pinned runtime. Docker Desktop is not used by native jobs.

Create a dedicated standard macOS account such as `robine-runner`. It must not be an administrator and must not own personal keychains, SSH keys, cloud credentials, or unrelated source trees. Log in as that account to build, install, and enroll:

```sh
mise use --global erlang@29.0.5 elixir@1.20.3-otp-29
mise exec -- mix deps.get
mise exec -- mix robine.runner_release --output dist/runner
install -m 0755 dist/runner/robine-runner-0.2.0.escript "$HOME/bin/robine-runner"
mkdir -m 0700 -p "$HOME/.config/robine-runner"
ROBINE_RUNNER_ENROLLMENT_TOKEN='replace-once' "$HOME/bin/robine-runner" enroll \
  --server https://ci.example.com \
  --name mac-mini-arm64 \
  --config "$HOME/.config/robine-runner/config.json"
```

On Darwin the runner automatically announces `macos`, normalized `arm64` or `amd64`, and `native`; it does not announce `docker`. A native job must opt in explicitly:

```yaml
jobs:
  macos-test:
    runs-on: [macos, arm64]
    image: native
    steps:
      - name: Test on macOS
        run: swift test
```

The `image` field remains required by workflow schema v1 but is not used by native execution. Native execution is not a sandbox and is supported only for trusted repositories. Cache and artifact built-ins use the same attempt-scoped server transfers as Docker jobs. The initial native executor rejects service containers explicitly.

Install `docs/launchd/com.robine.runner.plist` as the runner account at `~/Library/LaunchAgents/com.robine.runner.plist`, then load it:

```sh
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/RobineRunner"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.robine.runner.plist"
launchctl kickstart -k "gui/$(id -u)/com.robine.runner"
launchctl print "gui/$(id -u)/com.robine.runner"
```

Before installation, replace `__ROBINE_RUNNER_HOME__` in the plist with the absolute home directory of the dedicated account. Logs are retained under `~/Library/Logs/RobineRunner/`; the credential remains in the mode-`0600` config file and never belongs in the plist.

For upgrades, build the new artifact on the same target architecture, stop the service, atomically replace `~/bin/robine-runner`, and kickstart it again. To remove the service, run `launchctl bootout "gui/$(id -u)/com.robine.runner"`, remove the plist and executable, revoke the runner in Robine, and only then remove its private config and logs.
