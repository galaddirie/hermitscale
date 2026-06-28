defmodule Hermitscale.Workflows.Nodes.BuiltinsTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Nodes.HttpRequest.V2, as: HttpRequest
  alias Hermitscale.Workflows.Nodes.MergeDecision.V1, as: MergeDecision
  alias Hermitscale.Workflows.Nodes.Params
  alias Hermitscale.Workflows.Nodes.ValidateOrder.V1, as: ValidateOrder

  describe "http_request v2" do
    test "declares credentials and builds from atom-keyed params" do
      spec = HttpRequest.spec()

      assert spec.id == "http_request"
      assert spec.requires == [credentials: []]

      params =
        Params.cast!(
          %{"method" => "GET", "url" => "https://example.test/orders/{{ $.id }}"},
          spec.params_schema
        )

      step = HttpRequest.build(params, %{name: "fetch_order", inputs: []})

      assert step.name == "fetch_order"
    end
  end

  describe "join and step builtins" do
    test "declare their catalog ports through generated specs" do
      assert %{id: "merge_decision", kind: :join, inputs: [:left, :right], outputs: [:main]} =
               MergeDecision.spec()

      assert %{id: "validate_order", kind: :step, inputs: [:main], outputs: [:main]} =
               ValidateOrder.spec()
    end
  end
end
