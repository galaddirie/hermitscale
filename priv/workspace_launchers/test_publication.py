"""Run the publication helper against a real disposable Git remote."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class PublicationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.workspace = root / 'workspace'
        self.workspace.mkdir()
        self.remote = root / 'remote.git'
        self.git('init', '--bare', str(self.remote))
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'Workspace test')
        self.git('config', 'user.email', 'workspace@example.test')
        (self.workspace / 'app.txt').write_text('initial\n')
        self.git('add', 'app.txt')
        self.git('commit', '-m', 'Initial')
        self.git('remote', 'add', 'origin', 'https://github.com/acme/example.git')
        self.launcher = root / 'sandbox-launch'
        self.launcher.write_text('#!' + sys.executable + '\n' +
            'import os, subprocess, sys\n' +
            'assert sys.argv[1] == "git"\n' +
            'args = [value.replace("https://github.com/acme/example.git", ' + repr(str(self.remote)) + ') for value in sys.argv[2:]]\n' +
            'env = dict(os.environ, GIT_ALLOW_PROTOCOL="file")\n' +
            'sys.exit(subprocess.run(["git"] + args, env=env).returncode)\n')
        self.launcher.chmod(0o700)
        source = Path(__file__).with_name('publication.py').read_text()
        self.script = source.replace("root = '/workspace'", 'root = ' + repr(str(self.workspace)))
        self.script = self.script.replace("launcher = '/opt/hermitscale/bin/sandbox-launch'", 'launcher = ' + repr(str(self.launcher)))
        self.script = self.script.replace("'/var/lib/hermitscale/control/publication.lock'", repr(str(root / 'publication.lock')))
        self.script = self.script.replace("pwd.getpwnam('hermitcoder')", 'pwd.getpwuid(os.getuid())')

    def git(self, *arguments):
        return subprocess.run(['git', *arguments], cwd=self.workspace, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()

    def publish(self, repository='github:acme/example'):
        request = {'repository': repository, 'branch': 'feature/update',
            'message': 'Update application', 'credential': 'test-token'}
        return subprocess.run([sys.executable, '-I', '-c', self.script],
            input=json.dumps(request).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_commits_pushes_and_reconciles_retries_without_private_provider_files(self):
        (self.workspace / 'app.txt').write_text('edited\n')
        for directory in ('.codex', '.hermitscale'):
            private = self.workspace / directory
            private.mkdir()
            (private / 'private.json').write_text('secret fixture\n')
        first = self.publish()
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        result = json.loads(first.stdout)
        self.assertEqual(result['repository'], 'acme/example')
        self.assertEqual(result['commit_sha'], self.git('--git-dir=' + str(self.remote), 'rev-parse', 'feature/update'))
        self.assertEqual(self.git('--git-dir=' + str(self.remote), 'ls-tree', '--name-only', 'feature/update'), 'app.txt')
        retry = self.publish()
        self.assertEqual(retry.returncode, 0, retry.stderr.decode())
        self.assertEqual(json.loads(retry.stdout), result)
        (self.workspace / 'app.txt').write_text('next edit\n')
        next_result = self.publish()
        self.assertEqual(next_result.returncode, 0, next_result.stderr.decode())
        self.assertNotEqual(json.loads(next_result.stdout)['commit_sha'], result['commit_sha'])
        self.assertEqual(self.git('rev-parse', 'HEAD^'), result['commit_sha'])

    def test_selected_repository_must_match_checkout_before_any_commit(self):
        original = self.git('rev-parse', 'HEAD')
        (self.workspace / 'app.txt').write_text('edited\n')
        result = self.publish('github:other/repository')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git('rev-parse', 'HEAD'), original)
        self.assertEqual(self.git('diff', '--cached', '--name-only'), '')


if __name__ == '__main__':
    unittest.main()
