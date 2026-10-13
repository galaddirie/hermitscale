import fcntl, json, os, pwd, subprocess, sys, tempfile
request = json.load(sys.stdin)
repository = request['repository'].removeprefix('github:')
url = 'https://github.com/' + repository + '.git'
branch = request['branch']
root = '/workspace'
launcher = '/opt/hermitscale/bin/sandbox-launch'

# Same-key retries may arrive together; serialize ordinary Git operations in one checkout.
lock = open('/var/lib/hermitscale/control/publication.lock','a')
fcntl.flock(lock,fcntl.LOCK_EX)

def git(args, env=None):
    process = subprocess.run([launcher, 'git', '-c', 'core.hooksPath=/dev/null'] + args,
        cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90)
    if process.returncode:
        raise RuntimeError('Git operation failed')
    return process.stdout.decode().strip()

git(['check-ref-format', '--branch', branch])
if git(['remote','get-url','origin']) != url:
    raise RuntimeError('Repository remote does not match the selected repository')
# Generated provider/control files never become part of ordinary commits.
git(['add','--all','--','.',':!.codex',':!.hermitscale'])
if git(['status','--porcelain','--untracked-files=no']):
    git(['commit','--no-verify','-m',request['message']])
commit = git(['rev-parse','HEAD'])
with tempfile.TemporaryDirectory(prefix='hermitscale-git-') as private:
    coder = pwd.getpwnam('hermitcoder')
    os.chown(private,coder.pw_uid,coder.pw_gid)
    helper = private+'/askpass'
    with open(helper,'w') as target:
        target.write('#!/usr/bin/python3 -I\nimport os,sys\nquestion=sys.argv[1]\nif "github.com/"+os.environ["HS_GIT_REPOSITORY"] not in question: sys.exit(1)\nprint("x-access-token" if "Username" in question else os.environ["HS_GIT_TOKEN"])\n')
    os.chown(helper,coder.pw_uid,coder.pw_gid); os.chmod(helper,0o700)
    env = dict(os.environ,GIT_ASKPASS=helper,GIT_TERMINAL_PROMPT='0',GIT_ALLOW_PROTOCOL='https',
        HS_GIT_TOKEN=request['credential'],HS_GIT_REPOSITORY=repository)
    args=['-c','credential.helper=','-c','credential.useHttpPath=true']
    ref='refs/heads/'+branch
    remote=git(args+['ls-remote',url,ref],env)
    if not remote or remote.split()[0] != commit:
        try: git(args+['push',url,commit+':'+ref],env)
        except RuntimeError: pass
    remote=git(args+['ls-remote',url,ref],env)
    if not remote or remote.split()[0] != commit:
        raise RuntimeError('Remote branch was not confirmed')
print(json.dumps({'repository':repository,'branch':branch,'commit_sha':commit}))
