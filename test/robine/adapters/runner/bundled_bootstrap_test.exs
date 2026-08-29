defmodule Robine.Adapters.Runner.BundledBootstrapTest do
  use Robine.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Robine.Adapters.Persistence.Postgres.Schemas.RunnerEnrollmentToken
  alias Robine.Adapters.Runner.BundledBootstrap
  alias Robine.Repo
  alias Robine.Runtime.Dependencies

  test "creates one private token handoff and removes it after the runner marks configuration" do
    directory = Path.join(System.tmp_dir!(), "robine-bundled-runner-#{Ecto.UUID.generate()}")

    context =
      Dependencies.system_context(
        Robine.ExecutionContext.standalone_tenant(),
        "system:bundled-runner-test",
        "bundled-runner:test"
      )

    pid =
      start_supervised!(
        {BundledBootstrap, name: nil, config: [bootstrap_directory: directory], context: context}
      )

    _ = :sys.get_state(pid)
    token_path = Path.join(directory, "enrollment-token")
    token = File.read!(token_path)
    assert "rbe_" <> _encoded = token
    assert File.stat!(token_path).mode |> Bitwise.band(0o777) == 0o600
    assert Repo.aggregate(RunnerEnrollmentToken, :count) == 1

    send(pid, :reconcile)
    _ = :sys.get_state(pid)
    assert File.read!(token_path) == token
    assert Repo.aggregate(RunnerEnrollmentToken, :count) == 1

    File.write!(Path.join(directory, "configured"), "runner-id", [:binary])
    File.chmod!(Path.join(directory, "configured"), 0o600)
    send(pid, :reconcile)
    _ = :sys.get_state(pid)
    refute File.exists?(token_path)

    on_exit(fn -> File.rm_rf(directory) end)
  end

  test "refreshes a stale token without exposing plaintext in persistence" do
    directory =
      Path.join(System.tmp_dir!(), "robine-bundled-runner-stale-#{Ecto.UUID.generate()}")

    File.mkdir_p!(directory)
    token_path = Path.join(directory, "enrollment-token")
    File.write!(token_path, "rbe_stale", [:binary])
    File.chmod!(token_path, 0o600)
    stale = System.os_time(:second) - 700
    File.touch!(token_path, stale)

    context =
      Dependencies.system_context(
        Robine.ExecutionContext.standalone_tenant(),
        "system:bundled-runner-test",
        "bundled-runner:stale"
      )

    pid =
      start_supervised!(
        {BundledBootstrap, name: nil, config: [bootstrap_directory: directory], context: context},
        id: :stale_bundled_bootstrap
      )

    _ = :sys.get_state(pid)
    token = File.read!(token_path)
    refute token == "rbe_stale"

    stored =
      Repo.one!(
        from enrollment in RunnerEnrollmentToken, order_by: [desc: enrollment.inserted_at]
      )

    refute Base.encode16(stored.token_digest) =~ token

    on_exit(fn -> File.rm_rf(directory) end)
  end

  test "reports a bounded secret-free bootstrap filesystem failure" do
    path = Path.join(System.tmp_dir!(), "robine-bundled-runner-file-#{Ecto.UUID.generate()}")
    File.write!(path, "not-a-directory", [:binary])

    context =
      Dependencies.system_context(
        Robine.ExecutionContext.standalone_tenant(),
        "system:bundled-runner-test",
        "bundled-runner:failure"
      )

    log =
      capture_log(fn ->
        pid =
          start_supervised!(
            {BundledBootstrap, name: nil, config: [bootstrap_directory: path], context: context},
            id: :failed_bundled_bootstrap
          )

        _ = :sys.get_state(pid)
      end)

    assert log =~ "bundled runner bootstrap unavailable: enotdir"
    refute log =~ path
    refute log =~ "rbe_"

    on_exit(fn -> File.rm(path) end)
  end
end
