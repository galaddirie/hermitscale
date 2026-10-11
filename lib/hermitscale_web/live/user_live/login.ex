defmodule HermitscaleWeb.UserLive.Login do
  use HermitscaleWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="authkit-sign-in"
        class="mx-auto grid max-w-5xl overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-xl shadow-slate-950/5 dark:border-slate-800 dark:bg-slate-900 lg:grid-cols-[1.05fr_0.95fr]"
      >
        <div class="relative isolate overflow-hidden bg-slate-950 px-7 py-12 text-white sm:px-12 sm:py-16">
          <div class="absolute -right-20 -top-20 size-72 rounded-full bg-emerald-400/15 blur-3xl">
          </div>
          <div class="absolute -bottom-28 -left-16 size-72 rounded-full bg-cyan-400/10 blur-3xl">
          </div>

          <div class="relative">
            <span class="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-semibold tracking-wide text-emerald-300">
              <.icon name="hero-shield-check" class="size-4" /> Protected by WorkOS
            </span>
            <h1 class="mt-7 max-w-lg text-4xl font-semibold tracking-tight sm:text-5xl">
              Automation that starts with a secure identity.
            </h1>
            <p class="mt-5 max-w-lg text-base leading-7 text-slate-300">
              Sign in through Hermitscale's hosted authentication experience. Passwords,
              social identities, MFA, and recovery stay with WorkOS.
            </p>

            <dl class="mt-10 grid gap-5 text-sm sm:grid-cols-2">
              <div class="rounded-2xl border border-white/10 bg-white/5 p-4">
                <dt class="font-semibold text-white">One secure session</dt>
                <dd class="mt-1 leading-6 text-slate-400">
                  Revocation and session lifetime remain bounded by WorkOS.
                </dd>
              </div>
              <div class="rounded-2xl border border-white/10 bg-white/5 p-4">
                <dt class="font-semibold text-white">Tenant isolation</dt>
                <dd class="mt-1 leading-6 text-slate-400">
                  Every workflow remains scoped to its local organization.
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="flex items-center px-7 py-12 sm:px-12 sm:py-16">
          <div class="w-full">
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-emerald-600 dark:text-emerald-400">
              Welcome to Hermitscale
            </p>
            <h2 class="mt-3 text-3xl font-semibold tracking-tight text-slate-950 dark:text-white">
              <%= if @current_scope do %>
                Confirm your identity
              <% else %>
                Continue securely
              <% end %>
            </h2>
            <p class="mt-3 text-sm leading-6 text-slate-600 dark:text-slate-400">
              <%= if @current_scope do %>
                A sensitive account action needs a fresh authentication check.
              <% else %>
                New here? The same hosted flow lets you create an account.
              <% end %>
            </p>

            <.link
              id="authkit-sign-in-button"
              href={@sign_in_path}
              class="group mt-8 inline-flex w-full items-center justify-center gap-2 rounded-xl bg-slate-950 px-5 py-3.5 text-sm font-semibold text-white shadow-sm transition duration-200 hover:-translate-y-0.5 hover:bg-slate-800 hover:shadow-md focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:ring-offset-2 dark:bg-white dark:text-slate-950 dark:hover:bg-slate-100 dark:focus-visible:ring-offset-slate-900"
            >
              Continue with AuthKit
              <.icon
                name="hero-arrow-right"
                class="size-4 transition-transform group-hover:translate-x-0.5"
              />
            </.link>

            <p class="mt-5 flex items-start gap-2 text-xs leading-5 text-slate-500 dark:text-slate-400">
              <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
              Hermitscale never receives or stores your sign-in password.
            </p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    query =
      []
      |> maybe_put(:return_to, params["return_to"])
      |> maybe_put(:max_age, params["max_age"])

    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:sign_in_path, ~p"/auth/sign-in?#{query}")}
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, key, value)
end
