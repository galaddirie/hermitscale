# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Hermitscale.Repo.insert!(%Hermitscale.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Hermitscale.Workflows
alias Hermitscale.Workflows.Graph

example_order_rollup_definition = %{
  "schema_version" => 1,
  "id" => "wf_example_order_rollup",
  "name" => "example_order_rollup",
  "nodes" => [
    %{
      "id" => "line_items",
      "type" => "map",
      "version" => 1,
      "params" => %{
        "value" => %{
          "sku" => "{{ $json.sku | upcase }}",
          "quantity" => "{{ $json.quantity | to_number }}",
          "unit_price_cents" => "{{ $json.unit_price_cents | to_number }}",
          "line_total_cents" => "{{ $json.quantity | times: $json.unit_price_cents }}",
          "customer_email" => "{{ $json.customer.email | downcase }}",
          "currency" => "{{ $vars.currency | default: \"USD\" }}",
          "source" => "{{ $env.ORDER_SOURCE }}",
          "workflow" => "{{ $workflow.name }}"
        }
      },
      "policy" => %{
        "timeout_ms" => 5_000
      }
    },
    %{
      "id" => "order_summary",
      "type" => "reduce",
      "version" => 1,
      "params" => %{
        "initial" => %{"total_cents" => 0, "item_count" => 0},
        "value" => %{
          "total_cents" => "{{ $acc.total_cents | plus: $json.line_total_cents }}",
          "item_count" => "{{ $acc.item_count | plus: 1 }}",
          "currency" => "{{ $json.currency }}",
          "source" => "{{ $json.source }}",
          "workflow" => "{{ $json.workflow }}"
        }
      },
      "policy" => %{
        "timeout_ms" => 5_000
      }
    }
  ],
  "connections" => [
    %{"from" => "line_items", "to" => "order_summary"}
  ],
  "env" => %{"ORDER_SOURCE" => "seed-demo"},
  "vars" => %{"currency" => "USD"}
}

numbers_debug_math_definition = %{
  "schema_version" => 1,
  "id" => "wf_example_numbers_debug_math",
  "name" => "example_numbers_debug_math",
  "nodes" => [
    %{
      "id" => "iterate_numbers",
      "type" => "map",
      "version" => 1,
      "params" => %{},
      "policy" => %{"timeout_ms" => 5_000}
    },
    %{
      "id" => "print_each_number",
      "type" => "debug",
      "version" => 1,
      "params" => %{
        "label" => "input-number",
        "value" => "{{ $json }}"
      },
      "policy" => %{"timeout_ms" => 5_000}
    },
    %{
      "id" => "multiply_by_20",
      "type" => "math",
      "version" => 1,
      "params" => %{
        "operation" => "multiply",
        "left" => "{{ $json | to_number }}",
        "right" => "{{ $vars.multiplier | to_number }}"
      },
      "policy" => %{"timeout_ms" => 5_000}
    },
    %{
      "id" => "collect_products",
      "type" => "reduce",
      "version" => 1,
      "params" => %{
        "initial" => [],
        "value" => "{{ $acc | push: $json }}"
      },
      "policy" => %{"timeout_ms" => 5_000}
    },
    %{
      "id" => "print_final_list",
      "type" => "debug",
      "version" => 1,
      "params" => %{
        "label" => "multiplied-numbers",
        "value" => "{{ $json }}"
      },
      "policy" => %{"timeout_ms" => 5_000}
    }
  ],
  "connections" => [
    %{"from" => "iterate_numbers", "to" => "print_each_number"},
    %{"from" => "print_each_number", "to" => "multiply_by_20"},
    %{"from" => "multiply_by_20", "to" => "collect_products"},
    %{"from" => "collect_products", "to" => "print_final_list"}
  ],
  "vars" => %{"multiplier" => 20}
}

case {Mix.env(), System.get_env("DEV_SEED_ORG_ID"), System.get_env("DEV_SEED_USER_ID")} do
  {:dev, org_id, actor_id}
  when is_binary(org_id) and org_id != "" and is_binary(actor_id) and actor_id != "" ->
    context = %Hermitscale.Integrations.ExecutionContext{
      organization_id: org_id,
      actor_user_id: actor_id,
      required_permissions: ["workflows:edit", "workflows:run", "workflows:activate"]
    }

    {:ok, scope} = Hermitscale.Authorization.execution_scope(context)
    suffix = :crypto.hash(:sha256, org_id) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    existing_graphs = Map.new(Workflows.list_graphs(scope), &{&1.id, &1})

    Enum.each([example_order_rollup_definition, numbers_debug_math_definition], fn definition ->
      definition = Map.update!(definition, "id", &(&1 <> "_" <> suffix))

      attrs = %{
        id: definition["id"],
        name: definition["name"],
        schema_version: definition["schema_version"],
        definition: definition,
        status: :active
      }

      result =
        case Map.fetch(existing_graphs, attrs.id) do
          {:ok, %Graph{} = graph} -> Workflows.update_graph(scope, graph, attrs)
          :error -> Workflows.create_graph(scope, attrs)
        end

      {:ok, %Graph{id: id}} = result
      IO.puts("Seeded workflow graph #{id}")
    end)

  {:dev, nil, nil} ->
    :ok

  {:dev, _org_id, _actor_id} ->
    raise "set both DEV_SEED_ORG_ID and DEV_SEED_USER_ID to an existing authorized development actor"

  {_environment, _org_id, _actor_id} ->
    :ok
end
