import Darwin
import Foundation

extension CmuxTopProcessSnapshot {
    /// Verifies one foreground PID without enumerating the process table.
    ///
    /// Identity comes from the kernel-reported executable path
    /// (`proc_pidpath`), never from user-controlled argv[0], so a process
    /// cannot impersonate an agent by forging its argument vector. Fails
    /// closed when the executable path cannot be resolved.
    nonisolated static func promptAgentDefinition(
        foregroundPID: Int
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        guard let details = processArgumentsAndEnvironment(for: foregroundPID),
              let executablePath = executablePath(for: foregroundPID) else {
            return nil
        }
        let definition = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: (executablePath as NSString).lastPathComponent,
            processPath: executablePath,
            arguments: details.arguments,
            environment: details.environment
        )
        guard definition?.promptTurnDetection != nil else {
            return nil
        }
        return definition
    }

    /// The coding agent (Claude Code, Codex, …) that `foregroundPID` is, by
    /// the same kernel-reported identity as `promptAgentDefinition`, but for
    /// any agent definition (not only prompt-line-detected ones). Used by the
    /// semantic-mode overlay to know when Claude Code or Codex owns a terminal.
    nonisolated static func codingAgentDefinition(
        foregroundPID: Int
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        guard let details = processArgumentsAndEnvironment(for: foregroundPID),
              let executablePath = executablePath(for: foregroundPID) else {
            return nil
        }
        return CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: (executablePath as NSString).lastPathComponent,
            processPath: executablePath,
            arguments: details.arguments,
            environment: details.environment
        )
    }

    private nonisolated static func executablePath(for pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
