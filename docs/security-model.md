# Security model

Robine's MVP assumes repository code and maintainers are trusted. Docker containers reduce accidental interference but are not a security boundary against hostile code. Fork pull requests are ignored, secrets are never delivered to forks, and workflows cannot request privileged mode, host networking, devices, host paths, or the Docker socket.

Local passwords use Argon2id. OIDC uses Authorization Code with PKCE, state, nonce, issuer, audience, signature, and verified-email checks. A local administrator account remains the recovery path. Global roles are viewer, maintainer, and administrator; every route and LiveView event rechecks authorization on the server.

Secrets use versioned AES-256-GCM envelopes with a unique nonce and authenticated scope metadata. Master keys remain outside PostgreSQL. Secret reads are internal and explicit; UI/API responses expose metadata only. Runner output is demand-driven, independently redacted on stdout and stderr before persistence, and then ANSI-sanitized before HTML rendering.

GitHub webhook signatures are verified before durable ingestion. Delivery IDs and deterministic pipeline idempotency keys make retries safe. GitHub App permissions are limited to metadata read, contents write for idempotent tag-release publication, and checks write. Structured logs and metrics accept bounded metadata only and reject credentials, payloads, URLs, repository names, commit SHAs, commands, and output.

Public liveness/readiness responses expose no dependency inventory. Detailed health requires an administrator. Metrics are disabled unless a Bearer token is configured and must be exposed only through TLS and network controls. Report vulnerabilities privately to the maintainers; do not include production secrets or exploit public instances during disclosure.
