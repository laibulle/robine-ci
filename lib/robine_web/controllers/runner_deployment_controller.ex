defmodule RobineWeb.RunnerDeploymentController do
  use RobineWeb, :controller

  alias Robine.{Deployments, Runners, Secrets, Storage}
  alias Robine.Runtime.Dependencies

  def artifact(conn, %{"deployment_id" => deployment_id}) do
    with {:ok, raw, system_context} <- authorized_execution(conn, deployment_id),
         artifact = raw["artifact"],
         {:ok, download} <-
           Storage.download_artifact(
             %{
               repository_id: raw["repository_id"],
               artifact_id: artifact["artifact_id"]
             },
             system_context
           ),
         true <- download.digest == artifact["digest"] do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-sha256", download.digest)
      |> put_resp_content_type("application/gzip")
      |> send_resp(:ok, download.content)
    else
      false ->
        conn |> put_status(:service_unavailable) |> json(%{error: "digest mismatch"})

      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, :forbidden} ->
        unauthorized(conn)

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "artifact unavailable"})
    end
  end

  def secrets(conn, %{"deployment_id" => deployment_id}) do
    with {:ok, raw, system_context} <- authorized_execution(conn, deployment_id),
         {:ok, values} <-
           Secrets.resolve_secrets(
             %{repository_id: raw["repository_id"], names: raw["secret_names"]},
             system_context
           ) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{secrets: values})
    else
      {:error, :unauthorized} ->
        unauthorized(conn)

      {:error, :forbidden} ->
        unauthorized(conn)

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "secrets unavailable"})
    end
  end

  defp authorized_execution(conn, deployment_id) do
    with {:ok, runner_id} <- request_header(conn, "x-robine-runner-id"),
         {:ok, credential} <- bearer(conn),
         correlation_id = List.first(get_req_header(conn, "x-request-id")) || Ecto.UUID.generate(),
         anonymous_context =
           Dependencies.context(%{id: "anonymous:runner-api", role: :runner}, correlation_id),
         {:ok, identity} <-
           Runners.authenticate(
             %{runner_id: runner_id, credential: credential},
             anonymous_context
           ),
         runner_context =
           Dependencies.context(%{id: identity.runner_id, role: :runner}, correlation_id),
         {:ok, raw} <-
           Deployments.remote_execution(%{deployment_id: deployment_id}, runner_context) do
      system_context =
        Dependencies.context(
          %{id: "system:deployment-transfer", role: :administrator},
          correlation_id
        )

      {:ok, raw, system_context}
    else
      _failure -> {:error, :unauthorized}
    end
  end

  defp bearer(conn) do
    case request_header(conn, "authorization") do
      {:ok, "Bearer " <> credential} when credential != "" -> {:ok, credential}
      _invalid -> {:error, :missing_credential}
    end
  end

  defp request_header(conn, name) do
    case get_req_header(conn, name) do
      [value] when value != "" -> {:ok, value}
      _missing -> {:error, :missing_header}
    end
  end

  defp unauthorized(conn),
    do: conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
end
