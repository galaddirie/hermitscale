defmodule Hermitscale.Agents.Turn do
  @moduledoc "An immutable admitted request with durable dispatch and cancellation intent."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @terminal [:interrupted, :succeeded, :failed, :cancelled]

  schema "agent_turns" do
    field :org_id, :string
    belongs_to :session, Hermitscale.Agents.Session
    field :execution_actor_user_id, :string
    field :instructions, :string
    field :operation_key, :string
    field :input_digest, :string
    field :admission_sequence, :integer
    field :timeout_seconds, :integer, default: 1800
    field :deadline, :utc_datetime

    field :status, Ecto.Enum,
      values:
        [:queued, :provisioning, :running, :waiting_for_input, :waiting_for_approval] ++ @terminal,
      default: :queued

    field :cancellation_requested_at, :utc_datetime
    field :dispatched_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :result, :map
    field :error, :map
    field :lease_id, :binary_id
    field :worker_command_id, :binary_id
    field :cancel_command_id, :binary_id
    field :worker_epoch, :string
    field :worker_cursor, :integer, default: 0
    field :provider_conversation_id, :string
    field :approval_id, :binary_id
    field :result_schema, :map, default: %{}
    field :verification_commands, {:array, :string}, default: []
    field :runtime_state, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :instructions,
      :operation_key,
      :timeout_seconds,
      :result_schema,
      :verification_commands
    ])
    |> update_change(:instructions, &String.trim/1)
    |> validate_required([
      :instructions,
      :operation_key,
      :org_id,
      :session_id,
      :execution_actor_user_id
    ])
    |> validate_length(:instructions, min: 1, max: 32_000)
    |> validate_length(:operation_key, min: 8, max: 128)
    |> validate_number(:timeout_seconds,
      greater_than_or_equal_to: 30,
      less_than_or_equal_to: 3_600
    )
    |> unique_constraint([:session_id, :operation_key])
    |> validate_change(:result_schema, fn :result_schema, schema ->
      case Hermitscale.Agents.Result.validate_schema(schema) do
        :ok -> []
        {:error, _reason} -> [result_schema: "is not a supported valid JSON schema"]
      end
    end)
    |> validate_verification_commands()
    |> foreign_key_constraint(:session_id)
  end

  defp validate_verification_commands(changeset) do
    case get_field(changeset, :verification_commands) do
      commands when is_list(commands) ->
        if length(commands) <= 10 and Enum.all?(commands, &(byte_size(&1) in 1..4096)) do
          changeset
        else
          add_error(
            changeset,
            :verification_commands,
            "must contain at most 10 commands of 1 to 4096 bytes"
          )
        end

      nil ->
        add_error(changeset, :verification_commands, "must be a list of commands")
    end
  end
end
