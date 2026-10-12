defmodule Hermitscale.Integrations.Linear.Client do
  @moduledoc "Linear issue operations with GraphQL variables and explicit partial-error handling."
  alias Hermitscale.Integrations.Request
  @url "https://api.linear.app/graphql"
  @fields "id identifier title description url priority estimate createdAt updatedAt dueDate assignee { id name } team { id name } state { id name } project { id name } labels { nodes { id name } }"
  @get_issue "query HermitscaleIssue($id: String!) { issue(id: $id) { #{@fields} } }"
  @create_issue "mutation HermitscaleIssueCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { #{@fields} } } }"

  @doc "Reads an issue by UUID or identifier such as ENG-7."
  def get_issue(credentials, id, opts \\ []) do
    with {:ok, data} <- graphql(credentials, @get_issue, %{"id" => id}, opts) do
      case data do
        %{"issue" => nil} -> {:error, :issue_not_found}
        %{"issue" => issue} -> validate_issue(issue)
        _data -> {:error, :invalid_linear_response}
      end
    end
  end

  @doc "Creates an issue from a string-keyed IssueCreateInput map."
  def create_issue(credentials, input, opts \\ []) when is_map(input) do
    with {:ok, data} <- graphql(credentials, @create_issue, %{"input" => input}, opts) do
      case data do
        %{"issueCreate" => %{"success" => true, "issue" => issue}} -> validate_issue(issue)
        %{"issueCreate" => %{"success" => false}} -> {:error, :linear_mutation_failed}
        _data -> {:error, :invalid_linear_response}
      end
    end
  end

  @doc "Runs a provider-authenticated GraphQL operation, rejecting partial errors."
  def graphql(credentials, query, variables, opts \\ []) do
    opts =
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(opts)
      |> Keyword.put(:json, %{query: query, variables: variables})

    with {:ok, body} <- Request.json(:post, @url, credentials, opts) do
      case body do
        %{"errors" => [_error | _rest]} ->
          {:error, :linear_graphql_error}

        %{"data" => data} = response when is_map(data) ->
          case Map.get(response, "errors", []) do
            [] -> {:ok, data}
            _errors -> {:error, :invalid_linear_response}
          end

        _body ->
          {:error, :invalid_linear_response}
      end
    end
  end

  defp validate_issue(%{"id" => id, "identifier" => identifier, "title" => title} = issue)
       when is_binary(id) and id != "" and is_binary(identifier) and is_binary(title),
       do: {:ok, issue}

  defp validate_issue(_issue), do: {:error, :invalid_linear_response}
end
