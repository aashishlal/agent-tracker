# Product Requirement Document (PRD) - Agent Tracker 📊

## 1. Product Overview & Vision
Agent Tracker is a lightweight, native macOS menu bar utility designed for AI developers and power users of agentic coding assistants. Its goal is to provide **real-time, zero-friction visibility** into daily and weekly limits, token counts, and cost metrics for multiple local AI CLIs (such as Claude Code, Antigravity, Command Code, and Codex) without requiring account creation, cloud sync, or external credentials.

The core principles of the product are:
- **100% Local Privacy**: No server sign-ups, no telemetry to third-party endpoints.
- **Accessory UI**: Lives entirely in the macOS menu bar, hiding from the Dock and keeping workspace clutter to a minimum.
- **Asynchronous Non-Blocking Execution**: System commands are executed in background queues to prevent UI freezes.
- **Full Extensibility**: The user can configure the app to scrape limits from *any* CLI using custom commands and regular expressions.

---

## 2. Key Features & Specification

### 2.1. Dynamic Status Indicator (Menu Bar Icon)
- **Status Bar Representation**: The app occupies a single slot in the macOS menu bar showing a custom eye icon (`👁️`). No text is shown by default to maintain menu bar space.
- **Interactive States**:
  * **Default State**: Closed eye icon (`Closed.png`).
  * **Hover State**: As the user hovers over the icon, the eye opens (`Open.png`) and displays a detailed tooltip summary of all tracked metrics.
  * **Click State**: Displays a detailed dropdown menu listing each CLI tool, individual metrics, and control items.
- **Template Rendering**: Icons are configured as Template Images, allowing macOS to automatically tint them (Black in Light Mode, White in Dark Mode, White when highlighted).

### 2.2. Multi-CLI Metrics & Local Parsers
The application dynamically scrapes and aggregates metrics:
- **Claude Code**:
  * Weekly Limit & Session Limit: Scraped non-interactively via `/Users/YOUR_USER/.local/bin/claude -p '/usage' < /dev/null`.
  * Historical Cost: Parsed directly from `~/.claude.json` to calculate the cumulative USD cost of all workspaces.
- **Antigravity**:
  * Quota & Model Status: Scraped via `antigravity-usage --json` (interfacing with local language server or fallback token manager).
- **Command Code**:
  * Auth / Connection: Scraped via `cmd status`.
- **Codex**:
  * Usage Statistics: Runs local database queries directly on `~/.codex/logs_2.sqlite` to display the total logs count and size in kilobytes.

### 2.3. Native GUI Configuration Editor
Users do not need to manually edit JSON files. Configuration management is built directly into the status menu:
- **Add Custom CLI Tool**:
  * Opens a native modal requesting: Tool Name, Command, Metric Label, and Regex Pattern.
  * Appends the new CLI tool structure to `~/.agent-tracker.json` and triggers a refresh.
- **Remove Custom CLI Tool**:
  * An expandable sub-menu lists all configured tools. Clicking one prompts a confirmation dialog and deletes it.

### 2.4. Desktop Threshold Warnings
- The app checks metrics after each polling cycle.
- If Claude Code weekly usage reaches or exceeds **90%**, it triggers a native macOS desktop notification banner to warn the user.

### 2.5. Terminal Login Helpers
- Spawns a native AppleScript targeting the macOS Terminal app to run authentication sequences (e.g. `claude auth`, `cmd login`) in a new terminal window without manual copying.

---

## 3. Technical Architecture & File Layout
The app is constructed with a zero-dependency compiled model:
- **`AgentTracker.swift`**: The main entry point. Sets up `NSApplicationDelegate`, creates the `NSStatusItem`, hooks up mouse hover tracking via `NSTrackingArea`, spawns processes, and parses regular expressions.
- **`Info.plist`**: Customizes the app bundle metadata, including `LSUIElement = true` (Accessory mode).
- **`Icons/`**: Holds custom png assets (`Closed.png`, `Open.png` with standard, @2x, and @3x Retina scales) copied directly to the compiled bundle resources.
- **`build.sh`**: Compiles the binary using `swiftc`, maps assets to the bundle path, and sets up templates.
- **`package.sh`**: Assembles the `.app` bundle and packages it into a read-only `.dmg` installer using `hdiutil`.
- **`~/.agent-tracker.json`**: The local configuration schema stored in the user's home folder.

---

## 4. Security & Permissions compliance
To deliver a secure experience, the app respects the following security boundaries:
- **No Documents Folder Restraints**: To prevent macOS Gatekeeper from displaying "Folder Access" warnings, the app must be installed and run from the standard `/Applications` directory.
- **Zero Privacy Indicators**: The app does not request or contain API hooks for Photos, Location, Camera, or Contacts.
- **Local Sandbox Compatibility**: Reads and writes configuration data within `~/.agent-tracker.json` which is allowed by macOS sandboxing defaults.
