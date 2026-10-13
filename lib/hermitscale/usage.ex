defmodule Hermitscale.Usage do
  @moduledoc "Separated usage accounting with stable measurement identity."
  import Ecto.Query
  alias Hermitscale.{Authorization, Repo}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Usage.Entry

  def record(scope, attrs) do
    with :ok <- authorized(scope) do
      cs = Entry.changeset(%Entry{org_id: Scope.organization_id!(scope)}, attrs)

      with {:ok, _} <-
             Repo.insert(cs,
               on_conflict: :nothing,
               conflict_target: [:org_id, :deduplication_key]
             ) do
        requested = Ecto.Changeset.apply_changes(cs)

        stored =
          Repo.get_by!(Entry,
            org_id: requested.org_id,
            deduplication_key: requested.deduplication_key
          )

        fields = [:operation_id, :category, :quantity, :cost_micros, :rate_version]

        if Map.take(stored, fields) == Map.take(requested, fields),
          do: {:ok, stored},
          else: {:error, :usage_key_conflict}
      end
    end
  end

  def summary(scope, operation_id) do
    with :ok <- authorized(scope) do
      org = Scope.organization_id!(scope)

      Repo.all(
        from e in Entry,
          where: e.org_id == ^org and e.operation_id == ^operation_id,
          group_by: e.category,
          select:
            {e.category,
             %{
               quantity: sum(e.quantity),
               cost_micros: sum(e.cost_micros),
               priced: fragment("BOOL_AND(? NOT LIKE '%:unpriced')", e.rate_version)
             }}
      )
      |> Map.new(fn {category, measurements} ->
        quantities = %{
          quantity: Decimal.to_integer(measurements.quantity),
          cost_micros: Decimal.to_integer(measurements.cost_micros)
        }

        quantities =
          if category == :model,
            do: quantities,
            else:
              Map.merge(quantities, %{
                priced: measurements.priced,
                unit: if(category == :compute, do: "milliseconds", else: "logical_file_bytes")
              })

        {category, quantities}
      end)
    end
  end

  @doc false
  def record_worker_measurements(scope, turn_id, worker, result) do
    measurements = [
      {:compute, Map.get(worker, "compute_milliseconds"), "worker-hold-ms-v1:unpriced"},
      {:storage, Map.get(result, "storage_bytes"), "logical-files-bytes-v1:unpriced"}
    ]

    Enum.reduce_while(measurements, :ok, fn
      {_category, nil, _version}, :ok ->
        {:cont, :ok}

      {category, quantity, version}, :ok when is_integer(quantity) and quantity >= 0 ->
        case record(scope, %{
               operation_id: turn_id,
               category: category,
               quantity: quantity,
               cost_micros: 0,
               rate_version: version,
               deduplication_key: "worker:" <> turn_id <> ":" <> Atom.to_string(category)
             }) do
          {:ok, _record} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, :ok ->
        {:halt, {:error, :invalid_worker_measurement}}
    end)
  end

  defp authorized(scope),
    do:
      if(
        Enum.any?(
          ~w(agents:read agents:run apps:read apps:deploy),
          &(Authorization.authorize(scope, &1) == :ok)
        ),
        do: :ok,
        else: {:error, :forbidden}
      )
end
