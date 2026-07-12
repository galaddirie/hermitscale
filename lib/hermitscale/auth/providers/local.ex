defmodule Hermitscale.Auth.Providers.Local do
  @moduledoc """
  The built-in identity provider: phx.gen.auth magic-link + optional
  password flows. Identity verification happens entirely in-app, so this
  module is nearly pure metadata — the actual flows live in the generated
  `Hermitscale.Accounts` functions and auth LiveViews.
  """

  @behaviour Hermitscale.Auth.IdentityProvider

  @impl true
  def id, do: "local"

  @impl true
  def capabilities, do: [:registration, :password, :magic_link, :self_service_settings]

  @impl true
  def log_in_path, do: "/users/log-in"
end
