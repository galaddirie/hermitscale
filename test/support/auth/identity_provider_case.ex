defmodule Hermitscale.Auth.IdentityProviderCase do
  @moduledoc """
  Conformance suite every identity provider must pass.

  `use` it in a provider's test module and provide a setup returning
  `%{provider: module}`. The suite asserts the
  `Hermitscale.Auth.IdentityProvider` contract: metadata shape and that
  optional callbacks are exported exactly when the matching capability is
  declared.
  """

  @known_capabilities [
    :registration,
    :password,
    :magic_link,
    :self_service_settings,
    :hosted_login,
    :remote_logout
  ]

  def known_capabilities, do: @known_capabilities

  defmacro __using__(_opts) do
    quote do
      describe "identity provider conformance" do
        test "id/0 is a stable non-empty string", %{provider: provider} do
          assert is_binary(provider.id())
          assert provider.id() != ""
        end

        test "capabilities/0 is a subset of the known set", %{provider: provider} do
          capabilities = provider.capabilities()

          assert capabilities -- Hermitscale.Auth.IdentityProviderCase.known_capabilities() == []
        end

        test "log_in_path/0 is an absolute path", %{provider: provider} do
          assert "/" <> _ = provider.log_in_path()
        end

        test "hosted-login callbacks are exported iff :hosted_login is declared",
             %{provider: provider} do
          hosted? = :hosted_login in provider.capabilities()

          assert function_exported?(provider, :authorize_url, 1) == hosted?
          assert function_exported?(provider, :exchange_code, 2) == hosted?
        end

        test "logout_url/2 is exported iff :remote_logout is declared",
             %{provider: provider} do
          remote_logout? = :remote_logout in provider.capabilities()

          assert function_exported?(provider, :logout_url, 2) == remote_logout?
        end
      end
    end
  end
end
