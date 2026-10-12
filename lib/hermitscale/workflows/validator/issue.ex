defmodule Hermitscale.Workflows.Validator.Issue do
  @moduledoc """
  Structured validation issue returned to editors and forms.
  """

  @enforce_keys [:path, :code, :message]
  defstruct [:path, :code, :message, severity: :error]

  @doc false
  def new(path, code, message, severity \\ :error) do
    %__MODULE__{path: path, code: code, message: message, severity: severity}
  end
end
