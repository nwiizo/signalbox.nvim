# Herdr compatibility watch

Signalbox treats Herdr's CLI and snapshot schema as an upstream contract. A scheduled GitHub Actions workflow checks the canonical `herdrdev/herdr` latest stable release every day. When its tag differs from Signalbox's verified version, the workflow opens one compatibility-audit issue for that tag, including closed issues in duplicate detection.

The currently verified release is **Herdr 0.9.0** (endpoint generation 1, private protocol 22). Signalbox still accepts Herdr 0.7.5 or newer.

## Herdr 0.9.0 audit

[Herdr 0.9.0](https://github.com/herdrdev/herdr/releases/tag/v0.9.0) separates stable endpoint compatibility from its private wire protocol. `status server` now reports `endpoint_compatible`, `private_protocol`, and `private_protocol_compatible` instead of the former `protocol` and `compatible` fields. Signalbox parses complete field names and shares this check between startup, maintenance, and health. An explicit endpoint `yes` keeps the server running even when its private protocol differs or is unknown; endpoint `no` or `unknown` cannot be overridden by private-protocol compatibility. Herdr 0.7.5–0.8.2 clients retain the legacy check.

The consumed snapshot fields and lifecycle CLI arguments remain compatible. Herdr still owns prompt submission and its five-second activity check, recent/visible terminal reads, provider detection, and native session persistence. Signalbox keeps its six-second prompt wait and eight-second process ceiling. The CLI help and release source were inspected for snapshot, start, prompt, read, explain, rename, attach, workspace/tab creation, pane targeting/move, and manifest status. No new snapshot normalization or provider-specific shim is needed.

Herdr's combined Local/SSH machine list belongs to its client UI. Signalbox continues to observe one server through the inherited CLI session/socket environment. IDs and names remain scoped to that server; switching machines in Herdr does not retarget commands from an existing pane. Multi-machine aggregation is outside this audit. Signalbox still polls snapshots, so the change to live-only lifecycle event subscriptions does not affect it.

The macOS arm64 smoke test used a checksum-verified 0.9.0 release binary, isolated config/state/socket paths, Codex 0.153.4, and Claude Code 2.1.261. Both providers started through Signalbox's tab allocation and accepted prompts through `prompt_until_working`. Snapshot normalization, active/idle preview, explanation, rename, board rendering and explanation switching, and a live Neovim terminal attach were exercised against the disposable server. Closing the Neovim attach left the agents available. Moving a disposable shell pane to another workspace retained its terminal ID. A Codex `/status` submission returned structured `agent_prompt_stalled` through Signalbox's existing error path after five seconds.

Health accepted the 0.9.0 server and current detection manifests (Codex 2026.09.05.1, Claude 2026.09.04.1). Existing v7 provider integrations were left in place; health correctly recommended Codex v8 and Claude v9. A separate disposable 0.8.2 server with a shell workspace was upgraded through `update_all`, returning `handed_off`; its next snapshot reported 0.9.0 and retained the workspace. Both initial test servers and their panes were stopped afterward. See the [extended remote and workflow validation](herdr-0.9.0-validation.md) for SSH reconnects, multiple clients, resume pickers, maintenance, and the attach-warning fix found during those tests.

The first-run Codex trust-screen limitation remains reproducible: `agent start` reported idle/ready while the trust question was visible; the first prompt accepted trust and reported working without delivering the instruction. Resending after startup produced the expected reply. This extends the 0.8.2 observation below; complete the trust screen and resend when it occurs.

Regression tests cover endpoint/private-protocol disagreement, unknown private protocols, preserving compatible servers during maintenance, and matching health results. Local `make check` and the Linux `act` matrix for Neovim v0.10.4 and stable passed. The local runner needed an isolated `DOCKER_CONFIG` because the configured desktop credential helper was absent, plus an explicit container Node path; the workflow and pinned tools were unchanged.

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
