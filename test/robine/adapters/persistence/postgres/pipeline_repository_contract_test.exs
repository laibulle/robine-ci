defmodule Robine.Adapters.Persistence.Postgres.PipelineRepositoryContractTest do
  use Robine.DataCase, async: true

  use Robine.TestSupport.PortContracts.PipelineRepositoryContract,
    adapter: Robine.Adapters.Persistence.Postgres.PipelineRepository
end
