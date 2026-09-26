import Foundation

/// Remembered balances, so a prepaid key can be drawn on the same axis as a
/// quota window: percent spent since the highest balance seen in the last
/// thirty days. This store holds amounts only, never a key; last-good usage
/// readings and rate-limit deadlines live in their own credential-free stores.
public struct SampleStore: Equatable, Sendable {

    public struct Sample: Equatable, Sendable, Codable {
        public let at: Date
        public let amount: Double
    }

    public static let window: TimeInterval = 30 * 86_400
    /// A repeat of the last amount inside this gap is not a new sample.
    public static let minimumGap: TimeInterval = 10 * 60
    // A run of one amount is kept as two samples, when it was first and last
    // seen, so a balance that sits still for weeks does not add a sample every
    // ten minutes (2026-09-26: 1,664 Moonshot samples held 18 amounts). The
    // last-seen time is what keeps that amount in the window, so the peak and
    // the percent are the same as with every repeat kept.

    public private(set) var samples: [String: [Sample]]

    public init(samples: [String: [Sample]] = [:]) {
        self.samples = samples
    }

    /// Record one balance and return the percent spent since the window's
    /// peak (nil until there is any spend to show).
    public mutating func record(_ amount: Double, for key: String, at now: Date = Date()) -> Double? {
        var series = samples[key] ?? []
        series.removeAll { now.timeIntervalSince($0.at) > Self.window }
        if let last = series.last, last.amount == amount {
            if series.count >= 2, series[series.count - 2].amount == amount {
                series[series.count - 1] = Sample(at: now, amount: amount)   // the run was seen again
            } else if now.timeIntervalSince(last.at) >= Self.minimumGap {
                series.append(Sample(at: now, amount: amount))
            }
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
