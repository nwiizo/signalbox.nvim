# Herdr 0.9.0 remote and workflow validation

Validated on 2026-09-08 against the v0.9.0 release binaries. This extends the [compatibility audit](upstream-herdr.md#herdr-090-audit) with SSH, multiple clients, and common Signalbox operations.

## Environment

- Client: macOS arm64, Herdr 0.9.0, Neovim 0.12.5.
- SSH target: disposable Linux x86_64 Docker container, OpenSSH 9.6p1, Herdr 0.9.0, Neovim 0.10.4. The SSH port was published only on loopback. A temporary Ed25519 key authenticated the connection.
- Herdr: isolated local config/state and a remote named session, `signalbox-audit`; endpoint generation 1 and private protocol 22.
- Remote Signalbox ran inside a Herdr-owned pane. A shell registered through `pane report-agent` provided controlled idle/working/blocked transitions. These were API-driven lifecycle tests, not remote AI inference; provider credentials were not copied to the container.
- Native resume checks ran locally with Codex 0.153.4 and Claude Code 2.1.263, using only conversations created by the compatibility smoke test.
- The attach warning was also reproduced with the actual local LazyVim configuration and Noice notification provider in an interactive Neovim terminal.

## Results

| Operation | Result and evidence |
| --- | --- |
| SSH setup and named session | Plain SSH succeeded. `machine add --remote-session signalbox-audit` prepared the remote server and saved an enabled profile. Both the saved-machine UI and standalone `--remote --session` client connected. |
| Local/remote navigation | Selecting the saved machine displayed the remote shell. Typing through the local Herdr UI produced `REMOTE_INPUT_OK` on the remote shell. Selecting Local returned to the local shell. |
| Network interruption and reconnect | Stopping only the disposable SSH service produced the reconnecting state and an unavailable-endpoint overlay. Restarting SSH restored the saved-machine connection automatically. The remote shell PID 198 and Neovim PID 719 survived the interruption. |
| Input during disconnection | A command typed into the disconnected remote view was absent from the remote transcript after reconnect. It was not queued for later execution. |
| Local work during remote failure | Local still accepted a command and printed `LOCAL_DURING_DROP`. Reconnecting the remote machine did not take selection away from Local. |
| Independent client tabs and sizes | Two clients showed `/work/project` and `/work/other` at the same time. `stty size` reported 42 rows × 50 columns and 41 rows × 61 columns, respectively; navigating one client did not switch the other's visible tab. |
| Saved-machine lifecycle | Rename updated the live sidebar. Disabling the selected machine returned to Local; enabling reconnected it. Removing the profile left the remote server and shell PID 198 running. |
| Remote Signalbox board | The remote Neovim normalized the snapshot, displayed the registered agent, and followed its semantic state. Signalbox remained scoped to the server inherited by that Neovim process. |
| Cross-workspace attach and return | `:SignalboxAttach remote-reviewer` moved the actual Neovim pane from the sole-pane source workspace into the agent's workspace. The source closed, the terminal identity and Neovim PID remained intact, and the direct attach worked. `<C-g>` detached and reopened the board. A subsequent attach still resolved the moved Neovim pane correctly. |
| Attention notifications | A blocked transition was suppressed while the board was visible. A later blocked transition with the board closed notified once. Completion notified while the board was open. |
| Blocked prompt protection | Prompting the blocked test agent returned `agent_blocked`; the submitted command was not sent to the shell. |
| Direct attach ownership | A second writable attach was rejected while an SSH client owned the terminal. Explicit `:SignalboxAttach!` acquired it and the previous direct client exited. A warning-display bug found here was fixed as described below. |
| Multiline direct paste | A two-command bracketed paste did not create its target file before Enter. After Enter, the file contained exactly `first` and `second` on separate lines. |
| Read-only terminal observer | `terminal session observe --cols 40 --rows 10` emitted a `terminal.frame` record while a writable direct client remained attached. The shell's dimensions stayed 43 × 62 before and after observation. The observer was deliberately stopped after three seconds; its timeout exit was expected. |
| Worktree group close protection | A disposable clone and linked worktree were opened as a group. Closing only the primary returned `workspace_group_close_required` and retained both workspaces. Explicit `workspace close --group` closed the group. No commits were created. |
| Integration and manifest maintenance | With missing provider config directories, `update_all` surfaced the installation error. After creating empty config directories in the container, it installed Codex v8 and Claude v9 hooks and refreshed manifests without replacing the compatible server. Repeating maintenance skipped the current hooks. This checks installation/status, not hook delivery from authenticated remote providers. |
| Native Codex resume | Signalbox allocated a workspace, launched `codex resume`, and showed only the test conversation in the cwd-filtered picker. Selecting it restored the previous prompt and `SIGNALBOX_090_OK` reply. |
| Native Claude resume | Signalbox allocated a tab, launched `claude --resume`, and restored the test conversation and its native session identity. The restored transcript contained a login-expired response, so successful new model output was not verified. |

## Attach warning fix

A rejected direct attach prints an instruction to retry with `--takeover`. In a narrow terminal, that word can wrap across rows. Neovim also pads the terminal buffer with blank rows, so reading only its final eight rows lost the diagnostic and produced a generic health warning.

Signalbox now retains a bounded 4 KiB tail of the raw PTY output in memory and uses it to classify an unsuccessful attach. It reports `:SignalboxAttach! <terminal_id>` even when the displayed diagnostic wraps or sits above blank rows, so retrying targets the same agent. It does not save this output to disk.

Two regression cases cover a takeover diagnostic split across output callbacks and a generic connection failure. The takeover case failed before the fix. The SSH reproduction and the actual local Noice provider both displayed the corrected instruction afterward.

## Verification and limits

- Local `make check`: 117 tests passed, with StyLua and Luacheck passing.
- The same 117 headless tests passed over SSH on remote Neovim 0.10.4.
- The local `act` CI matrix passed on Neovim v0.10.4 and stable with the workflow's pinned tools. As in the initial audit, the runner used an isolated Docker config and an explicit container Node path.
- This was real SSH transport between macOS and a Linux container over loopback. WAN latency, packet loss, bastions, other authentication methods, and a separate physical host were not tested.
- The local Signalbox board does not aggregate Herdr's Local/SSH machine catalog. Remote Signalbox was tested by running Neovim on the SSH target; changing machines in the local Herdr UI did not retarget its local CLI environment.
- Authenticated AI inference on the SSH target was not tested. Local Claude authentication had expired. Codex resume restored the conversation, but the local v7 integration did not expose its session identity in the observed snapshot, so automatic restoration after a full server restart is not claimed here.
- The first-run Codex trust-screen issue from the initial audit remains. Its trust screen also appeared before the resume picker and was completed explicitly for the empty test directory.
- Graphics, image clipboard bridging, themes, Windows, and live-only event subscriptions were not exercised. Signalbox continues to use snapshot polling.

The disposable Herdr sessions, panes, SSH service, container, temporary key/agent, and temporary trust entries were removed after validation. The installed Herdr binary and the user's running Herdr server were not upgraded by these tests.

## Pre-commit recheck

The final code was checked again on 2026-09-08: local `make check` passed all 117 tests, and both `act` entries (Neovim v0.10.4 and stable) passed the same 117 tests. The existing runner image stores Node at `/opt/acttoolcache/node/24.19.0/x64/bin`; supplying that path and an empty isolated Docker config resolved the local runner setup failure without changing the workflow.

A fresh disposable Herdr 0.9.0 server and a shell registered through `pane report-agent` exercised the actual LazyVim and Noice configuration. A competing writable client rejected the Signalbox attach in a 32-column split: `--takeover` wrapped between rows and the buffer ended with blank rows. Noice displayed `:SignalboxAttach!` with the same stable terminal ID. Running that command attached in terminal mode and disconnected the previous client. `<C-g>` returned to the visible board in normal mode; the terminal ID and idle agent remained present after closing Neovim. The test server and shell were then stopped.

Health reported the server as compatible and both detection manifests as current. The existing local provider hooks still reported Codex v7 < v8 and Claude v7 < v9; this recheck did not modify them. This final smoke test covers Signalbox's attach and compatibility paths using a controlled shell; it does not repeat the earlier SSH or authenticated provider checks.
