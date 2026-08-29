defmodule Robine.RuntimeConfigurationTest do
  use ExUnit.Case, async: false

  @environment_variables ~w(
    ROBINE_PUBLIC_URL
    OIDC_ISSUER
    OIDC_CLIENT_ID
    OIDC_CLIENT_SECRET
  )

  setup do
    previous = Map.new(@environment_variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "applies the public URL without requiring OIDC configuration" do
    System.put_env("ROBINE_PUBLIC_URL", "https://ci.example.test")
    System.delete_env("OIDC_ISSUER")
    System.delete_env("OIDC_CLIENT_ID")
    System.delete_env("OIDC_CLIENT_SECRET")

    runtime_configuration = Config.Reader.read!("config/runtime.exs", env: :test)
    robine_configuration = Keyword.fetch!(runtime_configuration, :robine)

    assert Keyword.fetch!(robine_configuration, :public_url) == "https://ci.example.test"
    refute Keyword.has_key?(robine_configuration, :oidc_config)
  end
end
