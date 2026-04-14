import Foundation
import CoreMonitorIPC

public enum CoreMonitorDefaults {
    public static let helperPath = "/Library/PrivilegedHelperTools/\(CoreMonitorIdentity.helperExecutableName)"
    public static let launchDaemonPath = "/Library/LaunchDaemons/\(CoreMonitorIdentity.helperLabel).plist"
    public static let localSupportDirectoryName = "core-monitor-cli"
    public static let localSupportBundlePath = ".local/share/\(localSupportDirectoryName)/CoreMonitorBlessHost.app"
}

public enum SMCKeys {
    public static let cpuTemperatureKeys = [
        "TC0P", "TCXC", "TC0E", "TC0F", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C",
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0b"
    ]

    public static let gpuTemperatureKeys = [
        "TGDD", "TG0P", "TG0D", "TG0E", "TG0F", "Tg0T", "Tg05"
    ]

    public static let totalPowerKeys = ["PSTR", "PC0C"]
}
