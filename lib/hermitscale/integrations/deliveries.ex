defmodule Hermitscale.Integrations.Deliveries do
  @moduledoc """
  Retained GitHub PR and Linear comment delivery with provider reconciliation.

  A dispatch becomes uncertain before sending. A lost response is reconciled by
  the stable marker and target, and never causes a second blind mutation. Reads
  and mutations vend credentials afresh and run outside the ledger transaction.
  """
  import Ecto.Query
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.{Authorization, Repo}
  alias Hermitscale.Integrations.{ConnectedAccounts, Delivery}
  alias Hermitscale.Integrations.GitHub.Client, as: GitHub
  alias Hermitscale.Integrations.Linear.Client, as: Linear

  @doc "Delivers or reconciles one mutation identified by its immutable effect key."
  def deliver(%Scope{} = scope, attrs) when is_map(attrs) do
    attrs = jsonable(attrs)

    with {:ok, permission} <- delivery_permission(scope),
         {:ok, kind, provider} <- validate_kind(attrs),
         :ok <- validate_params(kind, attrs["params"]),
         {:ok, credentials} <-
           ConnectedAccounts.credential_ref(
             Scope.execution_context(scope, [permission]),
             attrs["connection"],
             scopes(kind)
           ),
         {:ok, delivery} <- admit(scope, attrs, provider),
         {:ok, mode, delivery} <- claim(delivery) do
      case mode do
        :settled ->
          {:ok, delivery.result}

        mode when mode in [:dispatch, :reconcile] ->
          resolve(delivery, kind, credentials, attrs, mode)
      end
    end
  end

  @doc "Inspects a delivery through organization and actor authorization."
  def get(%Scope{} = scope, id) do
    with {:ok, _permission} <- delivery_permission(scope) do
      org_id = Scope.organization_id!(scope)

      case Repo.get_by(Delivery, id: id, org_id: org_id, actor_user_id: scope.user.id) do
        nil -> {:error, :not_found}
        delivery -> {:ok, delivery}
      end
    end
  end

  defp admit(scope, attrs, provider) do
    payload_digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(attrs, [:deterministic]))
      |> Base.encode16(case: :lower)

    org_id = Scope.organization_id!(scope)
    effect_key = attrs["effect_key"]

    Repo.transaction(fn ->
      candidate =
        %Delivery{org_id: org_id, actor_user_id: scope.user.id}
        |> Delivery.changeset(%{
          effect_key: effect_key,
          provider: provider,
          payload_digest: payload_digest
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:org_id, :effect_key])
        |> unwrap!()

      record = Repo.get_by!(Delivery, org_id: org_id, effect_key: candidate.effect_key)

      case record do
        %Delivery{payload_digest: ^payload_digest, actor_user_id: actor}
        when actor == scope.user.id ->
          record

        %Delivery{} ->
          Repo.rollback(:effect_key_conflict)
      end
    end)
  end

  defp claim(delivery) do
    Repo.transaction(fn ->
      current = lock!(delivery.id)

      case current.status do
        :succeeded ->
          {:settled, current}

        :uncertain ->
          {:reconcile, current}

        :pending ->
          record =
            current |> Delivery.changeset(%{status: :uncertain}) |> Repo.update() |> unwrap!()

          {:dispatch, record}
      end
    end)
    |> case do
      {:ok, {mode, record}} -> {:ok, mode, record}
      {:error, _reason} = error -> error
    end
  end

  defp resolve(delivery, kind, credentials, attrs, mode) do
    marker = "<!-- hermitscale-delivery:#{delivery.id} -->"

    case find_existing(kind, credentials, attrs["params"], marker) do
      {:ok, :absent} when mode == :dispatch ->
        case create_verified(kind, credentials, attrs, marker) do
          {:ok, result} -> settle(delivery, result)
          {:error, _reason} -> {:error, :delivery_uncertain}
        end

      {:ok, :absent} ->
        {:error, :delivery_uncertain}

      {:ok, result} when is_map(result) ->
        with :ok <- verify_recovered(kind, credentials, attrs, result),
             do: settle(delivery, result)

      {:error, _reason} = error ->
        if mode == :dispatch, do: reset_undispatched(delivery)
        error
    end
  end

  defp create_verified(
         "github.pull_requests.create" = kind,
         credentials,
         %{"publication" => publication} = attrs,
         marker
       )
       when is_map(publication) do
    params = attrs["params"]

    with :ok <- verify_branch(credentials, params, publication),
         {:ok, result} <- create(kind, credentials, params, marker),
         true <- get_in(result, ["head", "sha"]) == publication["commit_sha"] do
      {:ok, result}
    else
      false -> {:error, :published_branch_changed}
      {:error, _reason} = error -> error
    end
  end

  defp create_verified(kind, credentials, attrs, marker),
    do: create(kind, credentials, attrs["params"], marker)

  defp verify_recovered(
         "github.pull_requests.create",
         credentials,
         %{"publication" => publication} = attrs,
         result
       )
       when is_map(publication) do
    with true <- get_in(result, ["head", "sha"]) == publication["commit_sha"],
         :ok <- verify_branch(credentials, attrs["params"], publication) do
      :ok
    else
      false -> {:error, :published_branch_changed}
      {:error, _reason} = error -> error
    end
  end

  defp verify_recovered(_kind, _credentials, _attrs, _result), do: :ok

  defp verify_branch(credentials, params, publication) do
    case publication do
      %{"repository" => repository, "branch" => branch, "commit_sha" => sha}
      when is_binary(repository) and is_binary(branch) and is_binary(sha) ->
        with true <-
               repository == params["owner"] <> "/" <> params["repo"] and branch == params["head"],
             {:ok, ref} <-
               GitHub.api(
                 credentials,
                 :get,
                 repo_path(params) <> "/git/ref/heads/" <> segment(branch)
               ),
             true <- get_in(ref, ["object", "sha"]) == sha do
          :ok
        else
          false -> {:error, :published_branch_changed}
          {:error, _reason} = error -> error
        end

      _unverified ->
        {:error, :invalid_publication_evidence}
    end
  end

  @doc "Reads the ledger for an actor's stable effect key."
  def get_by_key(%Scope{} = scope, effect_key) do
    with {:ok, _permission} <- delivery_permission(scope) do
      case Repo.get_by(Delivery,
             org_id: Scope.organization_id!(scope),
             actor_user_id: scope.user.id,
             effect_key: effect_key
           ) do
        nil -> {:error, :not_found}
        delivery -> {:ok, delivery}
      end
    end
  end

  defp find_existing("github.pull_requests.create", credentials, params, marker) do
    query = %{
      "state" => "all",
      "head" => params["owner"] <> ":" <> params["head"],
      "base" => params["base"],
      "per_page" => 100
    }

    with {:ok, pulls} <-
           GitHub.api(credentials, :get, repo_path(params) <> "/pulls", params: query) do
      case pulls do
        pulls when is_list(pulls) ->
          matches =
            Enum.filter(pulls, fn pull ->
              is_binary(pull["body"]) and String.contains?(pull["body"], marker)
            end)

          case matches do
            [pull] -> {:ok, pull}
            [] -> {:ok, :absent}
            [_first | _others] -> {:error, :delivery_reconciliation_conflict}
          end

        _response ->
          {:error, :invalid_github_response}
      end
    end
  end

  defp find_existing("linear.comments.create", credentials, params, marker) do
    query =
      "query HermitscaleDeliveryComments($id: String!) { issue(id: $id) { comments(first: 100) { nodes { id body url createdAt updatedAt } pageInfo { hasNextPage } } } }"

    with {:ok, data} <- Linear.graphql(credentials, query, %{"id" => params["issue_id"]}) do
      case data do
        %{
          "issue" => %{
            "comments" => %{"nodes" => comments, "pageInfo" => %{"hasNextPage" => false}}
          }
        }
        when is_list(comments) ->
          case Enum.filter(comments, fn comment ->
                 is_binary(comment["body"]) and String.contains?(comment["body"], marker)
               end) do
            [comment] -> {:ok, comment}
            [] -> {:ok, :absent}
            [_first | _others] -> {:error, :delivery_reconciliation_conflict}
          end

        %{"issue" => %{"comments" => %{"pageInfo" => %{"hasNextPage" => true}}}} ->
          {:error, :delivery_reconciliation_limit}

        _response ->
          {:error, :invalid_linear_response}
      end
    end
  end

  defp create("github.pull_requests.create", credentials, params, marker) do
    body = Map.get(params, "body", "") <> "\n\n" <> marker

    payload =
      Map.merge(Map.get(params, "fields", %{}), Map.take(params, ["title", "head", "base"]))
      |> Map.put("body", body)

    with {:ok, result} <-
           GitHub.api(credentials, :post, repo_path(params) <> "/pulls",
             json: payload,
             retry: false
           ),
         :ok <- validate_result("github.pull_requests.create", result) do
      {:ok, result}
    end
  end

  defp create("linear.comments.create", credentials, params, marker) do
    with {:ok, result} <-
           Hermitscale.Integrations.Linear.Operations.execute(
             :comments_create,
             %{issue_id: params["issue_id"], body: params["body"] <> "\n\n" <> marker},
             credentials,
             retry: false
           ),
         :ok <- validate_result("linear.comments.create", result) do
      {:ok, result}
    end
  end

  defp settle(delivery, result) when is_map(result) do
    Repo.transaction(fn ->
      current = lock!(delivery.id)

      case current.status do
        :succeeded ->
          current.result

        :uncertain ->
          current
          |> Delivery.changeset(%{status: :succeeded, result: result})
          |> Repo.update()
          |> unwrap!()
          |> Map.fetch!(:result)
      end
    end)
  end

  defp validate_kind(%{"kind" => "github.pull_requests.create", "provider" => "github"}),
    do: {:ok, "github.pull_requests.create", "github"}

  defp validate_kind(%{"kind" => "linear.comments.create", "provider" => "linear"}),
    do: {:ok, "linear.comments.create", "linear"}

  defp validate_kind(_attrs), do: {:error, :unsupported_delivery}

  defp delivery_permission(scope) do
    case Enum.find(
           ["workflows:run", "support:reply"],
           &(Authorization.authorize(scope, &1) == :ok)
         ) do
      nil -> {:error, :forbidden}
      permission -> {:ok, permission}
    end
  end

  defp validate_params("github.pull_requests.create", %{
         "owner" => owner,
         "repo" => repo,
         "head" => head,
         "base" => base,
         "title" => title
       })
       when is_binary(owner) and owner != "" and is_binary(repo) and repo != "" and
              is_binary(head) and head != "" and is_binary(base) and base != "" and
              is_binary(title) and title != "",
       do: :ok

  defp validate_params("linear.comments.create", %{"issue_id" => id, "body" => body})
       when is_binary(id) and id != "" and is_binary(body) and byte_size(body) in 1..32000,
       do: :ok

  defp validate_params(_kind, _params), do: {:error, :invalid_delivery_params}

  defp validate_result("github.pull_requests.create", %{
         "id" => id,
         "number" => number,
         "html_url" => url
       })
       when is_integer(id) and id > 0 and is_integer(number) and number > 0 and is_binary(url),
       do: :ok

  defp validate_result("linear.comments.create", %{"id" => id}) when is_binary(id) and id != "",
    do: :ok

  defp validate_result(_kind, _result), do: {:error, :invalid_delivery_response}

  defp reset_undispatched(delivery) do
    delivery |> Delivery.changeset(%{status: :pending}) |> Repo.update!()
  end

  defp scopes("github.pull_requests.create"), do: ["repo"]
  defp scopes("linear.comments.create"), do: ["comments:create", "read"]
  defp repo_path(params), do: "/repos/#{segment(params["owner"])}/#{segment(params["repo"])}"
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp lock!(id),
    do: Delivery |> where([delivery], delivery.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp jsonable(value), do: value |> Jason.encode!() |> Jason.decode!()
end
