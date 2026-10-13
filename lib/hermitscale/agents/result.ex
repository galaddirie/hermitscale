defmodule Hermitscale.Agents.Result do
  @moduledoc "Validates requested structured output against recorded checks and source evidence."
  def validate(result, schema) when is_map(result) and is_map(schema) do
    cond do
      Map.get(result, "result_evidence_present", true) == false ->
        {:error, :result_evidence_missing}

      Map.get(result, "result_valid_json", true) == false ->
        {:error, :invalid_result_json}

      byte_size(Jason.encode!(Map.drop(result, ["diff", "files"]))) > 1_048_576 ->
        {:error, :result_too_large}

      not is_binary(result["base_sha"]) ->
        {:error, :source_evidence_missing}

      not is_list(result["checks"]) ->
        {:error, :check_evidence_missing}

      Enum.any?(result["checks"], fn check ->
        not (is_map(check) and check["exit_code"] == 0 and is_binary(check["name"]))
      end) ->
        {:error, :checks_failed_or_unverified}

      external_refs?(schema) ->
        {:error, :external_schema_reference_denied}

      true ->
        try do
          case ExJsonSchema.Validator.validate(
                 ExJsonSchema.Schema.resolve(schema),
                 Map.get(result, "result", result)
               ) do
            :ok -> :ok
            {:error, errors} -> {:error, {:invalid_result, errors}}
          end
        rescue
          _error in [
            ExJsonSchema.Schema.InvalidSchemaError,
            ExJsonSchema.Schema.InvalidReferenceError,
            ExJsonSchema.Schema.UnsupportedSchemaVersionError
          ] ->
            {:error, :invalid_result_schema}
        end
    end
  end

  def validate(_result, _schema), do: {:error, :invalid_result}

  def validate_schema(schema) when is_map(schema) do
    if external_refs?(schema) do
      {:error, :external_schema_reference_denied}
    else
      try do
        ExJsonSchema.Schema.resolve(schema)
        :ok
      rescue
        _error in [
          ExJsonSchema.Schema.InvalidSchemaError,
          ExJsonSchema.Schema.InvalidReferenceError,
          ExJsonSchema.Schema.UnsupportedSchemaVersionError
        ] ->
          {:error, :invalid_result_schema}
      end
    end
  end

  def validate_schema(_schema), do: {:error, :invalid_result_schema}

  defp external_refs?(map) when is_map(map),
    do:
      Enum.any?(map, fn
        {"$ref", ref} when is_binary(ref) -> not String.starts_with?(ref, "#")
        {_key, value} -> external_refs?(value)
      end)

  defp external_refs?(list) when is_list(list), do: Enum.any?(list, &external_refs?/1)
  defp external_refs?(_value), do: false
end
