defmodule HermitscaleWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HermitscaleWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh bg-slate-50 text-slate-950 dark:bg-slate-950 dark:text-slate-100">
      <header class="sticky top-0 z-40 border-b border-slate-200/80 bg-white/85 backdrop-blur-xl dark:border-slate-800 dark:bg-slate-950/80">
        <div class="mx-auto flex h-16 max-w-7xl items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <.link
            href={~p"/"}
            id="app-home-link"
            class="group inline-flex items-center gap-3 rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-slate-950"
          >
            <span class="flex size-9 items-center justify-center rounded-xl bg-slate-950 shadow-sm transition group-hover:-translate-y-0.5 dark:bg-white">
              <.icon name="hero-bolt" class="size-5 text-emerald-400 dark:text-emerald-600" />
            </span>
            <span>
              <span class="block text-sm font-semibold tracking-tight text-slate-950 dark:text-white">Hermitscale</span>
              <span class="block text-[10px] font-medium uppercase tracking-[0.16em] text-slate-500 dark:text-slate-400">Automation OS</span>
            </span>
          </.link>

          <nav id="app-navigation" class="flex items-center gap-1.5" aria-label="Primary navigation">
            <%= if @current_scope && @current_scope.user do %>
              <.link
                href={~p"/"}
                class="hidden rounded-lg px-3 py-2 text-sm font-medium text-slate-600 transition hover:bg-slate-100 hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-white sm:inline-flex"
              >
                Workflows
              </.link>
              <.link
                href={~p"/users/settings"}
                class="hidden rounded-lg px-3 py-2 text-sm font-medium text-slate-600 transition hover:bg-slate-100 hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-white sm:inline-flex"
              >
                Settings
              </.link>
              <span
                :if={@current_scope.organization}
                id="current-organization-name"
                class="hidden max-w-44 items-center gap-1.5 truncate rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs font-semibold text-emerald-800 dark:border-emerald-900/70 dark:bg-emerald-950/50 dark:text-emerald-300 md:inline-flex"
                title={@current_scope.organization.name}
              >
                <.icon name="hero-building-office-2-micro" class="size-3.5 shrink-0" />
                <span class="truncate">{@current_scope.organization.name}</span>
              </span>
              <span
                id="current-user-email"
                class="hidden max-w-44 truncate rounded-lg bg-slate-100 px-3 py-2 text-xs font-medium text-slate-600 dark:bg-slate-900 dark:text-slate-300 lg:inline-flex"
              >
                {@current_scope.user.email}
              </span>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                id="log-out-link"
                class="rounded-lg px-3 py-2 text-sm font-semibold text-slate-700 transition hover:bg-slate-100 hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-200 dark:hover:bg-slate-800 dark:hover:text-white"
              >
                Log out
              </.link>
            <% else %>
              <.link
                href={~p"/users/log-in"}
                id="log-in-link"
                class="rounded-lg px-3 py-2 text-sm font-semibold text-slate-700 transition hover:bg-slate-100 hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-200 dark:hover:bg-slate-800 dark:hover:text-white"
              >
                Log in
              </.link>
              <.link
                href={~p"/users/register"}
                id="register-link"
                class="hidden rounded-lg bg-slate-950 px-3.5 py-2 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-slate-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:ring-offset-2 dark:bg-white dark:text-slate-950 dark:hover:bg-slate-200 dark:focus-visible:ring-offset-slate-950 sm:inline-flex"
              >
                Create account
              </.link>
            <% end %>
            <.theme_toggle />
          </nav>
        </div>
      </header>

      <main class="px-4 py-10 sm:px-6 sm:py-14 lg:px-8">
        <div class="mx-auto max-w-7xl">
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer class="border-t border-slate-200/80 px-4 py-6 dark:border-slate-800 sm:px-6 lg:px-8">
        <div class="mx-auto flex max-w-7xl items-center justify-between gap-4 text-xs text-slate-500 dark:text-slate-400">
          <span>Hermitscale workflow control plane</span>
          <span class="hidden sm:inline">Securely scoped to the active organization</span>
        </div>
      </footer>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  The bundled app.js persists the choice and applies the matching data attributes.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="relative ml-1 flex items-center rounded-full border border-slate-200 bg-slate-100 p-0.5 dark:border-slate-700 dark:bg-slate-900"
    >
      <div class="pointer-events-none absolute left-0.5 top-0.5 size-7 rounded-full bg-white shadow-sm ring-1 ring-slate-950/5 transition-transform duration-200 [[data-theme=light]_&]:translate-x-7 [[data-theme=dark]_&]:translate-x-14 [[data-theme-source=system]_&]:!translate-x-0 dark:bg-slate-700 dark:ring-white/10" />

      <button
        id="theme-system"
        type="button"
        class="relative z-10 flex size-7 cursor-pointer items-center justify-center rounded-full text-slate-500 transition hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-400 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5" />
      </button>

      <button
        id="theme-light"
        type="button"
        class="relative z-10 flex size-7 cursor-pointer items-center justify-center rounded-full text-slate-500 transition hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-400 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-3.5" />
      </button>

      <button
        id="theme-dark"
        type="button"
        class="relative z-10 flex size-7 cursor-pointer items-center justify-center rounded-full text-slate-500 transition hover:text-slate-950 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 dark:text-slate-400 dark:hover:text-white"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-3.5" />
      </button>
    </div>
    """
  end
end
