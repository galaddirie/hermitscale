defmodule Hermitscale.Workspaces.Evidence do
  @moduledoc "Collects actual retained Git changes, command receipts, artifacts and structured results."
  alias Hermitscale.Workspaces.{SpriteAccess, SpriteSDK}

  @script """
  import os, json, sys, subprocess, hashlib, base64, stat, time, datetime
  base = sys.argv[1]
  verification_commands = json.loads(sys.argv[2])
  root = '/workspace'
  def run(args, timeout=90, limit=65536):
      p = subprocess.run(args, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, input=b'')
      if limit > 65536 and len(p.stdout)>limit: sys.exit(85)
      return {'name':' '.join(args),'command': args, 'exit_code': p.returncode, 'output': p.stdout[:limit].decode(errors='replace')}
  head = run(['git','rev-parse','HEAD'])
  if head['exit_code'] != 0: sys.exit(78)
  actual_base = base or head['output'].strip()
  empty_attributes=run(['git','hash-object','-w','-t','tree','--stdin'])['output'].strip()
  diff = run(['git','-c','core.fsmonitor=false','-c','core.filemode=true','--attr-source='+empty_attributes,'diff','--no-ext-diff','--no-textconv','--binary',actual_base,'--'], limit=8000000)
  status = run(['git','status','--porcelain'])
  untracked = run(['git','ls-files','--others','--exclude-standard','-z'],limit=256000)
  checks = []
  check_deadline = time.monotonic() + 90
  for command in verification_commands:
      remaining = max(0, check_deadline - time.monotonic())
      try:
          receipt = run(['bash','-lc',command], timeout=remaining) if remaining else {'command': ['bash','-lc',command], 'exit_code':124, 'output':'Verification deadline exceeded'}
      except subprocess.TimeoutExpired:
          receipt = {'command': ['bash','-lc',command], 'exit_code':124, 'output':'Verification deadline exceeded'}
      receipt['name'] = command
      checks.append(receipt)
  result = None
  result_present = False
  result_valid = False
  result_diagnostic = {'reason':'missing'}
  try:
      directory=os.open(root+'/.hermitscale',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
      try:
          fd=os.open('result.json',os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory)
      finally: os.close(directory)
      result_present=True
      metadata=os.fstat(fd)
      if not stat.S_ISREG(metadata.st_mode):
          os.close(fd); result_diagnostic={'reason':'not_regular'}
      else:
          with os.fdopen(fd,'rb') as f: content=f.read(65537)
          captured=content[:65536]
          result_diagnostic={'reason':'invalid_json','content':base64.b64encode(captured).decode(),'digest':hashlib.sha256(captured).hexdigest(),'captured_bytes':len(captured),'truncated':metadata.st_size>65536 or len(content)>65536}
          if result_diagnostic['truncated']: result_diagnostic['reason']='too_large'
          else:
              try:
                  result=json.loads(content); result_valid=True; result_diagnostic=None
              except (ValueError,UnicodeDecodeError): pass
  except FileNotFoundError: pass
  except OSError:
      result_present=True; result_diagnostic={'reason':'unsafe_path'}
  artifacts = []
  files = []
  exported_bytes = 0
  for path in untracked['output'].split('\\0'):
      if not path or path.startswith(('.env','.codex','.hermitscale')): continue
      if len(files) >= 100: sys.exit(85)
      full = os.path.realpath(os.path.join(root,path))
      if not full.startswith(root + '/') or not os.path.isfile(full): continue
      size = os.path.getsize(full)
      if size > 1048576: continue
      with open(full,'rb') as f: content=f.read(1048577)
      if len(content)>1048576: continue
      exported_bytes += len(content)
      if exported_bytes>4194304: sys.exit(85)
      digest = hashlib.sha256(content).hexdigest()
      files.append({'path':path,'digest':digest,'content':base64.b64encode(content).decode()})
      artifacts.append({'path':path,'digest':digest,'size':len(content)})
  changed = run(['git','-c','core.fsmonitor=false','-c','core.filemode=true','--attr-source='+empty_attributes,'diff','--no-ext-diff','--no-textconv','--name-only','-z',actual_base,'--'])['output'].rstrip('\\0').split('\\0')
  changed = [p for p in changed if p]
  manifest = changed + [f['path'] for f in files]
  candidate = {'base_sha':actual_base,'diff':diff['output'],'files':sorted([{'path':f['path'],'digest':f['digest']} for f in files],key=lambda f:f['path'])}
  storage_bytes=0; storage_entries=0; storage_deadline=time.monotonic()+5
  for directory,dirs,names in os.walk(root,followlinks=False):
      dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(directory,name))]
      for name in names:
          storage_entries+=1
          if storage_entries>100000 or time.monotonic()>storage_deadline: sys.exit(85)
          metadata=os.stat(os.path.join(directory,name),follow_symlinks=False)
          if stat.S_ISREG(metadata.st_mode): storage_bytes+=metadata.st_size
  candidate_digest = hashlib.sha256(json.dumps(candidate,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
  print(json.dumps({'storage_bytes':storage_bytes,'storage_measurement':{'path':root,'bytes_kind':'logical_regular_files','measured_at':datetime.datetime.now(datetime.timezone.utc).isoformat()},'candidate_digest':candidate_digest,'base_sha':actual_base, 'head_sha':head['output'].strip(), 'diff':diff['output'],
    'status':status['output'], 'checks':checks, 'artifacts':artifacts, 'files':files, 'manifest':manifest,
    'result':result, 'result_evidence_present':result_present, 'result_valid_json':result_valid, 'result_diagnostic':result_diagnostic, 'checks_passed':len(checks)>0 and all(c['exit_code']==0 for c in checks)}))
  """

  @wrapper """
  import os,json,sys,subprocess,stat,re
  request=json.load(sys.stdin)
  base=request['base_sha']
  if base:
      if not re.fullmatch('[a-f0-9]{40,64}',base): sys.exit(78)
      exists=subprocess.run(['/opt/hermitscale/bin/sandbox-launch','git','cat-file','-e',base+'^{commit}'],cwd='/workspace',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
      if not exists: sys.exit(78)
  result=subprocess.run(['/opt/hermitscale/bin/sandbox-launch','coder','python3','-I','-c',request['script'],base,json.dumps(request['verification_commands'])])
  sys.exit(result.returncode)
  """

  def collect(workspace, _lease, base_sha, options \\ []) do
    commands = Keyword.get(options, :verification_commands, [])

    with {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0, output: output}} <-
           SpriteSDK.capture(
             sprite,
             "sudo",
             ["-n", "python3", "-I", "-c", @wrapper],
             stdin:
               Jason.encode!(%{
                 script: @script,
                 base_sha: base_sha || "",
                 verification_commands: commands
               }),
             timeout: 180_000,
             output_limit: 16_000_000
           ),
         {:ok, evidence} <- Jason.decode(output) do
      {:ok, evidence}
    else
      {:ok, %{exit_code: _status}} -> {:error, :evidence_collection_failed}
      {:error, _reason} = error -> error
    end
  end

  def digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
