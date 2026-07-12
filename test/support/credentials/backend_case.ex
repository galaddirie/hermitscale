defmodule Hermitscale.Credentials.BackendCase do
  @moduledoc """
  Conformance suite every credential backend must pass.

  `use` it in a backend's test module and provide a setup returning
  `%{backend: module, backend_ctx: ctx}` where `ctx` is a valid
  `Hermitscale.Credentials.Backend.ctx()` (for backends with foreign keys,
  the referenced credential row must exist).
  """

  defmacro __using__(_opts) do
    quote do
      alias Hermitscale.Credentials.SecretPayload.{ApiKey, Custom, OAuthToken}

      describe "backend conformance: secret material" do
        test "api key round-trips", %{backend: backend, backend_ctx: ctx} do
          assert {:ok, ref} = backend.put_secret(%ApiKey{key: "sk_live_123"}, ctx)
          assert {:ok, %ApiKey{key: "sk_live_123"}} = backend.get_secret(ref, ctx)
        end

        test "oauth token round-trips with expiry and scopes",
             %{backend: backend, backend_ctx: ctx} do
          expires_at = DateTime.add(DateTime.utc_now(:second), 3_600, :second)

          payload = %OAuthToken{
            access_token: "access_1",
            refresh_token: "refresh_1",
            expires_at: expires_at,
            scopes: ["repo", "read:org"]
          }

          assert {:ok, ref} = backend.put_secret(payload, ctx)

          assert {:ok,
                  %OAuthToken{
                    access_token: "access_1",
                    refresh_token: "refresh_1",
                    expires_at: ^expires_at,
                    scopes: ["repo", "read:org"]
                  }} = backend.get_secret(ref, ctx)
        end

        test "custom fields round-trip", %{backend: backend, backend_ctx: ctx} do
          fields = %{"username" => "svc", "password" => "hunter2"}
          assert {:ok, ref} = backend.put_secret(%Custom{fields: fields}, ctx)
          assert {:ok, %Custom{fields: ^fields}} = backend.get_secret(ref, ctx)
        end

        test "put with an existing external_ref replaces the material",
             %{backend: backend, backend_ctx: ctx} do
          assert {:ok, ref} = backend.put_secret(%ApiKey{key: "v1"}, ctx)

          update_ctx = Map.put(ctx, :external_ref, ref)
          assert {:ok, new_ref} = backend.put_secret(%ApiKey{key: "v2"}, update_ctx)
          assert {:ok, %ApiKey{key: "v2"}} = backend.get_secret(new_ref, ctx)
        end

        test "get_secret on an unknown ref is :not_found",
             %{backend: backend, backend_ctx: ctx} do
          assert {:error, :not_found} = backend.get_secret("missing_#{Ecto.UUID.generate()}", ctx)
        end

        test "delete_secret removes material and is idempotent",
             %{backend: backend, backend_ctx: ctx} do
          assert {:ok, ref} = backend.put_secret(%ApiKey{key: "doomed"}, ctx)
          assert :ok = backend.delete_secret(ref, ctx)
          assert {:error, :not_found} = backend.get_secret(ref, ctx)
          assert :ok = backend.delete_secret(ref, ctx)
        end
      end
    end
  end
end
