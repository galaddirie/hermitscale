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

  describe "cast!/2" do
    test "raises on validation errors" do
      assert_raise ArgumentError, ~r/required :method option not found/, fn ->
        Params.cast!(%{}, @schema)
      end
    end
  end
end
