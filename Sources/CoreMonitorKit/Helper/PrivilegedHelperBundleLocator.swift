import Foundation

public struct PrivilegedHelperBundleLocator {
    private let fileManager = FileManager.default

    public init() {}

    public func blessHostExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["CORE_MONITOR_BLESS_HOST"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            executableURL.deletingLastPathComponent()
                .appendingPathComponent("../libexec/CoreMonitorBlessHost.app/Contents/MacOS/core-monitor-bless-host")
                .standardizedFileURL,
            executableURL.deletingLastPathComponent()
                .appendingPathComponent("../CoreMonitorBlessHost.app/Contents/MacOS/core-monitor-bless-host")
                .standardizedFileURL,
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(CoreMonitorDefaults.localSupportBundlePath)
                .appendingPathComponent("Contents/MacOS/core-monitor-bless-host"),
            URL(fileURLWithPath: "/Applications/CoreMonitorBlessHost.app/Contents/MacOS/core-monitor-bless-host")
        ]

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}
