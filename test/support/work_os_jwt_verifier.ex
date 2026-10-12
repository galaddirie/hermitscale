defmodule Hermitscale.WorkOSTest.JWTVerifier do
  @moduledoc false

  def verify(token, opts \\ []) when is_binary(token) do
    with {:ok, claims} when is_map(claims) <- Jason.decode(token),
         :ok <- validate_equal(claims["sub"], Keyword.get(opts, :subject)),
         :ok <- validate_equal(claims["sid"], Keyword.get(opts, :session_id)),
         :ok <- validate_expiry(claims["exp"], Keyword.get(opts, :allow_expired, false)) do
      {:ok, claims}
    else
      _reason -> {:error, :invalid_access_token}
    end
  end

  defp validate_equal(_actual, nil), do: :ok
  defp validate_equal(value, value), do: :ok
  defp validate_equal(_actual, _expected), do: {:error, :claim_mismatch}

  defp validate_expiry(expiration, true) when is_integer(expiration), do: :ok

  defp validate_expiry(expiration, false) when is_integer(expiration) do
    if expiration > System.system_time(:second),
      do: :ok,
      else: {:error, :expired}
  end

  defp validate_expiry(_expiration, _allow_expired), do: {:error, :expired}
end
