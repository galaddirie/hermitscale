defmodule Hermitscale.Workflows.Nodes.CredentialProbe.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.credential_probe",
    version: 1,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    requires: [
      credentials: [
        provider: "test.credentials",
        scopes: ["scope:a"]
      ]
    ]

  require Runic

  @impl true
  def build(_params, %{name: name}) do
    Runic.step(
      fn input ->
        credentials = context(:credentials)

        input
        |> Map.put("access_token", credentials.access_token)
        |> Map.put("scopes", credentials.scopes)
      end,
      name: name
    )
  end
end
