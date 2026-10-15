import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case automatic, japanese, english
    var id: String { rawValue }

    func code(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .japanese: return "ja"
        case .english: return "en"
        case .automatic: return preferredLanguages.first?.lowercased().hasPrefix("ja") == true ? "ja" : "en"
        }
    }
}

enum MetricGroup: String, CaseIterable, Identifiable {
    case compute, memory, disk, externalSSD
    var id: String { rawValue }
    static let menuOrder: [MetricGroup] = [.externalSSD, .compute, .memory, .disk]
    var title: String {
        switch self {
        case .compute: return "CPU・GPU"
        case .memory: return "メモリ"
        case .disk: return "内蔵SSD"
        case .externalSSD: return "外付けSSD"
        }
    }
    var defaultMetric: DisplayMetric {
        switch self {
        case .compute: return .cpuUtilization
        case .memory: return .memoryUtilization
        case .disk: return .diskFree
        case .externalSSD: return .ssdTemperature
        }
    }
    var choices: [DisplayMetric] { DisplayMetric.allCases.filter { $0.group == self } }
}

enum DisplayMetric: String, CaseIterable, Identifiable {
    case cpuUtilization, cpuLoad1, gpuUtilization, gpuRenderer, gpuTiler
    case memoryUtilization, memoryUsed, memoryPressure, compressed, swap
    case diskFree, diskAvailable, diskPurgeable, diskUsed
    case ssdTemperature, ssdWritten, ssdRead, ssdEndurance, ssdHours
    case ssdStorageUtilization, ssdStorageFree, ssdStorageUsed
    var id: String { rawValue }
    var group: MetricGroup {
        switch self {
        case .cpuUtilization, .cpuLoad1, .gpuUtilization, .gpuRenderer, .gpuTiler: return .compute
        case .memoryUtilization, .memoryUsed, .memoryPressure, .compressed, .swap: return .memory
        case .diskFree, .diskAvailable, .diskPurgeable, .diskUsed: return .disk
        default: return .externalSSD
        }
    }
    var title: String {
        switch self {
        case .cpuUtilization: return "CPU使用率"
        case .cpuLoad1: return "CPU負荷平均（1分）"
        case .gpuUtilization: return "GPU使用率"
        case .gpuRenderer: return "GPU描画使用率"
        case .gpuTiler: return "GPUタイル使用率"
        case .memoryUtilization: return "メモリ使用率"
        case .memoryUsed: return "メモリ使用量"
        case .memoryPressure: return "メモリプレッシャー"
        case .compressed: return "圧縮メモリ"
        case .swap: return "スワップ使用量"
        case .diskFree: return "実際の空き容量"
        case .diskAvailable: return "削除可能領域込みの利用可能容量"
        case .diskPurgeable: return "削除可能容量の目安"
        case .diskUsed: return "内蔵SSD使用容量（概算）"
        case .ssdTemperature: return "外付けSSD温度"
        case .ssdWritten: return "SSD累積書き込み"
        case .ssdRead: return "SSD累積読み取り"
        case .ssdEndurance: return "SSD寿命使用率の目安"
        case .ssdHours: return "SSD累積稼働時間"
        case .ssdStorageUtilization: return "外付けSSD使用率"
        case .ssdStorageFree: return "外付けSSD残量"
        case .ssdStorageUsed: return "外付けSSD使用容量"
        }
    }
}

enum PollInterval: Int, CaseIterable, Identifiable {
    case one = 1, two = 2, five = 5, ten = 10, fifteen = 15, thirty = 30, sixty = 60
    var id: Int { rawValue }
    static let systemChoices: [PollInterval] = [.one, .two, .five, .ten, .thirty]
    static let ssdChoices: [PollInterval] = [.five, .fifteen, .thirty, .sixty]
}

