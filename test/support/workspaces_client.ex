defmodule Hermitscale.WorkspacesTest.Client do
  @moduledoc false
  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{responses: %{}, calls: []} end, name: __MODULE__)

  def put_response(operation, response),
    do: Agent.update(__MODULE__, &put_in(&1.responses[operation], response))

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  def create(name, opts), do: respond(:create, [name, opts], {:ok, sprite(name)})
  def get(name), do: respond(:get, [name], {:ok, sprite(name)})
  def delete(name), do: respond(:delete, [name], :ok)

  def execute(name, command, args, opts), do: respond(:execute, [name, command, args, opts])
  def spawn(name, command, args, opts), do: respond(:spawn, [name, command, args, opts])
  def list_sessions(name), do: respond(:list_sessions, [name])
  def kill_session(name, id, opts), do: respond(:kill_session, [name, id, opts])
  def attach_session(name, id, opts), do: respond(:attach_session, [name, id, opts])
  def read_file(name, path, opts), do: respond(:read_file, [name, path, opts])
  def write_file(name, path, bytes, opts), do: respond(:write_file, [name, path, bytes, opts])
  def list_files(name, path, opts), do: respond(:list_files, [name, path, opts])
  def delete_file(name, path, opts), do: respond(:delete_file, [name, path, opts], :ok)
  def list_checkpoints(name, opts), do: respond(:list_checkpoints, [name, opts])
  def create_checkpoint(name, opts), do: respond(:create_checkpoint, [name, opts])
  def restore_checkpoint(name, id), do: respond(:restore_checkpoint, [name, id])
  def list_services(name), do: respond(:list_services, [name])
  def get_service(name, service), do: respond(:get_service, [name, service])
  def put_service(name, service, attrs), do: respond(:put_service, [name, service, attrs])
  def delete_service(name, service), do: respond(:delete_service, [name, service], :ok)
  def update_url_settings(name, settings), do: respond(:update_url_settings, [name, settings])

  defp sprite(name), do: %{"id" => "sprite:" <> name, "name" => name, "status" => "cold"}

  defp respond(operation, args), do: respond(operation, args, {:ok, %{operation: operation}})

  defp respond(operation, args, default) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.get(state.responses, operation, default),
         %{state | calls: [{operation, args} | state.calls]}}
      end)

    case response do
      response when is_function(response) -> apply(response, args)
      response -> response
    end
  end
end
