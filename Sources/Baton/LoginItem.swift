import BatonCore
import Foundation

/// Open at Login for this copy of Baton: the launch agent, and the program it should start.
struct LoginItem {
    var agent = LaunchAgent()
    var executable = Bundle.main.executablePath ?? CommandLine.arguments[0]

    var isOn: Bool { agent.isInstalled }

    /// Why this copy cannot be the one that opens at login, if it cannot.
    var problem: String? { LaunchAgent.problem(withExecutable: executable) }

    /// Whether the switch can be moved to the other side by this copy.
    var canToggle: Bool { isOn ? LaunchAgent.belongs(toExecutable: executable) : problem == nil }

    /// Only the agent's file is written or removed. launchd reads it at the next login; for the
    /// rest of this session Baton keeps running as it was started.
    func set(_ on: Bool) throws {
        if on {
            if let problem { throw LoginItemError(reason: problem) }
            try agent.install(executable: executable)
        } else {
            guard LaunchAgent.belongs(toExecutable: executable) else {
                throw LoginItemError(reason: problem ?? "this copy of Baton does not own the launch agent")
            }
            try agent.remove()
        }
        log("open at login: \(on ? "on, starting \(executable)" : "off")")
    }

    /// An agent left by an earlier install may start a copy that has since moved, as when Baton
    /// goes from `~/Applications` to `/Applications`. It is pointed at this copy; an agent that
    /// already starts this copy is left exactly as it is.
    func adopt() {
        guard problem == nil else { return }
        do {
            if let old = try agent.correct(executable: executable) {
                log("open at login: now starts \(executable) instead of \(old)")
            }
        } catch {
            log("open at login: could not correct the launch agent: \(error)")
        }
    }

    /// `Baton login [on|off]`: shows or changes Open at Login without the agent running, which
    /// is how `scripts/install-agent.sh` writes the launch agent.
    func run(_ words: [String]) -> Int32 {
        switch words.first {
        case "on", "off":
            guard words.count == 1 else { fallthrough }
            do {
                try set(words[0] == "on")
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                return 1
            }
        case nil:
            break
        default:
            print("usage: Baton login [on|off]")
            return 64
        }
        print("Open at Login is \(isOn ? "on" : "off")" + (agent.executable.map { ": \($0)" } ?? ""))
        return 0
    }
}

struct LoginItemError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}
