defmodule Hermitscale.Workflows.Nodes.HttpRequest.V2 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "http_request",
    version: 2,
    kind: :step,
    inputs: [:main],
    outputs: [:main],
    requires: [credentials: []],
    params: [
      method: [
        type: {:in, ~w(GET POST PUT PATCH DELETE)},
        required: true,
        doc: "HTTP method."
      ],
      url: [
        type: :string,
        required: true,
        doc: "URL template using constrained workflow interpolation."
      ]
    ]

  require Runic

  @impl true
  def build(%{method: method, url: url_template}, %{name: name}) do
    Runic.step(
      fn input ->
        url = Hermitscale.Workflows.Template.render!(^url_template, input)
        auth = context(:credentials, default: nil)

        case Hermitscale.HTTP.request(^method, url, body: input, auth: auth) do
          {:ok, response} -> response.body
          {:error, reason} -> raise "HTTP request failed: #{inspect(reason)}"
        end
      end,
      name: name
    )
  end
end
