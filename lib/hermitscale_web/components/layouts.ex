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
    <header class="border-b border-base-300 bg-base-100 px-4 sm:px-6 lg:px-8">
      <div class="mx-auto flex min-h-20 max-w-6xl flex-wrap items-center justify-between gap-4 py-4">
        <a
          href={~p"/"}
          id="brand-home"
          class="inline-flex items-center gap-2 font-semibold tracking-tight"
        >
          <span class="flex size-8 items-center justify-center rounded-lg bg-base-content text-base-100"><.icon
            name="hero-command-line"
            class="size-5"
          /></span>
          Hermitscale
        </a>
        <nav
          aria-label="Main navigation"
          class="flex w-full flex-wrap items-center gap-x-4 gap-y-3 sm:w-auto sm:gap-x-5"
        >
          <%= if @current_scope do %>
            <.link
              navigate={~p"/agents"}
              id="nav-conversations"
              class="text-sm font-medium hover:text-primary"
            >Conversations</.link>
            <.link navigate={~p"/apps"} id="nav-apps" class="text-sm font-medium hover:text-primary">Apps</.link>
            <.link
              navigate={~p"/reviews"}
              id="nav-reviews"
              class="text-sm font-medium hover:text-primary"
            >Reviews</.link>
            <.link
              navigate={~p"/workflows"}
              id="nav-workflows"
              class="text-sm font-medium hover:text-primary"
            >Workflows</.link>
            <span class="hidden max-w-48 truncate text-xs text-base-content/55 sm:block">{Map.get(
              @current_scope.user,
              :email
            ) || @current_scope.user.id}</span>
            <.link
              href={~p"/auth/logout"}
              method="delete"
              id="nav-sign-out"
              class="btn btn-ghost btn-sm"
            >Sign out</.link>
          <% else %>
            <.link href={~p"/auth/login"} id="nav-sign-in" class="btn btn-primary btn-sm">Sign in</.link>
          <% end %>
          <.theme_toggle />
        </nav>
      </div>
    </header>

    <main class="min-h-[calc(100vh-5rem)] bg-base-200/35 px-4 py-8 sm:px-6 sm:py-12 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
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

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        id="theme-system"
        type="button"
        aria-label="Use system theme"
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        id="theme-light"
        type="button"
        aria-label="Use light theme"
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        id="theme-dark"
        type="button"
        aria-label="Use dark theme"
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
