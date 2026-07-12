defmodule Hermitscale.Auth do
  @moduledoc """
  User authentication with pluggable identity providers.

  The active provider is configured instance-wide (see `AUTH_BACKEND` in
  runtime.exs) and answers only "how is identity verified". Session tokens,
  scope resolution, and user records are always local — see
  `Hermitscale.Auth.IdentityProvider` for the split.
  """

  alias Hermitscale.Auth.IdentityProvider

  @doc "The active identity provider module."
  def provider do
    :hermitscale
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:provider, Hermitscale.Auth.Providers.Local)
  end

  @doc "Whether the active provider declares the capability."
  def capability?(capability), do: IdentityProvider.capability?(provider(), capability)

  @doc "Where unauthenticated users are sent to log in."
  def log_in_path, do: provider().log_in_path()
end
