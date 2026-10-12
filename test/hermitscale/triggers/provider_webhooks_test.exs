defmodule Hermitscale.Triggers.ProviderWebhooksTest do
  use Hermitscale.DataCase, async: false
  use Oban.Testing, repo: Hermitscale.Repo
  alias Hermitscale.{Repo, Triggers}

  alias Hermitscale.Triggers.{
    Webhooks,
    WebhookLifecycleWorker,
    WebhookDeliveryWorker,
    WebhookDelivery,
    WebhookPlug
  }

  alias Hermitscale.Integrations.GitHub.Client, as: GitHub
  alias Hermitscale.Integrations.Linear.Client, as: Linear
  alias Hermitscale.WorkOSTest.Client, as: Pipes
  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures
  import Hermitscale.IntegrationsFixtures

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    start_supervised!(Pipes)

    Pipes.put_response(:list_org_providers, fn org ->
      {:ok,
       %{
         "data" =>
           Enum.map(~w(github linear), fn provider ->
             %{"slug" => provider, "connected_accounts" => [account_fixture(provider, org)]}
           end)
       }}
    end)

    Pipes.put_response(:vend_credentials, fn provider, _user, _org, _id ->
      {:ok,
       %{
         auth_method: "oauth",
         value: "provider-secret",
         scopes: scopes_fixture(provider),
         missing_scopes: []
       }}
    end)

    for {module, config} <- [
          {Webhooks,
           [base_url: "https://hooks.example.test", signing_secret: String.duplicate("s", 64)]},
          {GitHub, [req_options: [plug: {Req.Test, __MODULE__}]]},
          {Linear, [req_options: [plug: {Req.Test, __MODULE__}]]}
        ] do
      previous = Application.get_env(:hermitscale, module)
      Application.put_env(:hermitscale, module, config)

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:hermitscale, module),
          else: Application.put_env(:hermitscale, module, previous)
      end)
    end

    %{scope: user_scope_fixture()}
  end

  describe "provider registration lifecycle" do
    test "changing repositories cleans a retired registration before provisioning the new source",
         %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      previous = Webhooks.get_subscription!(scope, trigger)
      expect_github_registration(previous)
      assert {:ok, :active} = perform_job(WebhookLifecycleWorker, %{subscription_id: previous.id})
      node = put_in(provider_node("github"), ["params", "repo"], "new-repo")

      {:ok, graph} =
        Hermitscale.Workflows.update_graph(scope, graph, %{definition: trigger_graph(node)})

      assert {:ok, _} = Triggers.activate_graph(scope, graph)
      updated = Webhooks.get_subscription!(scope, trigger)

      refute updated.desired_config["registration_id"] ==
               previous.desired_config["registration_id"]

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/repos/acme/backend/hooks/77"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/repos/acme/new-repo/hooks"

        Req.Test.json(conn, [
          %{"id" => 99, "config" => %{"url" => "https://somebody-else.test/hook"}}
        ])
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/acme/new-repo/hooks"

        Req.Test.json(conn, %{
          "id" => 78,
          "active" => true,
          "config" => %{"url" => Webhooks.url(updated)}
        })
      end)

      assert {:ok, :active} = perform_job(WebhookLifecycleWorker, %{subscription_id: updated.id})
      assert Webhooks.get_subscription!(scope, trigger).retired_configs == %{}
    end

    test "removing a trigger retains enough state to remove its provider hook", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      expect_github_registration(subscription)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      {:ok, graph} =
        Hermitscale.Workflows.update_graph(scope, graph, %{
          definition: trigger_graph(manual_trigger_node(), %{"id" => graph.id})
        })

      assert {:ok, _} = Triggers.activate_graph(scope, graph)
      assert Repo.reload!(subscription).trigger_id == nil

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/repos/acme/backend/hooks/77"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, :inactive} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})
    end

    test "deactivation cleans up a hook even when its creation acknowledgement was lost", %{
      scope: scope
    } do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, []))
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "lost acknowledgement"))

      assert {:error, {:provider_request_failed, 503}} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      assert {:ok, _graph} = Triggers.deactivate_graph(scope, graph)

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, [%{"id" => 77, "config" => %{"url" => Webhooks.url(subscription)}}])
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/repos/acme/backend/hooks/77"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, :inactive} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})
    end

    test "activation queues registration, reactivation is stable, and deactivation cleans up", %{
      scope: scope
    } do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      assert subscription.status == :pending
      assert_enqueued(worker: WebhookLifecycleWorker, args: %{subscription_id: subscription.id})
      expect_github_registration(subscription)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      assert Webhooks.get_subscription!(scope, trigger).remote_id == "77"
      assert {:ok, _activated} = Triggers.activate_graph(scope, graph)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, [%{"id" => 77, "config" => %{"url" => Webhooks.url(subscription)}}])
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PATCH"

        Req.Test.json(conn, %{
          "id" => 77,
          "active" => true,
          "config" => %{"url" => Webhooks.url(subscription)}
        })
      end)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      assert {:ok, _graph} = Triggers.deactivate_graph(scope, graph)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/repos/acme/backend/hooks/77"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, :inactive} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      assert Webhooks.get_subscription!(scope, trigger).remote_id == nil
    end

    test "Linear creates a deterministic signed team subscription", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, provider_node("linear"))
      subscription = Webhooks.get_subscription!(scope, trigger)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["query"] =~ "webhooks"

        Req.Test.json(conn, %{
          "data" => %{
            "webhooks" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        input = Jason.decode!(raw)["variables"]["input"]
        assert input["teamId"] == "team-1"
        assert input["resourceTypes"] == ["Issue", "Comment"]
        assert input["secret"] == Webhooks.signing_secret(subscription)
        assert input["id"] == subscription.desired_config["registration_id"]

        Req.Test.json(conn, %{
          "data" => %{
            "webhookCreate" => %{
              "success" => true,
              "webhook" => %{"id" => input["id"], "enabled" => true, "url" => input["url"]}
            }
          }
        })
      end)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})
    end

    test "ineligible actors cannot register remote hooks", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      Pipes.put_response(:list_memberships, {:ok, %{"data" => []}})

      assert {:cancel, :execution_actor_ineligible} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      assert Webhooks.get_subscription!(scope, trigger).status == :errored
    end
  end

  describe "signed delivery ingress" do
    test "an in-progress firing stays retryable and later links to the acknowledged run", %{
      scope: scope
    } do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      expect_github_registration(subscription)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      firing = unresolved_firing_fixture(trigger, "github:delivery-1")
      payload = %{"repository" => %{"full_name" => "acme/backend"}}
      assert (signed_conn(subscription, payload) |> WebhookPlug.call([])).status == 202
      [delivery] = Repo.all(WebhookDelivery)

      assert {:error, :firing_in_progress} =
               perform_job(WebhookDeliveryWorker, %{delivery_id: delivery.id})

      assert Repo.reload!(delivery).status == :failed
      {:ok, run} = Hermitscale.Workflows.create_run(scope, graph)
      firing |> Ecto.Changeset.change(run_id: run.id) |> Repo.update!()
      assert {:ok, :dispatched} = perform_job(WebhookDeliveryWorker, %{delivery_id: delivery.id})
      assert Repo.reload!(delivery).run_id == run.id
      assert Repo.aggregate(Hermitscale.Triggers.Firing, :count) == 1
    end

    test "accepts Linear deliveries with timestamp and registration checks", %{scope: scope} do
      {_graph, trigger} = activate_trigger_graph!(scope, provider_node("linear"))
      subscription = Webhooks.get_subscription!(scope, trigger)

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{
          "data" => %{
            "webhooks" => %{
              "nodes" => [],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        })
      )

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{
          "data" => %{
            "webhookCreate" => %{
              "success" => true,
              "webhook" => %{
                "id" => subscription.desired_config["registration_id"],
                "enabled" => true,
                "url" => Webhooks.url(subscription)
              }
            }
          }
        })
      )

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      raw =
        Jason.encode!(%{
          "type" => "Issue",
          "action" => "create",
          "webhookId" => subscription.desired_config["registration_id"],
          "webhookTimestamp" => System.system_time(:millisecond),
          "data" => %{"id" => "issue-1"}
        })

      signature =
        :crypto.mac(:hmac, :sha256, Webhooks.signing_secret(subscription), raw)
        |> Base.encode16(case: :lower)

      conn =
        Plug.Test.conn(:post, "/hooks/" <> subscription.webhook_token, raw)
        |> Plug.Conn.put_req_header("content-type", "application/json; charset=utf-8")
        |> Plug.Conn.put_req_header("linear-signature", signature)
        |> Plug.Conn.put_req_header("linear-delivery", "linear-1")
        |> WebhookPlug.call([])

      assert conn.status == 202
      [delivery] = Repo.all(WebhookDelivery)
      assert {:ok, :dispatched} = perform_job(WebhookDeliveryWorker, %{delivery_id: delivery.id})
    end

    test "rejects malformed JSON, media types, and oversized bodies without retention" do
      assert (Plug.Test.conn(:get, "/hooks/unknown") |> WebhookPlug.call([])).status == 405

      for {body, content_type, status} <- [
            {"{", "application/json", 400},
            {"[]", "application/json", 400},
            {"{}", "application/json-fake", 415},
            {String.duplicate("x", 1_048_577), "application/json", 413}
          ] do
        conn =
          Plug.Test.conn(:post, "/hooks/unknown", body)
          |> Plug.Conn.put_req_header("content-type", content_type)
          |> WebhookPlug.call([])

        assert conn.status == status
      end

      assert Repo.all(WebhookDelivery) == []
    end

    test "acknowledges durable events and dedupes redeliveries into one workflow run", %{
      scope: scope
    } do
      {_graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      expect_github_registration(subscription)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      payload = %{
        "action" => "opened",
        "repository" => %{"full_name" => "acme/backend"},
        "issue" => %{"id" => 1}
      }

      for _ <- 1..2 do
        conn =
          signed_conn(subscription, payload)
          |> HermitscaleWeb.Endpoint.call(HermitscaleWeb.Endpoint.init([]))

        assert conn.status == 202
      end

      assert [delivery] = Repo.all(WebhookDelivery)
      assert_enqueued(worker: WebhookDeliveryWorker, args: %{delivery_id: delivery.id})
      assert {:ok, :dispatched} = perform_job(WebhookDeliveryWorker, %{delivery_id: delivery.id})
      assert {:ok, :dispatched} = perform_job(WebhookDeliveryWorker, %{delivery_id: delivery.id})
      run = Repo.get!(Hermitscale.Workflows.Run, Repo.reload!(delivery).run_id)
      assert run.input["value"]["data"] == payload
      refute Jason.encode!(run.input) =~ "provider-secret"
      assert Repo.aggregate(Hermitscale.Triggers.Firing, :count) == 1
    end

    test "rejects bad signatures and disabled triggers without storing payloads", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      expect_github_registration(subscription)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      bad =
        signed_conn(subscription, %{})
        |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=bad")
        |> WebhookPlug.call([])

      assert bad.status == 401
      assert {:ok, _graph} = Triggers.deactivate_graph(scope, graph)
      assert (signed_conn(subscription, %{}) |> WebhookPlug.call([])).status == 404
      assert Repo.all(WebhookDelivery) == []
    end

    test "a delivery accepted before deactivation cannot dispatch afterwards", %{scope: scope} do
      {graph, trigger} = activate_trigger_graph!(scope, provider_node("github"))
      subscription = Webhooks.get_subscription!(scope, trigger)
      expect_github_registration(subscription)

      assert {:ok, :active} =
               perform_job(WebhookLifecycleWorker, %{subscription_id: subscription.id})

      payload = %{"repository" => %{"full_name" => "acme/backend"}}
      assert (signed_conn(subscription, payload) |> WebhookPlug.call([])).status == 202
      [delivery] = Repo.all(WebhookDelivery)
      assert {:ok, _graph} = Triggers.deactivate_graph(scope, graph)

      assert {:cancel, :disabled} =
               perform_job(WebhookDeliveryWorker, %{delivery_id: delivery.id})

      assert Repo.aggregate(Hermitscale.Triggers.Firing, :count) == 0
    end
  end

  defp provider_node("github"),
    do: %{
      "id" => "github_hook",
      "type" => "github.events",
      "version" => 1,
      "params" => %{"owner" => "acme", "repo" => "backend", "events" => ["issues"]},
      "connection" => %{"provider" => "github", "account_id" => "data_github"}
    }

  defp provider_node("linear"),
    do: %{
      "id" => "linear_hook",
      "type" => "linear.events",
      "version" => 1,
      "params" => %{"team_id" => "team-1", "resources" => ["Issue", "Comment"]},
      "connection" => %{"provider" => "linear", "account_id" => "data_linear"}
    }

  defp expect_github_registration(subscription) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      assert body["config"]["url"] == Webhooks.url(subscription)
      assert body["config"]["secret"] == Webhooks.signing_secret(subscription)
      assert body["config"]["insecure_ssl"] == "0"

      Req.Test.json(conn, %{
        "id" => 77,
        "active" => true,
        "config" => %{"url" => body["config"]["url"]}
      })
    end)
  end

  defp signed_conn(subscription, payload) do
    raw = Jason.encode!(payload)

    signature =
      :crypto.mac(:hmac, :sha256, Webhooks.signing_secret(subscription), raw)
      |> Base.encode16(case: :lower)

    Plug.Test.conn(:post, "/hooks/" <> subscription.webhook_token, raw)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-github-event", "issues")
    |> Plug.Conn.put_req_header("x-github-delivery", "delivery-1")
    |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=" <> signature)
  end
end
