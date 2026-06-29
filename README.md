# Agent Tracker 📊

A native macOS menu bar application to track daily and weekly usage limits for your AI coding assistants (Claude Code, Antigravity, Command Code, and more) 100% locally.

No accounts. No sign-up. Completely private.

![Agent Tracker Menu Bar Example](https://raw.githubusercontent.com/skainguyen1412/antigravity-usage/main/images/icon.png)

## Features
- **Menu Bar Indicator**: Shows your active Claude Code usage right in the status bar (e.g. `📊 Claude: 91% used`).
- **Accessory App**: Runs quietly in the background without cluttering your Dock.
- **Asynchronous Execution**: Checks limits in background threads without blocking your macOS interface.
- **Auto-Refresh**: Polls the limits automatically every 10 minutes.
- **Fully Extensible**: Add any command-line tool or script by configuring it in a simple JSON file.

---

## Getting Started

### 1. Requirements
- macOS 10.13 or newer.
- Swift compiler (pre-installed with Xcode Command Line Tools).

### 2. Installation & Build
Clone the repository and build the `.app` bundle:

```bash
git clone https://github.com/aashishlal/agent-tracker.git
cd agent-tracker
./build.sh
```

This compiles the Swift source and creates `AgentTracker.app`.

### 3. Run
You can launch the app directly:
```bash
open AgentTracker.app
```

Or copy it to your Applications directory for easy access via Spotlight:
```bash
cp -R AgentTracker.app /Applications/
open /Applications/AgentTracker.app
```

---

## Configuration

The application is configured using a local file at `~/.agent-tracker.json`.

If the file does not exist, a default template will be created for you on first build, preset with hooks for:
- **Claude Code** (`claude -p "/usage"`)
- **Antigravity** (`antigravity-usage --json`)
- **Command Code** (`cmd status`)

### Customizing Tools
To add a new tool or edit how the values are extracted, click **Edit Configuration** in the status bar menu. It will open `~/.agent-tracker.json` in your default editor.

For each tool, specify:
1. `name`: Display name in the dropdown menu.
2. `command`: The terminal command to execute to get status.
3. `metrics`: A list of values to pull, each with a `label` and a `regex` expression to extract the matched group from the command's stdout.

Example configuration for Claude Code:
```json
{
  "name": "Claude Code",
  "command": "/Users/YOUR_USER/.local/bin/claude -p '/usage' < /dev/null",
  "metrics": [
    {
      "label": "Weekly Usage",
      "regex": "Current week \\(all models\\): ([^·\\n]+)"
    }
  ]
}
```

*Note: Always use absolute paths for CLI binaries (e.g. `/Users/YOUR_USER/.local/bin/claude` or `/opt/homebrew/bin/cmd`) because background menu bar apps may not inherit your terminal's full shell PATH.*

---

## Development & Modification
The main code is structured in a single Swift file for simplicity:
- `AgentTracker.swift`: Cocoa `NSApplication` setup, background process spawning, regular expression extraction, and TUI menu updates.
- `Info.plist`: Tells macOS not to show the app in the Dock (`LSUIElement: true`).

To modify and recompile the app, edit `AgentTracker.swift` and rerun `./build.sh`.

---

## License
MIT License.
