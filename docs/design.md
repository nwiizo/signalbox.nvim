# Signalbox design notes

## Job model

The core functional job is:

> When several delegated coding tasks are running while I edit, help me identify the next human intervention, inspect enough context to decide, act, and return to editing without terminal-pane touring.

The emotional job is to feel in control without watching every agent. The social job is to make concurrent delegation legible and reviewable rather than magical.

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
6. Preserve Herdr state when the board or Neovim closes.

## Milestones

- v0.1: Herdr 0.7.5+ lifecycle (verified through 0.9.0), focused float, preview, context, native attach, Lazygit/Diffview actions.
- v0.2: raw Unix-socket event subscription with reconnect, snapshot re-bootstrap, and polling fallback.
- Later: opt-in structured review adapters; no automatic all-agent context broadcast.

## Job-driven priorities

These are implementation candidates from the current code and the Herdr 0.9.0 validation, not measured user demand or shipped features. Rank them by whether they help the operator notice, decide, act, and return to editing.

| Priority | Situation and current behavior | Proposed outcome | Verification |
| --- | --- | --- | --- |
| 1 | An agent moves while the instruction input is open. `rename` refreshes and resolves the stable terminal ID before acting; `prompt_agent` still sends to the target captured before input. | Resolve the latest target for the same terminal immediately before sending prompts and editor context. If that agent disappeared or was replaced, retain the instruction for explicit recovery and send nothing. | Move or replace a disposable agent while input is open; confirm that only the original live agent can receive the instruction. |
| 2 | An agent in a later Space needs approval. Rows are ranked inside each workspace, but workspace groups retain Herdr order, so working agents in an earlier group can appear first. | Rank groups by their most urgent visible agent while preserving order for ties and preserving the selected terminal across updates. | Put a working agent in the first Space and a blocked agent in the last; verify the blocked group appears first without moving selection to another agent. |
| 3 | The operator has reviewed completed work and wants to find the next intervention. `done` stays in attention counts until Herdr changes its state. | Add an explicit, in-memory acknowledgement for that completion. Keep the agent accessible in the all-agents view and let a later completion surface again. Do not infer acknowledgement from opening a preview. | Acknowledge one completion, observe a working-to-done cycle, and confirm the new completion returns. Document that acknowledgement resets after Neovim restarts. |

The current compatibility and attach fixes support the same job: keep compatible servers and their agents running, and make a rejected attach show an explicit takeover command for the same terminal ID. A failed connection must not force the operator to guess which session to select again.

Prompt delivery at provider setup screens remains a separate upstream detection limitation. Signalbox already retains instructions when Herdr reports `agent_prompt_stalled`; a reported success is not sufficient evidence for automatic replay. Validate future Herdr fixes with a disposable first-run provider session before changing this behavior.

Event subscriptions should follow these interaction fixes unless polling latency is observed to delay intervention. Their success criterion is timely, complete attention updates across reconnects, with snapshot recovery and polling fallback. Multi-machine aggregation needs a demonstrated cross-machine job and explicit machine targeting before adding another connection layer. Neither transport expansion nor a second transcript store resolves the three operator tasks above.
