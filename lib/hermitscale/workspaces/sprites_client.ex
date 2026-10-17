defmodule Hermitscale.Workspaces.SpritesClient do
  @moduledoc """
  Fly Sprites client. REST calls use Req; commands use the official SDK's
  WebSocket transport; WebSockets to Sprite URLs use Mint.WebSocket.

  Configure `:token`, `:base_url`, and optional `:req_options` under this module.
  Non-2xx responses return `{:error, :not_found}`, `{:error, :conflict}`, or
  `{:error, {:http_error, status, body}}`.
  """

  @base_url "https://api.sprites.dev"

  def create(name),
    do: request(:post, "/v1/sprites", json: %{name: name}, receive_timeout: 120_000)

  def get(name), do: request(:get, sprite_path(name))

  def delete(name) do
    case request(:delete, sprite_path(name)) do
      {:ok, _body} -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def update_url_settings(name, settings),
    do: request(:put, sprite_path(name), json: %{url_settings: settings})

  def read_file(name, path),
    do: request(:get, sprite_path(name, "/fs/read"), params: [path: path], decode_body: false)

  def write_file(name, path, bytes, opts \\ []) do
    request(:put, sprite_path(name, "/fs/write"),
      params: [path: path] ++ Keyword.take(opts, [:mode, :mkdir]),
      body: IO.iodata_to_binary(bytes),
      headers: [{"content-type", "application/octet-stream"}]
    )
  end

  def list_files(name, path),
    do: request(:get, sprite_path(name, "/fs/list"), params: [path: path])

  def delete_file(name, path, opts \\ []) do
    with {:ok, _body} <-
           request(:delete, sprite_path(name, "/fs/delete"),
             json: %{path: path, recursive: Keyword.get(opts, :recursive, false)}
           ) do
      :ok
    end
  end

  def list_checkpoints(name), do: request(:get, sprite_path(name, "/checkpoints"))

  def create_checkpoint(name, opts \\ []) do
    progress(:post, sprite_path(name, "/checkpoint"),
      json: Map.new(Keyword.take(opts, [:comment]))
    )
  end

  def restore_checkpoint(name, checkpoint_id),
    do: progress(:post, sprite_path(name, "/checkpoints/#{encode(checkpoint_id)}/restore"))

  def list_sessions(name) do
    with {:ok, %{"sessions" => sessions}} <- request(:get, sprite_path(name, "/exec")) do
      {:ok, sessions}
    end
  end

  def kill_session(name, session_id, opts \\ []) do
    progress(:post, sprite_path(name, "/exec/#{encode(to_string(session_id))}/kill"),
      params: Keyword.take(opts, [:signal, :timeout])
    )
  end

  def list_services(name), do: request(:get, sprite_path(name, "/services"))

  def get_service(name, service), do: request(:get, service_path(name, service))

  def put_service(name, service, attrs),
    do: request(:put, service_path(name, service), json: attrs)

  def delete_service(name, service) do
    with {:ok, _body} <- request(:delete, service_path(name, service)), do: :ok
  end

  @doc """
  Sends a request to a private Sprite URL with the API token. The response body
  is a `Req.Response.Async` stream owned by the caller.
  """
  def url_request(url, opts) do
    config = config()

    [
      url: url,
      auth: {:bearer, Keyword.fetch!(config, :token)},
      into: :self,
      raw: true,
      compressed: false,
      redirect: false,
      retry: false,
      receive_timeout: 60_000
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(opts)
    |> Req.request()
  end

  @doc """
  Opens a WebSocket to a private Sprite URL with the API token and completes the
  handshake. The connection is in active mode and owned by the caller.

  Returns `%{conn: conn, ref: ref, websocket: websocket, headers: headers, data: data}`,
  where `data` holds frame bytes that arrived with the handshake. A non-101 reply
  returns `{:error, %Mint.WebSocket.UpgradeFailureError{}}`.
  """
  def url_websocket(url, headers, opts \\ []) do
    token = Keyword.fetch!(config(), :token)
    timeout = Keyword.get(opts, :timeout, 15_000)
    uri = URI.parse(url)
    {scheme, ws_scheme} = if uri.scheme == "https", do: {:https, :wss}, else: {:http, :ws}
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    with {:ok, conn} <-
           Mint.HTTP.connect(scheme, uri.host, uri.port,
             protocols: [:http1],
             mode: :passive,
             transport_opts: [timeout: timeout]
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [
             {"authorization", "Bearer " <> token} | headers
           ]),
         {:ok, conn, response} <- await_upgrade(conn, ref, %{data: []}, timeout),
         {:ok, conn, websocket} <-
           Mint.WebSocket.new(conn, ref, response.status, response.headers),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :active) do
      {:ok,
       %{
         conn: conn,
         ref: ref,
         websocket: websocket,
         headers: response.headers,
         data: IO.iodata_to_binary(response.data)
       }}
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_upgrade(conn, ref, response, timeout) do
    case Mint.WebSocket.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        response = Enum.reduce(responses, response, &collect_upgrade(&1, ref, &2))

        case response do
          %{done: true} -> {:ok, conn, response}
          _pending -> await_upgrade(conn, ref, response, timeout)
        end

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  defp collect_upgrade({:status, ref, status}, ref, response),
    do: Map.put(response, :status, status)

  defp collect_upgrade({:headers, ref, headers}, ref, response),
    do: Map.put(response, :headers, headers)

  defp collect_upgrade({:done, ref}, ref, response), do: Map.put(response, :done, true)

  defp collect_upgrade({:data, ref, data}, ref, %{done: true} = response),
    do: Map.update!(response, :data, &[&1, data])

  defp collect_upgrade(_body_or_other, _ref, response), do: response

  @doc """
  Starts a command and sends its events to `:owner` (default: the caller):
  `{:stdout | :stderr, %{ref: ref}, bytes}`, `{:exit, %{ref: ref}, code}`,
  `{:error, %{ref: ref}, reason}`, and with `session_info: true`,
  `{:session_info, %{ref: ref}, session_id}`.

  The local transport closes when the owner exits. Use `Sprites.write/2`,
  `Sprites.close_stdin/1`, and `Sprites.resize/3` on the returned handle.
  """
  def spawn(name, command, args \\ [], opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    sdk_opts =
      opts
      |> Keyword.take([:env, :dir, :tty, :tty_rows, :tty_cols, :stdin, :session_info])
      |> Keyword.put(:owner, owner)

    with {:ok, command} <- Sprites.spawn(sdk_sprite(name), command, args, sdk_opts) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Hermitscale.Workspaces.CommandSupervisor, fn ->
          close_with_owner(command, owner)
        end)

      {:ok, %{command | sprite: nil}}
    end
  end

  @doc "Runs a command to completion. Accepts `spawn/4` options and `:timeout`."
  def execute(name, command, args \\ [], opts \\ []) do
    with {:ok, handle} <- spawn(name, command, args, Keyword.put(opts, :owner, self())) do
      collect(handle, [], [], Keyword.get(opts, :timeout, :infinity))
    end
  end

  defp collect(%{ref: ref} = handle, stdout, stderr, timeout) do
    receive do
      {:stdout, %{ref: ^ref}, bytes} ->
        collect(handle, [stdout, bytes], stderr, timeout)

      {:stderr, %{ref: ^ref}, bytes} ->
        collect(handle, stdout, [stderr, bytes], timeout)

      {:exit, %{ref: ^ref}, code} ->
        {:ok,
         %{
           stdout: IO.iodata_to_binary(stdout),
           stderr: IO.iodata_to_binary(stderr),
           exit_code: code
         }}

      {:error, %{ref: ^ref}, reason} ->
        {:error, reason}

      {_event, %{ref: ^ref}, _data} ->
        collect(handle, stdout, stderr, timeout)
    after
      timeout ->
        GenServer.stop(handle.pid, :normal)
        {:error, :timeout}
    end
  end

  defp close_with_owner(command, owner) do
    owner_ref = Process.monitor(owner)
    command_ref = Process.monitor(command.pid)

    receive do
      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        GenServer.stop(command.pid, :normal)

      {:DOWN, ^command_ref, :process, _pid, _reason} ->
        :ok
    end
  catch
    :exit, _command_already_stopped -> :ok
  end

  defp sdk_sprite(name) do
    config = config()

    config
    |> Keyword.fetch!(:token)
    |> Sprites.new(base_url: Keyword.get(config, :base_url, @base_url))
    |> Sprites.sprite(name)
  end

  defp progress(method, path, opts \\ []) do
    with {:ok, body} <-
           request(
             method,
             path,
             Keyword.merge(opts, decode_body: false, receive_timeout: :infinity)
           ) do
      messages = body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      case Enum.find(messages, &(&1["type"] == "error")) do
        nil -> {:ok, messages}
        error -> {:error, {:operation_failed, error}}
      end
    end
  end

  defp request(method, path, opts \\ []) do
    config = config()

    [
      method: method,
      base_url: Keyword.get(config, :base_url, @base_url),
      url: path,
      auth: {:bearer, Keyword.fetch!(config, :token)},
      retry: false
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Keyword.merge(opts)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: 409}} -> {:error, :conflict}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp config do
    config = Application.get_env(:hermitscale, __MODULE__, [])

    case Keyword.get(config, :token) do
      token when is_binary(token) and token != "" -> config
      _missing -> raise "Sprites token is not configured; set SPRITES_API_KEY"
    end
  end

  defp sprite_path(name, suffix \\ ""), do: "/v1/sprites/" <> encode(name) <> suffix
  defp service_path(name, service), do: sprite_path(name, "/services/" <> encode(service))
  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
