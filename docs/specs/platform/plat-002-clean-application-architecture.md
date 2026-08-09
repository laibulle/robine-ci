# PLAT-002 — Clean application architecture

## Status

- **State:** Accepted
- **Owner:** Platform
- **Target:** MVP
- **Last updated:** 2026-08-09

## Summary

Robine organizes each bounded context around pure domain code, explicit application use cases, outbound ports, infrastructure adapters, and one public facade. Phoenix, Oban, GitHub, PostgreSQL, Docker, and the CLI are delivery or infrastructure details: they invoke the same use cases and do not contain business rules. Each context facade exposes its supported use cases through explicit `defdelegate` declarations.

## Problem

A CI product touches several volatile systems: source-control providers, Docker, storage, databases, background jobs, HTTP, LiveView, and eventually remote runners. If business decisions live inside controllers, LiveViews, Ecto schemas, workers, or adapter callbacks, behavior becomes difficult to test, reuse from the CLI, and evolve independently of those technologies.

Clean architecture can also become harmful when applied mechanically. A port for every function, generic repositories, or layers that merely rename data create ceremony without protecting a meaningful boundary. Robine needs enforceable dependency rules and explicit use cases, not abstraction for its own sake.

## Goals

- Express every state-changing application operation as a named use case.
- Keep domain rules independent from Phoenix, Ecto, Oban, Docker, GitHub, and filesystem APIs.
- Allow HTTP, LiveView, background workers, and the CLI to invoke the same application behavior.
- Replace infrastructure in tests through explicit ports and dependency injection.
- Provide one discoverable, stable public facade per bounded context.
- Make architectural violations detectable by automated tests or static checks.

## Non-goals

- A module, behaviour, command object, or DTO for every function call.
- Hiding ordinary Elixir data structures behind object-oriented patterns.
- A generic repository abstraction shared by unrelated bounded contexts.
- Runtime dependency injection containers or global service locators.
- Preventing all compile-time dependencies between bounded contexts.
- Splitting every architectural layer into a separate OTP application in the MVP.

## Users and use cases

### Primary user

A Robine contributor implementing a feature that must be callable from more than one delivery mechanism and testable without live infrastructure.

### Use cases

1. Add a pipeline operation once and invoke it from LiveView, a webhook handler, or a background worker.
2. Test scheduling rules using deterministic in-memory or fake port implementations.
3. Replace the local Docker adapter with a future remote runner adapter.
4. Discover a bounded context's supported API from its facade.

## Requirements

### Functional requirements

