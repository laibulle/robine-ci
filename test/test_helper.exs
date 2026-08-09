ExUnit.start()

if Process.whereis(Robine.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Robine.Repo, :manual)
end