struct AppLocalization {
    let code: String
    var locale: Locale { Locale(identifier: code == "ja" ? "ja_JP" : "en_US") }
    private var bundle: Bundle {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
    func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
    static var system: AppLocalization { AppLocalization(code: AppLanguage.automatic.code()) }
}

private struct AppLocalizationKey: EnvironmentKey {
    static let defaultValue = AppLocalization.system
}
extension EnvironmentValues {
    var appLocalization: AppLocalization {
        get { self[AppLocalizationKey.self] }
        set { self[AppLocalizationKey.self] = newValue }
    }
}

protocol PreferencesStore {
    func string(forKey key: String) -> String?
    func dictionary(forKey key: String) -> [String: Any]?
    func stringArray(forKey key: String) -> [String]?
    func integer(forKey key: String) -> Int
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: PreferencesStore {}

@MainActor final class AppSettings: ObservableObject {
    private let defaults: PreferencesStore?
    private let preferredLanguages: [String]
    var onChange: (() -> Void)?
    var onPollingChange: (() -> Void)?
    var onDriveChange: (() -> Void)?
    @Published private(set) var externalDriveID: String?
    @Published private(set) var externalDriveName: String

    func selectExternalDrive(_ drive: ExternalDrive, notify: Bool = true) {
        let changed = externalDriveID != drive.id
        externalDriveID = drive.id
        externalDriveName = drive.name
        defaults?.set(drive.id, forKey: "externalDriveID")
        defaults?.set(drive.name, forKey: "externalDriveName")
        if changed && notify { onDriveChange?() }
        onChange?()
    }
    @Published private(set) var hiddenMenuGroups: Set<MetricGroup> {
        didSet {
            defaults?.set(MetricGroup.allCases.filter { hiddenMenuGroups.contains($0) }.map(\.rawValue), forKey: "hiddenMenuGroups")
            onChange?()
        }
    }
    @Published var systemInterval: PollInterval {
        didSet {
            defaults?.set(systemInterval.rawValue, forKey: "systemRefreshSeconds")
            onPollingChange?(); onChange?()
        }
    }
    @Published var ssdInterval: PollInterval {
        didSet {
            defaults?.set(ssdInterval.rawValue, forKey: "ssdRefreshSeconds")
            onPollingChange?(); onChange?()
        }
    }
    @Published var language: AppLanguage {
        didSet {
            defaults?.set(language.rawValue, forKey: "displayLanguage")
            onChange?()
        }
    }
    @Published private(set) var primaryMetrics: [MetricGroup: DisplayMetric] {
        didSet {
            let saved = Dictionary(uniqueKeysWithValues: primaryMetrics.map { ($0.key.rawValue, $0.value.rawValue) })
            defaults?.set(saved, forKey: "primaryMetrics")
            onChange?()
        }
    }
    var localization: AppLocalization { AppLocalization(code: language.code(preferredLanguages: preferredLanguages)) }
    func metric(for group: MetricGroup) -> DisplayMetric { primaryMetrics[group] ?? group.defaultMetric }
    func select(_ metric: DisplayMetric, for group: MetricGroup) {
        guard metric.group == group else { return }
        primaryMetrics[group] = metric
        hiddenMenuGroups.remove(group)
    }
    func hideMenuGroup(_ group: MetricGroup) {
        hiddenMenuGroups.insert(group)
    }

