defmodule Hermitscale.Workspaces.SpritesManagement do
  @moduledoc """
  Private Req adapter for retained Sprite allocation.

  Inspect before creating and reconcile uncertain creation by the exact stored name.
  The token is server configuration and never reaches a workspace, a result, or logs.
  This adapter does not qualify coding execution, network policy, or termination.
  Sources: https://docs.fly.io/sprites/api/sprites/create-a-sprite and
  https://docs.fly.io/sprites/api/sprites/get-a-sprite.
  """
  @behaviour Hermitscale.Workspaces.Management
  alias Hermitscale.Workspaces.{Workspace, SpriteAccess, SpriteSDK}

  @base_url "https://api.sprites.dev"

  @impl true
  def ensure_allocated(%Workspace{} = workspace) do
    with {:ok, request} <- request() do
      case inspect_sprite(request, workspace) do
        {:ok, metadata} -> {:ok, metadata}
        {:error, :not_found} -> create_and_reconcile(request, workspace)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def verify_termination(workspace, lease, evidence) do
    with {:ok, proof} <- termination_evidence(workspace, lease) do
      if proof == evidence, do: :ok, else: {:error, :termination_unverified}
    end
  end

  def termination_evidence(workspace, lease) do
    script = """
    import os, json, hashlib, sys, pwd
    workspace, lease, operation, generation = sys.argv[1:]
    path = '/var/lib/hermitscale/control/groups/' + lease + '.json'
    forced = '/var/lib/hermitscale/control/forced/' + lease + '.json'
    journal = '/var/lib/hermitscale/control/journal.ndjson'
    if os.path.exists(journal):
        with open(journal) as f: records = f.read().splitlines()
        data = json.loads(records[-1])
        active = data.get('active_operation')
        if active and not data['operations'][active].get('termination_confirmed') and not os.path.exists(forced): sys.exit(76)
    groups = json.load(open(path)) if os.path.exists(path) else []
    for pid in groups:
        try: os.killpg(pid, 0); sys.exit(76)
        except ProcessLookupError: pass
        except PermissionError: sys.exit(76)
    coder=pwd.getpwnam('hermitcoder').pw_uid
    for entry in os.scandir('/proc'):
        if not entry.name.isdecimal(): continue
        try:
            if entry.stat().st_uid==coder and open(entry.path+'/stat').read().rsplit(')',1)[1].split()[0]!='Z': sys.exit(76)
        except ProcessLookupError: pass
        except FileNotFoundError: pass
    proof = {'workspace_id': workspace, 'lease_id': lease, 'operation_key': operation,
             'generation': int(generation), 'writer_stopped': True}
    proof['receipt'] = hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()
    print(json.dumps(proof))
    """

    with {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0, output: output}} <-
           SpriteSDK.capture(
             sprite,
             "sudo",
             [
               "-n",
               "python3",
               "-I",
               "-c",
               script,
               workspace.id,
               lease.id,
               lease.operation_key,
               to_string(lease.generation)
             ],
             timeout: 10_000,
             output_limit: 4096
           ),
         {:ok, proof} <- Jason.decode(output) do
      {:ok, proof}
    else
      {:ok, %{exit_code: 76}} -> {:error, :writer_still_running}
      {:ok, %{exit_code: _code}} -> {:error, :termination_unverified}
      {:error, _reason} = error -> error
    end
  end

  def terminate_admitted(workspace, lease) do
    stopped =
      case stop_service(workspace, "hs-worker") do
        {:ok, _service} -> :ok
        {:error, :not_found} -> :ok
        {:error, _reason} = error -> error
      end

    with :ok <- stopped,
         {:ok, sprite} <- SpriteAccess.sprite(workspace) do
      script = """
      import os,sys,json,time,signal,pwd
      lease, generation = sys.argv[1:]
      base = '/var/lib/hermitscale/control'
      path = base + '/groups/' + lease + '.json'
      groups = json.load(open(path)) if os.path.exists(path) else []
      for pid in groups:
          try: os.killpg(pid, signal.SIGKILL)
          except ProcessLookupError: pass
      deadline = time.monotonic() + 5
      while True:
          live=[]
          for pid in groups:
              try: os.killpg(pid,0); live.append(pid)
              except ProcessLookupError: pass
          if not live: break
          if time.monotonic()>deadline: sys.exit(76)
          time.sleep(0.05)
      coder=pwd.getpwnam('hermitcoder').pw_uid
      def coder_processes():
          result=[]
          for entry in os.scandir('/proc'):
              if not entry.name.isdecimal(): continue
              try:
                  if entry.stat().st_uid==coder and open(entry.path+'/stat').read().rsplit(')',1)[1].split()[0]!='Z': result.append(int(entry.name))
              except ProcessLookupError: pass
              except FileNotFoundError: pass
          return result
      stop_deadline=time.monotonic()+5
      while coder_processes():
          for pid in coder_processes():
              try: os.kill(pid,signal.SIGKILL)
              except ProcessLookupError: pass
          if time.monotonic()>=stop_deadline: sys.exit(76)
          time.sleep(0.05)
      os.makedirs(base+'/forced',mode=0o700,exist_ok=True)
      with open(base+'/forced/'+lease+'.json','w') as f:
          json.dump({'lease_id':lease,'generation':int(generation)},f); f.flush(); os.fsync(f.fileno())
      """

      case SpriteSDK.capture(
             sprite,
             "sudo",
             ["-n", "python3", "-I", "-c", script, lease.id, to_string(lease.generation)],
             timeout: 10_000,
             output_limit: 4096
           ) do
        {:ok, %{exit_code: 0}} -> termination_evidence(workspace, lease)
        {:ok, %{exit_code: _code}} -> {:error, :termination_unverified}
        {:error, _reason} = error -> error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  def release_hold(workspace, lease) do
    with {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0}} <-
           SpriteSDK.capture(
             sprite,
             "sudo",
             [
               "-n",
               "curl",
               "--silent",
               "--show-error",
               "--unix-socket",
               "/.sprite/api.sock",
               "-X",
               "DELETE",
               "http://sprite/v1/tasks/hs-" <> lease.id
             ],
             timeout: 10_000,
             output_limit: 4096
           ),
         do: :ok
  end

  def ensure_service(workspace, name, spec) do
    body = %{
      cmd: spec.command,
      args: spec.args,
      dir: spec.cwd,
      http_port: Map.get(spec, :http_port),
      env: Map.get(spec, :env, %{})
    }

    case inspect_service(workspace, name) do
      {:ok, %{"cmd" => cmd, "args" => args, "dir" => dir} = service}
      when cmd == spec.command and args == spec.args and dir == spec.cwd ->
        if Map.get(service, "env", %{}) == Map.get(spec, :env, %{}) and
             Map.get(service, "http_port") == Map.get(spec, :http_port),
           do: start_existing_service(workspace, name, service),
           else: replace_existing_service(workspace, name, body)

      {:ok, _different_service} ->
        replace_existing_service(workspace, name, body)

      {:error, :not_found} ->
        replace_service(workspace, name, body)

      {:error, _reason} = error ->
        error
    end
  end

  defp replace_service(workspace, name, body) do
    with {:ok, _service} <- operation(workspace, :put, "/services/" <> name, body),
         {:ok, _started} <- operation(workspace, :post, "/services/" <> name <> "/start", %{}) do
      operation(workspace, :get, "/services/" <> name)
    end
  end

  defp replace_existing_service(workspace, name, body) do
    with {:ok, _stopped} <- stop_service(workspace, name),
         {:ok, _deleted} <- operation(workspace, :delete, "/services/" <> name) do
      replace_service(workspace, name, body)
    end
  end

  defp start_existing_service(_workspace, _name, %{"state" => %{"status" => status}} = service)
       when status in ["running", "starting"],
       do: {:ok, service}

  defp start_existing_service(workspace, name, _service) do
    with {:ok, _started} <- operation(workspace, :post, "/services/" <> name <> "/start", %{}),
         do: inspect_service(workspace, name)
  end

  def inspect_service(workspace, name), do: operation(workspace, :get, "/services/" <> name)

  def stop_service(workspace, name),
    do: operation(workspace, :post, "/services/" <> name <> "/stop", %{})

  def service_logs(workspace, limit) do
    with {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0, output: logs}} <-
           SpriteSDK.capture(
             sprite,
             "tail",
             ["-n", to_string(limit), "/.sprite/logs/services/hs-app.log"],
             timeout: 5000,
             output_limit: 65_536
           ) do
      {:ok, logs}
    else
      {:ok, %{exit_code: _code}} -> {:error, :logs_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def set_app_access(workspace, access) do
    auth = if access == :public, do: "public", else: "sprite"

    with {:ok, _updated} <- operation(workspace, :put, "", %{url_settings: %{auth: auth}}),
         do: :ok
  end

  def network_policy(workspace, domains) do
    rules = Enum.map(domains, &%{domain: &1, action: "allow"}) ++ [%{domain: "*", action: "deny"}]

    with {:ok, _response} <- operation(workspace, :post, "/policy/network", %{rules: rules}) do
      operation(workspace, :get, "/policy/network")
    end
  end

  def operation(workspace, method, suffix, body \\ nil) do
    with {:ok, request} <- request() do
      options = [
        method: method,
        url:
          "/v1/sprites/" <> URI.encode(workspace.sprite_name, &URI.char_unreserved?/1) <> suffix
      ]

      options = if is_nil(body), do: options, else: Keyword.put(options, :json, body)

      case Req.request(request, options) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
        {:ok, %Req.Response{status: status}} -> normalize_status(status)
        {:error, _transport_error} -> {:error, :provider_unavailable}
      end
    end
  end

  def token do
    case Keyword.fetch(Application.get_env(:hermitscale, __MODULE__, []), :token) do
      :error -> {:error, :sprites_token_missing}
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _invalid} -> {:error, :invalid_management_configuration}
    end
  end

  def app_request(workspace, path, options) do
    options = Keyword.validate!(options, method: :get, body: nil, headers: [])

    with {:ok, url} <- app_url(workspace), {:ok, token} <- token() do
      headers =
        Enum.reject(Keyword.fetch!(options, :headers), fn {name, _value} ->
          String.downcase(name) in ~w(authorization proxy-authorization host connection transfer-encoding)
        end)

      request = [
        url: url <> path,
        auth: {:bearer, token},
        method: Keyword.fetch!(options, :method),
        body: Keyword.fetch!(options, :body),
        headers: headers,
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: 30_000,
        into: :self
      ]

      case Req.request(request) do
        {:ok, response} -> bounded_app_body(response)
        {:error, _reason} -> {:error, :app_unavailable}
      end
    end
  end

  def app_url(workspace) do
    with {:ok, %{"name" => name, "url" => url}} <-
           operation(workspace, :get, ""),
         true <- name == workspace.sprite_name,
         %URI{scheme: "https", host: host, userinfo: nil, port: 443, path: path} <-
           URI.parse(url),
         true <-
           is_binary(host) and String.ends_with?(host, ".sprites.app") and path in [nil, "", "/"] do
      {:ok, String.trim_trailing(url, "/")}
    else
      false -> {:error, :invalid_app_upstream}
      {:error, _reason} = error -> error
      _invalid_metadata -> {:error, :invalid_app_upstream}
    end
  end

  defp bounded_app_body(response) do
    case collect_app_body(response, "") do
      {:ok, body} ->
        {:ok, %{status: response.status, headers: response.headers, body: body}}

      {:error, reason} ->
        Req.cancel_async_response(response)
        {:error, reason}
    end
  end

  defp collect_app_body(response, body) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, [{:data, data}]} when byte_size(body) + byte_size(data) <= 1_048_576 ->
            collect_app_body(response, body <> data)

          {:ok, [{:data, _data}]} ->
            {:error, :app_response_too_large}

          {:ok, [:done]} ->
            {:ok, body}

          {:ok, [{:trailers, _headers}]} ->
            collect_app_body(response, body)

          {:error, _reason} ->
            {:error, :app_unavailable}

          :unknown ->
            collect_app_body(response, body)
        end
    after
      30_000 -> {:error, :app_response_timeout}
    end
  end

  defp create_and_reconcile(request, workspace) do
    result =
      Req.post(request,
        url: "/v1/sprites",
        json: %{name: workspace.sprite_name, url_settings: %{auth: "sprite"}}
      )

    case result do
      {:ok, %Req.Response{status: 201, body: body}} ->
        normalize_metadata(body, workspace)

      {:ok, %Req.Response{status: status}} when status in [400, 409, 429, 500, 502, 503, 504] ->
        reconcile_creation(request, workspace)

      {:error, _transport_error} ->
        reconcile_creation(request, workspace)

      {:ok, %Req.Response{status: status}} ->
        normalize_status(status)
    end
  end

  defp reconcile_creation(request, workspace) do
    case inspect_sprite(request, workspace) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, :not_found} -> {:error, :allocation_uncertain}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_sprite(request, workspace) do
    case Req.get(request,
           url: "/v1/sprites/" <> URI.encode(workspace.sprite_name, &URI.char_unreserved?/1)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> normalize_metadata(body, workspace)
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> normalize_status(status)
      {:error, _transport_error} -> {:error, :provider_unavailable}
    end
  end

  defp normalize_metadata(
         %{"name" => name, "status" => status, "url_settings" => %{"auth" => "sprite"}},
         %{sprite_name: name}
       ) do
    case status do
      "cold" -> {:ok, %{compute_state: :sleeping}}
      "warm" -> {:ok, %{compute_state: :sleeping}}
      "running" -> {:ok, %{compute_state: :running}}
      _unknown_status -> {:error, :invalid_provider_response}
    end
  end

  defp normalize_metadata(_body, _workspace), do: {:error, :invalid_provider_response}

  defp normalize_status(status) when status in 300..399, do: {:error, :redirect_not_allowed}
  defp normalize_status(status) when status in [401, 403], do: {:error, :provider_unauthorized}
  defp normalize_status(429), do: {:error, :provider_rate_limited}
  defp normalize_status(status) when status in 500..599, do: {:error, :provider_unavailable}
  defp normalize_status(_status), do: {:error, :invalid_provider_response}

  defp request do
    config = Application.get_env(:hermitscale, __MODULE__, [])

    case Keyword.fetch(config, :token) do
      :error ->
        {:error, :sprites_token_missing}

      {:ok, token} when is_binary(token) and token != "" ->
        options = Keyword.take(config, [:plug])

        {:ok,
         Req.new(
           [
             base_url: Keyword.get(config, :base_url, @base_url),
             auth: {:bearer, token},
             retry: false,
             redirect: false,
             receive_timeout: 15_000,
             connect_options: [timeout: 5_000]
           ] ++ options
         )}

      {:ok, _invalid_token} ->
        {:error, :invalid_management_configuration}
    end
  end
end
