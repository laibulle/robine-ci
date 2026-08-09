# Monitoring and troubleshooting

This runbook defines the initial operator alerts for a self-hosted Robine instance. Tune warning durations to the instance workload, but keep critical conditions strict enough to detect stuck durable work before retention or lease recovery hides the original symptom.

## Prometheus setup

Set a long random `ROBINE_METRICS_TOKEN`, restart Robine, and scrape `GET /metrics` with the same Bearer token over TLS. When the variable is absent the route returns HTTP 404; missing or invalid credentials return HTTP 401. Never place the token in a URL, label, dashboard variable, or alert annotation.

Example scrape configuration:

```yaml
scrape_configs:
  - job_name: robine
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /run/secrets/robine_metrics_token
    static_configs:
      - targets: [ci.example.com]
```

The exporter normalizes dots to underscores. Counters keep their declared `*_count` name, gauges expose their direct name, and distributions add Prometheus bucket, sum, and count series.

## Initial alerts

| Alert | PromQL starting point | Default trigger | First operator action |
|---|---|---|---|
| Queue backlog | `max_over_time(robine_queue_oldest_age[10m]) > 300` | Oldest runnable work exceeds 5 minutes for 10 minutes | Check active attempts, configured concurrency, Docker health, and disk admission |
| Runner loss | `increase(robine_runner_exit_count{reason="runner_lost"}[10m]) > 0` | Any lost runner in 10 minutes | Inspect correlated attempt events, Docker daemon health, leases, and orphan reconciliation |
| Storage pressure | `max_over_time(robine_storage_pressure_used_percent{status!="healthy"}[10m]) >= 95` | Non-healthy storage at or above 95% for 10 minutes | Stop adding capacity-heavy work, inspect quotas, then run retention and reconciliation |
| Outbox failure | `increase(robine_outbox_delivery_count{outcome!="ok"}[15m]) > 3` | More than 3 failed deliveries in 15 minutes | Inspect dead-letter health, provider availability, and the correlation ID; do not replay blindly |
| GitHub degraded | `increase(robine_github_api_request_count{outcome!="ok"}[10m]) > 5` | More than 5 failed API calls in 10 minutes | Check integration health, App permissions, rate-limit gauges, and GitHub status |
| Authentication anomaly | `increase(robine_identity_login_count{outcome!="ok"}[10m]) > 20` | More than 20 failed logins in 10 minutes | Check source/network controls and OIDC health; rotate credentials only if compromise evidence exists |

Also page when `GET /health/ready` fails continuously for five minutes. Liveness failure means the web process itself is unavailable; readiness failure identifies a required PostgreSQL, durable-queue, or blob-storage dependency. Docker, GitHub, and OIDC degradation appears in administrator health without making the control plane unready.

## Diagnosis order

1. Open the administrator health page and determine whether the failing component is required or optional.
2. Locate a bounded correlation identifier in structured logs and follow it across webhook delivery, pipeline, job, attempt, runner, and provider events.
3. Compare counters with state gauges. A rising failure counter with no stuck state may be transient; a stable queue age or expired lease gauge indicates recovery is not progressing.
4. Restore the dependency before replaying work. Robine deduplicates durable events, but manual repeated replay can amplify a provider or capacity outage.
5. Confirm recovery through both the health projection and a falling queue/lease gauge. Preserve relevant logs before changing retention or deleting resources.

## Secret-safety checks

Metrics labels are restricted to fixed enums such as status, phase, outcome, role, method, and operation. Repository names, commit SHAs, users, URLs, error messages, webhook bodies, commands, log output, and credentials are forbidden. If a dashboard or alert displays one of those values, treat it as an instrumentation defect and disable that panel until corrected.
