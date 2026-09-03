import Foundation

/// Remembered balances, so a prepaid key can be drawn on the same axis as a
/// quota window: percent spent since the highest balance seen in the last
/// thirty days. This is the only thing Usage writes to disk, and it holds
/// amounts only, never a key.
public struct SampleStore: Equatable, Sendable {

    public struct Sample: Equatable, Sendable, Codable {
        public let at: Date
        public let amount: Double
    }

    public static let window: TimeInterval = 30 * 86_400
    /// A repeat of the last amount inside this gap is not a new sample.
    public static let minimumGap: TimeInterval = 10 * 60

    public private(set) var samples: [String: [Sample]]

    public init(samples: [String: [Sample]] = [:]) {
        self.samples = samples
    }

    /// Record one balance and return the percent spent since the window's
    /// peak (nil until there is any spend to show).
    public mutating func record(_ amount: Double, for key: String, at now: Date = Date()) -> Double? {
        var series = samples[key] ?? []
        series.removeAll { now.timeIntervalSince($0.at) > Self.window }
        if let last = series.last, last.amount == amount, now.timeIntervalSince(last.at) < Self.minimumGap {
            // unchanged and recent: keep the series meaningful
        } else {
            series.append(Sample(at: now, amount: amount))
        }
        samples[key] = series
        return percentSpent(amount, in: series)
    }

    public func percentSpent(_ amount: Double, for key: String) -> Double? {
        percentSpent(amount, in: samples[key] ?? [])
    }

    private func percentSpent(_ amount: Double, in series: [Sample]) -> Double? {
        let peak = max(series.map(\.amount).max() ?? amount, amount)
        guard peak > 0, peak > amount else { return nil }
        return (1 - amount / peak) * 100
    }

    // MARK: - Disk

    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Usage/samples.json"
    }

    public static func load(from path: String) -> SampleStore {
        guard let data = FileManager.default.contents(atPath: path),
              let samples = try? decoder.decode([String: [Sample]].self, from: data) else {
            return SampleStore()
        }
        return SampleStore(samples: samples)
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(samples).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
