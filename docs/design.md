# Signalbox design notes

## Job model

The core functional job is:

> When several delegated coding tasks are running while I edit, help me identify the next human intervention, inspect enough context to decide, act, and return to editing without terminal-pane touring.

The emotional job is to feel in control without watching every agent. The social job is to make concurrent delegation legible and reviewable rather than magical.

This uses [Jobs to Be Done](https://www.christenseninstitute.org/theory/jobs-to-be-done/) as a design lens: organize capabilities around the progress an operator needs in a particular situation. The jobs below are working hypotheses grounded in repository issues and reproducible interactions, not validated findings from user interviews. Success means reaching the needed intervention and returning to editing with less searching, without losing the target or hiding unreviewed work.

An adjacent continuity job appears when work started in an ordinary terminal:

> When I realize an existing conversation needs persistence and attention monitoring, help me resume that exact saved conversation inside Herdr without copying its transcript or guessing which session I meant.

The closest conceptual model is a railway signal box. A signal box observes shared traffic, makes exceptions conspicuous, and lets an operator route or halt movement. It does not become the locomotive. In the same way, Signalbox must not recreate Herdr's process supervisor or the coding agents' interfaces.

## Progress forces

- Push: terminal pane touring, lost session context, unclear completion state, and initial instructions swallowed by provider update or setup screens.
- Pull: one compact attention inbox inside the editor.
- Anxiety: killing a persistent agent, prompting the wrong session, or hiding useful output.
- Habit: Lazygit-sized focused tools, native terminals, existing Codex/Claude integrations.

The design reduces anxiety with stable terminal identity, explicit actions, bounded context, no transcript persistence, and no implicit broadcast.

## Ownership boundary

| Concern | Owner |
| --- | --- |
| PTYs, processes, semantic agent status | Herdr |
| Session persistence and reconnectability | Herdr |
| Agent-native UX and protocol | Codex / Claude Code |
| Attention ordering and current-project filtering | Signalbox |
| Ephemeral recent-output preview | Signalbox |
| Neovim buffer/range/diagnostic context | Signalbox |
| Repository inspection | Snacks Lazygit / Diffview |

Signalbox stores no transcript and no duplicate session database. `terminal_id` is its stable in-memory key; actions use the latest `pane_id`, because that is the current Herdr command target. Herdr owns prompt delivery and reports whether the initial instruction made the agent start working. Signalbox keeps that instruction only as an in-memory recovery draft when delivery stalls.

## Interaction sequence

1. Bootstrap from `herdr api snapshot`.
2. Show current-project agents plus blocked/done work elsewhere, with a count of hidden working agents.
3. Sort agent rows by blocked, done, working, idle, unknown.
4. Read only the selected agent's recent unwrapped terminal output.
5. Let the operator explain a surprising state, rename a role, attach, prompt (including retrying an intercepted initial instruction), start, resume an exact saved conversation, inspect Git, or open a diff.
6. Return from attach to the same terminal, acknowledge reviewed completions explicitly, and close the board to resume editing. Preserve Herdr state when the board or Neovim closes.

## Milestones

- v0.1: Herdr 0.7.5+ lifecycle (verified through 0.9.5), focused float, preview, context, native attach, Lazygit/Diffview actions.
- v0.2: raw Unix-socket event subscription with reconnect, snapshot re-bootstrap, and polling fallback.
- Later: opt-in structured review adapters; no automatic all-agent context broadcast.

## Job-driven priorities

These are stages of one intervention, rather than separate reasons to add more screens.

| Progress needed | Situation | Existing capabilities and changes | Acceptance check |
| --- | --- | --- | --- |
| Notice the next intervention | Several Spaces have agents, but only some need a human. | Attention filtering, notifications, and urgency ordering across Spaces ([#7](https://github.com/nwiizo/signalbox.nvim/issues/7)). List `j` / `k` moves directly between agents, skipping headings. | A later Space with blocked work rises first; one navigation action selects another agent, including across Space boundaries. |
| Understand enough to decide | A status or completion needs inspection. | Recent output, state explanation (`e`), role names (`n`), Git (`g`), and diff (`d`). Shared actions work from either board pane; `1` / `2` select panes. | Inspecting output does not acknowledge work or alter the agent; right-pane scrolling remains normal Neovim scrolling. |
| Act on the intended conversation | The target may move while the operator writes an instruction. | Prompt and editor-context actions revalidate terminal identity against a fresh snapshot ([#6](https://github.com/nwiizo/signalbox.nvim/issues/6)); attach opens the native agent UI. Failed instructions remain recoverable in memory. | Movement follows the same terminal; replacement, disappearance, or failed validation stops submission and preserves the text. |
| Continue without finding the target again | The operator returns after interacting in an attached terminal. | The return chord selects that terminal on the board, revealing all agents only when needed. Existing selection survives updates, reopening, and preview layout changes. | A direct attach outside the current project returns to the same terminal. A disappeared target falls back to the first visible agent. |
| Finish the intervention and resume editing | Completed work has been reviewed, or the current view is empty. | Explicit acknowledgement (`x`, [#8](https://github.com/nwiizo/signalbox.nvim/issues/8)), reason-specific empty views, and close (`q`). Reviewed work remains available with `A`; a new completion becomes visible again. | Reviewed completions, filtering, no agents, and stale state have distinct guidance. Finishing review does not invite unnecessary new work. |

Starting (`a`) and resuming (`R`) support delegation and continuity when the operator already has work to assign. They are available actions, not a default response to an empty attention queue.

The current changes address observable friction: native line navigation could land on a heading instead of a target; returning from a direct attach could select another agent; and every empty snapshot suggested starting work, even after all completions were acknowledged. Ordinary board reopening already retained selection, so it is covered as preserved behavior. Shared board mappings now have one definition, reducing differences between list and preview actions.

Verification on 2026-10-20 used Neovim 0.10.4 and 0.12.6 with the CI-pinned formatter and linter. An actual LazyVim configuration with Noice and Snacks input, connected to a disposable Herdr 0.9.5 server with controlled shell agents, exercised cross-Space navigation, pane switching, resize, input cancellation, direct attach return, acknowledgement, and closing back to the original editor window. Resize kept both board window IDs, focus, selection, and z-index 25; the input used z-index 50 and returned to the preview on cancellation. This checks the UI path without making claims about provider inference. The Linux Actions matrix was not reproduced locally because `act` is absent and the Docker daemon is unavailable.

An operation audit on 2026-10-21 checked the upstream [Herdr input rules](https://herdr.dev/docs/agent-automation/#choose-the-control-surface), [direct attach](https://herdr.dev/docs/agents/#attach-directly-to-an-agent), [Neovim terminal modes](https://neovim.io/doc/user/terminal/#terminal-input), and installed Snacks input/picker bindings. Three mismatches were corrected: cancelled agent selection now stops the action, known blocked agents point to native attach rather than an instruction input, and a focused attach client's clean exit returns to the same agent on the board. Blocking discovered during submission preserves the instruction with a definite not-sent result; other submission failures retain the uncertain-delivery warning. The on-screen guide and README distinguish board, dialog, terminal-input, and terminal-Normal controls.

All 146 regression tests, formatting, and lint checks passed on both Neovim versions. The actual LazyVim/Snacks configuration reproduced picker cancellation, input-to-blocked draft preservation without terminal input, native `Ctrl-b q` detach with the agent process still alive, and Normal-mode inspection followed by resumed input. The disposable Herdr 0.9.5 server used controlled shell agents; no provider inference was needed. Test sessions and their temporary files were removed. Linux CI remains subject to the environment limitation above.

Snapshot validation and prompt submission are separate Herdr requests. Herdr still owns final foreground-process validation. If submission fails, the notification distinguishes uncertain delivery from a pre-send rejection, preserves a draft, and asks the operator to inspect the agent before retrying. Signalbox never automatically replays a failed submission.

Herdr 0.9.5 exposes an optional `completion_seq`. Signalbox carries it through normalized snapshots and `SignalboxAgentStatusChanged` event data, uses it to acknowledge one completion, and deduplicates completion notifications by this number. A later done snapshot with a different number can therefore surface new work without observing its intermediate working state. Terminal `revision` can stay unchanged across completions and is not a completion identity. Servers without `completion_seq` retain the status-transition and revision fallback; on those servers an entire working-to-done cycle between snapshots remains undetectable.

The current compatibility and attach fixes support the same job: keep compatible servers and their agents running, and make a rejected attach show an explicit takeover command for the same terminal ID. A failed connection must not force the operator to guess which session to select again.

Prompt delivery at provider setup screens remains a separate upstream detection limitation. Signalbox already retains instructions when Herdr reports `agent_prompt_stalled`; a reported success is not sufficient evidence for automatic replay. Validate future Herdr fixes with a disposable first-run provider session before changing this behavior.

Event subscriptions should follow these interaction fixes unless polling latency is observed to delay intervention. Their success criterion is timely, complete attention updates across reconnects, with snapshot recovery and polling fallback. Multi-machine aggregation needs a demonstrated cross-machine job and explicit machine targeting before adding another connection layer. A second transcript store has no demonstrated role in this intervention sequence.
