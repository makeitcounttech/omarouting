# OmaRouting

An Omarchy top-bar frontend for default/per-application routing through WireGuard, Headscale/Tailscale and proxy providers. Requested policy and observed routing state are distinct.

## Requirements

Source baseline: Omarchy 4.0.4-1, its Quickshell/QtQuick shell modules, Python 3, systemd and a compatible authenticated local routing backend. The frontend expects `/usr/local/bin/singbox-runtime`, `/usr/local/bin/singbox-connections`, `singbox-runtime-control.service` and `singbox-host-capture-guard.service`. Those privileged backend components, their installer and policy setup are NOT included in this repository. The frontend alone is not a complete VPN distribution. Never invent replacement sudoers rules or connect/capture on an unreviewed backend.

sing-box (GPL-3.0) is an external runtime dependency and is not bundled. This repository contains no sing-box executable or engine payload.

## First run

Review backend compatibility and install that backend separately before using routing controls. Enable the widget in plugin settings, import your own provider configuration through Settings → Connections, inspect status, and connect only after reviewing DNS/link inputs. User credentials and runtime state must remain outside source control. Autoconnect is opt-in; do not enable the supplied service until the backend is verified.

## Limitations

This preparation covers the canonical frontend snapshot, not later installed-only gateway additions or backend packaging. A selected provider is not proof of active traffic. Existing sockets may retain their old route. Host capture and kill-switch behavior depend on the separately reviewed backend. No routing, installation or live GUI test was run here.

## Credits and license

Plugin frontend maintained by makeitcount.tech: MIT, see LICENSE. Omarchy and Quickshell provide the shell runtime. sing-box is separately licensed GPL-3.0 and is neither vendored nor linked into this frontend. The existing plugin ID remains community.singbox-vpn.

## Install

This is a local release-preparation tree, not a published repository. Publication requires separate approval. Do not install over an existing plugin without backing it up and reviewing conflicts.

For a fresh test account with no existing plugin, copy this repository's runtime files (excluding `.git`, `.github`, `scripts`, and `tests`) into `~/.config/omarchy/plugins/community.singbox-vpn/`, retaining the root `manifest.json` and its relative entry-point layout. Use the Omarchy plugin settings to enable it. No install, enable, or desktop restart has been exercised for this release preparation.

## Uninstall

Disable the plugin in Omarchy first, then remove only its own plugin directory. Back up any settings you want to keep; removing the plugin does not necessarily remove user state or external services. Do not stop a routing service with active capture.

## Development checks

Install Python 3.13, Node.js, ruff 0.17.2, shellcheck-py 0.11.0.1 and gitleaks 8.30.1. Run `bash scripts/privacy-scan.sh`, `python -B scripts/lint.py`, and `gitleaks dir . --redact`. After committing, run `bash scripts/privacy-scan.sh --commit HEAD` and `gitleaks git . --redact --log-opts=--all`. CI repeats these checks. QML lint runs when qmllint and its Qt/Quickshell imports are available; otherwise its absence is explicitly reported, not counted as a pass.

The privacy policy scans file names and contents, including untracked files, and can read committed blobs independently of the working tree. It rejects internal domains, shared-address-space IPs (no exceptions currently), personal home/work paths, agent identities, host roles, and unapproved emails. Omarchy as a platform/product/API name is allowed; Omarchy used as an SSH/HTTP host is not. The exact email allowlist is `alice@example.com` (documentation), `noreply@paperclip.ing` (commit attribution), and `hello@makeitcount.tech` (approved public author/committer identity only, not an email support channel). Examples use `example.com`, `192.0.2.10` or `198.51.100.11`; never real credentials.
