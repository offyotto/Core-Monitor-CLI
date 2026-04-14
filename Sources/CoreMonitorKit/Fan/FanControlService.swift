import Foundation
import CoreMonitorIPC

public enum FanMode: String, Codable, Sendable {
    case silent
    case balanced
    case performance
    case max
    case smart
    case curve
}

public enum SensorKind: String, Codable, Sendable {
    case cpu
    case gpu
    case max
}

public final class FanControlService {
    private let helper: SMCHelperBridge
    private let monitor: SystemMonitor

    public init(helper: SMCHelperBridge = SMCHelperBridge(), monitor: SystemMonitor? = nil) {
        self.helper = helper
        self.monitor = monitor ?? SystemMonitor(helper: helper)
    }

    public func fans(installHelperIfNeeded: Bool = true) throws -> [FanInfo] {
        try helper.fanInfo(installIfNeeded: installHelperIfNeeded)
    }

    public func setAuto(fanID: Int?) throws {
        let targetFans = try resolveFanIDs(singleFanID: fanID)
        for id in targetFans {
            try helper.setFanAuto(id: id)
        }
    }

    public func setManual(fanID: Int?, rpm: Int, leaseSeconds: Int? = nil) throws {
        guard (500...10_000).contains(rpm) else {
            throw CoreMonitorError("RPM must be between 500 and 10000")
        }

        let targetFans = try resolveFanIDs(singleFanID: fanID)
        for id in targetFans {
            try helper.setFanManual(id: id, rpm: rpm, leaseSeconds: leaseSeconds)
        }
    }

    public func apply(mode: FanMode, fanID: Int? = nil, curve: FanCurve? = nil, leaseSeconds: Int? = nil) throws {
        switch mode {
        case .silent:
            try setAuto(fanID: fanID)
        case .balanced:
            try applyFixedPercent(0.60, fanID: fanID, leaseSeconds: leaseSeconds)
        case .performance:
            try applyFixedPercent(0.85, fanID: fanID, leaseSeconds: leaseSeconds)
        case .max:
            try applyFixedPercent(1.0, fanID: fanID, leaseSeconds: leaseSeconds)
        case .smart:
            try applySmart(fanID: fanID, leaseSeconds: leaseSeconds)
        case .curve:
            guard let curve else {
                throw CoreMonitorError("Curve mode requires a FanCurve")
            }
            try apply(curve: curve, fanID: fanID, leaseSeconds: leaseSeconds)
        }
    }

    public func watch(mode: FanMode, fanID: Int? = nil, interval: TimeInterval, curve: FanCurve? = nil) throws {
        let loopInterval: TimeInterval
        if mode == .curve, let curve {
            loopInterval = max(0.5, curve.updateIntervalSeconds)
        } else {
            loopInterval = max(0.5, interval)
        }

        let leaseSeconds = max(Int(ceil(loopInterval * 3)), 10)
        while true {
            try apply(mode: mode, fanID: fanID, curve: curve, leaseSeconds: leaseSeconds)
            Thread.sleep(forTimeInterval: loopInterval)
        }
    }

    private func applyFixedPercent(_ percent: Double, fanID: Int?, leaseSeconds: Int?) throws {
        let targetFans = try resolveFanIDs(singleFanID: fanID)
        let fanMap = Dictionary(uniqueKeysWithValues: try fans().map { ($0.id, $0) })
        for id in targetFans {
            let bounds = bounds(for: id, fanMap: fanMap)
            let target = Int((Double(bounds.maximum - bounds.minimum) * percent + Double(bounds.minimum)).rounded())
            try helper.setFanManual(id: id, rpm: target, leaseSeconds: leaseSeconds)
        }
    }

