defmodule Hermitscale.Integrations.DeliveriesTest do
  use Hermitscale.DataCase, async: false
  import Hermitscale.DeliveryFixtures
  import Hermitscale.IntegrationsFixtures
  alias Hermitscale.{Auth, AuthTest.Provider}
  alias Hermitscale.Integrations.Deliveries
  alias Hermitscale.WorkOSTest.Client, as: Pipes

  setup {Req.Test, :set_req_test_from_context}
  setup {Req.Test, :verify_on_exit!}

  setup do
    configure(Auth, provider: Provider)
    configure(Hermitscale.Integrations.GitHub.Client, req_options: [plug: {Req.Test, __MODULE__}])
    start_supervised!({Provider, %{}})
    start_supervised!({Pipes, %{}})
    {:ok, authentication} = Auth.sign_in("team-code")
    scope = authentication.current_scope

    Pipes.put_response(
      :list_org_providers,
      {:ok,
       %{
         "data" => [
           %{
             "slug" => "github",
             "connected_accounts" => [account_fixture("github", scope.organization.id)]
           }
         ]
       }}
    )

    Pipes.put_response(
      :vend_credentials,
      {:ok,
       %{
         auth_method: "oauth",
         value: "provider-secret",
         scopes: scopes_fixture("github"),
         missing_scopes: []
       }}
    )

    %{scope: scope}
  end

  test "retries return the retained provider result without another mutation", %{scope: scope} do
    attrs = pull_delivery_fixture()
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, []))

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      Req.Test.json(conn, pull_result_fixture(%{"body" => payload["body"]}))
    end)

    assert {:ok, result} = Deliveries.deliver(scope, attrs)
    assert {:ok, ^result} = Deliveries.deliver(scope, attrs)
    assert {:ok, %{status: :succeeded}} = Deliveries.get_by_key(scope, attrs.effect_key)
    changed = put_in(attrs.params.title, "Different changes")
    assert {:error, :effect_key_conflict} = Deliveries.deliver(scope, changed)
  end

  test "a lost response is reconciled by marker and never blindly creates a second PR", %{
    scope: scope
  } do
    attrs = pull_delivery_fixture()
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, []))

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, :delivery_uncertain} = Deliveries.deliver(scope, attrs)
    assert {:ok, delivery} = Deliveries.get_by_key(scope, attrs.effect_key)
    assert delivery.status == :uncertain
    marker = "<!-- hermitscale-delivery:#{delivery.id} -->"
    result = pull_result_fixture(%{"body" => "Verified changes\n\n" <> marker})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [result])
    end)

    assert {:ok, ^result} = Deliveries.deliver(scope, attrs)
    assert {:ok, ^result} = Deliveries.deliver(scope, attrs)
  end

  test "an unresolved lost response remains uncertain and has no second POST", %{scope: scope} do
    attrs = pull_delivery_fixture()
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, []))
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :delivery_uncertain} = Deliveries.deliver(scope, attrs)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    assert {:error, :delivery_uncertain} = Deliveries.deliver(scope, attrs)
    assert {:ok, %{status: :uncertain}} = Deliveries.get_by_key(scope, attrs.effect_key)
  end

  test "reconciliation cannot accept a PR whose published revision changed", %{scope: scope} do
    sha = String.duplicate("a", 40)

    attrs =
      pull_delivery_fixture(%{
        publication: %{repository: "acme/backend", branch: "fix/ENG-7", commit_sha: sha}
      })

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, []))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"object" => %{"sha" => sha}}))
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :delivery_uncertain} = Deliveries.deliver(scope, attrs)
    assert {:ok, delivery} = Deliveries.get_by_key(scope, attrs.effect_key)
    marker = "<!-- hermitscale-delivery:#{delivery.id} -->"

    changed =
      pull_result_fixture(%{"body" => marker, "head" => %{"sha" => String.duplicate("b", 40)}})

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, [changed]))
    assert {:error, :published_branch_changed} = Deliveries.deliver(scope, attrs)
    assert {:ok, %{status: :uncertain}} = Deliveries.get_by_key(scope, attrs.effect_key)
  end

  test "foreign organizations, forbidden scopes and invalid payloads are rejected", %{
    scope: scope
  } do
    attrs = pull_delivery_fixture()
    denied = %{scope | membership: %{scope.membership | permissions: []}}
    assert {:error, :forbidden} = Deliveries.deliver(denied, attrs)
    assert {:error, :invalid_delivery_params} = Deliveries.deliver(scope, %{attrs | params: %{}})

    assert {:error, :unsupported_delivery} =
             Deliveries.deliver(scope, %{attrs | kind: "github.arbitrary"})
  end

  defp configure(module, options) do
    previous = Application.get_env(:hermitscale, module)
    Application.put_env(:hermitscale, module, options)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hermitscale, module, previous),
        else: Application.delete_env(:hermitscale, module)
    end)
  end
end
