import AppKit
import Foundation

struct SSDHealthDetails {
    let readTB: Double?
    let percentageUsed: Double?
    let availableSpare: Double?
    let spareThreshold: Double?
    let powerOnHours: Double?
    let unsafeShutdowns: Double?
    let mediaErrors: Double?
    let criticalWarning: Double?

    static func number(_ value: Any?, maximum: Double = .greatestFiniteMagnitude) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 && value <= maximum ? value : nil
    }

    init(health: [String: Any], general: [String: Any] = [:]) {
        readTB = Self.number(health["data_units_read"]).flatMap {
            let tb = $0 * 512_000 / 1_000_000_000_000
            return tb.isFinite ? tb : nil
        }
        percentageUsed = Self.number(health["percentage_used"], maximum: 255) ?? Self.number((general["endurance_used"] as? [String: Any])?["current_percent"], maximum: 255)
        availableSpare = Self.number(health["available_spare"], maximum: 100) ?? Self.number((general["spare_available"] as? [String: Any])?["current_percent"], maximum: 100)
        spareThreshold = Self.number(health["available_spare_threshold"], maximum: 100)
        powerOnHours = Self.number(health["power_on_hours"]) ?? Self.number((general["power_on_time"] as? [String: Any])?["hours"])
        unsafeShutdowns = Self.number(health["unsafe_shutdowns"])
        mediaErrors = Self.number(health["media_errors"])
        criticalWarning = Self.number(health["critical_warning"], maximum: 255)
    }
}

struct Reading {
    let model: String
    let temperature: Int?
    let writtenTB: Double?
    let criticalWarning: Int?
    let mediaErrors: Int?
    let healthy: Bool?
    var details = SSDHealthDetails(health: [:])
    var storage: ExternalStorage? = nil
    var driveID: String? = nil
    var disk: String? = nil

    var hasFault: Bool { (criticalWarning ?? 0) != 0 || (mediaErrors ?? 0) != 0 || healthy == false }
    var hasSMARTData: Bool {
        temperature != nil || healthy != nil || writtenTB != nil || details.readTB != nil
            || details.percentageUsed != nil || details.powerOnHours != nil
            || criticalWarning != nil || mediaErrors != nil || details.availableSpare != nil
    }
    var level: String {
        let l = AppLocalization.system
        if hasFault { return l.text("SMART情報を確認してください") }
        if let temperature, temperature >= 70 { return l.text("高温：負荷を減らして放熱を確認") }
        if let temperature, temperature >= 65 { return l.text("温度高め：風通しを確認") }
        if healthy == true { return l.text("SMART正常") }
        return l.text("SMART判定なし")
    }
}

enum ReadError: LocalizedError {
    case missingTool, disconnected, smartUnavailable, unavailable(String)
    var errorDescription: String? { description(using: .system) }
    func description(using l: AppLocalization) -> String {
        switch self {
        case .missingTool: return l.text("smartctlが見つからないため、容量のみ表示します。")
        case .disconnected: return l.text("選択した外付けSSDが見つかりません。接続または設定を確認してください。")
        case .smartUnavailable: return l.text("SMARTを取得できません（非対応の接続・権限・読み取り失敗など）。容量のみ表示します。")
        case .unavailable(let detail): return l.text(detail)
        }
    }
}

struct ExternalPoll {
    let drives: [ExternalDrive]
    let selected: ExternalDrive?
    let reading: Reading?
    let issue: ReadError?
}

final class SSDReader: @unchecked Sendable {
    private let binary: String?
    private let inventory: () throws -> [ExternalDrive]
    private let command: (([String]) throws -> [String: Any])?

    static func writtenTerabytes(from health: [String: Any]) -> Double? {
        SSDHealthDetails.number(health["data_units_written"]).flatMap {
            let tb = $0 * 512_000 / 1e12
            return tb.isFinite ? tb : nil
        }
    }

