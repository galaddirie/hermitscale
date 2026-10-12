defmodule Hermitscale.Integrations.GitHub.Client do
  @moduledoc "GitHub REST operations using freshly vended organization credentials."
  alias Hermitscale.Integrations.Request
  @base_url "https://api.github.com"
  @headers [
    {"accept", "application/vnd.github+json"},
    {"x-github-api-version", "2026-03-10"},
    {"user-agent", "Hermitscale"}
  ]

  @doc "Reads a repository issue by number."
  def get_issue(credentials, owner, repo, number, opts \\ []) do
    request(:get, credentials, issue_path(owner, repo) <> "/#{segment(to_string(number))}", opts)
  end

  @doc "Creates a repository issue. Attributes use GitHub's string-keyed JSON fields."
  def create_issue(credentials, owner, repo, attrs, opts \\ []) when is_map(attrs) do
    request(:post, credentials, issue_path(owner, repo), Keyword.put(opts, :json, attrs))
  end

  @doc "Calls a GitHub API path, returning only validated JSON data or an explicitly requested text format."
  def api(credentials, method, path, opts \\ []) do
    with {:ok, response} <- response(credentials, method, path, opts) do
      normalize(response, Keyword.get(opts, :format, :json))
    end
  end

  @doc "Collects a bounded paginated endpoint without following provider-supplied URLs."
  def list(credentials, path, params, opts \\ []) do
    limit = if params.return_all, do: 10_000, else: min(params.limit, 10_000)

    list_page(
      credentials,
      path,
      params.filters,
      opts,
      1,
      limit,
      [],
      params.return_all,
      min(100, limit)
    )
  end

  defp list_page(_credentials, _path, _filters, _opts, page, _remaining, _acc, _all, _page_size)
       when page > 100,
       do: {:error, :pagination_limit_exceeded}

  defp list_page(credentials, path, filters, opts, page, remaining, acc, all, page_size) do
    query = Map.merge(filters, %{"page" => page, "per_page" => page_size})

    with {:ok, response} <- response(credentials, :get, path, Keyword.put(opts, :params, query)),
         {:ok, items} <- collection(response.body, Keyword.get(opts, :collection)) do
      next? =
        response.headers
        |> Map.get("link", [])
        |> Enum.any?(&String.contains?(&1, "rel=\"next\""))

      taken = Enum.take(items, remaining)
      remaining = remaining - length(taken)
      acc = [taken | acc]

      cond do
        next? and items == [] ->
          {:error, :invalid_pagination}

        next? and remaining == 0 and all ->
          {:error, :pagination_limit_exceeded}

        next? and remaining > 0 ->
          list_page(credentials, path, filters, opts, page + 1, remaining, acc, all, page_size)

        true ->
          {:ok, acc |> Enum.reverse() |> List.flatten()}
      end
    end
  end

  defp collection(body, nil) when is_list(body) do
    case Enum.all?(body, &is_map/1) do
      true -> {:ok, body}
      false -> {:error, :invalid_github_response}
    end
  end

  defp collection(body, key) when is_map(body) and is_binary(key) do
    case Map.fetch(body, key) do
      {:ok, items} when is_list(items) -> collection(items, nil)
      _ -> {:error, :invalid_github_response}
    end
  end

  defp collection(_body, _key), do: {:error, :invalid_github_response}

  defp response(credentials, method, path, opts) do
    defaults = Application.get_env(:hermitscale, __MODULE__, []) |> Keyword.get(:req_options, [])

    headers =
      case Keyword.get(opts, :format, :json) do
        :json ->
          @headers

        format when format in [:diff, :patch] ->
          List.keyreplace(@headers, "accept", 0, {"accept", "application/vnd.github.#{format}"})
      end

    opts = defaults |> Keyword.merge(opts) |> Keyword.put(:headers, headers)

    case Request.request(method, @base_url <> path, credentials, opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:provider_request_failed, status}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(%Req.Response{status: 204}, _format), do: {:ok, %{"success" => true}}

  defp normalize(%Req.Response{body: body}, :json) when is_map(body) or is_list(body),
    do: {:ok, body}

  defp normalize(%Req.Response{body: body}, format)
       when format in [:diff, :patch] and is_binary(body),
       do: {:ok, %{Atom.to_string(format) => body}}

  defp normalize(_response, _format), do: {:error, :invalid_github_response}

  defp request(method, credentials, path, opts) do
    opts =
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(opts)
      |> Keyword.put(:headers, @headers)

    with {:ok, body} <- Request.json(method, @base_url <> path, credentials, opts) do
      case body do
        %{"id" => id, "number" => number, "title" => title}
        when is_integer(id) and is_integer(number) and is_binary(title) ->
          {:ok, body}

        _body ->
          {:error, :invalid_github_response}
      end
    end
  end

  defp issue_path(owner, repo), do: "/repos/#{segment(owner)}/#{segment(repo)}/issues"
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
