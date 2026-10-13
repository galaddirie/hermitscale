defmodule HermitscaleWeb.AgentLiveTest do
  use HermitscaleWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import HermitscaleWeb.BrowserAuthFixtures
  import HermitscaleWeb.AgentFixtures

  alias Hermitscale.Agents
  alias Hermitscale.AuthTest.Provider

  setup %{conn: conn} do
    setup_provider()
    authenticated_conn(conn)
  end

  describe "conversation list" do
    test "requires a provider session", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} =
               conn |> clear_session() |> live(~p"/agents")
    end

    test "shows persisted conversations and creates a new conversation", %{
      conn: conn,
      scope: scope
    } do
      session = conversation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/agents")
      assert has_element?(view, "#agent-sessions-#{session.id}")
      assert has_element?(view, "#new-conversation-form")

      view
      |> form("#new-conversation-form", session: %{title: "Investigate an issue"})
      |> render_submit()

      assert_redirect(view)
      assert Enum.any?(Agents.list_sessions(scope), &(&1.title == "Investigate an issue"))
    end

    test "invalid conversation preserves its form and creates no record", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, ~p"/agents")
      view |> form("#new-conversation-form", session: %{title: ""}) |> render_submit()
      assert has_element?(view, "#new-conversation-form")
      assert has_element?(view, "#new-conversation-form p", "can't be blank")
      assert Agents.list_sessions(scope) == []
    end
  end

  describe "conversation" do
    test "retains a submitted turn and shows queued work", %{
      conn: conn,
      scope: scope
    } do
      session = conversation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      assert has_element?(view, "#turn-form")

      view
      |> form("#turn-form",
        turn: %{instructions: "Inspect this project", timeout_seconds: 1800}
      )
      |> render_submit()

      [turn] = Agents.list_turns(scope, session.id)
      assert has_element?(view, "#agent-turns-#{turn.id}", "Inspect this project")
      assert has_element?(view, "#turn-status-#{turn.id}")
    end

    test "shows native turn permission controls to the executing actor", %{
      conn: conn,
      scope: scope
    } do
      session = conversation_fixture(scope)
      turn = turn_fixture(scope, session)
      request = %{"permission_id" => "permission-1", "command" => "Inspect workspace files"}

      {:ok, approval} =
        Agents.Approvals.request(scope, turn.id, %{
          action: "agents.approve",
          target_digest: Agents.Protocol.payload_digest(request)
        })

      turn
      |> Ecto.Changeset.change(
        status: :waiting_for_approval,
        approval_id: approval.id,
        runtime_state: %{"approval_request" => request}
      )
      |> Hermitscale.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      assert has_element?(view, "#approval-#{turn.id}")
      assert has_element?(view, "#approve-turn-#{turn.id}")
      assert has_element?(view, "#deny-turn-#{turn.id}")

      Provider.put_response(:get_role, {:ok, %{slug: "admin", permissions: ["agents:read"]}})
      {:ok, viewer, _html} = live(conn, ~p"/agents/#{session.id}")
      assert has_element?(viewer, "#approval-#{turn.id}")
      refute has_element?(viewer, "#approve-turn-#{turn.id}")
      refute has_element?(viewer, "#deny-turn-#{turn.id}")
    end

    test "updates history from committed PubSub events", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      turn = turn_fixture(scope, session)
      assert has_element?(view, "#agent-turns-#{turn.id}")
    end

    test "a repeated form operation saves only one turn", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")

      [operation_key] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#turn_operation_key")
        |> LazyHTML.attribute("value")

      params = %{
        instructions: "Keep this request once",
        operation_key: operation_key,
        timeout_seconds: 1800
      }

      view |> form("#turn-form", turn: params) |> render_submit()
      render_submit(view, "submit_turn", %{"turn" => params})
      assert length(Agents.list_turns(scope, session.id)) == 1
    end

    test "invalid instructions display an error without admitting a turn", %{
      conn: conn,
      scope: scope
    } do
      session = conversation_fixture(scope)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      view |> form("#turn-form", turn: %{instructions: ""}) |> render_submit()
      assert has_element?(view, "#turn-form p", "can't be blank")
      assert Agents.list_turns(scope, session.id) == []
    end

    test "stops an undispatched turn through durable cancellation", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)
      turn = turn_fixture(scope, session)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      view |> element("#stop-turn-#{turn.id}") |> render_click()
      assert has_element?(view, "#turn-status-#{turn.id}", "Cancelled")
      refute has_element?(view, "#stop-turn-#{turn.id}")
    end

    test "pages older history and keeps it when new work arrives", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)

      turns =
        for index <- 1..22, do: turn_fixture(scope, session, %{instructions: "Request #{index}"})

      first = List.first(turns)
      last = List.last(turns)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      refute has_element?(view, "#agent-turns-#{first.id}")
      assert has_element?(view, "#agent-turns-#{last.id}")
      view |> element("#load-older-turns") |> render_click()
      assert has_element?(view, "#agent-turns-#{first.id}")
      assert {:ok, _turn} = Agents.cancel_turn(scope, first.id)
      assert has_element?(view, "#turn-status-#{first.id}", "Cancelled")
      view |> element("#load-older-events") |> render_click()
      refute has_element?(view, "#load-older-events")
      next = turn_fixture(scope, session)
      assert has_element?(view, "#agent-turns-#{first.id}")
      assert has_element?(view, "#agent-turns-#{next.id}")
    end

    test "archives and reopens without deleting history", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)
      turn = turn_fixture(scope, session)
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      view |> element("#archive-conversation") |> render_click()
      assert has_element?(view, "#reopen-conversation")
      refute has_element?(view, "#turn-form")
      assert has_element?(view, "#agent-turns-#{turn.id}")
      view |> element("#reopen-conversation") |> render_click()
      assert has_element?(view, "#turn-form")
    end

    test "does not open another initiator's conversation", %{conn: conn, scope: scope} do
      other_scope = %{
        scope
        | user: %{scope.user | id: "other-user"},
          membership: %{scope.membership | user_id: "other-user"}
      }

      Provider.put_response(
        :list_memberships,
        {:ok, [%{other_scope.membership | status: "active"}]}
      )

      session = conversation_fixture(other_scope)
      Provider.reset_responses()
      assert {:error, {:live_redirect, %{to: "/agents"}}} = live(conn, ~p"/agents/#{session.id}")
    end

    test "removed membership cannot reconnect", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)
      Provider.put_response(:list_memberships, {:ok, []})
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/agents/#{session.id}")
    end

    test "viewers can inspect history without run controls", %{conn: conn, scope: scope} do
      session = conversation_fixture(scope)
      turn = turn_fixture(scope, session)
      Provider.put_response(:get_role, {:ok, %{slug: "admin", permissions: ["agents:read"]}})
      {:ok, view, _html} = live(conn, ~p"/agents/#{session.id}")
      assert has_element?(view, "#agent-turns-#{turn.id}")
      assert has_element?(view, "#conversation-permission-read-only")
      refute has_element?(view, "#turn-form")
      refute has_element?(view, "#archive-conversation")
      refute has_element?(view, "#stop-turn-#{turn.id}")
    end
  end
end
