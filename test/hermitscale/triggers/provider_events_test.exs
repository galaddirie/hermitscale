defmodule Hermitscale.Triggers.ProviderEventsTest do
  use ExUnit.Case, async: true
  alias Hermitscale.Triggers.GitHub.Events.V1, as: GitHub
  alias Hermitscale.Triggers.Linear.Events.V1, as: Linear

  describe "GitHub events" do
    test "verifies the exact bytes and emits a provider delivery key" do
      body = %{
        "action" => "opened",
        "repository" => %{"full_name" => "acme/backend"},
        "issue" => %{"id" => 1}
      }

      req = request(body, "github", %{"x-github-event" => "issues"})

      assert {:fire, ^body, [idempotency_key: "github:delivery-1"]} =
               GitHub.handle_request(req, github_params())

      assert {:error, :unauthorized} =
               GitHub.handle_request(%{req | raw_body: req.raw_body <> " "}, github_params())

      assert {:error, :unauthorized} =
               GitHub.handle_request(
                 %{req | headers: Map.delete(req.headers, "x-hub-signature-256")},
                 github_params()
               )
    end

    test "ignores ping and unselected events after authentication" do
      assert {:reply, 200, %{}} =
               GitHub.handle_request(
                 request(%{}, "github", %{"x-github-event" => "ping"}),
                 github_params()
               )

      body = %{"repository" => %{"full_name" => "acme/backend"}}

      assert {:ignore, "event_not_selected"} =
               GitHub.handle_request(
                 request(body, "github", %{"x-github-event" => "push"}),
                 github_params()
               )
    end

    test "rejects a delivery for another repository" do
      req =
        request(%{"repository" => %{"full_name" => "other/repo"}}, "github", %{
          "x-github-event" => "issues"
        })

      assert {:error, :unauthorized} = GitHub.handle_request(req, github_params())
    end
  end

  describe "Linear events" do
    test "authenticates fresh selected resources and actions" do
      body = linear_body()

      assert {:fire, ^body, [idempotency_key: "linear:delivery-1"]} =
               Linear.handle_request(request(body, "linear", %{}), linear_params())

      updated = Map.put(body, "action", "update")

      assert {:ignore, "event_not_selected"} =
               Linear.handle_request(request(updated, "linear", %{}), %{
                 linear_params()
                 | actions: ["create"]
               })
    end

    test "rejects stale timestamps, missing signatures, and another subscription" do
      for body <- [
            Map.put(linear_body(), "webhookTimestamp", System.system_time(:millisecond) - 61_000),
            Map.put(linear_body(), "webhookId", "another-hook")
          ] do
        assert {:error, :unauthorized} =
                 Linear.handle_request(request(body, "linear", %{}), linear_params())
      end

      req = request(linear_body(), "linear", %{})

      assert {:error, :unauthorized} =
               Linear.handle_request(
                 %{req | headers: Map.delete(req.headers, "linear-signature")},
                 linear_params()
               )
    end
  end

  defp github_params,
    do: %{
      owner: "acme",
      repo: "backend",
      events: ["issues"],
      actions: [],
      _webhook_secret: "test-signing-key",
      _remote_id: "hook-1"
    }

  defp linear_params,
    do: %{
      resources: ["Issue"],
      actions: [],
      _webhook_secret: "test-signing-key",
      _remote_id: "hook-1"
    }

  defp linear_body,
    do: %{
      "action" => "create",
      "type" => "Issue",
      "webhookId" => "hook-1",
      "webhookTimestamp" => System.system_time(:millisecond),
      "data" => %{"id" => "issue-1"}
    }

  defp request(body, provider, headers) do
    raw = Jason.encode!(body)

    signature =
      :crypto.mac(:hmac, :sha256, "test-signing-key", raw) |> Base.encode16(case: :lower)

    auth =
      case provider do
        "github" ->
          %{"x-hub-signature-256" => "sha256=" <> signature, "x-github-delivery" => "delivery-1"}

        "linear" ->
          %{"linear-signature" => signature, "linear-delivery" => "delivery-1"}
      end

    %{
      method: "POST",
      path: [],
      headers: Map.merge(headers, auth),
      query: %{},
      body: body,
      raw_body: raw
    }
  end
end
