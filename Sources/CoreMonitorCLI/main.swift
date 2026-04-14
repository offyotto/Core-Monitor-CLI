import Foundation
import CoreMonitorKit

struct CLI {
    let args: [String]
    let helper = SMCHelperBridge()
    let monitor: SystemMonitor
    let fans: FanControlService

    init(args: [String]) {
        self.args = args
        self.monitor = SystemMonitor(helper: helper)
        self.fans = FanControlService(helper: helper)
    }

    func run() throws {
        guard args.count >= 2 else {
            printUsage()
            return
        }

        switch args[1] {
        case "status":
            try runStatus(Array(args.dropFirst(2)))
        case "fans":
            try runFans(Array(args.dropFirst(2)))
        case "sensors":
            try runSensors(Array(args.dropFirst(2)))
        case "helper":
            try runHelper(Array(args.dropFirst(2)))
        case "doctor":
            try runDoctor()
        case "config":
            try runConfig(Array(args.dropFirst(2)))
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CoreMonitorError("Unknown command: \(args[1])")
        }
    }

    private func runStatus(_ args: [String]) throws {
        let json = args.contains("--json")
        let watch = optionValue(named: "--watch", in: args).flatMap(Double.init)

        if let watch {
            while true {
                let snapshot = try monitor.snapshot(installHelperIfNeeded: true)
                render(snapshot: snapshot, json: json)
                print("")
                Thread.sleep(forTimeInterval: max(0.5, watch))
            }
        } else {
            let snapshot = try monitor.snapshot(installHelperIfNeeded: true)
            render(snapshot: snapshot, json: json)
        }
    }

    private func runFans(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CoreMonitorError("Missing fans subcommand")
        }

