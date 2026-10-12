defmodule Hermitscale.WorkflowsFixtures do
  @moduledoc """
  Test fixtures for workflow graph definitions.
  """

  def valid_join_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_order_fulfillment",
        "name" => "order_fulfillment",
        "nodes" => [
          %{"id" => "validate", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "inventory",
            "type" => "test.identity_probe",
            "version" => 1,
            "params" => %{}
          },
          %{"id" => "fraud", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{"id" => "decide", "type" => "test.join_probe", "version" => 1, "params" => %{}}
        ],
        "connections" => [
          %{"from" => "validate", "to" => "inventory"},
          %{"from" => "validate", "to" => "fraud"},
          %{"from" => "inventory", "to" => "decide", "to_input" => 0},
          %{"from" => "fraud", "to" => "decide", "to_input" => 1}
        ]
      },
      attrs
    )
  end

  def graph_attrs(attrs \\ %{}) do
    attrs = Map.new(attrs)
    definition = valid_join_graph()

    Map.merge(
      %{
        id: definition["id"],
        name: definition["name"],
        schema_version: definition["schema_version"],
        definition: definition,
        status: :active
      },
      attrs
    )
  end

  def authoring_probe_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_authoring_probe",
        "name" => "authoring_probe",
        "nodes" => [
          %{
            "id" => "probe",
            "type" => "test.authoring_probe",
            "version" => 1,
            "params" => %{"count" => 2}
          }
        ],
        "connections" => []
      },
      attrs
    )
  end

  def credential_probe_graph(attrs \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_credential_probe",
        "name" => "credential_probe",
        "nodes" => [
          %{
            "id" => "probe",
            "type" => "test.credential_probe",
            "version" => 1,
            "params" => %{},
            "connection" => %{"provider" => "test.credentials", "account_id" => "data_test"}
          }
        ],
        "connections" => []
      },
      Map.new(attrs)
    )
  end

  def credential_reference_fixture(provider \\ "google", account_id \\ "data_google") do
    %Hermitscale.Integrations.CredentialRef{
      execution_context: %Hermitscale.Integrations.ExecutionContext{
        organization_id: "org_test",
        actor_user_id: "user_test"
      },
      provider_id: provider,
      account_id: account_id,
      required_scopes: []
    }
  end

  def map_probe_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_map_probe",
        "name" => "map_probe",
        "nodes" => [
          %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "mapper",
            "type" => "test.expression_map_probe",
            "version" => 1,
            "params" => %{
              "value" => "{{ $json.n | times: 10 }}",
              "label" => "item-{{ $json.n }}"
            }
          }
        ],
        "connections" => [%{"from" => "source", "to" => "mapper"}]
      },
      attrs
    )
  end

  def map_reduce_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_map_reduce",
        "name" => "map_reduce",
        "nodes" => [
          %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "mapper",
            "type" => "test.expression_map_probe",
            "version" => 1,
            "params" => %{"value" => "{{ $json.n | times: 10 }}"}
          },
          %{
            "id" => "summer",
            "type" => "test.expression_reduce_probe",
            "version" => 1,
            "params" => %{"initial" => 0, "value" => "{{ $acc | plus: $json.params.value }}"}
          }
        ],
        "connections" => [
          %{"from" => "source", "to" => "mapper"},
          %{"from" => "mapper", "to" => "summer"}
        ]
      },
      attrs
    )
  end

  def constant_map_reduce_graph do
    graph = map_reduce_graph()

    nodes =
      Enum.map(graph["nodes"], fn
        %{"id" => "mapper"} = node ->
          %{node | "type" => "map", "params" => %{"value" => 3}}

        %{"id" => "summer"} = node ->
          %{
            node
            | "type" => "reduce",
              "params" => %{"initial" => 0, "value" => "{{ $acc | plus: $json }}"}
          }

        node ->
          node
      end)

    %{graph | "nodes" => nodes}
  end

  def rewirable_map_reduce_graph do
    %{
      "schema_version" => 1,
      "id" => "wf_rewirable_map",
      "name" => "rewirable_map",
      "nodes" => [
        %{
          "id" => "a",
          "type" => "math",
          "version" => 1,
          "params" => %{"operation" => "multiply", "left" => 10, "right" => 1}
        },
        %{
          "id" => "b",
          "type" => "math",
          "version" => 1,
          "params" => %{"operation" => "multiply", "left" => 20, "right" => 1}
        },
        %{"id" => "mapper", "type" => "map", "version" => 1, "params" => %{}},
        %{
          "id" => "sum",
          "type" => "reduce",
          "version" => 1,
          "params" => %{"initial" => 0, "value" => "{{ $acc | plus: $json }}"}
        }
      ],
      "connections" => [
        %{"from" => "a", "to" => "mapper"},
        %{"from" => "mapper", "to" => "sum"}
      ]
    }
  end

  def node_ref_map_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_node_ref_map",
        "name" => "node_ref_map",
        "nodes" => [
          %{"id" => "ctx_src", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{"id" => "list_src", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "mapper",
            "type" => "test.expression_map_probe",
            "version" => 1,
            "params" => %{
              "value" => "{{ $json.n }}",
              "label" => "{{ $node[\"ctx_src\"].json | size }}"
            }
          }
        ],
        # ctx_src is an upstream ancestor of mapper (via list_src) but not a
        # direct parent; the $node reference makes the compiler add the edge.
        "connections" => [
          %{"from" => "ctx_src", "to" => "list_src"},
          %{"from" => "list_src", "to" => "mapper"}
        ]
      },
      attrs
    )
  end

  def expression_probe_graph(attrs \\ %{}) do
    attrs = Map.new(attrs)

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_expression_probe",
        "name" => "expression_probe",
        "nodes" => [
          %{"id" => "source", "type" => "test.identity_probe", "version" => 1, "params" => %{}},
          %{
            "id" => "probe",
            "type" => "test.expression_probe",
            "version" => 1,
            "params" => %{
              "count" => "{{ $json.count | to_number }}",
              "message" => "{{ $env.API_BASE }}/users/{{ $json.id }}",
              "payload" => %{
                "email" => "{{ $node[\"source\"].json.email }}",
                "count" => "{{ $json.count | to_number }}"
              }
            }
          }
        ],
        "connections" => [%{"from" => "source", "to" => "probe"}],
        "env" => %{"API_BASE" => "https://api.example.test"}
      },
      attrs
    )
  end
end
