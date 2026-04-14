import Foundation
import IOKit
import Security
import CoreMonitorIPC

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum FanWriteMode {
    case perFanMode(String)
    case legacyForceMask
}

private struct LeaseRecord: Codable {
    let fanID: Int
    let expiresAt: Date
}

private struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class LeaseStateStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> [Int: LeaseRecord] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }

        let records = (try? decoder.decode([LeaseRecord].self, from: data)) ?? []
        return Dictionary(uniqueKeysWithValues: records.map { ($0.fanID, $0) })
    }

    func save(_ leases: [Int: LeaseRecord]) {
        lock.lock()
        defer { lock.unlock() }

        let records = leases.values.sorted(by: { $0.fanID < $1.fanID })
        guard let data = try? encoder.encode(records) else { return }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

private final class SMCController {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyDataInfo] = [:]

    private let smcReadBytes: UInt8 = 5
    private let smcWriteBytes: UInt8 = 6
    private let smcReadKeyInfo: UInt8 = 9
    private let kernelIndexSmc: UInt32 = 2

    private let typeFpe2 = fourCharCode(from: "fpe2")
    private let typeFlt = fourCharCode(from: "flt ")
    private let typeUi8 = fourCharCode(from: "ui8 ")
    private let typeUi16 = fourCharCode(from: "ui16")
    private let typeSp78 = fourCharCode(from: "sp78")
    private let legacyForceMaskKey = "FS! "

    private let cpuTemperatureKeys = [
        "TC0P", "TCXC", "TC0E", "TC0F", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C",
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0b"
    ]

    private let gpuTemperatureKeys = [
        "TGDD", "TG0P", "TG0D", "TG0E", "TG0F", "Tg0T", "Tg05"
    ]

    private let totalPowerKeys = ["PSTR", "PC0C"]

    deinit {
        close()
    }

    func open() throws {
        if connection != 0 { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw HelperError("AppleSMC service not found")
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw HelperError("Failed to open AppleSMC (\(result))")
        }
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    func readValue(_ key: String) throws -> Double {
        let keyCode = fourCharCode(from: key)
        let keyInfo = try getKeyInfo(keyCode)

        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = smcReadBytes

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSmc,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess, output.result == 0 else {
            throw HelperError("SMC read failed for \(key) (\(result))")
        }

        guard let parsed = parse(bytes: output.bytes, dataType: keyInfo.dataType, dataSize: keyInfo.dataSize) else {
            throw HelperError("Unsupported SMC type for \(key)")
        }
        return parsed
    }

    func readOptionalValue(_ key: String) -> Double? {
        try? readValue(key)
    }

    func numberOfFans() -> Int {
        if let explicit = readOptionalValue("FNum").map(Int.init), explicit > 0 {
            return explicit
        }

        var count = 0
        for fanID in 0..<12 {
            let key = String(format: "F%dAc", fanID)
            guard readOptionalValue(key) != nil else { break }
            count += 1
        }
        return count
    }

    func availableFanIDs() -> [Int] {
        Array(0..<numberOfFans())
    }

    func fanBounds(for fanID: Int) throws -> (minimum: Int, maximum: Int) {
        try validateFanID(fanID)
        let minimum = normalizedRPM(readOptionalValue(String(format: "F%dMn", fanID)), allowZero: false)
        let maximum = normalizedRPM(readOptionalValue(String(format: "F%dMx", fanID)), allowZero: false)

        guard let minimum, let maximum else {
            throw HelperError("Unable to resolve fan \(fanID) RPM limits")
        }
        guard maximum > minimum else {
            throw HelperError("Fan \(fanID) reported invalid RPM bounds")
        }
        return (minimum, maximum)
    }

    func setFanManual(_ fanID: Int, rpm: Int) throws {
        try validateFanID(fanID)
        let bounds = try fanBounds(for: fanID)
        let clampedRPM = min(max(rpm, bounds.minimum), bounds.maximum)

        switch try fanWriteMode(for: fanID) {
        case .perFanMode(let modeKey):
            try unlockFansIfNeeded(for: fanID)
            try writeValue(key: modeKey, value: 1)
            try writeValue(key: String(format: "F%dTg", fanID), value: clampedRPM)
        case .legacyForceMask:
            try updateLegacyForceMask(for: fanID, enabled: true)
            try writeValue(key: String(format: "F%dTg", fanID), value: clampedRPM)
        }
    }

    func setFanAuto(_ fanID: Int) throws {
        try validateFanID(fanID)

        switch try fanWriteMode(for: fanID) {
        case .perFanMode(let modeKey):
            try writeValue(key: modeKey, value: 0)
            try? writeValue(key: String(format: "F%dTg", fanID), value: 0)
            if hasKey("Ftst") {
                try? writeValue(key: "Ftst", value: 0)
            }
        case .legacyForceMask:
            try updateLegacyForceMask(for: fanID, enabled: false)
        }
    }

    func resetAllToAutomatic() {
        for fanID in availableFanIDs() {
            try? setFanAuto(fanID)
        }
    }

    func firstAvailableTemperature(keys: [String]) -> Double? {
        for key in keys {
            if let value = readOptionalValue(key), value > 0 {
                return value
            }
        }
        return nil
    }

    func diagnosticSnapshot() -> [String: Double?] {
        [
            "cpuTemperatureC": firstAvailableTemperature(keys: cpuTemperatureKeys),
            "gpuTemperatureC": firstAvailableTemperature(keys: gpuTemperatureKeys),
            "totalSystemWatts": firstAvailableTemperature(keys: totalPowerKeys)
        ]
    }

    private func validateFanID(_ fanID: Int) throws {
        guard availableFanIDs().contains(fanID) else {
            throw HelperError("Fan \(fanID) does not exist on this Mac")
        }
    }

    private func fanWriteMode(for fanID: Int) throws -> FanWriteMode {
        let lower = String(format: "F%dmd", fanID)
        if hasKey(lower) {
            return .perFanMode(lower)
        }

        let upper = String(format: "F%dMd", fanID)
        if hasKey(upper) {
            return .perFanMode(upper)
        }

        if hasKey(legacyForceMaskKey) {
            return .legacyForceMask
        }

        throw HelperError("No supported fan control key found for fan \(fanID)")
    }

    private func unlockFansIfNeeded(for fanID: Int) throws {
        if hasKey("Ftst") {
            try? writeValue(key: "Ftst", value: 1)
            Thread.sleep(forTimeInterval: 0.25)
        }

        let modeKey: String
        switch try fanWriteMode(for: fanID) {
        case .perFanMode(let key):
            modeKey = key
        case .legacyForceMask:
            return
        }

        var lastError: Error?
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            do {
                try writeValue(key: modeKey, value: 1)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func updateLegacyForceMask(for fanID: Int, enabled: Bool) throws {
        let currentMask = Int(try readValue(legacyForceMaskKey))
        let bit = 1 << fanID
        let nextMask = enabled ? (currentMask | bit) : (currentMask & ~bit)
        try writeValue(key: legacyForceMaskKey, value: nextMask)
    }

    private func hasKey(_ key: String) -> Bool {
        (try? getKeyInfo(fourCharCode(from: key))) != nil
    }

    private func writeValue(key: String, value: Int) throws {
        let keyCode = fourCharCode(from: key)
        let keyInfo = try getKeyInfo(keyCode)
        let encoded = try encode(value: value, dataType: keyInfo.dataType, dataSize: keyInfo.dataSize)

        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = smcWriteBytes
        input.bytes = encoded

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSmc,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess, output.result == 0 else {
            throw HelperError("SMC write failed for \(key) (\(result))")
        }
    }

    private func getKeyInfo(_ keyCode: UInt32) throws -> SMCKeyDataInfo {
        if let cached = keyInfoCache[keyCode] {
            return cached
        }

        var input = SMCParamStruct()
        input.key = keyCode
        input.data8 = smcReadKeyInfo

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let result = IOConnectCallStructMethod(
            connection,
            kernelIndexSmc,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess, output.result == 0 else {
            throw HelperError("SMC key info read failed (\(result))")
        }

        keyInfoCache[keyCode] = output.keyInfo
        return output.keyInfo
    }

    private func normalizedRPM(_ value: Double?, allowZero: Bool) -> Int? {
        guard let value else { return nil }
        if value == 0, allowZero {
            return 0
        }
        guard value.isFinite, value > 0, value < 100_000 else { return nil }
        guard value >= 100 else { return nil }
        return Int(value.rounded())
    }

    private func encode(value: Int, dataType: UInt32, dataSize: UInt32) throws -> SMCBytes {
        var raw = [UInt8](repeating: 0, count: 32)

        if dataType == typeUi8, dataSize >= 1 {
            raw[0] = UInt8(max(0, min(255, value)))
        } else if dataType == typeUi16, dataSize >= 2 {
            let v = UInt16(max(0, min(Int(UInt16.max), value)))
            raw[0] = UInt8((v >> 8) & 0xFF)
            raw[1] = UInt8(v & 0xFF)
        } else if dataType == typeFpe2, dataSize >= 2 {
            let v = UInt16(max(0, min(16383, value)))
            raw[0] = UInt8((v >> 6) & 0xFF)
            raw[1] = UInt8((v & 0x3F) << 2)
        } else if dataType == typeFlt, dataSize >= 4 {
            let bits = Float(value).bitPattern.littleEndian
            raw[0] = UInt8((bits >> 0) & 0xFF)
            raw[1] = UInt8((bits >> 8) & 0xFF)
            raw[2] = UInt8((bits >> 16) & 0xFF)
            raw[3] = UInt8((bits >> 24) & 0xFF)
        } else {
            throw HelperError("Unsupported write type for key")
        }

        return (
            raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
            raw[16], raw[17], raw[18], raw[19], raw[20], raw[21], raw[22], raw[23],
            raw[24], raw[25], raw[26], raw[27], raw[28], raw[29], raw[30], raw[31]
        )
    }

    private func parse(bytes: SMCBytes, dataType: UInt32, dataSize: UInt32) -> Double? {
        let raw = [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
            bytes.16, bytes.17, bytes.18, bytes.19, bytes.20, bytes.21, bytes.22, bytes.23,
            bytes.24, bytes.25, bytes.26, bytes.27, bytes.28, bytes.29, bytes.30, bytes.31
        ]

        if dataType == typeSp78, dataSize == 2 {
            let value = (Int(raw[0]) << 8) | Int(raw[1])
            return Double(Int16(bitPattern: UInt16(value))) / 256.0
        }

        if dataType == typeFpe2, dataSize == 2 {
            return Double((Int(raw[0]) << 6) + (Int(raw[1]) >> 2))
        }

        if dataType == typeUi8, dataSize == 1 {
            return Double(raw[0])
        }

        if dataType == typeUi16, dataSize == 2 {
            return Double((Int(raw[0]) << 8) | Int(raw[1]))
        }

        if dataType == typeFlt, dataSize == 4 {
            let bigEndianBits = (UInt32(raw[0]) << 24)
                | (UInt32(raw[1]) << 16)
                | (UInt32(raw[2]) << 8)
                | UInt32(raw[3])
            let littleEndianBits = (UInt32(raw[3]) << 24)
                | (UInt32(raw[2]) << 16)
                | (UInt32(raw[1]) << 8)
                | UInt32(raw[0])

            let bigEndianValue = Double(Float(bitPattern: bigEndianBits))
            let littleEndianValue = Double(Float(bitPattern: littleEndianBits))

            let beNormal = bigEndianValue.isNormal || bigEndianValue == 0
            let leNormal = littleEndianValue.isNormal || littleEndianValue == 0

            if leNormal && !beNormal { return littleEndianValue }
            if beNormal && !leNormal { return bigEndianValue }

            if littleEndianValue.isFinite && abs(littleEndianValue) >= 1 && abs(bigEndianValue) < 1 {
                return littleEndianValue
            }
            if bigEndianValue.isFinite && abs(bigEndianValue) >= 1 && abs(littleEndianValue) < 1 {
                return bigEndianValue
            }
            if littleEndianValue.isFinite {
                return littleEndianValue
            }
            if bigEndianValue.isFinite {
                return bigEndianValue
            }
        }

        return nil
    }
}

private final class ConnectionAuthorizer {
    private let requirementStrings: [String]

    init(requirementStrings: [String]) {
        self.requirementStrings = requirementStrings
    }

    func authorize(_ connection: NSXPCConnection) -> Bool {
        guard let auditTokenData = connection.value(forKey: "auditToken") as? Data else {
            return false
        }

        let attributes = [kSecGuestAttributeAudit: auditTokenData] as CFDictionary
        var guest: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guest)
        guard copyStatus == errSecSuccess, let guest else {
            return false
        }

        for requirementString in requirementStrings {
            var requirement: SecRequirement?
            let reqStatus = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
            guard reqStatus == errSecSuccess, let requirement else { continue }
            if SecCodeCheckValidity(guest, SecCSFlags(), requirement) == errSecSuccess {
                return true
            }
        }

        return false
    }
}

private final class SMCHelperService: NSObject, NSXPCListenerDelegate, SMCHelperXPCProtocol {
    private let controller = SMCController()
    private let stateStore = LeaseStateStore(
        url: URL(fileURLWithPath: "/var/run/\(CoreMonitorIdentity.helperExecutableName)-leases.json")
    )
    private let authorizer: ConnectionAuthorizer
    private let queue = DispatchQueue(label: "ventaphobia.smc-helper.leases")
    private var timer: DispatchSourceTimer?
    private var leases: [Int: LeaseRecord]

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let requirements = (info["SMAuthorizedClients"] as? [String]) ?? []
        self.authorizer = ConnectionAuthorizer(requirementStrings: requirements)
        self.leases = stateStore.load()
        super.init()
        try? controller.open()
        expireLeases()
        startLeaseTimer()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard authorizer.authorize(newConnection) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: SMCHelperXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func setFanManual(_ fanID: Int, rpm: Int, withReply reply: @escaping (NSString?) -> Void) {
        do {
            try controller.open()
            try controller.setFanManual(fanID, rpm: rpm)
            clearLease(for: fanID)
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    func setFanAuto(_ fanID: Int, withReply reply: @escaping (NSString?) -> Void) {
        do {
            try controller.open()
            try controller.setFanAuto(fanID)
            clearLease(for: fanID)
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    func readValue(_ key: String, withReply reply: @escaping (NSNumber?, NSString?) -> Void) {
        do {
            try controller.open()
            let value = try controller.readValue(key)
            reply(NSNumber(value: value), nil)
        } catch {
            reply(nil, error.localizedDescription as NSString)
        }
    }

    func setFanManualLease(
        _ fanID: Int,
        rpm: Int,
        leaseSeconds: Int,
        withReply reply: @escaping (NSString?) -> Void
    ) {
        do {
            try controller.open()
            try controller.setFanManual(fanID, rpm: rpm)
            recordLease(fanID: fanID, seconds: leaseSeconds)
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    func resetAllToAutomatic(withReply reply: @escaping (NSString?) -> Void) {
        do {
            try controller.open()
            controller.resetAllToAutomatic()
            clearAllLeases()
            reply(nil)
        } catch {
            reply(error.localizedDescription as NSString)
        }
    }

    private func startLeaseTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.expireLeases()
        }
        self.timer = timer
        timer.resume()
    }

    private func recordLease(fanID: Int, seconds: Int) {
        queue.async {
            let expiry = Date().addingTimeInterval(TimeInterval(max(seconds, 5)))
            self.leases[fanID] = LeaseRecord(fanID: fanID, expiresAt: expiry)
            self.stateStore.save(self.leases)
        }
    }

    private func clearLease(for fanID: Int) {
        queue.async {
            self.leases.removeValue(forKey: fanID)
            self.stateStore.save(self.leases)
        }
    }

    private func clearAllLeases() {
        queue.async {
            self.leases.removeAll()
            self.stateStore.save(self.leases)
        }
    }

    private func expireLeases() {
        queue.async {
            let now = Date()
            let expired = self.leases.values.filter { $0.expiresAt <= now }
            guard !expired.isEmpty else { return }

            for record in expired {
                try? self.controller.open()
                try? self.controller.setFanAuto(record.fanID)
                self.leases.removeValue(forKey: record.fanID)
            }
            self.stateStore.save(self.leases)
        }
    }
}

private func fourCharCode(from string: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, byte) in string.utf8.prefix(4).enumerated() {
        result |= UInt32(byte) << (8 * (3 - index))
    }
    return result
}

private func validateFanID(_ rawValue: String) throws -> Int {
    guard let fanID = Int(rawValue), (0..<12).contains(fanID) else {
        throw HelperError("Fan ID must be between 0 and 11")
    }
    return fanID
}

private func validateRPM(_ rawValue: String) throws -> Int {
    guard let rpm = Int(rawValue), (500...10_000).contains(rpm) else {
        throw HelperError("RPM must be between 500 and 10000")
    }
    return rpm
}

private func validateSMCKey(_ rawValue: String) throws -> String {
    let bytes = Array(rawValue.utf8)
    guard bytes.count == 4, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
        throw HelperError("SMC key must be exactly 4 printable ASCII characters")
    }
    return rawValue
}

private func printUsageAndExit() -> Never {
    FileHandle.standardError.write(
        Data(
            """
            Usage:
              core-monitor-helper set <fanID> <rpm>
              core-monitor-helper auto <fanID>
              core-monitor-helper read <SMC_KEY>
            """.appending("\n").utf8
        )
    )
    Foundation.exit(64)
}

private func runCommandLineMode(arguments: [String]) -> Never {
    guard arguments.count >= 2 else { printUsageAndExit() }

    let command = arguments[1]
    let controller = SMCController()

    do {
        try controller.open()

        switch command {
        case "set":
            guard arguments.count == 4 else { printUsageAndExit() }
            let fanID = try validateFanID(arguments[2])
            let rpm = try validateRPM(arguments[3])
            try controller.setFanManual(fanID, rpm: rpm)
            print("ok")
        case "auto":
            guard arguments.count == 3 else { printUsageAndExit() }
            let fanID = try validateFanID(arguments[2])
            try controller.setFanAuto(fanID)
            print("ok")
        case "read":
            guard arguments.count == 3 else { printUsageAndExit() }
            let key = try validateSMCKey(arguments[2])
            let value = try controller.readValue(key)
            print(value)
        default:
            printUsageAndExit()
        }
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        Foundation.exit(1)
    }

    Foundation.exit(0)
}

private func runServiceMode() -> Never {
    let listener = NSXPCListener(machServiceName: CoreMonitorIdentity.helperLabel)
    let service = SMCHelperService()
    listener.delegate = service
    listener.resume()
    RunLoop.current.run()
    Foundation.exit(0)
}

let arguments = CommandLine.arguments
if arguments.count > 1 {
    runCommandLineMode(arguments: arguments)
} else {
    runServiceMode()
}
