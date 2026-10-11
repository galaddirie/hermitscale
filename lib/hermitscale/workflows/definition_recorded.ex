defmodule Hermitscale.Workflows.DefinitionRecorded do
  @moduledoc """
  Application event identifying the compiled definition used to start a run.

  The fingerprint covers node identities, connections, policies and authored
  expression context. It carries no runtime credentials or executable source.
  """

  @enforce_keys [:fingerprint]
  defstruct [:fingerprint, version: 1]
end
