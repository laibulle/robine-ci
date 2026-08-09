defmodule Robine.Runners.Ports.Registry do
  @moduledoc "Atomic persistence boundary for remote runner identities and credentials."

  alias Robine.Runners.Domain.Runner

  @callback create_enrollment(map()) :: :ok | {:error, term()}

  @callback consume_enrollment(binary(), DateTime.t(), Runner.t(), map(), map()) ::
              {:ok, Runner.t()} | {:error, term()}

  @callback authentication_candidates(String.t(), DateTime.t()) ::
              {:ok, Runner.t(), [binary()]} | {:error, :not_found}

  @callback record_authentication(String.t(), DateTime.t()) :: :ok | {:error, term()}
  @callback record_session(String.t(), pos_integer(), String.t(), map(), DateTime.t()) ::
              :ok | {:error, term()}

  @callback heartbeat(String.t(), pos_integer(), DateTime.t()) :: :ok | {:error, term()}
  @callback next_available(DateTime.t()) :: {:ok, map()} | {:error, :none}
  @callback get(String.t()) :: {:ok, Runner.t()} | {:error, :not_found}
  @callback list_fleet(DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  @callback update_configuration(Runner.t(), map()) :: :ok | {:error, term()}
  @callback rotate_credential(String.t(), map(), DateTime.t(), DateTime.t(), map()) ::
              :ok | {:error, term()}

  @callback revoke(String.t(), DateTime.t(), map()) :: :ok | {:error, term()}
  @callback audit_authentication_failure(String.t(), DateTime.t(), map()) :: :ok
end
