defmodule Hermitscale.Workflows.Nodes.Behaviour do
  @moduledoc """
  Behaviour implemented by code-defined workflow catalog nodes.

  Catalog nodes are static descriptions plus a pure builder. Use this module to
  generate a compile-time-validated `spec/0` and catalog marker.
  """

  @type kind :: :step | :join | :map | :reduce | :rule
  @type spec :: %{
          required(:id) => String.t(),
          required(:version) => pos_integer(),
          required(:kind) => kind(),
          required(:inputs) => [atom()],
          required(:outputs) => [atom()],
          required(:params_schema) => keyword(),
          required(:requires) => keyword(),
          required(:default_policy) => map(),
          required(:deprecated) => boolean()
        }
  @type ctx :: %{required(:name) => String.t(), required(:inputs) => [String.t()]}

  @callback spec() :: spec()
  @callback build(params :: map(), ctx :: ctx()) :: term()
  @callback validate_params(params :: map()) :: :ok | {:error, String.t()}

  @optional_callbacks validate_params: 1

  @kinds ~w(step join map reduce rule)a

  defmacro __using__(opts) do
    # Evaluate compile-time options so integration macros can pass module attrs
    # and helper-call results into the base node declaration.
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)
    spec = __compile_spec__!(opts, __CALLER__.module)

    quote do
      @behaviour Hermitscale.Workflows.Nodes.Behaviour
      @__node_spec__ unquote(Macro.escape(spec))

      @impl true
      def spec, do: @__node_spec__

      def __catalog_node__, do: @__node_spec__
    end
  end

  @doc false
  def __compile_spec__!(opts, module) do
    assert!(keyword?(opts), module, "options must be a keyword list")

    id = require_opt!(opts, :id, module)
    version = require_opt!(opts, :version, module)
    kind = require_opt!(opts, :kind, module)
    inputs = Keyword.get(opts, :inputs, [:main])
    outputs = Keyword.get(opts, :outputs, [:main])
    params = Keyword.get(opts, :params, [])
    requires = Keyword.get(opts, :requires, [])
    default_policy = Keyword.get(opts, :default_policy, %{})
    deprecated = Keyword.get(opts, :deprecated, false)

    assert!(is_binary(id), module, "id must be a string")
    assert!(is_integer(version) and version > 0, module, "version must be a positive integer")
    assert!(kind in @kinds, module, "invalid kind #{inspect(kind)}")
    assert!(ports?(inputs), module, "inputs must be a non-empty list of atoms")
    assert!(ports?(outputs), module, "outputs must be a non-empty list of atoms")
    assert!(keyword?(requires), module, "requires must be a keyword list")
    assert!(is_map(default_policy), module, "default_policy must be a map")
    assert!(is_boolean(deprecated), module, "deprecated must be a boolean")

    default_policy = Hermitscale.Workflows.Policy.normalize(default_policy)

    %{
      id: id,
      version: version,
      kind: kind,
      inputs: inputs,
      outputs: outputs,
      params_schema: NimbleOptions.new!(params).schema,
      requires: requires,
      default_policy: default_policy,
      deprecated: deprecated
    }
  end

  defp require_opt!(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{inspect(module)} missing required #{inspect(key)} option"
    end
  end

  defp ports?(list), do: is_list(list) and list != [] and Enum.all?(list, &is_atom/1)

  defp assert!(true, _module, _message), do: :ok

  defp assert!(false, module, message) do
    raise ArgumentError, "#{inspect(module)} #{message}"
  end

  defp keyword?(list) when is_list(list), do: Enum.all?(list, &keyword_entry?/1)
  defp keyword?(_other), do: false

  defp keyword_entry?({key, _value}) when is_atom(key), do: true
  defp keyword_entry?(_entry), do: false
end
