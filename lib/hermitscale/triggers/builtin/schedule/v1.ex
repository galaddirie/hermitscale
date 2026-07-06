defmodule Hermitscale.Triggers.Builtin.Schedule.V1 do
  @moduledoc """
  Trigger fired on a cron schedule (UTC, standard five-field syntax plus the
  `@daily`-style shorthands Oban supports; `@reboot` is not a schedule).
  """

  use Hermitscale.Triggers.Behaviour,
    id: "trigger.schedule",
    version: 1,
    mode: :schedule,
    params: [
      cron: [type: :string, required: true]
    ]

  alias Oban.Cron.Expression

  @impl true
  def validate_params(%{cron: cron}) do
    case Expression.parse(cron) do
      {:ok, %{reboot?: true}} -> {:error, "@reboot is not a supported schedule"}
      {:ok, _expression} -> :ok
      {:error, error} -> {:error, "invalid cron expression: #{Exception.message(error)}"}
    end
  end
end
