# Signalbox design notes

## Job model

The core functional job is:

> When several delegated coding tasks are running while I edit, help me identify the next human intervention, inspect enough context to decide, act, and return to editing without terminal-pane touring.

The emotional job is to feel in control without watching every agent. The social job is to make concurrent delegation legible and reviewable rather than magical.

The closest conceptual model is a railway signal box. A signal box observes shared traffic, makes exceptions conspicuous, and lets an operator route or halt movement. It does not become the locomotive. In the same way, Signalbox must not recreate Herdr's process supervisor or the coding agents' interfaces.

## Progress forces

- Push: terminal pane touring, lost session context, and unclear completion state.
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

Signalbox stores no transcript and no duplicate session database. `terminal_id` is its stable in-memory key; actions use the latest `pane_id`, because that is the current Herdr command target.

## Interaction sequence

1. Bootstrap from `herdr api snapshot`.
2. Show current-project agents plus blocked/done work elsewhere.
3. Sort agent rows by blocked, done, working, idle, unknown.
4. Read only the selected agent's recent unwrapped terminal output.
5. Let the operator attach, prompt, start, inspect Git, or open a diff.
6. Preserve Herdr state when the board or Neovim closes.

## Milestones

- v0.1: compatible Herdr 0.7.5 lifecycle, focused float, preview, context, native attach, Lazygit/Diffview actions.
- v0.2: raw Unix-socket event subscription with reconnect, snapshot re-bootstrap, and polling fallback.
- Later: opt-in structured review adapters; no automatic all-agent context broadcast.
