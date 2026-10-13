import os, json, sys, subprocess, hashlib, base64, tarfile, io, re
config = json.load(sys.stdin)
os.makedirs('/workspace', exist_ok=True)
import pwd
coder=pwd.getpwnam('hermitcoder')
workspace=os.open('/workspace',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
    try: os.mkdir('.hermitscale',0o700,dir_fd=workspace)
    except FileExistsError: pass
    private=os.open('.hermitscale',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=workspace)
    os.fchown(private,coder.pw_uid,coder.pw_gid); os.fchmod(private,0o700); os.close(private)
finally: os.close(workspace)
source=config.get('source_bundle')
control='/var/lib/hermitscale/control'
marker=control+'/source-baseline.json'
pending=control+'/source-pending.json'
source_identity={k:source[k] for k in ('artifact_id','app_id','artifact_digest','deployed_revision')} if source else None
if os.path.isdir('/workspace/.git'):
    if not source: sys.exit(0)
    if os.path.isfile(marker):
        existing=json.load(open(marker))
        if any(existing.get(k)!=v for k,v in source_identity.items()): sys.exit(80)
        sys.exit(0)
    if not os.path.isfile(pending) or json.load(open(pending))!=source_identity: sys.exit(80)
def git(args, env=None): subprocess.run(['/opt/hermitscale/bin/sandbox-launch','git'] + args, cwd='/workspace', env=env, check=True)
git(['init']); git(['config','user.name','Hermitscale']); git(['config','user.email','agents@hermitscale.local'])
repo = config.get('repository')
if source:
    if source['deployed_revision']!=config['base_sha']: sys.exit(80)
    archive=base64.b64decode(source['content'],validate=True)
    if len(archive)>8388608 or hashlib.sha256(archive).hexdigest()!=source['artifact_digest']: sys.exit(80)
    with tarfile.open(fileobj=io.BytesIO(archive),mode='r:') as tar:
        members=tar.getmembers()
        if len(members)>200 or sum(m.size for m in members)>8388608: sys.exit(80)
        if not any(m.name=='app.py' and m.isfile() for m in members): sys.exit(80)
        proofs=[m for m in members if m.name=='_hermitscale_source.json']
        if len(proofs)!=1 or not proofs[0].isfile() or proofs[0].size>4096: sys.exit(80)
        proof=json.load(tar.extractfile(proofs[0]))
        if proof.get('source_commit')!=source['deployed_revision'] or proof.get('recipe')!='python-sqlite-v1': sys.exit(80)
        for member in members:
            parts=member.name.rstrip('/').split('/')
            forbidden=('.git','.codex','.hermitscale','data','preview-data','releases','incoming','backups','app-tools','recovery','builds')
            if not (member.isfile() or member.isdir()) or len(member.name)>1024 or any(p in ('','..','.') or p in forbidden or p.startswith('.env') for p in parts) or member.size>1048576: sys.exit(80)
        os.makedirs(control,mode=0o700,exist_ok=True)
        with open(pending,'w') as f: json.dump(source_identity,f); f.flush(); os.fsync(f.fileno())
        os.chown(pending,0,0); os.chmod(pending,0o600)
        import pwd
        coder=pwd.getpwnam('hermitcoder')
        for member in members:
            if member.isdir() or member.name=='_hermitscale_source.json': continue
            parts=member.name.split('/')
            directory=os.open('/workspace',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:
                for part in parts[:-1]:
                    try: os.mkdir(part,0o755,dir_fd=directory)
                    except FileExistsError: pass
                    next_directory=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=directory)
                    os.fchown(next_directory,coder.pw_uid,coder.pw_gid); os.close(directory); directory=next_directory
                target=os.open(parts[-1],os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o644,dir_fd=directory)
                with os.fdopen(target,'wb') as f:
                    content=tar.extractfile(member).read(1048577)
                    if len(content)!=member.size: sys.exit(80)
                    f.write(content); f.flush(); os.fsync(f.fileno()); os.fchown(f.fileno(),coder.pw_uid,coder.pw_gid)
            finally: os.close(directory)
    git(['add','-A']); git(['-c','core.hooksPath=/dev/null','commit','--allow-empty','-m','Import verified serving app source'])
    local_base=subprocess.run(['/opt/hermitscale/bin/sandbox-launch','git','rev-parse','HEAD'],cwd='/workspace',stdout=subprocess.PIPE,check=True).stdout.decode().strip()
    with open(marker+'.tmp','w') as f: json.dump(dict(source_identity,local_base_sha=local_base),f); f.flush(); os.fsync(f.fileno())
    os.chown(marker+'.tmp',0,0); os.chmod(marker+'.tmp',0o600); os.replace(marker+'.tmp',marker); os.unlink(pending)
elif repo:
    import re
    if not re.fullmatch(r'github:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo): sys.exit(77)
    url = 'https://github.com/' + repo.removeprefix('github:') + '.git'
    git(['remote','add','origin',url])
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    token = config.get('source_credential')
    helper = '/tmp/hermitscale-askpass-' + str(os.getpid())
    if token:
        with open(helper, 'w') as f: f.write('#!/bin/sh\ncase "$1" in *Username*) echo x-access-token;; *) printf %s "$HS_GIT_TOKEN";; esac\n')
        import pwd
        coder=pwd.getpwnam('hermitcoder'); os.chown(helper,coder.pw_uid,coder.pw_gid)
        os.chmod(helper, 0o700); env.update(GIT_ASKPASS=helper, HS_GIT_TOKEN=token)
    try:
        git(['fetch','--depth=1','origin',config['base_sha']], env)
        git(['checkout','--detach',config['base_sha']], env)
    finally:
        if os.path.exists(helper): os.unlink(helper)
else:
    if config['recipe'] == 'python-sqlite-v1':
        with open('/workspace/app.py','w') as f: f.write(config['scaffold'])
        with open('/workspace/test_app.py','w') as f: f.write(config['scaffold_test'])
        with open('/workspace/.gitignore','w') as f: f.write('.codex/\n.hermitscale/\ndata/\npreview-data/\npreview-releases/\nreleases/\nincoming/\nbackups/\napp-tools/\nbuilds/\nrecovery/\n__pycache__/\n')
        subprocess.run(['chown','hermitcoder:hermitcoder','/workspace/app.py','/workspace/test_app.py','/workspace/.gitignore'], check=True)
    git(['add','-A']); git(['commit','--allow-empty','-m','Initialize app workspace'])
