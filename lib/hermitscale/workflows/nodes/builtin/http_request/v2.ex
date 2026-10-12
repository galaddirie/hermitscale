defmodule Hermitscale.Workflows.Nodes.Builtin.HttpRequest.V2 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "http_request",
    version: 2,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    requires: [credentials: []],
    expr: [:url],
    params: [
      method: [
        type: {:in, ~w(GET POST PUT PATCH DELETE)},
        required: true,
        doc: "HTTP method."
      ],
      url: [
        type: :string,
        required: true,
        doc: "URL or expression-resolved URL."
      ]
    ]

  @impl true
  def work(%{method: method, url: url}, input, %{credentials: credentials}) do
    case Hermitscale.HTTP.request(method, url, body: input, credentials: credentials) do
      {:ok, response} -> response.body
      {:error, reason} -> raise "HTTP request failed: #{inspect(reason)}"
    end
  end
end
