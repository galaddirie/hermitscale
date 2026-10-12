defmodule Hermitscale.Workflows.Nodes.ParamsTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Nodes.Params

  @schema NimbleOptions.new!(
            method: [type: {:in, ~w(GET POST)}, required: true],
            timeout_ms: [type: :non_neg_integer, default: 5_000]
          ).schema

  describe "cast/2" do
    test "casts string-keyed params to atom-keyed params and applies defaults" do
      assert {:ok, %{method: "GET", timeout_ms: 5_000}} =
               Params.cast(%{"method" => "GET", "ignored" => true}, @schema)
    end

    test "returns validation errors" do
      assert {:error, %NimbleOptions.ValidationError{} = error} =
               Params.cast(%{"method" => "TRACE"}, @schema)

      assert Exception.message(error) =~ "invalid value"
    end
  end

  describe "cast/3" do
    test "compiles expressionable fields and keeps defaults from the schema" do
      schema =
        NimbleOptions.new!(
          count: [type: :non_neg_integer, required: true],
          flag: [type: :boolean, default: false]
        ).schema

      assert {:ok, %{count: {:expr, nil, %Solid.Template{}}, flag: false}} =
               Params.cast(%{"count" => "{{ $json.count | to_number }}"}, schema, [:count])
    end

    test "returns expression compile errors" do
      schema = NimbleOptions.new!(count: [type: :any, required: true]).schema

      assert {:error, %Hermitscale.Workflows.Expr.CompileError{} = error} =
               Params.cast(%{"count" => "{{ $json.count | unknown_filter }}"}, schema, [:count])

      assert Exception.message(error) =~ "unknown expression filter"
    end

    test "validates literal values in expressionable fields against their schema" do
      schema = NimbleOptions.new!(count: [type: :non_neg_integer, required: true]).schema

      assert {:error, %NimbleOptions.ValidationError{}} =
               Params.cast(%{"count" => "invalid"}, schema, [:count])

      assert {:error, %NimbleOptions.ValidationError{}} =
               Params.cast(%{"count" => -1}, schema, [:count])

      assert {:ok, %{count: {:literal, 2}}} = Params.cast(%{"count" => 2}, schema, [:count])
    end
  end

  describe "cast!/2" do
    test "raises on validation errors" do
      assert_raise ArgumentError, ~r/required :method option not found/, fn ->
        Params.cast!(%{}, @schema)
      end
    end
  end

  describe "Runic parameter bindings" do
    test "compiled expressions have deterministic, canonical bindings and keep typed results" do
      schema = NimbleOptions.new!(count: [type: :any, required: true]).schema
      params = Params.cast!(%{"count" => "{{ $json.count | to_number }}"}, schema, [:count])
      binding = Params.bind(Map.put(params, :flag, false))

      assert binding == Params.bind(Map.new([{:flag, false} | Map.to_list(params)]))
      assert %Runic.Identity{} = Runic.Identity.derive(:component_definition, binding)

      assert Params.resolve!(binding, %{"json" => %{"count" => "7"}}) == %{
               count: 7,
               flag: false
             }

      changed = Params.cast!(%{"count" => "{{ $json.count | times: 2 }}"}, schema, [:count])

      refute Runic.Identity.derive(:component_definition, binding) ==
               Runic.Identity.derive(:component_definition, Params.bind(changed))
    end

    test "nested runtime-only values cannot bypass Runic identity validation" do
      for value <- [self(), make_ref(), fn -> :local end] do
        assert_raise ArgumentError, ~r/runtime-only values/, fn ->
          Params.bind(%{nested: [{:payload, %{value: value}}]})
        end
      end
    end

    test "malformed internal bindings fail instead of resolving to a fallback" do
      assert_raise ArgumentError, fn -> Params.resolve!(<<0>>, %{}) end
    end
  end
end
