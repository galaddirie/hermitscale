defmodule Hermitscale.AppsRuntimeFake do
  @moduledoc false
  use Agent
  @behaviour Hermitscale.Workspaces.Management

  def start_link(_opts),
    do:
      Agent.start_link(
        fn ->
          %{
            calls: [],
            files: %{},
            services: %{},
            markers: %{},
            data: %{},
            fail_activation: false,
            lose_marker: false,
            app_response: nil,
            socket_peer: nil
          }
        end,
        name: __MODULE__
      )

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def data(workspace_id), do: Agent.get(__MODULE__, &Map.get(&1.data, workspace_id, []))

  def add_write(workspace_id, value),
    do:
      Agent.update(
        __MODULE__,
        &put_in(&1, [:data, workspace_id], Map.get(&1.data, workspace_id, []) ++ [value])
      )

  def fail_activation, do: Agent.update(__MODULE__, &%{&1 | fail_activation: true})
  def lose_marker_response, do: Agent.update(__MODULE__, &%{&1 | lose_marker: true})
  def app_response(response), do: Agent.update(__MODULE__, &%{&1 | app_response: response})
  def socket_peer(pid), do: Agent.update(__MODULE__, &%{&1 | socket_peer: pid})

  def open_app_socket(workspace, path, headers) do
    record({:open_app_socket, workspace.id, path, headers})
    {:ok, Agent.get(__MODULE__, & &1.socket_peer), make_ref()}
  end

  @impl true
  def ensure_allocated(workspace) do
    record({:allocate, workspace.id})
    {:ok, %{compute_state: :sleeping}}
  end

  @impl true
  def verify_termination(_workspace, _lease, %{"receipt" => "app-fixture"}), do: :ok

  def termination_evidence(workspace, lease) do
    record({:terminate, workspace.id, lease.operation_key})

    {:ok,
     %{
       "workspace_id" => workspace.id,
       "lease_id" => lease.id,
       "operation_key" => lease.operation_key,
       "generation" => lease.generation,
       "writer_stopped" => true,
       "receipt" => "app-fixture"
     }}
  end

  def write_file(workspace, _lease, path, content) do
    record({:write_file, workspace.id, path})
    Agent.update(__MODULE__, &put_in(&1, [:files, {workspace.id, path}], content))
    :ok
  end

  def read_file(workspace, _lease, path) do
    record({:read_file, workspace.id, path})

    case Agent.get(__MODULE__, &Map.fetch(&1.files, {workspace.id, path})) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :file_not_found}
    end
  end

  def execute_command(workspace, _lease, command) do
    record({:command, workspace.id, command})
    execute_recipe(workspace, command)
  end

  defp execute_recipe(workspace, command) do
    case Regex.run(~r/'app-tools\/release.py' '([^']+)' '--operation' '([^']+)'/, command) do
      [_, action, operation] ->
        recipe(workspace, action, operation, arg(command, "revision"), arg(command, "digest"))

      nil ->
        {:ok, %{exit_code: 0, output: ""}}
    end
  end

  defp recipe(workspace, "inspect", _operation, _revision, _digest) do
    Agent.get(__MODULE__, &Map.get(&1.markers, workspace.id, %{"operation_id" => nil}))
    |> output()
  end

  defp recipe(_workspace, "freeze", _operation, revision, _digest),
    do:
      output(%{
        "revision" => revision,
        "base_revision" => revision,
        "change_manifest" => ["app.py"]
      })

  defp recipe(_workspace, "preview", operation, revision, digest),
    do: output(%{"staged" => operation, "revision" => revision, "digest" => digest})

  defp recipe(workspace, "build", operation, revision, _digest) do
    content = "source:" <> revision
    path = "incoming/" <> operation <> ".tar"
    Agent.update(__MODULE__, &put_in(&1, [:files, {workspace.id, path}], content))

    output(%{
      "path" => path,
      "digest" => hash(content),
      "revision" => revision,
      "checks" => ["compile", "unit_tests", "database_integrity"]
    })
  end

  defp recipe(_workspace, "stage", operation, revision, digest),
    do:
      output(%{
        "staged" => operation,
        "revision" => revision,
        "digest" => digest,
        "migration" => false
      })

  defp recipe(workspace, "backup", operation, _revision, _digest) do
    path = "incoming/" <> operation <> ".backup.tar"
    content = Jason.encode!(%{"notes" => data(workspace.id)})
    Agent.update(__MODULE__, &put_in(&1, [:files, {workspace.id, path}], content))

    output(%{
      "operation_id" => operation,
      "path" => path,
      "digest" => hash(content),
      "integrity" => "ok",
      "restoration" => "verified"
    })
  end

  defp recipe(workspace, "restore", operation, _revision, digest) do
    content =
      Agent.get(
        __MODULE__,
        &Map.fetch!(&1.files, {workspace.id, "incoming/" <> operation <> ".backup.tar"})
      )

    %{"notes" => notes} = Jason.decode!(content)
    Agent.update(__MODULE__, &put_in(&1, [:data, workspace.id], notes))
    output(%{"restored" => operation, "digest" => digest, "integrity" => "ok"})
  end

  defp recipe(workspace, "mark", operation, revision, digest) do
    value = %{"operation_id" => operation, "revision" => revision, "artifact_digest" => digest}

    lost? =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.lose_marker,
         %{state | markers: Map.put(state.markers, workspace.id, value), lose_marker: false}}
      end)

    case lost? do
      true -> {:error, :provider_unavailable}
      false -> output(value)
    end
  end

  def ensure_service(workspace, name, spec) do
    record({:ensure_service, workspace.id, name, spec})

    fail? =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.fail_activation,
         %{
           state
           | fail_activation: false,
             services: Map.put(state.services, {workspace.id, name}, spec)
         }}
      end)

    case fail? do
      true ->
        Agent.update(__MODULE__, &%{&1 | services: Map.delete(&1.services, {workspace.id, name})})
        {:error, :service_failed}

      false ->
        {:ok, %{name: name, status: "running"}}
    end
  end

  def stop_service(workspace, name) do
    record({:stop_service, workspace.id, name})
    Agent.update(__MODULE__, &%{&1 | services: Map.delete(&1.services, {workspace.id, name})})
    {:ok, %{status: "stopped"}}
  end

  def inspect_service(workspace, name),
    do: {:ok, Agent.get(__MODULE__, &Map.get(&1.services, {workspace.id, name}))}

  def app_request(workspace, path, options) do
    record({:app_request, workspace.id, path, options})

    case Agent.get(__MODULE__, & &1.app_response) do
      nil -> serve(workspace)
      response -> {:ok, response}
    end
  end

  defp serve(workspace) do
    case Agent.get(__MODULE__, &Map.get(&1.services, {workspace.id, "hs-app"})) do
      nil ->
        {:ok, %{status: 503, body: %{}, headers: %{}}}

      spec ->
        revision =
          spec.args
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.find_value(fn [key, value] -> if key == "--revision", do: value end)

        {:ok,
         %{
           status: 200,
           body: %{"revision" => revision, "database" => "ok"},
           headers: %{"content-type" => ["application/json"]}
         }}
    end
  end

  defp arg(command, name) do
    case Regex.run(Regex.compile!("'--" <> name <> "' '([^']+)'"), command) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})
  defp output(value), do: {:ok, %{exit_code: 0, output: Jason.encode!(value)}}
  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
