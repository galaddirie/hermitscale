defmodule Hermitscale.Auth.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Hermitscale.Auth
  alias Hermitscale.AuthTest.Provider

  setup do
    variables =
      ~w(AUTH_PROVIDER DATABASE_URL SECRET_KEY_BASE WORKOS_API_KEY WORKOS_CLIENT_ID WORKOS_REDIRECT_URI)

    previous_environment = Map.new(variables, &{&1, System.get_env(&1)})
    previous_auth = Application.fetch_env!(:hermitscale, Auth)

    for variable <- variables, do: System.delete_env(variable)
    System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/hermitscale_test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("test", 16))

    on_exit(fn ->
      Application.put_env(:hermitscale, Auth, previous_auth)

      for {variable, value} <- previous_environment do
        case value do
          nil -> System.delete_env(variable)
          value -> System.put_env(variable, value)
        end
      end
    end)

    :ok
  end

  test "an alternate configured provider boots without WorkOS auth credentials" do
    Application.put_env(:hermitscale, Auth, provider: Provider)
    config = runtime_config()
    assert config[:hermitscale][Auth][:provider] == Provider
    refute config[:hermitscale][Hermitscale.WorkOS.Client][:api_key]
    refute config[:hermitscale][Hermitscale.WorkOS.JWT]
  end

  test "a release can select a compiled provider through the environment" do
    Application.put_env(:hermitscale, Auth, provider: Hermitscale.Auth.WorkOS)
    System.put_env("AUTH_PROVIDER", "Hermitscale.AuthTest.Provider")
    assert runtime_config()[:hermitscale][Auth][:provider] == Provider
  end

  test "the WorkOS provider still requires its auth credentials" do
    Application.put_env(:hermitscale, Auth, provider: Hermitscale.Auth.WorkOS)

    assert_raise RuntimeError, ~r/WORKOS_CLIENT_ID is missing/, fn ->
      runtime_config()
    end
  end

  defp runtime_config do
    Config.Reader.read!(Path.expand("../../../config/runtime.exs", __DIR__), env: :prod)
  end
end
