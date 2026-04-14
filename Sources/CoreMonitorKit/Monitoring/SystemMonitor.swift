import Foundation
#if os(macOS)
import Darwin
import IOKit
import IOKit.ps
#endif

public final class SystemMonitor {
    #if os(macOS)
    private var previousCPULoadInfo = host_cpu_load_info_data_t()
    #endif
    private var hasPreviousCPUInfo = false
    private let helper: SMCHelperBridge

    public init(helper: SMCHelperBridge = SMCHelperBridge()) {
        self.helper = helper
    }

    public func snapshot(installHelperIfNeeded: Bool = false) throws -> SystemSnapshot {
        let cpu = try cpuStats()
        let memory = try memoryStats()
        let disk = try diskStats()
        let battery = batteryStats()

        let fans = (try? helper.fanInfo(installIfNeeded: installHelperIfNeeded)) ?? []
        let cpuTemperature = firstAvailableValue(keys: SMCKeys.cpuTemperatureKeys, installIfNeeded: installHelperIfNeeded)
        let gpuTemperature = firstAvailableValue(keys: SMCKeys.gpuTemperatureKeys, installIfNeeded: installHelperIfNeeded)
        let totalSystemWatts = firstAvailableValue(keys: SMCKeys.totalPowerKeys, installIfNeeded: installHelperIfNeeded)

        return SystemSnapshot(
            timestampISO8601: ISO8601DateFormatter().string(from: Date()),
            cpu: cpu,
            memory: memory,
            disk: disk,
            battery: battery,
            thermal: ThermalStats(
                cpuTemperatureC: cpuTemperature,
                gpuTemperatureC: gpuTemperature,
                totalSystemWatts: totalSystemWatts
            ),
            fans: fans
        )
    }

    private func firstAvailableValue(keys: [String], installIfNeeded: Bool) -> Double? {
        for key in keys {
            if let value = helper.readOptionalValue(key: key, installIfNeeded: installIfNeeded), value > 0 {
                return value
            }
        }
        return nil
    }

    private func cpuStats() throws -> CPUStats {
        #if os(macOS)
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            throw CoreMonitorError("Failed to read CPU usage")
        }

        let usage: Double
        if hasPreviousCPUInfo {
            let userDiff = Double(info.cpu_ticks.0 - previousCPULoadInfo.cpu_ticks.0)
            let sysDiff = Double(info.cpu_ticks.1 - previousCPULoadInfo.cpu_ticks.1)
            let idleDiff = Double(info.cpu_ticks.2 - previousCPULoadInfo.cpu_ticks.2)
            let niceDiff = Double(info.cpu_ticks.3 - previousCPULoadInfo.cpu_ticks.3)
            let total = userDiff + sysDiff + idleDiff + niceDiff
            usage = total > 0 ? ((userDiff + sysDiff + niceDiff) / total) * 100.0 : 0
        } else {
            usage = 0
            hasPreviousCPUInfo = true
        }

        previousCPULoadInfo = info
        return CPUStats(usagePercent: usage)
        #else
        throw CoreMonitorError("CPU monitoring is only available on macOS")
        #endif
    }

    private func memoryStats() throws -> MemoryStats {
        #if os(macOS)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            throw CoreMonitorError("Failed to read memory statistics")
        }

        let pageSize = Double(vm_kernel_page_size)
        let totalBytes = Double(try totalMemoryBytes())
        let freeBytes = Double(stats.free_count) * pageSize
        let activeBytes = Double(stats.active_count) * pageSize
        let inactiveBytes = Double(stats.inactive_count) * pageSize
        let wiredBytes = Double(stats.wire_count) * pageSize
        let compressedBytes = Double(stats.compressor_page_count) * pageSize
        let usedBytes = activeBytes + inactiveBytes + wiredBytes + compressedBytes
        let swapUsedBytes = Double(stats.swapouts) * pageSize

        return MemoryStats(
            usagePercent: totalBytes > 0 ? (usedBytes / totalBytes) * 100.0 : 0,
            usedGB: usedBytes / 1_073_741_824.0,
            totalGB: totalBytes / 1_073_741_824.0,
            freeGB: freeBytes / 1_073_741_824.0,
            swapUsedGB: swapUsedBytes / 1_073_741_824.0
        )
        #else
        throw CoreMonitorError("Memory monitoring is only available on macOS")
        #endif
    }

    private func diskStats() throws -> DiskStats {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        guard
            let total = attributes[.systemSize] as? NSNumber,
            let free = attributes[.systemFreeSize] as? NSNumber
        else {
            throw CoreMonitorError("Failed to read disk stats")
        }

        let totalGB = total.doubleValue / 1_073_741_824.0
        let freeGB = free.doubleValue / 1_073_741_824.0
        let usedGB = max(0, totalGB - freeGB)
        let usagePercent = totalGB > 0 ? (usedGB / totalGB) * 100.0 : 0

        return DiskStats(totalGB: totalGB, usedGB: usedGB, freeGB: freeGB, usagePercent: usagePercent)
    }

    private func batteryStats() -> BatteryStats {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return BatteryStats(hasBattery: false, chargePercent: nil, isCharging: false, isPluggedIn: false, cycleCount: nil, healthPercent: nil)
        }

        let current = description[kIOPSCurrentCapacityKey] as? Int
        let max = description[kIOPSMaxCapacityKey] as? Int
        let chargePercent: Int?
        if let current, let max, max > 0 {
            chargePercent = Int((Double(current) / Double(max) * 100.0).rounded())
        } else {
            chargePercent = nil
        }

        let powerSourceState = description[kIOPSPowerSourceStateKey] as? String
        let isExternal = powerSourceState == kIOPSACPowerValue
        let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false

        return BatteryStats(
            hasBattery: true,
            chargePercent: chargePercent,
            isCharging: isCharging,
            isPluggedIn: isExternal,
            cycleCount: nil,
            healthPercent: nil
        )
        #else
        return BatteryStats(hasBattery: false, chargePercent: nil, isCharging: false, isPluggedIn: false, cycleCount: nil, healthPercent: nil)
        #endif
    }

    #if os(macOS)
    private func totalMemoryBytes() throws -> UInt64 {
        var size = MemoryLayout<UInt64>.size
        var value: UInt64 = 0
        let result = sysctlbyname("hw.memsize", &value, &size, nil, 0)
        guard result == 0 else {
            throw CoreMonitorError("Failed to read hw.memsize")
        }
        return value
    }
    #endif
}
