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

- v0.1: Herdr 0.7.5+ lifecycle (verified through 0.8.0), focused float, preview, context, native attach, Lazygit/Diffview actions.
- v0.2: raw Unix-socket event subscription with reconnect, snapshot re-bootstrap, and polling fallback.
- Later: opt-in structured review adapters; no automatic all-agent context broadcast.
