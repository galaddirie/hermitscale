defmodule Hermitscale.Workflows.Nodes.Behaviour do
  @moduledoc """
  Behaviour implemented by code-defined workflow catalog nodes.
  """

  @type kind :: :step | :join | :map | :reduce | :rule
  @type spec :: %{
          required(:id) => String.t(),
          required(:version) => pos_integer(),
          required(:kind) => kind(),
          required(:inputs) => [atom()],
          required(:outputs) => [atom()],
          required(:params_schema) => keyword(),
          required(:deprecated) => boolean()
        }

  @callback spec() :: spec()
  @callback build(params :: map(), ctx :: %{name: String.t(), inputs: [String.t()]}) :: term()

  defmacro __using__(_opts) do
    quote do
      @behaviour Hermitscale.Workflows.Nodes.Behaviour

      def __catalog_node__, do: spec()
    end
  end
end
