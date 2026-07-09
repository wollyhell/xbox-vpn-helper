import Foundation

struct CommandResult {
    let output: String
    let status: Int32
}

enum CommandError: Error, LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let command):
            return "Не удалось запустить команду: \(command)"
        }
    }
}

enum CommandRunner {
    static func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(([launchPath] + arguments).joined(separator: " "))
        }

        let group = DispatchGroup()
        let outputData = LockedData()
        let errorData = LockedData()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let combined = outputData.get() + errorData.get()
        let output = String(decoding: combined, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        return CommandResult(output: output, status: process.terminationStatus)
    }

    static func runShell(_ script: String) throws -> CommandResult {
        try run("/bin/zsh", ["-lc", script])
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum PrivilegedScriptRunner {
    static func run(script: String) throws -> CommandResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xbox-vpn-helper-\(UUID().uuidString).sh")

        try script.write(to: tempURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempURL.path)

        let appleScript = """
        set scriptPath to POSIX file "\(tempURL.path)"
        do shell script "/bin/bash " & quoted form of POSIX path of scriptPath with administrator privileges
        """

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return try CommandRunner.run("/usr/bin/osascript", ["-e", appleScript])
    }
}
