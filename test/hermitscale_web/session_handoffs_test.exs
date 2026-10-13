defmodule HermitscaleWeb.SessionHandoffsTest do
  use ExUnit.Case, async: true
  alias HermitscaleWeb.SessionHandoffs

  setup do
    clock = start_supervised!({Agent, fn -> 1_000 end})

    handoffs =
      start_supervised!({SessionHandoffs, name: nil, clock: fn -> Agent.get(clock, & &1) end})

    %{clock: clock, handoffs: handoffs}
  end

  test "a bound browser consumes a nonce only once", %{handoffs: handoffs} do
    assert {:ok, nonce} = SessionHandoffs.create("incoming-seal", "rotated-seal", handoffs)

    assert {:ok, %{sealed_session: "rotated-seal", return_to: "/agents"}} =
             SessionHandoffs.consume(nonce, "incoming-seal", handoffs)

    assert {:error, :invalid_handoff} = SessionHandoffs.consume(nonce, "incoming-seal", handoffs)
  end

  test "another browser cannot use the retained seal", %{handoffs: handoffs} do
    assert {:ok, nonce} = SessionHandoffs.create("incoming-seal", "rotated-seal", handoffs)
    assert {:error, :invalid_handoff} = SessionHandoffs.consume(nonce, "another-cookie", handoffs)
    assert {:error, :invalid_handoff} = SessionHandoffs.consume(nonce, "incoming-seal", handoffs)
    assert {:error, :invalid_handoff} = SessionHandoffs.consume(nonce, nil, handoffs)
  end

  test "a handoff expires after one minute", %{handoffs: handoffs, clock: clock} do
    assert {:ok, nonce} = SessionHandoffs.create("incoming-seal", "rotated-seal", handoffs)
    Agent.update(clock, fn now -> now + 60_000 end)
    assert {:error, :invalid_handoff} = SessionHandoffs.consume(nonce, "incoming-seal", handoffs)
  end

  test "unknown nonces grant no authority", %{handoffs: handoffs} do
    assert {:error, :invalid_handoff} =
             SessionHandoffs.consume("unknown", "incoming-seal", handoffs)
  end

  test "only known product return paths can be retained", %{handoffs: handoffs} do
    path = "/agents/" <> Ecto.UUID.generate()
    assert {:ok, nonce} = SessionHandoffs.create("old", "new", handoffs, path)

    assert {:ok, %{sealed_session: "new", return_to: ^path}} =
             SessionHandoffs.consume(nonce, "old", handoffs)

    app_id = Ecto.UUID.generate()

    for product_path <- [
          "/apps",
          "/reviews",
          "/workflows",
          "/apps/" <> app_id <> "/build",
          "/apps/" <> app_id <> "/deployments/" <> Ecto.UUID.generate(),
          "/reviews/" <> Ecto.UUID.generate(),
          "/workflows/wf:stored_1"
        ] do
      assert {:ok, nonce} = SessionHandoffs.create("old", "new", handoffs, product_path)
      assert {:ok, %{return_to: ^product_path}} = SessionHandoffs.consume(nonce, "old", handoffs)
    end

    for untrusted <- [
          "https://other.example/",
          "//other.example/",
          "/agents/../auth/login",
          "/agents?redirect=evil",
          "/apps/" <> app_id <> "/../auth/logout",
          "/workflows/wf?redirect=https://other.example/"
        ] do
      assert {:error, :invalid_return_to} =
               SessionHandoffs.create("old", "new", handoffs, untrusted)
    end
  end
end
