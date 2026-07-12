defmodule Hermitscale.Credentials.Backends.WorkOS do
  @moduledoc """
  Hosted credential backend on WorkOS: OAuth connections live in Pipes
  (WorkOS runs the authorization flow, stores refresh tokens, and returns
  always-fresh access tokens), API keys and custom payloads live in Vault as
  encrypted key-value objects whose encryption keys derive from a per-tenant
  key context.

  Configuration (`config :hermitscale, __MODULE__`): `:api_key`, `:client_id`,
  optional `:base_url` and `:req_options` (test stubbing).

  Endpoint paths are centralized below. Pipes is a young API surface —
  **verify the paths against the current WorkOS API reference before
  production use**; the conformance suite stubs them, so a path change is a
  one-line fix here.
  """

  @behaviour Hermitscale.Credentials.Backend

  alias Hermitscale.Credentials.{AccessToken, SecretPayload}

  @base_url "https://api.workos.com"
  @vault_kv_path "/vault/v1/kv"
  @pipes_tokens_path "/pipes/v1/tokens"
  @pipes_connections_path "/pipes/v1/connections"

  # Body codes WorkOS uses to signal that the *connection* (not our API key)
  # needs the user to reauthorize.
  @reauth_codes ["reauthorization_required", "connection_deactivated", "invalid_connection"]

  @impl true
  def id, do: "workos"

  @impl true
  def capabilities, do: [:managed_oauth, :secret_versions]

  # --- Secret material (Vault) ---

  @impl true
  def put_secret(payload, ctx) do
    value = Jason.encode!(SecretPayload.to_map(payload))

    case ctx[:external_ref] do
      nil ->
        body = %{
          name: "credential_" <> ctx.credential_id,
          value: value,
          key_context: key_context(ctx)
        }

        case request(:post, @vault_kv_path, json: body) do
          {:ok, %{"id" => object_id}} -> {:ok, object_id}
          {:ok, body} -> {:error, {:unexpected_vault_response, body}}
          {:error, reason} -> {:error, reason}
        end

      external_ref ->
        # Updating in place keeps the object's server-side version history.
        case request(:put, @vault_kv_path <> "/" <> external_ref, json: %{value: value}) do
          {:ok, _body} -> {:ok, external_ref}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def get_secret(external_ref, _ctx) do
    case request(:get, @vault_kv_path <> "/" <> external_ref, []) do
      {:ok, %{"value" => value}} when is_binary(value) ->
        with {:ok, map} <- Jason.decode(value) do
          SecretPayload.from_map(map)
        end

      {:ok, body} ->
        {:error, {:unexpected_vault_response, body}}

      {:error, {:status, 404, _body}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_secret(external_ref, _ctx) do
    case request(:delete, @vault_kv_path <> "/" <> external_ref, []) do
      {:ok, _body} -> :ok
      {:error, {:status, 404, _body}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Managed OAuth (Pipes) ---

  @impl true
  def connect_config(provider, ctx) do
    {:ok,
     %{
       type: "workos_pipes_widget",
       provider: provider,
       client_id: Keyword.fetch!(config(), :client_id),
       context: %{
         org_id: ctx.org_id,
         user_id: ctx[:user_id],
         credential_id: ctx.credential_id
       }
     }}
  end

  @impl true
  def get_oauth_token(connection_id, _ctx) do
    case request(:post, @pipes_tokens_path, json: %{connection_id: connection_id}) do
      {:ok, %{"access_token" => access_token} = body} when is_binary(access_token) ->
        {:ok,
         %AccessToken{
           access_token: access_token,
           expires_at: parse_expiry(body),
           scopes: body["scopes"] || []
         }}

      {:ok, body} ->
        {:error, {:unexpected_pipes_response, body}}

      {:error, {:status, _status, %{"code" => code}}} when code in @reauth_codes ->
        {:error, :reauth_required}

      {:error, {:status, 404, _body}} ->
        {:error, :reauth_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def disconnect(connection_id, _ctx) do
    case request(:delete, @pipes_connections_path <> "/" <> connection_id, []) do
      {:ok, _body} -> :ok
      {:error, {:status, 404, _body}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- HTTP ---

  defp key_context(ctx) do
    %{"org_id" => ctx.org_id, "credential_id" => ctx.credential_id}
  end

  defp parse_expiry(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_expiry(%{"expires_in" => expires_in}) when is_integer(expires_in) do
    DateTime.add(DateTime.utc_now(:second), expires_in, :second)
  end

  defp parse_expiry(_body), do: nil

  defp request(method, path, opts) do
    cfg = config()

    base_opts = [
      method: method,
      url: Keyword.get(cfg, :base_url, @base_url) <> path,
      auth: {:bearer, Keyword.fetch!(cfg, :api_key)}
    ]

    request_opts = Keyword.merge(base_opts ++ opts, Keyword.get(cfg, :req_options, []))

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, body}}

      {:error, reason} ->
        {:error, {:workos_unreachable, reason}}
    end
  end

  defp config do
    Application.get_env(:hermitscale, __MODULE__, [])
  end
end
