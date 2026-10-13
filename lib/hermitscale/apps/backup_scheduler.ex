defmodule Hermitscale.Apps.BackupScheduler do
  @moduledoc false
  use Oban.Worker,
    queue: :apps,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker], states: :incomplete]

  @impl true
  def perform(_job), do: Hermitscale.Apps.schedule_due_backups()
end
