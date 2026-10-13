defmodule HermitscaleWeb.AppLive do
  use HermitscaleWeb, :live_view
  alias Hermitscale.{Agents, Apps, Authorization}
  alias Ecto.Changeset

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Apps")
     |> assign(:app, nil)
     |> assign(:environment, nil)
     |> assign(:conversation, nil)
     |> assign(:deployment, nil)
     |> assign(:preview, nil)
     |> assign(:prepared, nil)
     |> assign(:share_url, nil)
     |> assign(:public_url, nil)
     |> assign(:recovery, nil)
     |> assign(:backup_options, [])
     |> assign(:connections_loaded?, false)
     |> assign(:openai_accounts, [])
     |> assign(:github_accounts, [])
     |> assign(:can_write?, Authorization.authorize(scope, "apps:write") == :ok)
     |> assign(:can_deploy?, Authorization.authorize(scope, "apps:deploy") == :ok)
     |> assign(
       :new_app_form,
       to_form(Apps.change_app(scope, %{operation_key: Ecto.UUID.generate()}))
     )
     |> assign(:build_form, build_form())
     |> assign(:release_form, release_form())
     |> assign(:environment_form, environment_form(%{}))
     |> assign(:recovery_form, recovery_form())
     |> stream(:apps, [])
     |> stream(:environments, [])
     |> stream(:deployments, [])
     |> stream(:previews, [])
     |> stream(:turns, [])
     |> stream(:events, [])
     |> stream(:logs, [])
     |> stream(:workflows, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.live_action do
      :index ->
        case Apps.list_apps(scope) do
          apps when is_list(apps) ->
            {:noreply, socket |> assign(:app, nil) |> stream(:apps, apps, reset: true)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Your role does not allow viewing apps.")
             |> push_navigate(to: ~p"/")}
        end

      action when action in [:show, :build, :deployment] ->
        case Apps.get_app(scope, params["id"]) do
          {:ok, app} ->
            if connected?(socket), do: Apps.subscribe(scope, app.id)
            socket = socket |> assign(:app, app) |> assign(:page_title, app.name) |> load_app()

            socket =
              if action == :deployment,
                do: load_deployment(socket, params["deployment_id"]),
                else: socket

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply,
             socket |> put_flash(:error, "App is unavailable.") |> push_navigate(to: ~p"/apps")}
        end
    end
  end

  @impl true
  def handle_event("validate_app", %{"app" => attrs}, socket) do
    changeset = Apps.change_app(socket.assigns.current_scope, attrs)
    {:noreply, assign(socket, new_app_form: to_form(changeset, action: :validate))}
  end

  def handle_event("create_app", %{"app" => attrs}, socket) do
    case Apps.create_app(socket.assigns.current_scope, attrs) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(:info, "App created. Start a build conversation.")
         |> push_navigate(to: ~p"/apps/#{app.id}/build")}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign(socket, new_app_form: to_form(changeset))}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("start_build", params, socket) do
    source = Map.get(params, "release", %{})

    connections =
      [{"openai", "openai_account_id"}, {"github", "github_account_id"}]
      |> Enum.flat_map(fn {provider, field} ->
        case Map.get(source, field, "") do
          "" -> []
          id -> [{provider, %{"provider" => provider, "account_id" => id}}]
        end
      end)
      |> Map.new()

    case Apps.start_build(socket.assigns.current_scope, socket.assigns.app.id, %{
           operation_key: Ecto.UUID.generate(),
           base_sha: Map.get(source, "source_commit"),
           connection_set: connections
         }) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:conversation, conversation)
         |> load_conversation()
         |> put_flash(:info, "Build conversation ready. Describe your app.")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("load_connections", _params, socket) do
    case Hermitscale.Integrations.ConnectedAccounts.list(socket.assigns.current_scope) do
      {:ok, accounts} ->
        options = fn provider ->
          accounts
          |> Enum.filter(&(&1["provider"] == provider and &1["state"] == "connected"))
          |> Enum.map(&{&1["account_display_name"] || &1["id"], &1["id"]})
        end

        {:noreply,
         assign(socket,
           connections_loaded?: true,
           openai_accounts: options.("openai"),
           github_accounts: options.("github")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Connected accounts could not be loaded.")}
    end
  end

  def handle_event("validate_build", %{"build" => attrs}, socket),
    do: {:noreply, assign(socket, build_form: build_form(attrs, :validate))}

  def handle_event("submit_build", %{"build" => attrs}, socket) do
    case Apps.submit_build_turn(
           socket.assigns.current_scope,
           socket.assigns.app.id,
           socket.assigns.conversation.id,
           Map.put(attrs, "operation_key", Ecto.UUID.generate())
         ) do
      {:ok, _turn} ->
        {:noreply, socket |> assign(:build_form, build_form()) |> load_conversation()}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("stop_turn", %{"id" => id}, socket) do
    case Agents.cancel_turn(socket.assigns.current_scope, id) do
      {:ok, _turn} -> {:noreply, load_conversation(socket)}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("validate_release", %{"release" => attrs}, socket),
    do: {:noreply, assign(socket, release_form: release_form(attrs, :validate))}

  def handle_event("load_preview", %{"release" => attrs}, socket) do
    case Apps.ensure_preview(socket.assigns.current_scope, socket.assigns.app.id, %{
           session_id: socket.assigns.conversation.id,
           source_commit: attrs["source_commit"],
           operation_key: Ecto.UUID.generate()
         }) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:preview, preview)
         |> assign(:release_form, release_form(%{"source_commit" => preview.source_commit}))
         |> stream_insert(:previews, preview)
         |> put_flash(:info, "Preview verified. Open it when ready.")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("prepare_release", %{"release" => %{"action" => "preview"} = attrs}, socket) do
    handle_event("load_preview", %{"release" => attrs}, socket)
  end

  def handle_event("prepare_release", %{"release" => attrs}, socket) do
    scope = socket.assigns.current_scope
    app = socket.assigns.app
    environment = socket.assigns.environment

    with {:ok, built} <-
           Apps.build_artifact(
             scope,
             app.id,
             socket.assigns.conversation.id,
             attrs["source_commit"],
             Ecto.UUID.generate(),
             freeze: true
           ),
         input = %{
           environment_id: environment.id,
           session_id: socket.assigns.conversation.id,
           source_commit: built.source_commit,
           artifact_id: built.artifact.id,
           artifact_digest: built.artifact.digest,
           configuration_digest: environment.configuration_digest,
           expected_active_deployment: environment.active_deployment_id,
           operation_key: Ecto.UUID.generate()
         },
         {:ok, _target} <- Apps.deployment_target_digest(scope, app.id, input) do
      prepared = %{input: input, checks: built.checks, action: :deploy}

      {:noreply,
       assign(socket,
         prepared: prepared,
         release_form: release_form(%{"source_commit" => built.source_commit})
       )}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event(
        "confirm_action",
        _params,
        %{assigns: %{prepared: %{action: :publish} = prepared}} = socket
      ) do
    scope = socket.assigns.current_scope

    with {:ok, _environment} <-
           Apps.publish_environment(scope, prepared.input.environment_id, %{
             public: prepared.input.public,
             expected_active_deployment: prepared.input.expected_active_deployment
           }) do
      {:noreply,
       socket
       |> assign(:prepared, nil)
       |> load_app()
       |> put_flash(:info, "Published access updated.")}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event(
        "confirm_action",
        _params,
        %{assigns: %{prepared: %{action: :restore} = prepared}} = socket
      ) do
    scope = socket.assigns.current_scope

    with {:ok, recovery} <-
           Apps.restore_data(scope, prepared.input.environment_id, prepared.input.backup_id, %{
             expected_active_deployment: prepared.input.expected_active_deployment,
             operation_key: prepared.input.operation_key
           }) do
      {:noreply,
       socket
       |> assign(prepared: nil, recovery: recovery)
       |> put_flash(:info, "Data recovery admitted. The app stays in maintenance until verified.")}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event(
        "confirm_action",
        _params,
        %{assigns: %{prepared: %{action: action} = prepared}} = socket
      )
      when action in [:deploy, :rollback] do
    scope = socket.assigns.current_scope

    with {:ok, deployment} <-
           Apps.request_deployment(
             scope,
             socket.assigns.app.id,
             prepared.input
           ) do
      {:noreply,
       socket
       |> assign(:prepared, nil)
       |> put_flash(:info, "Deployment admitted. Verification will appear here.")
       |> push_navigate(to: ~p"/apps/#{socket.assigns.app.id}/deployments/#{deployment.id}")}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("confirm_action", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Prepare an action before confirming it.")}

  def handle_event("prepare_publication", _params, socket) do
    scope = socket.assigns.current_scope
    environment = socket.assigns.environment
    public = not environment.public

    with {:ok, deployment} <- Apps.get_deployment(scope, environment.active_deployment_id) do
      input = %{
        environment_id: environment.id,
        public: public,
        source_commit: deployment.source_commit,
        artifact_digest: deployment.artifact_digest,
        expected_active_deployment: deployment.id
      }

      {:noreply,
       assign(socket,
         prepared: %{
           input: input,
           checks: [
             if(public,
               do: "Anyone with the published URL can access the app",
               else: "Revoke public URL access"
             )
           ],
           action: :publish
         }
       )}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("prepare_recovery", %{"recovery" => attrs}, socket) do
    scope = socket.assigns.current_scope
    environment = socket.assigns.environment

    with {:ok, backup} <- Apps.get_backup(scope, attrs["backup_id"]),
         {:ok, _target} <- Apps.restore_target_digest(scope, environment.id, backup.id),
         {:ok, deployment} <- Apps.get_deployment(scope, environment.active_deployment_id) do
      input = %{
        environment_id: environment.id,
        backup_id: backup.id,
        operation_key: Ecto.UUID.generate(),
        source_commit: deployment.source_commit,
        artifact_digest: backup.digest,
        expected_active_deployment: deployment.id
      }

      {:noreply,
       assign(socket,
         prepared: %{
           input: input,
           checks: [
             "Backup integrity and independent restoration verified",
             "Replaces current database and uploads with this backup"
           ],
           action: :restore
         }
       )}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("prepare_rollback", _params, socket) do
    scope = socket.assigns.current_scope
    prior = socket.assigns.deployment
    environment = socket.assigns.environment

    input = %{
      environment_id: prior.environment_id,
      session_id: prior.session_id,
      source_commit: prior.source_commit,
      artifact_id: prior.artifact_id,
      artifact_digest: prior.artifact_digest,
      configuration_digest: environment.configuration_digest,
      expected_active_deployment: environment.active_deployment_id,
      rollback_of_id: prior.id,
      operation_key: Ecto.UUID.generate()
    }

    with {:ok, _target} <- Apps.deployment_target_digest(scope, socket.assigns.app.id, input) do
      {:noreply,
       assign(socket,
         prepared: %{
           input: input,
           checks: ["Uses this recorded code artifact", "Preserves current customer data"],
           action: :rollback
         }
       )}
    else
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("share_preview", _params, socket) do
    case Apps.create_access_grant(socket.assigns.current_scope, socket.assigns.app.id, %{
           preview_id: socket.assigns.preview.id,
           kind: "shared",
           expires_in: 86400
         }) do
      {:ok, %{url: url}} -> {:noreply, assign(socket, share_url: url)}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("save_environment", %{"environment" => attrs}, socket) do
    result =
      case Integer.parse(attrs["backup_interval_hours"]) do
        {hours, ""} when hours in 1..168 ->
          Apps.update_environment(socket.assigns.current_scope, socket.assigns.environment.id, %{
            configuration: %{
              "display_name" => attrs["display_name"],
              "backup_interval_hours" => hours
            }
          })

        _invalid ->
          {:error, :invalid_backup_interval}
      end

    case result do
      {:ok, environment} ->
        {:noreply,
         socket
         |> assign(:environment, environment)
         |> assign(:environment_form, environment_form(environment.configuration))
         |> put_flash(:info, "Environment configuration saved. New releases bind this version.")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("backup_environment", _params, socket) do
    case Apps.backup_environment(
           socket.assigns.current_scope,
           socket.assigns.environment.id,
           Ecto.UUID.generate()
         ) do
      {:ok, backup} ->
        {:noreply,
         socket
         |> put_flash(:info, "Backup exported and restoration verified: " <> backup.id)
         |> load_app()}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  @impl true
  def handle_info({:app_changed, id}, %{assigns: %{app: %{id: id}}} = socket) do
    socket = load_app(socket)

    socket =
      case socket.assigns.recovery do
        nil ->
          socket

        recovery ->
          {:ok, recovery} = Apps.get_recovery(socket.assigns.current_scope, recovery.id)
          assign(socket, :recovery, recovery)
      end

    socket =
      case socket.assigns.deployment do
        nil -> socket
        deployment -> load_deployment(socket, deployment.id)
      end

    {:noreply, socket}
  end

  def handle_info({:agent_session_updated, id}, %{assigns: %{conversation: %{id: id}}} = socket),
    do: {:noreply, load_conversation(socket)}

  def handle_info(
        {:agent_turn_updated, id, _turn_id},
        %{assigns: %{conversation: %{id: id}}} = socket
      ),
      do: {:noreply, load_conversation(socket)}

  defp load_app(socket) do
    scope = socket.assigns.current_scope
    app = socket.assigns.app
    environments = Apps.list_environments(scope, app.id)
    builds = Apps.list_build_sessions(scope, app.id)
    environment = Enum.find(environments, &(&1.name == "production"))
    backups = Apps.list_backups(scope, environment.id)

    public_url =
      case Apps.public_url(scope, environment.id) do
        {:ok, url} -> url
        {:error, _private_or_unconfigured} -> nil
      end

    socket =
      socket
      |> assign(:environment, environment)
      |> assign(:environment_form, environment_form(environment.configuration))
      |> assign(:public_url, public_url)
      |> assign(
        :backup_options,
        Enum.map(
          backups,
          &{Calendar.strftime(&1.inserted_at, "%Y-%m-%d %H:%M UTC") <>
             " · " <> String.slice(&1.digest, 0, 8), &1.id}
        )
      )
      |> stream(:environments, environments, reset: true)
      |> stream(:deployments, Apps.list_deployments(scope, app.id), reset: true)
      |> stream(:previews, Apps.list_previews(scope, app.id), reset: true)
      |> stream(:logs, Apps.read_logs(scope, app.id), reset: true)
      |> stream(:workflows, Apps.list_workflows(scope, app.id), reset: true)

    case {socket.assigns.conversation, builds} do
      {nil, [%{session_id: id} | _]} ->
        {:ok, conversation} = Agents.get_session(scope, id)
        socket |> assign(:conversation, conversation) |> load_conversation()

      {%{} = _conversation, _builds} ->
        load_conversation(socket)

      {nil, []} ->
        socket
    end
  end

  defp load_conversation(socket) do
    conversation = socket.assigns.conversation
    scope = socket.assigns.current_scope
    if connected?(socket), do: Agents.subscribe(scope, conversation.id)
    turns = Agents.list_turns(scope, conversation.id)

    head =
      Enum.find_value(turns, fn
        %{result: %{"head_sha" => head}} -> head
        _without_result -> nil
      end)

    socket =
      case {head, Map.get(socket.assigns.release_form.params, "source_commit", "")} do
        {head, ""} when is_binary(head) ->
          assign(socket, :release_form, release_form(%{"source_commit" => head}))

        _existing_input ->
          socket
      end

    socket
    |> stream(:turns, turns, reset: true)
    |> stream(:events, Agents.list_events(scope, conversation.id), reset: true)
  end

  defp load_deployment(socket, id) do
    case Apps.get_deployment(socket.assigns.current_scope, id) do
      {:ok, deployment} when deployment.app_id == socket.assigns.app.id ->
        assign(socket, deployment: deployment)

      {:ok, _other} ->
        failure(socket, :not_found) |> push_navigate(to: ~p"/apps")

      {:error, reason} ->
        failure(socket, reason) |> push_navigate(to: ~p"/apps")
    end
  end

  defp build_form(attrs \\ %{}, action \\ nil) do
    {%{instructions: "", budget_cents: 500, timeout_seconds: 1800},
     %{instructions: :string, budget_cents: :integer, timeout_seconds: :integer}}
    |> Changeset.cast(attrs, [:instructions, :budget_cents, :timeout_seconds])
    |> Changeset.validate_required([:instructions])
    |> Changeset.validate_length(:instructions, max: 32000)
    |> to_form(as: :build, action: action)
  end

  defp release_form(attrs \\ %{}, action \\ nil) do
    {%{}, %{source_commit: :string, openai_account_id: :string, github_account_id: :string}}
    |> Changeset.cast(attrs, [:source_commit, :openai_account_id, :github_account_id])
    |> Changeset.validate_required([:source_commit])
    |> Changeset.validate_format(:source_commit, ~r/\A[0-9a-f]{40}\z/)
    |> to_form(as: :release, action: action)
  end

  defp environment_form(configuration) do
    {%{
       display_name: Map.get(configuration, "display_name", "Production"),
       backup_interval_hours: Map.get(configuration, "backup_interval_hours", 24)
     }, %{display_name: :string, backup_interval_hours: :integer}}
    |> Changeset.change()
    |> to_form(as: :environment)
  end

  defp recovery_form do
    {%{}, %{backup_id: :binary_id}}
    |> Changeset.change()
    |> to_form(as: :recovery)
  end

  defp action_label(:deploy), do: "deployment"
  defp action_label(:rollback), do: "code rollback"
  defp action_label(:publish), do: "access change"
  defp action_label(:restore), do: "data restoration"
  defp failure(socket, reason), do: put_flash(socket, :error, message(reason))

  defp message(:workspace_busy),
    do: "The workspace is working. Wait for the current task to finish, then try again."

  defp message(:active_deployment_changed),
    do: "Another release changed this environment. Reload and review the current deployment."

  defp message(:served_revision_mismatch),
    do: "The app did not serve the expected revision. Inspect the deployment evidence."

  defp message(:gateway_not_configured), do: "Configure the isolated app origin to open previews."
  defp message(:forbidden), do: "Your role does not allow this action."
  defp message(%Changeset{}), do: "Check the supplied fields and try again."

  defp message(reason),
    do:
      "Unable to complete this operation: " <>
        (inspect(reason, limit: 4, printable_limit: 160) |> String.replace("_", " "))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-7xl px-4 py-10 sm:px-8">
        <%= if @live_action == :index do %>
          <div class="mb-10">
            <p class="mb-3 text-xs font-semibold uppercase tracking-[0.2em] text-base-content/50">
              Create · build · publish
            </p><h1 class="text-4xl font-semibold tracking-tight">Your apps</h1><p class="mt-3 max-w-xl text-base-content/60">
              Build through conversation. Publish a verified release with its own persistent data.
            </p>
          </div>
          <div class="grid gap-8 lg:grid-cols-[1fr_340px]">
            <section id="apps" phx-update="stream" class="grid content-start gap-4 sm:grid-cols-2">
              <p
                id="apps-empty"
                class="hidden rounded-2xl border border-dashed border-base-300 p-8 text-base-content/60 only:block"
              >
                Create your first app to start building.
              </p>
              <.link
                :for={{id, app} <- @streams.apps}
                id={id}
                navigate={~p"/apps/#{app.id}"}
                class="group rounded-2xl border border-base-300 bg-base-100 p-6 transition duration-200 hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-lg"
              >
                <.icon name="hero-cube-transparent" class="mb-6 size-8 text-primary" /><h2 class="text-xl font-semibold">
                  {app.name}
                </h2><p class="mt-2 text-sm text-base-content/50">{app.slug}</p><p class="mt-6 inline-flex items-center gap-2 text-xs font-semibold">
                  Open app <.icon name="hero-arrow-up-right" class="size-4" />
                </p>
              </.link>
            </section>
            <.form
              :if={@can_write?}
              for={@new_app_form}
              id="new-app-form"
              phx-change="validate_app"
              phx-submit="create_app"
              class="h-fit rounded-2xl border border-base-300 bg-base-100 p-6"
            >
              <.input field={@new_app_form[:operation_key]} type="hidden" />
              <h2 class="mb-6 text-lg font-semibold">Create an app</h2><.input
                field={@new_app_form[:name]}
                label="App name"
                required
                maxlength="160"
              /><.input
                field={@new_app_form[:slug]}
                label="URL name"
                placeholder="team-app"
                required
                maxlength="80"
              /><.input
                field={@new_app_form[:repository]}
                label="Repository (optional)"
                placeholder="owner/repository"
              /><p class="mb-5 text-xs leading-6 text-base-content/55">
                Python frontend and SQLite. Code releases and customer data live independently.
              </p><button
                id="create-app"
                class="btn btn-primary w-full"
                phx-disable-with="Creating…"
              >Create app <.icon name="hero-plus" class="size-4" /></button>
            </.form>
          </div>
        <% else %>
          <%= if @app do %>
            <.link
              navigate={~p"/apps"}
              class="mb-6 inline-flex items-center gap-2 text-sm text-base-content/60"
            ><.icon name="hero-arrow-left" class="size-4" />Apps</.link>
            <header class="mb-8 flex flex-wrap items-center justify-between gap-4">
              <div>
                <p class="text-xs uppercase tracking-widest text-base-content/50">{@app.slug}</p><h1
                  id="app-title"
                  class="mt-2 text-3xl font-semibold tracking-tight"
                >
                  {@app.name}
                </h1>
              </div><nav class="flex gap-2">
                <.link
                  id="app-overview-tab"
                  navigate={~p"/apps/#{@app.id}"}
                  class="btn btn-ghost btn-sm"
                >Overview</.link><.link
                  id="app-build-tab"
                  navigate={~p"/apps/#{@app.id}/build"}
                  class="btn btn-primary btn-sm"
                >Build <.icon name="hero-sparkles" class="size-4" /></.link>
              </nav>
            </header>
            <%= if @live_action == :build do %>
              <div class="grid gap-8 lg:grid-cols-[1fr_360px]">
                <section class="min-w-0">
                  <div class="mb-6 flex items-center justify-between gap-4">
                    <h2 class="text-xl font-semibold">Build conversation</h2><.link
                      :if={@conversation}
                      id="full-app-conversation"
                      navigate={~p"/agents/#{@conversation.id}"}
                      class="text-xs font-semibold text-primary"
                    >Full history <.icon name="hero-arrow-up-right" class="size-3" /></.link>
                  </div>
                  <.form
                    :if={is_nil(@conversation) and @can_write?}
                    for={@release_form}
                    id="start-app-build-form"
                    phx-submit="start_build"
                    class="mb-5 rounded-2xl border border-base-300 p-5"
                  >
                    <.input
                      :if={@app.repository}
                      field={@release_form[:source_commit]}
                      label="Repository starting commit"
                      placeholder="Full 40-character commit SHA"
                      required
                      maxlength="40"
                    /><button
                      :if={not @connections_loaded?}
                      id="load-app-coding-connections"
                      type="button"
                      phx-click="load_connections"
                      phx-disable-with="Loading…"
                      class="btn btn-ghost btn-sm mb-5"
                    >Choose connected accounts</button>
                    <div :if={@connections_loaded?} class="mb-5">
                      <.input
                        field={@release_form[:openai_account_id]}
                        type="select"
                        label="Coding account"
                        prompt="Use the only eligible account"
                        options={@openai_accounts}
                      /><.input
                        :if={@app.repository}
                        field={@release_form[:github_account_id]}
                        type="select"
                        label="GitHub account"
                        prompt="Use the only eligible account"
                        options={@github_accounts}
                      />
                    </div><button
                      id="start-app-build"
                      type="submit"
                      phx-disable-with="Starting…"
                      class="btn btn-primary"
                    >Start building</button>
                  </.form>
                  <div id="app-build-turns" phx-update="stream" class="space-y-4">
                    <article
                      :for={{id, turn} <- @streams.turns}
                      id={id}
                      class="rounded-2xl border border-base-300 bg-base-100 p-5"
                    >
                      <div class="flex items-center justify-between">
                        <span class="text-xs font-semibold text-base-content/50">REQUEST</span><span
                          role="status"
                          class="badge badge-outline badge-sm"
                        >{turn.status}</span>
                      </div><p class="mt-4 whitespace-pre-wrap text-sm leading-7">
                        {turn.instructions}
                      </p><p
                        :if={turn.result}
                        class="mt-4 border-t border-base-200 pt-4 text-sm leading-7"
                      >
                        {Map.get(turn.result, "summary", "")}
                      </p><button
                        :if={@can_write? and not Agents.Turn.terminal?(turn)}
                        id={"app-stop-turn-#{turn.id}"}
                        phx-click="stop_turn"
                        phx-value-id={turn.id}
                        class="btn btn-ghost btn-xs mt-3"
                      >Stop task</button>
                    </article>
                  </div>
                  <.form
                    :if={@conversation && @can_write?}
                    for={@build_form}
                    id="app-build-form"
                    phx-change="validate_build"
                    phx-submit="submit_build"
                    class="mt-6 rounded-2xl border border-base-300 p-5"
                  >
                    <.input
                      field={@build_form[:instructions]}
                      label="Describe what to build"
                      type="textarea"
                      rows="5"
                      maxlength="32000"
                      required
                    /><div class="grid gap-4 sm:grid-cols-2">
                      <.input
                        field={@build_form[:budget_cents]}
                        label="Budget (cents)"
                        type="number"
                        min="1"
                        max="10000"
                      /><.input
                        field={@build_form[:timeout_seconds]}
                        label="Time limit (seconds)"
                        type="number"
                        min="30"
                        max="3600"
                      />
                    </div><button
                      id="submit-app-build"
                      class="btn btn-primary w-full"
                      phx-disable-with="Sending…"
                    >Send task <.icon name="hero-arrow-up" class="size-4" /></button>
                  </.form>
                  <h3 class="mb-3 mt-8 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                    Recorded activity
                  </h3><div id="app-build-events" phx-update="stream" class="space-y-2">
                    <div
                      :for={{id, event} <- @streams.events}
                      id={id}
                      class="rounded-xl border border-base-200 p-3 text-xs"
                    >
                      <p class="font-semibold">{event.type |> String.replace(".", " ")}</p><p class="mt-1 break-words text-base-content/60">
                        {Map.get(event.payload, "message", Map.get(event.payload, "summary", ""))}
                      </p>
                    </div>
                  </div>
                </section>
                <aside class="space-y-6">
                  <section class="rounded-2xl border border-base-300 bg-base-100 p-5">
                    <h2 class="text-lg font-semibold">Preview & release</h2><p class="mt-2 text-xs leading-6 text-base-content/60">
                      Use a committed revision from the conversation. Loading a preview or preparing a release starts workspace activity.
                    </p><.form
                      :if={@conversation}
                      for={@release_form}
                      id="app-release-form"
                      phx-change="validate_release"
                      phx-submit="prepare_release"
                      class="mt-5"
                    >
                      <.input
                        field={@release_form[:source_commit]}
                        label="Source commit"
                        placeholder="Full 40-character commit"
                        required
                        maxlength="40"
                      /><button
                        :if={@can_write?}
                        id="load-app-preview"
                        type="submit"
                        name="release[action]"
                        value="preview"
                        phx-disable-with="Verifying…"
                        class="btn btn-outline mb-3 w-full"
                      >Load preview <.icon name="hero-eye" class="size-4" /></button><button
                        :if={@can_deploy?}
                        id="prepare-app-release"
                        type="submit"
                        phx-disable-with="Building & checking…"
                        class="btn btn-primary w-full"
                      >Prepare release</button>
                    </.form>
                    <div :if={@preview} class="mt-5 border-t border-base-200 pt-5">
                      <p class="text-xs text-success">
                        Preview verified · {String.slice(@preview.source_commit, 0, 8)}
                      </p><.link
                        id="open-app-preview"
                        href={~p"/apps/#{@app.id}/previews/#{@preview.id}/open"}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-outline btn-sm mt-3 w-full"
                      >Open preview <.icon name="hero-arrow-up-right" class="size-4" /></.link><button
                        id="share-app-preview"
                        phx-click="share_preview"
                        class="btn btn-ghost btn-sm mt-2 w-full"
                      >Share for 24 hours</button><p
                        :if={@share_url}
                        id="app-share-url"
                        class="mt-3 break-all text-xs"
                      >
                        {@share_url}
                      </p>
                    </div>
                  </section>
                  <section class="rounded-2xl border border-base-300 p-5">
                    <h3 class="font-semibold">Production</h3><p
                      id="build-environment-state"
                      role="status"
                      class="mt-3 text-sm text-base-content/60"
                    >
                      {@environment.status}
                    </p><p class="mt-4 text-xs leading-6 text-base-content/55">
                      Preview data stays in the build workspace. Publishing preserves production's database and uploads.
                    </p>
                  </section>
                </aside>
              </div>
            <% else %>
              <%= if @live_action == :deployment and @deployment do %>
                <section id="deployment-detail" class="mb-8 rounded-2xl border border-base-300 p-6">
                  <div class="flex flex-wrap items-center justify-between gap-4">
                    <h2 class="text-xl font-semibold">Deployment</h2><span
                      id="deployment-status"
                      class="badge badge-outline"
                      role="status"
                    >{@deployment.status}</span>
                  </div><dl class="mt-6 grid gap-6 sm:grid-cols-2">
                    <div>
                      <dt class="text-xs text-base-content/50">Source commit</dt><dd
                        id="deployment-source"
                        class="mt-1 break-all font-mono text-xs"
                      >
                        {@deployment.source_commit}
                      </dd>
                    </div><div>
                      <dt class="text-xs text-base-content/50">Artifact digest</dt><dd class="mt-1 break-all font-mono text-xs">
                        {@deployment.artifact_digest}
                      </dd>
                    </div><div>
                      <dt class="text-xs text-base-content/50">Configuration digest</dt><dd class="mt-1 break-all font-mono text-xs">
                        {@deployment.configuration_digest}
                      </dd>
                    </div><div>
                      <dt class="text-xs text-base-content/50">Served revision</dt><dd
                        id="deployment-served-revision"
                        class="mt-1 break-all font-mono text-xs"
                      >
                        {Map.get(@deployment.verification, "served_revision", "Awaiting verification")}
                      </dd>
                    </div>
                  </dl><p
                    :if={@deployment.error != %{}}
                    id="deployment-error"
                    class="mt-5 text-sm text-error"
                  >
                    {Map.get(@deployment.error, "reason")}
                  </p><button
                    :if={@can_deploy? and @deployment.status in ["superseded", "active"]}
                    id="rollback-app-code"
                    phx-click="prepare_rollback"
                    class="btn btn-outline btn-sm mt-6"
                  >Prepare code rollback</button>
                </section>
              <% end %>
              <div class="grid gap-8 lg:grid-cols-[1fr_340px]">
                <div class="space-y-8">
                  <section>
                    <h2 class="mb-4 text-xl font-semibold">Environments</h2><div
                      id="app-environments"
                      phx-update="stream"
                      class="space-y-4"
                    >
                      <article
                        :for={{id, environment} <- @streams.environments}
                        id={id}
                        class="rounded-2xl border border-base-300 p-5"
                      >
                        <div class="flex items-center justify-between">
                          <h3 class="font-semibold">{environment.name}</h3><span
                            class="badge badge-outline badge-sm"
                            role="status"
                          >{environment.status}</span>
                        </div><p class="mt-3 text-xs leading-6 text-base-content/50">
                          Persistent SQLite and uploads · separate release workspace
                        </p><.link
                          :if={
                            is_binary(environment.active_deployment_id) and
                              environment.status == "running"
                          }
                          id={"open-published-app-#{environment.id}"}
                          href={~p"/apps/#{@app.id}/environments/#{environment.id}/open"}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="btn btn-outline btn-sm mt-4"
                        >Open app <.icon name="hero-arrow-up-right" class="size-4" /></.link><p class="mt-3 text-xs text-base-content/60">
                          {if(environment.public,
                            do: "Public URL access enabled",
                            else: "Private access"
                          )}
                        </p><p :if={environment.active_deployment_id} class="mt-3 font-mono text-xs">
                          {environment.active_deployment_id}
                        </p>
                      </article>
                    </div>
                  </section>
                  <section>
                    <h2 class="mb-4 text-xl font-semibold">Deployment history</h2><div
                      id="app-deployments"
                      phx-update="stream"
                      class="space-y-3"
                    >
                      <p
                        id="no-deployments"
                        class="hidden rounded-xl border border-dashed border-base-300 p-6 text-sm text-base-content/50 only:block"
                      >
                        Prepare a release from Build to publish this app.
                      </p><.link
                        :for={{id, deployment} <- @streams.deployments}
                        id={id}
                        navigate={~p"/apps/#{@app.id}/deployments/#{deployment.id}"}
                        class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-base-300 p-4 transition hover:border-primary/40"
                      ><span class="font-mono text-sm">{String.slice(deployment.source_commit, 0, 8)}</span><span class="badge badge-outline badge-sm">{deployment.status}</span></.link>
                    </div>
                  </section>
                  <section>
                    <h2 class="mb-4 text-xl font-semibold">Workflows</h2><div
                      id="app-workflows"
                      phx-update="stream"
                      class="space-y-3"
                    >
                      <p id="no-app-workflows" class="hidden text-sm text-base-content/50 only:block">
                        Workflows that reference this app or its environments appear here.
                      </p><.link
                        :for={{id, workflow} <- @streams.workflows}
                        id={id}
                        navigate={"/workflows/" <> workflow.id}
                        class="flex items-center justify-between gap-3 rounded-xl border border-base-300 p-4 transition hover:border-primary/40"
                      ><span class="text-sm font-medium">{workflow.name}</span><span class="badge badge-outline badge-sm">{workflow.status}</span></.link>
                    </div>
                  </section><section>
                    <h2 class="mb-4 text-xl font-semibold">Recorded logs</h2><div
                      id="app-logs"
                      phx-update="stream"
                      class="space-y-3"
                    >
                      <p id="no-app-logs" class="hidden text-sm text-base-content/50 only:block">
                        Diagnostic evidence appears after builds and deployments.
                      </p><article
                        :for={{id, log} <- @streams.logs}
                        id={id}
                        class="rounded-xl bg-base-200/70 p-4"
                      >
                        <span class="text-xs font-semibold">{log.kind}</span><pre class="mt-2 overflow-auto whitespace-pre-wrap break-all text-xs leading-6">{log.content}</pre>
                      </article>
                    </div>
                  </section>
                </div>
                <aside>
                  <.form
                    :if={@can_write?}
                    for={@environment_form}
                    id="app-environment-form"
                    phx-submit="save_environment"
                    class="rounded-2xl border border-base-300 p-5"
                  >
                    <h2 class="mb-5 font-semibold">Production settings</h2><.input
                      field={@environment_form[:display_name]}
                      label="Display name"
                      maxlength="120"
                    /><.input
                      field={@environment_form[:backup_interval_hours]}
                      label="Backup interval (hours)"
                      type="number"
                      min="1"
                      max="168"
                      required
                    /><button
                      id="save-app-environment"
                      class="btn btn-outline btn-sm w-full"
                      phx-disable-with="Saving…"
                    >Save configuration</button>
                  </.form><button
                    :if={@can_deploy? and @environment.active_deployment_id}
                    id="backup-app-data"
                    phx-click="backup_environment"
                    phx-disable-with="Exporting & verifying…"
                    class="btn btn-outline btn-sm mt-4 w-full"
                  >Back up production data</button><.link
                    :if={@public_url}
                    id="published-app-url"
                    href={@public_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="mt-4 block break-all text-xs text-primary"
                  >{@public_url}</.link><button
                    :if={@can_deploy? and @environment.active_deployment_id}
                    id="prepare-app-public-access"
                    phx-click="prepare_publication"
                    class="btn btn-ghost btn-sm mt-4 w-full"
                  >{if(@environment.public,
                    do: "Change to private access",
                    else: "Change to public access"
                  )}</button><.form
                    :if={@can_deploy? and @backup_options != []}
                    for={@recovery_form}
                    id="app-data-recovery-form"
                    phx-submit="prepare_recovery"
                    class="mt-6 rounded-2xl border border-base-300 p-5"
                  >
                    <h3 class="mb-4 font-semibold">Data recovery</h3><.input
                      field={@recovery_form[:backup_id]}
                      type="select"
                      label="Verified backup"
                      options={@backup_options}
                      required
                    /><p class="mb-4 text-xs leading-6 text-base-content/55">
                      Restoring a backup replaces the current database and uploads. Confirm the exact backup before restoring.
                    </p><button id="prepare-app-data-recovery" class="btn btn-outline btn-sm w-full">Prepare restoration</button>
                  </.form><p
                    :if={@recovery}
                    id="app-data-recovery-status"
                    class="mt-4 text-sm"
                    role="status"
                  >
                    Recovery: {@recovery.status}
                  </p><p class="mt-4 text-xs leading-6 text-base-content/55">
                    Reading this page keeps environments asleep. Data restoration requires an explicit request.
                  </p>
                </aside>
              </div>
            <% end %>
            <section
              :if={@prepared}
              id="deployment-confirmation"
              class="mt-8 rounded-2xl border border-primary/30 bg-primary/5 p-6"
            >
              <h2 class="text-xl font-semibold">Confirm {action_label(@prepared.action)}</h2><p class="mt-3 text-sm leading-7">
                Source
                <span class="font-mono">{String.slice(@prepared.input.source_commit, 0, 8)}</span>
                · production · current release {String.slice(
                  @prepared.input.expected_active_deployment || "none",
                  0,
                  8
                )}
              </p><p class="mt-3 break-all font-mono text-xs text-base-content/60">
                {@prepared.input.artifact_digest}
              </p><ul class="mt-4 space-y-2 text-xs text-base-content/60">
                <li :for={check <- @prepared.checks}>
                  <.icon name="hero-check-circle" class="mr-2 size-4 text-success" />{check}
                </li>
              </ul><p :if={@prepared.action in [:deploy, :rollback]} class="mt-4 text-sm">
                Customer data remains in production. The release performs a verified independent backup before switching.
              </p><p :if={@prepared.action == :restore} class="mt-4 text-sm text-error">
                This recovery replaces current data. Writes made after the selected backup will be removed.
              </p><button
                :if={@can_deploy?}
                id="confirm-app-action"
                phx-click="confirm_action"
                phx-disable-with="Admitting…"
                class="btn btn-primary mt-5"
              >Confirm {action_label(@prepared.action)}</button>
            </section>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
