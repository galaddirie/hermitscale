defmodule Hermitscale.Workspaces.Foundation do
  @moduledoc false
  alias Hermitscale.Workspaces.SpriteSDK

  @launcher_path Path.expand("../../../priv/workspace_launchers/sandbox-launch.py", __DIR__)
  @external_resource @launcher_path
  @launcher File.read!(@launcher_path)

  @script """
  import os, subprocess, json, sys
  launcher = json.load(sys.stdin)["launcher"]
  if subprocess.run(['id','-u','hermitcoder'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
      subprocess.run(['useradd','--create-home','--shell','/bin/bash','hermitcoder'], check=True)
  if subprocess.run(['id','-u','hermitapp'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
      subprocess.run(['useradd','--create-home','--shell','/bin/bash','hermitapp'], check=True)
  if subprocess.run(['id','-u','hermitworker'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
      subprocess.run(['useradd','--create-home','--shell','/bin/bash','hermitworker'], check=True)
  subprocess.run(['usermod','-a','-G','hermitapp','hermitcoder'], check=True)
  os.makedirs('/workspace', exist_ok=True)
  subprocess.run(['chown','hermitcoder:hermitcoder','/workspace'], check=True)
  import pwd
  workspace=os.open('/workspace',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
  try:
      for name,user,mode in [('.codex','hermitcoder',0o700),('data','hermitapp',0o2770),('preview-data','hermitapp',0o2770)]:
          try: os.mkdir(name,mode,dir_fd=workspace)
          except FileExistsError: pass
          directory=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=workspace)
          owner=pwd.getpwnam(user)
          os.fchown(directory,owner.pw_uid,owner.pw_gid); os.fchmod(directory,mode); os.close(directory)
  finally: os.close(workspace)
  os.makedirs('/opt/hermitscale/bin',mode=0o755,exist_ok=True)
  for path in ['/opt/hermitscale','/opt/hermitscale/bin']:
      os.chown(path,0,0); os.chmod(path,0o755)
  target='/opt/hermitscale/bin/sandbox-launch'
  with open(target+'.tmp','w') as f: f.write(launcher); f.flush(); os.fsync(f.fileno())
  os.chown(target+'.tmp',0,0); os.chmod(target+'.tmp',0o755); os.replace(target+'.tmp',target)
  with open('/opt/hermitscale/blocked-api','w') as f: f.write('Private management API is unavailable to this execution identity.\\n')
  os.chown('/opt/hermitscale/blocked-api',0,0); os.chmod('/opt/hermitscale/blocked-api',0o444)
  policy='/etc/sudoers.d/hermitscale-coder'
  with open(policy+'.tmp','w') as f:
      f.write('hermitworker ALL=(root) NOPASSWD: NOSETENV: /opt/hermitscale/bin/sandbox-launch provider, /opt/hermitscale/bin/sandbox-launch provider *, /opt/hermitscale/bin/sandbox-launch signal *\\n')
  os.chown(policy+'.tmp',0,0); os.chmod(policy+'.tmp',0o440)
  subprocess.run(['visudo','-cf',policy+'.tmp'],check=True,stdout=subprocess.DEVNULL)
  os.replace(policy+'.tmp',policy)
  """
  def prepare(sprite) do
    case SpriteSDK.capture(sprite, "sudo", ["-n", "python3", "-I", "-c", @script],
           stdin: Jason.encode!(%{launcher: @launcher}),
           timeout: 10_000,
           output_limit: 4096
         ) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: _code}} -> {:error, :workspace_setup_failed}
      {:error, _reason} = error -> error
    end
  end
end
