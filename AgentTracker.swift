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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "📊 Loading..."
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
        
        if let button = statusItem?.button {
            button.title = "🔄 Refreshing..."
        }
        
        // Reload config in case user edited it
        loadConfig()
        
        guard let config = config, !config.tools.isEmpty else {
            self.isRefreshing = false
            self.updateMenu()
            return
        }
        
        let group = DispatchGroup()
        var newResults: [String: [String: String]] = [:]
        let lock = NSLock()
        
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
        
        group.notify(queue: DispatchQueue.main) { [weak self] in
            guard let self = self else { return }
            self.toolResults = newResults
            self.isRefreshing = false
            self.updateMenu()
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
                    // Return first capture group
                    let range = match.range(at: 1)
                    return nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // Return full match
                    let range = match.range(at: 0)
                    return nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            print("Regex error: \(error)")
        }
        return nil
    }
    
    func updateMenu() {
        menu.removeAllItems()
        
        // 1. Summary details of each tool
        if let config = config {
            var totalToolsAdded = 0
            for tool in config.tools {
                let toolItem = NSMenuItem(title: tool.name, action: nil, keyEquivalent: "")
                let font = NSFont.boldSystemFont(ofSize: 13)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                toolItem.attributedTitle = NSAttributedString(string: tool.name, attributes: attributes)
                menu.addItem(toolItem)
                
                if let metrics = toolResults[tool.name] {
                    for (label, value) in metrics {
                        let metricItem = NSMenuItem(title: "  \(label): \(value)", action: nil, keyEquivalent: "")
                        menu.addItem(metricItem)
                    }
                } else {
                    menu.addItem(NSMenuItem(title: "  No data", action: nil, keyEquivalent: ""))
                }
                
                menu.addItem(NSMenuItem.separator())
                totalToolsAdded += 1
            }
            
            if totalToolsAdded == 0 {
                menu.addItem(NSMenuItem(title: "No tools configured", action: nil, keyEquivalent: ""))
                menu.addItem(NSMenuItem.separator())
            }
        }
        
        // 2. Control options
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(onRefresh), keyEquivalent: "r")
        menu.addItem(refreshItem)
        
        let configItem = NSMenuItem(title: "Edit Configuration", action: #selector(onEditConfig), keyEquivalent: "e")
        menu.addItem(configItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(onQuit), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        
        // Update menu bar title with summary
        if let button = statusItem?.button {
            var summary = "📊 Agent Limits"
            
            // Look for weekly usage of Claude to display in main bar as quick indicator
            if let claudeMetrics = toolResults["Claude Code"], let weekly = claudeMetrics["Weekly Usage"] {
                summary = "📊 Claude: \(weekly)"
            }
            
            button.title = summary
        }
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

// Hide icon from Dock since it is a menu bar only app
app.setActivationPolicy(.accessory)

app.run()
