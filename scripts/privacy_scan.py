"""Scan release file contents and names, without printing matched private values."""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import sys


def findings(text):
    rules = {
        'internal-domain': r'\b[\w.-]+\.(?:arpa|localhost)\b|\bmesh\.',
        'personal-path': r'/home/[\w.-]+|~/W' + r'ork\b',
        'agent-identity': r'\b(?:hermes|claude-code|codex)-[\w-]+',
        'host-role': r'\b(?:n' + r'as|v' + r'ps)\b|(?:\bHostName[=\s]+|(?:ssh|https?)://(?:[\w.-]+@)?)(?:omarchy)(?=[\s:/\"\']|$)',
    }
    result = [name for name, pattern in rules.items() if re.search(pattern, text, re.I)]
    # Tokenize ordinary SSH commands so options do not hide the destination.
    argument_options = set('BbcDEeFIiJLlmOopQRSWw')
    for command in re.finditer(r'\bssh[ \t]+([^\n]*)', text, re.I):
        try:
            tokens = shlex.split(command.group(1), comments=True)
        except ValueError:
            continue
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if token == '--':
                index += 1
                break
            if not token.startswith('-') or token == '-':
                break
            # SSH scans grouped short options left-to-right. An option that
            # takes a value owns the remainder, or the following token.
            for position, option in enumerate(token[1:], start=1):
                if option in argument_options:
                    if position == len(token) - 1:
                        index += 1
                    break
            index += 1
        if index < len(tokens) and re.fullmatch(r'(?:[\w.-]+@)?omarchy', tokens[index], re.I):
            result.append('host-role')
    # Loopback and RFC5737 documentation networks are public-example exceptions.
    # No RFC1918 or CGNAT address is allowlisted, including in tests/docs.
    for match in re.findall(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', text):
        octets = [int(part) for part in match.split('.')]
        if not all(part <= 255 for part in octets):
            continue
        first, second = octets[:2]
        if first == 10 or (first == 172 and 16 <= second <= 31) or (first == 192 and second == 168):
            result.append('rfc1918-address')
        if first == 100 and 64 <= second <= 127:
            result.append('tailnet-address')
    allowed_emails = {'alice@example.com', 'noreply@paperclip.ing', 'hello@makeitcount.tech'}
    emails = re.findall(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', text)
    if any(email not in allowed_emails for email in emails):
        result.append('unapproved-email')
    return sorted(set(result))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--tree', type=Path)
    group.add_argument('--commit')
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    if args.commit:
        ref = subprocess.check_output(['git', '-C', str(args.repo), 'rev-parse', '--verify', args.commit + '^{commit}'], text=True).strip()
        names = subprocess.check_output(['git', '-C', str(args.repo), 'ls-tree', '-rz', '--name-only', ref]).split(b'\0')
        files = [(n.decode(), subprocess.check_output(['git', '-C', str(args.repo), 'show', ref + ':' + n.decode()])) for n in names if n]
        files.append(('<commit-metadata>', subprocess.check_output(['git', '-C', str(args.repo), 'show', '-s', '--format=fuller', ref])))
    else:
        root = (args.tree or args.repo).resolve()
        files = []
        for path in sorted(root.rglob('*')):
            if '.git' in path.relative_to(root).parts:
                continue
            if path.is_symlink():
                files.append((str(path.relative_to(root)), str(path.readlink()).encode()))
            elif path.is_file():
                files.append((str(path.relative_to(root)), path.read_bytes()))
    count = 0
    for name, data in files:
        for category in findings(name + '\n' + data.decode('utf-8', errors='replace')):
            print(f'{name}: {category}')
            count += 1
    print(f'privacy scan: {len(files)} files; {count} findings')
    return int(count > 0)


if __name__ == '__main__':
    sys.exit(main())
