defmodule Hermitscale.ProductToolSchema do
  @moduledoc "Discoverable argument contracts at the authenticated product boundary."
  @fields %{
    "workflows.list" => {[], []},
    "workflows.inspect" => {~w(id), []},
    "workflows.validate" => {~w(definition), []},
    "workflows.create" => {~w(id name definition operation_key), ~w(schema_version status)},
    "runs.start" => {~w(graph_id input operation_key), []},
    "runs.status" => {~w(id), []},
    "agents.inspect" => {~w(id), []},
    "agents.continue" =>
      {~w(session_id instructions operation_key),
       ~w(timeout_seconds result_schema verification_commands)},
    "agents.cancel" => {~w(turn_id), []},
    "agents.publish" => {~w(session_id branch message operation_key), []},
    "apps.inspect" => {~w(id), []},
    "apps.create" => {~w(name slug operation_key), ~w(repository)},
    "apps.build" => {~w(app_id), ~w(base_sha connection_set)},
    "apps.preview" => {~w(app_id), ~w(start_command port)},
    "apps.publish" => {~w(app_id), ~w(start_command port)},
    "apps.logs" => {~w(app_id), ~w(limit)}
  }

  def schema(name) do
    {required, optional} = Map.fetch!(@fields, name)

    %{
      type: "object",
      properties: Map.new(required ++ optional, &{&1, field_schema(&1)}),
      required: required,
      additionalProperties: false
    }
  end

  def validate(name, args) when is_map(args) do
    case Map.fetch(@fields, name) do
      {:ok, {required, optional}} ->
        valid =
          Enum.all?(required, &Map.has_key?(args, &1)) and
            Enum.all?(args, fn {key, value} ->
              key in (required ++ optional) and valid_value?(field_schema(key), value)
            end)

        if valid, do: :ok, else: {:error, :invalid_arguments}

      :error ->
        {:error, :unknown_tool}
    end
  end

  def validate(_name, _args), do: {:error, :invalid_arguments}

  defp field_schema("input"), do: %{}

  defp field_schema(name) when name in ~w(definition connection_set result_schema),
    do: %{type: "object"}

  defp field_schema("verification_commands"), do: %{type: "array", items: %{type: "string"}}

  defp field_schema(name) when name in ~w(timeout_seconds limit schema_version port),
    do: %{type: "integer"}

  defp field_schema(_name), do: %{type: "string"}
  defp valid_value?(%{type: "string"}, value), do: is_binary(value)
  defp valid_value?(%{type: "object"}, value), do: is_map(value)
  defp valid_value?(%{type: "integer"}, value), do: is_integer(value)

  defp valid_value?(%{type: "array"}, value),
    do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp valid_value?(%{}, _value), do: true
end
