defmodule Hermitscale.Integrations.Action do
  @moduledoc "Declares a versioned catalog action backed by a provider's trusted operation definition."

  defmacro __using__(opts) do
    operations = opts |> Keyword.fetch!(:operations) |> Macro.expand(__CALLER__)
    operation = Keyword.fetch!(opts, :operation)
    {:module, ^operations} = Code.ensure_compiled(operations)
    definition = Map.fetch!(operations.definitions(), operation)

    opts = [
      id: definition.id,
      version: 1,
      kind: :step,
      params: definition.params,
      expr: Keyword.keys(definition.params),
      requires: [credentials: [provider: operations.provider_id(), scopes: definition.scopes]],
      default_policy: %{
        max_retries: if(definition.effect?, do: 0, else: 3),
        timeout_ms: 30_000,
        backoff: "exponential"
      }
    ]

    quote do
      use Hermitscale.Workflows.Nodes.Behaviour, unquote(Macro.escape(opts))

      @impl true
      def work(params, _input, %{credentials: credentials}) do
        case unquote(operations).execute(unquote(operation), params, credentials) do
          {:ok, result} -> result
          {:error, reason} -> Runic.Workflow.SingleOutput.Result.failure(reason)
        end
      end
    end
  end
end
