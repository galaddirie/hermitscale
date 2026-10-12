defmodule Hermitscale.WorkOS.Session do
  @moduledoc """
  WorkOS authentication using an encrypted browser session without local tables.

  Access tokens are verified on every request. Tokens near expiry are refreshed
  through WorkOS, and refreshed identity, session and tenant claims must match
  the original session. The original browser lifetime survives token rotation.
  """

  alias Hermitscale.Accounts.Scope
  alias Hermitscale.WorkOS.{Client, JWT}

  @salt "workos-browser-session-v1"
  @default_max_age_seconds 30 * 24 * 60 * 60
  @refresh_margin_seconds 60

  @doc "Verifies a WorkOS authentication response and seals its minimal session data."
  def create(authentication) when is_map(authentication) do
    with {:ok, access_token} <- required_string(authentication, "access_token"),
         {:ok, refresh_token} <- required_string(authentication, "refresh_token"),
         %{"id" => user_id} = profile when is_binary(user_id) and user_id != "" <-
           authentication["user"],
         {:ok, claims} <- verify_token(access_token, subject: user_id),
         :ok <- validate_claim_shape(claims) do
      payload = %{
        access_token: access_token,
        refresh_token: refresh_token,
        user: %{
          id: user_id,
          email: profile["email"],
          first_name: profile["first_name"],
          last_name: profile["last_name"]
        },
        session_id: claims["sid"],
        organization_id: claims["org_id"],
        started_at: System.system_time(:second)
      }

      authentication_result(payload, claims)
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_authentication_response}
    end
  end

  def create(_authentication), do: {:error, :invalid_authentication_response}

  @doc "Authenticates a sealed session, rotating WorkOS tokens when needed."
  def authenticate(sealed_session, request_metadata \\ %{}) do
    with {:ok, payload} <- unseal(sealed_session),
         {:ok, claims} <- verify_payload(payload, true),
         {:ok, refreshed_payload, claims} <- verify_or_refresh(payload, claims, request_metadata) do
      authentication_result(
        refreshed_payload,
        claims,
        retained_seal(payload, refreshed_payload, sealed_session)
      )
    end
  end

  @doc "Provisions every sign-in user's personal org and selects it when no tenant was supplied."
  def establish(authentication, metadata \\ %{}) do
    with {:ok, result} <- create(authentication),
         {:ok, org} <-
           Hermitscale.Accounts.ensure_personal_organization(result.current_scope.user) do
      case result.current_scope.organization do
        nil -> switch_organization(result.sealed_session, org["id"], metadata)
        _organization -> {:ok, result}
      end
    end
  end

  @doc "Explicitly switches workspace, verifying returned user, session and requested tenant."
  def switch_organization(sealed_session, organization_id, metadata \\ %{})
      when is_binary(organization_id) and organization_id != "" do
    with {:ok, payload} <- unseal(sealed_session),
         {:ok, _claims} <- verify_payload(payload, true),
         {:ok, replacement, claims} <-
           refresh(%{payload | organization_id: organization_id}, metadata) do
      authentication_result(replacement, claims)
    end
  end

  @doc "Refreshes permissions while preserving the current tenant and original browser lifetime."
  def refresh_claims(sealed_session, metadata \\ %{}) do
    with {:ok, payload} <- unseal(sealed_session),
         {:ok, _claims} <- verify_payload(payload, true),
         {:ok, replacement, claims} <- refresh(payload, metadata) do
      authentication_result(replacement, claims)
    end
  end

  @doc "Revokes the WorkOS session and returns its browser logout URL."
  def logout(sealed_session, return_to \\ nil) do
    with {:ok, payload} <- unseal(sealed_session),
         {:ok, _claims} <- verify_payload(payload, true),
         {:ok, _response} <- client().revoke_session(payload.session_id) do
      {:ok, client().logout_url(payload.session_id, return_to)}
    end
  end

  @doc "Returns the LiveView disconnect topic for the authoritative WorkOS session."
  def socket_topic(%{id: session_id}), do: "workos_sessions:#{session_id}"

  defp retained_seal(payload, payload, sealed_session), do: sealed_session
  defp retained_seal(_previous, _refreshed, _sealed_session), do: nil

  defp authentication_result(payload, claims, sealed_session \\ nil) do
    with {:ok, authenticated_at} <- JWT.authenticated_at(claims) do
      {:ok,
       %{
         sealed_session:
           sealed_session || Phoenix.Token.encrypt(HermitscaleWeb.Endpoint, @salt, payload),
         current_scope: Scope.from_workos(payload.user, claims),
         session: %{id: payload.session_id, authenticated_at: authenticated_at},
         claims: claims
       }}
    end
  end

  defp unseal(sealed_session) when is_binary(sealed_session) do
    with {:ok, %{started_at: started_at} = payload} <-
           Phoenix.Token.decrypt(HermitscaleWeb.Endpoint, @salt, sealed_session,
             max_age: max_age_seconds()
           ),
         true <- is_integer(started_at) and started_at <= System.system_time(:second),
         true <- System.system_time(:second) - started_at < max_age_seconds() do
      {:ok, payload}
    else
      _other -> {:error, :invalid_session}
    end
  end

  defp unseal(_sealed_session), do: {:error, :invalid_session}

  defp verify_payload(payload, allow_expired) do
    with {:ok, claims} <-
           verify_token(payload.access_token,
             subject: payload.user.id,
             session_id: payload.session_id,
             allow_expired: allow_expired
           ),
         :ok <- validate_claim_shape(claims),
         true <- claims["org_id"] == payload.organization_id do
      {:ok, claims}
    else
      _other -> {:error, :invalid_session}
    end
  end

  defp verify_or_refresh(payload, %{"exp" => expiration} = claims, request_metadata) do
    case expiration <= System.system_time(:second) + @refresh_margin_seconds do
      false -> {:ok, payload, claims}
      true -> refresh(payload, request_metadata)
    end
  end

  defp refresh(payload, request_metadata) do
    with {:ok, authentication} <-
           client().authenticate_with_refresh_token(
             payload.refresh_token,
             payload.organization_id,
             request_metadata
           ),
         :ok <- verify_refresh_user(authentication, payload.user.id),
         {:ok, access_token} <- required_string(authentication, "access_token"),
         {:ok, refresh_token} <- required_string(authentication, "refresh_token"),
         replacement = %{payload | access_token: access_token, refresh_token: refresh_token},
         {:ok, claims} <- verify_payload(replacement, false) do
      {:ok, replacement, claims}
    else
      {:error, reason} when reason in [:unavailable, :rate_limited] -> {:error, :unavailable}
      _other -> {:error, :invalid_session}
    end
  end

  defp verify_refresh_user(%{"user" => %{"id" => id}}, id), do: :ok
  defp verify_refresh_user(_authentication, _id), do: {:error, :invalid_session}

  defp validate_claim_shape(%{"sub" => subject, "sid" => sid, "exp" => expiration} = claims)
       when is_binary(subject) and subject != "" and is_binary(sid) and sid != "" and
              is_integer(expiration) do
    case claims["org_id"] do
      nil -> :ok
      organization_id when is_binary(organization_id) and organization_id != "" -> :ok
      _other -> {:error, :invalid_organization}
    end
  end

  defp validate_claim_shape(_claims), do: {:error, :invalid_access_token}

  defp required_string(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :invalid_authentication_response}
    end
  end

  defp verify_token(access_token, opts) do
    verifier = config()[:jwt_verifier] || JWT
    verifier.verify(access_token, opts)
  end

  defp client, do: config()[:client] || Client
  defp max_age_seconds, do: config()[:max_age_seconds] || @default_max_age_seconds
  defp config, do: Application.get_env(:hermitscale, __MODULE__, [])
end
