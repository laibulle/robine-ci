defmodule Robine.Adapters.SourceControl.ForgejoIntegrationTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.SourceControl.{ForgejoClient, ReqHttpClient}
  alias Robine.Repositories.Domain.Repository
  alias Robine.TestSupport.ForgejoServer

  @moduletag :forgejo_integration

  setup_all do
    case System.cmd("docker", ["image", "inspect", ForgejoServer.image()], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _missing -> [skip: "the pinned Forgejo integration image is not installed"]
    end
  end

  setup do
    previous_config = Application.get_env(:robine, :forgejo_source_control)
    previous_token = Application.get_env(:robine, :forgejo_token)
    server = start_supervised!(ForgejoServer)
    connection = ForgejoServer.connection(server)

    Application.put_env(:robine, :forgejo_source_control,
      base_url: connection.endpoint,
      http_client: ReqHttpClient
    )

    Application.put_env(:robine, :forgejo_token, connection.token)

    on_exit(fn ->
      restore(:forgejo_source_control, previous_config)
      restore(:forgejo_token, previous_token)
    end)

    {:ok, connection: connection}
  end

  test "the source-control adapter contract passes against pinned Forgejo", %{
    connection: connection
  } do
    repository = repository(connection)

    assert {:ok, repositories} = ForgejoClient.available_repositories()
    assert Enum.any?(repositories, &(&1.full_name == "robine/adapter-contract"))

    assert {:ok, %{branch: "main", sha: sha}} = ForgejoClient.default_branch_head(repository)
    assert sha == connection.sha

    assert {:ok, [%{path: ".robine-ci/workflows/ci.yml", content: workflow}]} =
             ForgejoClient.workflow_files(repository, sha)

    assert workflow =~ "name: Forgejo integration"

    assert {:ok, source_files} = ForgejoClient.source_files(repository, sha)
    assert {".robine-ci/workflows/ci.yml", workflow} in source_files

    assert {:ok, %{repository: "read", status: "write"}} =
             ForgejoClient.installation_permissions(repository)

    assert {:ok, provider_status_id} = ForgejoClient.upsert_check(repository, check(sha))
    assert is_integer(provider_status_id)

    assert {:ok, %{status: 200, body: statuses}} =
             Req.get(
               "#{connection.endpoint}/api/v1/repos/robine/adapter-contract/commits/#{sha}/statuses",
               headers: [{"authorization", "token #{connection.token}"}],
               retry: false
             )

    assert Enum.any?(statuses, fn status ->
             status["context"] == "Robine / integration" and status["status"] == "success"
           end)
  end

  defp repository(connection) do
    %Repository{
      id: Ecto.UUID.generate(),
      provider: :forgejo,
      provider_instance: "default",
      provider_id: 1,
      installation_id: 0,
      owner: connection.username,
      name: connection.repository,
      full_name: "#{connection.username}/#{connection.repository}",
      trusted: true,
      inserted_at: DateTime.utc_now()
    }
  end

  defp check(sha) do
    %{
      name: "Robine / integration",
      head_sha: sha,
      status: :completed,
      conclusion: :success,
      details_url: "https://ci.example.test/pipelines/integration",
      external_id: "forgejo-integration",
      output: %{summary: "Pinned Forgejo adapter contract passed."}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:robine, key)
  defp restore(key, value), do: Application.put_env(:robine, key, value)
end
