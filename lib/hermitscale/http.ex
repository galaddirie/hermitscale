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
    method = normalize_method!(method)

    case Keyword.get(opts, :credentials) do
      %Hermitscale.Integrations.CredentialRef{} = ref ->
        Hermitscale.Integrations.Request.request(
          method,
          url,
          ref,
          Keyword.put(Keyword.delete(opts, :credentials), :json, Keyword.get(opts, :body))
        )

      nil ->
        Req.request(
          [method: method, url: url, redirect: false, retry: false]
          |> maybe_put_body(Keyword.get(opts, :body))
        )

      _ ->
        {:error, :invalid_credentials}
    end
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
end