- **FR-1:** The codebase MUST be divided into bounded contexts aligned with product language, initially including `Pipelines`, `Workflows`, `Repositories`, `Execution`, `Identity`, `Secrets`, and `Storage`.
- **FR-2:** Every bounded context MUST expose exactly one primary public facade module named `Robine.<Context>`.
- **FR-3:** A facade MUST expose state-changing use cases through explicit `defdelegate` declarations to modules under `Robine.<Context>.UseCases`.
- **FR-4:** A facade MUST NOT contain business rules, persistence calls, adapter selection, or orchestration logic.
- **FR-5:** A use-case module MUST expose one primary `call/2` function: `call(input, execution_context)`. The typed execution context MUST carry actor and correlation metadata plus the explicitly assembled dependencies required by the use case. A narrowly justified `call/1` MAY be used only when the use case needs neither actor context nor outbound dependencies.
- **FR-6:** Use cases MUST coordinate domain rules and outbound ports, define the application transaction boundary, and return documented success or error values.
- **FR-7:** Use cases MUST NOT depend on Phoenix controllers, LiveViews, Plug connections, Oban workers, GitHub clients, Docker clients, Ecto repositories, or concrete adapters.
- **FR-8:** Domain modules MUST contain entities, value objects, policies, state transitions, and domain errors. They MUST remain free of Ecto, Phoenix, Oban, HTTP, Docker, and filesystem dependencies.
- **FR-9:** Outbound infrastructure dependencies used by application code MUST be represented by context-owned behaviours under `Robine.<Context>.Ports` when they cross a volatile or test-relevant boundary.
- **FR-10:** Port behaviours MUST describe business capabilities rather than vendor APIs. For example, `Execution.Ports.Runner` MAY expose `dispatch/2`; a generic `HttpClient` MUST NOT become the application port for runner dispatch.
- **FR-11:** Concrete implementations MUST live under `Robine.Adapters` and MAY depend on frameworks or external libraries.
- **FR-12:** Delivery adapters such as Phoenix controllers, LiveViews, webhook consumers, Oban workers, and CLI commands MUST call a context facade rather than use-case modules, ports, Ecto schemas, or infrastructure adapters directly.
- **FR-13:** Calls between bounded contexts MUST target the other context's facade or a deliberately published read contract. They MUST NOT reach into another context's use cases, domain internals, schemas, ports, or adapters.
- **FR-14:** Ecto schemas MUST be persistence representations owned by a PostgreSQL adapter. They MUST NOT be used as domain entities in use-case interfaces.
- **FR-15:** Adapter mapping MUST convert between persistence or transport data and domain/application data at the boundary. Mapping MUST NOT leak framework-specific structs into the domain.
- **FR-16:** Adapter selection and dependency construction MUST occur in a composition root under `Robine.Runtime`, using application configuration and explicit dependency maps or structs.
- **FR-17:** Tests MUST be able to call a use case with explicit fake dependencies without mutating global application environment.
- **FR-18:** All use cases MUST return `{:ok, result}` or `{:error, reason}` for expected outcomes. Exceptions MUST be reserved for programmer errors or irrecoverable invariant violations.
- **FR-19:** Domain and application errors MUST use stable atoms or typed structs. Delivery adapters MUST translate them into HTTP, LiveView, CLI, webhook, or worker-specific responses.
- **FR-20:** Query operations MAY use dedicated query services when constructing read-optimized projections. Queries MUST still be exposed through the context facade and MUST not permit delivery adapters to issue arbitrary Ecto queries.
- **FR-21:** Transaction ownership MUST be explicit. A use case MUST define which business operation is atomic; an adapter-provided unit-of-work port MUST implement the database transaction without exposing `Ecto.Multi` outside the persistence adapter.
- **FR-22:** Domain events MUST be produced as data by domain or use-case code and persisted atomically with the state change when external delivery is required. External side effects MUST occur after commit through an outbox or equivalent durable mechanism.
- **FR-23:** The codebase MUST contain an automated architecture check that rejects forbidden dependency directions.
- **FR-24:** `defdelegate` MUST be explicit per operation. Facades MUST NOT generate delegates by scanning modules or expose every function from a use-case namespace automatically.
- **FR-25:** Public facade functions MUST have `@spec` documentation and stable domain-oriented names; the delegated use-case `call/2` function itself is not part of the public API.

### Developer experience requirements

- **DX-1:** A contributor MUST be able to locate a feature's public API, use case, ports, and adapters from predictable module names.
- **DX-2:** A use-case unit test MUST run without starting Phoenix, PostgreSQL, Oban, Docker, or an HTTP server.
- **DX-3:** Architectural failures MUST identify the offending module and forbidden dependency direction.
- **DX-4:** The project documentation MUST include one complete reference feature showing command input, facade, use case, domain policy, port, production adapter, delivery adapter, and tests.
- **DX-5:** Adding a new adapter MUST not require changes to the domain or use-case implementation unless the business capability itself changes.

### Operational requirements

- **OR-1:** Dependency construction MUST fail fast during application startup when a required adapter is missing or does not implement its declared behaviour.
- **OR-2:** Use cases MUST accept correlation and actor metadata through a documented execution context rather than reading process-global state.
- **OR-3:** Telemetry emission MAY be implemented through an injected port or application wrapper, but telemetry failures MUST NOT alter business outcomes.
- **OR-4:** Process supervision remains an infrastructure responsibility. Use cases MUST NOT start, link, register, or supervise long-lived processes.

## Proposed design

### Dependency rule

Dependencies point inward:

```text
Delivery adapters ───────┐
                        v
Context facade -> Use cases -> Domain
                        |
                        v
                  Outbound ports
                        ^
                        |
Infrastructure adapters ┘
```

The domain knows no outer layer. Use cases know the domain and port behaviours. Facades know use-case modules only. Adapters know the contracts they implement. The composition root knows concrete adapters and assembles dependencies.

The implemented pipeline creation path is documented as the [canonical reference vertical slice](../../architecture/reference-vertical-slice.md), including its durable GitHub delivery path, shared LiveView/worker facade call, port contract, and transaction integration tests.

### Suggested source layout

```text
lib/
  robine/
    pipelines.ex                         # Robine.Pipelines facade
    pipelines/
      domain/
        pipeline.ex
        pipeline_policy.ex
        errors.ex
      use_cases/
        create_pipeline.ex
        cancel_pipeline.ex
        retry_job.ex
      ports/
        pipeline_repository.ex
        event_outbox.ex
        clock.ex
      queries/
        get_pipeline.ex
      contracts/
        pipeline_view.ex

    adapters/
      persistence/
        postgres/
          schemas/pipeline.ex
          pipeline_repository.ex
          unit_of_work.ex
      execution/
        docker_runner.ex
      source_control/
        github.ex
      storage/
        local.ex

    runtime/
      dependencies.ex

  robine_web/                            # Phoenix delivery adapters
    live/
    controllers/

  robine_cli/                            # CLI delivery adapters
```

