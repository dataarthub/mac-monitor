import Foundation
import IOKit

struct ExternalVolume {
    let group: String
    let name: String
    let path: String
    let total: Double
    let free: Double
}

struct ExternalStorage {
    let volumes: [ExternalVolume]
    // APFS volumes sharing one container must not be counted more than once.
    private var groups: [[ExternalVolume]] { Array(Dictionary(grouping: volumes, by: \.group).values) }
    var total: Double { groups.reduce(0) { $0 + ($1.first?.total ?? 0) } }
    var free: Double { groups.reduce(0) { $0 + ($1.map(\.free).min() ?? 0) } }
    var used: Double { max(0, total - free) }
    var utilization: Double? { total > 0 ? used / total * 100 : nil }
}

struct ExternalDrive: Identifiable {
    let id: String
    let disk: String
    let name: String
    let size: Double
    let solidState: Bool?
    var storage: ExternalStorage?
    var attachmentID: UInt64? = nil
    var label: String { "\(name) · \(String(format: "%.0f", size / 1e9)) GB · \(disk)" }
}

enum ExternalStorageReader {
    static func physicalDisk(devicePath: String) -> String? {
        if devicePath.hasPrefix("/dev/") {
            let name = String(devicePath.dropFirst(5)).replacingOccurrences(of: "^rdisk", with: "disk", options: .regularExpression)
            guard let range = name.range(of: "^disk[0-9]+(?=s[0-9]+$|$)", options: .regularExpression) else { return nil }
            return String(name[range])
        }
        let service = IORegistryEntryFromPath(kIOMainPortDefault, devicePath)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, "IOMedia") != 0,
                  let whole = IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                  whole.boolValue,
                  let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            return name
        }
        return nil
    }

    static func mountedCandidates(list: [String: Any], physicalDisk: String) -> [(group: String, name: String, path: String)] {
        var result: [(String, String, String)] = []
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            let identifier = entry["DeviceIdentifier"] as? String ?? ""
            let stores = entry["APFSPhysicalStores"] as? [[String: Any]] ?? []
            let matchingAPFS = !stores.isEmpty && stores.allSatisfy { store in
                guard let name = store["DeviceIdentifier"] as? String else { return false }
                return name == physicalDisk || name.hasPrefix(physicalDisk + "s")
            }
            let volumes: [[String: Any]]
            if matchingAPFS { volumes = entry["APFSVolumes"] as? [[String: Any]] ?? [] }
            else if identifier == physicalDisk { volumes = (entry["Partitions"] as? [[String: Any]] ?? []) + [entry] }
            else { continue }
            for volume in volumes {
                guard let path = volume["MountPoint"] as? String, path.hasPrefix("/"),
                      let name = volume["VolumeName"] as? String else { continue }
                let group = matchingAPFS ? identifier : (volume["DeviceIdentifier"] as? String ?? identifier)
                result.append((group, name, path))
            }
        }
        return result.sorted { $0.2 < $1.2 }
    }

    private static func plist(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw ReadError.unavailable("外付けドライブの一覧を取得できません。")
        }
        return list
    }

    private static let bootID: String = {
        var size = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 { return String(cString: bytes) }
        }
        return UUID().uuidString // Fail closed across launches if the OS omits the boot UUID.
    }()

    // Partition UUIDs survive disk-number changes and do not depend on volume names.
    // Unformatted media without a UUID get a boot-session IOKit identity, never diskN.
    static func identity(entry: [String: Any], info: [String: Any], sessionID: UInt64?) -> String? {
        let partitions = entry["Partitions"] as? [[String: Any]] ?? []
        let uuids = ([entry] + partitions).compactMap { ($0["DiskUUID"] ?? $0["VolumeUUID"]) as? String }
            .filter { !$0.isEmpty }.map { $0.uppercased() }.sorted()
        if !uuids.isEmpty { return "uuid:" + uuids.joined(separator: ":") }
        if let uuid = (info["DiskUUID"] ?? info["VolumeUUID"]) as? String, !uuid.isEmpty { return "uuid:" + uuid.uppercased() }
        if let sessionID { return "session:" + bootID + ":" + String(sessionID) }
        return nil
    }

    private static func registryID(disk: String) -> UInt64? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, disk))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    static func isCandidate(info: [String: Any]) -> Bool {
        // Some USB bridges omit SolidState. Include those as unclassified drives.
        info["Internal"] as? Bool == false && info["WholeDisk"] as? Bool == true
            && info["VirtualOrPhysical"] as? String == "Physical" && info["SolidState"] as? Bool != false
    }

    static func catalog() throws -> [ExternalDrive] {
        let external = try plist(["list", "-plist", "external", "physical"])
        let list = try plist(["list", "-plist"])
        var drives: [ExternalDrive] = []
        for entry in external["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            guard let disk = entry["DeviceIdentifier"] as? String,
                  let info = try? plist(["info", "-plist", disk]), isCandidate(info: info),
                  let attachmentID = registryID(disk: disk),
                  let id = identity(entry: entry, info: info, sessionID: attachmentID) else { continue }
            let name = info["MediaName"] as? String ?? info["IORegistryEntryName"] as? String ?? disk
            let size = (info["TotalSize"] as? NSNumber)?.doubleValue ?? 0
            drives.append(ExternalDrive(id: id, disk: disk, name: name, size: size,
                                        solidState: info["SolidState"] as? Bool, storage: storage(list: list, disk: disk), attachmentID: attachmentID))
        }
        return drives.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func selected(from drives: [ExternalDrive], id: String?) throws -> ExternalDrive {
        guard let id = id ?? drives.first?.id else { throw ReadError.disconnected }
        let matches = drives.filter { $0.id == id }
        guard matches.count == 1 else {
            throw matches.isEmpty ? ReadError.disconnected : ReadError.unavailable("同じ識別情報のドライブが複数あるため選択できません。")
        }
        return matches[0]
    }

    static func isStillAttached(_ drive: ExternalDrive) -> Bool {
        guard let attachmentID = drive.attachmentID else { return true }
        return registryID(disk: drive.disk) == attachmentID
    }

    private static func storage(list: [String: Any], disk: String) -> ExternalStorage? {
        let volumes = mountedCandidates(list: list, physicalDisk: disk).compactMap { candidate -> ExternalVolume? in
            guard let fs = try? FileManager.default.attributesOfFileSystem(forPath: candidate.path),
                  let total = (fs[.systemSize] as? NSNumber)?.doubleValue,
                  let free = (fs[.systemFreeSize] as? NSNumber)?.doubleValue,
                  total.isFinite, free.isFinite, total > 0, free >= 0, free <= total else { return nil }
            return ExternalVolume(group: candidate.group, name: candidate.name, path: candidate.path, total: total, free: free)
        }
        return volumes.isEmpty ? nil : ExternalStorage(volumes: volumes)
    }
}
