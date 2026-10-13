import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
import tempfile
from unittest.mock import patch, mock_open

spec = importlib.util.spec_from_file_location('sandbox', Path(__file__).with_name('sandbox-launch.py'))
sandbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sandbox)


class SandboxBoundaryTest(unittest.TestCase):
    def test_provider_environment_drops_management_and_git_credentials(self):
        user = SimpleNamespace(pw_name='hermitcoder', pw_dir='/home/hermitcoder')
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'injected-capability', 'SPRITES_API_KEY': 'fleet-secret', 'HS_GIT_TOKEN': 'git-secret'}, clear=True), patch.object(sandbox.os, 'open', return_value=1), patch.object(sandbox.os, 'fdopen', mock_open(read_data='{"OPENAI_API_KEY":"bounded-capability","OPENAI_BASE_URL":"https://gateway.example.test/v1","HERMITSCALE_MODEL":"fixture-model"}')):
            env = sandbox.execution_environment('provider', user)
        self.assertEqual(env['OPENAI_API_KEY'], 'bounded-capability')
        self.assertNotIn('SPRITES_API_KEY', env)
        self.assertNotIn('HS_GIT_TOKEN', env)
        self.assertEqual(env['MODEL_PROVIDER'], 'hermitscale')
        self.assertEqual(__import__('json').loads(env['CODEX_CONFIG'])['model_providers']['hermitscale']['supports_websockets'], False)

    def test_new_provider_result_clear_preserves_other_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / '.hermitscale'
            evidence.mkdir()
            (evidence / 'result.json').write_text('{"summary":"prior turn"}')
            (evidence / 'committed-artifact.txt').write_text('retained artifact')
            with patch.object(sandbox, 'WORKSPACE', str(root)):
                sandbox.clear_previous_result()
                sandbox.clear_previous_result()
            self.assertFalse((evidence / 'result.json').exists())
            self.assertEqual((evidence / 'committed-artifact.txt').read_text(), 'retained artifact')

    def test_result_clear_never_follows_a_customer_directory_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / 'workspace'
            workspace.mkdir()
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'result.json').write_text('outside evidence')
            (workspace / '.hermitscale').symlink_to(outside, target_is_directory=True)
            with patch.object(sandbox, 'WORKSPACE', str(workspace)), self.assertRaises(OSError):
                sandbox.clear_previous_result()
            self.assertEqual((outside / 'result.json').read_text(), 'outside evidence')

    def test_git_ignores_customer_global_and_system_configuration(self):
        user = SimpleNamespace(pw_name='hermitcoder', pw_dir='/home/hermitcoder')
        with patch.dict(os.environ, {'GIT_CONFIG_GLOBAL':'/workspace/evil', 'GIT_CONFIG_COUNT':'1', 'LD_PRELOAD':'injection'}, clear=True):
            env = sandbox.execution_environment('git', user)
        self.assertEqual(env['GIT_CONFIG_GLOBAL'], '/dev/null')
        self.assertEqual(env['GIT_CONFIG_SYSTEM'], '/dev/null')
        self.assertEqual(env['GIT_CONFIG_NOSYSTEM'], '1')
        self.assertNotIn('GIT_CONFIG_COUNT', env)
        self.assertNotIn('LD_PRELOAD', env)

    def test_app_environment_has_only_app_configuration(self):
        user = SimpleNamespace(pw_name='hermitapp', pw_dir='/home/hermitapp')
        with patch.dict(os.environ, {'HERMIT_REVISION': 'abc', 'OPENAI_API_KEY': 'model-secret', 'LD_PRELOAD': 'injection'}, clear=True):
            env = sandbox.execution_environment('app', user)
        self.assertEqual(env['HERMIT_REVISION'], 'abc')
        self.assertNotIn('OPENAI_API_KEY', env)
        self.assertNotIn('LD_PRELOAD', env)

    def test_user_commands_execute_only_after_namespace_and_identity_drop(self):
        user = SimpleNamespace(pw_uid=10002, pw_gid=10002, pw_name='hermitcoder', pw_dir='/home/hermitcoder')
        calls = []
        libc = SimpleNamespace(prctl=lambda *args: 0)
        with patch.object(sandbox.pwd, 'getpwnam', return_value=user), patch.object(sandbox.ctypes, 'CDLL', return_value=libc), patch.object(sandbox, 'isolate', side_effect=lambda _libc: calls.append('namespace')), patch.object(sandbox, 'checked', side_effect=lambda *_args: calls.append('privilege_lock')), patch.object(sandbox.os, 'initgroups', side_effect=lambda *_args: calls.append('groups')), patch.object(sandbox.os, 'setresgid', create=True, side_effect=lambda *_args: calls.append('gid')), patch.object(sandbox.os, 'setresuid', create=True, side_effect=lambda *_args: calls.append('uid')), patch.object(sandbox.os, 'umask'), patch.object(sandbox.os, 'execvpe', side_effect=lambda *_args: calls.append('exec')):
            sandbox.launch('coder', ['bash', '-lc', 'echo fixture'])
        self.assertEqual(calls, ['namespace', 'groups', 'gid', 'uid', 'privilege_lock', 'privilege_lock', 'exec'])

    def test_namespace_failure_never_executes_user_command(self):
        user = SimpleNamespace(pw_uid=10002, pw_gid=10002, pw_name='hermitcoder', pw_dir='/home/hermitcoder')
        with patch.object(sandbox.pwd, 'getpwnam', return_value=user), patch.object(sandbox, 'isolate', side_effect=PermissionError('mount denied')), patch.object(sandbox.os, 'execvpe') as execute:
            with self.assertRaises(PermissionError):
                sandbox.launch('coder', ['bash'])
        execute.assert_not_called()

    def test_arbitrary_signal_targets_and_modes_are_rejected(self):
        for arguments in [['TERM', '42'], ['KILL', '-42'], ['KILL', '1'], ['CHECK', '42', 'extra']]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                sandbox.signal_request(arguments)

    def test_unprivileged_caller_cannot_initialize_any_profile(self):
        with patch.object(sandbox.os, 'geteuid', return_value=10002):
            with self.assertRaises(PermissionError):
                sandbox.main(['coder', 'echo', 'fixture'])


if __name__ == '__main__':
    unittest.main()
