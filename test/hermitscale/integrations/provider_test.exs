defmodule Hermitscale.Integrations.ProviderTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Integrations.Provider
  alias Hermitscale.Integrations.TestProvider

  describe "index/0" do
    test "discovers provider modules by provider id" do
      index = Provider.refresh!()

      assert {:ok, TestProvider} = Provider.fetch(index, "test.credentials")

      assert {:ok, %{slug: "test.credentials", destinations: ["test.local"]}} =
               Provider.descriptor("test.credentials")
    end

    test "returns :not_found for undeployed providers" do
      assert {:error, :not_found} = Provider.fetch(%{}, "missing.provider")
    end
  end
end
