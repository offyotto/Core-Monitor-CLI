import Foundation

public enum JSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CoreMonitorError("Failed to encode JSON as UTF-8")
        }
        return string
    }
}
