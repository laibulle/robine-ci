defmodule Robine.Adapters.Runner.RemoteDeploymentOffer do
  @moduledoc "Builds one bounded deployment offer from an assigned immutable snapshot."

  alias Robine.Deployments

  def build(deployment_id, context) do
    with {:ok, raw} <-
           Deployments.remote_execution(%{deployment_id: deployment_id}, context) do
      public_url = Application.fetch_env!(:robine, :public_url) |> String.trim_trailing("/")
      transfer_base = "#{public_url}/api/v1/runners/deployments/#{deployment_id}"

      {:ok,
       Map.merge(raw, %{
         "artifact_url" => transfer_base <> "/artifact",
         "secrets_url" => transfer_base <> "/secrets"
       })}
    end
  end
end
