defmodule Hermitscale.Triggers.Supervisor do
  @moduledoc """
  Root of the trigger runtime.

  `:rest_for_one`: if the registry dies, the source supervisor, reconciler,
  and scheduler restart after it, and the reconciler's initial sync rebuilds
  every source process from the desired state in Postgres.

  The reconciler and scheduler are gated behind the `:start_runtime?` config
  flag (disabled in tests, where they are started per-test inside the SQL
  sandbox).
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:hermitscale, Hermitscale.Triggers, [])

    children =
      [
        {Registry, keys: :unique, name: Hermitscale.Triggers.Registry},
        {DynamicSupervisor, name: Hermitscale.Triggers.SourceSupervisor, strategy: :one_for_one}
      ] ++ runtime_children(Keyword.get(config, :start_runtime?, true))

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp runtime_children(true),
    do: [Hermitscale.Triggers.Reconciler, Hermitscale.Triggers.Scheduler]

  defp runtime_children(false), do: []
end
