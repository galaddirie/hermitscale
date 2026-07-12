defmodule Hermitscale.Auth.Providers.LocalTest do
  use ExUnit.Case, async: true
  use Hermitscale.Auth.IdentityProviderCase

  setup do
    %{provider: Hermitscale.Auth.Providers.Local}
  end

  test "identifies as local with in-app capabilities" do
    provider = Hermitscale.Auth.Providers.Local

    assert provider.id() == "local"
    assert provider.log_in_path() == "/users/log-in"
    assert :registration in provider.capabilities()
    assert :self_service_settings in provider.capabilities()
    refute :hosted_login in provider.capabilities()
  end
end