    init(defaults: PreferencesStore? = UserDefaults.standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        externalDriveID = defaults?.string(forKey: "externalDriveID").flatMap { $0.isEmpty ? nil : $0 }
        externalDriveName = defaults?.string(forKey: "externalDriveName") ?? ""
        hiddenMenuGroups = Set((defaults?.stringArray(forKey: "hiddenMenuGroups") ?? []).compactMap(MetricGroup.init(rawValue:)))
        language = defaults?.string(forKey: "displayLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .automatic
        let systemValue = defaults.flatMap { PollInterval(rawValue: $0.integer(forKey: "systemRefreshSeconds")) }
        let ssdValue = defaults.flatMap { PollInterval(rawValue: $0.integer(forKey: "ssdRefreshSeconds")) }
        systemInterval = systemValue.flatMap { PollInterval.systemChoices.contains($0) ? $0 : nil } ?? .two
        ssdInterval = ssdValue.flatMap { PollInterval.ssdChoices.contains($0) ? $0 : nil } ?? .fifteen
        let saved = defaults?.dictionary(forKey: "primaryMetrics") ?? [:]
        primaryMetrics = Dictionary(uniqueKeysWithValues: MetricGroup.allCases.map { group in
            let metric = (saved[group.rawValue] as? String).flatMap(DisplayMetric.init(rawValue:))
            if let metric, metric.group == group { return (group, metric) }
            return (group, group.defaultMetric)
        })
    }
}

struct SettingsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    var drives: [ExternalDrive] = []
    var scanning = false
    var onRescan: () -> Void = {}
    private var l: AppLocalization { settings.localization }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(l.text("設定"), systemImage: "gearshape").font(.headline)
                Spacer()
                Button(l.text("閉じる")) { dismiss() }
            }
            Picker(l.text("表示言語"), selection: $settings.language) {
                Text(l.text("自動（macOSに合わせる）")).tag(AppLanguage.automatic)
                Text("日本語").tag(AppLanguage.japanese)
                Text("English").tag(AppLanguage.english)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l.text("監視する外付けSSD")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(l.text("再検出"), action: onRescan).disabled(scanning)
                }
                Picker(l.text("ドライブ"), selection: Binding(
                    get: { settings.externalDriveID ?? "" },
                    set: { id in
                        if let drive = drives.first(where: { $0.id == id }) { settings.selectExternalDrive(drive) }
                    })) {
                        if settings.externalDriveID == nil { Text(l.text("SSDを選択してください")).tag("") }
                        if let id = settings.externalDriveID, !drives.contains(where: { $0.id == id }) {
                            Text(l.text("%@（未接続）", settings.externalDriveName)).tag(id)
                        }
                        ForEach(drives, id: \.disk) { drive in
                            Text(drive.label + (drive.solidState == nil ? l.text("（SSD種別不明）") : "")).tag(drive.id)
                        }
                    }
                Text(l.text("SMART非対応でも容量を表示します。取り外しても別のドライブへ自動変更しません。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text(l.text("各欄に表示する数値")).font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MetricGroup.allCases) { group in
                    Picker(l.text(group.title), selection: Binding(
                        get: { settings.hiddenMenuGroups.contains(group) ? nil : settings.metric(for: group) },
                        set: { metric in
                            if let metric { settings.select(metric, for: group) }
                            else { settings.hideMenuGroup(group) }
                        })) {
                            Text(l.text("メニューバーに表示しない")).tag(Optional<DisplayMetric>.none)
                            ForEach(group.choices) { metric in
                                Text(l.text(metric.title)).tag(Optional(metric))
                            }
                        }
                }
            }
            Text(l.text("選んだ数値をメニューバーと詳細の先頭に表示します。警告は既存の基準で判定します。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(l.text("非表示はメニューバーだけに適用します。全欄を非表示にしてもアプリアイコンは残ります。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(l.text("変更はすぐに反映され、次回起動時にも引き継ぎます。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Text(l.text("自動更新の間隔")).font(.system(size: 12, weight: .semibold))
            Picker(l.text("CPU・GPU・メモリ・内蔵SSD"), selection: $settings.systemInterval) {
                ForEach(PollInterval.systemChoices) { interval in
                    Text(l.text("%@秒", String(interval.rawValue))).tag(interval)
                }
            }
            Picker(l.text("外付けSSD（容量・SMART）"), selection: $settings.ssdInterval) {
                ForEach(PollInterval.ssdChoices) { interval in
                    Text(l.text("%@秒", String(interval.rawValue))).tag(interval)
                }
            }
            Text(l.text("間隔を変えた項目のグラフ履歴はリセットします。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(20).frame(width: 440)
        .environment(\.locale, l.locale)
    }
}
