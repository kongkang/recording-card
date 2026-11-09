import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'prepare_asr_models.py'
spec = importlib.util.spec_from_file_location('prepare_asr_models', SCRIPT)
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)


class PrepareAsrModelsTest(unittest.TestCase):
    def test_production_and_local_pins_are_separate(self):
        self.assertEqual(models.ARTIFACTS['model.int8.onnx'][0], 239233841)
        self.assertEqual(models.LOCAL_ARTIFACTS['model.int8.onnx'][0], 237115547)
        self.assertNotEqual(models.ARTIFACTS['model.int8.onnx'][1],
                            models.LOCAL_ARTIFACTS['model.int8.onnx'][1])
        self.assertEqual(models.ARTIFACTS['tokens.txt'], models.LOCAL_ARTIFACTS['tokens.txt'])

    def test_exact_size_and_hash_required(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'm.onnx'
            path.write_bytes(b'abc')
            digest = hashlib.sha256(b'abc').hexdigest()
            self.assertTrue(models.verified(path, 3, digest))
            self.assertFalse(models.verified(path, 4, digest))
            self.assertFalse(models.verified(path, 3, '0' * 64))
            with self.assertRaises(ValueError):
                models.require_verified(path, 3, '0' * 64)

    def test_verify_only_local_is_offline_and_does_not_modify_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pins = {}
            for name, data in [('model.int8.onnx', b'model'),
                               ('tokens.txt', b'tokens'), ('silero_vad.onnx', b'vad')]:
                (root / name).write_bytes(data)
                pins[name] = (len(data), hashlib.sha256(data).hexdigest())
            output = root / 'manifest.json'
            with patch.object(models, 'LOCAL_ARTIFACTS', pins), \
                    patch.object(models, 'download', side_effect=AssertionError('network forbidden')), \
                    patch.object(models, 'copy_verified', side_effect=AssertionError('copy forbidden')):
                models.main(['--profile', models.LOCAL_PROFILE,
                             '--source-directory', str(root), '--vad-source', str(root / 'silero_vad.onnx'),
                             '--verify-only', '--manifest-output', str(output), '--accept-model-license'])
            manifest = json.loads(output.read_text())
            self.assertEqual(manifest['artifact_profile'], models.LOCAL_PROFILE)
            self.assertIsNone(manifest['source_commit'])
            self.assertFalse(manifest['runtime_defines']['RC_ASR_ALLOW_DOWNLOAD'])
            self.assertTrue(manifest['runtime_defines']['RC_ASR_LOCAL_ARTIFACTS_APPROVED'])
            self.assertEqual((root / 'model.int8.onnx').read_bytes(), b'model')
            self.assertEqual(manifest['files']['silero_vad.onnx']['sha256'], pins['silero_vad.onnx'][1])

    def test_local_mismatch_does_not_emit_manifest_or_use_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / 'manifest.json'
            with patch.object(models, 'download', side_effect=AssertionError('network forbidden')):
                with self.assertRaises(ValueError):
                    models.main(['--profile', models.LOCAL_PROFILE,
                                 '--source-directory', str(root), '--vad-source', str(root / 'vad'),
                                 '--verify-only', '--manifest-output', str(output), '--accept-model-license'])
            self.assertFalse(output.exists())

    def test_local_sources_never_implicitly_replace_production_profile(self):
        with self.assertRaises(SystemExit):
            models.main(['--source-directory', '/tmp/source', '--accept-model-license'])
        with self.assertRaises(SystemExit):
            models.main(['--profile', models.LOCAL_PROFILE, '--accept-model-license'])
        with self.assertRaises(SystemExit):
            models.main(['--verify-only'])

    def test_weight_destination_inside_repository_is_rejected(self):
        with self.assertRaises(ValueError):
            models.check_destination(SCRIPT.parents[1] / 'app/assets/models/model.int8.onnx')

    def test_atomic_local_copy_validates_and_preserves_good_target_on_bad_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, target = root / 'source', root / 'target'
            source.write_bytes(b'abc')
            digest = hashlib.sha256(b'abc').hexdigest()
            models.copy_verified(source, target, 3, digest)
            source.write_bytes(b'bad')
            with self.assertRaises(ValueError):
                models.copy_verified(source, target, 3, digest)
            self.assertEqual(target.read_bytes(), b'abc')
            self.assertFalse((root / 'target.part').exists())

    def test_remote_source_stays_pinned_to_https_allowlist(self):
        for url in ['http://huggingface.co/m', 'https://evil.test/m',
                    'https://user@huggingface.co/m', 'https://huggingface.co:444/m']:
            with self.assertRaises(ValueError):
                models.check_url(url)
        models.check_url(models.BASE + '/model.int8.onnx')


if __name__ == '__main__':
    unittest.main()
