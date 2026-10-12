defmodule Hermitscale.Workflows.Nodes.Behaviour do
  @moduledoc """
  Behaviour implemented by code-defined workflow catalog nodes.

  Catalog nodes are static descriptions plus a pure builder. Use this module to
  generate a compile-time-validated `spec/0` and catalog marker.
  """

  @type kind :: :step | :join | :map | :reduce | :rule | :trigger
  @type spec :: %{
          required(:id) => String.t(),
          required(:version) => pos_integer(),
          required(:kind) => kind(),
          required(:inputs) => [atom()],
          required(:outputs) => [atom()],
          required(:params_schema) => keyword(),
          required(:expr_fields) => [atom()],
          required(:predicate_fields) => [atom()],
          required(:requires) => keyword(),
          required(:default_policy) => map(),
          required(:deprecated) => boolean()
        }
  @type ctx :: %{
          required(:name) => String.t(),
          optional(:parents) => [String.t()],
          optional(:main_count) => non_neg_integer(),
          optional(:ref_ids) => [String.t()],
          optional(:ambient) => map(),
          optional(:map) => String.t()
        }

  @callback spec() :: spec()
  @callback build(params :: map(), ctx :: ctx()) :: term()
  @callback work(params :: map(), item :: term(), deps :: map()) :: term()
  @callback validate_params(params :: map()) :: :ok | {:error, String.t()}

  @optional_callbacks validate_params: 1

  @kinds ~w(step join map reduce rule)a
  @options ~w(id version kind inputs outputs params expr predicate requires default_policy deprecated)a

  defmacro __using__(opts) do
    # Evaluate compile-time options so integration macros can pass module attrs
    # and helper-call results into the base node declaration.
    {opts, _binding} = Code.eval_quoted(opts, [], __CALLER__)
    spec = __compile_spec__!(opts, __CALLER__.module)

    quote do
      require Runic

      @behaviour Hermitscale.Workflows.Nodes.Behaviour
      @__node_spec__ unquote(Macro.escape(spec))

      @impl true
      def spec, do: @__node_spec__

      def __catalog_node__, do: @__node_spec__

      unquote(__gen_build__(spec))

      defoverridable build: 2
    end
  end

  @doc false
  def __compile_spec__!(opts, module) do
    assert!(keyword?(opts), module, "options must be a keyword list")
    assert!(Keyword.keys(opts) -- @options == [], module, "unknown node options")
    assert!(unique?(Keyword.keys(opts)), module, "node options must be unique")

    id = require_opt!(opts, :id, module)
    version = require_opt!(opts, :version, module)
    kind = require_opt!(opts, :kind, module)
    inputs = Keyword.get(opts, :inputs, [:main])
    outputs = Keyword.get(opts, :outputs, [:main])
    params = Keyword.get(opts, :params, [])
    expr_fields = Keyword.get(opts, :expr, [])
    predicate_fields = Keyword.get(opts, :predicate, [])
    requires = Keyword.get(opts, :requires, [])
    default_policy = Keyword.get(opts, :default_policy, %{})
    deprecated = Keyword.get(opts, :deprecated, false)

    assert!(is_binary(id) and id != "", module, "id must be a non-empty string")
    assert!(is_integer(version) and version > 0, module, "version must be a positive integer")
    assert!(kind in @kinds, module, "invalid kind #{inspect(kind)}")
    assert!(ports?(inputs), module, "inputs must be a non-empty list of atoms")
    assert!(ports?(outputs), module, "outputs must be a non-empty list of atoms")
    assert!(unique?(inputs), module, "inputs must be unique")
    assert!(unique?(outputs), module, "outputs must be unique")
    assert!(ports_or_empty?(expr_fields), module, "expr must be a list of atoms")
    assert!(ports_or_empty?(predicate_fields), module, "predicate must be a list of atoms")
    assert!(keyword?(requires), module, "requires must be a keyword list")
    assert!(is_map(default_policy), module, "default_policy must be a map")
    assert!(is_boolean(deprecated), module, "deprecated must be a boolean")

    params_schema = NimbleOptions.new!(params).schema

    assert!(
      expr_fields -- Keyword.keys(params_schema) == [],
      module,
      "expr fields must name declared params"
    )

    assert!(
      predicate_fields -- expr_fields == [],
      module,
      "predicate fields must be expression fields"
    )

    default_policy = Hermitscale.Workflows.Policy.normalize(default_policy)

    %{
      id: id,
      version: version,
      kind: kind,
      inputs: inputs,
      outputs: outputs,
      params_schema: params_schema,
      expr_fields: expr_fields,
      predicate_fields: predicate_fields,
      requires: requires,
      default_policy: default_policy,
      deprecated: deprecated
    }
  end

  @doc false
  # Steps and joins share one closure. Facts flow as bare values; the node
  # reconstructs its `$json`/`$node` view from the inputs Runic delivered (a
  # single value for 0/1 parent, an ordered list for a join of 2+ parents).
  def __gen_build__(%{kind: kind, requires: requires}) when kind in [:step, :join] do
    deps = deps_ast(requires)

    quote generated: true do
      @impl true
      def build(params, %{name: name, parents: parents, main_count: main_count}) do
        params_binding = Hermitscale.Workflows.Nodes.Params.bind(params)
        joined? = length(parents) >= 2

        Runic.step(
          fn input ->
            runtime = context(:_expr, default: %{})
            deps = unquote(deps)

            {main, node_map} =
              Hermitscale.Workflows.Expr.node_view(input, ^parents, ^main_count, ^joined?)

            expression_context =
              Hermitscale.Workflows.Expr.build_context(
                %{"json" => main, "node" => node_map},
                runtime
              )

            resolved_params =
              Hermitscale.Workflows.Nodes.Params.resolve!(^params_binding, expression_context)

            work(resolved_params, main, deps)
          end,
          name: name
        )
      end
    end
  end

  # Prepare normalizes the collection and zips in `$node` references. Native
  # Map owns fan-out and the mapper; the compiler composes the body and Reduce
  # through the public component API.
  def __gen_build__(%{kind: :map, requires: requires}) do
    deps = deps_ast(requires)

    quote generated: true do
      @impl true
      def build(params, %{name: name, ref_ids: ref_ids}) do
        params_binding = Hermitscale.Workflows.Nodes.Params.bind(params)

        prepare =
          Runic.step(
            fn input ->
              {collection, refs} =
                case ^ref_ids do
                  [] ->
                    {input, []}

                  ids ->
                    [collection | ref_values] = input
                    {collection, Enum.zip(ids, ref_values)}
                end

              # Only genuine lists fan out; a scalar/map becomes one element and
              # nil becomes none, so a misconfigured collection never crashes.
              collection
              |> List.wrap()
              |> Enum.map(fn element -> {element, refs} end)
            end,
            # `$` cannot appear in a node id, so these never collide with one.
            name: "#{name}$prepare"
          )

        mapper =
          Runic.step(
            fn {element, refs} ->
              runtime = context(:_expr, default: %{})
              deps = unquote(deps)

              node_map = Map.new(refs, fn {id, value} -> {id, %{"json" => value}} end)

              expression_context =
                Hermitscale.Workflows.Expr.build_context(
                  %{"json" => element, "node" => node_map},
                  runtime
                )

              resolved_params =
                Hermitscale.Workflows.Nodes.Params.resolve!(^params_binding, expression_context)

              work(resolved_params, element, deps)
            end,
            name: name
          )

        map = Runic.map([mapper], name: "#{name}$collection")
        {:region, prepare, map}
      end
    end
  end

  # Native Reduce folds per-element values. Its mapped coordinator invokes
  # reducer/2, so ambient expression namespaces remain captured at compile time.
  # The named Map binding identifies the owning collection through body Steps.
  def __gen_build__(%{kind: :reduce, requires: requires}) do
    deps = deps_ast(requires)

    quote generated: true do
      @impl true
      def build(params, %{name: name, ambient: ambient, map: map_name}) do
        params_binding = Hermitscale.Workflows.Nodes.Params.bind(params)

        reduce =
          Runic.reduce(
            Map.get(params, :initial),
            fn element, acc ->
              deps = Map.put(unquote(deps), :acc, acc)

              expression_context =
                %{"json" => element, "node" => %{}}
                |> Hermitscale.Workflows.Expr.build_context(^ambient)
                |> Map.put("acc", acc)

              resolved_params =
                Hermitscale.Workflows.Nodes.Params.resolve!(^params_binding, expression_context)

              work(resolved_params, element, deps)
            end,
            name: name,
            map: map_name
          )

        reduce
      end
    end
  end

  def __gen_build__(%{kind: kind}) do
    quote generated: true do
      @impl true
      def build(_params, _ctx) do
        raise ArgumentError,
              "generated build for #{unquote(kind)} nodes is not implemented; define build/2"
      end
    end
  end

  defp require_opt!(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{inspect(module)} missing required #{inspect(key)} option"
    end
  end

  defp ports?(list), do: is_list(list) and list != [] and Enum.all?(list, &is_atom/1)
  defp ports_or_empty?(list), do: is_list(list) and Enum.all?(list, &is_atom/1)
  defp unique?(list), do: length(Enum.uniq(list)) == length(list)

  defp deps_ast(requires) do
    {:%{}, [],
     Enum.map(requires, fn {key, _opts} ->
       {key, quote(do: context(unquote(key)))}
     end)}
  end

  defp assert!(true, _module, _message), do: :ok

  defp assert!(false, module, message) do
    raise ArgumentError, "#{inspect(module)} #{message}"
  end

  defp keyword?(list) when is_list(list), do: Enum.all?(list, &keyword_entry?/1)
  defp keyword?(_other), do: false

  defp keyword_entry?({key, _value}) when is_atom(key), do: true
  defp keyword_entry?(_entry), do: false
end
