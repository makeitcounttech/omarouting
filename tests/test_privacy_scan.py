"""Privacy scanner integration tests; fixtures are assembled at runtime."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCANNER = Path(__file__).resolve().parents[1] / 'scripts/privacy-scan.sh'

class PrivacyTests(unittest.TestCase):
    def scan(self, text, name='sample.txt', commit=False):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as directory:
            root = Path(directory)
            (root / name).write_text(text)
            args = ['bash', str(SCANNER), '--tree', str(root)]
            if commit:
                for command in [['git', 'init', '-q'], ['git', 'add', '.'], ['git', '-c', 'user.name=Test', '-c', 'user.email=alice@example.com', 'commit', '-qm', 'fixture']]:
                    subprocess.run(command, cwd=root, check=True)
                (root / name).write_text('safe')
                args = ['bash', str(SCANNER), '--commit', 'HEAD', '--repo', str(root)]
            return subprocess.run(args, capture_output=True, text=True)

    def test_ssh_options_and_uri_aliases_tree_and_commit(self):
        alias = 'oma' + 'rchy'
        forbidden = [
            'ssh -p 22 ' + alias,
            'ssh -p22 ' + alias,
            'ssh -o BatchMode=yes -i example.key alice@' + alias,
            'ssh -oBatchMode=yes -- ' + alias,
            'ssh -v -T ' + alias,
            'ssh://' + alias,
            'ssh://alice@' + alias + ':22/project',
        ]
        for text in forbidden:
            for commit in (False, True):
                with self.subTest(text=text, commit=commit):
                    self.assertEqual(self.scan(text, commit=commit).returncode, 1)
        for text in ['ssh -p 22 example.com # Omarchy plugin', 'ssh://alice@example.com/project', 'Omarchy plugin; omarchy-shell']:
            self.assertEqual(self.scan(text).returncode, 0)

    def test_grouped_ssh_flags_consume_option_arguments(self):
        alias = 'oma' + 'rchy'
        commands = [
            'ssh -vp 22 ', 'ssh -Tp 22 ', 'ssh -vi example.key ',
            'ssh -vTp22 ', 'ssh -vvvi./example.key ',
            'ssh -4vT -vo BatchMode=yes -vp22 ',
            'ssh -vi "example key" -Tp 22 -- ',
        ]
        for command in commands:
            for commit in (False, True):
                for destination, expected in ((alias, 1), ('alice@' + alias, 1), ('example.com', 0)):
                    with self.subTest(command=command, commit=commit, destination=destination):
                        result = self.scan(command + destination, commit=commit)
                        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_rfc1918_addresses_tree_and_commit(self):
        addresses = [(10, 0, 0, 0), (10, 255, 255, 255),
                     (192, 168, 0, 0), (192, 168, 255, 255)]
        addresses += [(172, second, 1, 2) for second in range(16, 32)]
        for address in addresses:
            for commit in (False, True):
                with self.subTest(address=address, commit=commit):
                    result = self.scan('.'.join(map(str, address)), commit=commit)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('rfc1918-address', result.stdout)

    def test_public_address_boundaries_tree_and_commit(self):
        addresses = [(192, 0, 2, 1), (198, 51, 100, 254), (203, 0, 113, 2),
                     (127, 0, 0, 1), (172, 15, 255, 255), (172, 32, 0, 0),
                     (192, 167, 255, 255), (192, 169, 0, 0), (11, 0, 0, 0),
                     (10, 256, 0, 1)]
        for address in addresses:
            for commit in (False, True):
                with self.subTest(address=address, commit=commit):
                    result = self.scan('.'.join(map(str, address)), commit=commit)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_internal_domain(self):
        result = self.scan('service.' + 'home.' + 'arpa')
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_remaining_privacy_categories_tree_and_commit(self):
        forbidden = [
            'service.' + 'localhost', 'mesh' + '.example.com',
            '100.' + '64.0.1', '100.' + '127.255.254',
            '/home/' + 'alice/project', '~/' + 'Work/project',
            'hermes' + '-worker', 'claude' + '-code-worker', 'codex' + '-worker',
            'ssh ' + 'n' + 'as', 'ssh alice@' + 'v' + 'ps', 'HostName ' + 'oma' + 'rchy',
            'person@' + 'private.example',
        ]
        for text in forbidden:
            for commit in (False, True):
                with self.subTest(text=text, commit=commit):
                    self.assertEqual(self.scan(text, commit=commit).returncode, 1)

    def test_allows_public_platform_and_documentation(self):
        result = self.scan('Omarchy plugin; omarchy-shell; alice@example.com; 192.0.2.10; 198.51.100.10; 127.0.0.1; 100.63.255.255; 100.128.0.0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_exact_public_owner_email_tree_and_commit(self):
        approved = 'hello@makeitcount.tech'
        forbidden = ['other@' + 'makeitcount.tech', 'hello+tag@' + 'makeitcount.tech',
                     'hello@' + 'makeitcount.tech.example', 'Hello@' + 'makeitcount.tech']
        for commit in (False, True):
            with self.subTest(commit=commit, approved=True):
                result = self.scan(approved, commit=commit)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for text in forbidden:
                with self.subTest(commit=commit, approved=False, text=text):
                    self.assertEqual(self.scan(text, commit=commit).returncode, 1)

    def test_commit_metadata_is_scanned(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as directory:
            commands = [['git', 'init', '-q'], ['git', '-c', 'user.name=Test', '-c', 'user.email=person@' + 'private.example', 'commit', '--allow-empty', '-qm', 'fixture']]
            for command in commands:
                subprocess.run(command, cwd=directory, check=True)
            result = subprocess.run(['bash', str(SCANNER), '--commit', 'HEAD', '--repo', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)

    def test_rejects_private_filename(self):
        self.assertEqual(self.scan('safe', name='service.' + 'arpa').returncode, 1)

if __name__ == '__main__':
    unittest.main()
