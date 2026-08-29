defmodule Robine.Adapters.SourceControl.GitLabIntegrationTest do
  use ExUnit.Case, async: false

  alias Robine.Adapters.SourceControl.{GitLabClient, ReqHttpClient}
  alias Robine.Repositories.Domain.Repository
  alias Robine.TestSupport.GitLabServer

  @moduletag :gitlab_integration
  @moduletag timeout: 360_000
  @integration_skip_reason (cond do
                              System.get_env("ROBINE_GITLAB_INTEGRATION") != "1" ->
                                "set ROBINE_GITLAB_INTEGRATION=1 to run the heavyweight GitLab smoke"

                              not match?(
                                {_output, 0},
                                System.cmd(
                                  "docker",
                                  ["image", "inspect", GitLabServer.image()],
                                  stderr_to_stdout: true
                                )
                              ) ->
                                "the pinned GitLab integration image is not installed"

                              true ->
                                nil
                            end)

  if @integration_skip_reason do
    @moduletag skip: @integration_skip_reason
  end

  setup do
    previous_config = Application.get_env(:robine, :gitlab_source_control)
    previous_token = Application.get_env(:robine, :gitlab_token)
    server = start_supervised!({GitLabServer, []}, shutdown: 10_000)
    connection = GitLabServer.connection(server)

    Application.put_env(:robine, :gitlab_source_control,
      base_url: connection.endpoint,
      http_client: ReqHttpClient
    )

    Application.put_env(:robine, :gitlab_token, connection.token)

    on_exit(fn ->
      restore(:gitlab_source_control, previous_config)
      restore(:gitlab_token, previous_token)
    end)

    {:ok, connection: connection}
  end

  test "the source-control adapter contract passes against pinned GitLab CE", %{
    connection: connection
  } do
    repository = repository(connection)

    assert {:ok, repositories} = GitLabClient.available_repositories()
    assert Enum.any?(repositories, &(&1.provider_id == connection.project_id))

    assert {:ok, %{branch: "main", sha: sha}} = GitLabClient.default_branch_head(repository)
    assert sha == connection.sha

    assert {:ok, [%{path: ".robine-ci/workflows/ci.yml", content: workflow}]} =
             GitLabClient.workflow_files(repository, sha)

    assert workflow =~ "name: GitLab integration"

    assert {:ok, source_files} = GitLabClient.source_files(repository, sha)

    assert %{path: ".robine-ci/workflows/ci.yml", content: ^workflow, mode: mode} =
             Enum.find(source_files, &(&1.path == ".robine-ci/workflows/ci.yml"))

    assert mode in [0o644, 0o755]

    assert {:ok, permissions} = GitLabClient.installation_permissions(repository)
    assert is_map(permissions)

    assert {:ok, provider_status_id} = GitLabClient.upsert_check(repository, check(sha))
    assert is_integer(provider_status_id)

    assert {:ok, %{status: 200, body: statuses}} =
             Req.get(
               "#{connection.endpoint}/api/v4/projects/#{connection.project_id}/repository/commits/#{sha}/statuses",
               headers: [{"private-token", connection.token}],
               retry: false
             )

    assert Enum.any?(statuses, fn status ->
             status["name"] == "Robine / integration" and status["status"] == "success"
           end)
  end

  defp repository(connection) do
    %Repository{
      id: Ecto.UUID.generate(),
      provider: :gitlab,
      provider_instance: "default",
      provider_id: connection.project_id,
      installation_id: 0,
      owner: "root",
      name: connection.project,
      full_name: "root/#{connection.project}",
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
      external_id: "gitlab-integration",
      output: %{summary: "Pinned GitLab adapter contract passed."}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:robine, key)
  defp restore(key, value), do: Application.put_env(:robine, key, value)
end
