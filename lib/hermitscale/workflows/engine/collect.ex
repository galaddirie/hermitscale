defmodule Hermitscale.Workflows.Engine.Collect do
  @moduledoc "Collects ordered terminal item results and closes one map scope."

  alias Runic.Workflow.Components

  @enforce_keys [:name, :parent, :map_id, :hash]
  defstruct [:name, :parent, :map_id, :hash]

  def new(name, parent, map_id) when not is_nil(map_id) do
    %__MODULE__{
      name: name,
      parent: parent,
      map_id: map_id,
      hash: Components.fact_hash({__MODULE__, name, parent, map_id})
    }
  end
end
