defmodule Hermitscale.WorkspacesTest.Client do
  @moduledoc false
  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{responses: %{}, calls: []} end, name: __MODULE__)

  def put_response(operation, response),
    do: Agent.update(__MODULE__, &put_in(&1.responses[operation], response))

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def create(name), do: respond(:create, [name], {:ok, %{"name" => name}})
  def delete(name), do: respond(:delete, [name], :ok)

  for {operation, arity} <- [
        get: 1,
        execute: 4,
        spawn: 4,
        list_sessions: 1,
        kill_session: 3,
        read_file: 2,
        write_file: 4,
        list_files: 2,
        delete_file: 3,
        list_checkpoints: 1,
        create_checkpoint: 2,
        restore_checkpoint: 2,
        list_services: 1,
        get_service: 2,
        put_service: 3,
        delete_service: 2,
        update_url_settings: 2,
        get_network_policy: 1,
        put_network_policy: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(operation)(unquote_splicing(args)),
      do: respond(unquote(operation), unquote(args), {:ok, %{operation: unquote(operation)}})
  end

  defp respond(operation, args, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      {Map.get(state.responses, operation, default),
       %{state | calls: [{operation, args} | state.calls]}}
    end)
  end
end
