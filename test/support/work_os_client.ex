defmodule Hermitscale.WorkOSTest.Client do
  @moduledoc false

  use Agent

  def start_link(initial \\ %{}) do
    initial = Map.new(initial)
    Agent.start_link(fn -> %{responses: initial, calls: []} end, name: __MODULE__)
  end

  def put_response(operation, response) do
    Agent.update(__MODULE__, &put_in(&1, [:responses, operation], response))
  end

  def calls do
    Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  end

  def authorization_url(state, opts \\ []) do
    respond(
      :authorization_url,
      [state, opts],
      {:ok, "https://api.workos.com/authorize?state=#{state}"}
    )
  end

  def authenticate_with_code(code, metadata \\ %{}) do
    respond(:authenticate_with_code, [code, metadata], {:error, :not_configured})
  end

  def authenticate_with_refresh_token(refresh_token, organization_id, metadata \\ %{}) do
    respond(
      :authenticate_with_refresh_token,
      [refresh_token, organization_id, metadata],
      {:error, :not_configured}
    )
  end

  def jwks do
    respond(:jwks, [], {:ok, %{"keys" => []}})
  end

  def list_providers(user_id, organization_id \\ nil) do
    respond(:list_providers, [user_id, organization_id], {:ok, %{"data" => []}})
  end

  def authorize_connection(provider, user_id, organization_id, return_to) do
    respond(
      :authorize_connection,
      [provider, user_id, organization_id, return_to],
      {:ok, %{"url" => "https://api.workos.com/pipes/authorize"}}
    )
  end

  def get_connected_account(provider, user_id, organization_id) do
    respond(
      :get_connected_account,
      [provider, user_id, organization_id],
      {:error, :not_found}
    )
  end

  def delete_connected_account(provider, user_id, organization_id) do
    respond(:delete_connected_account, [provider, user_id, organization_id], {:ok, %{}})
  end

  def fetch_oauth_token(provider, user_id, organization_id) do
    respond(
      :fetch_oauth_token,
      [provider, user_id, organization_id],
      {:error, :not_configured}
    )
  end

  def revoke_session(session_id) do
    respond(:revoke_session, [session_id], {:ok, %{}})
  end

  def logout_url(session_id, return_to \\ nil) do
    respond(
      :logout_url,
      [session_id, return_to],
      "https://api.workos.com/user_management/sessions/logout?session_id=#{session_id}"
    )
  end

  defp respond(operation, args, default) do
    case Process.whereis(__MODULE__) do
      nil ->
        default

      _pid ->
        Agent.get_and_update(__MODULE__, fn state ->
          response = Map.get(state.responses, operation, default)
          {resolve(response, args), %{state | calls: [{operation, args} | state.calls]}}
        end)
    end
  end

  defp resolve(response, args) when is_function(response), do: apply(response, args)
  defp resolve(response, _args), do: response
end
