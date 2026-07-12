defmodule Hermitscale.Credentials.Backends.LocalTest do
  use Hermitscale.DataCase, async: true
  use Hermitscale.Credentials.BackendCase

  import Ecto.Query
  import Hermitscale.CredentialsFixtures

  alias Hermitscale.Credentials.Backends.Local
  alias Hermitscale.Credentials.Backends.Local.Secret

  setup do
    credential = credential_row_fixture()

    ctx = %{
      credential_id: credential.id,
      provider: credential.provider,
      org_id: credential.org_id,
      user_id: nil,
      external_ref: nil
    }

    %{backend: Local, backend_ctx: ctx, credential: credential}
  end

  describe "local specifics" do
    test "each put writes a new version and get reads the latest",
         %{backend_ctx: ctx} do
      assert {:ok, _ref} = Local.put_secret(%ApiKey{key: "v1"}, ctx)
      assert {:ok, _ref} = Local.put_secret(%ApiKey{key: "v2"}, ctx)

      assert {:ok, %ApiKey{key: "v2"}} = Local.get_secret(ctx.credential_id, ctx)

      versions =
        Secret
        |> where([s], s.credential_id == ^ctx.credential_id)
        |> select([s], s.version)
        |> order_by([s], asc: s.version)
        |> Repo.all()

      assert versions == [1, 2]
    end

    test "payload is ciphertext at rest", %{backend_ctx: ctx} do
      assert {:ok, _ref} = Local.put_secret(%ApiKey{key: "plaintext_marker"}, ctx)

      %{rows: [[raw_payload]]} =
        Repo.query!(
          "SELECT payload FROM credential_secrets WHERE credential_id = $1",
          [ctx.credential_id]
        )

      refute raw_payload =~ "plaintext_marker"
    end

    test "delete removes every version", %{backend_ctx: ctx} do
      assert {:ok, _ref} = Local.put_secret(%ApiKey{key: "v1"}, ctx)
      assert {:ok, _ref} = Local.put_secret(%ApiKey{key: "v2"}, ctx)
      assert :ok = Local.delete_secret(ctx.credential_id, ctx)

      assert Repo.aggregate(
               where(Secret, [s], s.credential_id == ^ctx.credential_id),
               :count
             ) == 0
    end
  end
end
