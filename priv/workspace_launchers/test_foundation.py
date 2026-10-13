"""Exercise the actual embedded private directory initialization without root."""
import os
from pathlib import Path
import tempfile
import sys
import textwrap
from types import SimpleNamespace
import unittest


class FoundationDirectoriesTest(unittest.TestCase):
    def initialize(self, workspace):
        source = (Path(__file__).resolve().parents[2] / 'lib/hermitscale/workspaces/foundation.ex').read_text()
        script = source.split('  workspace=os.open', 1)[1].split("  os.makedirs('/opt/hermitscale/bin'", 1)[0]
        script = textwrap.dedent('  workspace=os.open' + script).replace("'/workspace'", repr(str(workspace)))
        users = SimpleNamespace(getpwnam=lambda _name: SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid()))
        exec(compile(script, '<foundation-directory-initialization>', 'exec'), {'os': os, 'pwd': users})

    def test_new_workspace_has_private_coder_home_and_separate_app_data(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            self.initialize(workspace)
            self.assertEqual((workspace / '.codex').stat().st_mode & 0o7777, 0o700)
            for name in ('data', 'preview-data'):
                mode = (workspace / name).stat().st_mode
                self.assertEqual(mode & 0o777, 0o770)
                if sys.platform.startswith('linux'):
                    self.assertTrue(mode & 0o2000)
            self.initialize(workspace)
            self.assertTrue((workspace / '.codex').is_dir())

    def test_existing_coder_home_symlink_cannot_change_external_ownership_or_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / 'workspace'
            workspace.mkdir()
            external = root / 'external'
            external.mkdir(mode=0o755)
            (workspace / '.codex').symlink_to(external, target_is_directory=True)
            before = external.stat()
            with self.assertRaises(OSError):
                self.initialize(workspace)
            after = external.stat()
            self.assertEqual((after.st_uid, after.st_gid, after.st_mode), (before.st_uid, before.st_gid, before.st_mode))


if __name__ == '__main__':
    unittest.main()
