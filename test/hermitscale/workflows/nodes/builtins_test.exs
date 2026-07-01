defmodule Hermitscale.Workflows.Nodes.BuiltinsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Hermitscale.Workflows.{Compiler, Validator}
  alias Hermitscale.Workflows.Nodes.Builtin.Debug.V1, as: Debug
  alias Hermitscale.Workflows.Nodes.Builtin.HttpRequest.V2, as: HttpRequest
  alias Hermitscale.Workflows.Nodes.Builtin.Math.V1, as: Math
  alias Hermitscale.Workflows.Nodes.Params
  alias Runic.Workflow

  describe "http_request v2" do
    test "declares credentials and builds from atom-keyed params" do
      spec = HttpRequest.spec()

      assert spec.id == "http_request"
      assert spec.requires == [credentials: []]
      assert spec.expr_fields == [:url]

      params =
        Params.cast!(
          %{"method" => "GET", "url" => "https://example.test/orders/{{ $json.id }}"},
          spec.params_schema,
          spec.expr_fields
        )

      step = HttpRequest.build(params, %{name: "fetch_order", parents: [], main_count: 0})

      assert step.name == "fetch_order"
    end
  end

  describe "debug v1" do
    test "logs each item and returns the original input" do
      log =
        capture_info_log(fn ->
          assert [1, 2, 3] =
                   Debug.work(
                     %{label: "number", mode: "each", value: [1, 2, 3]},
                     [1, 2, 3],
                     %{}
                   )
        end)

      assert log_count(log) == 3
    end
  end

  describe "math v1" do
    test "declares a per-item arithmetic node" do
      spec = Math.spec()

      assert spec.id == "math"
      assert spec.kind == :step
      assert spec.expr_fields == [:left, :right]
    end

    test "multiplies two operands" do
      assert Math.work(%{operation: "multiply", left: 6, right: 20}, 6, %{}) == 120
    end

    test "rejects unknown operations during param casting" do
      spec = Math.spec()

      assert {:error, error} =
               Params.cast(
                 %{"operation" => "power", "left" => 2, "right" => 8},
                 spec.params_schema,
                 spec.expr_fields
               )

      assert Exception.message(error) =~ "operation"
    end
  end

  describe "debug/math workflow" do
    test "prints each number, multiplies by 20, accumulates a list, and prints the final list" do
      graph = numbers_debug_math_graph()

      assert :ok = Validator.validate(graph)

      log =
        capture_info_log(fn ->
          assert {:ok, workflow} = Compiler.compile(graph)

          executed =
            workflow
            |> Workflow.react_until_satisfied([1, 2, 3])

          results = Workflow.raw_productions(executed)
          final_debug_results = Workflow.raw_productions(executed, "print_final_list")

          send(self(), {:results, results, final_debug_results})
        end)

      assert_receive {:results, results, final_debug_results}
      assert [20, 40, 60] in results
      assert final_debug_results == [[20, 40, 60]]
      assert log_count(log) == 4
    end
  end

  defp log_count(log), do: ~r/Workflow debug/ |> Regex.scan(log) |> length()

  defp capture_info_log(fun) do
    previous_level = Logger.level()

    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp numbers_debug_math_graph do
    %{
      "schema_version" => 1,
      "id" => "wf_numbers_debug_math_test",
      "name" => "numbers_debug_math_test",
      "nodes" => [
        %{
          "id" => "iterate_numbers",
          "type" => "map",
          "version" => 1,
          "params" => %{}
        },
        %{
          "id" => "print_each_number",
          "type" => "debug",
          "version" => 1,
          "params" => %{
            "label" => "input-number",
            "value" => "{{ $json }}"
          }
        },
        %{
          "id" => "multiply_by_20",
          "type" => "math",
          "version" => 1,
          "params" => %{
            "operation" => "multiply",
            "left" => "{{ $json | to_number }}",
            "right" => 20
          }
        },
        %{
          "id" => "collect_products",
          "type" => "reduce",
          "version" => 1,
          "params" => %{
            "initial" => [],
            "value" => "{{ $acc | push: $json }}"
          }
        },
        %{
          "id" => "print_final_list",
          "type" => "debug",
          "version" => 1,
          "params" => %{
            "label" => "multiplied-numbers",
            "value" => "{{ $json }}"
          }
        }
      ],
      "connections" => [
        %{"from" => "iterate_numbers", "to" => "print_each_number"},
        %{"from" => "print_each_number", "to" => "multiply_by_20"},
        %{"from" => "multiply_by_20", "to" => "collect_products"},
        %{"from" => "collect_products", "to" => "print_final_list"}
      ]
    }
  end
end
