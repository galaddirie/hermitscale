defmodule Hermitscale.Workspaces.Recipe do
  @moduledoc "Pinned worker/provider installation and retained checkout preparation."
  alias Hermitscale.Workspaces.{SpriteAccess, SpriteSDK, SpritesManagement, WorkerClient}
  @root Path.expand("../../..", __DIR__)
  @source_paths Path.wildcard(Path.join(@root, "workspace_worker/lib/**/*.ex")) ++
                  Path.wildcard(Path.join(@root, "workspace_worker/config/*.exs")) ++
                  Enum.map(~w(mix.exs mix.lock), &Path.join(@root, "workspace_worker/" <> &1)) ++
                  Path.wildcard(Path.join(@root, "priv/workspace_protocol/v1/lib/**/*.ex")) ++
                  [Path.join(@root, "priv/workspace_protocol/v1/mix.exs")]
  for path <- @source_paths, do: @external_resource(path)

  @sources Map.new(@source_paths, fn path -> {Path.relative_to(path, @root), File.read!(path)} end)
  @launcher_path Path.join(@root, "priv/workspace_launchers/sandbox-launch.py")
  @external_resource @launcher_path
  @source_seed_path Path.join(@root, "priv/workspace_launchers/source_seed.py")
  @external_resource @source_seed_path
  @source_seed_script File.read!(@source_seed_path)

  @provider_version "0.162.1"
  @adapter_version "1.6.2"
  @scaffold_path Path.join(@root, "priv/app_recipes/python_sqlite_v1/app.py")
  @external_resource @scaffold_path
  @scaffold File.read!(@scaffold_path)
  @scaffold_test_path Path.join(@root, "priv/app_recipes/python_sqlite_v1/test_app.py")
  @external_resource @scaffold_test_path
  @scaffold_test File.read!(@scaffold_test_path)

  @installer """
  import os, sys, json, subprocess, shutil
  bundle = json.load(sys.stdin)
  files = bundle['files']
  root = '/opt/hermitscale/source'
  for path, content in files.items():
      target = os.path.join(root, path)
      os.makedirs(os.path.dirname(target), exist_ok=True)
      with open(target, 'w') as f: f.write(content)
  os.makedirs('/workspace', exist_ok=True)
  subprocess.run(['id', '-u', 'hermitcoder'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0 or subprocess.run(['useradd','--create-home','--shell','/bin/bash','hermitcoder'], check=True)
  subprocess.run(['chown', 'hermitcoder:hermitcoder', '/workspace'], check=True)
  for path in ['/var/lib/hermitscale/control/groups', '/run/hermitscale', '/opt/hermitscale/bin']:
      os.makedirs(path, mode=0o700, exist_ok=True)
  import pwd
  worker_user = pwd.getpwnam('hermitworker')
  for private in ['/var/lib/hermitscale/control','/var/lib/hermitscale/control/groups','/run/hermitscale']:
      os.chown(private,worker_user.pw_uid,worker_user.pw_gid); os.chmod(private,0o700)
  log = open('/opt/hermitscale/install.log', 'a')
  env = dict(os.environ, MIX_ENV='prod', HOME='/root', PATH='/.sprite/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
  node_path=subprocess.check_output(['node','-p','process.execPath'],env=env).decode().strip()
  shutil.copyfile(node_path,'/opt/hermitscale/bin/node'); os.chown('/opt/hermitscale/bin/node',0,0); os.chmod('/opt/hermitscale/bin/node',0o755)
  subprocess.run(['npm', 'install', '--prefix', '/opt/hermitscale/provider', '@openai/codex@0.162.1', '@agentclientprotocol/codex-acp@1.6.2'], env=env, check=True, stdout=log, stderr=subprocess.STDOUT)
  wrapper = '/opt/hermitscale/bin/codex-acp'
  with open(wrapper, 'w') as f:
      f.write('#!/usr/bin/python3 -I\\nimport os,json,sys\\nb="/var/lib/hermitscale/control"\\nlease=json.load(open(b+"/lease.json"))["lease_id"]\\np=b+"/groups/"+lease+".json"\\ngroups=json.load(open(p)) if os.path.exists(p) else []\\npid=os.getpgrp()\\nif pid not in groups: groups.append(pid)\\nwith open(p+".tmp","w") as f: json.dump(groups,f); f.flush(); os.fsync(f.fileno())\\nos.replace(p+".tmp",p)\\nos.execv("/usr/bin/sudo",["sudo","-n","--","/opt/hermitscale/bin/sandbox-launch","provider"]+sys.argv[1:])\\n')
  os.chmod(wrapper, 0o755)
  service = '/opt/hermitscale/bin/start-worker'
  with open(service,'w') as f:
      f.write('#!/usr/bin/python3 -I\\nimport os,json,sys\\nconfig=json.load(open("/var/lib/hermitscale/control/worker-env.json"))\\nallowed={"WORKSPACE_WORKER_ENABLED","WORKSPACE_BUNDLE_ID","WORKSPACE_ID","WORKSPACE_JOURNAL_PATH","WORKSPACE_CONTROL_SOCKET","WORKSPACE_CONTROL_TOKEN_FILE","WORKSPACE_CONTROL_DEADLINE","WORKSPACE_PROVIDER_ENV_FILE","WORKSPACE_LEASE_FILE","WORKSPACE_PROVIDER_SESSION_FILE","WORKSPACE_CWD","WORKSPACE_ACP_PATH","HOME","PATH"}\\nif not isinstance(config,dict) or any(k not in allowed or not isinstance(v,str) for k,v in config.items()): raise ValueError("invalid worker configuration")\\nif len(sys.argv)!=2 or sys.argv[1]!=config["WORKSPACE_BUNDLE_ID"]: raise ValueError("worker bundle mismatch")\\nconfig.update(PATH="/.sprite/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",HOME="/home/hermitworker",SHELL="/bin/bash",LANG="C.UTF-8",USER="hermitworker",LOGNAME="hermitworker")\\nos.execve("/usr/sbin/runuser",["runuser","-u","hermitworker","--preserve-environment","--","/opt/hermitscale/source/workspace_worker/_build/prod/rel/workspace_worker/bin/workspace_worker","start"],config)\\n')
  os.chown(service,0,0); os.chmod(service,0o755)
  worker = os.path.join(root, 'workspace_worker')
  for args in [['mix','local.hex','--force'],['mix','local.rebar','--force'],['mix','deps.get','--only','prod'],['mix','deps.compile'],['mix','compile','--warnings-as-errors'],['mix','release','--overwrite']]:
      subprocess.run(args, cwd=worker, env=env, check=True, stdout=log, stderr=subprocess.STDOUT)
  with open('/opt/hermitscale/worker-ready', 'w') as f: f.write(bundle['digest'])
  """

  @bundle_digest :crypto.hash(
                   :sha256,
                   :erlang.term_to_binary({@sources, @installer, File.read!(@launcher_path)})
                 )
                 |> Base.encode16(case: :lower)

  def prepare(workspace, lease, _turn, provider_env, options \\ []) do
    provider_env =
      Map.merge(
        %{
          "PATH" =>
            "/opt/hermitscale/bin:/opt/hermitscale/provider/node_modules/.bin:/.sprite/bin:/usr/local/bin:/usr/bin:/bin",
          "HOME" => "/home/hermitcoder",
          "CODEX_HOME" => "/workspace/.codex"
        },
        provider_env
      )

    with :ok <- valid_provider_env(provider_env),
         {:ok, sprite} <- SpriteAccess.sprite(workspace),
         :ok <- Hermitscale.Workspaces.Foundation.prepare(sprite),
         :ok <-
           initialize_checkout(
             sprite,
             workspace,
             Keyword.get(options, :source_credential)
           ),
         :ok <- ensure_worker(sprite),
         {:ok, _policy} <-
           SpritesManagement.network_policy(workspace, allowed_domains(provider_env)),
         {:ok, token} <- WorkerClient.control_token(workspace),
         :ok <- deliver_configuration(sprite, workspace, lease, token, provider_env),
         {:ok, _service} <-
           SpritesManagement.ensure_service(workspace, "hs-worker", %{
             command: "sudo",
             args: ["-n", "/opt/hermitscale/bin/start-worker", @bundle_digest],
             cwd: "/workspace",
             env: %{},
             http_port: nil
           }),
         :ok <- await_control(workspace, lease, System.monotonic_time(:millisecond) + 10_000) do
      {:ok, workspace}
    end
  end

  defp await_control(workspace, lease, deadline) do
    payload = %{}

    command = %{
      "version" => 1,
      "workspace_id" => workspace.id,
      "operation_id" => "worker-ready",
      "generation" => lease.generation,
      "command_id" => Ecto.UUID.generate(),
      "deadline" => DateTime.to_iso8601(lease.deadline),
      "type" => "inspect",
      "payload" => payload,
      "payload_digest" => Hermitscale.WorkspaceProtocol.V1.payload_digest(payload)
    }

    case WorkerClient.command(workspace, lease, command) do
      {:error, :operation_not_found} ->
        :ok

      {:ok, _status} ->
        :ok

      {:error, :worker_unavailable} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          await_control(workspace, lease, deadline)
        else
          {:error, :worker_startup_timeout}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def sources, do: @sources

  def install(sprite) do
    with :ok <- Hermitscale.Workspaces.Foundation.prepare(sprite), do: ensure_worker(sprite)
  end

  def versions, do: %{codex: @provider_version, codex_acp: @adapter_version}

  defp allowed_domains(env) do
    gateway = URI.parse(Map.fetch!(env, "OPENAI_BASE_URL")).host

    [
      gateway
      | ~w(github.com raw.githubusercontent.com codeload.github.com registry.npmjs.org pypi.org files.pythonhosted.org hex.pm repo.hex.pm builds.hex.pm)
    ]
  end

  defp ensure_worker(sprite) do
    case SpriteSDK.capture(sprite, "cat", ["/opt/hermitscale/worker-ready"], timeout: 5000) do
      {:ok, %{exit_code: 0, output: digest}} when digest == @bundle_digest ->
        :ok

      {:ok, %{exit_code: _code}} ->
        case SpriteSDK.capture(sprite, "sudo", ["-n", "python3", "-I", "-c", @installer],
               stdin: Jason.encode!(%{files: @sources, digest: @bundle_digest}),
               timeout: 600_000,
               output_limit: 262_144
             ) do
          {:ok, %{exit_code: 0}} -> :ok
          {:ok, %{exit_code: _code}} -> {:error, :worker_install_failed}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp initialize_checkout(sprite, workspace, source_credential) do
    setup = @source_seed_script

    config = %{
      repository: workspace.repository,
      base_sha: workspace.base_sha,
      source_credential: credential_value(source_credential),
      recipe: workspace.recipe,
      scaffold: @scaffold,
      scaffold_test: @scaffold_test
    }

    case SpriteSDK.capture(sprite, "sudo", ["-n", "python3", "-I", "-c", setup],
           stdin: Jason.encode!(config),
           timeout: 90_000,
           output_limit: 8192
         ) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: 77}} -> {:error, :invalid_repository}
      {:ok, %{exit_code: _code}} -> {:error, :source_checkout_failed}
      {:error, _reason} = error -> error
    end
  end

  defp deliver_configuration(sprite, workspace, lease, token, env) do
    script = """
    import os, json, sys
    config = json.load(sys.stdin)
    import pwd
    worker_user = pwd.getpwnam('hermitworker')
    base = '/var/lib/hermitscale/control'
    os.makedirs(base + '/groups', mode=0o700, exist_ok=True)
    os.makedirs('/run/hermitscale', mode=0o700, exist_ok=True)
    for name, value in config.items():
        path = base + '/' + name
        tmp = path + '.tmp'
        with open(tmp, 'w') as f: f.write(value); f.flush(); os.fsync(f.fileno())
        os.chown(tmp,worker_user.pw_uid,worker_user.pw_gid); os.chmod(tmp, 0o600); os.replace(tmp, path)
    """

    files = %{
      "token" => token,
      "worker-env.json" => Jason.encode!(worker_env(workspace)),
      "provider-env.json" => Jason.encode!(env),
      "lease.json" =>
        Jason.encode!(%{
          workspace_id: workspace.id,
          lease_id: lease.id,
          operation_key: lease.operation_key,
          generation: lease.generation,
          deadline: DateTime.to_iso8601(lease.deadline)
        })
    }

    case SpriteSDK.capture(sprite, "sudo", ["-n", "python3", "-I", "-c", script],
           stdin: Jason.encode!(files),
           timeout: 10_000,
           output_limit: 8192
         ) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: _code}} -> {:error, :worker_configuration_failed}
      {:error, _reason} = error -> error
    end
  end

  defp worker_env(workspace) do
    %{
      "WORKSPACE_WORKER_ENABLED" => "true",
      "WORKSPACE_BUNDLE_ID" => @bundle_digest,
      "WORKSPACE_ID" => workspace.id,
      "WORKSPACE_JOURNAL_PATH" => "/var/lib/hermitscale/control/journal.ndjson",
      "WORKSPACE_CONTROL_SOCKET" => "/run/hermitscale/worker.sock",
      "WORKSPACE_CONTROL_TOKEN_FILE" => "/var/lib/hermitscale/control/token",
      "WORKSPACE_CONTROL_DEADLINE" => "2099-01-01T00:00:00Z",
      "WORKSPACE_PROVIDER_ENV_FILE" => "/var/lib/hermitscale/control/provider-env.json",
      "WORKSPACE_LEASE_FILE" => "/var/lib/hermitscale/control/lease.json",
      "WORKSPACE_PROVIDER_SESSION_FILE" => "/var/lib/hermitscale/control/provider-session",
      "WORKSPACE_CWD" => "/workspace",
      "WORKSPACE_ACP_PATH" => "/opt/hermitscale/bin/codex-acp",
      "HOME" => "/home/hermitworker",
      "PATH" => "/.sprite/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    }
  end

  defp credential_value(nil), do: nil
  defp credential_value(%{value: value}) when is_binary(value), do: value

  defp valid_provider_env(env) when is_map(env) do
    allowed = ~w(PATH HOME OPENAI_BASE_URL OPENAI_API_KEY CODEX_HOME HERMITSCALE_MODEL)

    if Enum.all?(env, fn {key, value} -> key in allowed and is_binary(value) end) and
         Enum.all?(
           ~w(OPENAI_BASE_URL OPENAI_API_KEY HERMITSCALE_MODEL),
           &(is_binary(Map.get(env, &1)) and Map.get(env, &1) != "")
         ),
       do: :ok,
       else: {:error, :invalid_provider_environment}
  end

  defp valid_provider_env(_env), do: {:error, :invalid_provider_environment}
end
