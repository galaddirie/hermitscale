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
  end
end
