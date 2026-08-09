# Supported platforms, defaults, and limitations

The MVP server supports Ubuntu Server 24.04 and 26.04 LTS on x86-64 or ARM64, Erlang/OTP 29, Elixir 1.20, Docker Engine 29.x, Docker Compose v2, and PostgreSQL 17 or 18. The CLI is an escript for Linux, macOS, and Windows with a compatible Erlang runtime.

Defaults are 2 vCPU, 4 GiB RAM, 512 processes, 20-minute job timeout, 60-second attempt lease, 20-second heartbeat, five-second cancellation grace, and global/repository concurrency controlled by operator configuration. Runner admission stops below 2 GiB free or above 95% filesystem use. Logs retain for 30 days. Logical storage quotas are 50 GiB per instance and 10 GiB per repository; artifact/cache expiry is declared by the workflow and unreferenced blobs have a one-hour GC grace.

Only trusted GitHub.com repositories are supported. The MVP has one local Docker runner host, local blob storage, YAML schema v1, one OIDC provider, global roles, and no repository-specific ACLs. It does not support remote runners, untrusted forks, micro-VM isolation, service containers, matrices, reusable workflows, scheduled/manual inputs, S3, GitLab/Forgejo, deployment environments, approvals, SAML/LDAP/SCIM, or managed-cloud operation.

Log search covers only the bounded visible window and raw download is deferred. Docker image tags are allowed but mutable; use digests for reproducibility. Root images remain allowed for trusted code with dropped capabilities and `no-new-privileges`. An unavailable optional GitHub/OIDC integration degrades administrator health but does not make the durable control plane unready.
