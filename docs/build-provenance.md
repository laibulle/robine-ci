# Embedding Robine CI build provenance

Robine CI injects authoritative, non-secret provenance into every CI job. Applications can capture these values while compiling a release and display them later without contacting Robine or their source-control provider.

| Variable | Meaning |
|---|---|
| `ROBINE_BUILD_COMMIT_SHA` | Exact immutable 40-character commit SHA executed by the pipeline |
| `ROBINE_BUILD_REF_NAME` | Source tag, branch, or pull-request target retained by the pipeline; empty for legacy or synthetic runs |
| `ROBINE_BUILD_REF_TYPE` | `tag`, `branch`, `pull_request`, or `unknown` |
| `ROBINE_BUILD_TIMESTAMP` | ISO 8601 UTC pipeline execution start, falling back to immutable pipeline creation time |
| `ROBINE_BUILD_PIPELINE_ID` | Stable Robine pipeline identifier |
| `ROBINE_BUILD_TRIGGER` | Normalized trigger such as `tag`, `push`, `pull_request`, `schedule`, or `workflow_dispatch` |

These names are reserved. A workflow that attempts to set one is rejected, and the runner overlays the authoritative values at its execution boundary. They contain no credentials, repository contents, or mutable provider URLs.

## Elixir releases

Read the variables into module attributes so they are stored in the compiled BEAM files rather than expected at runtime:

```elixir
defmodule MyApp.BuildInfo do
  @commit System.get_env("ROBINE_BUILD_COMMIT_SHA", "development")
  @ref System.get_env("ROBINE_BUILD_REF_NAME", "local")
  @built_at System.get_env("ROBINE_BUILD_TIMESTAMP", "unknown")

  def current, do: %{commit: @commit, ref: @ref, built_at: @built_at}
end
```

Robine itself follows this pattern in `Robine.BuildInfo`. Its authenticated product shell shows a small footer linking to `/build-information`, where operators can retrieve the complete provenance for support and deployment verification.

## JavaScript applications

Copy the CI variables into generated build configuration or bundler-defined constants. Do not read them only from `process.env` in the deployed server unless the deployment deliberately carries them forward.

```javascript
export const buildInfo = Object.freeze({
  commit: process.env.ROBINE_BUILD_COMMIT_SHA ?? "development",
  ref: process.env.ROBINE_BUILD_REF_NAME ?? "local",
  builtAt: process.env.ROBINE_BUILD_TIMESTAMP ?? "unknown",
})
```

## Go applications

Declare string variables and populate them from the same contract using linker flags in the workflow:

```sh
go build -ldflags "-X main.commit=$ROBINE_BUILD_COMMIT_SHA -X main.ref=$ROBINE_BUILD_REF_NAME -X main.builtAt=$ROBINE_BUILD_TIMESTAMP" ./cmd/server
```

The application owns the presentation. A discreet support footer plus a detailed build-information page is recommended for operator-facing products; public products may prefer an About page or authenticated diagnostics endpoint.
