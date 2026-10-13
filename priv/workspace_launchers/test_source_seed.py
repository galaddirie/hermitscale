import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('source_seed.py').read_text()
REVISION = 'a' * 40


def source_archive(extra=None):
    content = io.BytesIO()
    with tarfile.open(fileobj=content, mode='w') as archive:
        directory = tarfile.TarInfo('tests/')
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        files = {'app.py': b'print("serving source")\n', 'tests/test_app.py': b'# test source\n', '_hermitscale_source.json': json.dumps({'source_commit': REVISION, 'recipe': 'python-sqlite-v1'}).encode()}
        for path, data in files.items():
            entry = tarfile.TarInfo(path)
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        if extra:
            archive.addfile(extra)
    return content.getvalue()


class SourceSeedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / 'workspace'
        self.control = self.root / 'control'

    def run_seed(self, archive, digest=None):
        configuration = {'base_sha': REVISION, 'recipe': 'python-sqlite-v1', 'repository': 'github:fixture/repo', 'source_bundle': {'content': base64.b64encode(archive).decode(), 'artifact_digest': digest or hashlib.sha256(archive).hexdigest(), 'deployed_revision': REVISION, 'artifact_id': 'fixture-artifact', 'app_id': 'fixture-app'}}
        path = self.root / 'input.json'
        path.write_text(json.dumps(configuration))
        script = SCRIPT.replace('/workspace', str(self.workspace)).replace('/var/lib/hermitscale/control', str(self.control)).replace("'/opt/hermitscale/bin/sandbox-launch','git'", "'git'")
        # Local OS fixture uses the current UID; production keeps root-only setup
        # and the fixed unprivileged launcher. Git and tar/file operations are real.
        prefix = "import os,sys,subprocess,pwd,types\nos.chown=lambda *a,**k: None\nos.fchown=lambda *a,**k: None\npwd.getpwnam=lambda _n: types.SimpleNamespace(pw_uid=os.getuid(),pw_gid=os.getgid())\noriginal_run=subprocess.run\ndef local_run(args,**kwargs):\n    if args[0]=='chown': return subprocess.CompletedProcess(args,0)\n    return original_run(args,**kwargs)\nsubprocess.run=local_run\nsys.stdin=open(" + repr(str(path)) + ")\n"
        return subprocess.run(['python3', '-I', '-c', prefix + script], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_serving_code_import_creates_real_local_baseline_without_reserved_proof(self):
        archive = source_archive()
        result = self.run_seed(archive)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual((self.workspace / 'app.py').read_text(), 'print("serving source")\n')
        self.assertFalse((self.workspace / '_hermitscale_source.json').exists())
        marker = json.loads((self.control / 'source-baseline.json').read_text())
        self.assertEqual(marker['artifact_digest'], hashlib.sha256(archive).hexdigest())
        self.assertEqual(marker['deployed_revision'], REVISION)
        actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.workspace, text=True).strip()
        self.assertEqual(marker['local_base_sha'], actual)
        self.assertNotEqual(actual, REVISION)

    def test_retained_turn_keeps_edits_and_original_imported_baseline(self):
        archive = source_archive()
        self.assertEqual(self.run_seed(archive).returncode, 0)
        before = (self.control / 'source-baseline.json').read_text()
        (self.workspace / 'app.py').write_text('retained fix\n')
        self.assertEqual(self.run_seed(archive).returncode, 0)
        self.assertEqual((self.workspace / 'app.py').read_text(), 'retained fix\n')
        self.assertEqual((self.control / 'source-baseline.json').read_text(), before)

    def test_digest_mismatch_cannot_import_source(self):
        result = self.run_seed(source_archive(), '0' * 64)
        self.assertEqual(result.returncode, 80)
        self.assertFalse((self.workspace / 'app.py').exists())

    def test_symlink_and_parent_escape_are_rejected_before_file_writes(self):
        for kind in ('symlink', 'parent'):
            with self.subTest(kind=kind):
                entry = tarfile.TarInfo('escape' if kind == 'symlink' else '../escape')
                if kind == 'symlink':
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = '/etc/passwd'
                result = self.run_seed(source_archive(entry))
                self.assertEqual(result.returncode, 80)
                self.assertFalse((self.workspace / 'app.py').exists())


if __name__ == '__main__':
    unittest.main()
