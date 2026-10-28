"""Reference-side regressions for security fixes found during the Dart port."""
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

import ai_core
import desktop_omarchy
import flutter_backend


class DartFoundationReferenceTests(unittest.TestCase):
    def test_atomic_write_allows_trusted_ancestor_symlinks_and_fsyncs_private_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'outside'
            target.mkdir()
            (root / 'link').symlink_to(target)
            ai_core.atomic_write(root / 'link/settings.json', 'yes')
            self.assertEqual((target / 'settings.json').read_text(), 'yes')
            destination = root / 'new/private/settings.json'
            ai_core.atomic_write(destination, 'yes')
            self.assertEqual(destination.read_bytes(), b'yes')
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            self.assertEqual(destination.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_theme_reader_refuses_fifo_and_retains_managed_symlink_support(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fifo = root / 'fifo'
            os.mkfifo(fifo)
            self.assertEqual(desktop_omarchy.theme_colors(fifo), {})
            theme = root / 'theme'
            theme.write_text('background = "#123456"\n')
            link = root / 'link'
            link.symlink_to(theme)
            self.assertEqual(desktop_omarchy.theme_colors(link), {'background': '#123456'})

    def test_foundation_routes_validate_protocol_and_never_disclose_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            service = flutter_backend.Service(Path(temp) / 'settings.json')
            requests = [
                {'id': i, 'protocol': 1, 'method': method, 'params': params}
                for i, (method, params) in enumerate([
                    ('settings.get', {}), ('app.identity', {'extra': True}),
                    ('desktop.snapshot', {'extra': True}),
                    ('i18n.lookup', {'text': 'one', 'other': 'many', 'n': True}),
                    ('i18n.lookup', {'text': 'unknown'}),
                ])
            ]
            source = io.BytesIO(('\n'.join(json.dumps(q) for q in requests)+'\n').encode())
            output = io.StringIO()
            flutter_backend.serve(service, source, output)
            replies = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(replies[0]['result']['map_light_fps'], 20)
            for reply in replies[1:4]:
                self.assertEqual(reply['error'], {'code': 'invalid_request'})
            self.assertEqual(replies[4]['result']['text'], 'unknown')

    def test_settings_refuse_valid_prefix_of_oversized_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'settings.json'
            path.write_bytes(b'{"language":"pl"}' + b' ' * ai_core.SETTINGS_MAX_BYTES)
            self.assertEqual(ai_core.load_settings(path), {})

    def test_reference_translation_cache_can_be_invalidated_without_replaying_write(self):
        import i18n
        from unittest import mock
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'settings.json'
            ai_core.update_settings(path, language='de')
            service = flutter_backend.Service(path)
            with mock.patch.object(i18n, 'SETTINGS_FILE', path), mock.patch.object(i18n, '_lang', None):
                self.assertEqual(i18n.current(), 'de')
                ai_core.update_settings(path, language='pl')
                before = path.read_bytes()
                self.assertEqual(service.dispatch('app.settings_changed', {}), {})
                self.assertEqual(i18n.current(), 'pl')
                self.assertEqual(path.read_bytes(), before)
                with self.assertRaises(ValueError):
                    service.dispatch('app.settings_changed', {'extra': True})

    def test_symlinked_config_and_home_like_ancestors(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / 'var/home/user'
            home.mkdir(parents=True)
            (root / 'home').symlink_to(root / 'var/home')
            config = root / 'configs'
            config.mkdir()
            (home / '.config').symlink_to(config)
            ai_core.atomic_write(root / 'home/user/.config/asterism/settings.json', 'yes')
            self.assertEqual((config / 'asterism/settings.json').read_text(), 'yes')

    def test_untrusted_writable_and_hidden_intermediate_parents_are_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            unsafe = root / 'unsafe'
            unsafe.mkdir(mode=0o777)
            unsafe.chmod(0o777)
            safe = root / 'safe'
            safe.mkdir()
            (unsafe / 'link').symlink_to(safe)
            (root / 'alias').symlink_to(unsafe / 'link')
            for parent in (unsafe, unsafe / 'link', root / 'alias'):
                with self.assertRaises(PermissionError):
                    ai_core.atomic_write(parent / 'x.json', 'no')
            self.assertEqual(list(safe.iterdir()), [])

    def test_other_owner_is_refused_even_with_sticky_bit(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            real_stat = os.fstat
            def foreign_stat(fd):
                info = real_stat(fd)
                if info.st_ino == root.stat().st_ino and info.st_dev == root.stat().st_dev:
                    fields = list(info)
                    fields[4] = os.getuid() + 12345
                    fields[0] |= 0o1000
                    return os.stat_result(fields)
                return info
            with mock.patch.object(ai_core.os, 'fstat', side_effect=foreign_stat):
                with self.assertRaises(PermissionError):
                    ai_core.atomic_write(root / 'x.json', 'no')
            self.assertFalse((root / 'x.json').exists())

    def test_swap_between_resolve_and_walk_is_refused(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            chosen = root / 'chosen'
            chosen.mkdir()
            outside = root / 'outside'
            outside.mkdir()
            resolve = ai_core._resolve_private_parent
            def swapped(path):
                result = resolve(path)
                chosen.rename(root / 'old')
                chosen.symlink_to(outside)
                return result
            with mock.patch.object(ai_core, '_resolve_private_parent', side_effect=swapped):
                with self.assertRaises(OSError):
                    ai_core.atomic_write(chosen / 'x.json', 'no')
            self.assertEqual(list(outside.iterdir()), [])
            self.assertEqual(list((root / 'old').iterdir()), [])

    def test_final_symlink_is_replaced_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'target'
            target.write_text('keep')
            link = root / 'x.json'
            link.symlink_to(target)
            ai_core.atomic_write(link, 'new')
            self.assertFalse(link.is_symlink())
            self.assertEqual(link.read_text(), 'new')
            self.assertEqual(target.read_text(), 'keep')
