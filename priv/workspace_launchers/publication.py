import json, os, sys, subprocess, re, hashlib, time, datetime, fcntl, signal, pwd, tempfile, stat, shutil
request=json.load(sys.stdin)
op=request['operation_id']
if not re.fullmatch('[A-Za-z0-9_-]{1,128}',op): sys.exit(80)
reconcile_only = request.get('reconcile_only') is True
deadline = datetime.datetime.fromisoformat(request['deadline'].replace('Z','+00:00')).timestamp()
deadline = time.time()+60 if reconcile_only else deadline
if deadline<=time.time(): sys.exit(88)
control='/var/lib/hermitscale/control'
os.makedirs(control+'/groups',mode=0o700,exist_ok=True)
lease=request['lease_id']
if not re.fullmatch('[A-Za-z0-9_-]{1,128}',lease): sys.exit(80)
# A detached effect stays visible to lease termination even if exec loses its response.
child=os.fork()
if child:
    while True:
        finished,status=os.waitpid(child,os.WNOHANG)
        if finished: sys.exit(os.waitstatus_to_exitcode(status))
        if time.time()>=deadline:
            try: os.killpg(child,signal.SIGKILL)
            except ProcessLookupError: pass
            os.waitpid(child,0); sys.exit(88)
        time.sleep(0.05)
os.setsid()
worker=pwd.getpwnam('hermitworker')
group_path=control+'/groups/'+lease+'.json'
group_lock=open(group_path+'.lock','a'); fcntl.flock(group_lock,fcntl.LOCK_EX)
groups=json.load(open(group_path)) if os.path.exists(group_path) else []
if os.getpgrp() not in groups: groups.append(os.getpgrp())
with open(group_path+'.tmp','w') as f: json.dump(groups,f); f.flush(); os.fsync(f.fileno())
os.chown(group_path+'.tmp',worker.pw_uid,worker.pw_gid); os.chmod(group_path+'.tmp',0o600)
os.replace(group_path+'.tmp',group_path); group_lock.close()
signal.signal(signal.SIGALRM,lambda _signal,_frame: os.killpg(os.getpgrp(),signal.SIGKILL))
signal.setitimer(signal.ITIMER_REAL,max(deadline-time.time(),0.001))
# Serialize retries around both the durable commit marker and the remote push.
lock=open(control+'/publication.lock','a')
while True:
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB); break
    except BlockingIOError:
        if time.time()>=deadline: sys.exit(88)
        time.sleep(0.05)
root='/workspace'
def git(args, env=None, raw=False, cwd=None, data=None):
    p=subprocess.run(['/opt/hermitscale/bin/sandbox-launch','git','-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-c','core.filemode=true','-c','commit.gpgsign=false','-c','credential.helper=']+args,cwd=cwd or root,env=env,input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=max(min(90,deadline-time.time()),0.001))
    if p.returncode: raise RuntimeError('git operation failed')
    output=p.stdout.decode()
    return output if raw else output.strip()
repo=request['repository']
if not re.fullmatch(r'github:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo): sys.exit(80)
branch=request['branch']
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9/_-]{0,199}',branch) or '..' in branch or branch.endswith('/'): sys.exit(80)
url='https://github.com/'+repo.removeprefix('github:')+'.git'
helper='/tmp/hermitscale-publish-'+op
with open(helper,'w') as f: f.write('#!/bin/sh\ncase "$1" in *Username*) echo x-access-token;; *) printf %s "$HS_GIT_TOKEN";; esac\n')
import pwd
coder=pwd.getpwnam('hermitcoder')
os.chown(helper,coder.pw_uid,coder.pw_gid); os.chmod(helper,0o700)
env=dict(os.environ,GIT_TERMINAL_PROMPT='0',GIT_ASKPASS=helper,HS_GIT_TOKEN=request['credential'])
marker='/var/lib/hermitscale/control/publications/'+op+'.json'
store=tempfile.mkdtemp(prefix='hermitscale-git-'+op+'-')
os.chown(store,coder.pw_uid,coder.pw_gid)
def isolated(args, env=None, data=None):
    return git(['--git-dir='+store]+args,env=env,cwd=store,data=data)
isolated(['init','--bare'])
def object_directory(path):
    if path==root+'/.git/objects':
        root_fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try: git_fd=os.open('.git',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=root_fd)
        finally: os.close(root_fd)
        try: return os.open('objects',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=git_fd)
        finally: os.close(git_fd)
    return os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
def copy_objects(source,target):
    total=0
    directory=object_directory(source)
    target_directory=object_directory(target)
    try:
        for name in os.listdir(directory):
            if not (re.fullmatch('[a-f0-9]{2}',name) or name=='pack'): continue
            sub=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=directory)
            try:
                try: os.mkdir(name,0o755,dir_fd=target_directory)
                except FileExistsError: pass
                destination=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=target_directory)
                os.fchown(destination,coder.pw_uid,coder.pw_gid)
                for filename in os.listdir(sub):
                    if not (re.fullmatch('[a-f0-9]{38,62}',filename) or re.fullmatch('pack-[a-f0-9]{40,64}\\.(pack|idx|rev|bitmap)',filename)): continue
                    source_file=os.open(filename,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=sub)
                    metadata=os.fstat(source_file)
                    if not stat.S_ISREG(metadata.st_mode): raise ValueError('invalid object file')
                    total+=metadata.st_size
                    if total>268435456: raise ValueError('repository objects exceed bounded profile')
                    try: destination_file=os.open(filename,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644,dir_fd=destination)
                    except FileExistsError:
                        if not stat.S_ISREG(os.stat(filename,dir_fd=destination,follow_symlinks=False).st_mode): raise ValueError('invalid destination object')
                        os.close(source_file); continue
                    with os.fdopen(source_file,'rb') as source_stream, os.fdopen(destination_file,'wb') as target_stream:
                        shutil.copyfileobj(source_stream,target_stream,1048576); os.fchown(target_stream.fileno(),coder.pw_uid,coder.pw_gid)
            finally:
                os.close(sub)
                if 'destination' in locals(): os.close(destination); del destination
    finally: os.close(directory); os.close(target_directory)