This layout is conceptual, not permission to create a single giant `Robine.Adapters` dependency graph. Each adapter MUST implement a port owned by a bounded context, and shared adapter code MUST remain infrastructure-only.

### Facade and use case

```elixir
defmodule Robine.Pipelines do
  @moduledoc "Public application API for pipeline operations."

  alias Robine.Pipelines.UseCases

  @spec create_pipeline(map(), Robine.ExecutionContext.t()) ::
          {:ok, Robine.Pipelines.Contracts.PipelineView.t()}
          | {:error, term()}
  defdelegate create_pipeline(input, context),
    to: UseCases.CreatePipeline,
    as: :call

  @spec cancel_pipeline(map(), Robine.ExecutionContext.t()) ::
          {:ok, Robine.Pipelines.Contracts.PipelineView.t()}
          | {:error, term()}
  defdelegate cancel_pipeline(input, context),
    to: UseCases.CancelPipeline,
    as: :call
end
```

The public second argument is a typed execution context, not a raw dependency map. Delivery adapters obtain a production context from the composition root. Unit tests construct a test context containing fake dependency implementations. The convention MUST avoid hidden reads from `Application.get_env/3`, the process dictionary, or globally registered mocks inside use cases.

```elixir
defmodule Robine.Pipelines.UseCases.CreatePipeline do
  alias Robine.Pipelines.Domain.Pipeline

  @spec call(map(), Robine.ExecutionContext.t()) :: {:ok, struct()} | {:error, term()}
  def call(input, context) do
    deps = context.dependencies.pipelines

    deps.unit_of_work.transaction(fn ->
      with {:ok, pipeline} <- Pipeline.create(input, context.actor, deps.clock.now()),
           :ok <- deps.pipeline_repository.insert(pipeline),
           :ok <- deps.event_outbox.append(Pipeline.events(pipeline)) do
        {:ok, deps.presenter.pipeline_view(pipeline)}
      end
    end)
  end
end
```

The sample illustrates direction, not a mandatory final API. In particular, dependency access SHOULD use a typed struct rather than an unvalidated nested map, and presenters SHOULD only exist when a stable application contract cannot be returned directly.

### Inputs and outputs

Use-case input SHOULD be a typed command struct when the operation has validation, security significance, or more than a few fields. Small query inputs MAY use ordinary values or maps. Domain entities MUST enforce invariants after syntactic input validation.

Use cases return domain values or explicit contract structs. They MUST NOT return `Ecto.Schema`, `Plug.Conn`, `Phoenix.LiveView.Socket`, `Oban.Job`, GitHub SDK, or Docker client structs. Delivery adapters decide rendering, navigation, flash messages, HTTP status, and process exit codes.

### Ports and adapters

A port exists when the application needs a capability whose implementation is external, volatile, nondeterministic, or expensive. Expected ports include repositories, unit of work, clock, ID generation, runner dispatch, source control, object storage, secret encryption, event outbox, and notification publication.

Pure modules do not need behaviours merely to be mocked. Context facades are not behaviours. Use cases are not required to implement a common behaviour because their input and output types differ meaningfully.

### Transactions and side effects

The use case decides the atomic business boundary; the PostgreSQL adapter implements it. A transaction MUST contain only database work. Docker dispatch, GitHub API calls, log publication, email, and other network effects MUST NOT run inside a database transaction. Those effects are represented as durable outbox records and delivered by infrastructure workers after commit.

### OTP and background jobs

GenServers, supervisors, Tasks, PubSub, and Oban are delivery or infrastructure mechanisms. An Oban worker MUST parse its durable input, construct an execution context, call a facade, and translate the result into retry/discard behavior. It MUST NOT duplicate the use case or become the owner of a business state machine.

Long-running execution is modeled as multiple short use cases reacting to durable facts, for example `DispatchJob`, `RecordRunnerEvent`, `RequestCancellation`, and `ExpireRunnerLease`. A single use case MUST NOT block for the duration of a CI job.

### Architecture enforcement

The project SHOULD use compile-time boundary enforcement where practical and MUST supplement it with tests. At minimum, checks reject:

- domain modules depending on Ecto, Phoenix, Oban, adapters, or delivery modules;
- use cases depending on concrete adapters or delivery modules;
- delivery adapters accessing Ecto repositories or schemas directly;
- cross-context access to internal namespaces;
- concrete adapter references outside the composition root;
- public use-case calls that bypass a context facade.

