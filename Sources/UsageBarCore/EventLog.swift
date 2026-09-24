import Foundation

/// When the app started and how it stopped, one line each, so a Usage that
/// is simply not running can be explained afterwards.
///
/// Added 2026-09-25: the login-item launch of 2026-09-13 ran for three days
/// and was gone by 2026-09-16 with no crash report and nothing in the unified
/// log to say whether it was quit, killed, or crashed. A `launch` line with no
/// `quit` or `terminate` after it now means the process died without AppKit
/// running its shutdown (a kill or a crash, and a crash leaves an `.ips` in
/// ~/Library/Logs/DiagnosticReports).
///
/// The fourth file Usage writes. It holds dates, a pid, a build stamp, and an
/// event word, never a credential, a number, or a reason a source gave.
public enum EventLog {

    /// The newest lines kept; older ones are dropped on write.
    public static let keptLines = 400

    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Usage/events.log"
    }

    /// "2026-09-25T06:54:01Z launch pid=29435 build=4cba9a1".
    public static func line(_ event: String, at date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date) + " " + event
    }

    /// Append one event, keeping only the newest `keptLines`. A failed write
    /// is dropped: the log is evidence, never a reason to stop.
    public static func append(_ event: String, at date: Date = Date(), to path: String = defaultPath()) {
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.split(whereSeparator: \.isNewline).map(String.init)
        lines.append(line(event, at: date))
        if lines.count > keptLines { lines.removeFirst(lines.count - keptLines) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
