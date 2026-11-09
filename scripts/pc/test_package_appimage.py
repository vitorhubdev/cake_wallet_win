#!/usr/bin/env python3
"""Pure filesystem tests; synthetic files only, no wallet or system mutation."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest
from package_appimage import REQUIRED, UPSTREAM, validate_layout, stage_appdir, write_checksums

class AppImagePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='pc-appimage-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'bundle with spaces'
        for name in REQUIRED:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic fixture only\n')
        (self.bundle / 'build-info.json').write_text(json.dumps({
            'version': '6.5.3+1006', 'upstreamCommit': UPSTREAM, 'commit': 'a' * 40}))
        self.icon = self.root / 'test.png'
        self.icon.write_bytes(b'fixture-icon')

    def test_valid_layout(self):
        self.assertEqual(validate_layout(self.bundle, '6.5.3', 1006)['commit'], 'a' * 40)

    def test_missing_dependency_is_rejected(self):
        (self.bundle / 'lib/libapp.so').unlink()
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            validate_layout(self.bundle, '6.5.3', 1006)

    def test_wrong_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'provenance'):
            validate_layout(self.bundle, '6.5.2', 1006)

    def test_bad_build_is_rejected(self):
        for build in (0, -1, 65535):
            with self.assertRaisesRegex(ValueError, 'Invalid'):
                validate_layout(self.bundle, '6.5.3', build)

    def test_wrong_upstream_is_rejected(self):
        info = self.bundle / 'build-info.json'
        data = json.loads(info.read_text()); data['upstreamCommit'] = 'b' * 40
        info.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'provenance'):
            validate_layout(self.bundle, '6.5.3', 1006)

    def test_external_symlink_is_rejected(self):
        target = self.root / 'outside'; target.write_text('not package content')
        (self.bundle / 'external').symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            validate_layout(self.bundle, '6.5.3', 1006)

    def test_internal_symlink_is_preserved(self):
        (self.bundle / 'lib/alias.so').symlink_to('libapp.so')
        validate_layout(self.bundle, '6.5.3', 1006)
        app = stage_appdir(self.bundle, self.root / 'AppDir', self.icon)
        self.assertTrue((app / 'lib/alias.so').is_symlink())

    def test_wallet_material_is_rejected(self):
        for name in ('wallet.keys', '.cake-wallet.lock'):
            path = self.bundle / name; path.write_text('synthetic-not-real')
            with self.assertRaisesRegex(ValueError, 'wallet/profile'):
                validate_layout(self.bundle, '6.5.3', 1006)
            path.unlink()

    def test_apprun_preserves_profile_home_and_arguments(self):
        (self.bundle / 'cake-wallet-pc').write_bytes(
            (Path(__file__).parent / 'cake-wallet-pc').read_bytes())
        (self.bundle / 'cake_wallet_pc').write_text(
            '#!/usr/bin/env bash\nprintf "%s\\0" "$HOME" "$CAKE_WALLET_DIR" "$@"\n')
        appdir = self.root / 'AppDir with spaces'
        stage_appdir(self.bundle, appdir, self.icon)
        result = subprocess.run([str(appdir / 'AppRun'), 'argument with spaces', '--synthetic'],
            cwd='/', env=dict(os.environ, HOME='/unmodified/home', CAKE_WALLET_DIR='/isolated/profile'),
            capture_output=True, check=True, timeout=5)
        self.assertEqual(result.stdout.split(b'\0')[:-1],
            [b'/unmodified/home', b'/isolated/profile', b'argument with spaces', b'--synthetic'])

    def test_checksums_have_exact_distribution_files(self):
        dist = self.root / 'dist'; dist.mkdir()
        prefix = 'CakeWalletPC-Linux-x64-6.5.3-1006'
        for suffix in ('.deb', '.tar.gz', '.AppImage'):
            (dist / (prefix + suffix)).write_bytes(b'synthetic fixture')
        (dist / (prefix + '-unrelated.log')).write_text('excluded')
        write_checksums(dist, prefix)
        first = (dist / 'SHA256SUMS-linux.txt').read_text()
        write_checksums(dist, prefix)
        self.assertEqual(first, (dist / 'SHA256SUMS-linux.txt').read_text())
        self.assertEqual(len(first.splitlines()), 3)
        self.assertNotIn('unrelated', first)

if __name__ == '__main__':
    unittest.main(verbosity=2)
