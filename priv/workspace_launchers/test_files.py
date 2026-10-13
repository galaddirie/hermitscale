"""Exercise the actual embedded bounded-file implementation without root."""
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


class BoundedFilesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.workspace = root / 'workspace'
        self.workspace.mkdir()
        self.outside = root / 'outside'
        self.outside.mkdir()
        source = (Path(__file__).resolve().parents[2] / 'lib/hermitscale/workspaces/files.ex').read_text()
        self.script = textwrap.dedent(source.split('  @script """\n', 1)[1].split('  """', 1)[0])
        self.script = self.script.replace("'/workspace/'", repr(str(self.workspace) + '/'))
        self.script = self.script.replace("'/workspace'", repr(str(self.workspace)))
        self.script = self.script.replace("pwd.getpwnam('hermitcoder')", 'pwd.getpwuid(os.getuid())')

    def run_file(self, operation, path, maximum=64, content=None):
        return subprocess.run([sys.executable, '-I', '-c', self.script,
            operation, str(self.workspace / path), str(maximum)],
            input=None if content is None else base64.b64encode(content),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_result_read_rejects_oversized_files_and_preserves_other_files(self):
        private = self.workspace / '.hermitscale'
        private.mkdir()
        result = private / 'result.json'
        result.write_bytes(b'{"answer":"done"}')
        read = self.run_file('read', '.hermitscale/result.json')
        self.assertEqual(read.returncode, 0, read.stderr.decode())
        self.assertEqual(base64.b64decode(read.stdout), result.read_bytes())
        result.write_bytes(b'x' * 65)
        self.assertEqual(self.run_file('read', '.hermitscale/result.json').returncode, 74)

    def test_read_and_write_cannot_follow_file_or_directory_symlinks(self):
        external = self.outside / 'external.txt'
        external.write_bytes(b'external')
        (self.workspace / 'file-link').symlink_to(external)
        (self.workspace / 'directory-link').symlink_to(self.outside, target_is_directory=True)
        for path in ['file-link', 'directory-link/external.txt']:
            self.assertEqual(self.run_file('read', path).returncode, 73)
            self.assertEqual(self.run_file('write', path, content=b'changed').returncode, 73)
        self.assertEqual(external.read_bytes(), b'external')

    def test_confined_write_creates_coder_owned_parents_and_read_is_bounded(self):
        written = self.run_file('write', 'lib/app.txt', content=b'retained')
        self.assertEqual(written.returncode, 0, written.stderr.decode())
        self.assertEqual((self.workspace / 'lib/app.txt').stat().st_uid, os.getuid())
        self.assertEqual(base64.b64decode(self.run_file('read', 'lib/app.txt').stdout), b'retained')
        self.assertEqual(self.run_file('read', 'missing').returncode, 72)


if __name__ == '__main__':
    unittest.main()
