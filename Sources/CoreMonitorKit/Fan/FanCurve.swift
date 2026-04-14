import Foundation

public struct FanCurve: Codable {
    public struct CurvePoint: Codable {
        public let temperatureC: Double
        public let speedPercent: Double

        public init(temperatureC: Double, speedPercent: Double) {
            self.temperatureC = temperatureC
            self.speedPercent = speedPercent
        }
    }

    public struct PowerBoost: Codable {
        public let enabled: Bool
        public let wattsAtMaxBoost: Double
        public let maxAddedTemperatureC: Double

        public init(enabled: Bool, wattsAtMaxBoost: Double, maxAddedTemperatureC: Double) {
            self.enabled = enabled
            self.wattsAtMaxBoost = wattsAtMaxBoost
            self.maxAddedTemperatureC = maxAddedTemperatureC
        }
    }

    public let name: String
    public let sensor: SensorKind
    public let updateIntervalSeconds: Double
    public let minimumRPM: Int?
    public let maximumRPM: Int?
    public let powerBoost: PowerBoost?
    public let points: [CurvePoint]

    public init(
        name: String,
        sensor: SensorKind,
        updateIntervalSeconds: Double,
        minimumRPM: Int?,
        maximumRPM: Int?,
        powerBoost: PowerBoost?,
        points: [CurvePoint]
    ) {
        self.name = name
        self.sensor = sensor
        self.updateIntervalSeconds = updateIntervalSeconds
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.powerBoost = powerBoost
        self.points = points
    }

    public func interpolatedSpeedPercent(for temperature: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temperature <= first.temperatureC { return first.speedPercent }
        if temperature >= last.temperatureC { return last.speedPercent }

        for index in 0..<(points.count - 1) {
            let left = points[index]
            let right = points[index + 1]
            guard temperature >= left.temperatureC, temperature <= right.temperatureC else { continue }
            let span = right.temperatureC - left.temperatureC
            guard span > 0 else { return right.speedPercent }
            let ratio = (temperature - left.temperatureC) / span
            return left.speedPercent + (right.speedPercent - left.speedPercent) * ratio
        }

        return last.speedPercent
    }

    public func validated() throws -> FanCurve {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreMonitorError("Curve name cannot be empty")
        }
        guard points.count >= 2 else {
            throw CoreMonitorError("Curve needs at least two points")
        }
        var lastTemperature = -Double.infinity
        for point in points {
            guard point.temperatureC >= 0, point.temperatureC <= 120 else {
                throw CoreMonitorError("Curve temperatures must be between 0 and 120°C")
            }
            guard point.speedPercent >= 0, point.speedPercent <= 100 else {
                throw CoreMonitorError("Curve speed percentages must be between 0 and 100")
            }
            guard point.temperatureC > lastTemperature else {
                throw CoreMonitorError("Curve temperatures must be strictly increasing")
            }
            lastTemperature = point.temperatureC
        }
        return self
    }

    public static func load(from filePath: String) throws -> FanCurve {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FanCurve.self, from: data).validated()
    }
}
