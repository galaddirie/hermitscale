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

  @impl true
  def work(_params, input, %{credentials: credentials}) do
    input
    |> Map.put("access_token", credentials.access_token)
    |> Map.put("scopes", credentials.scopes)
  end
end
