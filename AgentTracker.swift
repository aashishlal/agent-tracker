import Cocoa
import Foundation

// MARK: - Models

struct Metric: Decodable {
    let label: String
    let regex: String
}

struct Tool: Decodable {
    let name: String
    let command: String
    let metrics: [Metric]
}

struct Config: Decodable {
    let tools: [Tool]
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu = NSMenu()
    var config: Config?
    var toolResults: [String: [String: String]] = [:]
    var isRefreshing = false
    var hasAlertedClaude = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use SF Symbols "eye" icon (supported in macOS 11.0+)
            if #available(macOS 11.0, *) {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                if let image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Agent Tracker") {
                    button.image = image.withSymbolConfiguration(config)
                    button.imagePosition = .imageOnly
                } else {
                    button.title = "👁️"
                }
            } else {
                button.title = "👁️"
            }
            button.toolTip = "Agent Tracker - Loading..."
        }
        
        // Load initial config
        loadConfig()
        
        // Initial refresh
        refreshData()
        
        // Setup timer to refresh every 10 minutes (600 seconds)
        Timer.scheduledTimer(withTimeInterval: 600.0, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }
    
    func loadConfig() {
        let configPath = NSString(string: "~/.agent-tracker.json").expandingTildeInPath
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            print("Failed to load config: \(error)")
            // Create a dummy config if failed to load
            config = Config(tools: [])
        }
    }
    
    func refreshData() {
        guard !isRefreshing else { return }
        isRefreshing = true
        
        // Reload config in case user edited it
        loadConfig()
        
        guard let config = config else {
            self.isRefreshing = false
            self.updateMenu()
            return
        }
        
        let group = DispatchGroup()
        var newResults: [String: [String: String]] = [:]
        let lock = NSLock()
        
        // Process configured tools
        for tool in config.tools {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let output = self.runShell(tool.command)
                var metricsResults: [String: String] = [:]
                
                for metric in tool.metrics {
                    if let value = self.extractValue(from: output, regexPattern: metric.regex) {
                        metricsResults[metric.label] = value
                    } else {
                        metricsResults[metric.label] = "N/A"
                    }
                }
                
                lock.lock()
                newResults[tool.name] = metricsResults
                lock.unlock()
                
                group.leave()
            }
        }
        
        // Fetch Claude Cost directly from JSON file (custom feature)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let cost = self.getClaudeCost()
            lock.lock()
            if newResults["Claude Code"] == nil {
                newResults["Claude Code"] = [:]
            }
            newResults["Claude Code"]?["Historical Cost"] = cost
            lock.unlock()
            group.leave()
        }
        
        // Fetch Codex Logs directly from SQLite database (custom feature)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let dbPath = NSString(string: "~/.codex/logs_2.sqlite").expandingTildeInPath
            var stats = "N/A"
            if FileManager.default.fileExists(atPath: dbPath) {
                let output = self.runShell("sqlite3 \(dbPath) \"SELECT count(*), sum(estimated_bytes) FROM logs;\" 2>/dev/null")
                let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
                if parts.count == 2, let count = Int(parts[0]), let bytes = Int(parts[1]) {
                    let kb = bytes / 1024
                    stats = "\(count) logs (\(kb) KB)"
                }
            }
            lock.lock()
            if newResults["Codex"] == nil {
                newResults["Codex"] = [:]
            }
            newResults["Codex"]?["Local Activity"] = stats
            lock.unlock()
            group.leave()
        }
        
        group.notify(queue: DispatchQueue.main) { [weak self] in
            guard let self = self else { return }
            self.toolResults = newResults
            self.isRefreshing = false
            self.checkAlerts()
            self.updateMenu()
            self.updateToolTip()
        }
    }
    
    func runShell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        
        // Timeout handling
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 15.0) // 15 seconds timeout
        timer.setEventHandler {
            if task.isRunning {
                task.terminate()
            }
        }
        timer.resume()
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            timer.cancel()
            return "Error: \(error.localizedDescription)"
        }
        
        timer.cancel()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    func extractValue(from text: String, regexPattern: String) -> String? {
        do {
            let regex = try NSRegularExpression(pattern: regexPattern, options: [])
            let nsString = text as NSString
            let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            
            if let match = results.first {
                if match.numberOfRanges > 1 {
                    let range = match.range(at: 1)
                    return nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let range = match.range(at: 0)
                    return nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            print("Regex error: \(error)")
        }
        return nil
    }
    
    func getClaudeCost() -> String {
        let path = NSString(string: "~/.claude.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "N/A"
        }
        
        struct ClaudeJson: Decodable {
            struct Project: Decodable {
                let lastCost: Double?
            }
            let projects: [String: Project]?
        }
        
        do {
            let decoded = try JSONDecoder().decode(ClaudeJson.self, from: data)
            if let projects = decoded.projects {
                let totalCost = projects.values.compactMap { $0.lastCost }.reduce(0.0, +)
                return String(format: "$%.2f", totalCost)
            }
        } catch {
            print("Error decoding Claude JSON: \(error)")
        }
        return "N/A"
    }
    
    func checkAlerts() {
        if let claudeMetrics = toolResults["Claude Code"], let weekly = claudeMetrics["Weekly Usage"] {
            // Check if usage exceeds 90% (extract digits)
            let digits = weekly.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let pct = Int(digits), pct >= 90 {
                if !hasAlertedClaude {
                    sendNotification(title: "Claude Limit Warning", text: "Claude Code weekly usage has reached \(weekly)!")
                    hasAlertedClaude = true
                }
            } else {
                hasAlertedClaude = false
            }
        }
    }
    
    func sendNotification(title: String, text: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = text
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func updateToolTip() {
        var tooltipParts: [String] = ["Agent Tracker - Hover Details"]
        
        let sortedKeys = toolResults.keys.sorted()
        for key in sortedKeys {
            if let metrics = toolResults[key] {
                tooltipParts.append("\n\(key):")
                for (label, value) in metrics {
                    tooltipParts.append("  • \(label): \(value)")
                }
            }
        }
        
        statusItem?.button?.toolTip = tooltipParts.joined(separator: "\n")
    }
    
    func updateMenu() {
        menu.removeAllItems()
        
        // 1. Summary details of each tool
        if let config = config {
            var totalToolsAdded = 0
            let sortedTools = config.tools.sorted(by: { $0.name < $1.name })
            
            for tool in sortedTools {
                let toolItem = NSMenuItem(title: tool.name, action: nil, keyEquivalent: "")
                let font = NSFont.boldSystemFont(ofSize: 13)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                toolItem.attributedTitle = NSAttributedString(string: tool.name, attributes: attributes)
                menu.addItem(toolItem)
                
                if let metrics = toolResults[tool.name] {
                    // Sort metric labels to keep them consistent
                    let sortedMetrics = metrics.sorted(by: { $0.key < $1.key })
                    for (label, value) in sortedMetrics {
                        let metricItem = NSMenuItem(title: "  \(label): \(value)", action: nil, keyEquivalent: "")
                        menu.addItem(metricItem)
                    }
                } else {
                    menu.addItem(NSMenuItem(title: "  No data", action: nil, keyEquivalent: ""))
                }
                
                menu.addItem(NSMenuItem.separator())
                totalToolsAdded += 1
            }
            
            // Add Codex explicitly if it was parsed but not in config
            if totalToolsAdded > 0 && toolResults["Codex"] != nil && !config.tools.contains(where: { $0.name == "Codex" }) {
                let toolItem = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
                let font = NSFont.boldSystemFont(ofSize: 13)
                toolItem.attributedTitle = NSAttributedString(string: "Codex", attributes: [.font: font])
                menu.addItem(toolItem)
                if let metrics = toolResults["Codex"] {
                    for (label, value) in metrics {
                        menu.addItem(NSMenuItem(title: "  \(label): \(value)", action: nil, keyEquivalent: ""))
                    }
                }
                menu.addItem(NSMenuItem.separator())
            }
        }
        
        // 2. Link Accounts section (custom feature)
        let linkSectionItem = NSMenuItem(title: "Link / Login Accounts", action: nil, keyEquivalent: "")
        let font = NSFont.boldSystemFont(ofSize: 12)
        linkSectionItem.attributedTitle = NSAttributedString(string: "Link / Login Accounts", attributes: [.font: font])
        menu.addItem(linkSectionItem)
        
        menu.addItem(NSMenuItem(title: "  Log in to Claude Code", action: #selector(onLoginClaude), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "  Log in to Antigravity", action: #selector(onLoginAntigravity), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "  Log in to Command Code", action: #selector(onLoginCommandCode), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Control options
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(onRefresh), keyEquivalent: "r")
        menu.addItem(refreshItem)
        
        let configItem = NSMenuItem(title: "Edit Configuration", action: #selector(onEditConfig), keyEquivalent: "e")
        menu.addItem(configItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(onQuit), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    func runTerminalCommand(_ command: String) {
        let scriptContent = """
        tell application "Terminal"
            do script "\(command)"
            activate
        end tell
        """
        if let script = NSAppleScript(source: scriptContent) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript Error: \(error)")
            }
        }
    }
    
    @objc func onLoginClaude() {
        runTerminalCommand("/Users/aashishlal/.local/bin/claude auth")
    }
    
    @objc func onLoginAntigravity() {
        runTerminalCommand("/opt/homebrew/bin/antigravity-usage login")
    }
    
    @objc func onLoginCommandCode() {
        runTerminalCommand("/opt/homebrew/bin/cmd login")
    }
    
    @objc func onRefresh() {
        refreshData()
    }
    
    @objc func onEditConfig() {
        let configPath = NSString(string: "~/.agent-tracker.json").expandingTildeInPath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [configPath]
        task.launch()
    }
    
    @objc func onQuit() {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - Main Application Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Hide icon from Dock
app.setActivationPolicy(.accessory)

app.run()
