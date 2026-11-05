import Foundation

class AgentMonitor {
    let stateMachine: StateMachine
    private var timer: Timer?
    private var lastActive: Date?
    private var lastPid: Int32?
    private var currentAgent: String?

    let agentNames = ["opencode", "claude", "claude-code", "codex", "cursor", "antigravity", "kiro"]

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.fire()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard let (pid, name) = findAgentPID() else {
            lastActive = nil; lastPid = nil; currentAgent = nil
            if stateMachine.state == .thinking || stateMachine.state == .done {
                stateMachine.setState(.idle)
            }
            return
        }
        lastPid = pid; currentAgent = name
        let cpuActive = getCPU(pid: pid) > 12.0

        if cpuActive {
            lastActive = Date()
            if stateMachine.state != .thinking { stateMachine.setState(.thinking) }
        } else {
            if let last = lastActive {
                if Date().timeIntervalSince(last) >= 3.0 {
                    if stateMachine.state == .thinking { stateMachine.triggerDone() }
                    lastActive = nil
                }
            }
        }
    }

    private func findAgentPID() -> (Int32, String)? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["aux"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Filter lines that have a process name matching our agents
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("grep") { continue }
            for name in agentNames {
                // Match " name" (space before process name) at word boundary
                if t.contains(" \(name)") || t.hasSuffix(" \(name)") || t.hasSuffix(" \(name)\n") {
                    let parts = t.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count > 1, let pid = Int32(parts[1]) {
                        return (pid, name)
                    }
                }
            }
        }
        return nil
    }

    private func getCPU(pid: Int32) -> Double {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "%cpu="]
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = Pipe()
        do { try task.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return 0 }
        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
