# Fresh-host first-pipeline protocol

## Purpose

Prove that a developer unfamiliar with Robine can start from an empty supported host and reach a successful Robine GitHub check in no more than ten measured minutes. External approval wait and container-image download time are excluded; ordinary reading, typing, configuration, startup, and troubleshooting time are not.

## Preconditions

- Use a newly provisioned Ubuntu Server 24.04 or 26.04 LTS host on x86-64 or ARM64.
- The operator has not installed or operated Robine before and receives no coaching beyond published documentation.
- Docker Engine 29.x and Docker Compose v2 are the only preinstalled Robine prerequisites.
- Use the published server artifact and manifest, not a source worktree or a preconfigured image.
- Use a trusted GitHub repository with a known minimal `.robine-ci/workflows/ci.yml` and no warmed Robine images.
- Arrange GitHub organization approval in advance when possible. If approval must occur during the session, record the exact wait interval.

## Procedure

1. Record `started_at` immediately before the operator opens the installation documentation.
2. Let the operator verify the artifact, configure the instance, migrate, start Robine, complete browser setup, configure the GitHub App, select the repository, and push the tested workflow without coaching.
3. Record each external approval or image-download interval at the moment it begins and ends. Intervals must not overlap and must remain inside the measured session.
4. Stop at `green_check_at` when GitHub shows the successful Robine check for the exact pushed commit.
5. Copy the check-run URL, full 40-character commit SHA, repository slug, and SHA-256 digest of the published `SHA256SUMS` file into a copy of `first-pipeline.template.json`.
6. Run the acceptance verifier with the retained `SHA256SUMS` file. It verifies the recorded digest against the actual manifest, subtracts only the allowlisted intervals, and rejects a measured duration above 600 seconds.
7. A release reviewer opens the recorded GitHub URL, confirms the repository/commit/check conclusion, and retains the evidence with the release record.

Restart the session from a fresh host if the operator receives implementation-specific assistance or if timing evidence is incomplete. Failures are product findings: record them, fix or re-specify them, and run a new session rather than editing timestamps.

Robine's own `.robine-ci/workflows/ci.yml` is the maintained reference workflow. It is exercised locally through the released CLI before an external session, but that local baseline cannot substitute for the fresh-host GitHub evidence required here.
