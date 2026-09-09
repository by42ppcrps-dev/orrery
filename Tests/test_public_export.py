import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('export_public', ROOT/'scripts/export_public.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PublicExportTests(unittest.TestCase):
    def fixture(self, root):
        for name in module.ROOT_FILES:
            (root/name).write_text('public source\n')
        (root/'public').mkdir()
        (root/'public/README.md').write_text('Getting started\n')
        (root/'Sources').mkdir()
        (root/'Sources/main.swift').write_text('print("hello")\n')

    def test_private_material_and_history_do_not_enter_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            for name in ['docs/private.log','.git/config','build/auth.json','scratchpad/screen.png','.env','Sources/auth.json','Resources/private-photo.png']:
                p=root/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_text('private material')
            out=root/'result.zip'; module.export(root,out)
            with zipfile.ZipFile(out) as archive:
                names=archive.namelist()
                self.assertIn('Orrery/Sources/main.swift',names)
                self.assertIn('Orrery/PUBLIC-MANIFEST.json',names)
                self.assertFalse(any('/docs/' in n or '/.git/' in n or '/build/' in n or '/scratchpad/' in n or n.endswith('/.env') or n.endswith('/auth.json') or n.endswith('/private-photo.png') for n in names))
                self.assertEqual(archive.read('Orrery/README.md'),b'Getting started\n')

    def test_relay_is_deployable_without_including_local_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            for name in ['Remote/OrreryRelay/src/index.js', 'Remote/OrreryRelay/wrangler.toml', 'Remote/OrreryRelay/package.json', 'Remote/OrreryRelay/tests/serve.js']:
                p=root/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_text('public source')
            for name in ['Remote/OrreryRelay/node_modules/private/config.json', 'Remote/OrreryRelay/.wrangler/state.json']:
                p=root/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_text('must not ship')
            out=root/'result.zip'; module.export(root,out)
            with zipfile.ZipFile(out) as archive:
                names=archive.namelist()
                self.assertIn('Orrery/Remote/OrreryRelay/src/index.js', names)
                self.assertIn('Orrery/Remote/OrreryRelay/wrangler.toml', names)
                self.assertIn('Orrery/Remote/OrreryRelay/tests/serve.js', names)
                self.assertFalse(any('/node_modules/' in n or '/.wrangler/' in n for n in names))
                ignored = archive.read('Orrery/.gitignore').decode().splitlines()
                self.assertIn('node_modules/', ignored)
                self.assertIn('.wrangler/', ignored)
                self.assertIn('.public-guard-terms', ignored)

    def test_secret_refuses_export_without_printing_value(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            secret='gh'+'p_'+'A'*36
            (root/'Sources/main.swift').write_text('let key = "'+secret+'"')
            with self.assertRaises(ValueError) as result: module.export(root,root/'result.zip')
            self.assertNotIn(secret,str(result.exception))
            self.assertIn('provider-token',str(result.exception))
            self.assertFalse((root/'result.zip').exists())

    def test_link_to_external_file_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            (root/'outside.swift').write_text('do not export')
            (root/'Sources/link.swift').symlink_to(root/'outside.swift')
            with self.assertRaises(ValueError): module.export(root,root/'result.zip')

    def test_private_term_refuses_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            (root/'Sources/main.swift').write_text('CustomerSecretProject')
            with self.assertRaises(ValueError): module.export(root,root/'result.zip',['CustomerSecretProject'])

    def test_local_guard_terms_are_loaded_automatically(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            (root/'.public-guard-terms').write_text('CustomerSecretProject\n')
            (root/'Sources/main.swift').write_text('CustomerSecretProject')
            with self.assertRaises(ValueError): module.export(root,root/'result.zip')

    def test_executable_installer_survives_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            (root/'Install.command').chmod(0o755)
            out=root/'result.zip'; module.export(root,out)
            with zipfile.ZipFile(out) as archive:
                self.assertEqual(archive.getinfo('Orrery/Install.command').external_attr >> 16 & 0o777, 0o755)

if __name__=='__main__': unittest.main()
