# Herdr compatibility watch

Signalbox treats Herdr's CLI and snapshot schema as an upstream contract. A scheduled GitHub Actions workflow checks the canonical `herdrdev/herdr` latest stable release every day. When its tag differs from Signalbox's verified version, the workflow opens one compatibility-audit issue for that tag, including closed issues in duplicate detection.

The currently verified release is **Herdr 0.7.5** (protocol 17).

## Audit procedure

For every new stable release:

1. Read the upstream release notes and inspect protocol/schema changes.
2. Capture fresh `--help` output for the lifecycle commands used by Signalbox.
3. Run `make check`.
4. Start a disposable Herdr server, workspace, and agent.
5. Verify snapshot normalization, pane targeting, `agent explain`, `agent rename`, and `server agent-manifests`.
6. Verify preview/explain switching, rename race protection, board rendering, start, prompt, attach, and cleanup behavior.
7. Update the verified version in `lua/signalbox/compatibility.lua`, `README.md`, this document, and `.github/workflows/monitor-herdr.yml`.
8. Document shims or migrations here before closing the audit issue.

The watcher detects releases; it does not silently claim compatibility or automatically loosen the supported-version range.
