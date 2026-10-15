import AppKit
import SwiftUI
import Foundation

private func gb(_ bytes: Double, digits: Int = 1) -> String {
    String(format: "%.*f", digits, bytes / 1_000_000_000)
}
private func memoryGB(_ bytes: UInt64, digits: Int = 1) -> String {
    String(format: "%.*f", digits, Double(bytes) / 1_073_741_824)
}

private func fittedDashboardFrame(current: NSRect, visible: NSRect, preferred: NSSize) -> NSRect {
    let bounds = visible.insetBy(dx: 8, dy: 8)
    let size = NSSize(width: min(preferred.width, bounds.width), height: min(preferred.height, bounds.height))
    return NSRect(x: min(max(current.minX, bounds.minX), bounds.maxX - size.width),
                  y: min(max(current.maxY - size.height, bounds.minY), bounds.maxY - size.height),
                  width: size.width, height: size.height)
}

private struct BarPart {
    let symbol: String
    let text: String
    let color: NSColor
    var reservedTextWidth: CGFloat? = nil
}

private let menuFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

private struct MenuWidthCache {
    private var widths: [String: CGFloat] = [:]

    mutating func width(for metric: DisplayMetric, text: String, using l: AppLocalization) -> CGFloat {
        let key = metric.rawValue + ":" + l.code
        let minimum: [String]
        switch metric {
        case .cpuUtilization, .gpuUtilization, .gpuRenderer, .gpuTiler, .memoryUtilization, .ssdEndurance, .ssdStorageUtilization:
            minimum = ["100%"]
        case .memoryPressure: minimum = [l.text("正常"), l.text("注意"), l.text("圧迫")]
        case .ssdTemperature: minimum = ["99°C"]
        default: minimum = []
        }
        // Keep only the space actually needed during this launch. A newly seen
        // digit count may expand once, but smaller readings never pull it back.
        let needed = ceil(([text] + minimum).map(menuTextWidth).max() ?? 0)
        let width = max(widths[key] ?? 0, needed)
        widths[key] = width
        return width
    }
}

private func menuTextWidth(_ text: String) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: menuFont]).size().width
}

private func menuSlotWidths(_ parts: [BarPart]) -> [CGFloat] {
    parts.map { part in
        let textWidth = part.reservedTextWidth ?? ceil(menuTextWidth(part.text))
        return 14 + (textWidth > 0 ? 3 + textWidth : 0)
    }
}

private func menuImage(_ parts: [BarPart]) -> NSImage {
    let widths = menuSlotWidths(parts)
    let width = widths.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * 9
    let image = NSImage(size: NSSize(width: width, height: 20), flipped: false) { _ in
        var x = CGFloat(0)
        for (index, part) in parts.enumerated() {
            let symbol = NSImage(systemSymbolName: part.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [part.color]))
            symbol?.draw(in: NSRect(x: x, y: 3, width: 14, height: 14))
            if !part.text.isEmpty {
                let title = NSAttributedString(string: part.text, attributes: [.font: menuFont, .foregroundColor: part.color])
                title.draw(at: NSPoint(x: x + 17,
                                       y: (CGFloat(20) - title.size().height) / CGFloat(2)))
            }
            x += widths[index] + 9
        }
        return true
    }
    image.isTemplate = false
    return image
}

struct SystemSample {
    let metrics: SystemMetrics
    let diskFree: Double?
    let diskTotal: Double?
    let diskAvailable: Double?
    let gpu: GPUReading?
    let diskFormat: String?
    let diskName: String?

    init(metrics: SystemMetrics, diskFree: Double?, diskTotal: Double?, diskAvailable: Double? = nil, gpu: GPUReading? = nil, diskFormat: String? = nil, diskName: String? = nil) {
        self.metrics = metrics
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.diskAvailable = diskAvailable.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.gpu = gpu
        self.diskFormat = diskFormat
        self.diskName = diskName
    }

    // The difference is an estimate, not a measurement of Time Machine snapshots.
    // The OS capacity estimate and filesystem free space can change between reads.
    var diskPurgeableEstimate: Double? {
        guard let diskAvailable, let diskFree, diskFree.isFinite, diskFree >= 0 else { return nil }
        return max(0, diskAvailable - diskFree)
    }

    var memoryUtilization: Double? {
        guard metrics.memory_valid != 0, metrics.memory_total > 0 else { return nil }
        return Double(metrics.memory_used) / Double(metrics.memory_total) * 100
    }

    var diskUsedEstimate: Double? {
        guard let diskTotal, let diskFree, diskTotal > 0, diskFree >= 0, diskFree <= diskTotal else { return nil }
        return diskTotal - diskFree
    }

    var cpuCores: [Double] {
        withUnsafeBytes(of: metrics.cpu_cores) { bytes in
            Array(bytes.bindMemory(to: Double.self).prefix(min(Int(metrics.cpu_core_count), Int(METRIC_MAX_CORES))))
        }
    }

    var loadAverages: [Double]? {
        guard metrics.load_valid != 0 else { return nil }
        return withUnsafeBytes(of: metrics.load_average) { Array($0.bindMemory(to: Double.self)) }
    }

    static func read() -> SystemSample {
        let metrics = sample_metrics()
        let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
        let fs = try? FileManager.default.attributesOfFileSystem(forPath: dataVolume.path)
        // A fresh URL avoids reusing cached resource values on subsequent samples.
        // Important usage includes space macOS expects to reclaim automatically.
        let capacity = try? dataVolume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTypeNameKey, .volumeNameKey])
        return SystemSample(metrics: metrics,
                            diskFree: (fs?[.systemFreeSize] as? NSNumber)?.doubleValue,
                            diskTotal: (fs?[.systemSize] as? NSNumber)?.doubleValue,
                            diskAvailable: capacity?.volumeAvailableCapacityForImportantUsage.map { Double($0) },
                            gpu: GPUReading.read(), diskFormat: capacity?.volumeTypeName?.uppercased(), diskName: capacity?.volumeName)
    }
}

