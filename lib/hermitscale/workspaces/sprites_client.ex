defmodule Hermitscale.Workspaces.SpritesClient do
  @moduledoc """
  Server-side Fly Sprites client. REST requests use Req; commands use the official
  SDK's WebSocket transport so output frames retain their boundaries.

  Configure `:token`, `:base_url`, and optional trusted `:req_options` under this
  module. Caller options never select credentials or an HTTP destination.
  """

  @base_url "https://api.sprites.dev"

  @doc """
  Streams an arbitrary command to `:owner` (defaults to the caller).

  Messages are `{:stdout | :stderr, %{ref: ref}, bytes}`, `{:exit, %{ref: ref}, code}`,
  or `{:error, %{ref: ref}, reason}`. Set `session_info: true` to receive
  `{:session_info, %{ref: ref}, session_id}`. The returned backend handle has its
  client credentials removed and supports `Sprites.write/2`, `close_stdin/1`,
  and `resize/3`. Set `stdin: true` when writing input. The owner's death closes
  the local transport; detached remote sessions can be inspected and killed
  separately. No execution timeout is imposed.
  """
  def spawn(name, command, args \\ [], opts \\ []) do
    with {:ok, handle, _guardian, monitor} <- start_command(name, command, args, opts) do
      Process.demonitor(monitor, [:flush])
      {:ok, handle}
    end
  end

  @doc """
  Runs a command and captures separate stdout, stderr, and its exit code.

  A nonzero exit code is a successful execution result. No execution timeout or
  output quota is imposed; use `spawn/4` to consume large output incrementally.
  An explicit `:timeout` ends local collection, leaving remote lifecycle to Fly.
  """
  def execute(name, command, args \\ [], opts \\ []) do
    with :ok <- validate_timeout(Keyword.get(opts, :timeout, :infinity)),
         {:ok, handle, guardian, monitor} <-
           start_command(name, command, args, Keyword.put(opts, :owner, self())) do
      deadline = command_deadline(Keyword.get(opts, :timeout, :infinity))
      collect_output(handle.ref, guardian, monitor, [], [], deadline)
    end
  end

  @doc "Attaches to an existing remote session using the SDK's stdin and TTY controls."
  def attach_session(name, session_id, opts \\ []) do
    spawn(
      name,
      "",
      [],
      opts |> Keyword.put(:session_id, session_id) |> Keyword.put_new(:tty, true)
    )
  end

  @doc "Lists provider exec sessions, including detached sessions."
  def list_sessions(name) do
    with {:ok, body} <- request(:get, sprite_path(name, "/exec")) do
      sessions =
        case body do
          %{"sessions" => sessions} -> sessions
          other -> other
        end

      validate_list(sessions, fn
        %{"id" => id, "command" => command} when is_binary(command) -> valid_session_id?(id)
        _invalid_session -> false
      end)
    end
  end

  @doc "Kills a provider session, returning completed kill progress."
  def kill_session(name, session_id, opts \\ []) do
    request_progress(
      :post,
      sprite_path(name, "/exec/" <> encode_segment(to_string(session_id)) <> "/kill"),
      params: Keyword.take(opts, [:signal, :timeout])
    )
  end

  @doc "Creates a Sprite with authenticated URL access by default."
  def create(name, opts \\ []) do
    body =
      opts
      |> Keyword.take([
        :config,
        :environment,
        :labels,
        :runtime,
        :wait_for_capacity,
        :url_settings
      ])
      |> Map.new()
      |> Map.put_new(:url_settings, %{auth: "sprite"})
      |> Map.put(:name, name)

    with {:ok, body} <- request(:post, "/v1/sprites", json: body, receive_timeout: 120_000) do
      validate_sprite(body, name)
    end
  end

  @doc "Fetches provider metadata for a Sprite."
  def get(name) do
    with {:ok, body} <- request(:get, sprite_path(name)) do
      validate_sprite(body, name)
    end
  end

  @doc "Deletes a Sprite, treating an already missing Sprite as success."
  def delete(name), do: delete_resource(sprite_path(name))

  @doc "Reads raw bytes from the Sprite filesystem."
  def read_file(name, path, opts \\ []) do
    with {:ok, body} <-
           request(:get, sprite_path(name, "/fs/read"),
             params: file_params(path, opts),
             decode_body: false
           ) do
      case body do
        bytes when is_binary(bytes) -> {:ok, bytes}
        _invalid_body -> {:error, :invalid_response}
      end
    end
  end

  @doc "Writes bytes and returns the provider's file metadata."
  def write_file(name, path, bytes, opts \\ []) do
    params = file_params(path, opts) ++ Keyword.take(opts, [:mode, :mkdir])

    with {:ok, body} <-
           request(:put, sprite_path(name, "/fs/write"),
             params: params,
             body: IO.iodata_to_binary(bytes),
             headers: [{"content-type", "application/octet-stream"}]
           ) do
      case body do
        %{"path" => path, "size" => size, "mode" => mode}
        when is_binary(path) and is_integer(size) and size >= 0 and is_binary(mode) ->
          {:ok, body}

        _invalid_body ->
          {:error, :invalid_response}
      end
    end
  end

  @doc "Lists files in a remote directory."
  def list_files(name, path, opts \\ []) do
    with {:ok, body} <-
           request(:get, sprite_path(name, "/fs/list"), params: file_params(path, opts)) do
      case body do
        %{"entries" => entries, "path" => path, "count" => count}
        when is_list(entries) and is_binary(path) and is_integer(count) and count >= 0 ->
          case Enum.all?(entries, &valid_file_entry?/1) do
            true -> {:ok, body}
            false -> {:error, :invalid_response}
          end

        _invalid_body ->
          {:error, :invalid_response}
      end
    end
  end

  @doc "Deletes a remote file or directory; use `recursive: true` for directories."
  def delete_file(name, path, opts \\ []) do
    body = %{
      path: path,
      workingDir: Keyword.get(opts, :working_dir, "/"),
      recursive: Keyword.get(opts, :recursive, false),
      asRoot: Keyword.get(opts, :as_root, false)
    }

    delete_resource(sprite_path(name, "/fs/delete"), json: body)
  end

  @doc "Lists filesystem checkpoints."
  def list_checkpoints(name, opts \\ []) do
    with {:ok, body} <-
           request(:get, sprite_path(name, "/checkpoints"),
             params: Keyword.take(opts, [:history])
           ) do
      validate_list(body, fn
        %{"id" => id} when is_binary(id) and id != "" -> true
        _invalid_checkpoint -> false
      end)
    end
  end

  @doc "Creates a checkpoint, returning its completed progress messages."
  def create_checkpoint(name, opts \\ []) do
    request_progress(:post, sprite_path(name, "/checkpoint"),
      json: Map.new(Keyword.take(opts, [:comment]))
    )
  end

  @doc "Restores a filesystem checkpoint, returning completed progress messages."
  def restore_checkpoint(name, checkpoint_id) do
    request_progress(
      :post,
      sprite_path(name, "/checkpoints/" <> encode_segment(checkpoint_id) <> "/restore")
    )
  end

  @doc "Lists configured services and their runtime state."
  def list_services(name) do
    with {:ok, body} <- request(:get, sprite_path(name, "/services")) do
      services =
        case body do
          %{"services" => services} -> services
          other -> other
        end

      validate_list(services, &valid_service?/1)
    end
  end

  @doc "Fetches one configured service."
  def get_service(name, service_name) do
    with {:ok, body} <- request(:get, service_path(name, service_name)) do
      validate_service(body, service_name)
    end
  end

  @doc "Creates or updates a service and returns its provider definition."
  def put_service(name, service_name, attrs) do
    with {:ok, body} <-
           request(:put, service_path(name, service_name), json: attrs, decode_body: false) do
      case Jason.decode(body) do
        {:ok, %{"cmd" => _command} = service} ->
          validate_service(service, service_name)

        _progress_body ->
          with {:ok, _messages} <- parse_progress(body) do
            get_service(name, service_name)
          end
      end
    end
  end

  @doc "Deletes a configured service."
  def delete_service(name, service_name), do: delete_resource(service_path(name, service_name))

  @doc "Updates authenticated or public access to the Sprite's HTTP URL."
  def update_url_settings(name, settings) do
    with {:ok, body} <- request(:put, sprite_path(name), json: %{url_settings: settings}) do
      validate_sprite(body, name)
    end
  end

  defp service_path(name, service_name),
    do: sprite_path(name, "/services/" <> encode_segment(service_name))

  defp start_command(name, command, args, opts) do
    with {:ok, config} <- configured(),
         :ok <- validate_session_option(opts) do
      caller = self()
      owner = Keyword.get(opts, :owner, caller)
      started_ref = make_ref()

      client =
        Sprites.new(Keyword.fetch!(config, :token),
          base_url: Keyword.get(config, :base_url, @base_url)
        )

      sprite = Sprites.sprite(client, name)

      sdk_opts =
        opts
        |> Keyword.take([
          :env,
          :dir,
          :tty,
          :tty_rows,
          :tty_cols,
          :detachable,
          :stdin,
          :session_info,
          :session_id
        ])
        |> normalize_session_option()

      case Task.Supervisor.start_child(Hermitscale.Workspaces.CommandSupervisor, fn ->
             run_command(caller, started_ref, owner, sprite, command, args, sdk_opts)
           end) do
        {:ok, guardian} ->
          monitor = Process.monitor(guardian)

          receive do
            {^started_ref, {:ok, handle}} ->
              {:ok, handle, guardian, monitor}

            {^started_ref, {:error, _reason} = error} ->
              Process.demonitor(monitor, [:flush])
              error

            {:DOWN, ^monitor, :process, ^guardian, _reason} ->
              {:error, :unavailable}
          end

        {:error, _reason} ->
          {:error, :unavailable}
      end
    end
  end

  defp validate_session_option(opts) do
    case Keyword.fetch(opts, :session_id) do
      :error ->
        :ok

      {:ok, session_id} ->
        case valid_session_id?(session_id) do
          true -> :ok
          false -> {:error, :invalid_session_id}
        end
    end
  end

  defp normalize_session_option(opts) do
    case Keyword.fetch(opts, :session_id) do
      :error -> opts
      {:ok, session_id} -> Keyword.put(opts, :session_id, to_string(session_id))
    end
  end

  defp valid_session_id?(id) when is_integer(id), do: id > 0

  defp valid_session_id?(id) when is_binary(id) and byte_size(id) in 1..256,
    do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp valid_session_id?(_id), do: false

  defp run_command(caller, started_ref, owner, sprite, executable, args, opts) do
    owner_monitor = Process.monitor(owner)

    case Sprites.spawn(sprite, executable, args, Keyword.put(opts, :owner, self())) do
      {:ok, command} ->
        command_monitor = Process.monitor(command.pid)
        send(caller, {started_ref, {:ok, %{command | sprite: nil, owner: owner}}})
        forward_output(command, command_monitor, owner, owner_monitor)

      {:error, reason} ->
        send(caller, {started_ref, command_error(reason)})
    end
  end

  defp forward_output(command, command_monitor, owner, owner_monitor) do
    ref = command.ref

    receive do
      {stream, %{ref: ^ref} = identity, bytes}
      when stream in [:stdout, :stderr] and is_binary(bytes) ->
        send(owner, {stream, identity, bytes})
        forward_output(command, command_monitor, owner, owner_monitor)

      {:session_info, %{ref: ^ref} = identity, session_id} ->
        send(owner, {:session_info, identity, session_id})
        forward_output(command, command_monitor, owner, owner_monitor)

      {:port, %{ref: ^ref} = identity, port} ->
        send(owner, {:port, identity, port})
        forward_output(command, command_monitor, owner, owner_monitor)

      {:exit, %{ref: ^ref} = identity, code} when is_integer(code) and code >= 0 ->
        send(owner, {:exit, identity, code})

      {:exit, %{ref: ^ref}, _invalid_code} ->
        send(owner, {:error, %{ref: ref}, :invalid_response})

      {:error, %{ref: ^ref} = identity, reason} ->
        {:error, normalized} = command_error(reason)
        send(owner, {:error, identity, normalized})

      {:DOWN, ^command_monitor, :process, _pid, _reason} ->
        send(owner, {:error, %{ref: ref}, :unavailable})

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        close_command(command)

      {:cancel, ^ref} ->
        close_command(command)
    end
  end

  defp close_command(command) do
    try do
      GenServer.stop(command.pid, :normal)
    catch
      :exit, {:noproc, _call} -> :ok
    end
  end

  defp collect_output(ref, guardian, monitor, stdout, stderr, deadline) do
    case remaining_timeout(deadline) do
      0 -> command_timeout(ref, guardian, monitor)
      remaining -> receive_output(ref, guardian, monitor, stdout, stderr, deadline, remaining)
    end
  end

  defp receive_output(ref, guardian, monitor, stdout, stderr, deadline, remaining) do
    receive do
      {:stdout, %{ref: ^ref}, bytes} ->
        collect_output(ref, guardian, monitor, [bytes | stdout], stderr, deadline)

      {:stderr, %{ref: ^ref}, bytes} ->
        collect_output(ref, guardian, monitor, stdout, [bytes | stderr], deadline)

      {:exit, %{ref: ^ref}, code} ->
        Process.demonitor(monitor, [:flush])

        {:ok,
         %{
           stdout: stdout |> Enum.reverse() |> IO.iodata_to_binary(),
           stderr: stderr |> Enum.reverse() |> IO.iodata_to_binary(),
           exit_code: code
         }}

      {:error, %{ref: ^ref}, reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        {:error, :unavailable}
    after
      remaining -> command_timeout(ref, guardian, monitor)
    end
  end

  defp command_timeout(ref, guardian, monitor) do
    send(guardian, {:cancel, ref})
    Process.demonitor(monitor, [:flush])
    {:error, :timeout}
  end

  defp command_deadline(:infinity), do: :infinity

  defp command_deadline(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  defp remaining_timeout(:infinity), do: :infinity
  defp remaining_timeout(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp validate_timeout(:infinity), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: :ok
  defp validate_timeout(_invalid_timeout), do: {:error, :invalid_timeout}

  defp command_error(%Sprites.Error.APIError{status: status}), do: status_error(status)
  defp command_error({:api_error, status, _body}), do: status_error(status)
  defp command_error(:timeout), do: {:error, :timeout}

  defp command_error(reason) when reason in [:invalid_session_info, :conflicting_session_info],
    do: {:error, :invalid_response}

  defp command_error(_transport_error), do: {:error, :unavailable}

  defp valid_service?(%{"name" => name, "cmd" => cmd, "args" => args, "needs" => needs})
       when is_binary(name) and is_binary(cmd) and is_list(args) and is_list(needs),
       do: Enum.all?(args ++ needs, &is_binary/1)

  defp valid_service?(_service), do: false

  defp validate_service(%{"name" => name} = body, name) do
    case valid_service?(body) do
      true -> {:ok, body}
      false -> {:error, :invalid_response}
    end
  end

  defp validate_service(_body, _name), do: {:error, :invalid_response}

  defp validate_list(body, valid_item?) when is_list(body) do
    case Enum.all?(body, valid_item?) do
      true -> {:ok, body}
      false -> {:error, :invalid_response}
    end
  end

  defp validate_list(_body, _valid_item?), do: {:error, :invalid_response}

  defp request_progress(method, path, opts \\ []) do
    with {:ok, body} <-
           request(
             method,
             path,
             Keyword.merge(opts, decode_body: false, receive_timeout: :infinity)
           ) do
      parse_progress(body)
    end
  end

  defp parse_progress(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, messages} ->
      case Jason.decode(line) do
        {:ok, %{"type" => "error"}} ->
          {:halt, {:error, :operation_failed}}

        {:ok, %{"type" => type} = message} when is_binary(type) ->
          {:cont, {:ok, [message | messages]}}

        _invalid_message ->
          {:halt, {:error, :invalid_response}}
      end
    end)
    |> completed_progress()
  end

  defp parse_progress(_invalid_body), do: {:error, :invalid_response}

  defp completed_progress({:ok, [%{"type" => "complete"} | _earlier] = messages}),
    do: {:ok, Enum.reverse(messages)}

  defp completed_progress({:ok, _incomplete_messages}), do: {:error, :invalid_response}
  defp completed_progress({:error, _reason} = error), do: error

  defp file_params(path, opts),
    do: [path: path, workingDir: Keyword.get(opts, :working_dir, "/")]

  defp valid_file_entry?(%{"name" => name, "path" => path, "isDir" => directory?})
       when is_binary(name) and is_binary(path) and is_boolean(directory?),
       do: true

  defp valid_file_entry?(_entry), do: false

  defp delete_resource(path, opts \\ []) do
    case request(:delete, path, opts) do
      {:ok, _body} -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp sprite_path(name, suffix \\ ""), do: "/v1/sprites/" <> encode_segment(name) <> suffix
  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp request(method, path, opts \\ []) do
    with {:ok, config} <- configured() do
      config
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(opts)
      |> Keyword.merge(
        method: method,
        url: String.trim_trailing(Keyword.get(config, :base_url, @base_url), "/") <> path,
        auth: {:bearer, Keyword.fetch!(config, :token)},
        redirect: false,
        retry: false,
        retry_log_level: false
      )
      |> Req.request()
      |> normalize_response()
    end
  end

  defp configured do
    config = Application.get_env(:hermitscale, __MODULE__, [])

    case Keyword.get(config, :token) do
      token when is_binary(token) and byte_size(token) > 0 -> {:ok, config}
      _missing -> {:error, :not_configured}
    end
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp normalize_response({:ok, %Req.Response{status: status}}), do: status_error(status)
  defp normalize_response({:error, _transport_error}), do: {:error, :unavailable}

  defp status_error(401), do: {:error, :unauthorized}
  defp status_error(403), do: {:error, :forbidden}
  defp status_error(404), do: {:error, :not_found}
  defp status_error(409), do: {:error, :conflict}
  defp status_error(429), do: {:error, :rate_limited}

  defp status_error(status) when status in [400, 413, 422],
    do: {:error, {:invalid_request, status}}

  defp status_error(status) when status >= 500, do: {:error, :unavailable}
  defp status_error(status), do: {:error, {:unexpected_status, status}}

  defp validate_sprite(
         %{"id" => id, "name" => name, "status" => status, "url" => url} = body,
         name
       )
       when is_binary(id) and id != "" and status in ["cold", "warm", "running"] and
              is_binary(url),
       do: {:ok, body}

  defp validate_sprite(_invalid_body, _name), do: {:error, :invalid_response}
end
