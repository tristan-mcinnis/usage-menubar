import Foundation
import XCTest

/// The publish scrub runs with the tests, so a personal path, a private note
/// path, or key material in a tracked file fails `swift test`.
final class PublishScrubTests: XCTestCase {

    func testTrackedFilesCarryNoPrivateContent() throws {
        // Tests/UsageBarCoreTests/PublishScrubTests.swift -> package root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Tests/scrub.sh")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            throw XCTSkip("not a git checkout; the scrub reads git ls-files")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("SCRUB_CLEAN"), text)
    }
}
