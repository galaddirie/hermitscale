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
      ~w(session_id branch base_sha manifest message candidate_digest patch_snapshot_artifact_id review_id operation_key),
    "reviews.request" => ~w(action target target_digest operation_key),
    "reviews.decide" => ~w(id decision),
    "apps.inspect" => ~w(id),
    "apps.create" => ~w(name slug operation_key),
    "apps.build" => ~w(app_id operation_key),
    "apps.preview" => ~w(app_id session_id source_commit operation_key),
    "apps.logs" => ~w(app_id),
    "apps.verify_defect" => ~w(app_id environment_id path expected_status expected_body_digest),
    "deployments.request" =>
      ~w(app_id environment_id session_id source_commit artifact_id artifact_digest configuration_digest review_id operation_key),
    "deployments.inspect" => ~w(id),
    "support.subscribe" => ~w(app_id environment_id connection ticket_prefix operation_key),
    "support.investigate" => ~w(subscription_id ticket_id operation_key),
    "support.inspect" => ~w(id),
    "support.reply" => ~w(case_id body outcome review_id operation_key)
  }
  @optional ~w(status schema_version repository base_sha recipe connection_set title instructions budget_cents timeout_seconds result_schema expected_active_deployment_id expected_active_deployment policy_revision eligible_approver_ids expiry_seconds deployment_id defect_evidence_id limit input)

  def schema(name) do
    required = Map.fetch!(@required, name)
    properties = Map.new(Enum.uniq(required ++ @optional), &{&1, field_schema(&1)})
    %{type: "object", properties: properties, required: required, additionalProperties: false}
  end

  def validate(name, args) do
    required = Map.fetch!(@required, name)

    valid =
      Enum.all?(required, &Map.has_key?(args, &1)) and
        Enum.all?(args, fn {key, value} ->
          key in (required ++ @optional) and valid_value?(field_schema(key), value)
        end)

    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  defp field_schema("input"), do: %{}

  defp field_schema(name)
       when name in ~w(definition connection connection_set result_schema target),
       do: %{type: "object"}

  defp field_schema(name) when name in ~w(manifest eligible_approver_ids),
    do: %{type: "array", items: %{type: "string"}}

  defp field_schema(name)
       when name in ~w(budget_cents timeout_seconds policy_revision expiry_seconds limit schema_version expected_status),
       do: %{type: "integer"}

  defp field_schema(name)
       when name in ~w(expected_active_deployment_id expected_active_deployment deployment_id),
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
