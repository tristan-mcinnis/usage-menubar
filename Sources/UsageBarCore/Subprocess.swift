import Foundation

/// The result of one command: its exit status and both streams as text.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The one place in Usage a `Process` is built.
///
/// Every call passes an executable path and an argument array. Nothing is ever
/// handed to a shell, so a file name with a space, a quote, or a semicolon in
/// it is an argument and can never become syntax. Callers run this off the
/// main thread; the panel never blocks on a subprocess.
public enum Subprocess {

    /// Run `executable` with `arguments` and wait for it.
    ///
    /// `NO_COLOR` is always set: every house CLI drops its ANSI escapes when it
    /// sees it, so what comes back is the plain words a parser can read.
    /// A command that outlives `timeout` is terminated and reported as a
    /// failure, so a wedged CLI cannot pin a polling task forever.
    public static func run(
        executable: String,
        arguments: [String],
        environment extra: [String: String] = [:],
        timeout: TimeInterval = 30
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }

        // Read both pipes on their own threads. A command that fills the 64 KB
        // pipe buffer while we wait on `waitUntilExit` would deadlock
        // otherwise, and `agy --print=/usage` prints a whole JSON document.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(out, { outData = $0 }), (err, { errData = $0 })] as [(Pipe, (Data) -> Void)] {
            DispatchQueue.global(qos: .utility).async(group: group) {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        let deadline = DispatchTime.now() + timeout
        let finished = DispatchQueue.global(qos: .utility).sync { () -> Bool in
            let waiter = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                waiter.signal()
            }
            return waiter.wait(timeout: deadline) == .success
        }
        if !finished {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(executable): timed out after \(Int(timeout))s")
        }
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
