defmodule Hermitscale.HTTP do
  @moduledoc """
  Small application wrapper around `Req` for workflow HTTP nodes.
  """

  @allowed_methods %{
    "DELETE" => :delete,
    "GET" => :get,
    "PATCH" => :patch,
    "POST" => :post,
    "PUT" => :put
  }

  @doc """
  Executes an HTTP request with a normalized method and optional runtime auth.
  """
  def request(method, url, opts \\ []) do
    req_opts =
      [
        method: normalize_method!(method),
        url: url
      ]
      |> maybe_put_body(Keyword.get(opts, :body))
      |> maybe_put_auth(Keyword.get(opts, :auth))

    Req.request(req_opts)
  end

  defp normalize_method!(method) when is_binary(method) do
    Map.fetch!(@allowed_methods, String.upcase(method))
  end

  defp normalize_method!(method) when is_atom(method) do
    method
    |> Atom.to_string()
    |> normalize_method!()
  end

  defp maybe_put_body(opts, nil), do: opts
  defp maybe_put_body(opts, body), do: Keyword.put(opts, :json, body)

  defp maybe_put_auth(opts, nil), do: opts
  defp maybe_put_auth(opts, {:bearer, token}), do: Keyword.put(opts, :auth, {:bearer, token})
  defp maybe_put_auth(opts, {:basic, userinfo}), do: Keyword.put(opts, :auth, {:basic, userinfo})

  defp maybe_put_auth(opts, auth) when is_binary(auth),
    do: Keyword.put(opts, :auth, {:bearer, auth})
end
