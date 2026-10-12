defmodule Hermitscale.Integrations.Provider do
  @moduledoc """
  Discovery and trusted metadata for deployed integrations.
  """

  @app :hermitscale
  @cache_key {__MODULE__, :index}

  @callback provider_id() :: String.t()
  @callback descriptor() :: %{
              slug: String.t(),
              auth_methods: [String.t()],
              authentication: map(),
              destinations: [String.t()]
            }
  @callback network_domains() :: [String.t()]

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

  @doc "Fetches the deployed integration's trusted vending and request metadata."
  def descriptor(provider_id) do
    with {:ok, module} <- fetch(provider_id) do
      {:ok, module.descriptor()}
    else
      {:error, :not_found} -> {:error, :unknown_provider}
    end
  end

  @doc "Checks consent using deployed provider scope implications, including normalized OAuth grants."
  def scopes_satisfied?(descriptor, granted, required) do
    implications = Map.get(descriptor, :scope_implications, %{})
    effective = Enum.flat_map(granted, fn scope -> [scope | Map.get(implications, scope, [])] end)
    Enum.all?(required, &(&1 in effective))
  end

  @doc """
  Returns the declared network domains for a provider.
  """
  def network_domains(provider_id) when is_binary(provider_id) do
    module = fetch!(provider_id)
    module.network_domains()
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