        switch subcommand {
        case "list":
            let json = args.contains("--json")
            let info = try fans.fans()
            if json {
                print(try JSON.encode(info))
            } else if info.isEmpty {
                print("No fan data available")
            } else {
                for fan in info {
                    print(
                        "fan \(fan.id): current=\(fan.currentRPM.map(Format.rpm) ?? "n/a") min=\(fan.minimumRPM.map(Format.rpm) ?? "n/a") max=\(fan.maximumRPM.map(Format.rpm) ?? "n/a") target=\(fan.targetRPM.map(Format.rpm) ?? "n/a")"
                    )
                }
            }

        case "auto":
            let fanID = parsedFanID(in: args)
            try fans.setAuto(fanID: fanID)
            print(fanID == nil ? "All fans restored to automatic mode" : "Fan \(fanID!) restored to automatic mode")

        case "set":
            guard let rpmRaw = optionValue(named: "--rpm", in: args), let rpm = Int(rpmRaw) else {
                throw CoreMonitorError("fans set requires --rpm <value>")
            }
            let leaseSeconds = optionValue(named: "--lease", in: args).flatMap(Int.init)
            let fanID = parsedFanID(in: args)
            try fans.setManual(fanID: fanID, rpm: rpm, leaseSeconds: leaseSeconds)
            if let leaseSeconds {
                print(
                    fanID == nil
                        ? "Applied \(rpm) RPM to all fans for \(leaseSeconds)s"
                        : "Applied \(rpm) RPM to fan \(fanID!) for \(leaseSeconds)s"
                )
            } else {
                print(fanID == nil ? "Applied \(rpm) RPM to all fans" : "Applied \(rpm) RPM to fan \(fanID!)")
            }

        case "mode":
            guard args.count >= 2 else {
                throw CoreMonitorError("fans mode requires a mode name")
            }
            guard let mode = FanMode(rawValue: args[1]) else {
                throw CoreMonitorError("Unsupported fan mode: \(args[1])")
            }
            let fanID = parsedFanID(in: args)
            let watch = optionValue(named: "--watch", in: args).flatMap(Double.init)
            let curveFile = optionValue(named: "--file", in: args)
            let curve = try curveFile.map(FanCurve.load(from:))
            let leaseSeconds = optionValue(named: "--lease", in: args).flatMap(Int.init)
            if mode == .curve, curve == nil {
                throw CoreMonitorError("fans mode curve requires --file <curve.json>")
            }
            if let watch {
                print("Running \(mode.rawValue) mode. Press Ctrl+C to stop.")
                try fans.watch(mode: mode, fanID: fanID, interval: watch, curve: curve)
            } else {
                try fans.apply(mode: mode, fanID: fanID, curve: curve, leaseSeconds: leaseSeconds)
                print("Applied \(mode.rawValue) mode")
            }

        default:
            throw CoreMonitorError("Unknown fans subcommand: \(subcommand)")
        }
    }

    private func runSensors(_ args: [String]) throws {
        guard args.count >= 2, args[0] == "read" else {
            throw CoreMonitorError("Usage: core-monitor sensors read <SMC_KEY>")
        }
        let key = args[1]
        let value = try helper.readValue(key: key)
        print(value)
    }

    private func runHelper(_ args: [String]) throws {
        guard let subcommand = args.first else {
            throw CoreMonitorError("Usage: core-monitor helper <install|status>")
        }

        switch subcommand {
        case "install":
            try helper.installHelperIfNeeded()
            print("Privileged helper installed")
        case "status":
            print("helper label: \(helper.helperLabel)")
            print("helper path: \(helper.helperPath)")
            print("helper installed: \(helper.isInstalled() ? "yes" : "no")")
            print("bless host path: \(helper.blessHostPath ?? "n/a")")
            let reachable = (try? helper.readValue(key: "FNum", installIfNeeded: false)) != nil
            print("xpc reachable: \(reachable ? "yes" : "no")")
        default:
            throw CoreMonitorError("Usage: core-monitor helper <install|status>")
        }
    }

    private func runDoctor() throws {
        print("helper label: \(helper.helperLabel)")
        print("helper path: \(helper.helperPath)")
        print("helper installed: \(helper.isInstalled() ? "yes" : "no")")
        print("bless host path: \(helper.blessHostPath ?? "n/a")")

        let xpcReachable = (try? helper.readValue(key: "FNum", installIfNeeded: false)) != nil
        print("xpc reachable: \(xpcReachable ? "yes" : "no")")

        let snapshot = try monitor.snapshot(installHelperIfNeeded: false)
        print("fans detected: \(snapshot.fans.count)")
        print("cpu temp: \(Format.temperature(snapshot.thermal.cpuTemperatureC))")
        print("gpu temp: \(Format.temperature(snapshot.thermal.gpuTemperatureC))")
        print("battery present: \(snapshot.battery.hasBattery ? "yes" : "no")")
    }

    private func runConfig(_ args: [String]) throws {
        guard args.first == "example-curve" else {
            throw CoreMonitorError("Usage: core-monitor config example-curve")
        }
        let path = FileManager.default.currentDirectoryPath + "/config/example-curve.json"
        print(path)
    }

    private func render(snapshot: SystemSnapshot, json: Bool) {
        if json {
            do {
                print(try JSON.encode(snapshot))
            } catch {
                print("Failed to encode JSON: \(error.localizedDescription)")
            }
            return
        }

        print("time: \(snapshot.timestampISO8601)")
        print("cpu: \(Format.percent(snapshot.cpu.usagePercent))")
        print(
            "memory: \(Format.percent(snapshot.memory.usagePercent)) used=\(Format.gigabytes(snapshot.memory.usedGB)) total=\(Format.gigabytes(snapshot.memory.totalGB)) free=\(Format.gigabytes(snapshot.memory.freeGB)) swap=\(Format.gigabytes(snapshot.memory.swapUsedGB))"
        )
        print(
            "disk: \(Format.percent(snapshot.disk.usagePercent)) used=\(Format.gigabytes(snapshot.disk.usedGB)) total=\(Format.gigabytes(snapshot.disk.totalGB)) free=\(Format.gigabytes(snapshot.disk.freeGB))"
        )
        if snapshot.battery.hasBattery {
            print(
                "battery: \(snapshot.battery.chargePercent.map { "\($0)%" } ?? "n/a") charging=\(snapshot.battery.isCharging ? "yes" : "no") plugged=\(snapshot.battery.isPluggedIn ? "yes" : "no") cycles=\(snapshot.battery.cycleCount.map(String.init) ?? "n/a") health=\(snapshot.battery.healthPercent.map { "\($0)%" } ?? "n/a")"
            )
        } else {
            print("battery: none")
        }
        print(
            "thermal: cpu=\(Format.temperature(snapshot.thermal.cpuTemperatureC)) gpu=\(Format.temperature(snapshot.thermal.gpuTemperatureC)) totalPower=\(Format.watts(snapshot.thermal.totalSystemWatts))"
        )
        if snapshot.fans.isEmpty {
            print("fans: unavailable")
        } else {
            for fan in snapshot.fans {
                print(
                    "fan \(fan.id): current=\(fan.currentRPM.map(Format.rpm) ?? "n/a") min=\(fan.minimumRPM.map(Format.rpm) ?? "n/a") max=\(fan.maximumRPM.map(Format.rpm) ?? "n/a") target=\(fan.targetRPM.map(Format.rpm) ?? "n/a")"
                )
            }
        }
    }

    private func parsedFanID(in args: [String]) -> Int? {
        if args.contains("--all") {
            return nil
        }
        return optionValue(named: "--fan", in: args).flatMap(Int.init)
    }

    private func optionValue(named name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private func printUsage() {
        print(
            """
            core-monitor

            Commands:
              core-monitor status [--json] [--watch seconds]
              core-monitor fans list [--json]
              core-monitor fans auto [--fan id | --all]
              core-monitor fans set [--fan id | --all] --rpm value [--lease seconds]
              core-monitor fans mode <silent|balanced|performance|max|smart|curve> [--fan id | --all] [--watch seconds] [--lease seconds] [--file path]
              core-monitor sensors read <SMC_KEY>
              core-monitor helper install
              core-monitor helper status
              core-monitor doctor
              core-monitor config example-curve
            """
        )
    }
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
