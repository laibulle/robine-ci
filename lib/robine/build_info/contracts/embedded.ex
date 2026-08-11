defmodule Robine.BuildInfo.Contracts.Embedded do
  @moduledoc "Compile-time values captured before the OTP release is assembled."

  @version Mix.Project.config() |> Keyword.fetch!(:version)
  @commit_sha System.get_env("ROBINE_BUILD_COMMIT_SHA") || String.pad_trailing("dev", 40, "0")
  @ref_name System.get_env("ROBINE_BUILD_REF_NAME") || "working-tree"
  @ref_type System.get_env("ROBINE_BUILD_REF_TYPE") || "branch"
  @built_at System.get_env("ROBINE_BUILD_TIMESTAMP") || "1970-01-01T00:00:00Z"
  @pipeline_id System.get_env("ROBINE_BUILD_PIPELINE_ID") || "development-local"
  @trigger System.get_env("ROBINE_BUILD_TRIGGER") || "manual"

  @spec current() :: map()
  def current do
    %{
      version: @version,
      commit_sha: @commit_sha,
      ref_name: @ref_name,
      ref_type: @ref_type,
      built_at: @built_at,
      pipeline_id: @pipeline_id,
      trigger: @trigger
    }
  end
end
