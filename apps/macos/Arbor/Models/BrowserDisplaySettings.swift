import Foundation
import SwiftUI

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .icons: return "Icons"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        }
    }
}

/// Layout metrics for icon view (size + configurable grid gap).
struct IconViewMetrics: Equatable {
    static let minimum: CGFloat = 32
    static let maximum: CGFloat = 128
    static let step: CGFloat = 8
    static let `default`: CGFloat = 64

    static let spacingMinimum: CGFloat = 4
    static let spacingMaximum: CGFloat = 48
    static let spacingStep: CGFloat = 4
    static let spacingDefault: CGFloat = 14

    let iconPoints: CGFloat
    let gridSpacing: CGFloat

    init(iconPoints: CGFloat, gridSpacing: CGFloat = Self.spacingDefault) {
        let clampedSize = min(Self.maximum, max(Self.minimum, iconPoints))
        let sizeSteps = ((clampedSize - Self.minimum) / Self.step).rounded()
        self.iconPoints = Self.minimum + sizeSteps * Self.step

        let clampedSpacing = min(Self.spacingMaximum, max(Self.spacingMinimum, gridSpacing))
        let spacingSteps = ((clampedSpacing - Self.spacingMinimum) / Self.spacingStep).rounded()
        self.gridSpacing = Self.spacingMinimum + spacingSteps * Self.spacingStep
    }

    var cellWidth: CGFloat { iconPoints + 48 }

    var labelWidth: CGFloat { cellWidth - 12 }

    var lineLimit: Int {
        if iconPoints <= 40 { return 2 }
        if iconPoints <= 88 { return 3 }
        return 4
    }

    var labelFontSize: CGFloat {
        if iconPoints <= 40 { return 10 }
        if iconPoints <= 88 { return 11 }
        return 12
    }

    var cellHeight: CGFloat {
        let labelLineHeight = labelFontSize + 3
        let labelBlock = CGFloat(lineLimit) * labelLineHeight + 4
        return iconPoints + 8 + labelBlock + 12
    }

    var gridMinimum: CGFloat { cellWidth }
    var gridMaximum: CGFloat { cellWidth + 16 }
}

enum BrowserColumn: String, CaseIterable, Identifiable {
    case name
    case kind
    case size
    case modified
    case created
    case relativePath
    case fullPath
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .size: return "Size"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .relativePath: return "Relative Path"
        case .fullPath: return "Full Path"
        case .location: return "Location"
        }
    }

    /// Columns the user can toggle (Name is always on).
    static var configurable: [BrowserColumn] {
        [.kind, .size, .modified, .created, .relativePath, .fullPath]
    }
}

