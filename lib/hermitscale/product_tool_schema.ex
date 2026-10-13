defmodule Hermitscale.ProductToolSchema do
  @moduledoc "Discoverable argument contracts at the authenticated product boundary."
  @required %{
    "workflows.list" => [],
    "workflows.inspect" => ~w(id),
    "workflows.validate" => ~w(definition),
    "workflows.create" => ~w(id name definition operation_key),
    "runs.start" => ~w(graph_id input operation_key),
    "runs.status" => ~w(id),
    "agents.inspect" => ~w(id),
    "agents.continue" => ~w(session_id instructions operation_key),
    "agents.cancel" => ~w(turn_id),
    "agents.publish" =>
      ~w(session_id branch base_sha manifest message candidate_digest patch_snapshot_artifact_id operation_key),
    "apps.inspect" => ~w(id),
    "apps.create" => ~w(name slug operation_key),
    "apps.build" => ~w(app_id operation_key),
    "apps.preview" => ~w(app_id session_id source_commit operation_key),
    "apps.logs" => ~w(app_id),
    "deployments.request" =>
      ~w(app_id environment_id session_id source_commit artifact_id artifact_digest configuration_digest operation_key),
    "deployments.inspect" => ~w(id)
  }
  @optional ~w(status schema_version repository base_sha recipe connection_set title instructions budget_cents timeout_seconds result_schema expected_active_deployment_id expected_active_deployment limit input)

  def schema(name) do
    required = Map.fetch!(@required, name)
    properties = Map.new(Enum.uniq(required ++ optional(name)), &{&1, field_schema(&1)})
    %{type: "object", properties: properties, required: required, additionalProperties: false}
  end

  def validate(name, args) do
    required = Map.fetch!(@required, name)

    valid =
      Enum.all?(required, &Map.has_key?(args, &1)) and
        Enum.all?(args, fn {key, value} ->
          key in (required ++ optional(name)) and valid_value?(field_schema(key), value)
        end)

    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  defp optional("agents.continue"), do: ["verification_commands" | @optional]
  defp optional(_name), do: @optional

  defp field_schema("input"), do: %{}

  defp field_schema(name)
       when name in ~w(definition connection_set result_schema),
       do: %{type: "object"}

  defp field_schema(name) when name in ~w(manifest verification_commands),
    do: %{type: "array", items: %{type: "string"}}

  defp field_schema(name)
       when name in ~w(budget_cents timeout_seconds limit schema_version),
       do: %{type: "integer"}

  defp field_schema(name)
       when name in ~w(expected_active_deployment_id expected_active_deployment),
       do: %{type: ["string", "null"]}

  defp field_schema(_name), do: %{type: "string"}
  defp valid_value?(%{type: ["string", "null"]}, value), do: is_binary(value) or is_nil(value)
  defp valid_value?(%{type: "string"}, value), do: is_binary(value)
  defp valid_value?(%{type: "object"}, value), do: is_map(value)
  defp valid_value?(%{type: "integer"}, value), do: is_integer(value)

  defp valid_value?(%{type: "array"}, value),
    do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp valid_value?(%{}, _value), do: true
end
