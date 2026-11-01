"""Basic syntax/lint and loader checks. Does not load or install the plugin."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    assert manifest['schemaVersion'] == 1
    assert manifest['license'] == 'MIT'
    for name in ('id', 'name', 'version', 'author', 'description', 'kinds', 'entryPoints'):
        assert manifest[name], name
    for name, value in manifest['entryPoints'].items():
        path = ROOT / value
        assert path.is_file() and path.resolve().is_relative_to(ROOT), name
    print('manifest/layout: PASS', flush=True)
    files = [p for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.relative_to(ROOT).parts and '__pycache__' not in p.parts]
    python_files, shell_files, js_files, qml_files = [], [], [], []
    for path in files:
        first = path.read_bytes().split(b'\n', 1)[0]
        if path.suffix == '.py' or (first.startswith(b'#!') and b'python' in first):
            python_files.append(str(path))
        elif path.suffix == '.sh' or (first.startswith(b'#!') and b'bash' in first):
            shell_files.append(str(path))
        elif path.suffix == '.js':
            js_files.append(path)
        elif path.suffix == '.qml':
            qml_files.append(str(path))
    if python_files:
        subprocess.run(['ruff', 'check', '--no-cache', '--select', 'E9,F63,F7,F82', *python_files], check=True)
        for path in python_files:
            compile(Path(path).read_text(), path, 'exec')
    if shell_files:
        subprocess.run(['shellcheck', '--severity=warning', *shell_files], check=True)
    for path in js_files:
        # QML's library directive is not JavaScript; preserve all actual JS.
        source = '\n'.join(line for line in path.read_text().splitlines() if line.strip() != '.pragma library')
        subprocess.run(['node', '--check', '-'], input=source, text=True, check=True)
    if qml_files:
        if shutil.which('qmllint'):
            subprocess.run(['qmllint', *qml_files], check=True)
        else:
            print('qmllint: SKIP (not installed; requires Qt/Quickshell import modules)')
    subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', str(ROOT / 'tests'), '-v'], check=True)
    print(f'lint: PASS ({len(python_files)} Python, {len(shell_files)} shell, {len(js_files)} JavaScript; {len(qml_files)} QML files inventoried)')


if __name__ == '__main__':
    main()
