import Foundation

/// Last good readings, so the panel shows the last numbers it got on launch
/// before the first poll returns.
///
/// This is the second thing Usage writes to disk (besides `SampleStore`). It
/// holds the same shape a reading shows a provider with: meters and a plan,
/// never a credential or a token, and only readings that actually read OK, so
/// the archive is always "last good", never a failure reason or a status.
public struct ReadingStore: Equatable, Sendable {

    public private(set) var readings: [ProviderReading]

    public init(readings: [ProviderReading] = []) {
        self.readings = readings.filter(Self.carriesData)
    }

    /// Remember a snapshot's good readings, keeping a provider's last numbers
    /// even when the current snapshot shows it as rate-limited or failed, so a
    /// transient failure does not erase the last values it had. Whatever state a
    /// read ended in, the archived reading is a good one: it never carries a
    /// status or reason, only the last numbers and the plan. A sign-in ask is
    /// invalid auth and never rearchived as OK, so the provider goes back to
    /// pending at launch until it is reauthorized.
    public mutating func record(_ snapshot: UsageSnapshot) {
        var current: [ProviderID: ProviderReading] = [:]
        for reading in readings { current[reading.provider] = reading }
        for reading in snapshot.readings {
            if case .signIn = reading.state {
                current[reading.provider] = nil
            } else if Self.carriesData(reading) {
                current[reading.provider] = Self.goodReading(of: reading)
            }
        }
        readings = ProviderID.allCases.compactMap { current[$0] }
    }

    /// A reading is worth archiving when it has something to show: meters or a
    /// plan. A provider never read OK (a pure status) stays out of the archive.
    private static func carriesData(_ reading: ProviderReading) -> Bool {
        !reading.meters.isEmpty || reading.plan != nil
    }

    /// A reading normalized to an OK state: the archive holds numbers and a
    /// plan, never a status or a reason, so it can never carry a token.
    private static func goodReading(of reading: ProviderReading) -> ProviderReading {
        ProviderReading(
            provider: reading.provider,
            state: .ok,
            plan: reading.plan,
            meters: reading.meters,
            readAt: reading.readAt,
            attemptedAt: reading.attemptedAt,
            retryAfterSeconds: nil
        )
    }

    /// The snapshot to show at launch: the last good readings for the
    /// providers we have, pending for the rest. Every archived reading is
    /// presented as stale, not OK, so it is visibly not freshly read and the
    /// header never claims the panel is fully healthy, and each keeps its own
    /// data age.
    public func snapshot() -> UsageSnapshot {
        var byProvider: [ProviderID: ProviderReading] = [:]
        for reading in readings { byProvider[reading.provider] = reading }
        let all = ProviderID.allCases.map { byProvider[$0] ?? .pending($0) }
        let restored = all.map { reading in
            guard reading.state.isOK, reading.readAt != nil else { return reading }
            return ProviderReading(
                provider: reading.provider,
                state: .stale,
                plan: reading.plan,
                meters: reading.meters,
                readAt: reading.readAt,
                attemptedAt: reading.attemptedAt
            )
        }
        // The summary names the oldest restored data, so one recent provider
        // cannot make an older one look fresh. Each row still shows its own age.
        return UsageSnapshot(readings: restored, readAt: readings.compactMap(\.readAt).min())
    }

    // MARK: - Disk

    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Usage/readings.json"
    }

    public static func load(from path: String) -> ReadingStore {
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? decoder.decode([ProviderReading].self, from: data) else {
            return ReadingStore()
        }
        return ReadingStore(readings: list)
    }

    public func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(readings).write(to: url, options: .atomic)
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
