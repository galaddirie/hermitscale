defmodule Hermitscale.Triggers.Mode.Schedule do
  @moduledoc """
  Contract for schedule-mode triggers.

  Schedule triggers have no process of their own; the trigger scheduler turns
  due rows into Oban jobs, and the job calls `build_payload/2` to produce the
  firing payload. The cron expression itself lives in the trigger params.
  """

  @callback build_payload(params :: map(), scheduled_at :: DateTime.t()) :: map()
end
