defmodule HermitscaleWeb.Layouts do
  @moduledoc "Application layouts and flash messages."
  use HermitscaleWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-slate-200">
      <div class="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 px-6 py-5">
        <.link
          href={~p"/"}
          id="app-home-link"
          class="rounded text-lg font-semibold tracking-tight text-slate-950 transition hover:text-orange-600 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-orange-600"
        >
          Hermitscale
        </.link>
        <nav id="app-navigation" aria-label="Account" class="flex items-center gap-4">
          <%= if @current_scope do %>
            <span id="current-user-email" class="text-sm text-slate-600">
              {@current_scope.user.email}
            </span>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              id="log-out-link"
              class="rounded text-sm font-medium text-slate-700 transition hover:text-orange-600 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-orange-600"
            >
              Log out
            </.link>
          <% else %>
            <.link
              href={~p"/auth/sign-in"}
              id="log-in-link"
              class="rounded text-sm font-medium text-slate-700 transition hover:text-orange-600 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-orange-600"
            >
              Log in
            </.link>
          <% end %>
        </nav>
      </div>
    </header>
    <main class="mx-auto max-w-5xl px-6 py-8">
      {render_slot(@inner_block)}
    </main>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

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
end
