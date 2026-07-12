defmodule Hermitscale.Integrations.Google.OAuth do
  @moduledoc """
  Google OAuth credential provider.

  `fetch_token/2` accepts an opaque reference and resolves it through the
  configured `:google_oauth_credential_store` before checking or refreshing the
  token. If no store is configured, the reference itself is treated as the
  credential payload for local development and tests.
  """

  use Hermitscale.Integrations.Provider

  @provider "google.oauth"
  @token_url "https://oauth2.googleapis.com/token"
  @refresh_margin_seconds 60

  @impl true
  def provider_id, do: @provider

  @impl true
  def network_domains do
    [
      "oauth2.googleapis.com",
      "sheets.googleapis.com",
      "www.googleapis.com"
    ]
  end

  @impl true
  def spec do
    %{
      id: @provider,
      methods: %{
        oauth: %{
          authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
          token_url: @token_url,
          default_scopes: [],
          refresh: :standard
        }
      }
    }
  end

  @impl true
  def fetch_token(ref, scopes) do
    # References known to the credential system resolve there (storage,
    # refresh, audit). Anything else — legacy external-store refs, raw dev
    # payloads — takes the pre-existing path below until call sites migrate.
    case Hermitscale.Credentials.fetch_token(@provider, ref, scopes) do
      {:ok, token} ->
        {:ok, token}

      {:error, :unknown_credential} ->
        fetch_token(ref, scopes, Application.get_env(:hermitscale, :google_oauth_req_options, []))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def fetch_token(ref, scopes, req_opts)
      when is_map(ref) and is_list(scopes) and is_list(req_opts) do
    {credential_store, req_opts} =
      Keyword.pop(
        req_opts,
        :credential_store,
        Application.get_env(:hermitscale, :google_oauth_credential_store)
      )

    with {:ok, credential} <- credential_payload(ref, credential_store) do
      fetch_credential_token(credential, scopes, req_opts)
    end
  end

  defp credential_payload(ref, nil), do: {:ok, ref}
  defp credential_payload(ref, store) when is_function(store, 1), do: store.(ref)

  defp credential_payload(ref, store) when is_atom(store) do
    apply(store, :fetch_google_oauth_credential, [ref])
  end

  defp fetch_credential_token(credential, scopes, req_opts) do
    case access_token(credential) do
      {:ok, token} ->
        {:ok, token}

      :refresh ->
        refresh_token(credential, scopes, req_opts)

      :error ->
        {:error, :missing_google_oauth_credentials}
    end
  end

  defp access_token(ref) do
    with {:ok, access_token} <- fetch_binary(ref, :access_token),
         {:ok, expires_at} <- expires_at(ref),
         false <- stale?(expires_at) do
      {:ok, %{access_token: access_token, expires_at: expires_at}}
    else
      true -> :refresh
      :missing_expiry -> {:ok, %{access_token: fetch_value(ref, :access_token), expires_at: nil}}
      _other -> :error
    end
  end

  defp refresh_token(ref, scopes, req_opts) do
    with {:ok, refresh_token} <- fetch_binary(ref, :refresh_token),
         {:ok, client_id} <- fetch_binary(ref, :client_id),
         {:ok, client_secret} <- fetch_binary(ref, :client_secret),
         {:ok, response} <-
           Req.post(
             Keyword.merge(
               [
                 url: @token_url,
                 form: [
                   client_id: client_id,
                   client_secret: client_secret,
                   grant_type: "refresh_token",
                   refresh_token: refresh_token,
                   scope: Enum.join(scopes, " ")
                 ]
               ],
               req_opts
             )
           ) do
      token_response(response)
    else
      :error ->
        {:error, :missing_google_oauth_credentials}

      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  defp token_response(%Req.Response{status: status, body: body}) when status in 200..299 do
    with %{"access_token" => access_token} when is_binary(access_token) <- body do
      {:ok,
       %{
         access_token: access_token,
         expires_at: expires_at_from_body(body)
       }}
    else
      _body -> {:error, :invalid_token_response}
    end
  end

  defp token_response(%Req.Response{status: status}) do
    {:error, {:token_refresh_failed, status}}
  end

  defp expires_at_from_body(%{"expires_in" => expires_in}) when is_integer(expires_in) do
    DateTime.utc_now(:second)
    |> DateTime.add(expires_in, :second)
  end

  defp expires_at_from_body(_body), do: nil

  defp expires_at(ref) do
    case fetch_value(ref, :expires_at) do
      nil ->
        :missing_expiry

      %DateTime{} = expires_at ->
        {:ok, expires_at}

      expires_at when is_binary(expires_at) ->
        parse_expires_at(expires_at)

      _other ->
        :error
    end
  end

  defp parse_expires_at(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  defp stale?(nil), do: false

  defp stale?(%DateTime{} = expires_at) do
    DateTime.utc_now(:second)
    |> DateTime.add(@refresh_margin_seconds, :second)
    |> DateTime.compare(expires_at)
    |> Kernel.!=(:lt)
  end

  defp fetch_binary(ref, key) do
    case fetch_value(ref, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp fetch_value(ref, key) do
    Map.get(ref, key) || Map.get(ref, Atom.to_string(key))
  end
end
