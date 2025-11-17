# DiffSnap.nvim

A small, self-contained Neovim plugin for creating temporary, in-session diffs 
of your buffers.

DiffSnap is designed for the specific workflow where you need to see changes 
against an arbitrary point in time, not just the last Git commit. It's perfect 
for refactoring, reviewing clipboard content before pasting, or any situation 
where a temporary "before" and "after" view is needed.

## Features

-   **Manual Snapshots:** Create a snapshot of the current buffer's state at 
any time.
-   **Visual Diffing:** Displays additions, changes, and deletions using signs 
in the signcolumn.
-   **Virtual Text Previews:**
    -   See the original content of a changed line when navigating between 
hunks.
    -   See the full content of deleted blocks displayed as virtual text.
-   **Clipboard Integration:** A one-shot command (`gz`) to snapshot, replace 
the buffer with clipboard content, and show the diff.
-   **Hunk Navigation:** Quickly jump between changes using keymaps.
-   **Zero Configuration:** Works out of the box with sensible defaults.
-   **Theme Integration:** Automatically links its highlight groups to 
`gitsigns.nvim` highlights for a consistent look with your colorscheme.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
 {
    'drgo/diffsnap',
    opts = {},
  }
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
-- lua/plugins.lua
use {
  "drgo/diffsnap.nvim",
  config = function()
    require("diffsnap").setup()
  end,
}
```

## Setup

It does not currently have any configuration options.

```lua
-- placeholder
require("diffsnap").setup()
```

## Usage

DiffSnap provides two primary workflows: the manual snapshot workflow and the 
clipboard replacement workflow.

### Manual Workflow

This is useful for tracking changes as you refactor or edit a file.

1.  **`:DiffSnap`**: Run this command to save a "before" state of the current 
buffer.
2.  **Edit your file**: Make any changes you need.
3.  **`:DiffShow`**: Run this command to display the differences between your 
current buffer and the snapshot. Signs will appear in the gutter.
4.  **`[c` / `]c`**: Use these keys to jump between the changes. A preview of 
the original content will appear as virtual text.
5.  **`:DiffClear`**: When you're done, run this to remove the diff signs.

### Clipboard Workflow (`gz`)

When you want to replace the entire content of a 
file with code from your clipboard and see exactly what changed.

1.  Copy the new code to your system clipboard.
2.  In the buffer you want to replace, press `gz` in normal mode.
3.  The plugin will automatically:
    -   Take a snapshot of the current content.
    -   Delete everything in the buffer.
    -   Paste the content from your clipboard.
    -   (Optional) Format the new content if an LSP formatter is available.
    -   Show the diff signs.

## Commands

| Command        | Description                                                  
            |
------------------------------------------------------------------------ |
| `:DiffSnap`    | Creates a snapshot of the current buffer's content.          
            |
| `:DiffShow`    | Shows diff signs comparing the current buffer to the 
snapshot.           |
| `:DiffClear`   | Clears all diff signs and virtual text from the buffer.      
            |
| `:DiffReplace` | The command behind `gz`. Replaces the buffer with clipboard 
and diffs.   |
| `:DiffRemove`  | Deletes the snapshot for the current buffer.                 
            |

## Keymaps

| Keymap | Mode   | Description                                           |
| ------ | ------ | ----------------------------------------------------- |
| `gz`   | Normal | Snapshot, replace buffer with clipboard, and show diff. |
| `]c`   | Normal | Jump to the next diff hunk.                           |
| `[c`   | Normal | Jump to the previous diff hunk.                       |

## Highlights

This plugin does not define its own colors. Instead, it links to the highlight 
groups used by the popular 
[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) plugin. For the 
signs to show up correctly, your colorscheme must support gitsigns.

| Plugin Highlight         | Links to         | Default Sign |
| ------------------------ | ---------------- | ------------ |
| `DiffSnapAdd`            | `GitSignsAdd`    | `+`          |
| `DiffSnapChange`         | `GitSignsChange` | `~`          |
| `DiffSnapDelete`         | `GitSignsDelete` | `-` / `━`    |
| `DiffSnapDeletedContent` | `DiffDelete`     | (Virtual Text) |

## License

MIT
