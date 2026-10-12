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
    |> Map.put("account_id", credentials.account_id)
    |> Map.put("actor_user_id", credentials.execution_context.actor_user_id)
  end
end
