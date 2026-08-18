# Upgrade, backup, recovery, and rollback

## Backup contract

A recoverable backup is one consistent set containing the PostgreSQL dump, the complete blob root, every configured `ROBINE_CI_SECRET_KEYS` version, the active version number, GitHub App private key or encrypted credential bootstrap material, and deployment configuration. Store encryption keys separately from the database dump. Test restoration regularly; an untested backup is not a recovery plan.

1. Pause new dispatch and wait for active attempts to finish or cancel them explicitly.
2. Record the running version and migration level.
3. Create a PostgreSQL custom-format dump with `pg_dump --format=custom`.
4. Snapshot the blob root after the database dump window is quiescent.
5. Copy configuration and every encryption-key version into the protected backup system.
6. Resume dispatch and verify readiness.

## Forward upgrade

Read the release notes and Rust migration contract before upgrading. Verify `SHA256SUMS`, back up the instance, and retain the prior native bundle. Then:

1. Remove the instance from the reverse proxy and stop the old process so only one scheduler can own work.
2. Start the new `robine-server` with the existing `DATABASE_URL`, blob-store configuration, and every retained encryption-key version.
3. The server validates the historical cutover schema before binding its listener. An empty database receives the Rust-owned baseline; an older incomplete schema fails closed with `SchemaUpgradeRequired`.
4. Require HTTP 200 from `/health/live` and `/health/ready` before restoring proxy traffic.
5. Verify administrator health, storage namespace, provider permissions, metrics, one read-only historical pipeline, and one representative new pipeline.
6. Observe durable-job, outbox, runner-lease, and storage reconciliation metrics through at least one reconciliation interval.

Never run the old and new schedulers concurrently. Never remove an old encryption key merely because a deploy succeeded; remove it only after rotation reports zero remaining values and a restored backup has been tested.

## Recovery

Provision a host with the same supported OS, architecture, PostgreSQL, and Docker versions. Verify the native bundle, restore PostgreSQL and the blob root, restore configuration and all key versions, then start Robine with dispatch initially disabled at the infrastructure boundary. Check readiness, storage reconciliation, outbox health, expired leases, and labeled Docker orphans before allowing new jobs.

## Rollback

Database migrations are forward-only in production. Never reverse schema changes in place. If the new release fails before receiving traffic and its release notes explicitly declare the schema backward-compatible, stop it and restart the prior native artifact against that schema. Otherwise restore the pre-upgrade PostgreSQL dump, blob snapshot, configuration, and encryption keys as one consistent unit, start the prior artifact, and verify both health probes before reopening traffic.

Rollback rehearsal uses a disposable restored environment: start the candidate, verify probes and one pipeline, stop it, restore the recorded backup, start the prior artifact, and compare retained pipeline/artifact counts plus representative digests. Record timestamps proving the candidate and prior schedulers never overlap.

Record the incident, failed version, restored backup identifier, migration versions, and integrity checks. Replaying outbox or webhook work manually is a last resort and must use existing idempotency keys.
