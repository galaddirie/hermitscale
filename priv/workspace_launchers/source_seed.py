import os, json, sys, subprocess
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
if os.path.isdir('/workspace/.git'): sys.exit(0)
def git(args, env=None): subprocess.run(['/opt/hermitscale/bin/sandbox-launch','git'] + args, cwd='/workspace', env=env, check=True)
git(['init']); git(['config','user.name','Hermitscale']); git(['config','user.email','agents@hermitscale.local'])
repo = config.get('repository')
if repo:
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
        if config.get('base_sha'):
            git(['fetch','--depth=1','origin',config['base_sha']], env)
            git(['checkout','--detach',config['base_sha']], env)
        else:
            git(['fetch','--depth=1','origin','HEAD'], env)
            git(['checkout','-B','main','FETCH_HEAD'], env)
    finally:
        if os.path.exists(helper): os.unlink(helper)
else:
    git(['commit','--allow-empty','-m','Initialize workspace'])
