# @maxpaulus/pi-nvim

Send a prompt and the current Neovim context to the conversation open in Pi.

- `<leader>ai` opens a prompt input.
- If Pi is running with the included extension, the prompt becomes a real user message in its active conversation.
- If Pi is busy, the message is queued as a follow-up.
- If no Pi instance is available, Neovim opens a split running Pi with the prompt as its first message.
- Modified file buffers are saved before the prompt is sent, so Pi edits the current version.
- Successful Pi `edit` and `write` calls automatically reload matching unmodified buffers.
- Normal mode includes a bounded excerpt around the cursor. Visual mode includes the selected lines.

## Requirements

- Neovim 0.10 or newer
- Pi 0.84 or newer
- macOS or Linux (the transport uses a Unix domain socket)

## Install

Install the Neovim plugin with your plugin manager. For `lazy.nvim`:

```lua
{
  "maxpaulus43/pi-nvim",
  config = function()
    require("pi-nvim").setup()
  end,
}
```

The plugin also applies its defaults automatically, so the `config` block is only needed for custom options.

Install the Pi package globally:

```sh
pi install npm:@maxpaulus/pi-nvim
```

Restart any running Pi instances after installation. `pi list` should show the package.

## Configuration

```lua
require("pi-nvim").setup({
  mapping = "<leader>ai",
  context_lines = 20,
  split = "botright split",
  pi_command = { "pi" },
  socket_timeout_ms = 1500,
})
```

The mapping works in normal and visual mode. Context contains the working directory, absolute buffer path, filetype, cursor, modified state, and numbered source lines. A modified file buffer is written before context is captured. If it cannot be written, the prompt is not sent.

The Pi extension reports successful `edit` and `write` calls back to Neovim over a local Unix socket. Neovim reloads a matching buffer only when it has no newer unsaved changes; otherwise it preserves the buffer and shows a warning.

## Multiple Pi instances

When multiple Pi instances are available, Neovim shows an instance picker. Instances whose working directory exactly matches Neovim's current working directory appear first, followed by the most recently opened sessions. The preferred instance is initially highlighted. Unreachable instances are skipped during delivery.

## Security

The extension creates its runtime directory with mode `0700` and its socket and metadata with mode `0600`. The extension accepts only a versioned JSON message containing the prompt and limits requests to 256 KiB. Like all Pi extensions, it runs with the user's permissions; review it before installation.

## Development

For local testing, install the repository as both a Neovim plugin and a Pi package:

```lua
{ dir = "/path/to/pi-nvim" }
```

```sh
pi install /path/to/pi-nvim
```

For a one-off Pi test without installing the extension:

```sh
pi -e ./pi-extension/index.ts
```

Run the Lua tests:

```sh
nvim --headless -u tests/minimal_init.lua -l tests/test.lua
```

Check that Pi can load the extension without starting a conversation:

```sh
PI_OFFLINE=1 pi -e ./pi-extension/index.ts --list-models
```
