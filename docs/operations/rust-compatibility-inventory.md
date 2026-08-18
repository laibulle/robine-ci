# Rust cutover compatibility inventory

This inventory compares the final Phoenix router witness (`263bc83`) with the authoritative Actix registration in `robine-server::configure`. Rust owns every production route from that witness; development-only LiveDashboard and mailbox routes are intentionally absent from production artifacts.

| Surface | Preserved paths | Rust evidence |
|---|---|---|
| Browser identity | `GET /`, `GET/POST /sign-in`, `DELETE /sign-out`, `GET/POST /setup`, `GET /auth/oidc`, `GET /auth/oidc/callback` | Server identity, bootstrap, OIDC, cookie, CSRF, and non-disclosure tests |
| Pipeline browser | `GET /pipelines`, `/pipelines/:id`, `/pipelines/:id/workflow`, `/pipelines/:id/jobs/:job_id`, plus log and artifact downloads | Authenticated browser projection and download tests |
| Repository browser | `GET /repositories`, `/repositories/:id`, `/repositories/:id/secrets`, `/build-information` | Repository workflow/manual/schedule and write-only secret tests |
| Administration | `GET /admin` | Administrator role and last-admin tests |
| Source-control ingress | `POST /api/github/webhooks`, `/api/gitlab/webhooks`, `/api/forgejo/webhooks` | Raw-body authentication, size, deduplication, normalization, and exact-SHA worker tests |
| Runner transfer | `POST /api/v1/runners/enroll`; `GET` source/secrets/cache/artifacts; `PUT` cache/artifacts under `/api/v1/runners/attempts/:attempt_id` | Enrollment, ownership, no-store, archive-bound, digest, and transfer tests |
| Runner socket | `GET /runner/socket/websocket` (Phoenix socket transport path) | Authenticated protocol tests and a real TCP reverse-proxy upgrade/hello/welcome test |
| Operations | `GET /health/live`, `/health/ready`, `/metrics`, and build/coverage badge routes | Probe, token, database-failure, and badge projection tests |

Actix additionally exposes versioned JSON lifecycle, administration, and remote-runner polling endpoints used by the native CLI and runner. These are Rust-owned extensions rather than compatibility omissions. The release gate executes strict Clippy, the complete workspace suite, all PostgreSQL scenarios, dependency policy, native process smoke, and package checksum/version validation.

The final historical PostgreSQL schema is exercised directly before every cutover release. Fresh installations apply `0001_baseline.sql` followed by idempotent forward migration `0002_native_scheduler_metrics.sql`; existing installations apply only the forward migration while holding the bootstrap advisory lock.
