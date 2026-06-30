# Agent Tracker

A macOS menu bar app that tracks usage and limits across your AI coding tools — locally, no accounts needed.

Each metric shows a colour-coded progress bar that turns orange (≥85% consumed) or red (≥95%). Refreshes every 10 minutes.

## Supported tools

| Tool | Data source | Metrics |
|------|-------------|---------|
| **Claude Code** | `claude -p '/usage'` | Weekly % used, Session % used |
| **Antigravity** | Local cache file | 5-Hour & Weekly limits + reset times |
| **Codex** | `~/.codex/logs_2.sqlite` | Log count & storage |
| **Command Code** | Local JSONL session files | Session & message count |
| **Kimi** | PTY `/usage` capture | Weekly & 5-Hour limits + reset times |

## Requirements

- macOS 10.13+
- Xcode Command Line Tools: `xcode-select --install`
- The CLI tools you want to track, already installed and authenticated

## Install

```bash
git clone https://github.com/yourusername/agent-tracker
cd agent-tracker
bash build.sh
open AgentTracker.app
```

To launch at login: **System Settings → General → Login Items → +** and add `AgentTracker.app`.

## Add your own tools

Click the menu bar icon → **Add Tool…** to pick a built-in preset or enter a custom command.

Config lives at `~/.agent-tracker.json`. Edit it directly and hit **Refresh Now** (⌘R) to reload:

```json
{
  "tools": [
    {
      "name": "My Tool",
      "command": "/usr/local/bin/mytool --status",
      "metrics": [
        { "label": "Weekly", "regex": "weekly usage: (\\d+%)" }
      ]
    }
  ]
}
```

> **Tip:** Use absolute paths for binaries — menu bar apps don't inherit your shell's `$PATH`.

## Build

```bash
bash build.sh      # compiles AgentTracker.swift → AgentTracker.app
bash package.sh    # wraps it in a .dmg (optional)
```

Single Swift source file, no Xcode project required.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| Refresh Now | ⌘R |
| Open Config JSON | ⌘E |
| Check for Updates | ⌘U |
| Quit | ⌘Q |

## Privacy

Runs 100% locally. No network calls, no telemetry, no credentials stored. It reads output from your local CLI tools and local cache files only.

## License

MIT
