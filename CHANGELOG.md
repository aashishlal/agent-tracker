# Changelog 📜

All notable changes to the Agent Tracker project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.3.0] - 2026-06-29

### Added
- **Reset Time Display**: Now shows when limits will reset for both Antigravity and Claude Code.
- **Antigravity Cache Reader**: Reads from local cache file for instant, reliable usage data.
- **ASCII Bar Charts**: Visual bar charts using `█` and `░` characters on the right side of values.

### Changed
- **Simplified Layout**: Removed Command Code (can't get usage data), shows only working tools.
- **Simplified Antigravity Display**: Shows only "5-Hour Limit" and "Weekly Limit" with reset times.

### Fixed
- **Crash Fix**: Fixed negative count error in ASCII chart generation.
- **Antigravity Data Fetching**: Resolved timeout issue by reading from local cache file.
- **Reset Time Extraction**: Added regex to extract reset times from Claude Code output.

### Removed
- **Command Code**: Removed from display since CLI doesn't provide usage metrics in non-interactive mode.
- **Debug Menu Items**: Removed to simplify the interface.

## [1.2.0] - 2026-06-29

### Added
- **Dynamic Hover Icons**: Menu bar icon shows a closed eye (`Closed.png`) by default, changing to an open eye (`Open.png`) on hover (supports standard, @2x, and @3x scales).
- **GUI Config Editor**: Added menu items to "Add Custom CLI Tool" and "Remove Custom CLI Tool" using native Cocoa dialog text fields and confirmation alerts, eliminating the need to edit raw JSON configuration.
- **Claude Cost Parser**: Direct parser that reads `~/.claude.json` to calculate aggregate dollar cost across workspaces.
- **Codex SQLite Parser**: Auto-queries Codex database `~/.codex/logs_2.sqlite` to display logs count and storage metrics.
- **Terminal Login Integrations**: Dropdown items to run authentication loops (`claude auth`, `cmd login`, `antigravity-usage login`) in a native Terminal window using AppleScript.
- **Packaging Utility (`package.sh`)**: Added standard packager that assembles the `.app` bundle and packages it into a read-only `.dmg` installer using `hdiutil`.

### Changed
- **Menu Bar Styling**: Removed all text labels from the menu bar to save status bar space, showing only the template eye icon.
- **Application Directory Compliance**: Replaced standard build paths to install and launch from `/Applications/` to completely bypass macOS Documents folder permission prompts.

---

## [1.1.0] - 2026-06-29

### Added
- **Native Status App**: Built Cocoa interface (`NSStatusItem` / `NSMenu`) compiling Swift source using `swiftc` without Xcode overhead.
- **Background Dispatch Queue**: Integrated asynchronous polling using `DispatchQueue.global(qos: .userInitiated)` to avoid blocking the main UI thread during CLI calls.
- **Multi-CLI Tooltip Details**: Generates a tooltip listing limits for Claude Code, Antigravity, and Command Code on mouse hover.
- **Default JSON Configuration**: Set up user schema config (`~/.agent-tracker.json`) to define CLI commands and regex parsers.
- **Threshold Warnings**: Added native macOS notification alerts when Claude Code weekly usage exceeds 90%.

---

## [1.0.0] - 2026-06-29

### Added
- **Initial Concept**: Investigated CLI usage loops (e.g. `claude -p "/usage"`, `antigravity-usage --json`, `cmd status`) and designed local parsers.
- **Token Sync Script**: Added a python sync helper to clone Google OAuth credentials.
