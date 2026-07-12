defmodule HermitscaleWeb.WebhookControllerTest do
  use HermitscaleWeb.ConnCase, async: false

  import Hermitscale.AccountsFixtures
  import Hermitscale.TriggersFixtures

  alias Hermitscale.Repo
  alias Hermitscale.Triggers
  alias Hermitscale.Workflows
  alias Hermitscale.Workflows.Run

  setup do
    %{scope: user_scope_fixture()}
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  test "unknown tokens 404", %{conn: conn} do
    conn = post_json(conn, ~p"/hooks/nope", %{})
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "a valid request fires a run and returns 202", %{conn: conn, scope: scope} do
    {_graph, trigger} = activate_trigger_graph!(scope, webhook_trigger_node())

    conn = post_json(conn, ~p"/hooks/#{trigger.webhook_token}", %{"hello" => "world"})

    response = json_response(conn, 202)
    assert response["status"] == "accepted"

    run = Workflows.get_run!(scope, response["run_id"])
    data = run.input["value"]["data"]
    assert data["body"] == %{"hello" => "world"}
    assert data["method"] == "POST"
  end

  test "disabled triggers 404 without leaking existence", %{conn: conn, scope: scope} do
    {graph, trigger} = activate_trigger_graph!(scope, webhook_trigger_node())
    {:ok, _graph} = Triggers.deactivate_graph(scope, graph)

    conn = post_json(conn, ~p"/hooks/#{trigger.webhook_token}", %{})
    assert json_response(conn, 404)["error"] == "not_found"
    assert Repo.aggregate(Run, :count) == 0
  end

  describe "shared-secret auth" do
    setup %{conn: conn, scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(
          scope,
          webhook_trigger_node(%{"auth" => "secret", "secret" => "s3cret"})
        )

      %{conn: conn, trigger: trigger}
    end

    test "rejects requests without the secret", %{conn: conn, trigger: trigger} do
      conn = post_json(conn, ~p"/hooks/#{trigger.webhook_token}", %{})
      assert json_response(conn, 401)["error"] == "unauthorized"
      assert Repo.aggregate(Run, :count) == 0
    end

    test "accepts requests carrying the secret and redacts it from the payload",
         %{conn: conn, scope: scope, trigger: trigger} do
      conn =
        conn
        |> put_req_header("x-hermitscale-secret", "s3cret")
        |> post_json(~p"/hooks/#{trigger.webhook_token}", %{"n" => 1})

      response = json_response(conn, 202)
      run = Workflows.get_run!(scope, response["run_id"])
      headers = run.input["value"]["data"]["headers"]
      refute Map.has_key?(headers, "x-hermitscale-secret")
    end
  end

  describe "hmac auth" do
    setup %{conn: conn, scope: scope} do
      {_graph, trigger} =
        activate_trigger_graph!(
          scope,
          webhook_trigger_node(%{"auth" => "hmac", "secret" => "s3cret"})
        )

      %{conn: conn, trigger: trigger}
    end

    defp sign(body),
      do: :hmac |> :crypto.mac(:sha256, "s3cret", body) |> Base.encode16(case: :lower)

    test "accepts a correctly signed body (with sha256= prefix)", %{conn: conn, trigger: trigger} do
      body = Jason.encode!(%{"n" => 1})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-signature", "sha256=#{sign(body)}")
        |> post(~p"/hooks/#{trigger.webhook_token}", body)

      assert json_response(conn, 202)["status"] == "accepted"
    end

    test "rejects a bad signature", %{conn: conn, trigger: trigger} do
      body = Jason.encode!(%{"n" => 1})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-signature", sign("tampered"))
        |> post(~p"/hooks/#{trigger.webhook_token}", body)

      assert json_response(conn, 401)["error"] == "unauthorized"
      assert Repo.aggregate(Run, :count) == 0
    end
  end

  test "respond=when_finished returns the run output", %{conn: conn, scope: scope} do
    {_graph, trigger} =
      activate_trigger_graph!(
        scope,
        webhook_trigger_node(%{"respond" => "when_finished"})
      )

    conn = post_json(conn, ~p"/hooks/#{trigger.webhook_token}", %{"n" => 7})

    response = json_response(conn, 200)
    assert response["status"] == "complete"
    assert [echoed] = response["output"]["value"]["echo"]
    assert echoed["body"] == %{"n" => 7}
  end
end
