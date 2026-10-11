defmodule HermitscaleWeb.UserLive.Settings do
  use HermitscaleWeb, :live_view

  alias Hermitscale.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="account-settings" class="mx-auto max-w-5xl space-y-8">
        <header class="border-b border-slate-200 pb-7 dark:border-slate-800">
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-emerald-600 dark:text-emerald-400">
            Identity & access
          </p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight text-slate-950 dark:text-white">
            Account settings
          </h1>
          <p class="mt-2 max-w-2xl text-sm leading-6 text-slate-600 dark:text-slate-400">
            Your authentication profile is managed by WorkOS. Hermitscale keeps only the
            local profile and organization mappings needed to authorize your workflows.
          </p>
        </header>

        <div class="grid gap-6 lg:grid-cols-[1.15fr_0.85fr]">
          <article
            id="workos-profile"
            class="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm shadow-slate-950/5 dark:border-slate-800 dark:bg-slate-900"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
                  WorkOS profile
                </p>
                <h2 class="mt-2 text-xl font-semibold text-slate-950 dark:text-white">
                  {@display_name}
                </h2>
              </div>
              <span class="inline-flex items-center gap-1.5 rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 ring-1 ring-inset ring-emerald-600/20 dark:bg-emerald-950/60 dark:text-emerald-300 dark:ring-emerald-400/20">
                <.icon name="hero-check-badge" class="size-4" /> Verified session
              </span>
            </div>

            <dl class="mt-7 divide-y divide-slate-100 dark:divide-slate-800">
              <div class="grid gap-1 py-4 sm:grid-cols-[9rem_1fr]">
                <dt class="text-sm font-medium text-slate-500 dark:text-slate-400">Email</dt>
                <dd id="settings-user-email" class="text-sm text-slate-950 dark:text-white">
                  {@current_scope.user.email}
                </dd>
              </div>
              <div class="grid gap-1 py-4 sm:grid-cols-[9rem_1fr]">
                <dt class="text-sm font-medium text-slate-500 dark:text-slate-400">
                  Email status
                </dt>
                <dd class="text-sm text-slate-950 dark:text-white">
                  {if(@current_scope.user.email_verified, do: "Verified", else: "Pending")}
                </dd>
              </div>
              <div class="grid gap-1 py-4 sm:grid-cols-[9rem_1fr]">
                <dt class="text-sm font-medium text-slate-500 dark:text-slate-400">
                  Identity source
                </dt>
                <dd class="text-sm text-slate-950 dark:text-white">WorkOS AuthKit</dd>
              </div>
            </dl>

            <div class="mt-5 rounded-xl border border-slate-200 bg-slate-50 p-4 text-sm leading-6 text-slate-600 dark:border-slate-700 dark:bg-slate-950/50 dark:text-slate-400">
              Passwords, login identities, MFA, email verification, and recovery are managed
              in the hosted authentication flow.
            </div>
          </article>

          <aside class="space-y-6">
            <article
              id="connected-accounts-summary"
              class="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm shadow-slate-950/5 dark:border-slate-800 dark:bg-slate-900"
            >
              <div class="flex size-10 items-center justify-center rounded-xl bg-cyan-50 text-cyan-700 dark:bg-cyan-950/60 dark:text-cyan-300">
                <.icon name="hero-link" class="size-5" />
              </div>
              <h2 class="mt-4 text-base font-semibold text-slate-950 dark:text-white">
                Connected accounts
              </h2>
              <p class="mt-2 text-sm leading-6 text-slate-600 dark:text-slate-400">
                Authorize external services for workflow nodes without storing provider
                tokens in workflow definitions.
              </p>
              <.link
                id="manage-connected-accounts"
                navigate={~p"/users/settings/connected-accounts"}
                class="group mt-5 inline-flex items-center gap-2 text-sm font-semibold text-emerald-700 transition hover:text-emerald-600 dark:text-emerald-400 dark:hover:text-emerald-300"
              >
                Manage connections
                <.icon
                  name="hero-arrow-right"
                  class="size-4 transition-transform group-hover:translate-x-0.5"
                />
              </.link>
            </article>

            <article
              id="account-danger-zone"
              class="rounded-2xl border border-rose-200 bg-rose-50/60 p-6 dark:border-rose-900/60 dark:bg-rose-950/20"
            >
              <h2 class="text-base font-semibold text-rose-950 dark:text-rose-200">
                Delete account
              </h2>
              <p class="mt-2 text-sm leading-6 text-rose-800/80 dark:text-rose-300/80">
                This starts a durable cleanup of sessions, connected accounts, and your
                WorkOS identity. A fresh identity check is required.
              </p>
              <.link
                id="delete-account-button"
                href={~p"/users/account"}
                method="delete"
                data-confirm="Delete your Hermitscale account? This cannot be undone."
                class="mt-5 inline-flex items-center justify-center rounded-lg bg-rose-700 px-3.5 py-2 text-sm font-semibold text-white transition hover:-translate-y-0.5 hover:bg-rose-600 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-rose-950"
              >
                Delete account
              </.link>
            </article>
          </aside>
        </div>

        <section
          id="organization-switcher"
          class="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm shadow-slate-950/5 dark:border-slate-800 dark:bg-slate-900"
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 class="text-lg font-semibold text-slate-950 dark:text-white">
                Active organization
              </h2>
              <p class="mt-1 text-sm text-slate-600 dark:text-slate-400">
                Switching changes both the local tenant and WorkOS organization context.
              </p>
            </div>
            <span class="text-xs font-semibold text-slate-500 dark:text-slate-400">
              {@current_scope.organization.name}
            </span>
          </div>

          <div id="settings-organizations" phx-update="stream" class="mt-5 grid gap-3 md:grid-cols-2">
            <article
              :for={{id, organization} <- @streams.organizations}
              id={id}
              class={[
                "flex items-center justify-between gap-4 rounded-xl border p-4 transition",
                organization.id == @current_scope.organization.id &&
                  "border-emerald-300 bg-emerald-50/70 dark:border-emerald-800 dark:bg-emerald-950/30",
                organization.id != @current_scope.organization.id &&
                  "border-slate-200 hover:border-slate-300 dark:border-slate-700 dark:hover:border-slate-600"
              ]}
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-semibold text-slate-950 dark:text-white">
                  {organization.name}
                </p>
                <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  {if(organization.personal, do: "Personal", else: "Shared")}
                </p>
              </div>

              <span
                :if={organization.id == @current_scope.organization.id}
                class="text-xs font-semibold text-emerald-700 dark:text-emerald-300"
              >
                Active
              </span>
              <.link
                :if={organization.id != @current_scope.organization.id}
                id={"switch-organization-#{organization.id}"}
                href={~p"/organizations/#{organization.id}/switch"}
                method="post"
                class="rounded-lg border border-slate-300 px-3 py-2 text-xs font-semibold text-slate-700 transition hover:bg-slate-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800"
              >
                Switch
              </.link>
            </article>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Account settings")
     |> assign(:display_name, display_name(user))
     |> stream(:organizations, Accounts.list_user_organizations(user),
       dom_id: &"settings-organization-#{&1.id}"
     )}
  end

  defp display_name(user) do
    [user.first_name, user.last_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> user.email
      name -> name
    end
  end
end
