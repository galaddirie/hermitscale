defmodule Hermitscale.DeliveryFixtures do
  @moduledoc false
  def pull_delivery_fixture(attrs \\ %{}) do
    Map.merge(
      %{
        effect_key: Ecto.UUID.generate(),
        provider: "github",
        kind: "github.pull_requests.create",
        connection: %{"provider" => "github", "account_id" => "data_github"},
        params: %{
          owner: "acme",
          repo: "backend",
          title: "Fix ENG-7",
          head: "fix/ENG-7",
          base: "main",
          body: "Verified changes"
        }
      },
      attrs
    )
  end

  def pull_result_fixture(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => 7,
        "number" => 7,
        "html_url" => "https://github.com/acme/backend/pull/7",
        "body" => "Verified changes"
      },
      attrs
    )
  end
end
