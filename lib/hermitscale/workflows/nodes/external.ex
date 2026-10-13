defmodule Hermitscale.Workflows.Nodes.External do
  @moduledoc "Catalog declaration for effects admitted and continued by Workflows."

  defmacro __using__(opts) do
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)
    opts = Keyword.put_new(opts, :default_policy, %{max_retries: 0})

    quote do
      use Hermitscale.Workflows.Nodes.Behaviour, unquote(Macro.escape(opts))

      def __external_operation__, do: true

      @impl true
      def work(_params, _item, _deps) do
        raise "external catalog nodes must execute through durable Workflows operations"
      end
    end
  end
end
