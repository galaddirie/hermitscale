defmodule Hermitscale.Workflows.TemplateTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Workflows.Template

  describe "render/2" do
    test "interpolates constrained JSON accessors" do
      input = %{"sku" => "ABC-123", "items" => [%{"id" => 42}]}

      assert {:ok, "/inventory/ABC-123/items/42"} =
               Template.render("/inventory/{{ $.sku }}/items/{{ $.items.0.id }}", input)
    end

    test "returns an error for missing paths" do
      assert {:error, {"$.missing", {:missing_path, "missing"}}} =
               Template.render("/inventory/{{ $.missing }}", %{})
    end
  end
end
