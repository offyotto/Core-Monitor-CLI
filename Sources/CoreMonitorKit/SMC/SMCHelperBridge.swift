import Foundation
import CoreMonitorIPC

public final class SMCHelperBridge {
    public let helperLabel: String
    public let helperPath: String
    public let launchDaemonPath: String

    private let locator: PrivilegedHelperBundleLocator
    private let timeout: DispatchTimeInterval

    public init(
        helperLabel: String? = nil,
        helperPath: String? = nil,
        launchDaemonPath: String? = nil,
        locator: PrivilegedHelperBundleLocator = PrivilegedHelperBundleLocator(),
        timeout: DispatchTimeInterval = .seconds(5)
    ) {
        let environment = ProcessInfo.processInfo.environment
        self.helperLabel = helperLabel
            ?? environment["CORE_MONITOR_HELPER_LABEL"]
            ?? CoreMonitorIdentity.helperLabel
        self.helperPath = helperPath
            ?? environment["CORE_MONITOR_HELPER_PATH"]
            ?? CoreMonitorDefaults.helperPath
        self.launchDaemonPath = launchDaemonPath
            ?? environment["CORE_MONITOR_LAUNCHD_PLIST"]
            ?? CoreMonitorDefaults.launchDaemonPath
        self.locator = locator
        self.timeout = timeout
    }

