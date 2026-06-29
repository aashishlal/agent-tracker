import Cocoa
import Foundation

// MARK: - Models

struct Metric: Codable {
    let label: String
    let regex: String
}

struct Tool: Codable {
    let name: String
    let command: String
    let metrics: [Metric]
}

struct Config: Codable {
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
            button.imagePosition = .imageOnly
            setButtonImage(open: true)
            
            // Setup tracking area for hover state
            let trackingArea = NSTrackingArea(rect: button.bounds,
                                              options: [.mouseEnteredAndExited, .activeAlways],
                                              owner: self,
                                              userInfo: nil)
            button.addTrackingArea(trackingArea)
            button.toolTip = "Agent Tracker - Loading..."
        }
        
        // Load initial config
        loadConfig()
        
        // Initial refresh
        refreshData()
        
        // Setup timer to refresh every 10 minutes
        Timer.scheduledTimer(withTimeInterval: 600.0, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }
    
    func setButtonImage(open: Bool) {
        guard let button = statusItem?.button else { return }
        let imageName = open ? "Open" : "Closed"
        
        // 1. Try loading from main bundle resources
        if let image = Bundle.main.image(forResource: imageName) {
            image.isTemplate = true
            button.image = image
            return
        }
        
        // 2. Try loading from bundle resources subpath (compiled .app/Contents/Resources/Icons/)
        if let resourcesPath = Bundle.main.resourcePath {
            let path = (resourcesPath as NSString).appendingPathComponent("Icons/\(imageName).png")
            if FileManager.default.fileExists(atPath: path), let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                button.image = image
                return
            }
        }
        
        // 3. Try loading from local path (for dev fallback)
        let devPath = "/Users/aashishlal/Documents/Agent Tracker/Icons/\(imageName).png"
        if FileManager.default.fileExists(atPath: devPath), let image = NSImage(contentsOfFile: devPath) {
            image.isTemplate = true
            button.image = image
            return
        }
        
        // 4. Fallback emoji if files missing
        button.image = nil
        button.title = open ? "👁️" : "🫵"
    }
    
    // Mouse hover tracking
    @objc func mouseEntered(with event: NSEvent) {
        setButtonImage(open: false)
    }
    
    @objc func mouseExited(with event: NSEvent) {
        setButtonImage(open: true)
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
        
        loadConfig()
        
        guard let config = config else {
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
                
                let cleanedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if tool.name == "Antigravity" && cleanedOutput.hasPrefix("{") {
                    if let data = cleanedOutput.data(using: .utf8) {
                        struct AgyModel: Decodable {
                            let label: String
                            let modelId: String
                            let remainingPercentage: Double?
                        }
                        struct AgyQuota: Decodable {
                            let models: [AgyModel]?
                        }
                        
                        do {
                            let decoded = try JSONDecoder().decode(AgyQuota.self, from: data)
                            if let models = decoded.models {
                                if let geminiModel = models.first(where: { $0.modelId.contains("gemini") }),
                                   let remaining = geminiModel.remainingPercentage {
                                    let pct = Int(remaining * 100)
                                    metricsResults["Gemini Quota"] = "\(pct)% remaining"
                                }
                                if let claudeModel = models.first(where: { $0.modelId.contains("claude") }),
                                   let remaining = claudeModel.remainingPercentage {
                                    let pct = Int(remaining * 100)
                                    metricsResults["Claude Quota"] = "\(pct)% remaining"
                                }
                            }
                        } catch {
                            print("Failed to parse Antigravity JSON: \(error)")
                        }
                    }
                }
                
                if metricsResults.isEmpty {
                    for metric in tool.metrics {
                        if let value = self.extractValue(from: output, regexPattern: metric.regex) {
                            metricsResults[metric.label] = value
                        } else {
                            if output.contains("expired") || output.contains("login") || output.contains("login again") || output.contains("Failed to fetch") {
                                metricsResults[metric.label] = "Login required"
                            } else {
                                metricsResults[metric.label] = "N/A"
                            }
                        }
                    }
                }
                
                lock.lock()
                newResults[tool.name] = metricsResults
                lock.unlock()
                
                group.leave()
            }
        }
        
        // Fetch Claude Cost directly from JSON file
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
        
        // Fetch Codex Logs directly from SQLite database
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
        
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        task.currentDirectoryPath = homeDir
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = ["-c", command]
        task.launchPath = "/bin/zsh"
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 15.0)
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
        
        // 2. Settings / Edit Configuration in Menu (New Feature)
        let settingsHeader = NSMenuItem(title: "Configuration", action: nil, keyEquivalent: "")
        let font = NSFont.boldSystemFont(ofSize: 12)
        settingsHeader.attributedTitle = NSAttributedString(string: "Configuration", attributes: [.font: font])
        menu.addItem(settingsHeader)
        
        menu.addItem(NSMenuItem(title: "  Add Custom CLI Tool...", action: #selector(onAddToolDialog), keyEquivalent: ""))
        
        // Remove Tool Submenu
        let removeSubmenu = NSMenu()
        if let config = config, !config.tools.isEmpty {
            for tool in config.tools {
                let removeToolItem = NSMenuItem(title: "Remove \(tool.name)", action: #selector(onRemoveToolItem(_:)), keyEquivalent: "")
                removeToolItem.representedObject = tool.name
                removeSubmenu.addItem(removeToolItem)
            }
        } else {
            removeSubmenu.addItem(NSMenuItem(title: "No tools configured", action: nil, keyEquivalent: ""))
        }
        
        let removeItem = NSMenuItem(title: "  Remove Custom CLI Tool", action: nil, keyEquivalent: "")
        removeItem.submenu = removeSubmenu
        menu.addItem(removeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Control options
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(onRefresh), keyEquivalent: "r")
        menu.addItem(refreshItem)
        
        let configItem = NSMenuItem(title: "Open Configuration JSON", action: #selector(onEditConfig), keyEquivalent: "e")
        menu.addItem(configItem)
        
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(onCheckForUpdates), keyEquivalent: "u")
        menu.addItem(updateItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(onQuit), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    // MARK: - Dynamic Configuration Actions
    
    @objc func onAddToolDialog() {
        let alert = NSAlert()
        alert.messageText = "Add Custom CLI Tool"
        alert.informativeText = "Enter the configuration details for the new CLI tool:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        // Create form view
        let nameField = NSTextField(frame: NSRect(x: 0, y: 90, width: 280, height: 24))
        nameField.placeholderString = "Tool Name (e.g. Claude Code)"
        
        let cmdField = NSTextField(frame: NSRect(x: 0, y: 60, width: 280, height: 24))
        cmdField.placeholderString = "CLI Command (e.g. /usr/local/bin/my-tool --usage)"
        
        let labelField = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        labelField.placeholderString = "Metric Label (e.g. Daily limit)"
        
        let regexField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        regexField.placeholderString = "Regex to extract value (e.g. (\\d+%))"
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 114))
        container.addSubview(nameField)
        container.addSubview(cmdField)
        container.addSubview(labelField)
        container.addSubview(regexField)
        
        alert.accessoryView = container
        
        // Activate app to bring dialog to front
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = cmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let regex = regexField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !name.isEmpty && !command.isEmpty && !label.isEmpty && !regex.isEmpty {
                addToolToConfig(name: name, command: command, label: label, regex: regex)
            }
        }
    }
    
    @objc func onRemoveToolItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        
        let alert = NSAlert()
        alert.messageText = "Remove Tool"
        alert.informativeText = "Are you sure you want to remove '\(name)' from the tracker?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            removeToolFromConfig(name: name)
        }
    }
    
    func addToolToConfig(name: String, command: String, label: String, regex: String) {
        loadConfig()
        guard let currentConfig = config else { return }
        
        let newMetric = Metric(label: label, regex: regex)
        let newTool = Tool(name: name, command: command, metrics: [newMetric])
        
        var updatedTools = currentConfig.tools
        updatedTools.removeAll(where: { $0.name == name })
        updatedTools.append(newTool)
        
        let newConfig = Config(tools: updatedTools)
        saveConfigToDisk(newConfig)
        refreshData()
    }
    
    func removeToolFromConfig(name: String) {
        loadConfig()
        guard let currentConfig = config else { return }
        
        var updatedTools = currentConfig.tools
        updatedTools.removeAll(where: { $0.name == name })
        
        let newConfig = Config(tools: updatedTools)
        saveConfigToDisk(newConfig)
        refreshData()
    }
    
    func saveConfigToDisk(_ newConfig: Config) {
        let configPath = NSString(string: "~/.agent-tracker.json").expandingTildeInPath
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(newConfig)
            try data.write(to: URL(fileURLWithPath: configPath))
            self.config = newConfig
        } catch {
            print("Failed to save config: \(error)")
        }
    }
    
    // MARK: - Link Commands
    

    
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
    
    @objc func onCheckForUpdates() {
        checkForUpdates(isManual: true)
    }
    
    func checkForUpdates(isManual: Bool) {
        let plistUrl = URL(string: "https://raw.githubusercontent.com/aashishlal/agent-tracker/main/Info.plist")!
        
        let task = URLSession.shared.dataTask(with: plistUrl) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                guard error == nil, let data = data else {
                    if isManual {
                        self.showUpdateAlert(title: "Update Check Failed", text: "Failed to connect to update server. Please check your internet connection.")
                    }
                    return
                }
                
                guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    if isManual {
                        self.showUpdateAlert(title: "Update Check Failed", text: "Failed to parse update information.")
                    }
                    return
                }
                
                if let remoteVersionStr = plist["CFBundleShortVersionString"] as? String,
                   let remoteBuildStr = plist["CFBundleVersion"] as? String,
                   let localVersionStr = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                   let localBuildStr = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                    
                    let hasUpdate = remoteVersionStr != localVersionStr || remoteBuildStr != localBuildStr
                    
                    if hasUpdate {
                        let alert = NSAlert()
                        alert.messageText = "Update Available"
                        alert.informativeText = "A new version of Agent Tracker is available!\n\nLocal: v\(localVersionStr) (Build \(localBuildStr))\nLatest: v\(remoteVersionStr) (Build \(remoteBuildStr))\n\nWould you like to open the GitHub repository to download the latest release?"
                        alert.addButton(withTitle: "Download")
                        alert.addButton(withTitle: "Cancel")
                        
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn {
                            if let url = URL(string: "https://github.com/aashishlal/agent-tracker") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        if isManual {
                            self.showUpdateAlert(title: "Up to Date", text: "You are running the latest version (v\(localVersionStr)).")
                        }
                    }
                }
            }
        }
        task.resume()
    }
    
    func showUpdateAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Main Application Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Hide icon from Dock
app.setActivationPolicy(.accessory)

app.run()
