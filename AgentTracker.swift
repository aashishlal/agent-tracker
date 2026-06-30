import Cocoa
import Foundation

// MARK: - Logging System

struct Logger {
    static let logPath = "/tmp/agent_tracker_debug.log"
    static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()
    
    static func log(_ message: String, level: String = "INFO") {
        let timestamp = dateFormatter.string(from: Date())
        let logMessage = "[\(timestamp)] [\(level)] \(message)\n"
        
        print(logMessage) // Also print to console
        
        if let data = logMessage.data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: data, attributes: nil)
            } else if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        }
    }
    
    static func error(_ message: String) {
        log(message, level: "ERROR")
    }
    
    static func warn(_ message: String) {
        log(message, level: "WARN")
    }
    
    static func debug(_ message: String) {
        log(message, level: "DEBUG")
    }
    
    static func clearLog() {
        try? FileManager.default.removeItem(atPath: logPath)
        log("=== Agent Tracker Log Started ===")
    }
}

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

// MARK: - Metric Row View

class MetricRowView: NSView {
    private let labelText: String
    private let valueText: String
    private let pct: Int?
    private let consumed: Int?  // 0–100: how much is consumed regardless of framing

    static let withBarHeight: CGFloat = 34
    static let plainHeight: CGFloat = 22

    init(label: String, value: String) {
        self.labelText = label
        self.valueText = value
        if value.contains("%") {
            let digits = value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let p = Int(digits), p >= 0, p <= 100 {
                self.pct = p
                let isRemaining = value.lowercased().contains("remaining") || value.lowercased().contains("left")
                self.consumed = isRemaining ? (100 - p) : p
            } else { self.pct = nil; self.consumed = nil }
        } else { self.pct = nil; self.consumed = nil }
        let h = (pct != nil) ? MetricRowView.withBarHeight : MetricRowView.plainHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: h))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    private var barFill: NSColor {
        guard let c = consumed else { return .systemBlue }
        if c >= 95 { return .systemRed }
        if c >= 85 { return .systemOrange }
        return .systemBlue
    }

    private var labelColor: NSColor {
        guard let c = consumed else { return .labelColor }
        if c >= 95 { return .systemRed }
        if c >= 85 { return .systemOrange }
        return .labelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let lx: CGFloat = 16  // left indent matches macOS menu system items

        // Label + value text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: labelColor
        ]
        let textY: CGFloat = (pct != nil) ? h - 18 : (h - 13) / 2
        NSAttributedString(string: "\(labelText)  \(valueText)", attributes: attrs)
            .draw(at: NSPoint(x: lx, y: textY))

        // Progress bar
        guard let p = pct else { return }
        let bh: CGFloat = 4
        let bw = w - lx - 16
        let trackRect = NSRect(x: lx, y: 5, width: bw, height: bh)
        let r = bh / 2

        // Track
        NSColor(white: 0.5, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: r, yRadius: r).fill()

        // Fill
        let fillW = bw * CGFloat(max(0, min(100, p))) / 100
        if fillW > 1 {
            let fillRect = NSRect(x: lx, y: 5, width: fillW, height: bh)
            barFill.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: r, yRadius: r).fill()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menu: NSMenu = NSMenu()
    var config: Config?
    var toolResults: [String: [String: String]] = [:]
    var isRefreshing = false
    var hasAlertedClaude = false
    var workspacePath = ""
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.clearLog()
        Logger.log("Agent Tracker starting...")
        
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
            Logger.log("Status bar button initialized")
        } else {
            Logger.error("Failed to create status bar button")
        }
        
        // Load initial config
        loadConfig()
        
        // Setup temp workspace
        setupTempWorkspace()
        
        // Initial refresh
        Logger.log("Starting initial data refresh...")
        refreshData()
        
        // Setup timer to refresh every 10 minutes
        Timer.scheduledTimer(withTimeInterval: 600.0, repeats: true) { [weak self] _ in
            Logger.log("Timer triggered - refreshing data...")
            self?.refreshData()
        }
        
        Logger.log("Agent Tracker launched successfully")
    }
    
    func setupTempWorkspace() {
        let fm = FileManager.default
        guard let appSupportURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Logger.error("Could not find Application Support directory")
            return
        }
        
        let folderName = Bundle.main.bundleIdentifier ?? "com.aashishlal.AgentTracker"
        let pathURL = appSupportURL.appendingPathComponent(folderName).appendingPathComponent("agent_tracker_workspace")
        let path = pathURL.path
        self.workspacePath = path
        
        Logger.debug("Workspace path: \(path)")
        
        if !fm.fileExists(atPath: path) {
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
                Logger.log("Created workspace directory")
            } catch {
                Logger.error("Failed to create workspace: \(error)")
            }
        }
        
        if fm.fileExists(atPath: path) && !fm.fileExists(atPath: "\(path)/.git") {
            let task = Process()
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.currentDirectoryPath = path
            task.arguments = ["-c", "git init && git remote add origin https://github.com/aashishlal/agent-tracker.git"]
            task.launchPath = "/bin/zsh"
            try? task.run()
            task.waitUntilExit()
            Logger.log("Initialized git workspace")
        }
    }
    
    func setButtonImage(open: Bool) {
        guard let button = statusItem?.button else { return }
        let imageName = open ? "Open" : "Closed"
        
        // 1. Try loading from main bundle resources
        if let image = NSImage(named: NSImage.Name(imageName)) {
            image.isTemplate = true
            button.image = image
            Logger.debug("Loaded image from bundle: \(imageName)")
            return
        }
        
        // 2. Try loading from bundle resource path explicitly (for custom build scripts)
        if let resourcesPath = Bundle.main.resourcePath {
            let path = (resourcesPath as NSString).appendingPathComponent("\(imageName).png")
            if FileManager.default.fileExists(atPath: path), let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                button.image = image
                Logger.debug("Loaded image from resource path: \(path)")
                return
            }
        }
        
        // 3. Fallback emoji if files missing
        button.image = nil
        button.title = open ? "👁️" : "🫵"
        Logger.warn("Could not load image '\(imageName)', using emoji fallback")
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
        Logger.debug("Loading config from: \(configPath)")
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            config = try JSONDecoder().decode(Config.self, from: data)
            Logger.log("Loaded config with \(config?.tools.count ?? 0) tools")
        } catch {
            Logger.error("Failed to load config: \(error)")
            config = Config(tools: [])
        }
    }
    
    func refreshData() {
        guard !isRefreshing else {
            Logger.warn("Refresh already in progress, skipping...")
            return
        }
        isRefreshing = true
        
        Logger.log("=== Starting data refresh ===")
        loadConfig()
        
        guard let config = config else {
            Logger.error("No config loaded")
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
            let toolName = tool.name
            Logger.log("Processing tool: \(toolName)")
            
            DispatchQueue.global(qos: .userInitiated).async {
                var metricsResults: [String: String] = [:]
                
                // Special handling for Antigravity - read from cache file
                if tool.name == "Antigravity" {
                    Logger.log("[\(toolName)] Reading from cache file...")
                    metricsResults = self.getAntigravityUsageFromCache()
                } else {
                    // Standard command execution for other tools
                    let startTime = Date()
                    let output = self.runShell(tool.command, toolName: toolName)
                    let duration = Date().timeIntervalSince(startTime)
                    
                    Logger.debug("[\(toolName)] Command completed in \(String(format: "%.2f", duration))s")
                    Logger.debug("[\(toolName)] Output length: \(output.count) chars")
                    
                    if output.isEmpty {
                        Logger.warn("[\(toolName)] Empty output received")
                    } else {
                        Logger.debug("[\(toolName)] First 200 chars: \(output.prefix(200))")
                    }
                    
                    let cleanedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Standard regex parsing
                    Logger.debug("[\(toolName)] Using regex parsing for \(tool.metrics.count) metrics")
                    for metric in tool.metrics {
                        if let value = self.extractValue(from: output, regexPattern: metric.regex) {
                            metricsResults[metric.label] = value
                            Logger.log("[\(toolName)] ✓ \(metric.label): \(value)")
                        } else {
                            if output.contains("expired") || output.contains("login") || output.contains("login again") || output.contains("Failed to fetch") {
                                metricsResults[metric.label] = "Login required"
                                Logger.warn("[\(toolName)] \(metric.label): Login required")
                            } else if output.contains("timed out") || output.contains("Terminated") {
                                metricsResults[metric.label] = "Timeout"
                                Logger.warn("[\(toolName)] \(metric.label): Command timed out")
                            } else {
                                metricsResults[metric.label] = "N/A"
                                Logger.warn("[\(toolName)] \(metric.label): No match found")
                            }
                        }
                    }
                }
                
                lock.lock()
                newResults[toolName] = metricsResults
                lock.unlock()
                
                Logger.log("[\(toolName)] Completed with \(metricsResults.count) metrics")
                group.leave()
            }
        }
        
        // Fetch Claude Cost directly from JSON file
        group.enter()
        Logger.log("Fetching Claude Cost from ~/.claude.json...")
        DispatchQueue.global(qos: .userInitiated).async {
            let cost = self.getClaudeCost()
            Logger.log("Claude Cost: \(cost)")
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
        Logger.log("Fetching Codex logs from SQLite...")
        DispatchQueue.global(qos: .userInitiated).async {
            let dbPath = NSString(string: "~/.codex/logs_2.sqlite").expandingTildeInPath
            var stats = "N/A"
            
            Logger.debug("[Codex] Database path: \(dbPath)")
            Logger.debug("[Codex] File exists: \(FileManager.default.fileExists(atPath: dbPath))")
            
            if FileManager.default.fileExists(atPath: dbPath) {
                let output = self.runShell("sqlite3 \(dbPath) \"SELECT count(*), sum(estimated_bytes) FROM logs;\" 2>/dev/null", toolName: "Codex")
                Logger.debug("[Codex] SQLite output: \(output)")
                
                let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
                if parts.count == 2, let count = Int(parts[0]), let bytes = Int(parts[1]) {
                    let kb = bytes / 1024
                    stats = "\(count) logs (\(kb) KB)"
                    Logger.log("[Codex] Parsed: \(stats)")
                } else {
                    Logger.warn("[Codex] Could not parse SQLite output")
                }
            } else {
                Logger.warn("[Codex] Database file not found")
            }
            
            lock.lock()
            if newResults["Codex"] == nil {
                newResults["Codex"] = [:]
            }
            newResults["Codex"]?["Local Activity"] = stats
            lock.unlock()
            group.leave()
        }
        
        // CommandCode — /usage panel not capturable via PTY; read local activity instead
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let activity = self.getCommandCodeActivity()
            lock.lock()
            newResults["Command Code"] = activity.isEmpty ? [:] : ["Activity": activity]
            lock.unlock()
            group.leave()
        }

        // Kimi via PTY
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let metrics = self.getKimiUsage()
            lock.lock()
            newResults["Kimi"] = metrics
            lock.unlock()
            group.leave()
        }

        group.notify(queue: DispatchQueue.main) { [weak self] in
            guard let self = self else { return }
            
            Logger.log("=== Data refresh complete ===")
            Logger.log("Results summary:")
            for (tool, metrics) in newResults.sorted(by: { $0.key < $1.key }) {
                Logger.log("  \(tool): \(metrics)")
            }
            
            self.toolResults = newResults
            self.isRefreshing = false
            self.checkAlerts()
            self.updateMenu()
            self.updateToolTip()
            
            Logger.log("UI updated successfully")
        }
    }
    
    func runShell(_ command: String, toolName: String = "Shell") -> String {
        let task = Process()
        let tempFile = NSTemporaryDirectory() + UUID().uuidString + ".log"
        let fullCommand = "\(command) > \(tempFile) 2>&1"
        
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(currentPath)"
        // Explicitly set HOME so CLIs can find ~/.commandcode and other auth configs
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        task.environment = env
        
        if !workspacePath.isEmpty && FileManager.default.fileExists(atPath: workspacePath) {
            task.currentDirectoryPath = workspacePath
        } else {
            task.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        }
        task.arguments = ["-l", "-c", "source ~/.zshrc 2>/dev/null; " + fullCommand]
        task.launchPath = "/bin/zsh"
        
        Logger.debug("[\(toolName)] Executing: \(command)")
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 30.0)
        timer.setEventHandler {
            if task.isRunning {
                Logger.warn("[\(toolName)] Command timed out after 15s, terminating...")
                task.terminate()
            }
        }
        timer.resume()
        
        do {
            try task.run()
            task.waitUntilExit()
            Logger.debug("[\(toolName)] Process exited with status: \(task.terminationStatus)")
        } catch {
            timer.cancel()
            Logger.error("[\(toolName)] Process error: \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
        
        timer.cancel()
        
        let result = (try? String(contentsOfFile: tempFile, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: tempFile)
        
        Logger.debug("[\(toolName)] Output length: \(result.count) chars")
        
        return result
    }
    
    // MARK: - Menu Styling

    var sectionHeaderAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    var resetAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    func metricAttrs(for value: String) -> [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if value.contains("N/A") || value.contains("Timeout") || value.contains("Login required") {
            return [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        }
        if value.contains("%") {
            let digits = value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let pct = Int(digits) {
                let isRemaining = value.lowercased().contains("remaining") || value.lowercased().contains("left")
                let consumed = isRemaining ? (100 - pct) : pct
                if consumed >= 95 { return [.font: font, .foregroundColor: NSColor.systemRed] }
                if consumed >= 85 { return [.font: font, .foregroundColor: NSColor.systemOrange] }
            }
        }
        return [.font: font, .foregroundColor: NSColor.labelColor]
    }

    // MARK: - ASCII Chart Generator

    func generateASCIIChart(percentage: Int, width: Int = 12) -> String {
        // Clamp percentage to 0-100 range
        let clampedPercentage = max(0, min(100, percentage))
        let filled = Int(Double(clampedPercentage) / 100.0 * Double(width))
        let empty = max(0, width - filled)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        return bar
    }
    
    func formatMetricWithChart(label: String, value: String) -> String {
        return "  \(label)  \(value)"
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
            Logger.error("Regex error for pattern '\(regexPattern)': \(error)")
        }
        return nil
    }
    
    // MARK: - PTY-based interactive CLI capture

    // readyPattern: if set, wait for this string to appear in output before sending command (adaptive)
    // otherwise fall back to fixed initWait
    func runWithPTY(command: String, sendCommand: String, toolName: String,
                    initWait: Double = 4.0, totalWait: Double = 9.0,
                    readyPattern: String? = nil) -> String {
        Logger.log("[\(toolName)] PTY capture starting...")
        let scriptPath = NSTemporaryDirectory() + "agt_pty_\(toolName.replacingOccurrences(of: " ", with: "_")).py"
        let readyCheck: String
        if let pattern = readyPattern {
            // Escape for Python string
            let escaped = pattern.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "'", with: "\\'")
            readyCheck = """
    if not sent:
        recent = all_out[-1000:].decode('utf-8', errors='replace')
        if '\(escaped)' in recent:
            import time as t2; t2.sleep(0.3)
            os.write(master, b'\(sendCommand)\\r')
            sent = True
"""
        } else {
            readyCheck = """
    if not sent and time.time() - t0 >= \(initWait):
        os.write(master, b'\(sendCommand)\\r')
        sent = True
"""
        }
        let script = """
import pty, os, select, time, subprocess, re, sys, termios, struct, fcntl
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
env = dict(__import__('os').environ)
env['TERM'] = 'xterm-256color'
p = subprocess.Popen(['\(command)'], stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=env)
os.close(slave)
all_out = b''
sent = False
t0 = time.time()
while time.time() - t0 < \(totalWait):
    r, _, _ = select.select([master], [], [], 0.05)
    if r:
        try: all_out += os.read(master, 8192)
        except: break
\(readyCheck)
p.terminate()
try: os.close(master)
except: pass
clean = re.sub(b'\\x1b\\\\[[0-9;?]*[mABCDEFGHJKLMPSTXZfhilnrsu]', b'', all_out)
clean = re.sub(b'\\x1b\\\\][^\\x07\\x1b]*[\\x07\\x1b]', b'', clean)
clean = re.sub(b'\\x1b[78>=cNOME]', b'', clean)
clean = re.sub(b'\\r', b'\\n', clean)
clean = re.sub(b'[\\x00-\\x08\\x0b-\\x0c\\x0e-\\x1f\\x7f]', b'', clean)
sys.stdout.write(clean.decode('utf-8', errors='replace'))
"""
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            Logger.error("[\(toolName)] Failed to write PTY script: \(error)")
            return ""
        }
        let raw = runShell("python3 \(scriptPath)", toolName: toolName)
        try? FileManager.default.removeItem(atPath: scriptPath)
        Logger.debug("[\(toolName)] PTY raw output (\(raw.count) chars): \(raw.prefix(300))")
        return raw
    }

    func getCommandCodeUsage() -> [String: String] {
        let raw = runWithPTY(command: "cmd", sendCommand: "/usage", toolName: "Command Code", initWait: 4.0, totalWait: 9.0)
        var r: [String: String] = [:]
        guard !raw.isEmpty else { return r }

        if let v = extractValue(from: raw, regexPattern: "(\\d+)% used") { r["Cycle"] = "\(v)% used" }
        if let v = extractValue(from: raw, regexPattern: "\\$([0-9.]+) left") { r["Cycle Left"] = "$\(v) left" }
        if let v = extractValue(from: raw, regexPattern: "5-hour\\s+[^ \\n]* (\\d+%)") {
            r["5-Hour"] = "\(v) used"
        }
        if let v = extractValue(from: raw, regexPattern: "Weekly\\s+[^ \\n]* (\\d+%)") {
            r["Weekly"] = "\(v) used"
        }
        if let v = extractValue(from: raw, regexPattern: "Weekly[^\\n]+resets in\\s+([^\\n]+)") {
            r["Weekly Reset"] = "Resets in \(v.trimmingCharacters(in: .whitespaces))"
        }
        Logger.log("[CommandCode] Parsed: \(r)")
        return r
    }

    func getKimiUsage() -> [String: String] {
        let raw = runKimiPTY()
        var r: [String: String] = [:]
        guard !raw.isEmpty else { return r }

        if let v = extractValue(from: raw, regexPattern: "Weekly limit.*?(\\d+%\\s+left)") { r["Weekly"] = v }
        if let v = extractValue(from: raw, regexPattern: "Weekly limit.*?\\(resets in ([^)]+)\\)") {
            r["Weekly Reset"] = "Resets in \(v)"
        }
        if let v = extractValue(from: raw, regexPattern: "5h limit.*?(\\d+%\\s+left)") { r["5-Hour"] = v }
        if let v = extractValue(from: raw, regexPattern: "5h limit.*?\\(resets in ([^)]+)\\)") {
            r["5h Reset"] = "Resets in \(v)"
        }
        Logger.log("[Kimi] Parsed: \(r)")
        return r
    }

    func runKimiPTY() -> String {
        Logger.log("[Kimi] PTY capture starting...")
        let scriptPath = NSTemporaryDirectory() + "agt_pty_kimi_usage.py"
        // Send /usage once MCP settles (InMemoryKV fallback or connected); fallback to 20s
        let script = """
import pty, os, select, time, subprocess, re, sys, termios, struct, fcntl
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
env = dict(__import__('os').environ)
env['TERM'] = 'xterm-256color'
p = subprocess.Popen(['/Users/aashishlal/.local/bin/kimi'], stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=env)
os.close(slave)
all_out = b''
sent = False
t0 = time.time()
end = None
while True:
    r, _, _ = select.select([master], [], [], 0.05)
    if r:
        try: all_out += os.read(master, 8192)
        except: break
    now = time.time() - t0
    if not sent:
        ready = b'InMemoryKV' in all_out or b'connected, 1 tool' in all_out
        if ready or now > 20:
            time.sleep(0.5)
            os.write(master, b'/usage\\r')
            sent = True
            end = time.time() + 4
    if end and time.time() > end:
        break
    if now > 26:
        break
p.terminate()
try: os.close(master)
except: pass
clean = re.sub(b'\\x1b\\\\[[0-9;?]*[mABCDEFGHJKLMPSTXZfhilnrsu]', b'', all_out)
clean = re.sub(b'\\x1b\\\\][^\\x07\\x1b]*[\\x07\\x1b]', b'', clean)
clean = re.sub(b'\\x1b[78>=cNOME]', b'', clean)
clean = re.sub(b'\\r', b'\\n', clean)
clean = re.sub(b'[\\x00-\\x08\\x0b-\\x0c\\x0e-\\x1f\\x7f]', b'', clean)
sys.stdout.write(clean.decode('utf-8', errors='replace'))
"""
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            Logger.error("[Kimi] Failed to write PTY script")
            return ""
        }
        let raw = runShell("python3 \(scriptPath)", toolName: "Kimi")
        try? FileManager.default.removeItem(atPath: scriptPath)
        Logger.debug("[Kimi] PTY raw output (\(raw.count) chars): \(raw.prefix(200))")
        return raw
    }

    func getClaudeCost() -> String {
        let path = NSString(string: "~/.claude.json").expandingTildeInPath
        Logger.debug("[Claude Cost] Reading from: \(path)")
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            Logger.warn("[Claude Cost] Could not read file")
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
                Logger.log("[Claude Cost] Found \(projects.count) projects, total cost: $\(String(format: "%.2f", totalCost))")
                return String(format: "$%.2f", totalCost)
            }
        } catch {
            Logger.error("[Claude Cost] Decode error: \(error)")
        }
        return "N/A"
    }
    
    func getCommandCodeActivity() -> String {
        let fm = FileManager.default
        let projectsPath = NSString(string: "~/.commandcode/projects").expandingTildeInPath
        guard fm.fileExists(atPath: projectsPath),
              let projects = try? fm.contentsOfDirectory(atPath: projectsPath) else {
            return "N/A"
        }
        var totalSessions = 0
        var totalMessages = 0
        for proj in projects {
            let projPath = "\(projectsPath)/\(proj)"
            guard let files = try? fm.contentsOfDirectory(atPath: projPath) else { continue }
            let jsonls = files.filter { $0.hasSuffix(".jsonl") }
            totalSessions += jsonls.count
            for jf in jsonls {
                let content = (try? String(contentsOfFile: "\(projPath)/\(jf)", encoding: .utf8)) ?? ""
                totalMessages += content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            }
        }
        Logger.log("[CommandCode] Sessions: \(totalSessions), Messages: \(totalMessages)")
        return "\(totalSessions) sessions (\(totalMessages) msgs)"
    }

    func getKimiActivity() -> String {
        let fm = FileManager.default
        let sessionsPath = NSString(string: "~/.kimi/sessions").expandingTildeInPath
        guard fm.fileExists(atPath: sessionsPath),
              let sessions = try? fm.contentsOfDirectory(atPath: sessionsPath) else {
            return "N/A"
        }
        let count = sessions.filter { !$0.hasPrefix(".") }.count
        Logger.log("[Kimi] Sessions: \(count)")
        return "\(count) sessions"
    }

    func getAntigravityUsageFromCache() -> [String: String] {
        var results: [String: String] = [:]
        
        // Find the active account's cache file
        let configPath = NSString(string: "~/Library/Application Support/antigravity-usage/config.json").expandingTildeInPath
        Logger.debug("[Antigravity] Reading config from: \(configPath)")
        
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            Logger.warn("[Antigravity] Could not read config file")
            results["Status"] = "Config not found"
            return results
        }
        
        struct AgyConfig: Decodable {
            let activeAccount: String?
        }
        
        guard let config = try? JSONDecoder().decode(AgyConfig.self, from: configData),
              let email = config.activeAccount else {
            Logger.warn("[Antigravity] Could not parse config or find active account")
            results["Status"] = "No active account"
            return results
        }
        
        Logger.log("[Antigravity] Active account: \(email)")
        
        // Read the cache file for the active account
        let cachePath = NSString(string: "~/Library/Application Support/antigravity-usage/accounts/\(email)/cache.json").expandingTildeInPath
        Logger.debug("[Antigravity] Reading cache from: \(cachePath)")
        
        guard let cacheData = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) else {
            Logger.warn("[Antigravity] Could not read cache file")
            results["Status"] = "Cache not found"
            return results
        }
        
        struct AgyModel: Decodable {
            let label: String
            let modelId: String
            let remainingPercentage: Double?
            let isExhausted: Bool?
            let resetTime: String?
        }
        
        struct AgyCacheData: Decodable {
            let models: [AgyModel]?
        }
        
        struct AgyCache: Decodable {
            let cachedAt: String?
            let data: AgyCacheData?
        }
        
        do {
            let cache = try JSONDecoder().decode(AgyCache.self, from: cacheData)
            
            if let cachedAt = cache.cachedAt {
                Logger.log("[Antigravity] Cache timestamp: \(cachedAt)")
            }
            
            if let models = cache.data?.models {
                Logger.log("[Antigravity] Found \(models.count) models in cache")
                
                // Get all remaining percentages and reset times
                let allRemaining = models.compactMap { $0.remainingPercentage }
                
                // Find the earliest reset time for 5-hour limits
                let fiveHourResetTimes = models.compactMap { $0.resetTime }.filter { time in
                    // 5-hour limits have shorter reset times
                    return true
                }
                
                // 5-hour limit: use the lowest remaining percentage (most restrictive)
                if let worstRemaining = allRemaining.min() {
                    let pct = Int((worstRemaining * 100).rounded())
                    
                    // Find the reset time for the model with worst remaining
                    if let worstModel = models.first(where: { $0.remainingPercentage == worstRemaining }),
                       let resetTime = worstModel.resetTime {
                        let formatter = ISO8601DateFormatter()
                        if let resetDate = formatter.date(from: resetTime) {
                            let displayFormatter = DateFormatter()
                            displayFormatter.dateFormat = "MMM d, h:mm a"
                            results["5-Hour Reset"] = "Resets \(displayFormatter.string(from: resetDate))"
                        }
                    }
                    
                    results["5-Hour Limit"] = "\(pct)% remaining"
                    Logger.log("[Antigravity] 5-hour limit: \(pct)% remaining")
                }
                
                // Weekly limit: use the highest remaining percentage (most generous)
                if let bestRemaining = allRemaining.max() {
                    let pct = Int((bestRemaining * 100).rounded())
                    
                    // Find the reset time for the model with best remaining
                    if let bestModel = models.first(where: { $0.remainingPercentage == bestRemaining }),
                       let resetTime = bestModel.resetTime {
                        let formatter = ISO8601DateFormatter()
                        if let resetDate = formatter.date(from: resetTime) {
                            let displayFormatter = DateFormatter()
                            displayFormatter.dateFormat = "MMM d, h:mm a"
                            results["Weekly Reset"] = "Resets \(displayFormatter.string(from: resetDate))"
                        }
                    }
                    
                    results["Weekly Limit"] = "\(pct)% remaining"
                    Logger.log("[Antigravity] Weekly limit: \(pct)% remaining")
                }
            }
        } catch {
            Logger.error("[Antigravity] Cache parse error: \(error)")
            results["Status"] = "Parse error"
        }
        
        return results
    }
    
    func checkAlerts() {
        if let claudeMetrics = toolResults["Claude Code"], let weekly = claudeMetrics["Weekly Usage"] {
            let digits = weekly.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let pct = Int(digits), pct >= 90 {
                if !hasAlertedClaude {
                    Logger.log("Claude usage alert triggered: \(pct)%")
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
        Logger.log("Notification sent: \(title)")
    }
    
    func updateToolTip() {
        var tooltipParts: [String] = ["Agent Tracker - Hover Details"]
        
        let sortedKeys = toolResults.keys.sorted()
        for key in sortedKeys {
            if let metrics = toolResults[key] {
                tooltipParts.append("\n\(key):")
                for (label, value) in metrics.sorted(by: { $0.key < $1.key }) {
                    tooltipParts.append("  • \(label): \(value)")
                }
            }
        }
        
        statusItem?.button?.toolTip = tooltipParts.joined(separator: "\n")
        Logger.debug("Tooltip updated")
    }
    
    func updateMenu() {
        menu.removeAllItems()
        Logger.debug("Updating menu...")
        
        // 1. Summary details of each tool
        if let config = config {
            var totalToolsAdded = 0
            let sortedTools = config.tools.sorted(by: { $0.name < $1.name })
            
            for tool in sortedTools {
                let toolItem = NSMenuItem(title: tool.name, action: nil, keyEquivalent: "")
                toolItem.attributedTitle = NSAttributedString(string: tool.name.uppercased(), attributes: sectionHeaderAttrs)
                menu.addItem(toolItem)

                if let metrics = toolResults[tool.name] {
                    let sortedMetrics = metrics.sorted(by: { $0.key < $1.key })
                    for (label, value) in sortedMetrics {
                        if label.contains("Reset") {
                            let resetItem = NSMenuItem(title: "  \(value)", action: nil, keyEquivalent: "")
                            resetItem.attributedTitle = NSAttributedString(string: "  \(value)", attributes: resetAttrs)
                            menu.addItem(resetItem)
                        } else {
                            let metricItem = NSMenuItem()
                            metricItem.view = MetricRowView(label: label, value: value)
                            menu.addItem(metricItem)
                        }
                    }
                } else {
                    let noDataItem = NSMenuItem(title: "  No data", action: nil, keyEquivalent: "")
                    noDataItem.attributedTitle = NSAttributedString(string: "  No data", attributes: resetAttrs)
                    menu.addItem(noDataItem)
                }
                
                menu.addItem(NSMenuItem.separator())
                totalToolsAdded += 1
            }
            
            // Built-in sections: Codex (activity), CommandCode, Kimi (usage via PTY)
            for builtinName in ["Codex", "Command Code", "Kimi"] {
                guard let metrics = toolResults[builtinName], !metrics.isEmpty,
                      !config.tools.contains(where: { $0.name == builtinName }) else { continue }
                let headerItem = NSMenuItem(title: builtinName, action: nil, keyEquivalent: "")
                headerItem.attributedTitle = NSAttributedString(string: builtinName.uppercased(), attributes: sectionHeaderAttrs)
                menu.addItem(headerItem)
                for (label, value) in metrics.sorted(by: { $0.key < $1.key }) {
                    if label.contains("Reset") {
                        let item = NSMenuItem(title: "  \(value)", action: nil, keyEquivalent: "")
                        item.attributedTitle = NSAttributedString(string: "  \(value)", attributes: resetAttrs)
                        menu.addItem(item)
                    } else {
                        let item = NSMenuItem()
                        item.view = MetricRowView(label: label, value: value)
                        menu.addItem(item)
                    }
                }
                menu.addItem(NSMenuItem.separator())
            }
        }
        
        let settingsHeader = NSMenuItem(title: "Configuration", action: nil, keyEquivalent: "")
        settingsHeader.attributedTitle = NSAttributedString(string: "CONFIGURATION", attributes: sectionHeaderAttrs)
        menu.addItem(settingsHeader)

        menu.addItem(NSMenuItem(title: " Add Tool...", action: #selector(onAddToolDialog), keyEquivalent: ""))
        
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
        
        // 4. Control options
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
        Logger.debug("Menu updated with \(menu.items.count) items")
    }
    
    // MARK: - Dynamic Configuration Actions
    
    // Pre-configured known tools for the picker (built-ins like Codex/CommandCode/Kimi are auto-shown)
    let knownTools: [(name: String, command: String, metrics: [(label: String, regex: String)])] = []

    @objc func onAddToolDialog() {
        DispatchQueue.main.async {
            let existingNames = self.config?.tools.map { $0.name } ?? []

            // Build available known tools (not already added)
            let available = self.knownTools.filter { !existingNames.contains($0.name) }

            let alert = NSAlert()
            alert.window.level = .floating
            alert.messageText = "Add Tool"
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)

            if !available.isEmpty {
                for tool in available {
                    popup.addItem(withTitle: tool.name)
                }
                popup.menu?.addItem(NSMenuItem.separator())
            }
            popup.addItem(withTitle: "Custom Tool...")

            alert.informativeText = "Choose a tool to add:"
            alert.accessoryView = popup

            NSApp.activate(ignoringOtherApps: true)

            if alert.runModal() == .alertFirstButtonReturn {
                let selected = popup.titleOfSelectedItem ?? ""

                if let preset = self.knownTools.first(where: { $0.name == selected }) {
                    // Add all metrics from the preset
                    self.loadConfig()
                    guard let currentConfig = self.config else { return }
                    let newMetrics = preset.metrics.map { Metric(label: $0.label, regex: $0.regex) }
                    let newTool = Tool(name: preset.name, command: preset.command, metrics: newMetrics)
                    var updatedTools = currentConfig.tools
                    updatedTools.removeAll(where: { $0.name == preset.name })
                    updatedTools.append(newTool)
                    self.saveConfigToDisk(Config(tools: updatedTools))
                    self.refreshData()
                } else {
                    // Custom tool — show advanced form
                    self.showCustomToolDialog()
                }
            }
        }
    }

    func showCustomToolDialog() {
        let alert = NSAlert()
        alert.window.level = .floating
        alert.messageText = "Add Custom CLI Tool"
        alert.informativeText = "Enter the configuration details:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 90, width: 280, height: 24))
        nameField.placeholderString = "Tool Name (e.g. My Tool)"

        let cmdField = NSTextField(frame: NSRect(x: 0, y: 60, width: 280, height: 24))
        cmdField.placeholderString = "CLI Command (e.g. mytool --status)"

        let labelField = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        labelField.placeholderString = "Metric Label (e.g. Daily Limit)"

        let regexField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        regexField.placeholderString = "Regex (e.g. (\\d+%))"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 114))
        container.addSubview(nameField)
        container.addSubview(cmdField)
        container.addSubview(labelField)
        container.addSubview(regexField)
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = cmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let regex = regexField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if !name.isEmpty && !command.isEmpty && !label.isEmpty && !regex.isEmpty {
                Logger.log("Adding custom tool: \(name)")
                self.addToolToConfig(name: name, command: command, label: label, regex: regex)
            }
        }
    }
    
    @objc func onRemoveToolItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.window.level = .floating
            alert.messageText = "Remove Tool"
            alert.informativeText = "Are you sure you want to remove '\(name)' from the tracker?"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            
            NSApp.activate(ignoringOtherApps: true)
            
            if alert.runModal() == .alertFirstButtonReturn {
                Logger.log("Removing tool: \(name)")
                self.removeToolFromConfig(name: name)
            }
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
            Logger.log("Config saved successfully")
        } catch {
            Logger.error("Failed to save config: \(error)")
        }
    }
    
    // MARK: - Link Commands
    
    @objc func onRefresh() {
        Logger.log("Manual refresh triggered")
        refreshData()
    }
    
    @objc func onEditConfig() {
        let configPath = NSString(string: "~/.agent-tracker.json").expandingTildeInPath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [configPath]
        task.launch()
        Logger.log("Opened config file")
    }
    
    @objc func onQuit() {
        Logger.log("Agent Tracker quitting...")
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
