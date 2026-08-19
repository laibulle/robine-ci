if Mix.env() != :dev do
  raise "priv/repo/dev_seeds.exs is reserved for the development environment"
end

alias Robine.Adapters.Persistence.Postgres.Schemas.{GitHubRepository, Pipeline}
alias Robine.Repo

now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

repositories = [
  %{
    id: "10000000-0000-4000-8000-000000000001",
    provider_id: 910_001,
    installation_id: 91,
    owner: "base59",
    name: "robine",
    full_name: "base59/robine"
  },
  %{
    id: "10000000-0000-4000-8000-000000000002",
    provider_id: 910_002,
    installation_id: 91,
    owner: "base59",
    name: "commerce-api",
    full_name: "base59/commerce-api"
  },
  %{
    id: "10000000-0000-4000-8000-000000000003",
    provider_id: 910_003,
    installation_id: 91,
    owner: "base59",
    name: "design-studio",
    full_name: "base59/design-studio"
  },
  %{
    id: "10000000-0000-4000-8000-000000000004",
    provider_id: 920_001,
    installation_id: 92,
    owner: "lumen",
    name: "docs",
    full_name: "lumen/docs"
  },
  %{
    id: "10000000-0000-4000-8000-000000000005",
    provider_id: 930_001,
    installation_id: 93,
    owner: "acme",
    name: "platform",
    full_name: "acme/platform"
  }
]

Enum.each(repositories, fn attributes ->
  attributes =
    Map.merge(attributes, %{
      provider: :github,
      provider_instance: "github.com",
      trusted: true,
      inserted_at: DateTime.add(now, -21, :day)
    })

  %GitHubRepository{}
  |> GitHubRepository.changeset(attributes)
  |> Repo.insert!(
    on_conflict: {:replace_all_except, [:id]},
    conflict_target: [:id]
  )
end)

pipeline = fn id, repository_id, workflow_name, status, minutes_ago, source_ref ->
  inserted_at = DateTime.add(now, -minutes_ago, :minute)
  terminal? = status in [:succeeded, :failed, :cancelled, :invalid]

  %{
    id: id,
    repository_id: repository_id,
    workflow_name: workflow_name,
    commit_sha: :crypto.hash(:sha, id) |> Base.encode16(case: :lower),
    source_ref: source_ref,
    trigger: if(source_ref == "main", do: "push", else: "pull_request"),
    actor: "dev-seed",
    correlation_id: "dev-seed-#{id}",
    status: status,
    inserted_at: inserted_at,
    started_at: DateTime.add(inserted_at, 20, :second),
    finished_at: if(terminal?, do: DateTime.add(inserted_at, 4, :minute), else: nil),
    inputs: %{}
  }
end

pipelines = [
  pipeline.(
    "20000000-0000-4000-8000-000000000001",
    "10000000-0000-4000-8000-000000000001",
    "CI · Elixir 1.19",
    :succeeded,
    18,
    "main"
  ),
  pipeline.(
    "20000000-0000-4000-8000-000000000002",
    "10000000-0000-4000-8000-000000000001",
    "Release",
    :succeeded,
    1_460,
    "v1.8.0"
  ),
  pipeline.(
    "20000000-0000-4000-8000-000000000003",
    "10000000-0000-4000-8000-000000000002",
    "Quality gate",
    :failed,
    42,
    "feat/checkout"
  ),
  pipeline.(
    "20000000-0000-4000-8000-000000000004",
    "10000000-0000-4000-8000-000000000003",
    "Visual regression",
    :running,
    4,
    "redesign/repositories"
  ),
  pipeline.(
    "20000000-0000-4000-8000-000000000005",
    "10000000-0000-4000-8000-000000000003",
    "Accessibility",
    :queued,
    2,
    "redesign/repositories"
  ),
  pipeline.(
    "20000000-0000-4000-8000-000000000006",
    "10000000-0000-4000-8000-000000000003",
    "CI",
    :succeeded,
    190,
    "main"
  ),
  pipeline.(
    "20000000-0000-4000-8000-000000000007",
    "10000000-0000-4000-8000-000000000005",
    "Deploy preview",
    :succeeded,
    1_620,
    "main"
  )
]

Enum.each(pipelines, fn attributes ->
  %Pipeline{}
  |> Pipeline.changeset(attributes)
  |> Repo.insert!(
    on_conflict: {:replace_all_except, [:id]},
    conflict_target: [:id]
  )
end)

IO.puts(
  "Seeded #{length(repositories)} repositories and #{length(pipelines)} pipelines for UI review."
)
