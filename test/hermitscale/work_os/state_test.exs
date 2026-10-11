defmodule Hermitscale.WorkOS.StateTest do
  use Hermitscale.DataCase, async: true

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.{AuthorizationState, State}

  test "issues a single-use state with a server-side return path" do
    assert {:ok, token} = State.issue("/users/settings?tab=security")
    assert {:ok, "/users/settings?tab=security"} = State.consume(token)
    assert {:error, :state_already_used} = State.consume(token)
  end

  test "rejects external, protocol-relative, and non-absolute return targets" do
    for target <- [
          "https://evil.example/steal",
          "//evil.example/steal",
          "users/settings",
          "javascript:alert(1)"
        ] do
      assert {:error, :invalid_return_to} = State.issue(target)
    end
  end

  test "rejects an expired state without consuming it" do
    assert {:ok, token} = State.issue("/users/settings")
    token_hash = :crypto.hash(:sha256, token)

    Repo.get_by!(AuthorizationState, token_hash: token_hash)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()

    assert {:error, :expired_state} = State.consume(token)
  end
end
