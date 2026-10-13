defmodule Hermitscale.Workspaces.Files do
  @moduledoc false
  alias Hermitscale.Workspaces.SpriteSDK

  @script """
  import os, sys, base64, pwd
  coder = pwd.getpwnam('hermitcoder')
  op, path, maximum = sys.argv[1:4]
  maximum = int(maximum)
  parts = path.removeprefix('/workspace/').split('/')
  if not path.startswith('/workspace/') or any(p in ('', '.', '..') for p in parts): sys.exit(73)
  fd = os.open('/workspace', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
  try:
      for part in parts[:-1]:
          if op == 'write':
              try: os.mkdir(part, 0o755, dir_fd=fd)
              except FileExistsError: pass
          nextfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
          if op == 'write': os.fchown(nextfd, coder.pw_uid, coder.pw_gid)
          os.close(fd); fd = nextfd
      if op == 'read':
          target = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
          import stat
          info = os.fstat(target)
          if not stat.S_ISREG(info.st_mode) or info.st_size > maximum: sys.exit(74)
          with os.fdopen(target, 'rb') as f: data = f.read(maximum+1)
          if len(data) > maximum: sys.exit(74)
          sys.stdout.write(base64.b64encode(data).decode())
      elif op == 'write':
          data = base64.b64decode(sys.stdin.buffer.read(1398105), validate=True)
          if len(data) > maximum: sys.exit(74)
          target = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644, dir_fd=fd)
          os.fchown(target, coder.pw_uid, coder.pw_gid)
          with os.fdopen(target, 'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
  except FileNotFoundError:
      sys.stderr.write('not found'); sys.exit(72)
  except OSError:
      sys.stderr.write('permission denied'); sys.exit(73)
  finally:
      os.close(fd)
  """

  def read(workspace, path, maximum \\ 1_048_576) do
    with {:ok, output} <- run(workspace, "read", path, maximum, nil),
         {:ok, content} <- Base.decode64(output),
         do: {:ok, content}
  end

  def write(workspace, path, content) do
    with {:ok, _output} <- run(workspace, "write", path, 1_048_576, Base.encode64(content)),
         do: :ok
  end

  defp run(workspace, operation, path, maximum, stdin) do
    with {:ok, sprite} <- Hermitscale.Workspaces.SpriteAccess.sprite(workspace),
         {:ok, result} <-
           SpriteSDK.capture(
             sprite,
             "sudo",
             [
               "-n",
               "python3",
               "-I",
               "-c",
               @script,
               operation,
               "/workspace/" <> path,
               to_string(maximum)
             ],
             stdin: stdin,
             timeout: 15_000,
             output_limit: 1_400_000
           ) do
      case result do
        %{exit_code: 0, output: output} -> {:ok, output}
        %{exit_code: 72} -> {:error, :file_not_found}
        %{exit_code: 74} -> {:error, :file_too_large}
        %{exit_code: _code} -> {:error, :file_access_rejected}
      end
    end
  end
end
