#!/usr/bin/python3 -I
"""Record the worker's process group before invoking the fixed provider launcher.

Installed root-owned as /opt/hermitscale/bin/codex-acp; the worker runs this
unprivileged. Only sandbox-launch is allowed to transition execution identities.
"""
import json
import os
import re
import sys
import tempfile

CONTROL = '/var/lib/hermitscale/control'
LAUNCHER = '/opt/hermitscale/bin/sandbox-launch'


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as source:
        data = source.read(65537)
    if len(data.encode()) > 65536:
        raise ValueError('control file exceeds bound')
    return json.loads(data)


def record_group():
    lease = read_json(CONTROL + '/lease.json')['lease_id']
    if not isinstance(lease, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', lease):
        raise ValueError('invalid lease identity')
    group = os.getpgrp()
    if group <= 1:
        raise ValueError('invalid process group')
    directory = CONTROL + '/groups'
    path = directory + '/' + lease + '.json'
    try:
        groups = read_json(path)
    except FileNotFoundError:
        groups = []
    if not isinstance(groups, list) or any(type(value) is not int or value <= 1 or value > 9999999999 for value in groups):
        raise ValueError('invalid recorded groups')
    if group not in groups:
        groups.append(group)
    descriptor, temporary = tempfile.mkstemp(prefix='.provider-groups-', dir=directory)
    try:
        with os.fdopen(descriptor, 'w') as target:
            json.dump(groups, target)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(arguments):
    record_group()
    os.execv('/usr/bin/sudo', ['sudo', '-n', '--', LAUNCHER, 'provider'] + arguments)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as failure:
        print('provider initialization rejected: ' + type(failure).__name__, file=sys.stderr)
        sys.exit(77)
