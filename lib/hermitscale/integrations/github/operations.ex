defmodule Hermitscale.Integrations.GitHub.Operations do
  @moduledoc "GitHub's n8n-style action catalog, with fixed endpoint routing and bounded collections."
  alias Hermitscale.Integrations.GitHub.Client

  def provider_id, do: "github"

  @doc "Trusted action schemas and OAuth scopes. Mutation fields and list filters use GitHub JSON names."
  def definitions do
    repo = [owner: required(:string), repo: required(:string)]
    issue = repo ++ [issue_number: required(:pos_integer)]
    pull = repo ++ [pull_number: required(:pos_integer)]
    release = repo ++ [release_id: required(:pos_integer)]
    review = pull ++ [review_id: required(:pos_integer)]
    workflow = repo ++ [workflow_id: required(:string)]
    file = repo ++ [path: required(:string)]

    Map.new(
      [
        {:files_create, "files.create", true, repo_scopes(),
         file ++
           [
             message: required(:string),
             content: required(:string),
             encoding: [type: {:in, ~w(text base64)}, default: "text"],
             fields: fields()
           ]},
        {:files_edit, "files.edit", true, repo_scopes(),
         file ++
           [
             message: required(:string),
             content: required(:string),
             encoding: [type: {:in, ~w(text base64)}, default: "text"],
             fields: fields()
           ]},
        {:files_delete, "files.delete", true, repo_scopes(),
         file ++ [message: required(:string), fields: fields()]},
        {:files_get, "files.get", false, repo_scopes(), file ++ [ref: [type: :string]]},
        {:files_list, "files.list", false, repo_scopes(),
         repo ++ [path: [type: :string, default: ""], ref: [type: :string]]},
        {:issues_create, "issues.create", true, repo_scopes(),
         repo ++ [title: required(:string), body: [type: :string, default: ""], fields: fields()]},
        {:issues_get, "issues.get", false, repo_scopes(), issue},
        {:issues_edit, "issues.edit", true, repo_scopes(), issue ++ [fields: required(:map)]},
        {:issues_create_comment, "issues.create_comment", true, repo_scopes(),
         issue ++ [body: required(:string)]},
        {:issues_lock, "issues.lock", true, repo_scopes(),
         issue ++ [lock_reason: [type: {:in, ["off-topic", "too heated", "resolved", "spam"]}]]},
        {:organizations_get_repositories, "organizations.get_repositories", false, ["read:org"],
         [organization: required(:string)] ++ list_params()},
        {:organizations_get_members, "organizations.get_members", false, ["read:org"],
         [organization: required(:string)] ++ list_params()},
        {:pull_requests_close, "pull_requests.close", true, repo_scopes(), pull},
        {:pull_requests_reopen, "pull_requests.reopen", true, repo_scopes(), pull},
        {:pull_requests_create, "pull_requests.create", true, repo_scopes(),
         repo ++
           [
             title: required(:string),
             head: required(:string),
             base: required(:string),
             body: [type: :string, default: ""],
             fields: fields()
           ]},
        {:pull_requests_create_comment, "pull_requests.create_comment", true, repo_scopes(),
         pull ++ [body: required(:string)]},
        {:pull_requests_edit_comment, "pull_requests.edit_comment", true, repo_scopes(),
         repo ++ [comment_id: required(:pos_integer), body: required(:string)]},
        {:pull_requests_get, "pull_requests.get", false, repo_scopes(), pull},
        {:pull_requests_get_diff, "pull_requests.get_diff", false, repo_scopes(), pull},
        {:pull_requests_get_patch, "pull_requests.get_patch", false, repo_scopes(), pull},
        {:pull_requests_merge, "pull_requests.merge", true, repo_scopes(),
         pull ++
           [
             merge_method: [type: {:in, ~w(merge squash rebase)}, default: "merge"],
             fields: fields()
           ]},
        {:pull_requests_update, "pull_requests.update", true, repo_scopes(),
         pull ++ [fields: required(:map)]},
        {:releases_create, "releases.create", true, repo_scopes(),
         repo ++ [tag_name: required(:string), fields: fields()]},
        {:releases_delete, "releases.delete", true, repo_scopes(), release},
        {:releases_get, "releases.get", false, repo_scopes(), release},
        {:releases_list, "releases.list", false, repo_scopes(), repo ++ list_params()},
        {:releases_update, "releases.update", true, repo_scopes(),
         release ++ [fields: required(:map)]},
        {:repositories_get, "repositories.get", false, repo_scopes(), repo},
        {:repositories_get_issues, "repositories.get_issues", false, repo_scopes(),
         repo ++ list_params()},
        {:repositories_get_license, "repositories.get_license", false, repo_scopes(), repo},
        {:repositories_get_profile, "repositories.get_profile", false, repo_scopes(), repo},
        {:repositories_get_pull_requests, "repositories.get_pull_requests", false, repo_scopes(),
         repo ++ list_params()},
        {:repositories_list_popular_paths, "repositories.list_popular_paths", false,
         repo_scopes(), repo},
        {:repositories_list_referrers, "repositories.list_referrers", false, repo_scopes(), repo},
        {:reviews_create, "reviews.create", true, repo_scopes(),
         pull ++
           [
             event: [type: {:in, ~w(APPROVE REQUEST_CHANGES COMMENT)}, required: true],
             body: [type: :string, default: ""],
             fields: fields()
           ]},
        {:reviews_get, "reviews.get", false, repo_scopes(), review},
        {:reviews_list, "reviews.list", false, repo_scopes(), pull ++ list_params()},
        {:reviews_update, "reviews.update", true, repo_scopes(),
         review ++ [body: required(:string)]},
        {:users_get_repositories, "users.get_repositories", false, repo_scopes(),
         [username: required(:string)] ++ list_params()},
        {:users_get_issues, "users.get_issues", false, repo_scopes(), list_params()},
        {:users_invite, "users.invite", true, ["admin:org"],
         [organization: required(:string), email: required(:string), fields: fields()]},
        {:workflows_disable, "workflows.disable", true, repo_scopes(), workflow},
        {:workflows_dispatch, "workflows.dispatch", true, repo_scopes(),
         workflow ++ [ref: required(:string), inputs: fields()]},
        {:workflows_enable, "workflows.enable", true, repo_scopes(), workflow},
        {:workflows_get, "workflows.get", false, repo_scopes(), workflow},
        {:workflows_get_usage, "workflows.get_usage", false, repo_scopes(), workflow},
        {:workflows_list, "workflows.list", false, repo_scopes(), repo ++ list_params()}
      ],
      fn {operation, suffix, effect?, scopes, params} ->
        {operation, %{id: "github." <> suffix, effect?: effect?, scopes: scopes, params: params}}
      end
    )
  end

  @doc "Executes an action; paths and HTTP methods are defined in deployed code."
  def execute(operation, params, credentials, opts \\ [])

  def execute(operation, p, ref, opts)
      when operation in [:files_create, :files_edit, :files_delete] do
    with :ok <- valid_file_path(p.path),
         {:ok, body} <- file_body(operation, p, ref, opts) do
      method = if operation == :files_delete, do: :delete, else: :put
      Client.api(ref, method, contents(p), Keyword.merge(opts, json: body, retry: false))
    end
  end

  def execute(operation, p, ref, opts) when operation in [:files_get, :files_list] do
    with :ok <- valid_file_path(p.path),
         {:ok, result} <-
           Client.api(
             ref,
             :get,
             contents(p),
             Keyword.put(opts, :params, optional(%{}, "ref", Map.get(p, :ref)))
           ) do
      case {operation, result} do
        {:files_list, result} when is_list(result) -> {:ok, result}
        {:files_list, _result} -> {:error, :expected_directory}
        {:files_get, result} -> {:ok, result}
      end
    end
  end

  def execute(operation, p, ref, opts) do
    definition = Map.fetch!(definitions(), operation)
    {method, path, extra} = route(operation, p)

    opts =
      opts
      |> Keyword.merge(extra)
      |> Keyword.put(:retry, if(definition.effect?, do: false, else: :safe_transient))

    case Keyword.pop(opts, :collection_endpoint, false) do
      {true, opts} -> Client.list(ref, path, p, opts)
      {false, opts} -> Client.api(ref, method, path, opts)
    end
  end

  defp route(:issues_create, p),
    do: {:post, repo(p) <> "/issues", [json: body(p, %{"title" => p.title, "body" => p.body})]}

  defp route(:issues_get, p), do: {:get, issue(p), []}
  defp route(:issues_edit, p), do: {:patch, issue(p), [json: p.fields]}

  defp route(:issues_create_comment, p),
    do: {:post, issue(p) <> "/comments", [json: %{"body" => p.body}]}

  defp route(:issues_lock, p),
    do:
      {:put, issue(p) <> "/lock", [json: optional(%{}, "lock_reason", Map.get(p, :lock_reason))]}

  defp route(:organizations_get_repositories, p),
    do: {:get, "/orgs/#{segment(p.organization)}/repos", [collection_endpoint: true]}

  defp route(:organizations_get_members, p),
    do: {:get, "/orgs/#{segment(p.organization)}/members", [collection_endpoint: true]}

  defp route(:pull_requests_close, p), do: {:patch, pull(p), [json: %{"state" => "closed"}]}
  defp route(:pull_requests_reopen, p), do: {:patch, pull(p), [json: %{"state" => "open"}]}

  defp route(:pull_requests_create, p),
    do:
      {:post, repo(p) <> "/pulls",
       [
         json:
           body(p, %{"title" => p.title, "head" => p.head, "base" => p.base, "body" => p.body})
       ]}

  defp route(:pull_requests_create_comment, p),
    do:
      {:post, repo(p) <> "/issues/#{segment(p.pull_number)}/comments",
       [json: %{"body" => p.body}]}

  defp route(:pull_requests_edit_comment, p),
    do:
      {:patch, repo(p) <> "/issues/comments/#{segment(p.comment_id)}",
       [json: %{"body" => p.body}]}

  defp route(:pull_requests_get, p), do: {:get, pull(p), []}
  defp route(:pull_requests_get_diff, p), do: {:get, pull(p), [format: :diff]}
  defp route(:pull_requests_get_patch, p), do: {:get, pull(p), [format: :patch]}

  defp route(:pull_requests_merge, p),
    do: {:put, pull(p) <> "/merge", [json: body(p, %{"merge_method" => p.merge_method})]}

  defp route(:pull_requests_update, p), do: {:patch, pull(p), [json: p.fields]}

  defp route(:releases_create, p),
    do: {:post, repo(p) <> "/releases", [json: body(p, %{"tag_name" => p.tag_name})]}

  defp route(:releases_delete, p), do: {:delete, release(p), []}
  defp route(:releases_get, p), do: {:get, release(p), []}
  defp route(:releases_list, p), do: {:get, repo(p) <> "/releases", [collection_endpoint: true]}
  defp route(:releases_update, p), do: {:patch, release(p), [json: p.fields]}
  defp route(:repositories_get, p), do: {:get, repo(p), []}

  defp route(:repositories_get_issues, p),
    do: {:get, repo(p) <> "/issues", [collection_endpoint: true]}

  defp route(:repositories_get_license, p), do: {:get, repo(p) <> "/license", []}
  defp route(:repositories_get_profile, p), do: {:get, repo(p) <> "/community/profile", []}

  defp route(:repositories_get_pull_requests, p),
    do: {:get, repo(p) <> "/pulls", [collection_endpoint: true]}

  defp route(:repositories_list_popular_paths, p),
    do: {:get, repo(p) <> "/traffic/popular/paths", []}

  defp route(:repositories_list_referrers, p),
    do: {:get, repo(p) <> "/traffic/popular/referrers", []}

  defp route(:reviews_create, p),
    do: {:post, pull(p) <> "/reviews", [json: body(p, %{"event" => p.event, "body" => p.body})]}

  defp route(:reviews_get, p), do: {:get, review(p), []}
  defp route(:reviews_list, p), do: {:get, pull(p) <> "/reviews", [collection_endpoint: true]}
  defp route(:reviews_update, p), do: {:put, review(p), [json: %{"body" => p.body}]}

  defp route(:users_get_repositories, p),
    do: {:get, "/users/#{segment(p.username)}/repos", [collection_endpoint: true]}

  defp route(:users_get_issues, _p), do: {:get, "/issues", [collection_endpoint: true]}

  defp route(:users_invite, p),
    do:
      {:post, "/orgs/#{segment(p.organization)}/invitations",
       [json: body(p, %{"email" => p.email})]}

  defp route(:workflows_disable, p), do: {:put, workflow(p) <> "/disable", []}
  defp route(:workflows_enable, p), do: {:put, workflow(p) <> "/enable", []}

  defp route(:workflows_dispatch, p),
    do: {:post, workflow(p) <> "/dispatches", [json: %{"ref" => p.ref, "inputs" => p.inputs}]}

  defp route(:workflows_get, p), do: {:get, workflow(p), []}
  defp route(:workflows_get_usage, p), do: {:get, workflow(p) <> "/timing", []}

  defp route(:workflows_list, p),
    do:
      {:get, repo(p) <> "/actions/workflows",
       [collection_endpoint: true, collection: "workflows"]}

  defp file_body(operation, p, ref, opts) do
    fields = Map.get(p, :fields, %{})

    with {:ok, content} <- file_content(operation, p),
         {:ok, sha} <- file_sha(operation, p, fields, ref, opts) do
      {:ok,
       fields
       |> Map.merge(%{"message" => p.message})
       |> optional("content", content)
       |> optional("sha", sha)}
    end
  end

  defp file_content(:files_delete, _p), do: {:ok, nil}

  defp file_content(_operation, %{encoding: "text", content: content}),
    do: {:ok, Base.encode64(content)}

  defp file_content(_operation, %{encoding: "base64", content: content}) do
    case Base.decode64(content) do
      {:ok, _bytes} -> {:ok, content}
      :error -> {:error, :invalid_base64}
    end
  end

  defp file_sha(:files_create, _p, _fields, _ref, _opts), do: {:ok, nil}

  defp file_sha(_operation, _p, %{"sha" => sha}, _ref, _opts) when is_binary(sha) and sha != "",
    do: {:ok, sha}

  defp file_sha(_operation, p, fields, ref, opts) do
    with {:ok, body} <-
           Client.api(
             ref,
             :get,
             contents(p),
             Keyword.put(opts, :params, optional(%{}, "ref", fields["branch"]))
           ) do
      case body do
        %{"sha" => sha} when is_binary(sha) and sha != "" -> {:ok, sha}
        _ -> {:error, :invalid_github_response}
      end
    end
  end

  defp valid_file_path(path) do
    case Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])) or
           String.starts_with?(path, "/") do
      true -> {:error, :invalid_file_path}
      false -> :ok
    end
  end

  defp contents(%{path: ""} = p), do: repo(p) <> "/contents"

  defp contents(p),
    do: repo(p) <> "/contents/" <> (p.path |> String.split("/") |> Enum.map_join("/", &segment/1))

  defp repo(p), do: "/repos/#{segment(p.owner)}/#{segment(p.repo)}"
  defp issue(p), do: repo(p) <> "/issues/#{segment(p.issue_number)}"
  defp pull(p), do: repo(p) <> "/pulls/#{segment(p.pull_number)}"
  defp release(p), do: repo(p) <> "/releases/#{segment(p.release_id)}"
  defp review(p), do: pull(p) <> "/reviews/#{segment(p.review_id)}"
  defp workflow(p), do: repo(p) <> "/actions/workflows/#{segment(p.workflow_id)}"
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
  defp body(p, required), do: Map.merge(Map.get(p, :fields, %{}), required)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp required(:map), do: [type: {:map, :string, :any}, required: true]
  defp required(type), do: [type: type, required: true]
  defp fields, do: [type: {:map, :string, :any}, default: %{}]
  defp repo_scopes, do: ["repo"]

  defp list_params,
    do: [
      return_all: [type: :boolean, default: false],
      limit: [type: :pos_integer, default: 50],
      filters: fields()
    ]
end