@Observable
final class BrowserDisplaySettings {
    var viewMode: BrowserViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Keys.viewMode) }
    }

    /// Continuous icon size in points (stepped). Prefer `iconMetrics` for layout.
    var iconPoints: CGFloat {
        didSet {
            let normalized = IconViewMetrics(iconPoints: iconPoints, gridSpacing: gridSpacing).iconPoints
            if abs(iconPoints - normalized) > 0.1 {
                iconPoints = normalized
                return
            }
            UserDefaults.standard.set(Double(iconPoints), forKey: Keys.iconPoints)
        }
    }

    /// Gap between icon cells in icon view (stepped).
    var gridSpacing: CGFloat {
        didSet {
            let normalized = IconViewMetrics(iconPoints: iconPoints, gridSpacing: gridSpacing).gridSpacing
            if abs(gridSpacing - normalized) > 0.1 {
                gridSpacing = normalized
                return
            }
            UserDefaults.standard.set(Double(gridSpacing), forKey: Keys.gridSpacing)
        }
    }

    var iconMetrics: IconViewMetrics {
        IconViewMetrics(iconPoints: iconPoints, gridSpacing: gridSpacing)
    }

    var canIncreaseIconSize: Bool {
        iconPoints < IconViewMetrics.maximum
    }

    var canDecreaseIconSize: Bool {
        iconPoints > IconViewMetrics.minimum
    }

    var canIncreaseGridSpacing: Bool {
        gridSpacing < IconViewMetrics.spacingMaximum
    }

    var canDecreaseGridSpacing: Bool {
        gridSpacing > IconViewMetrics.spacingMinimum
    }

    var showKind: Bool {
        didSet { UserDefaults.standard.set(showKind, forKey: Keys.kind) }
    }

    var showSize: Bool {
        didSet { UserDefaults.standard.set(showSize, forKey: Keys.size) }
    }

    var showModified: Bool {
        didSet { UserDefaults.standard.set(showModified, forKey: Keys.modified) }
    }

    var showCreated: Bool {
        didSet { UserDefaults.standard.set(showCreated, forKey: Keys.created) }
    }

    var showRelativePath: Bool {
        didSet { UserDefaults.standard.set(showRelativePath, forKey: Keys.relativePath) }
    }

    var showFullPath: Bool {
        didSet { UserDefaults.standard.set(showFullPath, forKey: Keys.fullPath) }
    }

    init() {
        let defaults = UserDefaults.standard
        viewMode = BrowserViewMode(rawValue: defaults.string(forKey: Keys.viewMode) ?? "") ?? .list

        let resolvedIconPoints: CGFloat
        if defaults.object(forKey: Keys.iconPoints) != nil {
            resolvedIconPoints = IconViewMetrics(iconPoints: CGFloat(defaults.double(forKey: Keys.iconPoints))).iconPoints
        } else if let legacy = defaults.string(forKey: Keys.legacyIconSize) {
            switch legacy {
            case "small": resolvedIconPoints = 32
            case "large": resolvedIconPoints = 80
            case "extraLarge": resolvedIconPoints = 128
            default: resolvedIconPoints = IconViewMetrics.default
            }
        } else {
            resolvedIconPoints = IconViewMetrics.default
        }

        let resolvedSpacing: CGFloat
        if defaults.object(forKey: Keys.gridSpacing) != nil {
            resolvedSpacing = IconViewMetrics(
                iconPoints: resolvedIconPoints,
                gridSpacing: CGFloat(defaults.double(forKey: Keys.gridSpacing))
            ).gridSpacing
        } else {
            resolvedSpacing = IconViewMetrics.spacingDefault
        }

        iconPoints = resolvedIconPoints
        gridSpacing = resolvedSpacing

        showKind = defaults.object(forKey: Keys.kind) as? Bool ?? true
        showSize = defaults.object(forKey: Keys.size) as? Bool ?? true
        showModified = defaults.object(forKey: Keys.modified) as? Bool ?? true
        showCreated = defaults.object(forKey: Keys.created) as? Bool ?? false
        showRelativePath = defaults.object(forKey: Keys.relativePath) as? Bool ?? false
        showFullPath = defaults.object(forKey: Keys.fullPath) as? Bool ?? false
    }

    func increaseIconSize() {
        guard canIncreaseIconSize else { return }
        iconPoints = min(IconViewMetrics.maximum, iconPoints + IconViewMetrics.step)
    }

    func decreaseIconSize() {
        guard canDecreaseIconSize else { return }
        iconPoints = max(IconViewMetrics.minimum, iconPoints - IconViewMetrics.step)
    }

    func increaseGridSpacing() {
        guard canIncreaseGridSpacing else { return }
        gridSpacing = min(IconViewMetrics.spacingMaximum, gridSpacing + IconViewMetrics.spacingStep)
    }

    func decreaseGridSpacing() {
        guard canDecreaseGridSpacing else { return }
        gridSpacing = max(IconViewMetrics.spacingMinimum, gridSpacing - IconViewMetrics.spacingStep)
    }

    func binding(for column: BrowserColumn) -> Binding<Bool>? {
        switch column {
        case .kind: return Binding(get: { self.showKind }, set: { self.showKind = $0 })
        case .size: return Binding(get: { self.showSize }, set: { self.showSize = $0 })
        case .modified: return Binding(get: { self.showModified }, set: { self.showModified = $0 })
        case .created: return Binding(get: { self.showCreated }, set: { self.showCreated = $0 })
        case .relativePath: return Binding(get: { self.showRelativePath }, set: { self.showRelativePath = $0 })
        case .fullPath: return Binding(get: { self.showFullPath }, set: { self.showFullPath = $0 })
        case .name, .location: return nil
        }
    }

    private enum Keys {
        static let viewMode = "arbor.browser.viewMode"
        static let iconPoints = "arbor.browser.iconPoints"
        static let gridSpacing = "arbor.browser.gridSpacing"
        static let legacyIconSize = "arbor.browser.iconSize"
        static let kind = "arbor.browser.column.kind"
        static let size = "arbor.browser.column.size"
        static let modified = "arbor.browser.column.modified"
        static let created = "arbor.browser.column.created"
        static let relativePath = "arbor.browser.column.relativePath"
        static let fullPath = "arbor.browser.column.fullPath"
    }
}

/// App-wide, persisted Finder-style hidden-files visibility (all windows / tabs / panes).
enum HiddenFilesPreference {
    static let key = "arbor.browser.showHiddenFiles"

    static var showHiddenFiles: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Focused values for menu commands

private struct BrowserDisplaySettingsFocusedKey: FocusedValueKey {
    typealias Value = BrowserDisplaySettings
}

private struct BrowserFolderItemFocusedKey: FocusedValueKey {
    typealias Value = ItemRef
}

private struct ActiveBrowserTabFocusedKey: FocusedValueKey {
    typealias Value = BrowserTab
}

extension FocusedValues {
    var browserDisplaySettings: BrowserDisplaySettings? {
        get { self[BrowserDisplaySettingsFocusedKey.self] }
        set { self[BrowserDisplaySettingsFocusedKey.self] = newValue }
    }

    var browserFolderItem: ItemRef? {
        get { self[BrowserFolderItemFocusedKey.self] }
        set { self[BrowserFolderItemFocusedKey.self] = newValue }
    }

    /// Selected tab in the key window (split toggle / close commands).
    var activeBrowserTab: BrowserTab? {
        get { self[ActiveBrowserTabFocusedKey.self] }
        set { self[ActiveBrowserTabFocusedKey.self] = newValue }
    }
}