    public var blessHostPath: String? {
        locator.blessHostExecutableURL()?.path
    }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: helperPath)
            && FileManager.default.fileExists(atPath: launchDaemonPath)
    }

    public func blessHostIsAvailable() -> Bool {
        blessHostPath != nil
    }

    public func installHelperIfNeeded() throws {
        guard !isInstalled() else { return }
        try invokeBlessHost(arguments: ["install"])
    }

    public func readValue(key: String, installIfNeeded: Bool = true) throws -> Double {
        let response: NSNumber = try performValue(installIfNeeded: installIfNeeded) { proxy, complete in
            proxy.readValue(key) { value, error in
                if let error {
                    complete(nil, error as String)
                } else if let value {
                    complete(value, nil)
                } else {
                    complete(nil, "Helper returned no value for \(key)")
                }
            }
        }
        return response.doubleValue
    }

    public func readOptionalValue(key: String, installIfNeeded: Bool = true) -> Double? {
        try? readValue(key: key, installIfNeeded: installIfNeeded)
    }

    public func fanInfo(installIfNeeded: Bool = true) throws -> [FanInfo] {
        let count = Int(try readValue(key: "FNum", installIfNeeded: installIfNeeded))
        guard count > 0 else { return [] }

        return (0..<count).map { fanID in
            FanInfo(
                id: fanID,
                currentRPM: rpmValue(for: String(format: "F%dAc", fanID), allowZero: true, installIfNeeded: installIfNeeded),
                minimumRPM: rpmValue(for: String(format: "F%dMn", fanID), allowZero: false, installIfNeeded: installIfNeeded),
                maximumRPM: rpmValue(for: String(format: "F%dMx", fanID), allowZero: false, installIfNeeded: installIfNeeded),
                targetRPM: rpmValue(for: String(format: "F%dTg", fanID), allowZero: true, installIfNeeded: installIfNeeded)
            )
        }
    }

    public func setFanManual(id: Int, rpm: Int, leaseSeconds: Int? = nil, installIfNeeded: Bool = true) throws {
        if let leaseSeconds, leaseSeconds > 0 {
            do {
                try performVoid(installIfNeeded: installIfNeeded) { proxy, complete in
                    guard let leased = proxy.setFanManualLease else {
                        complete("lease-unsupported")
                        return
                    }
                    leased(id, rpm, leaseSeconds) { error in
                        complete(error as String?)
                    }
                }
                return
            } catch {
                if let coreError = error as? CoreMonitorError, coreError.message == "lease-unsupported" {
                    // Fall through to the legacy setter for compatibility with older helpers.
                } else {
                    throw error
                }
            }
        }

        try performVoid(installIfNeeded: installIfNeeded) { proxy, complete in
            proxy.setFanManual(id, rpm: rpm) { error in
                complete(error as String?)
            }
        }
    }

    public func setFanAuto(id: Int, installIfNeeded: Bool = true) throws {
        try performVoid(installIfNeeded: installIfNeeded) { proxy, complete in
            proxy.setFanAuto(id) { error in
                complete(error as String?)
            }
        }
    }

    public func resetAllToAutomatic(installIfNeeded: Bool = true) throws {
        try performVoid(installIfNeeded: installIfNeeded) { proxy, complete in
            if let reset = proxy.resetAllToAutomatic {
                reset { error in
                    complete(error as String?)
                }
            } else {
                complete("reset-unsupported")
            }
        }
    }

    private func rpmValue(for key: String, allowZero: Bool, installIfNeeded: Bool) -> Int? {
        guard let raw = readOptionalValue(key: key, installIfNeeded: installIfNeeded) else {
            return nil
        }
        if raw == 0, allowZero {
            return 0
        }
        if !raw.isFinite || raw <= 0 {
            return nil
        }
        if raw < 100 {
            return nil
        }
        if raw > 100_000 {
            return nil
        }
        return Int(raw.rounded())
    }

    private func invokeBlessHost(arguments: [String]) throws {
        guard let executable = locator.blessHostExecutableURL() else {
            throw CoreMonitorError(
                "Bless host bundle not found. Install the support bundle first or set CORE_MONITOR_BLESS_HOST."
            )
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoreMonitorError(message.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : message)
        }
    }

    private func performValue<T>(
        installIfNeeded: Bool,
        _ operation: @escaping (SMCHelperXPCProtocol, @escaping (T?, String?) -> Void) -> Void
    ) throws -> T {
        do {
            return try performValueXPC(operation)
        } catch {
            guard installIfNeeded else { throw error }
            try installHelperIfNeeded()
            return try performValueXPC(operation)
        }
    }

    private func performValueXPC<T>(
        _ operation: @escaping (SMCHelperXPCProtocol, @escaping (T?, String?) -> Void) -> Void
    ) throws -> T {
        let connection = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SMCHelperXPCProtocol.self)

        let semaphore = DispatchSemaphore(value: 0)
        var resolvedValue: T?
        var resolvedError: String?

        connection.invalidationHandler = { semaphore.signal() }
        connection.interruptionHandler = { semaphore.signal() }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            resolvedError = error.localizedDescription
            semaphore.signal()
        }) as? SMCHelperXPCProtocol else {
            connection.invalidate()
            throw CoreMonitorError("Failed to create XPC proxy for \(helperLabel)")
        }

        operation(proxy) { value, error in
            resolvedValue = value
            resolvedError = error
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        connection.invalidate()

        if result == .timedOut {
            throw CoreMonitorError("Timed out waiting for \(helperLabel)")
        }

        if let resolvedError, !resolvedError.isEmpty {
            throw CoreMonitorError(resolvedError)
        }

        guard let resolvedValue else {
            throw CoreMonitorError("No response from \(helperLabel)")
        }
        return resolvedValue
    }

    private func performVoid(
        installIfNeeded: Bool,
        _ operation: @escaping (SMCHelperXPCProtocol, @escaping (String?) -> Void) -> Void
    ) throws {
        do {
            try performVoidXPC(operation)
        } catch {
            guard installIfNeeded else { throw error }
            try installHelperIfNeeded()
            try performVoidXPC(operation)
        }
    }

    private func performVoidXPC(
        _ operation: @escaping (SMCHelperXPCProtocol, @escaping (String?) -> Void) -> Void
    ) throws {
        let connection = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SMCHelperXPCProtocol.self)

        let semaphore = DispatchSemaphore(value: 0)
        var resolvedError: String?
        var completed = false

        connection.invalidationHandler = { semaphore.signal() }
        connection.interruptionHandler = { semaphore.signal() }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            resolvedError = error.localizedDescription
            semaphore.signal()
        }) as? SMCHelperXPCProtocol else {
            connection.invalidate()
            throw CoreMonitorError("Failed to create XPC proxy for \(helperLabel)")
        }

        operation(proxy) { error in
            resolvedError = error
            completed = true
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        connection.invalidate()

        if result == .timedOut {
            throw CoreMonitorError("Timed out waiting for \(helperLabel)")
        }

        if let resolvedError, !resolvedError.isEmpty, resolvedError != "reset-unsupported" {
            throw CoreMonitorError(resolvedError)
        }

        if !completed && resolvedError == nil {
            throw CoreMonitorError("No response from \(helperLabel)")
        }
    }
}
