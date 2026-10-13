defmodule Hermitscale.Workflows.Engine.Node do
  @moduledoc """
  Catalog execution on Runic's native single-output lifecycle.

  Durable facts carry item lineage; callback runtime supplies credentials and
  other dependencies afresh. Empty and skipped outcomes flow as markers so a
  branch can close without cancelling unrelated item occurrences.
  """

  @behaviour Runic.Workflow.SingleOutput

  alias Hermitscale.Workflows.Engine.{Context, Metadata}
  alias Hermitscale.Workflows.Nodes.Params
  alias Runic.Identity
  alias Runic.Workflow.Fact
  alias Runic.Workflow.SingleOutput
  alias Runic.Workflow.SingleOutput.Result

  defstruct [
    :name,
    :hash,
    :module,
    :code_digest,
    :params,
    :kind,
    :requires,
    :build_context,
    meta_refs: []
  ]

  def new(module, params, %{name: name} = build_context) do
    spec = module.__catalog_node__()
    binding = Params.bind(params)
    build_context = Map.take(build_context, [:name, :parents, :map])
    code_digest = module.module_info(:md5)

    definition = %{
      module: module,
      code_digest: code_digest,
      requires: spec.requires,
      params: binding,
      context: build_context,
      kind: spec.kind
    }

    %__MODULE__{
      name: name,
      hash: Identity.derive(:component_definition, definition),
      module: module,
      code_digest: code_digest,
      params: binding,
      kind: spec.kind,
      requires: spec.requires,
      build_context: build_context,
      meta_refs:
        Enum.map(spec.requires, fn {key, _options} ->
          %{kind: :context, target: key, context_key: key, field_path: []}
        end)
    }
  end

  def __runic_single_output__, do: true

  @doc false
  def execute(node, runnable) do
    result = SingleOutput.execute(node, runnable)

    case result do
      %{status: :failed, error: error} ->
        case Metadata.runtime_resources?(error) do
          true -> %{result | error: {:node_execution_failed, node.name, error_kind(error)}}
          false -> result
        end

      %{status: :completed} ->
        result
    end
  end

  @doc "Whether this node delegates its effect to a durable context operation."
  def external?(%__MODULE__{module: module}),
    do: function_exported?(module, :__external_operation__, 0)

  def external?(_component), do: false

  @doc "Resolves non-secret request data without executing the external effect."
  def external_request(runnable) do
    callback = Runic.Workflow.SingleOutput.Context.from_runnable(runnable)
    input_id = Map.fetch!(callback.meta, :_hermitscale_input_id)
    context = Context.new(runnable.input_fact.value, runnable.input_fact.meta, callback, input_id)

    runnable.node.params
    |> :erlang.binary_to_term([:safe])
    |> Hermitscale.Workflows.Expr.resolve(Context.expressions(context))
  end

  @doc "Creates native completion events and preserves the original occurrence lineage."
  def complete_external(runnable, result) do
    context = %{
      runnable.context
      | run_context: Map.put(runnable.context.run_context, :_hermitscale_external_result, result)
    }

    execute(runnable.node, %{runnable | context: context})
  end

  defp error_kind(%module{}), do: module
  defp error_kind({kind, _reason}) when kind in [:error, :exit, :throw], do: kind
  defp error_kind(_error), do: :runtime_resource

  @impl true
  def run(node, value, callback_context) do
    metadata = callback_context.input_metadata
    state = Metadata.state(metadata)

    cond do
      Map.has_key?(callback_context.runtime, :_hermitscale_external_result) ->
        callback_context.runtime
        |> Map.fetch!(:_hermitscale_external_result)
        |> interpret(node, metadata, callback_context)

      Map.has_key?(callback_context.meta, :_hermitscale_skip) ->
        skipped = Map.fetch!(callback_context.meta, :_hermitscale_skip)

        metadata =
          Metadata.put_state(
            metadata,
            Map.put(state, :failed_attempt, Map.take(skipped, [:attempt_id, :attempt_number]))
          )

        marker(node, metadata, callback_context, :skipped, skipped.reason)

      node.kind in [:reduce, :aggregate] ->
        run_collection(node, value, metadata, callback_context)

      state.status == :empty ->
        marker(node, metadata, callback_context, :empty)

      node.kind == :join and Map.has_key?(state, :joined) ->
        run_join(node, value, metadata, callback_context)

      state.status in [:empty, :skipped] ->
        marker(node, metadata, callback_context, state.status)

      true ->
        run_item(node, value, metadata, callback_context)
    end
  end

  def skip_failure(runnable, _error) do
    {:retry_with,
     %{
       _hermitscale_skip: %{
         reason: "retries exhausted",
         attempt_id: runnable.attempt_id,
         attempt_number: runnable.attempt_number
       }
     }}
  end

  defp run_item(node, value, metadata, callback_context) do
    input_id = Map.fetch!(callback_context.meta, :_hermitscale_input_id)
    context = Context.new(value, metadata, callback_context, input_id)
    params = Params.resolve!(node.params, Context.expressions(context))
    deps = dependencies(node, context)

    node.module.work(params, value, deps)
    |> interpret(node, metadata, callback_context)
  end

  defp run_join(node, value, metadata, callback_context) do
    joined = Map.fetch!(Metadata.state(metadata), :joined)
    missing = Enum.reject(joined, &(&1.status == :ok))
    params = :erlang.binary_to_term(node.params, [:safe])

    case {missing, Map.get(params, :on_missing, "fail")} do
      {[], _mode} ->
        run_item(node, value, ready_metadata(metadata), callback_context)

      {missing, "fail"} ->
        Result.failure({:missing_join_inputs, node.name, Enum.map(missing, & &1.node)})

      {_missing, "nil"} ->
        missing_value =
          if Map.get(params, :mode) in ~w(zip_nil zip_shortest zip_cycle cartesian flatten),
            do: [],
            else: nil

        values =
          Enum.map(joined, fn entry ->
            if entry.status == :ok, do: entry.value, else: missing_value
          end)

        run_item(node, values, ready_metadata(metadata), callback_context)

      {_missing, "omit"} ->
        values = for entry <- joined, entry.status == :ok, do: entry.value
        run_item(node, values, ready_metadata(metadata), callback_context)
    end
  end

  defp run_collection(node, _value, metadata, callback_context) do
    state = Metadata.state(metadata)

    cond do
      Enum.any?(state.frames, &(&1.size == 0)) -> marker(node, metadata, callback_context, :empty)
      state.status == :skipped -> marker(node, metadata, callback_context, :skipped)
      true -> fold_collection(node, metadata, callback_context)
    end
  end

  defp fold_collection(node, metadata, callback_context) do
    entries = Map.fetch!(Metadata.state(metadata), :collected)
    params = :erlang.binary_to_term(node.params, [:safe])
    initial = if node.kind == :reduce, do: Map.fetch!(params, :initial), else: []

    result =
      Enum.reduce_while(entries, {:ok, initial, metadata}, fn entry,
                                                              {:ok, acc, output_metadata} ->
        case Metadata.state(entry.metadata).status do
          :ok ->
            context = Context.new(entry.value, entry.metadata, callback_context, entry.id)

            params =
              Params.resolve!(node.params, Map.put(Context.expressions(context), "acc", acc))

            deps = node |> dependencies(context) |> Map.put(:acc, acc)

            case node.module.work(params, entry.value, deps) do
              %Result{status: :failure} = failure ->
                {:halt, failure}

              {:skip, _reason} ->
                {:cont, {:ok, acc, output_metadata}}

              %Result{status: :value, value: value, metadata: custom} ->
                accumulate(node.kind, value, acc, custom_metadata(output_metadata, custom))

              value ->
                accumulate(node.kind, value, acc, output_metadata)
            end

          status when status in [:empty, :skipped] ->
            {:cont, {:ok, acc, output_metadata}}
        end
      end)

    case result do
      {:ok, values, output_metadata} when node.kind == :aggregate ->
        output(node, Enum.reverse(values), ready_metadata(output_metadata), callback_context)

      {:ok, value, output_metadata} ->
        output(node, value, ready_metadata(output_metadata), callback_context)

      %Result{status: :failure} = failure ->
        failure
    end
  end

  defp accumulate(:aggregate, value, acc, metadata), do: {:cont, {:ok, [value | acc], metadata}}
  defp accumulate(:reduce, value, _acc, metadata), do: {:cont, {:ok, value, metadata}}

  defp dependencies(node, context) do
    Map.new(node.requires, fn {key, _options} -> {key, Map.fetch!(context.runtime, key)} end)
    |> Map.put(:context, context)
  end

  defp interpret(%Result{status: :failure} = failure, _node, _metadata, _context), do: failure

  defp interpret(%Result{status: :value, value: value, metadata: custom}, node, metadata, context) do
    output(node, value, custom_metadata(metadata, custom), context)
  end

  defp interpret({:skip, reason}, node, metadata, context),
    do: marker(node, metadata, context, :skipped, reason)

  defp interpret(value, node, metadata, context), do: output(node, value, metadata, context)

  defp custom_metadata(metadata, custom) do
    Result.validate_metadata!(custom)

    if Map.has_key?(custom, :hermitscale) do
      raise ArgumentError, "catalog callbacks cannot replace item correlation metadata"
    end

    metadata |> Map.merge(custom) |> Metadata.validate!()
  end

  defp output(node, value, metadata, context) do
    input_id = Map.fetch!(context.meta, :_hermitscale_input_id)
    id = Fact.new(value: value, ancestry: {node.hash, input_id}).hash

    metadata =
      metadata
      |> Metadata.put_state(%{
        Metadata.state(metadata)
        | parents: Enum.uniq([input_id | Metadata.state(metadata).parents])
      })
      |> Metadata.record(node.name, value, id)

    Result.value(value, metadata: metadata)
  end

  defp marker(node, metadata, context, status, reason \\ nil) do
    state = Metadata.state(metadata) |> Map.put(:status, status)
    state = if is_nil(reason), do: state, else: Map.put(state, :reason, reason)
    output(node, nil, Metadata.put_state(metadata, state), context)
  end

  defp ready_metadata(metadata) do
    state =
      Metadata.state(metadata)
      |> Map.drop([:joined, :collected, :reason])
      |> Map.put(:status, :ok)

    Metadata.put_state(metadata, state)
  end
end
