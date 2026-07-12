defmodule Hermitscale.Credentials.TokenCacheTest do
  use ExUnit.Case, async: true

  alias Hermitscale.Credentials.{AccessToken, TokenCache}

  setup do
    table = :"token_cache_test_#{System.unique_integer([:positive])}"
    start_supervised!({TokenCache, name: table})
    %{table: table}
  end

  test "returns entries until their staleness deadline", %{table: table} do
    token = %AccessToken{access_token: "t"}
    future = DateTime.add(DateTime.utc_now(), 60, :second)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    assert :miss = TokenCache.get("cred_a", table)

    :ok = TokenCache.put("cred_a", token, future, table)
    assert {:ok, ^token} = TokenCache.get("cred_a", table)

    :ok = TokenCache.put("cred_a", token, past, table)
    assert :miss = TokenCache.get("cred_a", table)
  end

  test "invalidate drops the entry", %{table: table} do
    token = %AccessToken{access_token: "t"}
    future = DateTime.add(DateTime.utc_now(), 60, :second)

    :ok = TokenCache.put("cred_b", token, future, table)
    assert {:ok, ^token} = TokenCache.get("cred_b", table)

    :ok = TokenCache.invalidate("cred_b", table)
    assert :miss = TokenCache.get("cred_b", table)
  end
end
