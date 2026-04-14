import Foundation

public enum CoreMonitorIdentity {
    public static let cliBundleIdentifier = "CoreTools.Core-Monitor-CLI"
    public static let blessHostBundleIdentifier = "CoreTools.Core-Monitor-CLI.BlessHost"
    public static let helperLabel = "ventaphobia.smc-helper"
    public static let helperExecutableName = "ventaphobia.smc-helper"
}

public struct FanInfo: Codable, Sendable {
    public let id: Int
    public let currentRPM: Int?
    public let minimumRPM: Int?
    public let maximumRPM: Int?
    public let targetRPM: Int?

    public init(
        id: Int,
        currentRPM: Int?,
        minimumRPM: Int?,
        maximumRPM: Int?,
        targetRPM: Int?
    ) {
        self.id = id
        self.currentRPM = currentRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
    }
}

@objc public protocol SMCHelperXPCProtocol {
    func setFanManual(_ fanID: Int, rpm: Int, withReply reply: @escaping (NSString?) -> Void)
    func setFanAuto(_ fanID: Int, withReply reply: @escaping (NSString?) -> Void)
    func readValue(_ key: String, withReply reply: @escaping (NSNumber?, NSString?) -> Void)
    @objc optional func setFanManualLease(
        _ fanID: Int,
        rpm: Int,
        leaseSeconds: Int,
        withReply reply: @escaping (NSString?) -> Void
    )
    @objc optional func resetAllToAutomatic(withReply reply: @escaping (NSString?) -> Void)
}
