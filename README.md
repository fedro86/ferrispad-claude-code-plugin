# Claude Code Plugin for FerrisPad

AI assistant powered by the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, embedded directly in FerrisPad.

## Features

- **Embedded terminal** -- Opens Claude Code in an interactive terminal panel (`Ctrl+Shift+I`)
- **MCP integration** -- Registers FerrisPad as an [MCP server](https://modelcontextprotocol.io/) so Claude Code can query editor state (open file, cursor position, project root, etc.)
- **Auto-approve MCP tools** -- Configures `.claude/settings.local.json` so Claude Code skips permission prompts for FerrisPad tools (configurable)
- **Editor context hook** -- Attaches the current selection/file context to every Claude Code prompt via a `UserPromptSubmit` hook
- **Multi-project support** -- Tracks project roots across tab switches; sets up MCP config per project
- **Automatic cleanup** -- Removes `.mcp.json` on shutdown

## Requirements

- [FerrisPad](https://github.com/fedro86/ferrispad) v0.9.2+
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and on PATH
- Anthropic Pro/Max plan or API key (for Claude authentication)

## Installation

### From FerrisPad Plugin Manager

1. Open FerrisPad
2. Go to **Plugins > Manage Plugins**
3. Switch to the **Community** tab
4. Find **Claude Code** and click **Install**

### Manual

```bash
# Clone the plugin
git clone https://github.com/fedro86/ferrispad-claude-code-plugin.git

# Copy to the FerrisPad plugins directory
cp -r ferrispad-claude-code-plugin/ ~/.config/ferrispad/plugins/claude-code
```

## Configuration

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `auto_approve_mcp` | boolean | `true` | Auto-approve FerrisPad MCP tools in Claude Code (skips permission prompts) |

Configure via **Plugins > Claude Code > Settings** in FerrisPad.

## How It Works

1. **On startup / file open**, the plugin detects the project root and:
   - Writes `.mcp.json` so Claude Code discovers FerrisPad as an MCP server
   - Adds `.mcp.json` to `.gitignore`
   - Configures tool permissions in `.claude/settings.local.json` (if auto-approve is on)
   - Sets up a `UserPromptSubmit` hook for editor context

2. **On menu action** (`Ctrl+Shift+I`), opens an embedded terminal running `claude` in interactive mode.

3. **On shutdown**, cleans up `.mcp.json` from all handled project roots.

## License

MIT