@MainActor final class Monitor: ObservableObject {
    let settings: AppSettings
    var l: AppLocalization { settings.localization }
    var ssdError: String? {
        ssdFailure.map { ($0 as? ReadError)?.description(using: l) ?? $0.localizedDescription }
    }
    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        self.settings.onPollingChange = { [weak self] in self?.configureTimers() }
        self.settings.onDriveChange = { [weak self] in self?.driveSelectionChanged() }
    }
    func displayMetric(for group: MetricGroup) -> DisplayMetric {
        let requested = settings.metric(for: group)
        if group == .externalSSD, ssd?.storage != nil, presentation(for: requested).value == "—" {
            return .ssdStorageFree
        }
        return requested
    }
    func presentation(for metric: DisplayMetric) -> MetricPresentation {
        func formatted(_ value: Double?, digits: Int = 0) -> String? {
            value.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.*f", digits, $0) : nil }
        }
        func memory(_ value: KeyPath<SystemMetrics, UInt64>) -> String? {
            guard let s = system, s.metrics.memory_valid != 0 else { return nil }
            return memoryGB(s.metrics[keyPath: value])
        }
        var value: String?
        var unit = "%"
        var color = Color.blue
        var symbol = "cpu"
        switch metric {
        case .cpuUtilization: value = formatted(system?.metrics.cpu); color = cpuColor
        case .cpuLoad1: value = formatted(system?.loadAverages?.first, digits: 2); unit = ""
        case .gpuUtilization: value = formatted(system?.gpu?.utilization); symbol = "square.3.layers.3d"
        case .gpuRenderer: value = formatted(system?.gpu?.renderer); symbol = "square.3.layers.3d"
        case .gpuTiler: value = formatted(system?.gpu?.tiler); symbol = "square.3.layers.3d"
        case .memoryUtilization: value = formatted(system?.memoryUtilization)
        case .memoryUsed: value = memory(\.memory_used); unit = "GB"
        case .memoryPressure: value = system?.metrics.pressure_valid != 0 && system != nil ? pressureLabel : nil; unit = ""
        case .compressed: value = memory(\.compressed); unit = "GB"
        case .swap:
            value = system.flatMap { $0.metrics.swap_valid != 0 ? memoryGB($0.metrics.swap_used) : nil }; unit = "GB"
        case .diskFree: value = system?.diskFree.map { gb($0) }; unit = "GB"; color = diskColor
        case .diskAvailable: value = system?.diskAvailable.map { gb($0) }; unit = "GB"
        case .diskPurgeable: value = system?.diskPurgeableEstimate.map { gb($0) }; unit = "GB"
        case .diskUsed: value = system?.diskUsedEstimate.map { gb($0) }; unit = "GB"
        case .ssdTemperature: value = ssd?.temperature.map { String($0) }; unit = "°C"; color = temperatureColor
        case .ssdWritten: value = formatted(ssd?.writtenTB, digits: 2); unit = "TB"
        case .ssdRead: value = formatted(ssd?.details.readTB, digits: 2); unit = "TB"
        case .ssdEndurance: value = formatted(ssd?.details.percentageUsed)
        case .ssdHours: value = formatted(ssd?.details.powerOnHours); unit = l.text(" 時間").trimmingCharacters(in: .whitespaces)
        case .ssdStorageUtilization: value = formatted(ssd?.storage?.utilization)
        case .ssdStorageFree: value = ssd?.storage.map { gb($0.free) }; unit = "GB"
        case .ssdStorageUsed: value = ssd?.storage.map { gb($0.used) }; unit = "GB"
        }
        switch metric.group {
        case .memory: symbol = "memorychip"; color = pressureColor
        case .disk: symbol = "internaldrive"
        case .externalSSD: symbol = metric == .ssdTemperature ? "thermometer.medium" : "externaldrive"
        case .compute: break
        }
        return MetricPresentation(value: value ?? "—", unit: unit, color: value == nil ? .secondary : color, symbol: symbol)
    }
    @Published var system: SystemSample?
    @Published var ssd: Reading?
    @Published var ssdFailure: Error?
    @Published private(set) var externalDrives: [ExternalDrive] = []
    @Published private(set) var ssdBusy = false
    private(set) var driveGeneration = 0
    private var lastDriveID: String?
    @Published var peak: Int?
    @Published var cpuHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var diskHistory: [Double] = []
    @Published var temperatureHistory: [Double] = []
    @Published var lastSSDUpdate: Date?
    var onChange: (() -> Void)?
    private var firstFree: Double?
    private var systemBusy = false
    private var highCPUStarted: Date?
    private(set) var sustainedHighCPU = false
    private let reader = SSDReader()
    private var systemTimer: Timer?
    private var ssdTimer: Timer?
    private var started = false
    private var scheduledSystemInterval: PollInterval?
    private var scheduledSSDInterval: PollInterval?
    private let queue = DispatchQueue(label: "com.github.dataarthub.mac-monitor.metrics", qos: .utility)

    var pressureLabel: String {
        guard let s = system, s.metrics.pressure_valid != 0 else { return l.text("取得待ち") }
        return [l.text("正常"), l.text("注意"), l.text("圧迫")][min(Int(s.metrics.pressure), 2)]
    }
    var pressureDescription: String {
        guard let s = system, s.metrics.pressure_valid != 0 else { return l.text("macOSの判定を取得できません") }
        switch s.metrics.pressure {
        case 0: return l.text("macOS判定：正常")
        case 1: return l.text("macOS判定：メモリの余裕が減少")
        default: return l.text("macOS判定：メモリが逼迫")
        }
    }
    var cpuColor: Color {
        guard let cpu = system?.metrics.cpu, cpu >= 0 else { return .secondary }
        return cpu >= 90 ? .red : cpu >= 70 ? .orange : .green
    }
    var pressureColor: Color {
        guard let s = system, s.metrics.pressure_valid != 0 else { return .secondary }
        return [.green, .orange, .red][min(Int(s.metrics.pressure), 2)]
    }
    var diskColor: Color {
        guard let free = system?.diskFree else { return .secondary }
        return free < 10_000_000_000 ? .red : free < 20_000_000_000 ? .orange : .green
    }
    var diskDelta: String {
        guard let firstFree, let free = system?.diskFree else { return l.text("空き容量を確認中") }
        let delta = free - firstFree
        return l.text("起動時比 %@%@ GB", delta >= 0 ? "+" : "−", gb(abs(delta)))
    }
    var temperatureColor: Color {
        guard let ssd else { return .secondary }
        if ssd.hasFault { return .red }
        guard let temperature = ssd.temperature else { return .secondary }
        return temperature >= 70 ? .red : temperature >= 65 ? .orange : .green
    }
    var alerts: [(text: String, critical: Bool)] {
        var result: [(String, Bool)] = []
        if let s = system, s.metrics.pressure_valid != 0, s.metrics.pressure > 0 {
            result.append((s.metrics.pressure == 2 ? l.text("メモリ圧迫") : l.text("メモリ注意"), s.metrics.pressure == 2))
        }
        if let free = system?.diskFree, free < 20_000_000_000 {
            result.append((l.text("空き %@ GB", gb(free)), free < 10_000_000_000))
        }
        if let ssd {
            if ssd.hasFault {
                result.append((l.text("SSD診断を確認"), true))
            } else if let temperature = ssd.temperature, temperature >= 65 {
                result.append((l.text("SSD %@℃", String(temperature)), temperature >= 70))
            }
        }
        if sustainedHighCPU { result.append((l.text("CPU高負荷"), false)) }
        return result
    }
    var alertColor: Color { alerts.contains(where: { $0.critical }) ? .red : .orange }
    var hasMissingReadings: Bool {
        guard let system else { return true }
        return system.metrics.cpu < 0 || system.metrics.memory_valid == 0 || system.metrics.pressure_valid == 0 || system.metrics.swap_valid == 0 || system.diskFree == nil || ssd == nil || ssd?.temperature == nil || ssd?.healthy == nil || ssd?.storage == nil
    }

    func start() {
        started = true
        refresh()
        configureTimers()
    }
    private func configureTimers() {
        guard started else { return }
        if scheduledSystemInterval != settings.systemInterval {
            if scheduledSystemInterval != nil {
                cpuHistory = []; gpuHistory = []; memoryHistory = []; diskHistory = []
            }
            systemTimer?.invalidate()
            systemTimer = Timer(timeInterval: Double(settings.systemInterval.rawValue), repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSystem() }
            }
            RunLoop.main.add(systemTimer!, forMode: .common)
            scheduledSystemInterval = settings.systemInterval
        }
        if scheduledSSDInterval != settings.ssdInterval {
            if scheduledSSDInterval != nil { temperatureHistory = [] }
            ssdTimer?.invalidate()
            ssdTimer = Timer(timeInterval: Double(settings.ssdInterval.rawValue), repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSSD() }
            }
            RunLoop.main.add(ssdTimer!, forMode: .common)
            scheduledSSDInterval = settings.ssdInterval
        }
    }
    func refresh() { refreshSystem(); refreshSSD() }
    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
    private func refreshSystem() {
        guard !systemBusy else { return }
        systemBusy = true
        queue.async { [weak self] in
            let sample = SystemSample.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.system = sample
                self.systemBusy = false
                if sample.metrics.cpu >= 90 {
                    if self.highCPUStarted == nil { self.highCPUStarted = Date() }
                    self.sustainedHighCPU = Date().timeIntervalSince(self.highCPUStarted!) >= 30
                } else {
                    self.highCPUStarted = nil
                    self.sustainedHighCPU = false
                }
                if sample.metrics.cpu >= 0 { self.append(sample.metrics.cpu, to: &self.cpuHistory) }
                if let gpu = sample.gpu { self.append(gpu.utilization, to: &self.gpuHistory) }
                if let utilization = sample.memoryUtilization {
                    self.append(utilization, to: &self.memoryHistory)
                }
                if let free = sample.diskFree {
                    if self.firstFree == nil { self.firstFree = free }
                    self.append(free / 1_000_000_000, to: &self.diskHistory)
                }
                self.onChange?()
            }
        }
    }
    private func driveSelectionChanged() {
        driveGeneration += 1
        ssd = nil; ssdFailure = nil; peak = nil; temperatureHistory = []; lastSSDUpdate = nil
        lastDriveID = nil
        onChange?()
        if started { refreshSSD() }
    }

    // Returns false for a read that finished after the user selected another drive.
    @discardableResult func applyExternalPoll(_ result: ExternalPoll, generation: Int) -> Bool {
        guard generation == driveGeneration else { return false }
        externalDrives = result.drives
        if let selected = result.selected, settings.externalDriveID == nil {
            settings.selectExternalDrive(selected, notify: false)
        }
        if lastDriveID != result.selected?.id {
            peak = nil; temperatureHistory = []
            lastDriveID = result.selected?.id
        }
        ssd = result.reading
        ssdFailure = result.issue
        lastSSDUpdate = result.reading == nil ? nil : Date()
        if let temperature = result.reading?.temperature {
            peak = max(peak ?? temperature, temperature)
            append(Double(temperature), to: &temperatureHistory)
        } else {
            temperatureHistory = []
            if result.selected == nil { peak = nil }
        }
        onChange?()
        return true
    }

    func refreshExternal() { refreshSSD() }
    private func refreshSSD() {
        guard !ssdBusy else { return }
        ssdBusy = true
        let generation = driveGeneration
        let selectedID = settings.externalDriveID
        DispatchQueue.global(qos: .utility).async { [reader, weak self] in
            let result = reader.poll(selectedID: selectedID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.ssdBusy = false
                if !self.applyExternalPoll(result, generation: generation) { self.refreshSSD() }
            }
        }
    }

}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    let fixedRange: ClosedRange<Double>?
    var body: some View {
        GeometryReader { geometry in
            let lower = fixedRange?.lowerBound ?? ((values.min() ?? 0) - 0.5)
            let upper = fixedRange?.upperBound ?? ((values.max() ?? 1) + 0.5)
            let points = values.enumerated().map { index, value in
                CGPoint(x: geometry.size.width * Double(index) / Double(max(values.count - 1, 1)),
                        y: geometry.size.height * (1 - min(max((value - lower) / max(upper - lower, 1), 0), 1)))
            }
            Path { path in
                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }.frame(height: 30)
    }
}

struct Tile<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .padding(12)
        .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
    }
}

struct MetricPresentation {
    let value: String
    let unit: String
    let color: Color
    let symbol: String
    var menuText: String { value == "—" ? value : value + unit }
}

