defmodule Hermitscale.AuthTest do
  use Hermitscale.DataCase

  alias Hermitscale.Auth

  describe "provider selection" do
    test "defaults to the Local provider" do
      assert Auth.provider() == Hermitscale.Auth.Providers.Local
    end

    test "capability?/1 and log_in_path/0 delegate to the active provider" do
      assert Auth.capability?(:registration)
      refute Auth.capability?(:hosted_login)
      assert Auth.log_in_path() == "/users/log-in"
    end
  end
end
