import Foundation
import Testing
@testable import UsageBarCore

/// The one place a `Process` is built: both streams come back whole, and a
/// command that outlives its timeout is killed and reaped, not left running.
/// Run under `swift test --sanitize=thread` to check the reader threads.
@Suite("Subprocess")
struct SubprocessTests {

    @Test("Both streams come back, read while the child runs")
    func bothStreams() {
        // 200 KB on stdout is past the 64 KB pipe buffer: a reader that waited
        // for exit first would deadlock here.
        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' a; echo oops >&2; exit 3"],
            timeout: 10
        )
        #expect(result.exitCode == 3)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr == "oops\n")
    }

    @Test("A timeout after partial output kills the child and reports it")
    func timeoutAfterPartialOutput() {
        let start = Date()
        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo started; echo warn >&2; exec /bin/sleep 30"],
            timeout: 0.3
        )
        #expect(result.exitCode == -1)
        #expect(result.stderr.contains("timed out"))
        #expect(Date().timeIntervalSince(start) < 5, "the child is killed, not waited out")
    }

    @Test("A child that ignores SIGTERM is still dead when the run returns")
    func timeoutKillsStubbornChild() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("subprocess-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo $$ > \"$0\"; trap '' TERM; exec /bin/sleep 30", pidFile.path],
            timeout: 0.3
        )
        #expect(result.exitCode == -1)

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Reaped, not a zombie and not running: the pid no longer exists.
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("A grandchild holding the pipe open cannot hold the caller")
    func grandchildHoldsPipe() {
        // The shell exits at once, but the background sleep inherits stdout
        // and keeps the pipe open. The run must return on the child's exit
        // and not race the reader that is still blocked on that pipe.
        let start = Date()
        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo early; (/bin/sleep 3; echo late) & exec /bin/sleep 20"],
            timeout: 0.3
        )
        #expect(result.exitCode == -1)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("Many timeouts in parallel stay clean")
    func parallelTimeouts() async {
        await withTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    Subprocess.run(
                        executable: "/bin/sh",
                        arguments: ["-c", "echo x; echo y >&2; exec /bin/sleep 10"],
                        timeout: 0.2
                    )
                }
            }
            for await result in group {
                #expect(result.exitCode == -1)
            }
        }
    }
}
