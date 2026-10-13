defmodule Hermitscale.Workflows.Replay do
  @moduledoc """
  Restores accepted incremental events against a matching compiled workflow.

  A definition fingerprint checks topology before replay. Component definitions
  in the event stream are checked for matching identities, then excluded from
  source evaluation.
  Legacy vendor identities, missing components and graph snapshots are rejected;
  this is not a migration of histories across engine or callback versions.
  """

  alias Hermitscale.Workflows.DefinitionRecorded
  alias Runic.Identity
  alias Runic.Workflow
  alias Runic.Workflow.{ComponentAdded, ReactionOccurred}

  @node_fields [
    :node_hash,
    :step_hash,
    :fan_out_hash,
    :fan_in_hash,
    :join_hash,
    :parent_hash,
    :condition_hash,
    :accumulator_hash
  ]
  @ancestry_fields [:ancestry, :emitted_ancestry, :result_ancestry, :init_ancestry]

  @doc """
  Creates the definition record persisted before Runic's initial build events.

  Call on the freshly compiled workflow, before injecting runtime credentials.
  """
  def definition_event(%Workflow{} = base) do
    definition = {
      Enum.sort(Map.keys(base.graph.vertices)),
      base.graph.edges,
      base.graph.edge_properties,
      base.components,
      canonical_policies(base.scheduler_policies),
      base.run_context
    }

    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(definition, [:deterministic]))
    %DefinitionRecorded{fingerprint: fingerprint}
  end

  # Compiled PCRE resources have a fresh reference on each compilation. Their
  # authored source and options identify a scheduler matcher across restarts.
  defp canonical_policies(policies) do
    Enum.map(policies, fn
      {{:name, %Regex{} = matcher}, policy} ->
        {{:name, {:regex, Regex.source(matcher), Regex.opts(matcher)}}, policy}

      entry ->
        entry
    end)
  end

  @doc """
  Replays compatible incremental events, preserving runnable lifecycle records.

  Returns `{:error, :incompatible_workflow_events}` when an event references a
  changed definition, an old or absent component, a removed event module, or a
  legacy graph snapshot. Histories without a definition record are rejected.
  """
  @spec restore(Enumerable.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, :incompatible_workflow_events}
  def restore(events, %Workflow{} = base) do
    events = Enum.to_list(events)

    case matching_definition?(events, base) and Enum.all?(events, &compatible_event?(&1, base)) do
      true ->
        workflow =
          events
          |> Enum.reject(&(is_struct(&1, ComponentAdded) or is_struct(&1, DefinitionRecorded)))
          |> Workflow.from_events(base)

        {:ok, workflow}

      false ->
        {:error, :incompatible_workflow_events}
    end
  end

  defp matching_definition?([%DefinitionRecorded{} = record | _events], base),
    do: record == definition_event(base)

  defp matching_definition?(_events, _base), do: false

  defp compatible_event?(%DefinitionRecorded{} = record, base),
    do: record == definition_event(base)

  # Native Map imports a hash-less internal build header. Its named component
  # must exist; runtime events still have to reference matching compiled nodes.
  defp compatible_event?(%ComponentAdded{hash: nil, name: name}, base)
       when is_atom(name) or is_binary(name) do
    match?(%Workflow.Map{}, Workflow.get_component(base, name))
  end

  defp compatible_event?(%ComponentAdded{hash: hash}, base), do: known_node?(base, hash)
  defp compatible_event?(%ReactionOccurred{}, _base), do: false

  defp compatible_event?(%{__struct__: module} = event, base) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) and
      Enum.all?(@node_fields, &compatible_node_field?(event, &1, base)) and
      Enum.all?(@ancestry_fields, &compatible_ancestry?(Map.get(event, &1), base))
  end

  defp compatible_event?(_event, _base), do: false

  defp compatible_node_field?(event, field, base) do
    case Map.fetch(event, field) do
      {:ok, hash} -> known_node?(base, hash)
      :error -> true
    end
  end

  defp compatible_ancestry?(nil, _base), do: true
  defp compatible_ancestry?({producer, _parent}, base), do: known_node?(base, producer)
  defp compatible_ancestry?(_ancestry, _base), do: false

  defp known_node?(base, %Identity{} = hash), do: Map.has_key?(base.graph.vertices, hash)
  defp known_node?(_base, _hash), do: false
end
