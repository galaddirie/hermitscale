defmodule HermitscaleWeb.ConnectedAccountsLive do
  use HermitscaleWeb, :live_view

  alias Hermitscale.Integrations.ConnectedAccounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="connected-accounts-page" class="mx-auto max-w-5xl space-y-8">
        <header class="flex flex-col gap-5 border-b border-slate-200 pb-7 dark:border-slate-800 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <.link
              id="back-to-settings"
              navigate={~p"/users/settings"}
              class="inline-flex items-center gap-1.5 text-sm font-semibold text-slate-500 transition hover:text-slate-950 dark:text-slate-400 dark:hover:text-white"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Account settings
            </.link>
            <p class="mt-6 text-xs font-semibold uppercase tracking-[0.2em] text-cyan-700 dark:text-cyan-400">
              WorkOS Pipes
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-slate-950 dark:text-white">
              Connected accounts
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-600 dark:text-slate-400">
              Connect third-party services for workflows in <span class="font-semibold text-slate-900 dark:text-slate-200">
                {@current_scope.organization.name}
              </span>.
              Tokens stay in WorkOS and are vended only for an immediate provider request.
            </p>
          </div>

          <span
            id="connection-security-badge"
            class="inline-flex w-fit items-center gap-2 rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-xs font-semibold text-emerald-800 dark:border-emerald-900/70 dark:bg-emerald-950/50 dark:text-emerald-300"
          >
            <.icon name="hero-lock-closed" class="size-4" /> No provider secrets in graphs
          </span>
        </header>

        <div id="connected-account-providers" phx-update="stream" class="grid gap-5">
          <article
            :for={{id, provider} <- @streams.providers}
            id={id}
            class="group overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm shadow-slate-950/5 transition duration-200 hover:border-slate-300 hover:shadow-md dark:border-slate-800 dark:bg-slate-900 dark:hover:border-slate-700"
          >
            <div class="flex flex-col gap-6 p-6 md:flex-row md:items-start md:justify-between">
              <div class="flex min-w-0 gap-4">
                <div class="flex size-12 shrink-0 items-center justify-center rounded-2xl bg-slate-950 text-white shadow-sm dark:bg-white dark:text-slate-950">
                  <.icon name="hero-table-cells" class="size-6" />
                </div>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h2 class="text-lg font-semibold text-slate-950 dark:text-white">
                      {provider.name}
                    </h2>
                    <span class={[
                      "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ring-inset",
                      state_classes(provider.state)
                    ]}>
                      {state_label(provider.state)}
                    </span>
                  </div>
                  <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-600 dark:text-slate-400">
                    {provider.description}
                  </p>

                  <div class="mt-4 flex flex-wrap gap-2">
                    <span
                      :for={scope <- provider.scopes}
                      class="rounded-md bg-slate-100 px-2 py-1 font-mono text-[11px] text-slate-600 dark:bg-slate-800 dark:text-slate-300"
                    >
                      {short_scope(scope)}
                    </span>
                  </div>
                </div>
              </div>

              <div class="shrink-0 md:text-right">
                <.form
                  :if={provider.state in [:not_connected, :needs_reauthorization, :disconnected]}
                  for={provider.form}
                  id={"connect-provider-#{provider.slug}"}
                  action={~p"/users/settings/connected-accounts/#{provider.slug}/connect"}
                  method="post"
                >
                  <.input field={provider.form[:sharing_mode]} type="hidden" />
                  <.button
                    id={"connect-provider-button-#{provider.slug}"}
                    variant="primary"
                    class="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:ring-offset-2 dark:bg-white dark:text-slate-950 dark:hover:bg-slate-100 dark:focus-visible:ring-offset-slate-900 md:w-auto"
                    phx-disable-with="Opening WorkOS…"
                  >
                    <.icon
                      name={
                        if(provider.state == :needs_reauthorization,
                          do: "hero-arrow-path",
                          else: "hero-link"
                        )
                      }
                      class="size-4"
                    />
                    {if(provider.state == :needs_reauthorization,
                      do: "Reconnect",
                      else: "Connect"
                    )}
                  </.button>
                </.form>

                <.link
                  :if={provider.state in [:connected, :disconnecting]}
                  id={"disconnect-provider-#{provider.slug}"}
                  href={~p"/users/settings/connected-accounts/#{provider.slug}"}
                  method="delete"
                  data-confirm="Disconnect this account from Hermitscale?"
                  class={[
                    "inline-flex items-center justify-center gap-2 rounded-xl border px-4 py-2.5 text-sm font-semibold transition focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500",
                    provider.state == :disconnecting &&
                      "pointer-events-none border-amber-300 bg-amber-50 text-amber-700 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300",
                    provider.state == :connected &&
                      "border-rose-200 text-rose-700 hover:-translate-y-0.5 hover:bg-rose-50 dark:border-rose-900 dark:text-rose-300 dark:hover:bg-rose-950/40"
                  ]}
                >
                  <.icon
                    name={
                      if(provider.state == :disconnecting,
                        do: "hero-arrow-path",
                        else: "hero-link-slash"
                      )
                    }
                    class={["size-4", provider.state == :disconnecting && "motion-safe:animate-spin"]}
                  />
                  {if(provider.state == :disconnecting, do: "Disconnecting", else: "Disconnect")}
                </.link>
              </div>
            </div>

            <div
              :if={provider.connection}
              class="border-t border-slate-100 bg-slate-50/70 px-6 py-4 text-xs text-slate-600 dark:border-slate-800 dark:bg-slate-950/40 dark:text-slate-400"
            >
              <div class="grid gap-3 sm:grid-cols-2">
                <p class="inline-flex items-center gap-2">
                  <.icon name="hero-user" class="size-4 text-slate-400" />
                  Granted by {@current_scope.user.email}
                </p>
                <p class="inline-flex items-center gap-2 sm:justify-end">
                  <.icon name="hero-building-office-2" class="size-4 text-slate-400" />
                  {sharing_label(provider.connection.sharing_mode)}
                </p>
              </div>

              <.form
                :if={
                  provider.state == :connected and
                    not @current_scope.organization.personal
                }
                for={provider.sharing_form}
                id={"sharing-provider-#{provider.slug}"}
                action={~p"/users/settings/connected-accounts/#{provider.slug}/sharing"}
                method="patch"
                class="mt-4 grid gap-3 border-t border-slate-200 pt-4 dark:border-slate-800 sm:grid-cols-[1fr_auto] sm:items-end"
              >
                <.input
                  field={provider.sharing_form[:sharing_mode]}
                  type="select"
                  label="Workflow access"
                  options={[
                    {"Private to me", "private"},
                    {"Available to this organization", "organization"}
                  ]}
                  class="block w-full rounded-xl border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 shadow-sm outline-none transition focus:border-emerald-500 focus:ring-2 focus:ring-emerald-500/20 dark:border-slate-700 dark:bg-slate-900 dark:text-white"
                />
                <.button
                  id={"save-sharing-provider-#{provider.slug}"}
                  class="inline-flex items-center justify-center rounded-xl border border-slate-300 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 shadow-sm transition hover:-translate-y-0.5 hover:bg-slate-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200 dark:hover:bg-slate-800"
                  phx-disable-with="Saving…"
                >
                  Save access
                </.button>
              </.form>

              <p
                :if={provider.state == :connected}
                id={"connection-impact-warning-#{provider.slug}"}
                class="mt-3 flex items-start gap-2 text-[11px] leading-5 text-amber-700 dark:text-amber-300"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-3.5 shrink-0" />
                Removing organization access or disconnecting disables dependent triggers.
              </p>
            </div>
          </article>
        </div>

        <aside
          id="provider-revocation-note"
          class="flex gap-3 rounded-2xl border border-amber-200 bg-amber-50/70 p-5 text-sm leading-6 text-amber-900 dark:border-amber-900/60 dark:bg-amber-950/25 dark:text-amber-200"
        >
          <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0" />
          <p>
            Disconnecting deletes the tokens stored by WorkOS and blocks Hermitscale
            immediately. It does not necessarily revoke Hermitscale at the provider; use
            the provider's security settings when complete revocation is required.
          </p>
        </aside>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Connected accounts")
      |> maybe_refresh_intent(params)

    {:ok, load_providers(socket)}
  end

  defp maybe_refresh_intent(socket, %{"intent" => intent}) when is_binary(intent) do
    case ConnectedAccounts.refresh_intent(socket.assigns.current_scope, intent) do
      {:ok, _account} ->
        put_flash(socket, :info, "Connected account is ready.")

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          "The provider authorization is still finishing or could not be verified."
        )
    end
  end

  defp maybe_refresh_intent(socket, _params), do: socket

  defp load_providers(socket) do
    providers =
      socket.assigns.current_scope
      |> ConnectedAccounts.list_for_scope()
      |> Enum.map(&present_provider(&1, socket.assigns.current_scope))

    stream(socket, :providers, providers,
      reset: true,
      dom_id: &"connected-provider-#{&1.id}"
    )
  end

  defp present_provider(provider, scope) do
    state =
      case provider.connection do
        nil -> remote_state(provider.remote)
        connection -> connection.state
      end

    sharing_mode =
      case scope.organization.personal do
        true -> :private
        false -> :organization
      end

    provider
    |> Map.put(:state, state)
    |> Map.put(
      :form,
      to_form(%{"sharing_mode" => Atom.to_string(sharing_mode)}, as: :connection)
    )
    |> Map.put(
      :sharing_form,
      to_form(
        %{
          "sharing_mode" =>
            provider.connection
            |> connection_sharing_mode(sharing_mode)
            |> Atom.to_string()
        },
        as: :connection
      )
    )
  end

  defp connection_sharing_mode(nil, default), do: default
  defp connection_sharing_mode(connection, _default), do: connection.sharing_mode

  defp remote_state(%{"connected_account" => %{"state" => "connected"}}), do: :connected

  defp remote_state(%{"connected_account" => %{"state" => "needs_reauthorization"}}),
    do: :needs_reauthorization

  defp remote_state(_remote), do: :not_connected

  defp state_label(:not_connected), do: "Not connected"
  defp state_label(:pending), do: "Finishing"
  defp state_label(:connected), do: "Connected"
  defp state_label(:needs_reauthorization), do: "Needs attention"
  defp state_label(:disconnecting), do: "Disconnecting"
  defp state_label(:disconnected), do: "Disconnected"

  defp state_classes(:connected),
    do:
      "bg-emerald-50 text-emerald-700 ring-emerald-600/20 dark:bg-emerald-950/60 dark:text-emerald-300 dark:ring-emerald-400/20"

  defp state_classes(:needs_reauthorization),
    do:
      "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-950/60 dark:text-amber-300 dark:ring-amber-400/20"

  defp state_classes(:disconnecting),
    do:
      "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-950/60 dark:text-amber-300 dark:ring-amber-400/20"

  defp state_classes(_state),
    do:
      "bg-slate-100 text-slate-600 ring-slate-500/20 dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-400/20"

  defp short_scope(scope) do
    scope
    |> String.split("/")
    |> List.last()
  end

  defp sharing_label(:organization), do: "Available to this organization"
  defp sharing_label(:private), do: "Private connection"
end
