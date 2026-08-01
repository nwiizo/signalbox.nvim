# signalbox.nvim

`signalbox.nvim` is an attention-first Neovim control surface for persistent coding agents managed by [Herdr](https://herdr.dev/).

It is named after a railway signal box: it does not drive the trains or replace their engines. It gives one operator a compact view of traffic, highlights the routes that need intervention, and provides safe controls at the junctions.

> [!NOTE]
> This is an unofficial community integration. It is not maintained or endorsed by the Herdr project.

## The job

> When I delegate work to several coding agents while editing, help me notice only the work that needs human attention, inspect it without touring terminal panes, intervene, and return after Neovim restarts.

That job shapes the product:

- Herdr owns PTYs, processes, semantic state, and persistence.
- Signalbox owns the Neovim view, transient cache, and editor actions.
- `blocked` and `done` come before terminal topology.
- Recent terminal output is previewed but never persisted by this plugin.
- Attach, prompt, start, and repository actions remain explicit user actions.

## Features

- 90% floating attention board, sized like a full-screen Lazygit workflow
- Current project agents plus `blocked`/`done` agents elsewhere by default
- Ephemeral recent-output preview for the selected agent
- Notifications when an agent becomes blocked or completes work
- Herdr 0.7.5 workspace/tab creation and persistent Codex/Claude launches
- Direct attach in a native right-hand Neovim terminal
- Prompt, file, visual selection, range, and LSP diagnostic context
- Optional `Snacks.lazygit` and Diffview actions from the selected agent's cwd
- Compact attention-only status component and `:checkhealth signalbox`
- Pure Lua with no required Neovim plugin dependency

## Requirements

- Neovim 0.10+
- Herdr 0.7.5+
- macOS or Linux
- Codex CLI and/or Claude Code

Install Herdr's richer agent integrations once:

```sh
herdr integration install codex
herdr integration install claude
```

## Installation

With lazy.nvim or LazyVim:

```lua
{
  "nwiizo/signalbox.nvim",
  cmd = {
    "Signalbox",
    "SignalboxRefresh",
    "SignalboxStart",
    "SignalboxAttach",
    "SignalboxPrompt",
    "SignalboxSendVisual",
    "SignalboxSendFile",
    "SignalboxSendDiagnostics",
    "SignalboxHealth",
  },
  keys = {
    { "<leader>as", "<cmd>Signalbox<cr>", desc = "Agent Signalbox" },
  },
  opts = {},
}
```

`<leader>as` is only a recommendation. Signalbox defines no global mappings itself.

## Workflow

Open the board with `:Signalbox`.

```text
╭──────── Signalbox  !1  ✓1 ────────╮ ╭──────── reviewer · recent output ────────╮
│ this project + attention elsewhere │ │ ...                                      │
│                                    │ │ The agent is waiting for approval to     │
│ signalbox.nvim                     │ │ update the public API.                   │
│ ! reviewer       claude  blocked   │ │                                          │
│ * implementation codex   working   │ │                                          │
│ ✓ tests          codex   done      │ │                                          │
╰────────────────────────────────────╯ ╰──────────────────────────────────────────╯
```

Board mappings are buffer-local:

| Key | Action |
| --- | --- |
| `<CR>` | Attach to the selected agent |
| `p` / `s` | Prompt the selected agent |
| `a` | Start Codex or Claude Code at the captured project root |
| `g` | Open Snacks Lazygit at the selected agent's repository |
| `d` | Open Diffview at the selected agent's repository |
| `v` | Toggle recent-output preview |
| `A` | Toggle default attention view / all agents |
| `r` | Refresh immediately |
| `q` | Close |
| `?` | Toggle help |

The default view keeps agents from the current Git/Jujutsu root and also surfaces blocked or completed work elsewhere. `A` reveals the whole Herdr session.

## Commands

| Command | Description |
| --- | --- |
| `:Signalbox` | Toggle the attention board |
| `:SignalboxRefresh` | Refresh Herdr state immediately |
| `:SignalboxStart [codex\|claude]` | Start a named persistent agent at the project root |
| `:SignalboxAttach[!] [target]` | Attach; `!` explicitly takes over another direct client |
| `:SignalboxPrompt [target]` | Prompt an agent |
| `:[range]SignalboxPrompt [target]` | Prompt with complete lines from a range |
| `:'<,'>SignalboxSendVisual [target]` | Prompt with the exact visual selection |
| `:SignalboxSendFile [target]` | Send the saved current-file reference |
| `:SignalboxSendDiagnostics [target]` | Send current-buffer LSP diagnostics |
| `:SignalboxHealth` | Run `:checkhealth signalbox` |

Targets accept stable terminal IDs, current pane IDs, or an unambiguous agent name.

## Ambient status

`statusline()` returns only states that need attention:

```lua
require("signalbox").statusline()
-- "SB !1 ✓1" or "" when there is nothing to handle
```

It can be used from Incline, lualine, or another renderer after Signalbox is loaded. `~` marks last-known data after a refresh failure.

## Configuration

```lua
require("signalbox").setup({
  herdr_cmd = "herdr",
  auto_start_server = true,
  agent_start_timeout_ms = 30000,

  agents = {
    codex = { args = {} },
    claude = { args = {} },
  },

  refresh = {
    board_ms = 1000,
    background_ms = 5000,
    timeout_ms = 3000,
  },

  board = {
    width = 0.9,
    height = 0.9,
    preview = true,
    preview_ratio = 0.58,
    preview_lines = 80,
  },

  terminal = {
    side = "right",
    width = 0.4,
    auto_insert = true,
  },
})
```

Agent `args` are appended after Herdr's canonical agent command without using a shell:

```lua
agents = {
  codex = { args = { "--profile", "work" } },
}
```

## Safety and current limits

- External commands use argv arrays; editor content is never interpolated into a shell command.
- Context larger than the configured line or byte limit is rejected.
- File references reject unnamed and modified buffers.
- Closing Neovim stops only local attach clients, never Herdr agents or its server.
- Signalbox currently refreshes snapshots on a short adaptive poll. Herdr socket events are the next transport milestone.
- Agent-to-Neovim MCP tools and native diff review are deliberately out of scope for v0.1.
- Windows is not supported in v0.1.

## Herdr upgrade monitoring

The repository checks the canonical `herdrdev/herdr` latest stable release daily. If it differs from the currently verified Herdr version, GitHub Actions opens a deduplicated compatibility-audit issue with CLI, schema, and real-agent smoke-test checkpoints. See [the upstream audit runbook](docs/upstream-herdr.md).

See [the design notes](docs/design.md) for the job model and ownership boundary.

## Development

```sh
make check
```

Tests run in a clean headless Neovim and do not require a test framework plugin.

## License

Friend License (MIT-equivalent).
