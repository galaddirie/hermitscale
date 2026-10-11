defmodule Hermitscale.WorkOS.State do
  @moduledoc """
  Issues and atomically consumes callback state for Hosted AuthKit.
  """

  import Ecto.Query

  alias Hermitscale.Repo
  alias Hermitscale.WorkOS.AuthorizationState

  @lifetime_seconds 10 * 60
  @token_bytes 32

  @doc """
  Persists a single-use state token for an allowlisted local return path.
  """
  def issue(return_to \\ "/") when is_binary(return_to) do
    with :ok <- validate_return_to(return_to) do
      token = random_token()

      %AuthorizationState{}
      |> AuthorizationState.create_changeset(%{
        token_hash: token_hash(token),
        return_to: return_to,
        expires_at: DateTime.add(DateTime.utc_now(:second), @lifetime_seconds, :second)
      })
      |> Repo.insert()
      |> case do
        {:ok, _state} -> {:ok, token}
        {:error, _changeset} = error -> error
      end
    end
  end

  @doc """
  Consumes state exactly once and returns its server-stored local return path.
  """
  def consume(token) when is_binary(token) do
    now = DateTime.utc_now(:second)
    hash = token_hash(token)

    Repo.transaction(fn ->
      query =
        from state in AuthorizationState,
          where: state.token_hash == ^hash,
          lock: "FOR UPDATE"

      case Repo.one(query) do
        %AuthorizationState{consumed_at: nil, expires_at: expires_at} = state ->
          consume_unexpired(state, hash, expires_at, now)

        %AuthorizationState{} ->
          Repo.rollback(:state_already_used)

        nil ->
          Repo.rollback(:invalid_state)
      end
    end)
    |> transaction_result()
  end

  def consume(_token), do: {:error, :invalid_state}

  @doc """
  Accepts only absolute-path references on this application.
  """
  def validate_return_to(return_to) when is_binary(return_to) do
    uri = URI.parse(return_to)

    case uri do
      %URI{scheme: nil, host: nil, path: <<"/", rest::binary>>} ->
        case String.starts_with?(rest, "/") do
          true -> {:error, :invalid_return_to}
          false -> :ok
        end

      _other ->
        {:error, :invalid_return_to}
    end
  end

  defp consume_unexpired(state, hash, expires_at, now) do
    with true <- DateTime.after?(expires_at, now),
         true <- Plug.Crypto.secure_compare(state.token_hash, hash),
         {:ok, _state} <-
           state
           |> AuthorizationState.consume_changeset(now)
           |> Repo.update() do
      state.return_to
    else
      false -> Repo.rollback(:expired_state)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transaction_result({:ok, return_to}), do: {:ok, return_to}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp random_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)
end
