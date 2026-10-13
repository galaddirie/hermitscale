defmodule Hermitscale.Workspaces.ConfinedVFSClient do
  @moduledoc false
  alias Hermitscale.Workspaces.SpriteSDK

  @script """
  import os, sys, base64, pwd
  coder = pwd.getpwnam('hermitcoder')
  op, path = sys.argv[1:3]
  parts = path.removeprefix('/workspace/').split('/')
  if not path.startswith('/workspace/') or any(p in ('', '.', '..') for p in parts): sys.exit(73)
  fd = os.open('/workspace', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
  try:
      for part in parts[:-1] if op != 'mkdir' else parts:
          if op in ('write', 'mkdir'):
              try: os.mkdir(part, 0o755, dir_fd=fd)
              except FileExistsError: pass
          nextfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
          if op in ('write','mkdir'): os.fchown(nextfd, coder.pw_uid, coder.pw_gid)
          os.close(fd); fd = nextfd
      if op == 'read':
          target = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
          import stat
          info = os.fstat(target)
          if not stat.S_ISREG(info.st_mode) or info.st_size > 1048576: sys.exit(74)
          with os.fdopen(target, 'rb') as f: data = f.read(1048577)
          if len(data) > 1048576: sys.exit(74)
          sys.stdout.write(base64.b64encode(data).decode())
      elif op == 'write':
          data = base64.b64decode(sys.stdin.buffer.read(1398105), validate=True)
          if len(data) > 1048576: sys.exit(74)
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

  def cmd(sprite, "base64", ["-w0", path], options), do: run(sprite, "read", path, options)
  def cmd(_sprite, "mkdir", ["-p", "--", "/workspace"], _options), do: {"", 0}
  def cmd(sprite, "mkdir", ["-p", "--", path], options), do: run(sprite, "mkdir", path, options)

  def cmd(sprite, "sh", ["-c", _script, "_", path], options),
    do: run(sprite, "write", path, options)

  defp run(sprite, operation, path, options) do
    stdin = options |> Keyword.get(:env, []) |> List.keyfind("JIDO_VFS_DATA", 0)

    transport =
      options |> Keyword.delete(:env) |> Keyword.merge(timeout: 15_000, output_limit: 1_400_000)

    transport =
      case stdin do
        {"JIDO_VFS_DATA", encoded} -> Keyword.put(transport, :stdin, encoded)
        nil -> transport
      end

    case SpriteSDK.capture(
           sprite,
           "sudo",
           ["-n", "python3", "-I", "-c", @script, operation, path],
           transport
         ) do
      {:ok, %{output: output, exit_code: code}} -> {output, code}
      {:error, reason} -> {Atom.to_string(reason), 75}
    end
  end
end
