defmodule Hermitscale.Workflows.Nodes.OpenAI.Responses.Create.V1 do
  @moduledoc false
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "openai.responses.create",
    version: 1,
    kind: :step,
    requires: [credentials: [provider: "openai", scopes: []]],
    default_policy: %{max_retries: 0, timeout_ms: 130_000},
    expr: [:model, :input, :instructions, :max_output_tokens],
    params: [
      model: [
        type: :string,
        required: true,
        doc: "OpenAI model ID available to the connected project."
      ],
      input: [type: :any, required: true, doc: "Text or a Responses API input item list."],
      instructions: [type: :string, default: "", doc: "Instructions for this response."],
      max_output_tokens: [
        type: :pos_integer,
        default: 4096,
        doc: "Maximum output tokens, including reasoning."
      ]
    ]

  alias Hermitscale.Integrations.OpenAI.Client
  alias Runic.Workflow.SingleOutput.Result

  @impl true
  def work(
        %{model: model, input: input, instructions: instructions, max_output_tokens: max_tokens},
        _item,
        %{credentials: ref}
      ) do
    case Client.create_response(ref, %{
           "model" => model,
           "input" => input,
           "instructions" => instructions,
           "max_output_tokens" => max_tokens
         }) do
      {:ok, response} -> response
      {:error, reason} -> Result.failure(reason)
    end
  end
end
