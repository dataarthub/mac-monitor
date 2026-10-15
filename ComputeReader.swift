import Foundation
import IOKit

struct HardwareInfo {
    let model: String
    let logicalCores: Int?
    let performanceCores: Int?
    let efficiencyCores: Int?

    private static func integer(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    static let current: HardwareInfo = {
        var size = 0
        var model = "CPU"
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
                model = String(cString: bytes)
            }
        }
        return HardwareInfo(model: model, logicalCores: integer("hw.logicalcpu"),
                            performanceCores: integer("hw.perflevel0.physicalcpu"),
                            efficiencyCores: integer("hw.perflevel1.physicalcpu"))
    }()
}

struct GPUReading {
    let model: String
    let utilization: Double
    let renderer: Double?
    let tiler: Double?

    static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && (0...100).contains(value) ? value : nil
    }

    static func from(statistics: [String: Any], model: String) -> GPUReading? {
        guard let utilization = percentage(statistics["Device Utilization %"]) else { return nil }
        return GPUReading(model: model, utilization: utilization,
                          renderer: percentage(statistics["Renderer Utilization %"]),
                          tiler: percentage(statistics["Tiler Utilization %"]))
    }

    static func read() -> GPUReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var readings: [GPUReading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "GPU"
            if let reading = from(statistics: statistics, model: model) { readings.append(reading) }
        }
        // Keep utilization and its submetrics from the same device.
        return readings.max { $0.utilization < $1.utilization }
    }
}
