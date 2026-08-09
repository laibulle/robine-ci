# Reference vertical slice: create a pipeline

`Robine.Pipelines.create_pipeline/2` is the canonical example for adding an application operation. It preserves the inward dependency direction while supporting durable GitHub delivery, isolated unit tests, and PostgreSQL integration tests.

## Path through the architecture

1. `GitHubWebhookController` authenticates and stores a delivery through the `Robine.Repositories` facade.
2. `ProcessGitHubDeliveryWorker` consumes the durable delivery and calls that same repository facade.
3. `ProcessGitHubDelivery` validates trusted-repository policy and invokes the published `Robine.Pipelines.create_pipeline/2` facade API.
4. The facade explicitly delegates to `Pipelines.UseCases.CreatePipeline.call/2`.
5. The use case obtains typed dependencies from `ExecutionContext`, asks `Pipeline` and `WorkflowRevision` to enforce domain invariants, and defines one atomic operation.
6. Context-owned `PipelineRepository`, `JobRepository`, `EventOutbox`, and `UnitOfWork` ports express required capabilities.
7. PostgreSQL adapters map domain structures to Ecto schemas and atomically persist the pipeline, immutable revision, jobs, and outbox event.
8. `OutboxDeliveryWorker` later calls the facade to deliver the committed event. No external side effect occurs inside the creation transaction.

The facade input is currently a validated application map because workflow validation already supplies the structured graph. If pipeline creation gains an independent public transport or additional security-sensitive fields, replace it with a typed command contract at the facade boundary.

## Shared delivery example

`Robine.Pipelines.list_pipelines/2` demonstrates delivery reuse directly: `PipelineLive.Index` calls it to render the UI, and `ReconcileGitHubChecksWorker` calls the same facade operation during durable reconciliation. Neither adapter imports a use-case module, port, Ecto schema, or repository.

## Tests to copy

- `CreatePipelineTest` supplies fake port implementations and runs without a supervision tree or external service.
- `PipelineRepositoryContractTest` applies the reusable repository-port contract to the PostgreSQL adapter.
- `PipelineTransactionTest` proves the use-case transaction persists the aggregate, immutable workflow revision, outbox event, and Oban delivery job together.
- LiveView, webhook-controller, and background-worker tests verify translation at delivery boundaries.

For a new operation, start at the facade and use case, put invariants in the domain, introduce only capability-oriented ports that protect a volatile boundary, assemble adapters in `Robine.Runtime.Dependencies`, and add delivery translation last.
