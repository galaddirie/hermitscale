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

example_order_rollup_attrs = %{
  id: example_order_rollup_definition["id"],
  name: example_order_rollup_definition["name"],
  schema_version: example_order_rollup_definition["schema_version"],
  definition: example_order_rollup_definition,
  status: :active
}

seeded_graph =
  case Enum.find(Workflows.list_graphs(), &(&1.id == example_order_rollup_attrs.id)) do
    %Graph{} = graph -> Workflows.update_graph(graph, example_order_rollup_attrs)
    nil -> Workflows.create_graph(example_order_rollup_attrs)
  end

case seeded_graph do
  {:ok, %Graph{id: id, name: name}} ->
    IO.puts("Seeded workflow graph #{id} (#{name})")

  {:error, changeset} ->
    raise "failed to seed example workflow graph: #{inspect(changeset.errors)}"
end
