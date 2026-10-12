defmodule Hermitscale.Workflows.Nodes.BehaviourTest do
  use ExUnit.Case, async: true

  describe "__using__/1" do
    test "generates a catalog spec with defaults" do
      module =
        compile_node!(
          id: "test.generated_node",
          version: 1,
          kind: :step,
          default_policy: %{backoff: :exponential, max_retries: 2},
          params: [name: [type: :string, default: "generated"]]
        )

      assert %{
               id: "test.generated_node",
               version: 1,
               kind: :step,
               inputs: [:main],
               outputs: [:main],
               requires: [],
               default_policy: %{backoff: :exponential, max_retries: 2},
               deprecated: false
             } = module.__catalog_node__()

      assert module.spec().params_schema[:name][:default] == "generated"
    end

    test "raises at compile time for invalid kinds" do
      assert_raise ArgumentError, ~r/invalid kind :invalid/, fn ->
        compile_node!(id: "test.invalid_kind", version: 1, kind: :invalid)
      end
    end

    test "raises at compile time for malformed params schemas" do
      assert_raise ArgumentError, ~r/invalid NimbleOptions schema/, fn ->
        compile_node!(
          id: "test.invalid_schema",
          version: 1,
          kind: :step,
          params: [name: [type: :does_not_exist]]
        )
      end
    end

    test "raises at compile time for unknown default policy keys" do
      assert_raise KeyError, ~r/"retry"/, fn ->
        compile_node!(
          id: "test.invalid_policy_key",
          version: 1,
          kind: :step,
          default_policy: %{retry: 1}
        )
      end
    end

    test "raises at compile time for invalid default policy values" do
      assert_raise KeyError, ~r/"expnential"/, fn ->
        compile_node!(
          id: "test.invalid_policy_value",
          version: 1,
          kind: :step,
          default_policy: %{backoff: :expnential}
        )
      end
    end

    test "rejects expression declarations that do not name schema params" do
      assert_raise ArgumentError, ~r/expr fields must name declared params/, fn ->
        compile_node!(id: "test.bad_expr", version: 1, kind: :step, expr: [:missing])
      end
    end

    test "rejects predicates that are not expression fields" do
      assert_raise ArgumentError, ~r/predicate fields must be expression fields/, fn ->
        compile_node!(
          id: "test.bad_predicate",
          version: 1,
          kind: :step,
          params: [condition: [type: :boolean]],
          predicate: [:condition]
        )
      end
    end

    test "rejects unknown declaration options and duplicate ports" do
      assert_raise ArgumentError, ~r/unknown node options/, fn ->
        compile_node!(id: "test.bad_option", version: 1, kind: :step, exprs: [:value])
      end

      assert_raise ArgumentError, ~r/inputs must be unique/, fn ->
        compile_node!(id: "test.duplicate_port", version: 1, kind: :join, inputs: [:main, :main])
      end
    end

    test "rejects invalid integer default policy values" do
      assert_raise ArgumentError, ~r/max_retries must be a non-negative integer/, fn ->
        compile_node!(
          id: "test.bad_retry",
          version: 1,
          kind: :step,
          default_policy: %{max_retries: -1}
        )
      end
    end
  end

  defp compile_node!(opts) do
    module = Module.concat(__MODULE__, :"Generated#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Hermitscale.Workflows.Nodes.Behaviour, unquote(Macro.escape(opts))

          @impl true
          def work(_params, item, _deps), do: item
        end
      end
    )

    module
  end
end
