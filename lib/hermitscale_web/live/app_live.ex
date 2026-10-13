defmodule HermitscaleWeb.AppLive do
  use HermitscaleWeb, :live_view
  alias Hermitscale.{Apps, Authorization}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Apps",
       app: nil,
       can_edit?: false,
       can_publish?: false,
       new_form: to_form(Apps.change_app(socket.assigns.current_scope)),
       service_form: nil
     )
     |> stream(:apps, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Apps.get_app(socket.assigns.current_scope, id) do
      {:ok, app} ->
        if connected?(socket), do: Apps.subscribe(socket.assigns.current_scope, app.id)
        {:noreply, assign_app(socket, app)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "This app is unavailable.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  def handle_params(_params, _url, socket) do
    case Apps.list_apps(socket.assigns.current_scope) do
      apps when is_list(apps) ->
        {:noreply,
         socket
         |> assign(:app, nil)
         |> assign(
           :can_edit?,
           Authorization.authorize(socket.assigns.current_scope, "apps:write") == :ok
         )
         |> stream(:apps, apps, reset: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Your role does not allow viewing apps.")}
    end
  end

  @impl true
  def handle_event("validate_app", %{"app" => attrs}, socket) do
    changeset = Apps.change_app(socket.assigns.current_scope, attrs)
    {:noreply, assign(socket, :new_form, to_form(%{changeset | action: :validate}))}
  end

  def handle_event("create_app", %{"app" => attrs}, socket) do
    case Apps.create_app(socket.assigns.current_scope, attrs) do
      {:ok, app} ->
        {:noreply, push_navigate(socket, to: ~p"/apps/#{app.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("start_build", _params, socket) do
    case Apps.start_build(socket.assigns.current_scope, socket.assigns.app.id, %{}) do
      {:ok, session} -> {:noreply, push_navigate(socket, to: ~p"/agents/#{session.id}")}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("validate_service", %{"service" => attrs}, socket) do
    case Apps.change_service(socket.assigns.current_scope, socket.assigns.app.id, attrs) do
      {:ok, changeset} ->
        {:noreply,
         assign(socket, :service_form, to_form(%{changeset | action: :validate}, as: :service))}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("preview", %{"service" => attrs}, socket) do
    case Apps.ensure_preview(socket.assigns.current_scope, socket.assigns.app.id, attrs) do
      {:ok, app} ->
        {:noreply, socket |> assign_app(app) |> put_flash(:info, "App started privately.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :service_form, to_form(changeset, as: :service))}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("publish", _params, socket) do
    case Apps.publish(socket.assigns.current_scope, socket.assigns.app.id, %{}) do
      {:ok, app} ->
        {:noreply, socket |> assign_app(app) |> put_flash(:info, "The native app URL is public.")}

      {:error, reason} ->
        {:noreply, failure(socket, reason)}
    end
  end

  def handle_event("stop", _params, socket) do
    case Apps.stop(socket.assigns.current_scope, socket.assigns.app.id) do
      {:ok, app} -> {:noreply, socket |> assign_app(app) |> put_flash(:info, "App stopped.")}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  @impl true
  def handle_info({:app_changed, id}, %{assigns: %{app: %{id: id}}} = socket) do
    case Apps.get_app(socket.assigns.current_scope, id) do
      {:ok, app} -> {:noreply, assign_app(socket, app)}
      {:error, reason} -> {:noreply, failure(socket, reason)}
    end
  end

  defp assign_app(socket, app) do
    scope = socket.assigns.current_scope
    owner? = app.created_by_user_id == scope.user.id

    assign(socket,
      app: app,
      page_title: app.name,
      can_edit?: owner? and Authorization.authorize(scope, "apps:write") == :ok,
      can_publish?: owner? and Authorization.authorize(scope, "apps:deploy") == :ok,
      service_form: to_form(Hermitscale.Apps.App.service_changeset(app, %{}), as: :service)
    )
  end

  defp failure(socket, reason) when reason in [:forbidden, :execution_actor_ineligible],
    do: put_flash(socket, :error, "Only the app owner with the required permission can do this.")

  defp failure(socket, :conversation_required),
    do: put_flash(socket, :error, "Open the coding conversation before starting the app.")

  defp failure(socket, _reason),
    do: put_flash(socket, :error, "The action could not finish. Check the command and try again.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl">
        <%= if @app do %>
          <.link
            navigate={~p"/apps"}
            id="all-apps"
            class="inline-flex items-center gap-2 text-sm text-base-content/60 hover:text-primary"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Apps
          </.link>
          <header class="my-8 flex flex-wrap items-center justify-between gap-4">
            <div>
              <h1 class="text-3xl font-semibold tracking-tight">{@app.name}</h1>
              <p :if={@app.repository} class="mt-2 text-sm text-base-content/60">{@app.repository}</p>
            </div>
            <span id="app-service-status" class="badge badge-outline">{@app.service_status}</span>
          </header>
          <div class="grid gap-6 md:grid-cols-[1fr_1.4fr]">
            <section class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
              <h2 class="text-lg font-semibold">Code</h2>
              <p class="mt-2 text-sm leading-6 text-base-content/65">
                Build and edit this app in its retained coding conversation.
              </p>
              <.link
                :if={@can_edit? and @app.session_id}
                navigate={~p"/agents/#{@app.session_id}"}
                id="app-conversation"
                class="btn btn-primary mt-5 w-full"
              >
                Open conversation
              </.link>
              <button
                :if={@can_edit? and is_nil(@app.session_id)}
                id="start-app-build"
                phx-click="start_build"
                phx-disable-with="Opening…"
                class="btn btn-primary mt-5 w-full"
              >
                Open coding conversation
              </button>
              <p :if={not @can_edit?} id="app-owner-only" class="mt-5 text-sm text-base-content/60">
                The app owner manages its code and service.
              </p>
            </section>
            <section class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
              <h2 class="text-lg font-semibold">Run the app</h2>
              <p class="mt-2 text-sm leading-6 text-base-content/65">
                Choose the command and HTTP port for the app in its Sprite.
              </p>
              <.form
                :if={@can_edit?}
                for={@service_form}
                id="app-service-form"
                phx-change="validate_service"
                phx-submit="preview"
                class="mt-5 space-y-4"
              >
                <.input
                  field={@service_form[:start_command]}
                  type="text"
                  label="Start command"
                  placeholder="npm run start"
                />
                <.input
                  field={@service_form[:port]}
                  type="number"
                  label="HTTP port"
                  min="1"
                  max="65535"
                />
                <button
                  id="start-private-app"
                  class="btn btn-primary w-full"
                  phx-disable-with="Starting…"
                >Start privately</button>
              </.form>
              <div :if={@app.service_status == "running"} class="mt-5 space-y-3">
                <.link
                  :if={@app.public}
                  href={@app.native_url}
                  id="open-public-app"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-outline w-full"
                >Open public app</.link>
                <.link
                  :if={not @app.public and @can_edit?}
                  href={~p"/apps/#{@app.id}/open"}
                  id="open-private-app"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-outline w-full"
                >Open private app</.link>
                <p id="app-visibility" class="text-sm text-base-content/60">
                  {if(@app.public,
                    do: "Anyone with the URL can access this app.",
                    else: "Private access is limited to the app owner."
                  )}
                </p>
                <button
                  :if={@can_edit? and @can_publish? and not @app.public}
                  id="publish-app"
                  phx-click="publish"
                  phx-disable-with="Publishing…"
                  class="btn btn-outline w-full"
                >Make public</button>
                <button
                  :if={@can_edit?}
                  id="stop-app"
                  phx-click="stop"
                  phx-disable-with="Stopping…"
                  class="btn btn-ghost w-full"
                >Stop app</button>
              </div>
              <p
                :if={@app.source_commit}
                id="app-source-commit"
                class="mt-5 break-all font-mono text-xs text-base-content/50"
              >
                Git commit: {@app.source_commit}
              </p>
            </section>
          </div>
        <% else %>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">Apps</h1>
            <p class="mt-2 text-base-content/65">
              Your apps, their code, and their native Sprite services.
            </p>
          </header>
          <div class="grid items-start gap-8 md:grid-cols-[1.3fr_1fr]">
            <section id="apps" phx-update="stream" class="space-y-3">
              <p
                id="no-apps"
                class="hidden rounded-2xl border border-dashed border-base-300 p-8 text-sm text-base-content/60 only:block"
              >
                Create an app to get started.
              </p>
              <article
                :for={{id, app} <- @streams.apps}
                id={id}
                class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm transition hover:border-primary/40"
              >
                <.link navigate={~p"/apps/#{app.id}"} class="block">
                  <h2 class="font-semibold">{app.name}</h2>
                  <p class="mt-2 text-sm text-base-content/60">{app.service_status}</p>
                </.link>
              </article>
            </section>
            <section
              :if={@can_edit?}
              class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm"
            >
              <h2 class="text-lg font-semibold">Create an app</h2>
              <.form
                for={@new_form}
                id="new-app-form"
                phx-change="validate_app"
                phx-submit="create_app"
                class="mt-5 space-y-4"
              >
                <.input field={@new_form[:name]} type="text" label="Name" />
                <.input field={@new_form[:slug]} type="text" label="Identifier" placeholder="my-app" />
                <.input
                  field={@new_form[:repository]}
                  type="text"
                  label="GitHub repository (optional)"
                  placeholder="owner/repository"
                />
                <button id="create-app" class="btn btn-primary w-full" phx-disable-with="Creating…">Create app</button>
              </.form>
            </section>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
