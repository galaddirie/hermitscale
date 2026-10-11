defmodule Hermitscale.WorkOS.JWT do
  @moduledoc """
  Strict WorkOS access-token verification with a bounded JWKS cache.
  """

  alias Hermitscale.WorkOS.Client

  @cache_key {__MODULE__, :jwks}
  @allowed_algorithms ["RS256"]
  @clock_skew_seconds 60
  @default_issuer_base_url "https://api.workos.com"

  @doc """
  Verifies signature, algorithm, issuer, client, lifetime, subject, and session claims.
  """
  def verify(access_token, opts \\ []) when is_binary(access_token) do
    with {:ok, header} <- decode_header(access_token),
         :ok <- validate_header(header),
         {:ok, key} <- signing_key(header["kid"]),
         {:ok, claims} <- verify_signature(key, access_token),
         :ok <- validate_claims(claims, opts) do
      {:ok, claims}
    end
  rescue
    _exception -> {:error, :invalid_access_token}
  end

  @doc """
  Converts the verified numeric `exp` claim to a second-precision `DateTime`.
  """
  def expires_at(%{"exp" => expiration}) when is_integer(expiration) do
    DateTime.from_unix(expiration)
  end

  @doc """
  Returns the original authentication time, falling back to issued-at.
  """
  def authenticated_at(claims) when is_map(claims) do
    timestamp = claims["auth_time"] || claims["iat"]

    case timestamp do
      value when is_integer(value) -> DateTime.from_unix(value)
      _other -> {:error, :invalid_authentication_time}
    end
  end

  @doc false
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp decode_header(access_token) do
    with [encoded_header, _payload, _signature] <- String.split(access_token, "."),
         {:ok, json} <- Base.url_decode64(encoded_header, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(json) do
      {:ok, header}
    else
      _other -> {:error, :invalid_access_token}
    end
  end

  defp validate_header(%{"alg" => "RS256", "kid" => kid}) when is_binary(kid) and kid != "",
    do: :ok

  defp validate_header(_header), do: {:error, :invalid_access_token_header}

  defp signing_key(kid) do
    with {:ok, jwks} <- cached_jwks(false) do
      case find_key(jwks, kid) do
        {:ok, key} ->
          {:ok, key}

        {:error, :unknown_signing_key} ->
          with {:ok, refreshed} <- cached_jwks(true) do
            find_key(refreshed, kid)
          end
      end
    end
  end

  defp cached_jwks(force_refresh?) do
    config = config()
    ttl = config[:jwks_cache_ttl_seconds] || 300

    case {force_refresh?, :persistent_term.get(@cache_key, :missing)} do
      {false, %{fetched_at: fetched_at, jwks: jwks}} ->
        case System.system_time(:second) - fetched_at < ttl do
          true -> {:ok, jwks}
          false -> fetch_jwks()
        end

      _other ->
        fetch_jwks()
    end
  end

  defp fetch_jwks do
    client = config()[:client] || Client

    with {:ok, %{"keys" => keys} = jwks} <- client.jwks(),
         true <- is_list(keys) do
      :persistent_term.put(@cache_key, %{
        fetched_at: System.system_time(:second),
        jwks: jwks
      })

      {:ok, jwks}
    else
      false -> {:error, :invalid_jwks}
      {:ok, _body} -> {:error, :invalid_jwks}
      {:error, _reason} = error -> error
    end
  end

  defp find_key(%{"keys" => keys}, kid) do
    case Enum.find(keys, &(&1["kid"] == kid)) do
      nil -> {:error, :unknown_signing_key}
      key -> {:ok, JOSE.JWK.from_map(key)}
    end
  end

  defp verify_signature(key, access_token) do
    case JOSE.JWT.verify_strict(key, @allowed_algorithms, access_token) do
      {true, %JOSE.JWT{fields: claims}, _jws} when is_map(claims) -> {:ok, claims}
      _other -> {:error, :invalid_access_token_signature}
    end
  end

  defp validate_claims(claims, opts) do
    config = config()
    now = Keyword.get(opts, :now, System.system_time(:second))

    with :ok <- validate_issuer(claims["iss"], expected_issuer(config)),
         :ok <- validate_equal(claims["client_id"], config[:client_id], :invalid_client),
         :ok <- validate_required_string(claims["sub"], :invalid_subject),
         :ok <- validate_required_string(claims["sid"], :invalid_session),
         :ok <- validate_expiry(claims["exp"], now, Keyword.get(opts, :allow_expired, false)),
         :ok <- validate_issued_at(claims["iat"], now),
         :ok <-
           validate_optional_equal(claims["sub"], Keyword.get(opts, :subject), :invalid_subject),
         :ok <-
           validate_optional_equal(
             claims["sid"],
             Keyword.get(opts, :session_id),
             :invalid_session
           ) do
      :ok
    end
  end

  defp validate_issuer(issuer, expected) when is_binary(issuer) and is_binary(expected) do
    case String.trim_trailing(issuer, "/") == String.trim_trailing(expected, "/") do
      true -> :ok
      false -> {:error, :invalid_issuer}
    end
  end

  defp validate_issuer(_issuer, _expected), do: {:error, :invalid_issuer}

  defp expected_issuer(config) do
    case config[:issuer] do
      issuer when is_binary(issuer) and issuer != "" ->
        issuer

      _missing ->
        default_issuer(config[:client_id])
    end
  end

  defp default_issuer(client_id) when is_binary(client_id) and client_id != "" do
    "#{@default_issuer_base_url}/user_management/#{client_id}"
  end

  defp default_issuer(_client_id), do: nil

  defp validate_expiry(expiration, now, true)
       when is_integer(expiration) and expiration > 0 and is_integer(now),
       do: :ok

  defp validate_expiry(expiration, now, false)
       when is_integer(expiration) and expiration > now,
       do: :ok

  defp validate_expiry(_expiration, _now, _allow_expired), do: {:error, :expired_access_token}

  defp validate_issued_at(issued_at, now)
       when is_integer(issued_at) and issued_at <= now + @clock_skew_seconds,
       do: :ok

  defp validate_issued_at(_issued_at, _now), do: {:error, :invalid_issued_at}

  defp validate_required_string(value, _reason) when is_binary(value) and value != "", do: :ok
  defp validate_required_string(_value, reason), do: {:error, reason}

  defp validate_equal(value, value, _reason) when not is_nil(value), do: :ok
  defp validate_equal(_actual, _expected, reason), do: {:error, reason}

  defp validate_optional_equal(_actual, nil, _reason), do: :ok
  defp validate_optional_equal(value, value, _reason), do: :ok
  defp validate_optional_equal(_actual, _expected, reason), do: {:error, reason}

  defp config do
    Application.get_env(:hermitscale, __MODULE__, [])
  end
end
