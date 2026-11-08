import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'rust_nm.sh'


class RustSymbolToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rust-nm-test-')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.sysroot = self.root / 'toolchain with space'
        self.nm = self.sysroot / 'lib/rustlib/fake-host/bin/llvm-nm'
        self.nm.parent.mkdir(parents=True)
        rustc = self.bin / 'rustc'
        rustc.write_text('#!/bin/bash\nif [[ "$1" == --print ]]; then\n'
                         + '  printf "%s\\n" "' + str(self.sysroot) + '"\n'
                         + 'else\n  printf "host: fake-host\\n"\nfi\n')
        rustc.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.root), PATH=str(self.bin) + ':/usr/bin:/bin')

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, *args):
        return subprocess.run(['bash', str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True)

    def install_nm(self, code):
        self.nm.write_text('#!/bin/bash\n' + code + '\n')
        self.nm.chmod(0o755)

    def test_current_toolchain_and_argument_boundaries(self):
        self.install_nm('printf "%s\\n" "$@"')
        result = self.invoke('--defined-only', '--extern-only', 'archive path with spaces.a')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ['--defined-only', '--extern-only', 'archive path with spaces.a'])

    def test_missing_component_is_blocked_not_apple_nm_fallback(self):
        result = self.invoke('archive.a')
        self.assertEqual(result.returncode, 2)
        self.assertIn('rustup component add llvm-tools', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_symbol_tool_failure_is_propagated(self):
        self.install_nm('echo "invalid archive" >&2; exit 7')
        result = self.invoke('bad.a')
        self.assertEqual(result.returncode, 7)
        self.assertIn('invalid archive', result.stderr)


if __name__ == '__main__':
    unittest.main()
