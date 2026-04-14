import Foundation
import CoreMonitorIPC

public struct CPUStats: Codable, Sendable {
    public let usagePercent: Double
}

public struct MemoryStats: Codable, Sendable {
    public let usagePercent: Double
    public let usedGB: Double
    public let totalGB: Double
    public let freeGB: Double
    public let swapUsedGB: Double
}

public struct DiskStats: Codable, Sendable {
    public let totalGB: Double
    public let usedGB: Double
    public let freeGB: Double
    public let usagePercent: Double
}

public struct BatteryStats: Codable, Sendable {
    public let hasBattery: Bool
    public let chargePercent: Int?
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let cycleCount: Int?
    public let healthPercent: Int?
}

public struct ThermalStats: Codable, Sendable {
    public let cpuTemperatureC: Double?
    public let gpuTemperatureC: Double?
    public let totalSystemWatts: Double?
}

public struct SystemSnapshot: Codable, Sendable {
    public let timestampISO8601: String
    public let cpu: CPUStats
    public let memory: MemoryStats
    public let disk: DiskStats
    public let battery: BatteryStats
    public let thermal: ThermalStats
    public let fans: [FanInfo]
}