    convenience init() {
        let args = CommandLine.arguments
        let binary: String?
        if let index = args.firstIndex(of: "--smartctl"), args.count > index + 1 {
            binary = args[index + 1]
        } else {
            binary = ["/opt/homebrew/bin/smartctl", "/opt/homebrew/sbin/smartctl", "/usr/local/bin/smartctl", "/usr/local/sbin/smartctl"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        self.init(binary: binary)
    }

    // Injectable read-only boundaries allow fallback, selection and unplug tests
    // without requiring a second physical disk or a particular USB bridge.
    init(binary: String?, inventory: @escaping () throws -> [ExternalDrive] = ExternalStorageReader.catalog,
         command: (([String]) throws -> [String: Any])? = nil) {
        self.binary = binary; self.inventory = inventory; self.command = command
    }

    private func json(_ arguments: [String]) throws -> [String: Any] {
        if let command { return try command(arguments) }
        guard let binary else { throw ReadError.missingTool }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.smartUnavailable
        }
        // SMART health bits may make smartctl exit nonzero even for a valid report.
        return result
    }

    static func parse(_ object: [String: Any], drive: ExternalDrive) -> Reading {
        let health = object["nvme_smart_health_information_log"] as? [String: Any] ?? [:]
        let temperatureObject = object["temperature"] as? [String: Any] ?? [:]
        let rawTemperature = SSDHealthDetails.number(health["temperature"] ?? temperatureObject["current"], maximum: 149)
        let temperature = rawTemperature.flatMap { $0.rounded() == $0 ? Int($0) : nil }
        let status = (object["smart_status"] as? [String: Any])?["passed"] as? NSNumber
        let healthy = status.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        let details = SSDHealthDetails(health: health, general: object)
        return Reading(model: object["model_name"] as? String ?? object["product"] as? String ?? drive.name,
                       temperature: temperature, writtenTB: writtenTerabytes(from: health),
                       criticalWarning: details.criticalWarning.map(Int.init), mediaErrors: details.mediaErrors.map { $0 >= Double(Int.max) ? Int.max : Int($0) },
                       healthy: healthy, details: details, storage: drive.storage, driveID: drive.id, disk: drive.disk)
    }

    static func smartTarget(devices: [[String: Any]], drive: ExternalDrive) -> (path: String, type: String?) {
        for device in devices {
            guard let name = device["name"] as? String,
                  ExternalStorageReader.physicalDisk(devicePath: name) == drive.disk else { continue }
            return (name, device["type"] as? String)
        }
        // Auto-detect a physical device if the scan does not expose this bridge.
        return ("/dev/" + drive.disk, nil)
    }

    func poll(selectedID: String?) -> ExternalPoll {
        let drives: [ExternalDrive]
        do { drives = try inventory() }
        catch { return ExternalPoll(drives: [], selected: nil, reading: nil, issue: .unavailable("外付けドライブの一覧を取得できません。")) }
        let drive: ExternalDrive
        do { drive = try ExternalStorageReader.selected(from: drives, id: selectedID) }
        catch { return ExternalPoll(drives: drives, selected: nil, reading: nil, issue: error as? ReadError ?? .disconnected) }
        func finish(_ reading: Reading, issue: ReadError?) -> ExternalPoll {
            guard ExternalStorageReader.isStillAttached(drive) else {
                return ExternalPoll(drives: drives.filter { $0.disk != drive.disk }, selected: nil, reading: nil, issue: .disconnected)
            }
            return ExternalPoll(drives: drives, selected: drive, reading: reading, issue: issue)
        }
        let fallback = Self.parse([:], drive: drive)
        guard binary != nil else { return finish(fallback, issue: .missingTool) }
        do {
            let scan = try? json(["--scan", "-j"])
            let target = Self.smartTarget(devices: scan?["devices"] as? [[String: Any]] ?? [], drive: drive)
            var arguments = ["-a", "-j"]
            if let type = target.type { arguments += ["-d", type] }
            arguments.append(target.path)
            let reading = Self.parse(try json(arguments), drive: drive)
            return finish(reading, issue: reading.hasSMARTData ? nil : .smartUnavailable)
        } catch { return finish(fallback, issue: .smartUnavailable) }
    }

    func read(selectedID: String? = nil) throws -> Reading {
        let result = poll(selectedID: selectedID)
        if let reading = result.reading { return reading }
        throw result.issue ?? .disconnected
    }
}
