#!/usr/bin/python3 -I
"""Root-owned fixed entry point; remote code begins only after isolation and UID drop.

The host calls coder/app. The unprivileged worker may call provider/signal via
one exact sudoers entry. This file must be root-owned and never writable by an
execution user. It never executes a supplied command while privileged.
"""
import ctypes
import errno
import json
import os
import pwd
import re
import signal
import sys

CONTROL = '/var/lib/hermitscale/control'
WORKSPACE = '/workspace'
PROVIDER = '/opt/hermitscale/provider/node_modules/.bin/codex-acp'
API_SOCKET = '/.sprite/api.sock'
API_MASK = '/opt/hermitscale/blocked-api'
PROVIDER_ENV = frozenset(('PATH', 'HOME', 'CODEX_HOME', 'OPENAI_API_KEY'))
BASE_ENV = {'SHELL': '/bin/bash', 'PATH': '/opt/hermitscale/bin:/opt/hermitscale/provider/node_modules/.bin:/usr/local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8'}
CLONE_NEWNS = 0x00020000
MS_BIND = 4096
MS_REC = 16384
MS_PRIVATE = 1 << 18
MS_REMOUNT = 32
MS_RDONLY = 1
PR_SET_DUMPABLE = 4
PR_SET_NO_NEW_PRIVS = 38
PR_CAPBSET_DROP = 24


def bounded_arguments(arguments):
    if not arguments or len(arguments) > 128 or any('\x00' in value or len(value.encode()) > 8192 for value in arguments):
        raise ValueError('invalid arguments')
    return arguments


def signal_request(arguments):
    if len(arguments) != 2 or arguments[0] not in ('CHECK', 'KILL') or not re.fullmatch(r'[1-9][0-9]{0,9}', arguments[1]):
        raise ValueError('invalid signal request')
    group = int(arguments[1])
    if group <= 1:
        raise ValueError('invalid process group')
    lease = json.load(open(CONTROL + '/lease.json'))['lease_id']
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', lease):
        raise ValueError('invalid lease identity')
    admitted = json.load(open(CONTROL + '/groups/' + lease + '.json'))
    if group not in admitted:
        raise PermissionError('unrecorded process group')
    execution_users = {pwd.getpwnam(name).pw_uid for name in ('hermitcoder', 'hermitworker')}
    found = False
    for entry in os.scandir('/proc'):
        if not entry.name.isdecimal():
            continue
        try:
            pid = int(entry.name)
            if os.getpgid(pid) == group:
                if os.stat(entry.path).st_uid not in execution_users:
                    raise PermissionError('process group ownership mismatch')
                found = True
        except ProcessLookupError:
            pass
    if not found:
        return 0
    if arguments[0] == 'CHECK':
        return 1
    os.killpg(group, signal.SIGKILL)
    return 0


def checked(libc, name, *arguments):
    if getattr(libc, name)(*arguments) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), name)


def isolate(libc):
    # The provider cannot use the root Sprite API through the world-readable
    # virtual socket. This mount exists only in its descendants' namespace.
    checked(libc, 'unshare', CLONE_NEWNS)
    checked(libc, 'mount', None, b'/', None, MS_REC | MS_PRIVATE, None)
    checked(libc, 'mount', API_MASK.encode(), API_SOCKET.encode(), None, MS_BIND, None)
    checked(libc, 'mount', None, API_SOCKET.encode(), None, MS_BIND | MS_REMOUNT | MS_RDONLY, None)


def execution_environment(profile, user):
    result = dict(BASE_ENV, HOME=user.pw_dir, USER=user.pw_name, LOGNAME=user.pw_name)
    if profile == 'provider':
        fd = os.open(CONTROL + '/provider-env.json', os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as source:
            data = source.read(65537)
        if len(data.encode()) > 65536:
            raise ValueError('provider environment exceeds bound')
        provider = json.loads(data)
        if not isinstance(provider, dict) or any(key not in PROVIDER_ENV or not isinstance(value, str) for key, value in provider.items()):
            raise ValueError('invalid provider environment')
        result.update(provider)
        result.update(NO_BROWSER='1', DEFAULT_AUTH_REQUEST=json.dumps({'methodId':'api-key'}),
            CODEX_PATH='/opt/hermitscale/provider/node_modules/.bin/codex')
    if profile == 'git':
        result.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
        for key in ('GIT_TERMINAL_PROMPT', 'GIT_ASKPASS', 'HS_GIT_TOKEN', 'HS_GIT_REPOSITORY', 'GIT_ALLOW_PROTOCOL', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'):
            if key in os.environ:
                result[key] = os.environ[key]
    return result


def clear_previous_result():
    # Provider startup occurs once per newly journaled operation. Reconnection
    # only inspects that operation and never invokes this launcher again.
    root = os.open(WORKSPACE, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            directory = os.open('.hermitscale', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root)
        except FileNotFoundError:
            return
        try:
            try:
                os.unlink('result.json', dir_fd=directory)
            except FileNotFoundError:
                pass
        finally:
            os.close(directory)
    finally:
        os.close(root)


def launch(profile, arguments):
    user = pwd.getpwnam('hermitapp' if profile == 'app' else 'hermitcoder')
    if profile == 'provider':
        arguments = [PROVIDER] + arguments
    elif profile == 'git':
        arguments = ['/usr/bin/git'] + arguments
    arguments = bounded_arguments(arguments)
    environment = execution_environment(profile, user)
    libc = ctypes.CDLL(None, use_errno=True)
    isolate(libc)
    if profile == 'provider':
        clear_previous_result()
    # The process has no capability or setuid route back to the management user.
    for capability in range(41):
        if libc.prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) != 0 and ctypes.get_errno() != errno.EINVAL:
            raise OSError(ctypes.get_errno(), 'cannot drop capability')
    os.initgroups(user.pw_name, user.pw_gid)
    os.setresgid(user.pw_gid, user.pw_gid, user.pw_gid)
    os.setresuid(user.pw_uid, user.pw_uid, user.pw_uid)
    checked(libc, 'prctl', PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
    checked(libc, 'prctl', PR_SET_DUMPABLE, 0, 0, 0, 0)
    os.umask(0o007 if profile == 'app' else 0o022)
    os.execvpe(arguments[0], arguments, environment)


def main(arguments):
    if os.geteuid() != 0 or not sys.platform.startswith('linux'):
        raise PermissionError('root Linux initialization required')
    if not arguments or arguments[0] not in ('coder', 'app', 'provider', 'git', 'signal'):
        raise ValueError('invalid execution profile')
    profile, arguments = arguments[0], arguments[1:]
    if profile == 'signal':
        return signal_request(arguments)
    launch(profile, arguments)


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as failure:
        # Keep provider credentials and command bodies out of diagnostics.
        print('sandbox initialization rejected: ' + type(failure).__name__, file=sys.stderr)
        sys.exit(77)
