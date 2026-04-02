# Serena + Claude Code + JetBrains setup

Add to each project where you use Serena (project root):

```json
{
  "mcpServers": {
    "serena": {
      "command": "uvx",
      "args": [
        "--from", "git+https://github.com/oraios/serena",
        "serena", "start-mcp-server",
        "--context", "claude-code"
      ]
    }
  }
}
```

The `claude-code` context disables tools that duplicate Claude Code builtins:
`create_text_file`, `read_file`, `execute_shell_command`, `replace_content`, `prepare_for_new_conversation`.

## 3. Disable the Serena plugin

In Claude Code global settings (`~/.claude/settings.json`), keep the plugin disabled:

```json
"serena@claude-plugins-official": false
```

The plugin doesn't pass `--context claude-code`, so the manual `.mcp.json` entry above replaces it.
