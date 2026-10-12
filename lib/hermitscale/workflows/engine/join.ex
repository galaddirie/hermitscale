defmodule Hermitscale.Workflows.Engine.Join do
  @moduledoc "Joins the ordered branch results of one item occurrence."

  alias Runic.Workflow.Components

  @enforce_keys [:name, :parents, :hash]
  defstruct [:name, :parents, :hash]

  def new(name, [_ | _] = parents) do
    %__MODULE__{
      name: name,
      parents: parents,
      hash: Components.fact_hash({__MODULE__, name, parents})
    }
  end
end