    private func applySmart(fanID: Int?, leaseSeconds: Int?) throws {
        let snapshot = try monitor.snapshot(installHelperIfNeeded: true)
        let cpu = snapshot.thermal.cpuTemperatureC ?? 0
        let gpu = snapshot.thermal.gpuTemperatureC ?? 0
        let maxTemp = max(cpu, gpu)
        guard maxTemp > 0 else {
            throw CoreMonitorError("No valid CPU or GPU temperature is available for smart mode")
        }

        let systemWatts = abs(snapshot.thermal.totalSystemWatts ?? 0)
        let wattBoost = min(1.0, systemWatts / 40.0) * 8.0
        let effectiveTemp = min(maxTemp + wattBoost, 105.0)

        let tempFloor = 35.0
        let tempCeiling = 92.0
        let ratio = max(0.0, min(1.0, (effectiveTemp - tempFloor) / (tempCeiling - tempFloor)))

        let targetFans = try resolveFanIDs(singleFanID: fanID)
        let fanMap = Dictionary(uniqueKeysWithValues: snapshot.fans.map { ($0.id, $0) })
        for id in targetFans {
            let bounds = bounds(for: id, fanMap: fanMap)
            let target = Int((Double(bounds.minimum) + (Double(bounds.maximum - bounds.minimum) * ratio)).rounded())
            try helper.setFanManual(id: id, rpm: target, leaseSeconds: leaseSeconds)
        }
    }

    private func apply(curve: FanCurve, fanID: Int?, leaseSeconds: Int?) throws {
        let snapshot = try monitor.snapshot(installHelperIfNeeded: true)
        let baseTemperature: Double
        switch curve.sensor {
        case .cpu:
            baseTemperature = snapshot.thermal.cpuTemperatureC ?? 0
        case .gpu:
            baseTemperature = snapshot.thermal.gpuTemperatureC ?? 0
        case .max:
            baseTemperature = max(snapshot.thermal.cpuTemperatureC ?? 0, snapshot.thermal.gpuTemperatureC ?? 0)
        }

        guard baseTemperature > 0 else {
            throw CoreMonitorError("No valid temperature is available for curve mode")
        }

        let effectiveTemperature: Double
        if let boost = curve.powerBoost, boost.enabled {
            let watts = abs(snapshot.thermal.totalSystemWatts ?? 0)
            let ratio = min(max(watts / max(boost.wattsAtMaxBoost, 0.1), 0), 1)
            effectiveTemperature = min(baseTemperature + (ratio * boost.maxAddedTemperatureC), 120.0)
        } else {
            effectiveTemperature = baseTemperature
        }

        let percent = max(0, min(100, curve.interpolatedSpeedPercent(for: effectiveTemperature))) / 100.0
        let targetFans = try resolveFanIDs(singleFanID: fanID)
        let fanMap = Dictionary(uniqueKeysWithValues: snapshot.fans.map { ($0.id, $0) })
        for id in targetFans {
            let detectedBounds = bounds(for: id, fanMap: fanMap)
            let minimumRPM = max(curve.minimumRPM ?? detectedBounds.minimum, detectedBounds.minimum)
            let maximumRPM = min(curve.maximumRPM ?? detectedBounds.maximum, detectedBounds.maximum)
            let target = Int((Double(minimumRPM) + (Double(maximumRPM - minimumRPM) * percent)).rounded())
            try helper.setFanManual(id: id, rpm: target, leaseSeconds: leaseSeconds)
        }
    }

    private func resolveFanIDs(singleFanID: Int?) throws -> [Int] {
        let currentFans = try fans()
        guard !currentFans.isEmpty else {
            throw CoreMonitorError("No fan data is available")
        }

        if let singleFanID {
            guard currentFans.contains(where: { $0.id == singleFanID }) else {
                throw CoreMonitorError("Fan \(singleFanID) does not exist on this Mac")
            }
            return [singleFanID]
        }
        return currentFans.map(\.id)
    }

    private func bounds(for fanID: Int, fanMap: [Int: FanInfo]) -> (minimum: Int, maximum: Int) {
        let info = fanMap[fanID]
        let minimum = info?.minimumRPM ?? 1200
        let maximum = info?.maximumRPM ?? 7200
        return (minimum: minimum, maximum: max(maximum, minimum + 500))
    }
}
