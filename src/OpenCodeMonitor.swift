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

    private let queue = DispatchQueue(label: "nikxel.agent-monitor", qos: .utility)
    private var busy = false

    func startMonitoring() {
        // One `ps` per tick, off the main thread: it used to be two, every
        // 1.5s, blocking the avatar's frames while they ran.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self = self else { return }
            let found = self.busiestAgent()
            DispatchQueue.main.async { self.busy = false; self.check(found) }
        }
    }

    private func check(_ found: (pid: Int32, name: String, cpu: Double)?) {
        guard let found = found else {
            lastActive = nil; lastPid = nil; currentAgent = nil
            if stateMachine.state == .thinking || stateMachine.state == .done {
                stateMachine.setState(.idle)
            }
            return
        }
        lastPid = found.pid; currentAgent = found.name
        let cpuActive = found.cpu > 12.0

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

    /// The busiest running agent: `ps -r` sorts by CPU, as `ps aux` did.
    private func busiestAgent() -> (pid: Int32, name: String, cpu: Double)? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-Ar", "-o", "pid=,pcpu=,args="]
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("grep") { continue }
            for name in agentNames where t.contains(" \(name)") {
                let parts = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count > 1, let pid = Int32(parts[0]) {
                    return (pid, name, Double(parts[1]) ?? 0)
                }
            }
        }
        return nil
    }
}
