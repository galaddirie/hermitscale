defmodule Hermitscale.CollectionWorkflowsFixtures do
  @moduledoc false

  def branching_collection_graph do
    graph(
      "branching",
      [
        node("source", "test.identity_probe"),
        node("items", "map"),
        node("left", "test.collection_value", %{"value" => "{{ $json | times: 10 }}"}),
        node("right", "test.collection_value", %{"value" => "{{ $json | plus: 1 }}"}),
        node("right_next", "test.collection_value", %{"value" => "{{ $json | times: 100 }}"}),
        node("join", "merge"),
        node("collected", "aggregate")
      ],
      [
        {"source", "items"},
        {"items", "left"},
        {"items", "right"},
        {"right", "right_next"},
        {"left", "join", 0},
        {"right_next", "join", 1},
        {"join", "collected"}
      ]
    )
  end

  def nested_collection_graph do
    graph(
      "nested",
      [
        node("source", "test.identity_probe"),
        node("outer", "map"),
        node("inner", "map"),
        node("inner_collected", "aggregate"),
        node("collected", "aggregate")
      ],
      [
        {"source", "outer"},
        {"outer", "inner"},
        {"inner", "inner_collected"},
        {"inner_collected", "collected"}
      ]
    )
  end

  def payload_join_graph(mode, left, right) do
    graph(
      "payload_join",
      [
        node("source", "test.identity_probe"),
        node("left", "test.collection_value", %{"value" => left}),
        node("right", "test.collection_value", %{"value" => right}),
        node("join", "merge", %{"mode" => mode})
      ],
      [
        {"source", "left"},
        {"source", "right"},
        {"left", "join", 0},
        {"right", "join", 1}
      ]
    )
  end

  def history_collection_graph do
    base = branching_collection_graph()

    per_item =
      node("view", "test.collection_value", %{
        "value" => %{
          "left" => "{{ $node[\"left\"].json }}",
          "right" => "{{ $node[\"right_next\"].json }}",
          "item" => "{{ $item }}",
          "index" => "{{ $itemIndex }}"
        }
      })

    after_collection =
      node("history", "test.collection_value", %{
        "value" => %{
          "items" => "{{ $json }}",
          "left" => "{{ $node[\"left\"] }}",
          "count" => "{{ $node[\"left\"] | size }}"
        }
      })

    connections =
      Enum.reject(base["connections"], &(&1["to"] == "collected")) ++
        [edge({"join", "view"}), edge({"view", "collected"}), edge({"collected", "history"})]

    %{
      base
      | "nodes" => base["nodes"] ++ [per_item, after_collection],
        "connections" => connections
    }
  end

  def skipped_collection_graph(
        on_missing,
        right_params \\ %{"skip" => "{{ $json.skip }}"},
        policy \\ nil
      ) do
    graph(
      "skipped",
      [
        node("source", "test.identity_probe"),
        node("items", "map"),
        node("left", "test.collection_value", %{"value" => "{{ $json.n }}"}),
        node(
          "right",
          "test.collection_value",
          Map.put(right_params, "value", "{{ $json.n | times: 10 }}"),
          policy
        ),
        node("join", "merge", %{"on_missing" => on_missing}),
        node("collected", "aggregate")
      ],
      [
        {"source", "items"},
        {"items", "left"},
        {"items", "right"},
        {"left", "join", 0},
        {"right", "join", 1},
        {"join", "collected"}
      ]
    )
  end

  def effect_collection_graph do
    graph(
      "effects",
      [
        node("source", "test.identity_probe"),
        node("items", "map"),
        node("effects", "test.collection_effect"),
        node("collected", "aggregate")
      ],
      [{"source", "items"}, {"items", "effects"}, {"effects", "collected"}]
    )
  end

  def skipped_payload_join_graph(mode) do
    payload_join_graph(mode, [1, 2], ["a"])
    |> Map.update!("nodes", fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "right"} = node -> put_in(node["params"]["skip"], true)
        %{"id" => "join"} = node -> put_in(node["params"]["on_missing"], "nil")
        node -> node
      end)
    end)
  end

  defp node(id, type, params \\ %{}, policy \\ nil) do
    node = %{"id" => id, "type" => type, "version" => 1, "params" => params}
    if is_nil(policy), do: node, else: Map.put(node, "policy", policy)
  end

  defp graph(name, nodes, edges) do
    %{
      "schema_version" => 1,
      "id" => "wf_collection_#{name}",
      "name" => "collection_#{name}",
      "nodes" => nodes,
      "connections" => Enum.map(edges, &edge/1)
    }
  end

  defp edge({from, to}), do: %{"from" => from, "to" => to}
  defp edge({from, to, slot}), do: %{"from" => from, "to" => to, "to_input" => slot}
end
