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

        // Set before `run()`: a handler set later can miss a fast exit, and
        // mutating a running `Process` races its own termination callback.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }

        // Read both pipes while the child runs. A command that fills the 64 KB
        // pipe buffer while we wait for its exit would deadlock otherwise, and
        // `agy --print=/usage` prints a whole JSON document. Each reader owns
        // its own `StreamSink`; the caller reads it only through the lock.
        let outSink = StreamSink()
        let errSink = StreamSink()
        let readers = DispatchGroup()
        for (pipe, sink) in [(out, outSink), (err, errSink)] {
            DispatchQueue.global(qos: .utility).async(group: readers) {
                sink.finish(pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        let finished = exited.wait(timeout: .now() + timeout) == .success

        if !finished {
            // Ask politely, then insist, then reap: the child is gone before
            // this returns, whatever it does with SIGTERM.
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(executable): timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()

        // A grandchild can keep a pipe open after the child exits. Give the
        // readers a moment, then take whatever each one has finished with.
        _ = readers.wait(timeout: .now() + 5)

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outSink.data ?? Data(), as: UTF8.self),
            stderr: String(decoding: errSink.data ?? Data(), as: UTF8.self)
        )
    }
}

/// One stream's bytes, written once by its reader thread and read by the
/// caller. The lock is the single owner of `data`; `nil` means the reader is
/// still blocked on the pipe.
private final class StreamSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func finish(_ data: Data) {
        lock.withLock { stored = data }
    }

    var data: Data? {
        lock.withLock { stored }
    }
}
