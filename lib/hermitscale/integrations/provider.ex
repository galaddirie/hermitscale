defmodule Hermitscale.Integrations.Provider do
  @moduledoc """
  Behaviour and registry for credential providers.

  Providers resolve persisted credential references into short-lived runtime
  tokens. The graph stores references; only this provider layer handles token
  material.
  """

  @app :hermitscale
  @cache_key {__MODULE__, :index}

  @callback provider_id() :: String.t()
  @callback fetch_token(ref :: map(), scopes :: [String.t()]) ::
              {:ok,
               %{
                 required(:access_token) => String.t(),
                 optional(:expires_at) => DateTime.t() | nil
               }}
              | {:error, term()}
  @callback network_domains() :: [String.t()]

  @typedoc """
  Static provider descriptor consumed by `Hermitscale.Credentials`.

  `methods` declares every auth method the provider supports — the GitHub
  case: both `:oauth` and `:api_key`. For `:oauth`, `refresh: :rotating` flags
  providers whose refresh responses invalidate the previous refresh token, so
  the shared refresh path persists the new one before first use. For
  `:api_key`, `auth` is how the key is presented: `:bearer` or
  `{:header, name}`.
  """
  @type spec :: %{
          required(:id) => String.t(),
          required(:methods) => %{
            optional(:oauth) => %{
              required(:authorize_url) => String.t(),
              required(:token_url) => String.t(),
              optional(:default_scopes) => [String.t()],
              optional(:refresh) => :standard | :rotating | :none
            },
            optional(:api_key) => %{required(:auth) => :bearer | {:header, String.t()}},
            optional(:custom) => %{optional(:fields) => [String.t()]}
          }
        }

  @callback spec() :: spec()

  @optional_callbacks spec: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour Hermitscale.Integrations.Provider

      def __integration_provider__, do: provider_id()
    end
  end

  @doc """
  Returns the cached provider index keyed by provider id.
  """
  def index do
    case :persistent_term.get(@cache_key, :missing) do
      :missing -> refresh!()
      index -> index
    end
  end

  @doc """
  Rebuilds the provider index from loaded application modules.
  """
  def refresh! do
    {:ok, modules} = :application.get_key(@app, :modules)

    index =
      Enum.reduce(modules, %{}, fn module, acc ->
        if provider?(module) do
          provider_id = module.__integration_provider__()
          assert_provider_id!(provider_id, module)

          case Map.fetch(acc, provider_id) do
            {:ok, existing} ->
              raise ArgumentError,
                    "duplicate integration provider #{provider_id}: " <>
                      "#{inspect(existing)} and #{inspect(module)}"

            :error ->
              Map.put(acc, provider_id, module)
          end
        else
          acc
        end
      end)

    :persistent_term.put(@cache_key, index)
    index
  end

  @doc """
  Fetches a provider module by id.
  """
  def fetch(index \\ index(), provider_id) when is_binary(provider_id) do
    case Map.fetch(index, provider_id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Fetches a provider module by id or raises.
  """
  def fetch!(index \\ index(), provider_id) when is_binary(provider_id) do
    case fetch(index, provider_id) do
      {:ok, module} ->
        module

      {:error, :not_found} ->
        raise ArgumentError, "integration provider #{provider_id} not found in deployed code"
    end
  end

  @doc """
  Resolves a credential reference through its provider.
  """
  def fetch_token(provider_id, ref, scopes \\ [])
      when is_binary(provider_id) and is_map(ref) and is_list(scopes) do
    provider_id
    |> fetch!()
    |> apply(:fetch_token, [ref, scopes])
  end

  @doc """
  Returns the declared network domains for a provider.
  """
  def network_domains(provider_id) when is_binary(provider_id) do
    provider_id
    |> fetch!()
    |> apply(:network_domains, [])
  end

  @doc """
  Returns a provider's static spec, or `{:error, :no_spec}` for legacy
  providers that predate the credential system.
  """
  def spec(provider_id) when is_binary(provider_id) do
    with {:ok, module} <- fetch(provider_id) do
      if function_exported?(module, :spec, 0) do
        {:ok, module.spec()}
      else
        {:error, :no_spec}
      end
    end
  end

  defp provider?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__integration_provider__, 0)
  end

  defp assert_provider_id!(provider_id, _module) when is_binary(provider_id), do: :ok

  defp assert_provider_id!(provider_id, module) do
    raise ArgumentError,
          "#{inspect(module)} returned invalid provider_id #{inspect(provider_id)}"
  end
end
