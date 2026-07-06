defmodule Hermitscale.Triggers.Builtin.Manual.V1 do
  @moduledoc """
  Trigger fired explicitly by a user or API call.
  """

  use Hermitscale.Triggers.Behaviour,
    id: "trigger.manual",
    version: 1,
    mode: :manual,
    params: []
end
