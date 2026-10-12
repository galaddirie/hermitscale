defmodule Hermitscale.Integrations.Linear.Operations do
  @moduledoc "Linear actions corresponding to n8n's Issue and Comment operations."
  alias Hermitscale.Integrations.Linear.Client

  @issue_fields "id identifier title description url priority estimate createdAt updatedAt dueDate assignee { id name } team { id name } state { id name } project { id name } labels { nodes { id name } }"

  def provider_id, do: "linear"

  @doc "Trusted catalog declarations; fields maps use Linear's GraphQL input names."
  def definitions do
    %{
      issues_get: definition("issues.get", false, ["read"], issue_id: required(:string)),
      issues_create:
        definition("issues.create", true, ["issues:create"],
          team_id: required(:string),
          title: required(:string),
          description: [type: :string, default: ""],
          fields: fields()
        ),
      issues_update:
        definition("issues.update", true, ["write"],
          issue_id: required(:string),
          fields: [type: {:map, :string, :any}, required: true]
        ),
      issues_delete: definition("issues.delete", true, ["write"], issue_id: required(:string)),
      issues_list:
        definition("issues.list", false, ["read"],
          return_all: [type: :boolean, default: false],
          limit: [type: :pos_integer, default: 50],
          filter: fields(),
          include_archived: [type: :boolean, default: false]
        ),
      issues_add_link:
        definition("issues.add_link", true, ["write"],
          issue_id: required(:string),
          title: required(:string),
          url: required(:string)
        ),
      comments_create:
        definition("comments.create", true, ["comments:create"],
          issue_id: required(:string),
          body: required(:string)
        )
    }
  end

  @doc "Executes a trusted action using a non-secret credential reference."
  def execute(operation, params, credentials, opts \\ [])
  def execute(:issues_get, p, ref, opts), do: Client.get_issue(ref, p.issue_id, opts)

  def execute(:issues_create, p, ref, opts),
    do:
      Client.create_issue(
        ref,
        Map.merge(Map.get(p, :fields, %{}), %{
          "teamId" => p.team_id,
          "title" => p.title,
          "description" => p.description
        }),
        opts
      )

  def execute(:issues_update, p, ref, opts),
    do:
      mutation(
        ref,
        "issueUpdate",
        "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { #{@issue_fields} } } }",
        %{"id" => p.issue_id, "input" => p.fields},
        "issue",
        opts
      )

  def execute(:issues_delete, p, ref, opts),
    do:
      mutation(
        ref,
        "issueDelete",
        "mutation($id: String!) { issueDelete(id: $id) { success } }",
        %{"id" => p.issue_id},
        nil,
        opts
      )

  def execute(:comments_create, p, ref, opts),
    do:
      mutation(
        ref,
        "commentCreate",
        "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id body url createdAt updatedAt } } }",
        %{"input" => %{"issueId" => p.issue_id, "body" => p.body}},
        "comment",
        opts
      )

  def execute(:issues_add_link, p, ref, opts),
    do:
      mutation(
        ref,
        "attachmentCreate",
        "mutation($input: AttachmentCreateInput!) { attachmentCreate(input: $input) { success attachment { id title url } } }",
        %{"input" => %{"issueId" => p.issue_id, "title" => p.title, "url" => p.url}},
        "attachment",
        opts
      )

  def execute(:issues_list, p, ref, opts) do
    limit = if p.return_all, do: 10_000, else: min(p.limit, 10_000)
    list_page(ref, p, opts, nil, limit, [], MapSet.new())
  end

  @doc "Lists webhook definitions for lifecycle reconciliation."
  def webhooks(ref, opts \\ []) do
    webhook_page(ref, opts, nil, [], MapSet.new())
  end

  @doc "Creates a webhook with an explicit signing secret and deterministic UUID."
  def create_webhook(ref, input, opts \\ []),
    do:
      mutation(
        ref,
        "webhookCreate",
        "mutation($input: WebhookCreateInput!) { webhookCreate(input: $input) { success webhook { id url enabled } } }",
        %{"input" => input},
        "webhook",
        opts
      )

  @doc "Deletes an owned webhook."
  def delete_webhook(ref, id, opts \\ []),
    do:
      mutation(
        ref,
        "webhookDelete",
        "mutation($id: String!) { webhookDelete(id: $id) { success } }",
        %{"id" => id},
        nil,
        opts
      )

  defp mutation(ref, field, query, variables, resource, opts) do
    with {:ok, data} <- Client.graphql(ref, query, variables, Keyword.put(opts, :retry, false)) do
      case Map.fetch(data, field) do
        {:ok, %{"success" => true} = payload} -> mutation_result(payload, resource)
        {:ok, %{"success" => false}} -> {:error, :linear_mutation_failed}
        _ -> {:error, :invalid_linear_response}
      end
    end
  end

  defp mutation_result(_payload, nil), do: {:ok, %{"success" => true}}

  defp mutation_result(payload, resource) do
    case Map.fetch(payload, resource) do
      {:ok, %{"id" => id} = result} when is_binary(id) and id != "" -> {:ok, result}
      _ -> {:error, :invalid_linear_response}
    end
  end

  defp list_page(ref, p, opts, cursor, remaining, acc, seen) do
    query =
      "query($first: Int!, $after: String, $filter: IssueFilter, $includeArchived: Boolean!) { issues(first: $first, after: $after, filter: $filter, includeArchived: $includeArchived) { nodes { #{@issue_fields} } pageInfo { hasNextPage endCursor } } }"

    vars = %{
      "first" => min(100, remaining),
      "after" => cursor,
      "filter" => p.filter,
      "includeArchived" => p.include_archived
    }

    with :ok <- page_limit(seen),
         {:ok, data} <- Client.graphql(ref, query, vars, opts),
         %{"issues" => %{"nodes" => items, "pageInfo" => %{"hasNextPage" => next?} = page}}
         when is_list(items) and is_boolean(next?) <- data do
      taken = Enum.take(items, remaining)
      remaining = remaining - length(taken)
      acc = [taken | acc]
      next = Map.get(page, "endCursor")

      cond do
        next? and (not is_binary(next) or next == "" or items == [] or MapSet.member?(seen, next)) ->
          {:error, :invalid_pagination}

        next? and remaining == 0 and p.return_all ->
          {:error, :pagination_limit_exceeded}

        next? and remaining > 0 ->
          list_page(ref, p, opts, next, remaining, acc, MapSet.put(seen, next))

        true ->
          {:ok, acc |> Enum.reverse() |> List.flatten()}
      end
    else
      {:error, _reason} = error -> error
      _data -> {:error, :invalid_linear_response}
    end
  end

  defp page_limit(seen) do
    case MapSet.size(seen) < 100 do
      true -> :ok
      false -> {:error, :pagination_limit_exceeded}
    end
  end

  defp webhook_page(ref, opts, cursor, acc, seen) do
    query =
      "query($after: String) { webhooks(first: 100, after: $after) { nodes { id url enabled resourceTypes team { id } } pageInfo { hasNextPage endCursor } } }"

    with :ok <- page_limit(seen),
         {:ok, data} <- Client.graphql(ref, query, %{"after" => cursor}, opts),
         %{
           "webhooks" => %{
             "nodes" => items,
             "pageInfo" => %{"hasNextPage" => next?, "endCursor" => next}
           }
         }
         when is_list(items) and is_boolean(next?) <- data do
      cond do
        next? and (not is_binary(next) or next == "" or items == [] or MapSet.member?(seen, next)) ->
          {:error, :invalid_pagination}

        next? ->
          webhook_page(ref, opts, next, [items | acc], MapSet.put(seen, next))

        true ->
          {:ok, [items | acc] |> Enum.reverse() |> List.flatten()}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_linear_response}
    end
  end

  defp definition(suffix, effect?, scopes, params),
    do: %{id: "linear." <> suffix, effect?: effect?, scopes: scopes, params: params}

  defp required(type), do: [type: type, required: true]
  defp fields, do: [type: {:map, :string, :any}, default: %{}]
end
