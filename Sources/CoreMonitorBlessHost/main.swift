import Foundation
import Security
import ServiceManagement
import CoreMonitorIPC

private struct BlessHostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum Command: String {
    case install
    case status
}

private struct BlessHost {
    private let helperLabel = CoreMonitorIdentity.helperLabel
    private let helperPath = "/Library/PrivilegedHelperTools/\(CoreMonitorIdentity.helperExecutableName)"
    private let launchDaemonPath = "/Library/LaunchDaemons/\(CoreMonitorIdentity.helperLabel).plist"

    func run(arguments: [String]) throws {
        guard let command = arguments.dropFirst().first.flatMap(Command.init(rawValue:)) else {
            printUsage()
            return
        }

        switch command {
        case .install:
            try install(force: arguments.contains("--force"))
        case .status:
            try status()
        }
    }

    private func install(force: Bool) throws {
        guard hasBlessMetadataConfigured() else {
            throw BlessHostError(
                "SMPrivilegedExecutables is missing \(helperLabel) in \(Bundle.main.bundlePath)/Contents/Info.plist"
            )
        }

        if !force, FileManager.default.fileExists(atPath: helperPath), FileManager.default.fileExists(atPath: launchDaemonPath) {
            print("Privileged helper already installed at \(helperPath)")
            return
        }

        var authRef: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]

        let authStatus: OSStatus = kSMRightBlessPrivilegedHelper.withCString { rightName in
            var authItem = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &authItem) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCreate(&rights, nil, flags, &authRef)
            }
        }

        guard authStatus == errAuthorizationSuccess, let authRef else {
            throw BlessHostError("Failed to create authorization reference (\(authStatus))")
        }
        defer { AuthorizationFree(authRef, []) }

        var blessError: Unmanaged<CFError>?
        let blessed = SMJobBless(kSMDomainSystemLaunchd, helperLabel as CFString, authRef, &blessError)
        if blessed {
            print("Privileged helper installed at \(helperPath)")
            return
        }

        let message = (blessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "SMJobBless failed"
        throw BlessHostError(message)
    }

    private func status() throws {
        print("bundle path: \(Bundle.main.bundlePath)")
        print("bundle identifier: \(Bundle.main.bundleIdentifier ?? "n/a")")
        print("helper label: \(helperLabel)")
        print("helper path: \(helperPath)")
        print("launch daemon path: \(launchDaemonPath)")
        print("smprivileged config: \(hasBlessMetadataConfigured() ? "yes" : "no")")
        print("helper installed: \(FileManager.default.fileExists(atPath: helperPath) ? "yes" : "no")")
        print("launch daemon installed: \(FileManager.default.fileExists(atPath: launchDaemonPath) ? "yes" : "no")")
    }

    private func hasBlessMetadataConfigured() -> Bool {
        guard let privileged = Bundle.main.infoDictionary?["SMPrivilegedExecutables"] as? [String: String] else {
            return false
        }
        return privileged[helperLabel] != nil
    }

    private func printUsage() {
        print(
            """
            core-monitor-bless-host

            Commands:
              core-monitor-bless-host install [--force]
              core-monitor-bless-host status
            """
        )
    }
}

do {
    try BlessHost().run(arguments: CommandLine.arguments)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
