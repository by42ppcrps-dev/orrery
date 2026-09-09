"""Exercise the real staged-install shell flow inside a disposable filesystem.
Only external signature/process/Launch Services dependencies and the destination are stubbed.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'build-app.sh'

class StagedInstallTests(unittest.TestCase):
    def run_swap(self, root, running=False, valid=True, arguments=None):
        source = SCRIPT.read_text().replace('/Applications/$NAME.app', '$ROOT/destination/$NAME.app')
        source = source.replace('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '/usr/bin/true')
        script = root / 'build-app.sh'
        script.write_text(source)
        binary = root / 'bin'
        binary.mkdir(exist_ok=True)
        for name, status in [('pgrep', 0 if running else 1), ('codesign', 0 if valid else 1)]:
            tool = binary / name
            tool.write_text('#!/bin/sh\nexit ' + str(status) + '\n')
            tool.chmod(0o755)
        compiled = root / 'compiler-output'
        compiled.mkdir(exist_ok=True)
        (compiled/'Orrery').write_text('#!/bin/sh\nexit 0\n')
        (compiled/'Orrery').chmod(0o755)
        (binary/'swift').write_text('#!/bin/sh\ncase "$*" in *--show-bin-path*) echo "$ORRERY_FIXTURE_BIN" ;; esac\n')
        (binary/'swift').chmod(0o755)
        env = dict(os.environ, PATH=str(binary)+':/usr/bin:/bin:/usr/sbin:/sbin', ORRERY_AUTO_SIGN='0', ORRERY_SIGN_IDENTITY='', ORRERY_FIXTURE_BIN=str(compiled))
        return subprocess.run(['/bin/bash', str(script), *(arguments or ['--swap'])], env=env, capture_output=True, text=True, timeout=15)

    def fixture(self, root):
        stage = root / 'build/staging.fixture/Orrery.app'
        stage.mkdir(parents=True)
        (stage / 'payload').write_text('new verified build')
        (root / 'build/next-app-path').write_text(str(stage)+'\n')
        destination = root / 'destination/Orrery.app'
        destination.mkdir(parents=True)
        (destination / 'payload').write_text('original build')
        return stage, destination

    def test_swap_installs_staged_bundle_and_keeps_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage, destination = self.fixture(root)
            result = self.run_swap(root)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertEqual((destination/'payload').read_text(), 'new verified build')
            backups = list((root/'build').glob('previous.*/Orrery.app/payload'))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), 'original build')
            self.assertTrue(stage.exists(), 'active staged copy must survive cleanup')
            self.assertIn('Ready: '+str(destination), result.stdout)

    def test_running_app_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, destination = self.fixture(root)
            result = self.run_swap(root, running=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual((destination/'payload').read_text(), 'original build')

    def test_first_install_succeeds_without_a_previous_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, destination = self.fixture(root)
            (destination/'payload').unlink()
            destination.rmdir()
            result = self.run_swap(root)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertEqual((destination/'payload').read_text(), 'new verified build')
            self.assertIn('Ready: '+str(destination), result.stdout)

    def test_preview_preserves_the_release_waiting_for_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage, destination = self.fixture(root)
            obsolete = root/'build/staging.obsolete'
            obsolete.mkdir()
            result = self.run_swap(root, arguments=['--preview'])
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertTrue((root/'build/OrreryPreview.app/Contents/MacOS/Orrery').is_file())
            self.assertTrue(stage.is_dir(), 'a preview must not delete the pending release')
            self.assertEqual((root/'build/next-app-path').read_text().strip(), str(stage))
            self.assertFalse(obsolete.exists(), 'unreferenced staging folders should still be removed')
            self.assertEqual((destination/'payload').read_text(), 'original build')
            installed = self.run_swap(root)
            self.assertEqual(installed.returncode, 0, installed.stdout+installed.stderr)
            self.assertEqual((destination/'payload').read_text(), 'new verified build')

    def test_failed_signature_is_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, destination = self.fixture(root)
            result = self.run_swap(root, valid=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((destination/'payload').read_text(), 'original build')

    def test_invalid_stage_path_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, destination = self.fixture(root)
            (root/'build/next-app-path').write_text('/tmp/unrelated/Orrery.app')
            result = self.run_swap(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((destination/'payload').read_text(), 'original build')

class SourceInstallerTests(unittest.TestCase):
    def install(self, root, os_version='14.0', swift='6.0', available=True):
        source = (SCRIPT.parent/'Install.command').read_text()
        source = source.replace('/usr/bin/open', 'open')
        (root/'Install.command').write_text(source)
        (root/'build-app.sh').write_text('#!/bin/sh\ntouch build-was-run\n')
        (root/'build-app.sh').chmod(0o755)
        binary=root/'bin'; binary.mkdir()
        scripts = {
            'sw_vers': '#!/bin/sh\necho '+os_version+'\n',
            'xcrun': '#!/bin/sh\n'+('exit 1\n' if not available else 'echo "Apple Swift version '+swift+'"\n'),
            'open': '#!/bin/sh\ntouch app-was-opened\n',
        }
        for name, text in scripts.items():
            (binary/name).write_text(text); (binary/name).chmod(0o755)
        env=dict(os.environ, PATH=str(binary)+':/usr/bin:/bin')
        return subprocess.run(['/bin/bash', str(root/'Install.command')], env=env, input='\n', capture_output=True, text=True, timeout=10)

    def test_old_macos_is_explained_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); result=self.install(root, os_version='13.6')
            self.assertEqual(result.returncode, 1)
            self.assertIn('macOS 14', result.stdout)
            self.assertFalse((root/'build-was-run').exists())

    def test_old_swift_is_explained_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); result=self.install(root, swift='5.10')
            self.assertEqual(result.returncode, 1)
            self.assertIn('Swift 6', result.stdout)
            self.assertFalse((root/'build-was-run').exists())

    def test_missing_toolchain_is_explained(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); result=self.install(root, available=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Install Xcode', result.stdout)
            self.assertFalse((root/'build-was-run').exists())

    def test_supported_mac_builds_and_opens_from_path_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='orrery installer ') as directory:
            root=Path(directory); result=self.install(root)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertTrue((root/'build-was-run').exists())
            self.assertTrue((root/'app-was-opened').exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
