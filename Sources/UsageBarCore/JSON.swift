import Foundation

/// Defensive reads over a decoded JSON object. Every provider's payload is
/// read this way rather than through `Codable`, because a missing or null
/// field is a normal condition (the account has no such window) and must
/// drop that one row, never the whole reading, and never turn into a
/// reassuring 0.
enum JSON {

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A number, whether the source sent it as a number or as a decimal
    /// string ("12.34"), as DeepSeek does.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespaces)) {
            return parsed.isFinite ? parsed : nil
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A percent clamped to 0…100, or nil when there is no number.
    static func percent(_ value: Any?) -> Double? {
        guard let number = number(value) else { return nil }
        return min(100, max(0, number))
    }

    /// An ISO 8601 instant, with or without fractional seconds.
    static func date(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
