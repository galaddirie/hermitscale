ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Hermitscale.Repo, :manual)

for module <- [
      Hermitscale.Auth.WorkOS,
      Hermitscale.Integrations.ConnectedAccounts
    ] do
  Application.put_env(:hermitscale, module, client: Hermitscale.WorkOSTest.Client)
end
