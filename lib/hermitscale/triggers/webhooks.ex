defmodule Hermitscale.Triggers.Webhooks do
  @moduledoc "Durable provider webhook registration, authenticated intake, and queued workflow dispatch."
  import Ecto.Query
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.{Authorization, Repo, Triggers}
  alias Hermitscale.Integrations.{ConnectedAccounts, ExecutionContext}
  alias Hermitscale.Integrations.GitHub.Client, as: GitHub
  alias Hermitscale.Integrations.Linear.Operations, as: Linear

  alias Hermitscale.Triggers.{
    Trigger,
    WebhookSubscription,
    WebhookDelivery,
    WebhookLifecycleWorker,
    WebhookDeliveryWorker
  }

  alias Hermitscale.Workflows.{Credentials, Run}

  @doc "Reads registration state within a verified organization."
  def get_subscription!(%Scope{} = scope, %Trigger{} = trigger) do
    trigger = Triggers.get_trigger!(scope, trigger.id)
    Repo.get_by!(WebhookSubscription, trigger_id: trigger.id)
  end

  @doc false
  def provider(trigger) do
    module = Triggers.catalog_module!(trigger)

    case function_exported?(module, :provider_webhook, 0) do
      true -> module.provider_webhook()
      false -> nil
    end
  end

  @doc "Checks the public HTTPS callback configuration before activation."
  def validate_configuration do
    secret = root_secret()

    case is_binary(secret) and byte_size(secret) >= 32 do
      true ->
        case URI.parse(base_url()) do
          %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
          when is_binary(host) and host not in ["localhost", "127.0.0.1", "::1"] ->
            :ok

          _ ->
            {:error, :webhook_base_url_required}
        end

      false ->
        {:error, :webhook_signing_secret_required}
    end
  end

  @doc "Returns the stable callback URL recorded on a subscription."
  def url(subscription), do: Map.fetch!(subscription.desired_config, "url")

  @doc "Derives the provider signing key from a server secret and a random callback token. Never persist this value."
  def signing_secret(subscription) do
    :crypto.mac(:hmac, :sha256, root_secret(), "provider-webhook:" <> subscription.webhook_token)
    |> Base.url_encode64(padding: false)
  end

  @doc false
  def sync_graph(graph, triggers, old_triggers) do
    managed = Enum.filter(triggers, &(not is_nil(provider(&1))))
    keep_ids = Enum.map(managed, & &1.id)

    with :ok <- sync_all(managed, &sync_trigger(&1, graph)),
         :ok <-
           sync_all(Enum.reject(old_triggers, &(&1.id in keep_ids)), &disable_subscription(&1.id)) do
      :ok
    end
  end

  @doc false
  def status_changed(%Trigger{} = trigger) do
    case {provider(trigger), trigger.status} do
      {nil, _status} -> disable_subscription(trigger.id)
      {_provider, :enabled} -> sync_trigger(trigger, Repo.preload(trigger, :graph).graph)
      {_provider, status} when status in [:disabled, :errored] -> disable_subscription(trigger.id)
    end
  end

  defp sync_trigger(trigger, graph) do
    with :ok <- validate_configuration() do
      existing = Repo.get_by(WebhookSubscription, trigger_id: trigger.id)

      config = %{
        "provider" => provider(trigger),
        "organization_id" => graph.org_id,
        "actor_user_id" => trigger.execution_actor_user_id,
        "selection" => Map.fetch!(Credentials.selections(graph.definition), trigger.node_id),
        "params" => trigger.config,
        "url" => base_url() <> "/hooks/" <> trigger.webhook_token,
        "signing_key_id" => :crypto.hash(:sha256, root_secret()) |> Base.encode16(case: :lower)
      }

      registration_id =
        case existing do
          %WebhookSubscription{desired_config: desired} ->
            case Map.delete(desired, "registration_id") == config and existing.status != :errored do
              true -> Map.fetch!(desired, "registration_id")
              false -> Ecto.UUID.generate()
            end

          nil ->
            Ecto.UUID.generate()
        end

      config = Map.put(config, "registration_id", registration_id)
      retired = retired_configs(existing, config)

      status =
        case existing do
          %WebhookSubscription{remote_config: ^config, remote_id: id} when is_binary(id) ->
            :active

          _ ->
            :pending
        end

      with {:ok, subscription} <-
             (existing || %WebhookSubscription{})
             |> WebhookSubscription.changeset(%{
               trigger_id: trigger.id,
               provider: provider(trigger),
               webhook_token: trigger.webhook_token,
               desired_config: config,
               retired_configs: retired,
               enabled: true,
               status: status,
               error: nil
             })
             |> Repo.insert_or_update(),
           {:ok, _job} <- enqueue_lifecycle(subscription) do
        :ok
      end
    end
  end

  defp retired_configs(nil, _config), do: %{}

  defp retired_configs(existing, config) do
    previous = existing.desired_config

    case previous["registration_id"] == config["registration_id"] do
      true ->
        existing.retired_configs

      false ->
        id =
          if existing.remote_config["registration_id"] == previous["registration_id"],
            do: existing.remote_id,
            else: nil

        Map.put(
          existing.retired_configs,
          previous["registration_id"],
          Map.put(previous, "_remote_id", id)
        )
    end
  end

  defp disable_subscription(trigger_id) do
    case Repo.get_by(WebhookSubscription, trigger_id: trigger_id) do
      nil ->
        :ok

      subscription ->
        with {:ok, subscription} <-
               subscription
               |> WebhookSubscription.changeset(%{enabled: false, status: :pending})
               |> Repo.update(),
             {:ok, _job} <- enqueue_lifecycle(subscription),
             do: :ok
    end
  end

  defp enqueue_lifecycle(subscription) do
    WebhookLifecycleWorker.new(%{
      subscription_id: subscription.id,
      generation: subscription.desired_config["registration_id"],
      enabled: subscription.enabled
    })
    |> Oban.insert()
  end

  @doc false
  def enqueue_pending do
    from(s in WebhookSubscription,
      where: s.status == :pending or (is_nil(s.trigger_id) and s.status == :active)
    )
    |> Repo.all()
    |> Enum.each(fn subscription ->
      {:ok, _job} = enqueue_lifecycle(subscription)
    end)

    :ok
  end

  @doc false
  def reconcile(id) do
    Repo.transaction(
      fn ->
        case Repo.one(from s in WebhookSubscription, where: s.id == ^id, lock: "FOR UPDATE") do
          nil -> {:ok, :inactive}
          subscription -> reconcile_locked(subscription)
        end
      end,
      timeout: 120_000
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_locked(subscription) do
    result =
      with {:ok, subscription} <- purge_retired(subscription) do
        case {subscription.enabled, subscription.trigger_id} do
          {true, id} when is_binary(id) -> provision(subscription)
          _ -> remove(subscription)
        end
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} = error ->
        subscription
        |> WebhookSubscription.changeset(%{
          status: :errored,
          error: %{
            "message" => "Provider webhook setup or cleanup failed",
            "action" => "repair_webhook"
          }
        })
        |> Repo.update!()

        case terminal?(reason) and subscription.enabled and is_binary(subscription.trigger_id) do
          true ->
            trigger = Repo.get!(Trigger, subscription.trigger_id)

            trigger
            |> Trigger.changeset(%{
              status: :errored,
              error: %{"message" => "Provider webhook needs repair", "action" => "repair_webhook"}
            })
            |> Repo.update!()

          false ->
            :ok
        end

        error
    end
  end

  defp provision(subscription) do
    with :ok <- validate_configuration(),
         :ok <- remove_previous(subscription),
         {:ok, ref} <- reference(subscription.desired_config),
         {:ok, remote_id} <- ensure_remote(subscription, ref) do
      subscription
      |> WebhookSubscription.changeset(%{
        remote_id: remote_id,
        remote_config: subscription.desired_config,
        status: :active,
        error: nil
      })
      |> Repo.update!()

      {:ok, :active}
    end
  end

  defp remove_previous(%WebhookSubscription{remote_id: nil}), do: :ok

  defp remove_previous(%WebhookSubscription{remote_config: config, desired_config: config}),
    do: :ok

  defp remove_previous(subscription) do
    with {:ok, ref} <- reference(subscription.remote_config),
         :ok <- delete_remote(subscription.remote_config, subscription.remote_id, ref) do
      subscription
      |> WebhookSubscription.changeset(%{remote_id: nil, remote_config: %{}})
      |> Repo.update!()

      :ok
    end
  end

  defp remove(%WebhookSubscription{remote_id: nil} = subscription) do
    # The provider may have committed a create before the HTTP acknowledgement
    # or local transaction was lost. Reconcile the durable desired URL as well.
    with {:ok, ref} <- reference(subscription.desired_config, ["workflows:activate"]),
         :ok <- delete_remote(subscription.desired_config, nil, ref) do
      subscription
      |> WebhookSubscription.changeset(%{status: :inactive, remote_config: %{}, error: nil})
      |> Repo.update!()

      {:ok, :inactive}
    end
  end

  defp remove(subscription) do
    with {:ok, ref} <- reference(subscription.remote_config, ["workflows:activate"]),
         :ok <- delete_remote(subscription.remote_config, subscription.remote_id, ref) do
      subscription
      |> WebhookSubscription.changeset(%{
        remote_id: nil,
        remote_config: %{},
        status: :inactive,
        error: nil
      })
      |> Repo.update!()

      {:ok, :inactive}
    end
  end

  defp reference(config, permissions \\ ["workflows:run", "workflows:activate"]) do
    context = %ExecutionContext{
      organization_id: Map.fetch!(config, "organization_id"),
      actor_user_id: Map.fetch!(config, "actor_user_id"),
      required_permissions: permissions
    }

    scopes = if config["provider"] == "github", do: ["admin:repo_hook"], else: ["admin"]

    with {:ok, _scope} <- Authorization.execution_scope(context),
         {:ok, ref} <-
           ConnectedAccounts.credential_ref(context, Map.fetch!(config, "selection"), scopes),
         do: {:ok, ref}
  end

  defp ensure_remote(%WebhookSubscription{provider: "github"} = subscription, ref) do
    config = subscription.desired_config
    expected_url = config["url"]
    path = github_hooks(config)
    params = cast_provider_params(subscription)

    body = %{
      "name" => "web",
      "active" => true,
      "events" => params.events,
      "config" => %{
        "url" => config["url"],
        "content_type" => "json",
        "secret" => signing_secret(subscription),
        "insecure_ssl" => "0"
      }
    }

    with {:ok, hooks} <- GitHub.list(ref, path, %{return_all: true, limit: 100, filters: %{}}),
         :ok <- valid_hooks(hooks, "github") do
      existing = Enum.find(hooks, &(get_in(&1, ["config", "url"]) == config["url"]))

      result =
        case existing do
          nil ->
            GitHub.api(ref, :post, path, json: body, retry: false)

          %{"id" => id} ->
            GitHub.api(ref, :patch, path <> "/" <> to_string(id), json: body, retry: false)

          _ ->
            {:error, :invalid_github_response}
        end

      with {:ok, response} <- result do
        case response do
          %{"id" => id, "active" => true, "config" => %{"url" => ^expected_url}}
          when is_integer(id) or is_binary(id) ->
            {:ok, to_string(id)}

          _ ->
            {:error, :invalid_github_response}
        end
      end
    end
  end

  defp ensure_remote(%WebhookSubscription{provider: "linear"} = subscription, ref) do
    config = subscription.desired_config
    expected_url = config["url"]
    params = cast_provider_params(subscription)

    input = %{
      "id" => config["registration_id"],
      "url" => config["url"],
      "resourceTypes" => params.resources,
      "enabled" => true,
      "secret" => signing_secret(subscription),
      "allPublicTeams" => params.all_public_teams
    }

    input =
      case Map.get(params, :team_id) do
        nil -> input
        team -> Map.put(input, "teamId", team)
      end

    with {:ok, hooks} <- Linear.webhooks(ref),
         :ok <- valid_hooks(hooks, "linear") do
      case Enum.find(hooks, &(&1["id"] == config["registration_id"])) do
        %{"id" => id, "url" => ^expected_url, "enabled" => true} ->
          {:ok, id}

        nil ->
          case Linear.create_webhook(ref, input) do
            {:ok, %{"id" => id, "enabled" => true, "url" => ^expected_url}} -> {:ok, id}
            {:ok, _response} -> {:error, :invalid_linear_response}
            {:error, _reason} = error -> error
          end

        _ ->
          {:error, :invalid_linear_response}
      end
    end
  end

  defp delete_remote(config, nil, ref) do
    with {:ok, id} <- find_remote_id(config, ref) do
      case id do
        nil -> :ok
        id -> delete_remote(config, id, ref)
      end
    end
  end

  defp delete_remote(%{"provider" => "github"} = config, id, ref) do
    case GitHub.api(ref, :delete, github_hooks(config) <> "/" <> id, retry: false) do
      {:ok, _} -> :ok
      {:error, {:provider_request_failed, 404}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp delete_remote(%{"provider" => "linear"}, id, ref) do
    with {:ok, hooks} <- Linear.webhooks(ref),
         :ok <- valid_hooks(hooks, "linear") do
      case Enum.any?(hooks, &(&1["id"] == id)) do
        false ->
          :ok

        true ->
          case Linear.delete_webhook(ref, id) do
            {:ok, _} -> :ok
            {:error, _reason} = error -> error
          end
      end
    end
  end

  defp find_remote_id(%{"provider" => "github"} = config, ref) do
    with {:ok, hooks} <-
           GitHub.list(ref, github_hooks(config), %{return_all: true, limit: 100, filters: %{}}),
         :ok <- valid_hooks(hooks, "github") do
      case Enum.find(hooks, &(get_in(&1, ["config", "url"]) == config["url"])) do
        nil -> {:ok, nil}
        %{"id" => id} -> {:ok, to_string(id)}
      end
    end
  end

  defp find_remote_id(%{"provider" => "linear"} = config, ref) do
    with {:ok, hooks} <- Linear.webhooks(ref),
         :ok <- valid_hooks(hooks, "linear") do
      case Enum.find(
             hooks,
             &(&1["id"] == config["registration_id"] and &1["url"] == config["url"])
           ) do
        nil -> {:ok, nil}
        %{"id" => id} -> {:ok, id}
      end
    end
  end

  defp purge_retired(subscription) do
    Enum.reduce_while(subscription.retired_configs, {:ok, subscription}, fn {key, config},
                                                                            {:ok, subscription} ->
      with {:ok, ref} <- reference(config, ["workflows:activate"]),
           :ok <- delete_remote(config, config["_remote_id"], ref) do
        attrs = %{retired_configs: Map.delete(subscription.retired_configs, key)}

        attrs =
          if subscription.remote_config["registration_id"] == key,
            do: Map.merge(attrs, %{remote_id: nil, remote_config: %{}}),
            else: attrs

        updated = subscription |> WebhookSubscription.changeset(attrs) |> Repo.update!()
        {:cont, {:ok, updated}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp github_hooks(config),
    do: "/repos/#{segment(config["params"]["owner"])}/#{segment(config["params"]["repo"])}/hooks"

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp cast_provider_params(subscription) do
    module =
      case subscription.provider do
        "github" -> Hermitscale.Triggers.GitHub.Events.V1
        "linear" -> Hermitscale.Triggers.Linear.Events.V1
      end

    Hermitscale.Workflows.Nodes.Params.cast!(
      subscription.desired_config["params"],
      module.spec().params_schema,
      [],
      []
    )
  end

  defp valid_hooks(hooks, provider) do
    valid? =
      Enum.all?(hooks, fn
        %{"id" => id, "config" => %{"url" => url}} when provider == "github" ->
          (is_integer(id) or is_binary(id)) and is_binary(url)

        %{"id" => id, "url" => url, "enabled" => enabled} when provider == "linear" ->
          is_binary(id) and is_binary(url) and is_boolean(enabled)

        _ ->
          false
      end)

    case {valid?, provider} do
      {true, _} -> :ok
      {false, "github"} -> {:error, :invalid_github_response}
      {false, "linear"} -> {:error, :invalid_linear_response}
    end
  end

  @doc "Authenticates a provider delivery and retains it with a job before acknowledging it."
  def accept(token, request) do
    with %Trigger{status: :enabled} = trigger <- Triggers.get_webhook_trigger(token),
         %WebhookSubscription{status: :active, enabled: true, remote_id: remote_id} = subscription
         when is_binary(remote_id) <- Repo.get_by(WebhookSubscription, trigger_id: trigger.id) do
      params =
        Triggers.cast_params!(trigger)
        |> Map.put(:_webhook_secret, signing_secret(subscription))
        |> Map.put(:_remote_id, remote_id)

      case Triggers.catalog_module!(trigger).handle_request(request, params) do
        {:fire, payload, opts} ->
          retain_delivery(subscription, payload, Keyword.fetch!(opts, :idempotency_key))

        {:reply, status, body} ->
          {:reply, status, body}

        {:ignore, _reason} ->
          {:reply, 200, %{"status" => "ignored"}}

        {:error, :unauthorized} ->
          {:error, :unauthorized}
      end
    else
      nil -> {:error, :not_found}
      %Trigger{} -> {:error, :not_found}
      %WebhookSubscription{} -> {:error, :not_found}
    end
  end

  defp retain_delivery(subscription, payload, key) do
    Repo.transaction(fn ->
      current =
        Repo.one!(
          from s in WebhookSubscription, where: s.id == ^subscription.id, lock: "FOR UPDATE"
        )

      if not current.enabled or current.status != :active or
           current.desired_config != subscription.desired_config do
        Repo.rollback(:not_found)
      end

      case Repo.get_by(WebhookDelivery, subscription_id: subscription.id, delivery_key: key) do
        nil ->
          delivery =
            %WebhookDelivery{}
            |> WebhookDelivery.changeset(%{
              subscription_id: subscription.id,
              delivery_key: key,
              registration_id: subscription.desired_config["registration_id"],
              payload: payload
            })
            |> Repo.insert!()

          enqueue_delivery!(delivery)

        %WebhookDelivery{status: :failed} = delivery ->
          enqueue_delivery!(delivery)

        %WebhookDelivery{} ->
          :ok
      end

      {:reply, 202, %{"status" => "accepted"}}
    end)
    |> case do
      {:ok, reply} -> reply
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_delivery!(delivery) do
    case WebhookDeliveryWorker.new(%{delivery_id: delivery.id}) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _changeset} -> Repo.rollback(:unavailable)
    end
  end

  @doc false
  def deliver(id) do
    case Repo.get(WebhookDelivery, id) do
      nil ->
        {:cancel, :deleted}

      %WebhookDelivery{status: :dispatched} ->
        {:ok, :dispatched}

      %WebhookDelivery{status: :ignored} ->
        {:cancel, :disabled}

      delivery ->
        deliver_pending(delivery, Repo.get!(WebhookSubscription, delivery.subscription_id))
    end
  end

  defp deliver_pending(delivery, subscription) do
    trigger =
      case subscription.trigger_id do
        nil -> nil
        id -> Triggers.get_trigger(id)
      end

    cond do
      not subscription.enabled or is_nil(trigger) or trigger.status != :enabled ->
        cancel_delivery(delivery, :disabled)

      subscription.desired_config["registration_id"] != delivery.registration_id ->
        cancel_delivery(delivery, :stale_subscription)

      true ->
        case Hermitscale.Triggers.Dispatcher.fire(trigger, delivery.payload,
               idempotency_key: delivery.delivery_key
             ) do
          {:ok, %Run{id: run_id}} ->
            conclude_delivery(delivery, :dispatched, run_id)
            {:ok, :dispatched}

          {:ok, :deduped} ->
            firing =
              Repo.get_by!(Hermitscale.Triggers.Firing,
                trigger_id: trigger.id,
                idempotency_key: delivery.delivery_key
              )

            conclude_delivery(delivery, :dispatched, firing.run_id)
            {:ok, :dispatched}

          {:error, reason}
          when reason in [:disabled, :rejected, :execution_actor_ineligible] ->
            cancel_delivery(delivery, reason)

          {:error, reason} ->
            delivery
            |> WebhookDelivery.changeset(%{
              status: :failed,
              error: %{"message" => "Workflow dispatch failed", "action" => "retry_delivery"}
            })
            |> Repo.update!()

            {:error, reason}
        end
    end
  end

  defp cancel_delivery(delivery, reason) do
    delivery
    |> WebhookDelivery.changeset(%{
      status: :ignored,
      error: %{"reason" => Atom.to_string(reason)}
    })
    |> Repo.update!()

    {:cancel, reason}
  end

  defp conclude_delivery(delivery, status, run_id),
    do:
      delivery
      |> WebhookDelivery.changeset(%{status: status, run_id: run_id, error: nil})
      |> Repo.update!()

  @doc false
  def terminal?(reason)
      when reason in [
             :execution_actor_ineligible,
             :insufficient_scopes,
             :needs_reauthorization,
             :account_not_found,
             :webhook_base_url_required,
             :webhook_signing_secret_required
           ],
      do: true

  def terminal?({:provider_request_failed, status}) when status in [400, 401, 403, 404, 422],
    do: true

  def terminal?(_reason), do: false

  defp base_url,
    do:
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get(:base_url, "")
      |> String.trim_trailing("/")

  defp root_secret,
    do:
      Application.get_env(:hermitscale, __MODULE__, [])
      |> Keyword.get_lazy(:signing_secret, fn ->
        HermitscaleWeb.Endpoint.config(:secret_key_base)
      end)

  defp sync_all(items, fun),
    do:
      Enum.reduce_while(items, :ok, fn item, :ok ->
        case fun.(item) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
end
