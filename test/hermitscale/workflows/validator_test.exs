defmodule Hermitscale.Workflows.ValidatorTest do
  use ExUnit.Case, async: true

  import Hermitscale.WorkflowsFixtures

  alias Hermitscale.Workflows.Validator

  describe "validate/1" do
    test "accepts a valid graph" do
      assert :ok = Validator.validate(valid_join_graph())
    end

    test "returns all structural issues" do
      graph =
        valid_join_graph(%{
          "nodes" => [
            %{"id" => "validate", "type" => "missing", "version" => 1, "params" => %{}},
            %{
              "id" => "validate",
              "type" => "test.identity_probe",
              "version" => 1,
              "params" => %{}
            }
          ],
          "connections" => [%{"from" => "validate", "to" => "missing"}]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :duplicate_node_id))
      assert Enum.any?(issues, &(&1.code == :unknown_catalog_node))
      assert Enum.any?(issues, &(&1.code == :missing_node))
    end

    test "rejects non-contiguous join slots" do
      graph =
        valid_join_graph(%{
          "connections" => [
            %{"from" => "validate", "to" => "inventory"},
            %{"from" => "validate", "to" => "fraud"},
            %{"from" => "inventory", "to" => "decide", "to_input" => 1},
            %{"from" => "fraud", "to" => "decide", "to_input" => 1}
          ]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :join_input_slots))
    end

    test "runs node validate_params callback after schema params casting" do
      graph =
        authoring_probe_graph(%{
          "nodes" => [
            %{
              "id" => "probe",
              "type" => "test.authoring_probe",
              "version" => 1,
              "params" => %{"count" => 3}
            }
          ]
        })

      assert {:error, issues} = Validator.validate(graph)

      assert Enum.any?(
               issues,
               &match?(
                 %Validator.Issue{
                   path: "$.nodes[0].params",
                   code: :invalid_params,
                   message: "count must be even"
                 },
                 &1
               )
             )
    end

    test "rejects removed scheduler policy fields" do
      graph =
        valid_join_graph(%{
          "nodes" => [
            %{
              "id" => "validate",
              "type" => "test.identity_probe",
              "version" => 1,
              "params" => %{},
              "policy" => %{"execution_mode" => "sync", "priority" => "normal"}
            },
            %{
              "id" => "inventory",
              "type" => "test.identity_probe",
              "version" => 1,
              "params" => %{}
            },
            %{
              "id" => "fraud",
              "type" => "test.identity_probe",
              "version" => 1,
              "params" => %{}
            },
            %{
              "id" => "decide",
              "type" => "test.join_probe",
              "version" => 1,
              "params" => %{}
            }
          ]
        })

      assert {:error, issues} = Validator.validate(graph)

      assert Enum.any?(
               issues,
               &match?(
                 %Validator.Issue{
                   path: "$.nodes[0].policy.execution_mode",
                   code: :unknown_policy
                 },
                 &1
               )
             )

      assert Enum.any?(
               issues,
               &match?(
                 %Validator.Issue{
                   path: "$.nodes[0].policy.priority",
                   code: :unknown_policy
                 },
                 &1
               )
             )
    end

    test "rejects expressions that reference missing nodes" do
      graph =
        expression_probe_graph(%{
          "nodes" => [
            %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
            %{
              "id" => "probe",
              "type" => "test.expression_probe",
              "version" => 1,
              "params" => %{"message" => "{{ $node[\"missing\"].json.email }}"}
            }
          ],
          "connections" => [%{"from" => "source", "to" => "probe"}]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :missing_expression_node))
    end

    test "rejects expressions that reference non-upstream nodes" do
      graph =
        expression_probe_graph(%{
          "nodes" => [
            %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
            %{"id" => "other", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
            %{
              "id" => "probe",
              "type" => "test.expression_probe",
              "version" => 1,
              "params" => %{"message" => "{{ $node[\"other\"].json.email }}"}
            }
          ],
          "connections" => [%{"from" => "source", "to" => "probe"}]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :non_upstream_expression_node))
    end

    test "rejects $node references inside reduce nodes" do
      graph =
        map_reduce_graph(%{
          "nodes" => [
            %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
            %{
              "id" => "mapper",
              "type" => "test.expression_map_probe",
              "version" => 1,
              "params" => %{"value" => "{{ $json.n }}"}
            },
            %{
              "id" => "summer",
              "type" => "test.expression_reduce_probe",
              "version" => 1,
              "params" => %{
                "initial" => 0,
                "value" => "{{ $node[\"source\"].json }}"
              }
            }
          ],
          "connections" => [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "summer"}
          ]
        })

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :node_ref_unsupported_in_reduce))
    end

    test "accepts a linear map region closed by reduce" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map"),
            region_node("each", "test.identity_probe"),
            region_node("summer", "reduce", %{
              "initial" => 0,
              "value" => "{{ $acc | plus: $json }}"
            })
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "each"},
            %{"from" => "each", "to" => "summer"}
          ]
        )

      assert :ok = Validator.validate(graph)
    end

    test "rejects reduce nodes without an owning map region" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("summer", "reduce", %{
              "initial" => 0,
              "value" => "{{ $acc | plus: $json }}"
            })
          ],
          [%{"from" => "source", "to" => "summer"}]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :reduce_without_map))
    end

    test "rejects reduce nodes after an already closed map region" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map"),
            region_node("first_reduce", "reduce", %{
              "initial" => 0,
              "value" => "{{ $acc | plus: $json }}"
            }),
            region_node("second_reduce", "reduce", %{
              "initial" => 0,
              "value" => "{{ $acc | plus: $json }}"
            })
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "first_reduce"},
            %{"from" => "first_reduce", "to" => "second_reduce"}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :reduce_without_map))
    end

    test "rejects list-producing step to reduce" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("left", "test.identity_probe"),
            region_node("right", "test.identity_probe"),
            region_node("merged", "merge", %{"mode" => "append"}),
            region_node("summer", "reduce", %{
              "initial" => 0,
              "value" => "{{ $acc | plus: $json }}"
            })
          ],
          [
            %{"from" => "source", "to" => "left"},
            %{"from" => "source", "to" => "right"},
            %{"from" => "left", "to" => "merged", "to_input" => 0},
            %{"from" => "right", "to" => "merged", "to_input" => 1},
            %{"from" => "merged", "to" => "summer"}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :reduce_without_map))
    end

    test "rejects reduce nodes with multiple owning map regions" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("left_map", "map"),
            region_node("right_map", "map"),
            region_node("summer", "reduce", %{
              "initial" => 0,
              "value" => "{{ $acc | plus: $json }}"
            })
          ],
          [
            %{"from" => "source", "to" => "left_map"},
            %{"from" => "source", "to" => "right_map"},
            %{"from" => "left_map", "to" => "summer", "to_input" => 0},
            %{"from" => "right_map", "to" => "summer", "to_input" => 1}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :reduce_ambiguous_map))
      assert Enum.any?(issues, &(&1.code == :reduce_parent_count))
    end

    test "rejects map region branching before reduce" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map"),
            region_node("left", "test.identity_probe"),
            region_node("right", "test.identity_probe")
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "left"},
            %{"from" => "mapper", "to" => "right"}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :map_region_branch))
    end

    test "rejects nested maps and joins inside map regions" do
      nested_map_graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("outer", "map"),
            region_node("inner", "map")
          ],
          [
            %{"from" => "source", "to" => "outer"},
            %{"from" => "outer", "to" => "inner"}
          ]
        )

      join_graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map"),
            region_node("merged", "merge", %{"mode" => "append"})
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "merged"}
          ]
        )

      assert {:error, nested_issues} = Validator.validate(nested_map_graph)
      assert Enum.any?(nested_issues, &(&1.code == :unsupported_map_region_node))

      assert {:error, join_issues} = Validator.validate(join_graph)
      assert Enum.any?(join_issues, &(&1.code == :unsupported_map_region_node))
    end

    test "rejects node references to per-item map region nodes" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map"),
            region_node("each", "test.expression_probe", %{
              "message" => "{{ $node[\"mapper\"].json }}"
            }),
            region_node("summer", "reduce", %{
              "initial" => [],
              "value" => "{{ $acc | push: $json.message }}"
            }),
            region_node("after", "test.expression_probe", %{
              "message" => "{{ $node[\"each\"].json }}"
            })
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "each"},
            %{"from" => "each", "to" => "summer"},
            %{"from" => "summer", "to" => "after"}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :node_ref_unsupported_in_map_region))
      assert Enum.any?(issues, &(&1.code == :map_region_node_ref))
    end

    test "returns connection issues for map regions with missing children" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map")
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "missing"}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :missing_node))
    end

    test "returns cycle issues for cyclic map regions" do
      graph =
        region_graph(
          [
            region_node("source", "test.identity_probe"),
            region_node("mapper", "map"),
            region_node("a", "test.identity_probe"),
            region_node("b", "test.identity_probe")
          ],
          [
            %{"from" => "source", "to" => "mapper"},
            %{"from" => "mapper", "to" => "a"},
            %{"from" => "a", "to" => "b"},
            %{"from" => "b", "to" => "a"}
          ]
        )

      assert {:error, issues} = Validator.validate(graph)
      assert Enum.any?(issues, &(&1.code == :cycle))
    end
  end

  defp region_node(id, type, params \\ %{}),
    do: %{"id" => id, "type" => type, "version" => 1, "params" => params}

  defp region_graph(nodes, connections) do
    %{
      "schema_version" => 1,
      "id" => "wf_map_region",
      "name" => "map_region",
      "nodes" => nodes,
      "connections" => connections
    }
  end
end