# Import objects as inert bounded files. No workspace config, alternates,
# hooks, remote helper, or local upload-pack executes with a credential.
copy_objects('/workspace/.git/objects',store+'/objects')
def publish():
    identity={key:request[key] for key in ('repository','base_sha','branch','manifest','message','operation_id','candidate_digest')}
    digest=hashlib.sha256(json.dumps(identity,sort_keys=True).encode()).hexdigest()
    if os.path.isfile(marker):
        journal=json.load(open(marker))
        if journal['digest']!=digest: sys.exit(81)
        commit=journal['commit']
    else:
        if isolated(['ls-remote',url,'refs/heads/'+branch],env): sys.exit(83)
        if reconcile_only: sys.exit(84)
        if git(['rev-parse','HEAD'])!=request['base_sha']: sys.exit(82)
        empty_attributes=git(['hash-object','-w','-t','tree','--stdin'],data=b'')
        diff=git(['--attr-source='+empty_attributes,'diff','--no-ext-diff','--no-textconv','--binary',request['base_sha'],'--'],raw=True)
        files=[]
        for path in git(['ls-files','--others','--exclude-standard','-z'],raw=True).split('\0'):
            if not path or path.startswith(('.env','.codex','.hermitscale')): continue
            full=os.path.realpath(os.path.join(root,path))
            if not full.startswith(root+'/') or not os.path.isfile(full): continue
            if os.path.getsize(full)>1048576: continue
            with open(full,'rb') as f: content=f.read(1048577)
            if len(content)>1048576: continue
            files.append({'path':path,'digest':hashlib.sha256(content).hexdigest()})
        candidate={'base_sha':request['base_sha'],'diff':diff,'files':sorted(files,key=lambda f:f['path'])}
        candidate_digest=hashlib.sha256(json.dumps(candidate,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        if candidate_digest!=request['candidate_digest']: sys.exit(86)
        allowed=git(['--attr-source='+empty_attributes,'diff','--no-ext-diff','--no-textconv','--name-only','-z',request['base_sha'],'--'],raw=True).rstrip('\0').split('\0')+[f['path'] for f in files]
        manifest=request['manifest']
        if any(p not in allowed for p in manifest): sys.exit(87)
        if not manifest or any(not isinstance(p,str) or p.startswith(('/','-')) or '..' in p.split('/') for p in manifest): sys.exit(80)
        isolated(['read-tree',request['base_sha']])
        for path in manifest:
            full=os.path.join(root,path)
            if not os.path.lexists(full):
                isolated(['update-index','--force-remove','--',path]); continue
            parent=os.path.realpath(os.path.dirname(full))
            if not parent.startswith(root+'/') and parent!=root: sys.exit(80)
            if os.path.islink(full):
                content=os.readlink(full).encode(); mode='120000'
            else:
                fd=os.open(full,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
                metadata=os.fstat(fd)
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_size>8388608: sys.exit(80)
                with os.fdopen(fd,'rb') as source: content=source.read(8388609)
                mode='100755' if metadata.st_mode&0o111 and path not in [f['path'] for f in files] else '100644'
            blob=isolated(['hash-object','-w','--no-filters','--stdin'],data=content)
            isolated(['update-index','--add','--cacheinfo',mode+','+blob+','+path])
        tree=isolated(['write-tree'])
        author=dict(os.environ,GIT_AUTHOR_NAME='Hermitscale',GIT_AUTHOR_EMAIL='agents@hermitscale.local',GIT_COMMITTER_NAME='Hermitscale',GIT_COMMITTER_EMAIL='agents@hermitscale.local')
        commit=isolated(['-c','commit.gpgsign=false','commit-tree',tree,'-p',request['base_sha'],'-m',request['message']],env=author)
        copy_objects(store+'/objects','/workspace/.git/objects')
        os.makedirs(os.path.dirname(marker),exist_ok=True)
        with open(marker+'.tmp','w') as f: json.dump({'digest':digest,'commit':commit},f); f.flush(); os.fsync(f.fileno())
        os.replace(marker+'.tmp',marker)
    head=git(['rev-parse','HEAD'])
    if head==request['base_sha']: git(['update-ref','HEAD',commit,request['base_sha']])
    elif head!=commit: sys.exit(82)
    remote=isolated(['ls-remote',url,'refs/heads/'+branch],env)
    if remote and remote.split()[0]!=commit: sys.exit(83)
    if not remote and not reconcile_only:
        try: isolated(['push',url,commit+':refs/heads/'+branch],env)
        except RuntimeError: pass
    remote=isolated(['ls-remote',url,'refs/heads/'+branch],env)
    if not remote or remote.split()[0]!=commit:
        print(json.dumps({'local_commit':commit,'base_sha':request['base_sha'],'verified':False})); sys.exit(84)
    print(json.dumps({'repository':repo,'branch':branch,'commit_sha':commit,'base_sha':request['base_sha'],'manifest':request['manifest'],'verified':True}))
try:
    publish()
except (RuntimeError,subprocess.TimeoutExpired):
    if os.path.isfile(marker):
        journal=json.load(open(marker)); print(json.dumps({'local_commit':journal['commit'],'base_sha':request['base_sha'],'verified':False}))
    sys.exit(84)
finally:
    if os.path.exists(helper): os.unlink(helper)
    shutil.rmtree(store)
