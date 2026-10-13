import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
import uuid

SCRIPT = Path(__file__).with_name('publication.py').read_text()


class PublicationGitBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        self.control = self.root / 'control'
        self.state = self.root / 'remote.json'
        self.state.write_text(json.dumps({'remote': None, 'pushes': 0}))
        self.git(['init'])
        self.git(['config', 'user.name', 'Fixture'])
        self.git(['config', 'user.email', 'fixture@example.test'])
        (self.workspace / 'app.py').write_text('approved baseline\n')
        self.git(['add', 'app.py'])
        self.git(['commit', '-m', 'base'])
        self.base = self.git(['rev-parse', 'HEAD']).strip()
        self.operation = str(uuid.uuid4())
        self.stub = self.root / 'git-launcher'
        self.stub.write_text('''#!/usr/bin/python3 -I
import json, os, subprocess, sys
args=sys.argv[2:]
state_path=PATH_LITERAL
state=json.load(open(state_path))
network=next((arg for arg in args if arg in ('ls-remote','push')),None)
if network:
    cwd=os.getcwd()
    if cwd==SOURCE_LITERAL or not any(arg.startswith('--git-dir=') for arg in args): sys.exit(95)
    # Verify that the credentialed repo has neither poisoned workspace config
    # nor the malicious filter; only the newly initialized bare config is read.
    config=subprocess.check_output(['git']+args[:args.index(network)]+['config','--local','--list'],text=True)
    if 'evil.invalid' in config or 'filter.evil' in config: sys.exit(96)
    if network=='push':
        state['remote']=args[-1].split(':',1)[0]; state['pushes']+=1
        json.dump(state,open(state_path,'w'))
        if state.get('lose_response'): sys.exit(1)
    elif state['remote']: print(state['remote']+'\\trefs/heads/fixture/approved')
    sys.exit(0)
os.execvp('git',['git']+args)
'''.replace('PATH_LITERAL', repr(str(self.state))).replace('SOURCE_LITERAL', repr(str(self.workspace))))
        self.stub.chmod(0o755)

    def git(self, arguments):
        return subprocess.check_output(['git'] + arguments, cwd=self.workspace, text=True, stderr=subprocess.DEVNULL)

    def request(self, reconcile_only=False):
        empty = subprocess.check_output(['git', 'hash-object', '-w', '-t', 'tree', '--stdin'], input=b'', cwd=self.workspace).decode().strip()
        diff = self.git(['--attr-source=' + empty, 'diff', '--no-ext-diff', '--no-textconv', '--binary', self.base, '--'])
        candidate = {'base_sha': self.base, 'diff': diff, 'files': []}
        return {'operation_id': self.operation, 'lease_id': str(uuid.uuid4()), 'deadline': (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=20)).isoformat(), 'repository': 'github:fixture/repo', 'base_sha': self.base, 'branch': 'fixture/approved', 'manifest': ['app.py'], 'message': 'Approved fix', 'candidate_digest': hashlib.sha256(json.dumps(candidate, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(), 'credential': 'synthetic-test-token', 'reconcile_only': reconcile_only}

    def publish(self, request):
        script = SCRIPT.replace('/workspace', str(self.workspace)).replace('/var/lib/hermitscale/control', str(self.control)).replace('/opt/hermitscale/bin/sandbox-launch', str(self.stub))
        prefix = 'import os,pwd,types\npwd.getpwnam=lambda _name: types.SimpleNamespace(pw_uid=os.getuid(),pw_gid=os.getgid())\n'
        return subprocess.run(['python3', '-I', '-c', prefix + script], input=json.dumps(request).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def evidence(self, commands=None):
        source = (Path(__file__).resolve().parents[2] / 'lib/hermitscale/workspaces/evidence.ex').read_text()
        script = source.split('  @script """', 1)[1].split('  """', 1)[0]
        script = textwrap.dedent(script).replace('\\\\', '\\').replace('/workspace', str(self.workspace))
        process = subprocess.run(['python3', '-I', '-c', script, self.base, json.dumps(commands or [])], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(process.returncode, 0, process.stderr.decode())
        return json.loads(process.stdout)

    def test_missing_and_partial_result_remain_collectible_with_explicit_invalid_flags(self):
        (self.workspace / 'app.py').write_text('partial coding changes\n')
        missing = self.evidence()
        self.assertFalse(missing['result_evidence_present'])
        self.assertFalse(missing['result_valid_json'])
        self.assertTrue(missing['diff'])
        private = self.workspace / '.hermitscale'
        private.mkdir()
        (private / 'result.json').write_text('{"summary":"partial')
        partial = self.evidence()
        self.assertTrue(partial['result_evidence_present'])
        self.assertFalse(partial['result_valid_json'])
        self.assertEqual(partial['result_diagnostic']['reason'], 'invalid_json')
        self.assertTrue(partial['diff'])
        (private / 'result.json').write_text('{"summary":"complete"}')
        valid = self.evidence()
        self.assertTrue(valid['result_evidence_present'])
        self.assertTrue(valid['result_valid_json'])
        self.assertEqual(valid['result']['summary'], 'complete')

    def test_oversized_result_capture_is_bounded_and_does_not_discard_changes(self):
        private = self.workspace / '.hermitscale'
        private.mkdir()
        (private / 'result.json').write_bytes(b'x' * 100000)
        result = self.evidence()
        self.assertFalse(result['result_valid_json'])
        self.assertEqual(result['result_diagnostic']['captured_bytes'], 65536)
        self.assertTrue(result['result_diagnostic']['truncated'])

    def test_verification_commands_are_explicit_and_preserve_failed_receipts(self):
        (self.workspace / 'package.json').write_text('{"scripts":{"test":"exit 1"}}')
        ordinary = self.evidence()
        self.assertEqual(ordinary['checks'], [])
        checked = self.evidence(['printf verified', 'exit 7'])
        self.assertEqual([check['exit_code'] for check in checked['checks']], [0, 7])
        self.assertEqual(checked['checks'][0]['output'], 'verified')
        self.assertFalse(checked['checks_passed'])

    def test_evidence_and_publisher_bind_the_same_raw_candidate_despite_attributes(self):
        (self.workspace / 'app.py').write_text('exact reviewed bytes\n')
        (self.workspace / '.gitattributes').write_text('app.py filter=evil\n')
        self.git(['config', 'filter.evil.clean', 'printf transformed-unreviewed-bytes'])
        evidence = self.evidence()
        request = self.request()
        request['candidate_digest'] = evidence['candidate_digest']
        result = self.publish(request)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        receipt = json.loads(result.stdout)
        self.assertEqual(self.git(['show', receipt['commit_sha'] + ':app.py']), 'exact reviewed bytes\n')

    def test_candidate_diff_binds_more_than_the_check_output_limit(self):
        (self.workspace / 'app.py').write_text(''.join('reviewed line %06d\n' % index for index in range(12000)))
        evidence = self.evidence()
        self.assertGreater(len(evidence['diff']), 65536)
        request = self.request()
        self.assertEqual(request['candidate_digest'], evidence['candidate_digest'])
        result = self.publish(request)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_poisoned_workspace_url_and_clean_filter_cannot_redirect_or_change_commit(self):
        (self.workspace / 'app.py').write_text('reviewed raw fix\n')
        (self.workspace / '.gitattributes').write_text('app.py filter=evil\n')
        self.git(['config', 'url.https://evil.invalid/.insteadOf', 'https://github.com/'])
        self.git(['config', 'http.extraHeader', 'Authorization: unwanted-header'])
        self.git(['config', 'filter.evil.clean', 'printf unreviewed-filter-output'])
        self.git(['config', 'filter.evil.required', 'true'])
        request = self.request()
        # The untracked attributes file is deliberately excluded by the explicit
        # manifest, but it remains bound into the full candidate fingerprint.
        request['candidate_digest'] = hashlib.sha256(json.dumps({'base_sha': self.base, 'diff': self.git(['--attr-source=' + self.git(['hash-object', '-t', 'tree', '--stdin']).strip(), 'diff', '--no-ext-diff', '--no-textconv', '--binary', self.base, '--']), 'files': [{'path': '.gitattributes', 'digest': hashlib.sha256((self.workspace / '.gitattributes').read_bytes()).hexdigest()}]}, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
        result = self.publish(request)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        receipt = json.loads(result.stdout)
        content = self.git(['show', receipt['commit_sha'] + ':app.py'])
        self.assertEqual(content, 'reviewed raw fix\n')
        self.assertTrue(receipt['verified'])
        self.assertEqual(json.loads(self.state.read_text())['pushes'], 1)

    def test_existing_branch_fails_before_advancing_local_head(self):
        (self.workspace / 'app.py').write_text('fix\n')
        self.state.write_text(json.dumps({'remote': 'b' * 40, 'pushes': 0}))
        result = self.publish(self.request())
        self.assertEqual(result.returncode, 83, result.stderr.decode())
        self.assertEqual(self.git(['rev-parse', 'HEAD']).strip(), self.base)
        self.assertEqual(json.loads(self.state.read_text())['pushes'], 0)

    def test_lost_push_response_and_readonly_retry_do_not_push_twice(self):
        (self.workspace / 'app.py').write_text('fix\n')
        self.state.write_text(json.dumps({'remote': None, 'pushes': 0, 'lose_response': True}))
        request = self.request()
        first = self.publish(request)
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        request['reconcile_only'] = True
        second = self.publish(request)
        self.assertEqual(second.returncode, 0, second.stderr.decode())
        self.assertEqual(json.loads(first.stdout)['commit_sha'], json.loads(second.stdout)['commit_sha'])
        self.assertEqual(json.loads(self.state.read_text())['pushes'], 1)


if __name__ == '__main__':
    unittest.main()
