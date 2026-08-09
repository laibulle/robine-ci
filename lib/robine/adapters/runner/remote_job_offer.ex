defmodule Robine.Adapters.Runner.RemoteJobOffer do
  @moduledoc "Builds a bounded, retryable offer from durable attempt state."

  alias Robine.Pipelines

  def build(attempt_id, context) do
    with {:ok, raw} <- Pipelines.remote_job_execution(%{attempt_id: attempt_id}, context) do
      public_url = Application.fetch_env!(:robine, :public_url) |> String.trim_trailing("/")
      transfer_base = "#{public_url}/api/v1/runners/attempts/#{attempt_id}"

      {:ok,
       %{
         "attempt_id" => attempt_id,
         "idempotency_token" => raw["idempotency_token"],
         "execution" => raw,
         "source_url" => if(checkout_required?(raw), do: transfer_base <> "/source"),
         "secrets_url" => transfer_base <> "/secrets",
         "builtins_url" => transfer_base
       }}
    end
  end

  defp checkout_required?(%{"steps" => steps}) when is_list(steps) do
    Enum.any?(steps, fn
      %{"kind" => kind, "value" => "checkout"} when kind in ["builtin", :builtin] -> true
      _step -> false
    end)
  end

  defp checkout_required?(_raw), do: false
end
