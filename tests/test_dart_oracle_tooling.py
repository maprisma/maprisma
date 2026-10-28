"""No wrappers or real mounts: regressions for isolated differential tooling."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from tools import dart_sdk

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('diff_core', ROOT / 'tools/diff-core.py')
assert spec is not None and spec.loader is not None
oracle = importlib.util.module_from_spec(spec)
with mock.patch.dict(sys.modules, {'dart_sdk': dart_sdk}):
    spec.loader.exec_module(oracle)


class DartOracleToolingTests(unittest.TestCase):
    def native(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'\x7fELFfixture-only-not-executed')
        path.chmod(0o700)
        return path

    def test_flutter_root_selects_native_binary_without_running_wrapper(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = self.native(root / 'sdk/bin/cache/dart-sdk/bin/dart')
            with mock.patch.dict(os.environ, {'FLUTTER_ROOT': str(root / 'sdk')}), mock.patch.object(dart_sdk.shutil, 'which', return_value=None):
                self.assertEqual(dart_sdk.resolve_dart(), str(binary))

    def test_aur_style_symlink_wrapper_resolves_sdk_without_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = self.native(root / 'flutter/bin/cache/dart-sdk/bin/dart')
            wrapper = root / 'flutter/bin/aur_dart'
            wrapper.write_text('#!/bin/sh\nexit 99\n')
            wrapper.chmod(0o700)
            link = root / 'dart'
            link.symlink_to(wrapper)
            with mock.patch.dict(os.environ, {'FLUTTER_ROOT': ''}), mock.patch.object(dart_sdk.shutil, 'which', side_effect=lambda name: str(link) if name == 'dart' else None):
                self.assertEqual(dart_sdk.resolve_dart(), str(binary))

    def test_explicit_shell_wrapper_is_rejected_before_fixture_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            wrapper = root / 'dart'
            marker = root / 'executed'
            wrapper.write_text(f'#!/bin/sh\ntouch "{marker}"\n')
            wrapper.chmod(0o700)
            result = subprocess.run([sys.executable, str(ROOT / 'tools/diff-core.py'), '--dart', str(wrapper)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not a wrapper', result.stderr)
            self.assertFalse(marker.exists())

    def test_direct_native_sdk_on_path_is_accepted(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = self.native(Path(temp) / 'bin/dart')
            with mock.patch.dict(os.environ, {'FLUTTER_ROOT': ''}), mock.patch.object(dart_sdk.shutil, 'which', side_effect=lambda name: str(binary) if name == 'dart' else None):
                self.assertEqual(dart_sdk.resolve_dart(), str(binary))

    def test_mount_guard_decodes_mountinfo_and_uses_path_boundaries(self):
        mountinfo = ('1 0 0:1 / /tmp/fixture\\040space/cache rw - fuse unionfs rw\n'
                     '2 0 0:2 / /tmp/fixture\\040space-other rw - tmpfs tmpfs rw\n')
        with mock.patch.object(Path, 'read_text', return_value=mountinfo):
            self.assertEqual(oracle.fixture_mounts(Path('/tmp/fixture space')), ['/tmp/fixture space/cache'])
            with self.assertRaisesRegex(RuntimeError, 'Unexpected fixture mount'):
                oracle.assert_no_mounts(Path('/tmp/fixture space'))

    def test_mount_guard_runs_on_subprocess_failure_before_tree_walk(self):
        with tempfile.TemporaryDirectory() as temp:
            case = {'requests': [{'method': 'settings.get'}]}
            with mock.patch.object(oracle.subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 30)), mock.patch.object(oracle, 'assert_no_mounts') as guard, mock.patch.object(oracle, 'tree') as tree:
                with self.assertRaises(subprocess.TimeoutExpired):
                    oracle.run_side(['unused'], case, Path(temp))
                guard.assert_called_once_with(Path(temp))
                tree.assert_not_called()

    def test_detected_mount_prevents_cleanup_recursion(self):
        with tempfile.TemporaryDirectory() as temp:
            with mock.patch.object(oracle.tempfile, 'mkdtemp', return_value=temp), mock.patch.object(oracle, 'assert_no_mounts', side_effect=RuntimeError('fixture mount')), mock.patch.object(oracle.shutil, 'rmtree') as cleanup:
                with self.assertRaisesRegex(RuntimeError, 'fixture mount'):
                    with oracle.fixture_root():
                        pass
                cleanup.assert_not_called()
