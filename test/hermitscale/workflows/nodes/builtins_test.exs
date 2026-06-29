defmodule Hermitscale.Workflows.Nodes.BuiltinsTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Nodes.Builtin.HttpRequest.V2, as: HttpRequest
  alias Hermitscale.Workflows.Nodes.Params

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
end