Temporary exceptions MUST be explicit, narrowly scoped, documented with an owner, and tracked for removal.

## Failure modes and recovery

| Failure | Expected behavior | Recovery |
|---|---|---|
| Required adapter is absent | Application startup fails with the missing port and context | Configure a valid adapter and restart |
| Adapter returns malformed data | Boundary validation returns an infrastructure error and records telemetry | Fix adapter; retry only when safe |
| Use case returns expected failure | Delivery adapter renders its context-specific response | User or worker follows documented recovery |
| External effect fails after commit | Durable outbox item remains pending | Worker retries with bounded backoff |
| Architecture check detects a forbidden dependency | CI fails with module and violated rule | Move logic or introduce the correct port |
| Transaction retries or rolls back | No external effect has occurred inside it | Retry according to use-case policy |

## Security and privacy

Authorization is an application concern and MUST execute inside the use case or an application policy called by it; hiding a button or protecting a controller route is insufficient. The execution context carries the authenticated actor and correlation metadata. Adapters MUST minimize external payloads and map secret-bearing transport data before it enters general application structures.

Ports involving secrets, authentication, source code, logs, or artifacts MUST document sensitivity and redaction behavior. Fake adapters MUST use synthetic fixtures and MUST NOT depend on production credentials.

## Observability

Every facade call SHOULD create or continue a trace span named after the bounded context and use case. Standard metadata includes correlation ID, actor ID when permitted, repository ID, pipeline/job identifiers, outcome class, and duration. Inputs, domain entities, commands, adapter payloads, and errors MUST be inspected through redaction-safe implementations.

Architecture-check results run in CI. Test suites SHOULD report use-case test duration separately from adapter integration and end-to-end tests so loss of test isolation is visible.

## Testing strategy

- Domain tests exercise invariants and state transitions as pure functions.
- Use-case tests inject fakes or deterministic test adapters through explicit dependencies.
- Port contract tests define behavior that every production and test adapter MUST satisfy.
- Adapter integration tests exercise PostgreSQL, Docker, GitHub HTTP fixtures, filesystem storage, and cryptography at their real boundaries.
- Delivery tests verify input mapping, authorization handoff, and response translation without re-testing domain rules.
- End-to-end tests cover a small number of critical journeys through the assembled runtime.
- Architecture tests verify dependency direction and facade-only access.

Mocks SHOULD verify protocol-relevant interactions only. State-based fakes are preferred for repositories and outboxes when they make the business outcome clearer.

## Acceptance criteria

- [x] Every MVP state-changing operation is represented by a named use-case module and exposed by exactly one context facade.
- [x] Every public facade operation is an explicit documented `defdelegate` to one use case.
- [x] A representative use case is called unchanged from LiveView, an Oban worker, and a unit test.
- [x] A use-case unit test runs without starting the application supervision tree or external services.
- [x] Domain modules compile without Ecto, Phoenix, Oban, Docker, GitHub, or filesystem dependencies.
- [x] Ecto schemas never appear in facade or use-case public types.
- [x] External network or Docker side effects never execute inside a database transaction.
- [x] An outbox integration test proves that a committed effect survives a missing worker job, is reconciled, and is delivered idempotently.
- [x] Architecture checks fail on fixtures representing each forbidden dependency direction.
- [x] Only the composition root refers to concrete adapters when assembling production dependencies.
- [x] Cross-context calls use the target context facade or an explicitly published contract.
- [x] The reference feature documented by DX-4 is implemented and used as the pattern for subsequent work.

## Open questions

None blocking.

## Decisions

- The MVP remains one Mix/OTP application. A split requires an independently deployable boundary or a demonstrated compilation/runtime isolation need.
- Dependency directions are enforced by focused ExUnit architecture checks in CI. The allowed graph is the inward dependency rule documented above; no additional boundary library is required for the MVP.
- `Robine.ExecutionContext` is the typed public call context. Production contexts come from `Robine.Runtime.Dependencies`; unit tests construct explicit dependency structs with deterministic fakes.
- Read operations use named application query use cases exposed through the same context facade. Delivery adapters never access Ecto directly.
- `PipelineCreated` is the first durable outbox event. Additional effects that must survive process failure are migrated to the outbox as their projections are implemented.

## Out of scope / future work

- Separate deployable services per bounded context.
- Dynamic plugin loading, runtime adapter marketplaces, and user-provided application modules.
- Event sourcing as the default persistence model.
- A distributed transaction coordinator.
