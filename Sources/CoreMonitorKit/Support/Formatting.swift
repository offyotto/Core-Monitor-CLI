import Foundation

public enum Format {
    public static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    public static func gigabytes(_ value: Double) -> String {
        String(format: "%.2f GB", value)
    }

    public static func rpm(_ value: Int) -> String {
        "\(value) RPM"
    }

    public static func temperature(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f°C", value)
    }

    public static func watts(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f W", value)
    }
}
