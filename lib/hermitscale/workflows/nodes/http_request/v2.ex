defmodule Hermitscale.Workflows.Nodes.HttpRequest.V2 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour
  require Runic

  @params_schema NimbleOptions.new!(
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
                 )

  @impl true
  def spec do
    %{
      id: "http_request",
      version: 2,
      kind: :step,
      inputs: [:main],
      outputs: [:main],
      params_schema: @params_schema.schema,
      deprecated: false
    }
  end

  @impl true
  def build(params, ctx) do
    method = Map.fetch!(params, "method")
    url_template = Map.fetch!(params, "url")
    name = ctx.name

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
