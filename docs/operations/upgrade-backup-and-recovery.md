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

Read release notes and migration files before upgrading. Verify the release checksum, back up the instance, stop traffic to the old release, run `bin/robine eval 'Robine.Runtime.Release.migrate()'`, start the new version, and verify readiness, administrator health, GitHub permissions, metrics, and one representative pipeline. Never remove an old encryption key merely because a deploy succeeded; remove it only after rotation reports zero remaining values and a restored backup has been tested.

## Recovery

Provision a host with the same supported runtime and Docker versions. Restore PostgreSQL and the blob root, restore configuration and all key versions, run migrations for the selected application version, then start Robine with dispatch initially disabled at the infrastructure boundary. Check storage reconciliation, outbox health, expired leases, and labeled Docker orphans before allowing new jobs.

## Rollback

Database migrations are forward-only in production. Do not run automatic `mix ecto.rollback` against an upgraded live instance: later code may already have written data the old schema cannot interpret. If the new release fails before it receives traffic and its migrations are documented as backward-compatible, restart the previous application artifact against the migrated schema. Otherwise restore the pre-upgrade PostgreSQL/blob/config backup as one unit, start the previous artifact, and verify readiness before reopening traffic.

Record the incident, failed version, restored backup identifier, migration versions, and integrity checks. Replaying outbox or webhook work manually is a last resort and must use existing idempotency keys.
