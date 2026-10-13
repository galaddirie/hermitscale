defmodule Hermitscale.Integrations.ExecutionAccess do
  @moduledoc "Expiring remote capabilities, current actor validation and fixed inference upstream."
  import Ecto.Query
  alias Hermitscale.{Authorization, Repo}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Integrations.{Capability, ConnectedAccounts}

  @product_actions ~w(workflows.list workflows.inspect workflows.validate workflows.create runs.start runs.status agents.inspect agents.continue agents.cancel agents.publish reviews.request reviews.decide apps.inspect apps.create apps.build apps.preview apps.logs apps.verify_defect deployments.request deployments.inspect support.subscribe support.investigate support.inspect support.reply)

  def issue(scope, attrs) do
    with :ok <- authorize_issuance(scope, attrs) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      ttl = Map.get(attrs, :ttl_seconds, 3600)

      if is_integer(ttl) and ttl in 1..7200 do
        %Capability{
          org_id: Scope.organization_id!(scope),
          actor_user_id: scope.user.id,
          token_digest: digest(token),
          expires_at: DateTime.add(DateTime.utc_now(:second), ttl),
          initial_cost_micros: Map.get(attrs, :remaining_cost_micros, 0)
        }
        |> Capability.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, record} -> {:ok, %{record: record, token: token}}
          {:error, _} = error -> error
        end
      else
        {:error, :invalid_capability_expiry}
      end
    end
  end

  def issue_product(scope, resources, actions, opts \\ []) do
    with true <- is_list(resources) and Enum.all?(resources, &is_binary/1),
         true <- is_list(actions) and Enum.all?(actions, &(&1 in @product_actions)) do
      issue(scope, %{
        kind: "product",
        resource_ids: resources,
        actions: actions,
        remaining_calls: Keyword.get(opts, :max_calls, 50),
        remaining_cost_micros: 0,
        ttl_seconds: Keyword.get(opts, :ttl_seconds, 3600)
      })
    else
      false -> {:error, :invalid_product_capability}
    end
  end

  def authenticate(token, kind, action, resource_id \\ nil)

  def authenticate(token, kind, action, resource_id) when is_binary(token) do
    case Repo.get_by(Capability, token_digest: digest(token), kind: kind) do
      nil ->
        {:error, :invalid_capability}

      cap ->
        with :ok <- validate(cap, action, resource_id),
             {:ok, scope} <-
               Authorization.execution_scope(%Hermitscale.Integrations.ExecutionContext{
                 organization_id: cap.org_id,
                 actor_user_id: cap.actor_user_id,
                 required_permissions: []
               }) do
          {:ok, scope, cap}
        end
    end
  end

  def authenticate(_token, _kind, _action, _resource_id), do: {:error, :invalid_capability}

  def consume(cap, cost_micros \\ 0)

  def consume(cap, cost_micros) when is_integer(cost_micros) and cost_micros >= 0 do
    Repo.transaction(fn ->
      current = Repo.one!(from c in Capability, where: c.id == ^cap.id, lock: "FOR UPDATE")

      if current.revoked_at != nil or current.remaining_calls <= 0 or
           current.remaining_cost_micros < cost_micros or
           DateTime.compare(current.expires_at, DateTime.utc_now(:second)) != :gt,
         do: Repo.rollback(:execution_budget_exceeded)

      current
      |> Ecto.Changeset.change(
        remaining_calls: current.remaining_calls - 1,
        remaining_cost_micros: current.remaining_cost_micros - cost_micros
      )
      |> Repo.update!()
    end)
  end

  def consume(_cap, _cost_micros), do: {:error, :invalid_cost}

  def refund(cap, cost_micros) when is_integer(cost_micros) and cost_micros >= 0 do
    Repo.transaction(fn ->
      current = Repo.one!(from c in Capability, where: c.id == ^cap.id, lock: "FOR UPDATE")

      current
      |> Ecto.Changeset.change(remaining_cost_micros: current.remaining_cost_micros + cost_micros)
      |> Repo.update!()
    end)
  end

  def revoke(scope, operation_id) do
    org = Scope.organization_id!(scope)

    Repo.update_all(
      from(c in Capability,
        where:
          c.org_id == ^org and c.actor_user_id == ^scope.user.id and
            c.operation_id == ^operation_id and is_nil(c.revoked_at)
      ),
      set: [revoked_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  @doc false
  def revoke_turn(turn_id) do
    case Repo.get(Hermitscale.Agents.Turn, turn_id) do
      nil ->
        {:error, :not_found}

      turn ->
        Repo.update_all(
          from(c in Capability,
            where:
              c.org_id == ^turn.org_id and c.actor_user_id == ^turn.execution_actor_user_id and
                c.operation_id == ^turn.id and is_nil(c.revoked_at)
          ),
          set: [revoked_at: DateTime.utc_now(:second)]
        )

        :ok
    end
  end

  def provider_env(scope, session, turn) do
    config = Application.get_env(:hermitscale, __MODULE__, [])

    case Keyword.fetch(config, :gateway_url) do
      :error ->
        {:error, :inference_gateway_not_configured}

      {:ok, url} ->
        with {:ok, selection} <- openai_selection(scope, session.connection_set),
             {:ok, _ref} <-
               ConnectedAccounts.credential_ref(
                 Scope.execution_context(scope, ["agents:run"]),
                 selection,
                 []
               ),
             {:ok, issued} <-
               issue_inference(scope, turn, %{
                 kind: "inference",
                 resource_ids: [turn.id],
                 actions: ["responses"],
                 operation_id: turn.id,
                 connection: selection,
                 models: Keyword.get(config, :models, ["gpt-5.1-codex"]),
                 remaining_calls: 500,
                 remaining_cost_micros: turn.budget_cents * 10_000,
                 ttl_seconds: max(DateTime.diff(turn.deadline, DateTime.utc_now(:second)), 1)
               }) do
          {:ok,
           %{
             "OPENAI_BASE_URL" => url,
             "OPENAI_API_KEY" => issued.token,
             "HERMITSCALE_MODEL" => hd(Keyword.get(config, :models, ["gpt-5.1-codex"]))
           }}
        end
    end
  end

  def provider_ready(scope, session) do
    config = Application.get_env(:hermitscale, __MODULE__, [])

    with {:ok, url} when is_binary(url) <- Keyword.fetch(config, :gateway_url),
         {:ok, selection} <- openai_selection(scope, session.connection_set),
         {:ok, _ref} <-
           ConnectedAccounts.credential_ref(
             Scope.execution_context(scope, ["agents:run"]),
             selection,
             []
           ),
         models = Keyword.get(config, :models, ["gpt-5.1-codex"]),
         :ok <-
           Enum.reduce_while(models, :ok, fn model, :ok ->
             case Hermitscale.Integrations.InferenceGateway.rates(model) do
               {:ok, _rates} -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      :ok
    else
      :error -> {:error, :inference_gateway_not_configured}
      {:error, _reason} = error -> error
    end
  end

  def credential(scope, session, provider, scopes, permissions \\ ["agents:run"]) do
    with {:ok, selection} <- selected(scope, session.connection_set, provider, scopes),
         {:ok, ref} <-
           ConnectedAccounts.credential_ref(
             Scope.execution_context(scope, permissions),
             selection,
             scopes
           ),
         {:ok, credential} <- ConnectedAccounts.vend(ref),
         do: {:ok, credential}
  end

  defp issue_inference(scope, turn, attrs) do
    Repo.transaction(fn ->
      _turn =
        Repo.one!(from t in Hermitscale.Agents.Turn, where: t.id == ^turn.id, lock: "FOR UPDATE")

      org = Scope.organization_id!(scope)

      caps =
        Repo.all(
          from c in Capability,
            where: c.org_id == ^org and c.operation_id == ^turn.id,
            lock: "FOR UPDATE"
        )

      spent = Enum.sum(Enum.map(caps, &max(&1.initial_cost_micros - &1.remaining_cost_micros, 0)))
      remaining = turn.budget_cents * 10_000 - spent
      if remaining <= 0, do: Repo.rollback(:execution_budget_exceeded)
      revoke(scope, turn.id)

      case issue(scope, Map.put(attrs, :remaining_cost_micros, remaining)) do
        {:ok, issued} -> issued
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp openai_selection(scope, set), do: selected(scope, set, "openai", [])

  defp selected(scope, set, provider, scopes) do
    case Map.fetch(set, provider) do
      {:ok, selection} ->
        with :ok <- ConnectedAccounts.validate_selection(selection, provider),
             do: {:ok, selection}

      :error ->
        ConnectedAccounts.select(scope, provider, scopes)
    end
  end

  defp validate(cap, action, resource) do
    cond do
      cap.revoked_at != nil ->
        {:error, :capability_revoked}

      DateTime.compare(cap.expires_at, DateTime.utc_now(:second)) != :gt ->
        {:error, :capability_expired}

      action not in cap.actions and not (cap.kind == "product" and action == "protocol") ->
        {:error, :capability_action_denied}

      cap.kind == "product" and Hermitscale.ProductTools.resource_required?(action) and
          not is_binary(resource) ->
        {:error, :capability_resource_denied}

      resource != nil and resource not in cap.resource_ids ->
        {:error, :capability_resource_denied}

      cap.remaining_calls <= 0 ->
        {:error, :execution_budget_exceeded}

      true ->
        :ok
    end
  end

  defp digest(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp authorize_issuance(scope, %{kind: "product", actions: actions}) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case Authorization.authorize(scope, Hermitscale.ProductTools.permission(action)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp authorize_issuance(scope, _attrs), do: Authorization.authorize(scope, "agents:run")
end
