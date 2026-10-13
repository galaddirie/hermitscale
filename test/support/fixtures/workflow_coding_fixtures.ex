defmodule Hermitscale.WorkflowCodingFixtures do
  @moduledoc false
  import Hermitscale.WorkflowsFixtures

  def coding_graph(session_id) do
    valid_join_graph(%{
      "id" => "wf_coding",
      "name" => "Coding",
      "nodes" => [coding_node(session_id)],
      "connections" => []
    })
  end

  def mapped_coding_graph(session_id) do
    valid_join_graph(%{
      "id" => "wf_mapped_coding",
      "name" => "Mapped coding",
      "nodes" => [
        %{"id" => "items", "type" => "map", "version" => 1, "params" => %{}},
        coding_node(session_id),
        %{"id" => "results", "type" => "aggregate", "version" => 1, "params" => %{}}
      ],
      "connections" => [
        %{"from" => "items", "to" => "coding"},
        %{"from" => "coding", "to" => "results"}
      ]
    })
  end

  def coding_effect_graph(session_id) do
    graph = coding_graph(session_id)

    Map.merge(graph, %{
      "nodes" => graph["nodes"] ++ [Map.put(coding_node(session_id), "id", "effect")],
      "connections" => [%{"from" => "coding", "to" => "effect"}]
    })
  end

  defp coding_node(session_id) do
    %{
      "id" => "coding",
      "type" => "agents.codex.run",
      "version" => 1,
      "params" => %{
        "instructions" => "Update the source",
        "session_id" => session_id
      }
    }
  end
end
