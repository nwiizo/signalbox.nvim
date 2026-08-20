# Herdr compatibility watch

Signalbox treats Herdr's CLI and snapshot schema as an upstream contract. A scheduled GitHub Actions workflow checks the canonical `herdrdev/herdr` latest stable release every day. When its tag differs from Signalbox's verified version, the workflow opens one compatibility-audit issue for that tag, including closed issues in duplicate detection.

The currently verified release is **Herdr 0.8.2** (protocol 20). Signalbox still accepts Herdr 0.7.5 or newer.

## Herdr 0.8.2 audit

Herdr 0.8.2 raises the wire protocol from 19 to 20 for terminal input and graphics changes. The CLI contracts Signalbox uses remain compatible: `api snapshot` retains the consumed agent, workspace, pane, version, and protocol fields; prompt, recent/visible read, explain, rename, attach, workspace/tab creation, pane targeting, and agent-manifest commands retain their arguments and success response shapes.

The release rejects prompts to already blocked agents with `agent_blocked`, improves new-pane and first-run readiness waits in `agent start`, and reduces alternate-screen read work. Signalbox's existing structured-error path surfaces `agent_blocked` without sending duplicate input. No migration or new compatibility shim is required.

One upstream limit remains. With Herdr 0.8.2, Codex 0.148.0, and detection manifest 2026.08.09.1 on macOS arm64, a fresh repository's Codex trust screen was still reported as idle and ready. Accepting trust then produced a startup working transition even though the initial instruction was not delivered, so Herdr did not return `agent_prompt_stalled` and Signalbox could not retain a retry draft. This is the first-run readiness boundary tracked by [Herdr #2410](https://github.com/herdrdev/herdr/issues/2410). Signalbox deliberately leaves provider-screen detection with Herdr; finish the trust screen in the attached terminal and resend the instruction when this occurs.

## Herdr 0.8.0 audit

Herdr 0.8.0 keeps the Signalbox lifecycle commands and snapshot fields compatible while adding workspace reordering and more resumable agent kinds. Signalbox delegates the jobs added or hardened upstream instead of duplicating them:

- Herdr owns atomic prompt submission and confirms initial activity through `agent prompt --wait --until working`.
- Herdr owns alternate-screen transcript collection for idle agents; Signalbox falls back to the current visible screen when active-agent history cannot be collected.
- Herdr owns native session restore, including headless restore and the owning Codex session identity. Signalbox resume remains only for rehoming a conversation that started outside Herdr.
- Herdr's bundled agent skill and worktree-group ordering remain outside Signalbox's Neovim attention surface.

The compatibility shim in Signalbox parses structured CLI errors from stderr so it can retain an initial-instruction draft only after Herdr reports `agent_prompt_stalled`. No transcript or duplicate session state is persisted.

The audited CLI details are intentionally small: Herdr defines a stalled prompt as no observed state change within five seconds, so Signalbox gives the command a six-second window and its process an eight-second ceiling. Supported 0.7.5 through verified 0.8.2 publish `agent explain --format text`, which keeps the preview output explicit. Herdr 0.8.0 and 0.8.2 return `agent_info` after `agent rename`; Signalbox depends only on command success and refreshes the canonical snapshot instead of branching on that response label.

## Audit procedure

For every new stable release:

1. Read the upstream release notes and inspect protocol/schema changes.
2. Capture fresh `--help` output for the lifecycle commands used by Signalbox.
3. Run `make check`.
4. Start a disposable Herdr server, workspace, and agent.
5. Verify snapshot normalization, pane targeting, `agent prompt --wait`, recent/visible reads, `agent explain`, `agent rename`, and `server agent-manifests`.
6. Verify idle/active preview, explain switching, rename race protection, board rendering, start, prompt-stall recovery, attach, manifest health, and cleanup behavior.
7. Update the verified version in `lua/signalbox/compatibility.lua`, `README.md`, this document, and `.github/workflows/monitor-herdr.yml`.
8. Document shims or migrations here before closing the audit issue.

The watcher detects releases; it does not silently claim compatibility or automatically loosen the supported-version range.