private struct PrimaryMetric: View {
    let title: String
    let value: MetricPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.value).font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(value.color)
                Text(value.unit).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DiskDetails: View {
    @Environment(\.appLocalization) private var l
    let sample: SystemSample?
    private func capacity(_ value: Double?) -> String { value.map { gb($0) + " GB" } ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DetailRow(title: l.text("総容量"), value: capacity(sample?.diskTotal), explanation: l.text("Dataボリュームから参照するファイルシステム全体の容量です。APFSでは同じコンテナのボリューム間で容量を共有します。"))
            DetailRow(title: l.text("使用容量（概算）"), value: capacity(sample?.diskUsedEstimate), explanation: l.text("総容量から実際の空きを引いた値です。スナップショットや共有コンテナの他ボリュームも含むため、Data内のファイルサイズ合計ではありません。"))
            DetailRow(title: l.text("実際の空き容量"), value: capacity(sample?.diskFree), explanation: l.text("削除を待たずに空いている領域です。容量の警告と推移グラフはこの値が基準です。"))
            DetailRow(title: l.text("利用可能容量"), value: capacity(sample?.diskAvailable), explanation: l.text("利用可能は、Time Machineのローカルスナップショットやキャッシュなど、macOSが必要時に削除できる領域を考慮した見積もりです。削除可能の目安は利用可能容量と実際の空き容量との差分で、Time Machine単独の容量ではありません。Finderの表示とは異なる場合があります。取得できない場合は — を表示します。色・警告・グラフは実際の空き容量が基準です。"))
            DetailRow(title: l.text("削除可能容量の目安"), value: capacity(sample?.diskPurgeableEstimate), explanation: l.text("利用可能容量と実際の空きの差分で、Time Machineだけの容量ではありません。"))
            if let used = sample?.diskUsedEstimate, let total = sample?.diskTotal, total > 0 {
                Text(l.text("使用率 %@%%（実際の空き基準）", String(format: "%.1f", used / total * 100)))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.green.opacity(0.2))
                        Capsule().fill(.blue.opacity(0.65)).frame(width: geometry.size.width * min(1, used / total))
                    }
                }.frame(height: 6)
            }
            Divider().padding(.vertical, 3)
            DetailRow(title: l.text("ファイルシステム"), value: sample?.diskFormat ?? "—", explanation: l.text("容量を取得しているボリュームのファイルシステム形式です。"))
            DetailRow(title: l.text("ボリューム"), value: sample?.diskName ?? "—", explanation: "/System/Volumes/Data")
        }
    }
}

private struct MemoryDetails: View {
    @Environment(\.appLocalization) private var l
    let sample: SystemSample?

    private func value(_ key: KeyPath<SystemMetrics, UInt64>) -> String {
        guard let sample, sample.metrics.memory_valid != 0 else { return "—" }
        return memoryGB(sample.metrics[keyPath: key]) + " GB"
    }

    private func row(_ title: String, _ value: String, help: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }.font(.system(size: 10)).help(help)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let sample, let utilization = sample.memoryUtilization {
                Text(l.text("使用 %@ / %@ GB（%@%%）", memoryGB(sample.metrics.memory_used), memoryGB(sample.metrics.memory_total, digits: 0), String(format: "%.0f", utilization)))
                    .font(.system(size: 11)).monospacedDigit()
            } else {
                Text(l.text("使用量 —")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            row(l.text("アプリ用"), value(\.app_memory), help: l.text("匿名メモリから削除可能メモリを除いた概算です。プロセスごとの使用量の単純合計とは異なります。"))
            row(l.text("固定"), value(\.wired), help: l.text("システムなどがRAMに保持する、圧縮やスワップで退避できないメモリです。"))
            row(l.text("圧縮"), value(\.compressed), help: l.text("圧縮されたデータをRAM内に保持するために使っている容量です。圧縮前のデータ量ではありません。アプリ用・固定・圧縮は使用量の内訳です。"))
            row(l.text("キャッシュ目安"), value(\.cached), help: l.text("ファイル関連メモリと削除可能メモリの合計です。再利用できるメモリの概算で、使用量の内訳には含めません。アクティビティモニタのキャッシュ表示とは異なる場合があります。"))
            row(l.text("スワップ"), sample.flatMap { $0.metrics.swap_valid != 0 ? memoryGB($0.metrics.swap_used) + " GB" : nil } ?? "—",
                help: l.text("RAMから起動ディスクへ退避したデータが使う容量です。スワップが残っていても現在のメモリプレッシャーが正常な場合があります。容量だけで警告は判定しません。"))
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String
    let explanation: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }.font(.system(size: 10)).help(explanation)
    }
}

private func percent(_ value: Double?) -> String {
    value.map { String(format: "%.0f%%", $0) } ?? "—"
}

private struct CPUDetails: View {
    @Environment(\.appLocalization) private var l
    let sample: SystemSample?
    var showAverage = false
    private let hardware = HardwareInfo.current
    private var configuration: String {
        var text = hardware.model
        if let cores = hardware.logicalCores { text += l.text(" · %@コア", String(cores)) }
        if let p = hardware.performanceCores, let e = hardware.efficiencyCores { text += l.text("（P%@ / E%@）", String(p), String(e)) }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(configuration).font(.system(size: 11)).foregroundStyle(.secondary)
                .help(l.text("Pは高性能コア、Eは高効率コアの数です。"))
            if showAverage {
                DetailRow(title: l.text("CPU平均使用率"), value: sample.flatMap { $0.metrics.cpu >= 0 ? percent($0.metrics.cpu) : nil } ?? "—", explanation: l.text("全コアの平均使用率"))
            }
            if let m = sample?.metrics, m.cpu >= 0 {
                Text(l.text("ユーザー %@ · システム %@ · 空き %@", percent(m.cpu_user), percent(m.cpu_system), percent(m.cpu_idle)))
                    .font(.system(size: 10)).monospacedDigit()
            } else { Text(l.text("ユーザー — · システム — · 空き —")).font(.system(size: 10)).foregroundStyle(.secondary) }
            DetailRow(title: l.text("負荷平均 1 / 5 / 15分"),
                      value: sample?.loadAverages?.map { String(format: "%.2f", $0) }.joined(separator: " / ") ?? "—",
                      explanation: l.text("実行中・実行待ちの仕事の数の平均です。使用率（%）ではありません。コア数と比較するための参考値で、この値では警告しません。"))
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Label("GPU", systemImage: "square.3.layers.3d")
                Spacer()
                Text(percent(sample?.gpu?.utilization)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
            }.font(.system(size: 12)).foregroundStyle(.blue)
            .help(l.text("GPU全体の使用率です。CPU使用率とは別の値で、足し合わせません。複数GPUがある場合は取得できた中で最も使用率が高いGPUを表示します。GPUの使用率では警告を出しません。"))
            Text(l.text("描画 %@ · タイル %@", percent(sample?.gpu?.renderer), percent(sample?.gpu?.tiler)))
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                .help(l.text("GPUドライバが公開する描画処理・タイル処理の使用率です。別々の処理段階なので合計しません。取得できない項目は — になります。"))
        }
    }
}

private struct SSDDetails: View {
    @Environment(\.appLocalization) private var l
    let reading: Reading?
    private func number(_ value: Double?, suffix: String) -> String {
        value.map { String(format: "%.0f", $0) + suffix } ?? "—"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DetailRow(title: l.text("累積読み取り"), value: reading?.details.readTB.map { String(format: "%.2f TB", $0) } ?? "—", explanation: l.text("SSDが保持するホストからの累積読み取り量です。1 TB＝10¹²バイト。"))
            DetailRow(title: l.text("寿命使用率の目安"), value: number(reading?.details.percentageUsed, suffix: "%"), explanation: l.text("NVMe Percentage Used：メーカーが見積もる耐久性の消費割合です。空き容量や現在の負荷ではなく、0%は1%未満の消費を含みます。100%を超える場合もあり、残り寿命の保証や故障判定ではありません。"))
            DetailRow(title: l.text("予備領域 / しきい値"), value: number(reading?.details.availableSpare, suffix: "%") + " / " + number(reading?.details.spareThreshold, suffix: "%"), explanation: l.text("不良ブロックの置き換えなどに使う予備領域と、SSDが報告する警告しきい値です。ファイル保存用の空き容量とは異なります。"))
            DetailRow(title: l.text("累積稼働時間"), value: number(reading?.details.powerOnHours, suffix: l.text(" 時間")), explanation: l.text("SSDが保持するPower On Hoursです。アプリ起動後の経過時間ではありません。"))
            DetailRow(title: l.text("異常終了の累積"), value: number(reading?.details.unsafeShutdowns, suffix: l.text(" 回")), explanation: l.text("SSDが正常な終了通知を受けずに電源を失った回数です。過去の累積値であり、この値だけで現在の故障や警告とは判定しません。"))
            DetailRow(title: l.text("メディアエラー / 重大警告"), value: number(reading?.details.mediaErrors, suffix: "") + " / " + (reading?.details.criticalWarning.map { String(format: "0x%02X", Int($0)) } ?? "—"), explanation: l.text("メディア・データ整合性エラーの累積件数と、NVMe Critical Warningのビット値です。いずれかが0以外なら、温度とは別にSMART要確認として赤く表示します。"))
        }
    }
}

