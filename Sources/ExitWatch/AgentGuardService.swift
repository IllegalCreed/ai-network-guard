import AppKit
import Darwin
import Foundation

enum GuardedAgent: String, CaseIterable, Sendable {
    case claudeCode
    case chatGPT

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .chatGPT: return "ChatGPT"
        }
    }
}

struct GuardedAgentProcess: Identifiable, Hashable, Sendable {
    let pid: Int32
    let agent: GuardedAgent
    let command: String

    var id: String { "\(agent.rawValue)-\(pid)" }
    var displayName: String { agent.displayName }
}

struct AgentTerminationOutcome: Sendable {
    let discovered: [GuardedAgentProcess]
    let gracefullyTerminated: [GuardedAgentProcess]
    let forceTerminated: [GuardedAgentProcess]
    let failed: [GuardedAgentProcess]

    var terminated: [GuardedAgentProcess] {
        gracefullyTerminated + forceTerminated
    }
}

/// Finds only the named agent processes belonging to the current user, then
/// requests a normal shutdown before using SIGKILL as a last resort. The
/// service deliberately does not match Terminal, VS Code, browser helpers, or
/// arbitrary processes that merely contain the words “ChatGPT”/“Claude”.
@MainActor
final class AgentGuardService {
    private let gracefulWaitNanoseconds: UInt64 = 900_000_000

    func listAgents() -> [GuardedAgentProcess] {
        runningAgents()
    }

    func terminateAgents() async -> AgentTerminationOutcome {
        let discovered = runningAgents()
        guard !discovered.isEmpty else {
            return AgentTerminationOutcome(
                discovered: [],
                gracefullyTerminated: [],
                forceTerminated: [],
                failed: []
            )
        }

        var gracefullyTerminated: [GuardedAgentProcess] = []
        var failed: [GuardedAgentProcess] = []

        for process in discovered {
            guard process.pid != getpid() else { continue }
            if let application = NSRunningApplication(processIdentifier: process.pid),
               application.bundleIdentifier == "com.openai.codex" {
                if application.terminate() {
                    gracefullyTerminated.append(process)
                } else if kill(process.pid, SIGTERM) == 0 {
                    gracefullyTerminated.append(process)
                } else {
                    failed.append(process)
                }
            } else if kill(process.pid, SIGTERM) == 0 {
                gracefullyTerminated.append(process)
            } else {
                failed.append(process)
            }
        }

        do {
            try await Task.sleep(nanoseconds: gracefulWaitNanoseconds)
        } catch {
            // The user may switch the option off while the graceful shutdown
            // window is open. Do not escalate to SIGKILL in that case.
            return AgentTerminationOutcome(
                discovered: discovered,
                gracefullyTerminated: gracefullyTerminated,
                forceTerminated: [],
                failed: failed
            )
        }

        let requestedPIDs = Set(discovered.map(\.pid))
        let stillRunning = runningAgents().filter { requestedPIDs.contains($0.pid) }
        var forceTerminated: [GuardedAgentProcess] = []

        for process in stillRunning {
            guard process.pid != getpid() else { continue }
            if kill(process.pid, SIGKILL) == 0 {
                forceTerminated.append(process)
            } else if !failed.contains(where: { $0.pid == process.pid }) {
                failed.append(process)
            }
        }

        return AgentTerminationOutcome(
            discovered: discovered,
            gracefullyTerminated: gracefullyTerminated,
            forceTerminated: forceTerminated,
            failed: failed
        )
    }

    private func runningAgents() -> [GuardedAgentProcess] {
        let values = parseProcessTable()
        var seen = Set<Int32>()
        return values.filter { seen.insert($0.pid).inserted }
    }

    private func parseProcessTable() -> [GuardedAgentProcess] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid=,args="]
        process.standardOutput = pipe

        let data: Data
        do {
            try process.run()
            // Drain stdout while ps is running; the full command table can
            // exceed a pipe's buffer if we wait for exit first.
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let currentUID = String(getuid())
        var values: [GuardedAgentProcess] = []

        for line in output.split(separator: "\n") {
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  String(fields[1]) == currentUID else {
                continue
            }

            let command = String(fields[2])
            if Self.isChatGPTMain(command) {
                values.append(GuardedAgentProcess(pid: pid, agent: .chatGPT, command: command))
            } else if Self.isClaudeCode(command) {
                values.append(GuardedAgentProcess(pid: pid, agent: .claudeCode, command: command))
            }
        }

        return values
    }

    private static func isChatGPTMain(_ command: String) -> Bool {
        command.lowercased().contains("/chatgpt.app/contents/macos/chatgpt")
    }

    private static func isClaudeCode(_ command: String) -> Bool {
        let lowerCommand = command.lowercased()
        if lowerCommand.contains("/@anthropic-ai/claude-code/") ||
            lowerCommand.contains("/anthropic.claude-code/") {
            return true
        }

        let executable = command
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)?
            .lowercased() ?? ""

        guard executable == "claude" ||
            executable == "claude-code" ||
            executable.hasSuffix("/claude") ||
            executable.hasSuffix("/claude-code") else {
            return false
        }

        return !executable.contains("/claude.app/")
    }
}
