from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IosArchiveVerifierTests(unittest.TestCase):
    def test_archive_precedes_verify_arch_variadic_architecture_arguments(self):
        script = (ROOT / 'scripts/run_ios_device.sh').read_text()
        commands = [line.strip() for line in script.splitlines()
                    if line.strip().startswith('xcrun lipo ')]
        # Apple's -verify_arch consumes subsequent positional tokens as arches.
        # Place the input archive first, otherwise its path becomes an arch name.
        self.assertEqual(commands, ['xcrun lipo "$ARCHIVE" -verify_arch arm64'])


if __name__ == '__main__':
    unittest.main()
