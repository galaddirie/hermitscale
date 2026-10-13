defmodule Hermitscale.WorkspaceWorker.Harness do
  @moduledoc "Harness ACP continuation, approval responses and verified process-group cleanup."
  @session Jido.Harness.Session

  def start(command, config) do
    api = Keyword.get(config, :session_api, @session)
    {:ok, deadline, 0} = DateTime.from_iso8601(command["deadline"])
    timeout = max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 1)
    env = provider_env(config)

    request = %{
      cwd: Keyword.fetch!(config, :cwd),
      acp_path: Keyword.fetch!(config, :acp_path),
      env: env,
      env_mode: :replace,
      turn_runtime_timeout_ms: timeout,
      approval_timeout_ms: min(timeout, 300_000),
      session_idle_timeout_ms: 60_000
    }

    request =
      case Map.get(command["payload"], "provider_conversation_id", provider_session(config)) do
        nil -> request
        id -> Map.put(request, :provider_session_id, id)
      end

    previous = process_ids(config)

    with {:ok, session_id} <- apply(api, :start, [:codex, request]) do
      case send_when_ready(
             api,
             session_id,
             command["payload"]["prompt"],
             System.monotonic_time(:millisecond) + min(timeout, 30_000)
           ) do
        {:ok, turn_id} ->
          groups = process_groups(config, previous)
          persist_groups(config, groups)

          {:ok,
           %{
             session_api: api,
             session_id: session_id,
             turn_id: turn_id,
             cursor: 0,
             config: config,
             groups: groups
           }}

        {:error, reason} ->
          _close_result = apply(api, :close, [session_id])
          {:error, reason}
      end
    end
  end

  def poll(handle) do
    with {:ok, events} <-
           apply(handle.session_api, :replay, [
             handle.session_id,
             [cursor: handle.cursor, limit: 100]
           ]) do
      cursor =
        case List.last(events) do
          nil -> handle.cursor
          event -> event.sequence
        end

      persist_provider_session(handle)
      {:ok, events, %{handle | cursor: cursor}}
    end
  end

  def approve(handle, request_id, response) do
    decision =
      case response do
        "approved" -> :approve
        "denied" -> :deny
      end

    apply(handle.session_api, :respond_approval, [handle.session_id, request_id, decision])
  end

  def cancel(handle),
    do: apply(handle.session_api, :interrupt, [handle.session_id, handle.turn_id])

  def close(handle) do
    persist_provider_session(handle)
    result = apply(handle.session_api, :close, [handle.session_id])

    Enum.each(handle.groups, fn pid ->
      System.cmd(
        "sudo",
        ["-n", "/opt/hermitscale/bin/sandbox-launch", "signal", "KILL", "#{pid}"],
        stderr_to_stdout: true
      )
    end)

    result
  end

  def verify_termination(handle), do: verify_groups(handle.groups)

  def cleanup_failed_start(config) do
    processes = processes(config)

    Enum.each(processes, fn process ->
      if process.state in [:starting, :running, :stopping],
        do:
          apply(Keyword.get(config, :process_api, Jido.Harness.Process), :kill, [
            process.process_id
          ])
    end)

    groups =
      (Enum.map(processes, & &1.os_pid) ++ recorded_groups(config))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    Enum.each(groups, &signal_group(&1))
    persist_groups(config, groups)
    verify_groups(groups)
  end

  defp signal_group(pid),
    do:
      System.cmd(
        "sudo",
        ["-n", "/opt/hermitscale/bin/sandbox-launch", "signal", "KILL", "#{pid}"],
        stderr_to_stdout: true
      )

  def recover_termination(config) do
    case Keyword.fetch(config, :lease_file) do
      :error ->
        {:error, :termination_evidence_missing}

      {:ok, lease_file} ->
        %{"lease_id" => lease_id} = lease_file |> File.read!() |> JSON.decode!()
        path = Path.join(Path.dirname(lease_file), "groups/#{lease_id}.json")

        case File.read(path) do
          {:ok, data} ->
            groups = JSON.decode!(data)

            Enum.each(groups, fn pid ->
              System.cmd(
                "sudo",
                ["-n", "/opt/hermitscale/bin/sandbox-launch", "signal", "KILL", "#{pid}"],
                stderr_to_stdout: true
              )
            end)

            verify_groups(groups)

          {:error, :enoent} ->
            {:error, :termination_evidence_missing}
        end
    end
  end

  defp verify_groups(groups) do
    alive =
      Enum.filter(groups, fn pid ->
        {_output, owner_status} =
          System.cmd("/bin/kill", ["-0", "--", "-#{pid}"], stderr_to_stdout: true)

        {_output, coder_status} =
          System.cmd(
            "sudo",
            ["-n", "/opt/hermitscale/bin/sandbox-launch", "signal", "CHECK", "#{pid}"],
            stderr_to_stdout: true
          )

        owner_status == 0 or coder_status == 1 or coder_status not in [0, 1]
      end)

    if alive == [], do: {:ok, %{groups: groups}}, else: {:error, :writer_still_running}
  end

  defp send_when_ready(api, session_id, prompt, deadline) do
    case apply(api, :info, [session_id]) do
      {:ok, %{state: :idle}} ->
        apply(api, :send_message, [session_id, prompt])

      {:ok, %{state: :starting}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          send_when_ready(api, session_id, prompt, deadline)
        else
          {:error, :provider_startup_timeout}
        end

      {:ok, %{state: state, error: %{category: code}}}
      when state in [:closed, :failed, :cancelled] ->
        {:error, {:provider_start_failed, code}}

      {:ok, %{state: state}} when state in [:closed, :failed, :cancelled] ->
        {:error, :provider_start_failed}

      {:ok, _info} ->
        {:error, :provider_not_idle}

      {:error, _reason} = error ->
        error
    end
  end

  defp provider_env(config) do
    case Keyword.fetch(config, :env_file) do
      {:ok, path} -> path |> File.read!() |> JSON.decode!()
      :error -> Keyword.fetch!(config, :env)
    end
  end

  defp provider_session(config) do
    case Keyword.fetch(config, :provider_session_file) do
      :error ->
        nil

      {:ok, path} ->
        case File.read(path) do
          {:ok, id} -> String.trim(id)
          {:error, :enoent} -> nil
        end
    end
  end

  defp persist_provider_session(handle) do
    case Keyword.fetch(handle.config, :provider_session_file) do
      :error ->
        :ok

      {:ok, path} ->
        case apply(handle.session_api, :info, [handle.session_id]) do
          {:ok, %{provider_session_id: id}} when is_binary(id) ->
            File.write!(path, id, [:sync])
            File.chmod!(path, 0o600)

          {:ok, _info} ->
            :ok

          {:error, _reason} ->
            :ok
        end
    end
  end

  defp processes(config),
    do: apply(Keyword.get(config, :process_api, Jido.Harness.Process), :list, [[]])

  defp process_ids(config), do: processes(config) |> Enum.map(& &1.process_id)

  defp process_groups(config, previous) do
    processes(config)
    |> Enum.reject(&(&1.process_id in previous))
    |> Enum.map(& &1.os_pid)
    |> Enum.filter(&is_integer/1)
  end

  defp recorded_groups(config) do
    case Keyword.fetch(config, :lease_file) do
      :error ->
        []

      {:ok, path} ->
        %{"lease_id" => lease_id} = path |> File.read!() |> JSON.decode!()

        case File.read(Path.join(Path.dirname(path), "groups/#{lease_id}.json")) do
          {:ok, data} -> JSON.decode!(data)
          {:error, :enoent} -> []
        end
    end
  end

  defp persist_groups(config, groups) do
    case Keyword.fetch(config, :lease_file) do
      :error ->
        :ok

      {:ok, path} ->
        %{"lease_id" => lease_id} = path |> File.read!() |> JSON.decode!()
        groups_path = Path.join(Path.dirname(path), "groups/#{lease_id}.json")
        File.mkdir_p!(Path.dirname(groups_path))
        File.write!(groups_path, JSON.encode!(groups), [:sync])
        File.chmod!(groups_path, 0o600)
    end
  end
end