private struct ExternalStorageDetails: View {
    @Environment(\.appLocalization) private var l
    let storage: ExternalStorage?
    private func capacity(_ value: Double?) -> String { value.map { gb($0) + " GB" } ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DetailRow(title: l.text("使用率 / 残量"), value: percent(storage?.utilization) + " / " + capacity(storage?.free), explanation: l.text("選択した外付けSSDに属するマウント済み領域を集計します。同じAPFSコンテナを二重に数えず、未マウント領域は含めません。"))
            DetailRow(title: l.text("使用容量 / 総容量"), value: capacity(storage?.used) + " / " + capacity(storage?.total), explanation: l.text("使用容量は総容量から実際の空きを引いた概算で、スナップショットなども含みます。SMARTの寿命使用率とは別の値です。"))
            if let storage {
                Text(l.text("対象領域：%@", storage.volumes.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(storage.volumes.map { $0.name + ": " + $0.path }.joined(separator: "\n"))
            } else {
                Text(l.text("容量情報を取得できません")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

// Sum the natural heights of the grid, header and footer. The window adds
// their fixed spacing, padding and status strip without scaling the cards.
private struct DashboardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private struct FullWidthTiles<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { bounds in
            content()
                .frame(width: bounds.size.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: DashboardHeightKey.self, value: geometry.size.height)
                })
                .frame(width: bounds.size.width, height: bounds.size.height, alignment: .top)
        }
        .clipped()
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject private var settings: AppSettings
    @State private var showingSettings = false
    private var l: AppLocalization { settings.localization }
    private var statusColor: Color { monitor.alerts.isEmpty ? (monitor.hasMissingReadings ? .secondary : .green) : monitor.alertColor }
    private var statusText: String {
        if !monitor.alerts.isEmpty { return monitor.alerts.map { $0.text }.joined(separator: " · ") }
        return l.text(monitor.hasMissingReadings ? "一部の情報を取得中／取得できません" : "警告はありません")
    }
    let fitting: Bool
    private let onNaturalHeight: (CGFloat) -> Void
    init(monitor: Monitor, fitting: Bool = false, onNaturalHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.monitor = monitor; self.settings = monitor.settings; self.fitting = fitting
        self.onNaturalHeight = onNaturalHeight
    }
    private var tiles: some View {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Tile(title: l.text("CPU・GPU"), icon: "cpu", color: monitor.cpuColor) {
                    PrimaryMetric(title: l.text(settings.metric(for: .compute).title), value: monitor.presentation(for: settings.metric(for: .compute)))
                    CPUDetails(sample: monitor.system, showAverage: settings.metric(for: .compute) != .cpuUtilization)
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.text("CPU · 直近約%@分", String(settings.systemInterval.rawValue))).font(.system(size: 10)).foregroundStyle(.secondary)
                            Sparkline(values: monitor.cpuHistory, color: monitor.cpuColor, fixedRange: 0...100)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l.text("GPU · 直近約%@分", String(settings.systemInterval.rawValue))).font(.system(size: 10)).foregroundStyle(.secondary)
                            Sparkline(values: monitor.gpuHistory, color: .blue, fixedRange: 0...100)
                        }
                    }
                }
                Tile(title: l.text("メモリ"), icon: "memorychip", color: monitor.pressureColor) {
                    PrimaryMetric(title: l.text(settings.metric(for: .memory).title), value: monitor.presentation(for: settings.metric(for: .memory)))
                    if settings.metric(for: .memory) != .memoryPressure {
                        HStack(spacing: 6) {
                            Circle().fill(monitor.pressureColor).frame(width: 8, height: 8)
                            Text(l.text("メモリプレッシャー") + " · " + monitor.pressureLabel)
                        }.font(.system(size: 12, weight: .medium)).foregroundStyle(monitor.pressureColor)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.pressureDescription)
                        Text(l.text("色・警告は使用率とは別の判定"))
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(l.text("macOSが返すメモリプレッシャーを、正常＝緑、warning＝注意（オレンジ）、critical＝圧迫（赤）として表示します。macOSは空きメモリ、スワップの頻度、固定メモリ、ファイルキャッシュなどを考慮します。使用率やスワップ容量の固定しきい値は使いません。各内訳は状況を把握する参考値で、警告の原因を特定するものではありません。"))
                    MemoryDetails(sample: monitor.system)
                    Spacer(minLength: 0)
                    Text(l.text("推移：使用率（直近約%@分）", String(settings.systemInterval.rawValue))).font(.system(size: 10)).foregroundStyle(.secondary)
                    Sparkline(values: monitor.memoryHistory, color: monitor.pressureColor, fixedRange: 0...100)
                }
                Tile(title: l.text("内蔵SSD"), icon: "internaldrive", color: monitor.diskColor) {
                    PrimaryMetric(title: l.text(settings.metric(for: .disk).title), value: monitor.presentation(for: settings.metric(for: .disk)))
                    Text(monitor.diskDelta).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    DiskDetails(sample: monitor.system)
                    Spacer(minLength: 0)
                    Text(l.text("推移：実際の空き（直近約%@分）", String(settings.systemInterval.rawValue))).font(.system(size: 10)).foregroundStyle(.secondary)
                    Sparkline(values: monitor.diskHistory, color: monitor.diskColor, fixedRange: nil)
                }
                Tile(title: l.text("外付けSSD"), icon: "externaldrive", color: monitor.temperatureColor) {
                    PrimaryMetric(title: l.text(monitor.displayMetric(for: .externalSSD).title), value: monitor.presentation(for: monitor.displayMetric(for: .externalSSD)))
                    if monitor.displayMetric(for: .externalSSD) != settings.metric(for: .externalSSD) {
                        Text(l.text("取得できない代表値の代わりに残量を表示"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(monitor.ssd?.model ?? settings.externalDriveName)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .help(monitor.ssd?.model ?? settings.externalDriveName)
                    if monitor.displayMetric(for: .externalSSD) != .ssdTemperature {
                        DetailRow(title: l.text("現在のSSD温度"), value: monitor.ssd?.temperature.map { "\($0)°C" } ?? "—", explanation: l.text("外付けSSD温度"))
                    }
                    ExternalStorageDetails(storage: monitor.ssd?.storage)
                    Text(monitor.peak.map { l.text("起動後の最高 %@℃", String($0)) } ?? l.text("温度情報なし"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(l.text("累積書き込み ") + (monitor.ssd?.writtenTB.map { String(format: "%.2f", $0) } ?? "—") + " TB")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .help(l.text("SSDが保持するホストからの累積書き込み量です。SSD内部の追加書き込みを含むNAND書き込み量とは異なります。"))
                    if let ssd = monitor.ssd {
                        Text(ssd.hasFault ? l.text("SMART要確認") : ssd.healthy == true ? l.text("SMART正常") : l.text("SMART判定なし"))
                            .font(.system(size: 10)).foregroundStyle(ssd.hasFault ? .red : ssd.healthy == true ? .green : .secondary)
                    }
                    if let error = monitor.ssdError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).help(error)
                    }
                    if monitor.ssd?.hasSMARTData == true { SSDDetails(reading: monitor.ssd) }
                    if let updated = monitor.lastSSDUpdate, monitor.ssd != nil {
                        Text(l.text("更新 %@ · %@秒間隔", updated.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(l.locale)), String(settings.ssdInterval.rawValue))).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Sparkline(values: monitor.temperatureHistory, color: monitor.temperatureColor, fixedRange: 30...80)
                }
            }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.system(size: 22)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.text("Macモニター")).font(.system(size: 17, weight: .semibold))
                    Text(l.text("CPU・GPU・メモリ・ストレージ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(l.text("自動更新中")).font(.system(size: 10)).foregroundStyle(.secondary)
                Button { showingSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help(l.text("設定")).accessibilityLabel(l.text("設定"))
                    .popover(isPresented: $showingSettings, arrowEdge: .bottom) { SettingsPanel(settings: settings, drives: monitor.externalDrives, scanning: monitor.ssdBusy, onRescan: monitor.refreshExternal) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: DashboardHeightKey.self, value: geometry.size.height)
            })
            Label(statusText, systemImage: monitor.alerts.isEmpty ? (monitor.hasMissingReadings ? "ellipsis.circle" : "checkmark.circle.fill") : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).lineLimit(2)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 44)
                .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .help(statusText)
            if fitting { FullWidthTiles { tiles } } else { tiles }
            HStack(spacing: 12) {
                Text(l.text("色で確認：正常 / 注意 / 警戒")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(l.text("空き20 GB未満で注意、10 GB未満で警戒。SSD温度65℃以上で注意、70℃以上で警戒（冷却確認の目安）。メモリはmacOSのプレッシャー判定。CPU90%以上が30秒続くと注意。"))
                Spacer()
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help(l.text("今すぐ更新"))
                Button(l.text("終了")) { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: DashboardHeightKey.self, value: geometry.size.height)
            })
        }
        .onPreferenceChange(DashboardHeightKey.self) { height in
            if fitting { onNaturalHeight(ceil(height + 44 + 32 + 36)) }
        }
        .padding(16)
        .frame(width: 680)
        .frame(maxHeight: fitting ? .infinity : nil)
        .background(.regularMaterial)
        .environment(\.appLocalization, l)
        .environment(\.locale, l.locale)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var l: AppLocalization { monitor.settings.localization }
    private var item: NSStatusItem!
    private var dashboardWindow: NSWindow!
    private var preferredDashboardHeight: CGFloat = 900
    private var menuWidths = MenuWidthCache()
    func applicationDidFinishLaunching(_ notification: Notification) {
        for previous in NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.dataarthub.mac-monitor")
            where previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous.terminate()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Mac …"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        let controller = NSHostingController(rootView: Dashboard(monitor: monitor, fitting: true) { [weak self] height in
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.preferredDashboardHeight - height) > 1 else { return }
                self.preferredDashboardHeight = height
                self.updateTitle()
            }
        })
        controller.sizingOptions = []
        dashboardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: preferredDashboardHeight),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        dashboardWindow.title = l.text("Macモニター")
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.contentViewController = controller
        dashboardWindow.level = .floating
        dashboardWindow.collectionBehavior = [.moveToActiveSpace]
        dashboardWindow.center()
        monitor.onChange = { [weak self] in self?.updateTitle() }
        monitor.settings.onChange = { [weak self] in self?.updateTitle() }
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.toggle() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    private func updateTitle() {
        guard let button = item.button else { return }
        let alerts = monitor.alerts
        if let screen = dashboardWindow.screen ?? NSScreen.main {
            let preferred = dashboardWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 680, height: preferredDashboardHeight)).size
            let fitted = fittedDashboardFrame(current: dashboardWindow.frame, visible: screen.visibleFrame, preferred: preferred)
            if dashboardWindow.frame != fitted { dashboardWindow.setFrame(fitted, display: true) }
        }
        dashboardWindow.title = l.text("Macモニター")
        var parts: [BarPart] = []
        if !alerts.isEmpty {
            parts.append(BarPart(symbol: "exclamationmark.triangle.fill", text: "",
                                 color: alerts.contains(where: { $0.critical }) ? .systemRed : .systemOrange))
        }
        var descriptions: [String] = []
        for group in MetricGroup.menuOrder where !monitor.settings.hiddenMenuGroups.contains(group) {
            let metric = monitor.displayMetric(for: group)
            let value = monitor.presentation(for: metric)
            parts.append(BarPart(symbol: value.symbol, text: value.menuText, color: NSColor(value.color), reservedTextWidth: menuWidths.width(for: metric, text: value.menuText, using: l)))
            descriptions.append(l.text(metric.title) + ": " + value.menuText)
        }
        if descriptions.isEmpty {
            parts = [BarPart(symbol: alerts.isEmpty ? "waveform.path.ecg" : "exclamationmark.triangle.fill", text: "",
                             color: alerts.isEmpty ? .labelColor : alerts.contains(where: { $0.critical }) ? .systemRed : .systemOrange)]
        }
        let normalTitle = descriptions.isEmpty ? l.text("Macモニター") : descriptions.joined(separator: "  ")
        button.attributedTitle = NSAttributedString(string: "")
        button.image = menuImage(parts)
        button.imagePosition = .imageOnly
        let alertSummary = alerts.map { $0.text }.joined(separator: " · ")
        button.setAccessibilityLabel(normalTitle + (alerts.isEmpty ? "" : " · " + alertSummary))
        var toolTip = [l.text("クリックして詳細を確認"), normalTitle]
        if !alerts.isEmpty { toolTip.append(alertSummary) }
        toolTip.append(l.text("メモリの色・警告はmacOSのメモリプレッシャーが基準です。"))
        if let error = monitor.ssdError { toolTip.append(error) }
        button.toolTip = toolTip.joined(separator: "\n")
    }

    @objc private func wake() { monitor.refresh() }
    @objc private func toggle() {
        if dashboardWindow.isVisible { dashboardWindow.close() }
        else {
            monitor.refresh()
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated {
        let settings = AppSettings(defaults: nil, preferredLanguages: ["ja"])
        let monitor = Monitor(settings: settings)
        @MainActor func sample(free: Double, pressure: UInt32, valid: Bool = true, cpu: Double = 10) {
            var m = SystemMetrics()
            m.cpu = cpu
            m.pressure = pressure
            m.pressure_valid = valid ? 1 : 0
            monitor.system = SystemSample(metrics: m, diskFree: free, diskTotal: 500e9)
        }
        @MainActor func temp(_ value: Int, errors: Int = 0) {
            monitor.ssd = Reading(model: "CT2000T500SSD8", temperature: value, writtenTB: 0,
                                  criticalWarning: 0, mediaErrors: errors, healthy: true)
        }
        sample(free: 20e9, pressure: 0); temp(64)
        precondition(monitor.alerts.isEmpty, "正常時に警告を出さない")
        sample(free: 19.9e9, pressure: 0)
        precondition(monitor.alerts.count == 1 && !monitor.alerts[0].critical, "空き20GB未満で注意")
        sample(free: 9.9e9, pressure: 0)
        precondition(monitor.alerts.contains(where: { $0.critical }), "空き10GB未満で警戒")
        sample(free: 50e9, pressure: 1)
        precondition(monitor.alerts.count == 1 && !monitor.alerts[0].critical, "OSのメモリ注意を表示")
        sample(free: 50e9, pressure: 2)
        precondition(monitor.alerts[0].critical, "OSのメモリ圧迫を表示")
        sample(free: 50e9, pressure: 2, valid: false)
        precondition(monitor.alerts.isEmpty && monitor.pressureLabel == "取得待ち", "取得失敗を正常扱いしない")
        sample(free: 50e9, pressure: 0); temp(65)
        precondition(monitor.alerts.count == 1 && !monitor.alerts[0].critical, "65℃で注意")
        temp(70)
        precondition(monitor.alerts[0].critical, "70℃で警戒")
        temp(56, errors: 1)
        precondition(monitor.alerts[0].critical, "温度が低くてもSMARTエラーは警戒")
        temp(56)
        precondition(monitor.alerts.isEmpty, "回復したら警告を解除")
        monitor.ssd = nil
        precondition(monitor.alerts.isEmpty, "未取得の温度を高温と誤判定しない")
        sample(free: 50e9, pressure: 0, cpu: 69.9)
        precondition(monitor.cpuColor == .green, "CPU低負荷は緑")
        sample(free: 50e9, pressure: 0, cpu: 70)
        precondition(monitor.cpuColor == .orange, "CPU70%以上はオレンジ")
        sample(free: 50e9, pressure: 0, cpu: 90)
        precondition(monitor.cpuColor == .red, "CPU90%以上は赤")
        precondition(SSDReader.writtenTerabytes(from: ["data_units_written": 1_953_125]) == 1.0, "NVMe単位から1 TBへ換算")
        precondition(SSDReader.writtenTerabytes(from: ["data_units_written": 0]) == 0, "未使用の0を正しく表示")
        precondition(SSDReader.writtenTerabytes(from: [:]) == nil, "未取得を0 TBと誤表示しない")
        precondition(SSDReader.writtenTerabytes(from: ["data_units_written": -1]) == nil, "不正なカウンターを表示しない")
        let capacitySample = SystemSample(metrics: SystemMetrics(), diskFree: 10e9, diskTotal: 500e9, diskAvailable: 80e9)
        precondition(capacitySample.diskAvailable == 80e9 && capacitySample.diskPurgeableEstimate == 70e9, "利用可能容量には実際の空きを二重加算しない")
        precondition(SystemSample(metrics: SystemMetrics(), diskFree: 10e9, diskTotal: 500e9).diskPurgeableEstimate == nil, "取得不能を削除可能0と誤表示しない")
        precondition(SystemSample(metrics: SystemMetrics(), diskFree: nil, diskTotal: 500e9, diskAvailable: 80e9).diskPurgeableEstimate == nil, "空き未取得時は差分を表示しない")
        precondition(SystemSample(metrics: SystemMetrics(), diskFree: 10e9, diskTotal: 500e9, diskAvailable: 9e9).diskPurgeableEstimate == 0, "読み取り差で削除可能を負にしない")
        precondition(SystemSample(metrics: SystemMetrics(), diskFree: 10e9, diskTotal: 500e9, diskAvailable: -1).diskAvailable == nil, "不正な容量を表示しない")
        monitor.system = SystemSample(metrics: SystemMetrics(), diskFree: 9e9, diskTotal: 500e9, diskAvailable: 80e9)
        precondition(monitor.diskColor == .red && monitor.alerts.contains(where: { $0.critical }), "削除可能領域があっても実際の空きの警告を維持")
        var memoryMetrics = SystemMetrics()
        memoryMetrics.memory_valid = 1
        memoryMetrics.pressure_valid = 1
        memoryMetrics.memory_total = 16 * 1_073_741_824
        memoryMetrics.memory_used = 15 * 1_073_741_824
        monitor.system = SystemSample(metrics: memoryMetrics, diskFree: 50e9, diskTotal: 500e9)
        precondition(monitor.pressureColor == .green && monitor.alerts.isEmpty, "使用率が高くてもOS判定が正常ならメモリ警告を出さない")
        memoryMetrics.memory_used = 8 * 1_073_741_824
        memoryMetrics.pressure = 1
        monitor.system = SystemSample(metrics: memoryMetrics, diskFree: 50e9, diskTotal: 500e9)
        precondition(monitor.system?.memoryUtilization == 50 && monitor.pressureColor == .orange && monitor.alerts.count == 1, "使用率50%でもOS判定が注意なら警告を出す")
        memoryMetrics.memory_total = 0
        precondition(SystemSample(metrics: memoryMetrics, diskFree: nil, diskTotal: nil).memoryUtilization == nil, "総容量未取得時は使用率を表示しない")
        precondition(GPUReading.percentage(0) == 0, "GPUの0%を未取得と区別")
        precondition(GPUReading.from(statistics: [:], model: "GPU") == nil, "未取得GPUを0%と誤表示しない")
        precondition(GPUReading.percentage(-1) == nil, "負のGPU値を除外")
        precondition(GPUReading.percentage(101) == nil, "100%を超えるGPU値を除外")
        let partialGPU = GPUReading.from(statistics: ["Device Utilization %": 30, "Renderer Utilization %": -1], model: "GPU")
        precondition(partialGPU?.utilization == 30 && partialGPU?.renderer == nil && partialGPU?.tiler == nil, "GPUの一部指標が欠けても全体の値を保持")
        precondition(GPUReading.percentage(true) == nil, "GPUの真偽値を使用率と誤解しない")
        let missingHealth = SSDHealthDetails(health: [:])
        precondition(missingHealth.readTB == nil && missingHealth.percentageUsed == nil && missingHealth.powerOnHours == nil, "未取得SMART詳細を0と誤表示しない")
        let zeroHealth = SSDHealthDetails(health: ["data_units_read": 0, "percentage_used": 0, "power_on_hours": 0])
        precondition(zeroHealth.readTB == 0 && zeroHealth.percentageUsed == 0 && zeroHealth.powerOnHours == 0, "SMART詳細の有効な0を表示")
        precondition(SSDHealthDetails(health: ["percentage_used": 150]).percentageUsed == 150, "寿命使用率が100%を超えても保持")
        let invalidHealth = SSDHealthDetails(health: ["available_spare": 101, "percentage_used": 256, "power_on_hours": -1])
        precondition(invalidHealth.availableSpare == nil && invalidHealth.percentageUsed == nil && invalidHealth.powerOnHours == nil, "不正なSMART詳細を除外")
        precondition(SSDHealthDetails(health: ["data_units_read": 1_953_125]).readTB == 1, "NVMe読み取り単位からTBへ換算")
        precondition(SystemSample(metrics: SystemMetrics(), diskFree: nil, diskTotal: nil).cpuCores.isEmpty, "未取得CPUコアを空配列として表示")
        precondition(AppLanguage.automatic.code(preferredLanguages: ["ja-JP"]) == "ja", "自動：日本語のmacOS設定に追従")
        precondition(AppLanguage.automatic.code(preferredLanguages: ["en-US"]) == "en", "自動：英語のmacOS設定に追従")
        precondition(AppLanguage.automatic.code(preferredLanguages: ["fr-FR"]) == "en", "未対応言語は英語にフォールバック")
        precondition(AppLanguage.japanese.code(preferredLanguages: ["en"]) == "ja", "明示指定はOS言語より優先")
        settings.language = .english
        precondition(settings.localization.text("設定") == "Settings", "英語リソースがアプリに組み込まれている")
        sample(free: 50e9, pressure: 1)
        precondition(monitor.pressureLabel == "Warning" && monitor.alerts[0].text == "Memory pressure warning", "既存の状態・警告も言語変更に追従")
        monitor.ssdFailure = ReadError.disconnected
        precondition(monitor.ssdError?.contains("selected external SSD was not found") == true, "エラーも英語表示")
        settings.language = .japanese
        precondition(monitor.ssdError?.contains("選択した外付けSSDが見つかりません") == true, "保存済みエラーが再読み取りなしで言語変更に追従")
        final class TestPreferences: PreferencesStore {
            var values: [String: Any] = [:]
            func string(forKey key: String) -> String? { values[key] as? String }
            func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
            func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
            func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
            func set(_ value: Any?, forKey key: String) { values[key] = value }
        }
        let storage = TestPreferences()
        let preferences = AppSettings(defaults: storage)
        precondition(MetricGroup.allCases.allSatisfy { preferences.metric(for: $0) == $0.defaultMetric }, "初期値は従来の4項目")
        preferences.language = .english
        preferences.select(.gpuUtilization, for: .compute)
        preferences.select(.diskAvailable, for: .disk)
        let restored = AppSettings(defaults: storage)
        precondition(restored.language == .english && restored.metric(for: .compute) == .gpuUtilization && restored.metric(for: .disk) == .diskAvailable, "表示する数値を保存・再読込")
        preferences.select(.swap, for: .compute)
        precondition(preferences.metric(for: .compute) == .gpuUtilization, "異なるグループの値を誤保存しない")
        storage.values = ["displayLanguage": "invalid", "primaryMetrics": ["compute": "diskFree", "memory": "swap", "disk": "invalid"]]
        let repaired = AppSettings(defaults: storage)
        precondition(repaired.language == .automatic && repaired.metric(for: .compute) == .cpuUtilization && repaired.metric(for: .memory) == .swap && repaired.metric(for: .disk) == .diskFree, "不正な保存値を安全に読み込む")
        let diskSample = SystemSample(metrics: SystemMetrics(), diskFree: 10e9, diskTotal: 100e9, diskAvailable: 40e9)
        monitor.system = diskSample
        precondition(diskSample.diskUsedEstimate == 90e9 && monitor.presentation(for: .diskAvailable).value == "40.0", "使用容量と利用可能容量を混同しない")
        precondition(monitor.presentation(for: .diskFree).value == "10.0" && monitor.presentation(for: .diskPurgeable).value == "30.0", "表示の切替で対象の数値が変わる")
        monitor.system = nil
        precondition(monitor.presentation(for: .diskUsed).value == "—", "未取得の選択値を0と誤表示しない")
        precondition(preferences.systemInterval == .two && preferences.ssdInterval == .fifteen, "更新間隔の初期値")
        preferences.systemInterval = .five
        preferences.ssdInterval = .thirty
        let restoredIntervals = AppSettings(defaults: storage)
        precondition(restoredIntervals.systemInterval == .five && restoredIntervals.ssdInterval == .thirty, "2種類の更新間隔を保存・復元")
        storage.values = ["systemRefreshSeconds": -1, "ssdRefreshSeconds": 1]
        let invalidIntervals = AppSettings(defaults: storage)
        precondition(invalidIntervals.systemInterval == .two && invalidIntervals.ssdInterval == .fifteen, "不正な更新間隔を初期値へ戻す")
        let container: [String: Any] = ["DeviceIdentifier": "disk8", "APFSPhysicalStores": [["DeviceIdentifier": "disk6s2"]], "APFSVolumes": [["VolumeName": "Data", "MountPoint": "/Volumes/Data"], ["VolumeName": "Unmounted"]]]
        let otherContainer: [String: Any] = ["DeviceIdentifier": "disk9", "APFSPhysicalStores": [["DeviceIdentifier": "disk60s2"]], "APFSVolumes": [["VolumeName": "Other", "MountPoint": "/Volumes/Other"]]]
        let candidates = ExternalStorageReader.mountedCandidates(list: ["AllDisksAndPartitions": [container, otherContainer]], physicalDisk: "disk6")
        precondition(candidates.count == 1 && candidates.first?.name == "Data", "似た番号の別SSDや未マウント領域を混ぜない")
        let externalSpace = ExternalStorage(volumes: [ExternalVolume(group: "A", name: "A1", path: "/A1", total: 100e9, free: 20e9), ExternalVolume(group: "A", name: "A2", path: "/A2", total: 100e9, free: 20e9), ExternalVolume(group: "B", name: "B", path: "/B", total: 50e9, free: 5e9)])
        precondition(externalSpace.total == 150e9 && externalSpace.free == 25e9 && externalSpace.used == 125e9, "共有APFSコンテナを二重に集計しない")
        monitor.ssd = Reading(model: "T500", temperature: 50, writtenTB: nil, criticalWarning: 0, mediaErrors: 0, healthy: true, storage: externalSpace)
        precondition(monitor.presentation(for: .ssdStorageFree).value == "25.0" && monitor.presentation(for: .ssdStorageUtilization).value == "83", "外付けSSDの残量と使用率を選択表示")
        monitor.ssd = nil
        precondition(monitor.presentation(for: .ssdStorageFree).value == "—", "外付け容量の未取得を0と誤表示しない")
        preferences.select(.gpuUtilization, for: .compute)
        preferences.hideMenuGroup(.compute)
        let hiddenRestored = AppSettings(defaults: storage)
        precondition(hiddenRestored.hiddenMenuGroups == [.compute] && hiddenRestored.metric(for: .compute) == .gpuUtilization, "非表示を保存し詳細の代表値は保持")
        hiddenRestored.select(.cpuUtilization, for: .compute)
        precondition(hiddenRestored.hiddenMenuGroups.isEmpty && hiddenRestored.metric(for: .compute) == .cpuUtilization, "代表値を選ぶとメニューバーへ再表示")
        let screenBounds = NSRect(x: 0, y: 20, width: 1280, height: 700)
        let fitted = fittedDashboardFrame(current: NSRect(x: 1000, y: -100, width: 624, height: 1000), visible: screenBounds, preferred: NSSize(width: 624, height: 862))
        precondition(screenBounds.contains(fitted) && fitted.height <= 684, "警告があっても画面内に収める")
        let secondaryScreen = NSRect(x: -1440, y: -200, width: 1440, height: 900)
        precondition(secondaryScreen.contains(fittedDashboardFrame(current: NSRect(x: -1500, y: -300, width: 624, height: 950), visible: secondaryScreen, preferred: NSSize(width: 624, height: 862))), "別画面の負の座標でもはみ出さない")
        var completeMetrics = SystemMetrics()
        completeMetrics.cpu = 10; completeMetrics.memory_valid = 1; completeMetrics.pressure_valid = 1; completeMetrics.swap_valid = 1
        monitor.system = SystemSample(metrics: completeMetrics, diskFree: 50e9, diskTotal: 100e9)
        monitor.ssd = Reading(model: "T500", temperature: 50, writtenTB: nil, criticalWarning: 0, mediaErrors: 0, healthy: true, storage: externalSpace)
        precondition(!monitor.hasMissingReadings && monitor.alerts.isEmpty, "正常時にグリーンの状態欄を表示できる")
        monitor.ssd = nil
        precondition(monitor.hasMissingReadings, "未取得をグリーンの正常状態と誤表示しない")
        var widthCache = MenuWidthCache()
        func barPart(_ metric: DisplayMetric, _ text: String, _ localization: AppLocalization = AppLocalization(code: "ja")) -> BarPart {
            BarPart(symbol: "cpu", text: text, color: .labelColor,
                    reservedTextWidth: widthCache.width(for: metric, text: text, using: localization))
        }
        let utilizationWidths = ["—", "0%", "9%", "10%", "99%", "100%"].map { menuImage([barPart(.cpuUtilization, $0)]).size.width }
        precondition(Set(utilizationWidths).count == 1, "使用率は必要な3桁分だけ確保し更新で動かない")
        let initialCapacityWidth = menuSlotWidths([barPart(.diskFree, "46.2GB")])[0]
        precondition(initialCapacityWidth == 17 + ceil(menuTextWidth("46.2GB")), "容量に未使用の桁数の余白を設けない")
        let pressureWidths = ["Normal", "Warning", "Critical", "—"].map { menuImage([barPart(.memoryPressure, $0, AppLocalization(code: "en"))]).size.width }
        precondition(Set(pressureWidths).count == 1, "英語のプレッシャー状態変更で幅を変えない")
        let compactParts = [barPart(.ssdTemperature, "53°C"), barPart(.cpuUtilization, "9%"), barPart(.memoryUtilization, "79%"), barPart(.diskFree, "46.2GB")]
        let activeAlert = BarPart(symbol: "exclamationmark.triangle.fill", text: "", color: .systemRed)
        precondition(menuImage([activeAlert] + compactParts).size.width - menuImage(compactParts).size.width == 23, "警告用の23ポイントは警告がある時だけ追加")
        let capacitySequence = ["100.0GB", "99.9GB", "9.9GB", "100.0GB", "—"].map { menuSlotWidths([barPart(.diskFree, $0)])[0] }
        precondition(Set(capacitySequence).count == 1 && capacitySequence[0] > initialCapacityWidth, "新しい桁数に必要な分だけ広げ、その後は伸縮を繰り返さない")
        precondition(menuImage([BarPart(symbol: "waveform.path.ecg", text: "", color: .labelColor)]).size.width == 14, "全欄非表示ではアイコンだけの幅を維持")
        let driveA = ExternalDrive(id: "uuid:SSD-A", disk: "disk6", name: "Example NVMe", size: 150e9, solidState: true, storage: externalSpace)
        let driveB = ExternalDrive(id: "uuid:SSD-B", disk: "disk7", name: "USB SSD", size: 500e9, solidState: nil, storage: nil)
        let partitionID = ExternalStorageReader.identity(entry: ["DeviceIdentifier": "disk6", "Partitions": [["DiskUUID": "a"], ["DiskUUID": "b"]]], info: [:], sessionID: nil)
        precondition(partitionID == ExternalStorageReader.identity(entry: ["DeviceIdentifier": "disk20", "Partitions": [["DiskUUID": "B"], ["DiskUUID": "A"]]], info: [:], sessionID: nil), "ディスク番号・列挙順が変わっても同じSSDを識別")
        precondition(ExternalStorageReader.identity(entry: ["DeviceIdentifier": "disk6"], info: [:], sessionID: nil) == nil, "識別情報なしでディスク番号だけを保存しない")
        precondition(ExternalStorageReader.identity(entry: [:], info: [:], sessionID: 123)?.hasSuffix(":123") == true, "未フォーマット媒体はセッション限定の識別子")
        let externalInfo: [String: Any] = ["Internal": false, "WholeDisk": true, "VirtualOrPhysical": "Physical"]
        precondition(ExternalStorageReader.isCandidate(info: externalInfo), "USBケースでSSD種別が不明でも選択候補に含める")
        var excludedInfo = externalInfo; excludedInfo["SolidState"] = false
        precondition(!ExternalStorageReader.isCandidate(info: excludedInfo), "明確にHDDと報告されるドライブはSSD候補に含めない")
        excludedInfo = externalInfo; excludedInfo["Internal"] = true
        precondition(!ExternalStorageReader.isCandidate(info: excludedInfo), "内蔵ドライブを外付けの候補に混ぜない")
        excludedInfo = externalInfo; excludedInfo["VirtualOrPhysical"] = "Virtual"
        precondition(!ExternalStorageReader.isCandidate(info: excludedInfo), "ディスクイメージを候補に混ぜない")
        precondition(ExternalStorageReader.physicalDisk(devicePath: "/dev/rdisk20s2") == "disk20", "rawデバイスとパーティションを物理ディスクへ対応付け")
        let noToolPoll = SSDReader(binary: nil, inventory: { [driveA, driveB] }).poll(selectedID: driveA.id)
        precondition(noToolPoll.reading?.storage?.free == 25e9 && noToolPoll.reading?.temperature == nil && noToolPoll.issue != nil, "smartctlなしでも選択SSDの容量を表示")
        precondition(noToolPoll.reading?.healthy == nil && noToolPoll.reading?.hasFault == false && noToolPoll.reading?.criticalWarning == nil, "SMART未取得を正常・故障・警告0と誤認しない")
        let unplugged = SSDReader(binary: nil, inventory: { [driveB] }).poll(selectedID: driveA.id)
        precondition(unplugged.reading == nil && unplugged.selected == nil && unplugged.drives.count == 1, "選択SSDの切断時に他のSSDへ切り替えない")
        let duplicatePoll = SSDReader(binary: nil, inventory: { [driveA, driveA] }).poll(selectedID: driveA.id)
        precondition(duplicatePoll.reading == nil, "複製された識別情報が曖昧なら誤選択せず停止")
        let brokenSMART = SSDReader(binary: "fixture", inventory: { [driveA] }, command: { _ in throw ReadError.smartUnavailable }).poll(selectedID: driveA.id)
        precondition(brokenSMART.reading?.storage?.total == 150e9 && brokenSMART.reading?.hasSMARTData == false, "SMART読み取り失敗でも容量を失わない")
        let genericNVMe: [String: Any] = ["model_name": "OTHER BRAND NVMe", "smart_status": ["passed": true], "nvme_smart_health_information_log": ["temperature": 42, "critical_warning": 0, "media_errors": 0, "data_units_written": 1_953_125]]
        let parsedNVMe = SSDReader.parse(genericNVMe, drive: driveA)
        precondition(parsedNVMe.model == "OTHER BRAND NVMe" && parsedNVMe.temperature == 42 && parsedNVMe.writtenTB == 1, "T500以外のNVMeモデルを読み取れる")
        let sata = SSDReader.parse(["model_name": "SATA SSD", "smart_status": ["passed": true], "temperature": ["current": 35], "power_on_time": ["hours": 120], "ata_smart_attributes": ["table": [["id": 241, "raw": ["value": 999]]]]], drive: driveB)
        precondition(sata.temperature == 35 && sata.healthy == true && sata.details.powerOnHours == 120, "SATAの共通JSON温度・SMART判定・稼働時間に対応")
        precondition(sata.writtenTB == nil && sata.details.readTB == nil && sata.criticalWarning == nil && sata.mediaErrors == nil, "メーカー依存ATAカウンターをNVMe単位と誤換算しない")
        let partialSMART = SSDReader.parse(["temperature": ["current": 31]], drive: driveA)
        precondition(partialSMART.temperature == 31 && partialSMART.healthy == nil && !partialSMART.hasFault, "温度だけ読めてもSMART正常を捏造しない")
        let faulty = SSDReader.parse(["smart_status": ["passed": false]], drive: driveA)
        precondition(faulty.hasFault && faulty.temperature == nil, "温度が取れなくても明示的なSMART異常を検知")
        precondition(SSDReader.parse(["temperature": ["current": 0]], drive: driveA).temperature == 0, "有効な0℃を未取得と区別")
        precondition(SSDReader.parse(["temperature": ["current": true]], drive: driveA).temperature == nil, "真偽値を温度と誤認しない")
        precondition(SSDReader.parse(["temperature": ["current": 150]], drive: driveA).temperature == nil, "不正な温度を除外")
        let unknownSMART = SSDReader(binary: "fixture", inventory: { [driveA] }, command: { _ in ["model_name": "USB bridge", "smart_support": ["available": false]] }).poll(selectedID: driveA.id)
        precondition(unknownSMART.reading?.storage != nil && unknownSMART.reading?.hasSMARTData == false && unknownSMART.issue != nil, "SMART非対応のJSONでも容量フォールバック")
        let satTarget = SSDReader.smartTarget(devices: [["name": "/dev/disk6", "type": "sat"]], drive: driveA)
        precondition(satTarget.path == "/dev/disk6" && satTarget.type == "sat", "scanのSATAブリッジ種別をそのまま使う")
        let unmatched = SSDReader.smartTarget(devices: [["name": "/dev/disk0", "type": "nvme"]], drive: driveA)
        precondition(unmatched.path == "/dev/disk6" && unmatched.type == nil, "選択SSDに一致しない内蔵SMARTデバイスを読み取らない")
        var usedArguments: [[String]] = []
        let fixtureReader = SSDReader(binary: "fixture", inventory: { [driveA] }, command: { args in
            usedArguments.append(args)
            return args.first == "--scan" ? ["devices": [["name": "/dev/disk6", "type": "sat"]]] : genericNVMe
        })
        let fixturePoll = fixtureReader.poll(selectedID: driveA.id)
        precondition(fixturePoll.reading?.temperature == 42 && usedArguments.last == ["-a", "-j", "-d", "sat", "/dev/disk6"], "選択したドライブだけに読み取り専用SMARTコマンドを実行")
        let selectionStore = TestPreferences()
        let selectionSettings = AppSettings(defaults: selectionStore)
        selectionSettings.selectExternalDrive(driveA)
        let recoveredSelection = AppSettings(defaults: selectionStore)
        precondition(recoveredSelection.externalDriveID == driveA.id && recoveredSelection.externalDriveName == driveA.name, "選択SSDと未接続時の名前を保存・復元")
        let selectionMonitor = Monitor(settings: selectionSettings)
        selectionMonitor.applyExternalPoll(noToolPoll, generation: selectionMonitor.driveGeneration)
        precondition(selectionMonitor.displayMetric(for: .externalSSD) == .ssdStorageFree && selectionSettings.metric(for: .externalSSD) == .ssdTemperature, "取得不能な代表値は残量へフォールバックし保存設定は保持")
        selectionMonitor.applyExternalPoll(fixturePoll, generation: selectionMonitor.driveGeneration)
        precondition(selectionMonitor.displayMetric(for: .externalSSD) == .ssdTemperature, "SMARTが復帰したら元の代表値を再表示")
        let oldGeneration = selectionMonitor.driveGeneration
        selectionSettings.selectExternalDrive(driveB)
        precondition(selectionMonitor.ssd == nil && selectionMonitor.peak == nil && selectionMonitor.temperatureHistory.isEmpty, "ドライブ選択直後に前の値・最高温度・グラフを消去")
        precondition(!selectionMonitor.applyExternalPoll(fixturePoll, generation: oldGeneration) && selectionMonitor.ssd == nil, "選択前に始まった遅い読み取り結果を破棄")
        let unmounted = SSDReader.parse(genericNVMe, drive: driveB)
        precondition(unmounted.storage == nil && unmounted.temperature == 42, "未マウントでもSMART情報が読める場合は保持")
        let changedNumber = ExternalDrive(id: driveA.id, disk: "disk20", name: driveA.name, size: driveA.size, solidState: true, storage: externalSpace)
        precondition((try? ExternalStorageReader.selected(from: [changedNumber], id: driveA.id))?.disk == "disk20", "再接続でディスク番号が変わっても選択を維持")
        selectionMonitor.ssd = faulty
        precondition(selectionMonitor.alerts.contains(where: { $0.critical }) && selectionMonitor.temperatureColor == .red, "温度なしのSMART異常も画面・警告へ反映")
        precondition(SSDReader.writtenTerabytes(from: ["data_units_written": Double.greatestFiniteMagnitude]) == nil && SSDHealthDetails(health: ["data_units_read": Double.greatestFiniteMagnitude]).readTB == nil, "換算で無限大になる不正な転送カウンターを除外")
        let ambiguousFirst = SSDReader(binary: nil, inventory: { [driveA, driveA] }).poll(selectedID: nil)
        precondition(ambiguousFirst.reading == nil, "初回自動選択でも重複した識別情報を誤選択しない")
        let spanningContainer: [String: Any] = ["DeviceIdentifier": "disk10", "APFSPhysicalStores": [["DeviceIdentifier": "disk6s2"], ["DeviceIdentifier": "disk7s2"]], "APFSVolumes": [["VolumeName": "Spanning", "MountPoint": "/Volumes/Spanning"]]]
        precondition(ExternalStorageReader.mountedCandidates(list: ["AllDisksAndPartitions": [spanningContainer]], physicalDisk: "disk6").isEmpty, "複数物理ディスクの共有容量を一台分と誤集計しない")
        print("メトリクス・設定・言語・外付け選択・SMARTフォールバック・レイアウト：109項目 OK")
    }
} else if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
    let outputPath = CommandLine.arguments[index + 1]
    _ = SystemSample.read()
    Thread.sleep(forTimeInterval: 0.25)
    let sample = SystemSample.read()
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let settings = AppSettings(defaults: nil, preferredLanguages: ["ja"])
        if let languageIndex = CommandLine.arguments.firstIndex(of: "--preview-language"), CommandLine.arguments.count > languageIndex + 1 {
            settings.language = AppLanguage(rawValue: CommandLine.arguments[languageIndex + 1]) ?? .automatic
        }
        let monitor = Monitor(settings: settings)
        monitor.system = sample
        if sample.metrics.cpu >= 0 { monitor.cpuHistory = [sample.metrics.cpu, sample.metrics.cpu] }
        if let gpu = sample.gpu { monitor.gpuHistory = [gpu.utilization, gpu.utilization] }
        monitor.applyExternalPoll(SSDReader().poll(selectedID: nil), generation: monitor.driveGeneration)
        let preview: AnyView = CommandLine.arguments.contains("--preview-settings")
            ? AnyView(SettingsPanel(settings: settings, drives: monitor.externalDrives)) : AnyView(Dashboard(monitor: monitor))
        if CommandLine.arguments.contains("--preview-settings") {
            // Native macOS pickers/buttons cannot be drawn by ImageRenderer.
            let hosting = NSHostingView(rootView: preview.environment(\.colorScheme, .light).background(Color.white))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do { try png.write(to: URL(fileURLWithPath: outputPath)); print("画面プレビュー保存：" + outputPath) }
                    catch { fputs("プレビュー保存失敗：\(error)\n", stderr); exit(1) }
                } else { exit(1) }
            } else { exit(1) }
            return
        }
        let renderer = ImageRenderer(content: preview.environment(\.colorScheme, .light))
        renderer.scale = 2
        if let image = renderer.cgImage {
            let bitmap = NSBitmapImageRep(cgImage: image)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                do { try png.write(to: URL(fileURLWithPath: outputPath)); print("画面プレビュー保存：" + outputPath) }
                catch { fputs("プレビュー保存失敗：\(error)\n", stderr); exit(1) }
            } else { exit(1) }
        } else { fputs("画面描画に失敗しました\n", stderr); exit(1) }
    }
} else if CommandLine.arguments.contains("--check") {
    _ = SystemSample.read()
    Thread.sleep(forTimeInterval: 0.25)
    let s = SystemSample.read()
    var report: [String: Any] = ["cpu_percent": s.metrics.cpu, "memory_valid": s.metrics.memory_valid != 0,
                               "memory_used_bytes": s.metrics.memory_used, "memory_total_bytes": s.metrics.memory_total,
                               "pressure_valid": s.metrics.pressure_valid != 0, "pressure": s.metrics.pressure,
                               "swap_valid": s.metrics.swap_valid != 0, "swap_used_bytes": s.metrics.swap_used]
    if s.metrics.memory_valid != 0 {
        report["memory_app_bytes"] = s.metrics.app_memory
        report["memory_wired_bytes"] = s.metrics.wired
        report["memory_compressed_bytes"] = s.metrics.compressed
        report["memory_cached_estimate_bytes"] = s.metrics.cached
    }
    if let utilization = s.memoryUtilization { report["memory_utilization_percent"] = utilization }
    report["cpu_model"] = HardwareInfo.current.model
    if let cores = HardwareInfo.current.logicalCores { report["cpu_logical_cores"] = cores }
    if s.metrics.cpu >= 0 {
        report["cpu_user_percent"] = s.metrics.cpu_user
        report["cpu_system_percent"] = s.metrics.cpu_system
        report["cpu_idle_percent"] = s.metrics.cpu_idle
    }
    report["cpu_core_percent"] = s.cpuCores.map { $0 >= 0 ? $0 as Any : NSNull() as Any }
    if let averages = s.loadAverages { report["cpu_load_average_1_5_15"] = averages }
    if let gpu = s.gpu {
        report["gpu_model"] = gpu.model
        report["gpu_utilization_percent"] = gpu.utilization
        if let renderer = gpu.renderer { report["gpu_renderer_percent"] = renderer }
        if let tiler = gpu.tiler { report["gpu_tiler_percent"] = tiler }
    }
    if let free = s.diskFree { report["internal_disk_free_bytes"] = free }
    if let total = s.diskTotal { report["internal_disk_total_bytes"] = total }
    if let used = s.diskUsedEstimate { report["internal_disk_used_estimate_bytes"] = used }
    if let format = s.diskFormat { report["internal_disk_format"] = format }
    if let name = s.diskName { report["internal_disk_volume_name"] = name }
    if let available = s.diskAvailable { report["internal_disk_available_bytes"] = available }
    if let purgeable = s.diskPurgeableEstimate { report["internal_disk_purgeable_estimate_bytes"] = purgeable }
    do {
        let poll = SSDReader().poll(selectedID: UserDefaults.standard.string(forKey: "externalDriveID"))
        report["external_drives"] = poll.drives.map { ["id": $0.id, "disk": $0.disk, "name": $0.name, "ssd_known": $0.solidState != nil] as [String: Any] }
        if let issue = poll.issue { report["ssd_note"] = issue.localizedDescription }
        guard let reading = poll.reading else { throw poll.issue ?? ReadError.disconnected }
        report["ssd_model"] = reading.model
        if let temperature = reading.temperature { report["ssd_temperature_C"] = temperature }
        report["ssd_smart_available"] = reading.hasSMARTData
        if let id = reading.driveID { report["external_drive_id"] = id }
        if let disk = reading.disk { report["external_drive_disk"] = disk }
        if let written = reading.writtenTB { report["ssd_written_TB"] = written }
        if let read = reading.details.readTB { report["ssd_read_TB"] = read }
        if let used = reading.details.percentageUsed { report["ssd_percentage_used"] = used }
        if let spare = reading.details.availableSpare { report["ssd_available_spare_percent"] = spare }
        if let threshold = reading.details.spareThreshold { report["ssd_available_spare_threshold_percent"] = threshold }
        if let hours = reading.details.powerOnHours { report["ssd_power_on_hours"] = hours }
        if let storage = reading.storage {
            report["external_ssd_total_bytes"] = storage.total
            report["external_ssd_free_bytes"] = storage.free
            report["external_ssd_used_bytes"] = storage.used
            report["external_ssd_utilization_percent"] = storage.utilization
            report["external_ssd_volumes"] = storage.volumes.map(\.name)
        }
        if let shutdowns = reading.details.unsafeShutdowns { report["ssd_unsafe_shutdowns"] = shutdowns }
        if let healthy = reading.healthy { report["ssd_smart_healthy"] = healthy }
        if let warning = reading.criticalWarning { report["ssd_critical_warning"] = warning }
        if let errors = reading.mediaErrors { report["ssd_media_errors"] = errors }
    } catch { report["ssd_error"] = error.localizedDescription }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
