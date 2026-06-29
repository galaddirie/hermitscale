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
  end

  describe "cast!/2" do
    test "raises on validation errors" do
      assert_raise ArgumentError, ~r/required :method option not found/, fn ->
        Params.cast!(%{}, @schema)
      end
    end
  end
end
