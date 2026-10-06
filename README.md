# herdr-nvim

A Neovim plugin by [LTRF Labs](https://github.com/LTRF-Labs). Send prompts, files, and selections to an agent in your current Herdr workspace.

## Requirements

- Neovim 0.11 or later, running inside Herdr.
- The `herdr` CLI in `PATH`.
- Pi installed if you want the plugin to start an agent when none is ready.

Setup fails outside Herdr. The plugin uses the Herdr CLI only. No agent extension or Node.js dependencies are required.

## Install

Add `LTRF-Labs/herdr-nvim` to your lazy.nvim configuration:

```lua
{
  "LTRF-Labs/herdr-nvim",
  config = function()
    require("herdr-nvim").setup()
  end,
}
```

Options:

```lua
require("herdr-nvim").setup({
  set_default_keymaps = true,
  input = {}, -- passed to vim.ui.input
})
```

## Usage

Press `<leader>p` in Normal or Visual mode to open the input UI.

| Command | Action |
| --- | --- |
| `:Herdr` | Send a prompt with file or selection context |
| `:HerdrSend` | Send a plain prompt |
| `:HerdrSendFile` | Send the current file path and a prompt |
| `:HerdrSendSelection` | Send selected text and a prompt |
| `:HerdrSendBuffer` | Send the complete in-memory buffer and a prompt |

The input UI uses `vim.ui.input`. Providers such as `snacks.input` work without extra configuration.

- File paths are absolute.
- Selections include selected text and the line and column range.
- Cancel to restore an active visual selection.
- Submit to leave Visual mode and send the prompt.
- Unmodified buffers reload when an agent changes files on disk. The plugin enables `autoread` only if you have not set it.

Set `set_default_keymaps = false` to use your own mappings.

## Agent selection

For each prompt, the plugin reads the live Neovim pane and finds the first agent in that workspace with status `idle` or `done`. It supports all agent kinds recognized by Herdr. It skips the caller pane and agents with status `working`, `blocked`, or `unknown`.

If no agent is ready, the plugin creates a tab in the same workspace and starts Pi in Neovim's current directory. Editor focus does not change. Herdr waits for Pi to be ready before it sends the prompt.

CLI calls run asynchronously. Prompt text is passed as one argument, never as a shell command. Prompts are sent in order. Each prompt selects a ready agent again, so another Pi tab can be created if all agents are busy.

The plugin does not wait for an answer, use another workspace, or retry a failed prompt. Errors appear in Neovim. If startup fails, the new tab stays open for inspection.

## Tests

Run from the repo directory:

```sh
nvim --headless -u NONE -l tests/run.lua
```

Tests use simulated CLI responses. They do not start agents or change the live Herdr layout.

## License

MIT. See `LICENSE`.
