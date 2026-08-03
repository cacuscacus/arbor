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
        showKind = defaults.object(forKey: Keys.kind) as? Bool ?? true
        showSize = defaults.object(forKey: Keys.size) as? Bool ?? true
        showModified = defaults.object(forKey: Keys.modified) as? Bool ?? true
        showCreated = defaults.object(forKey: Keys.created) as? Bool ?? false
        showRelativePath = defaults.object(forKey: Keys.relativePath) as? Bool ?? false
        showFullPath = defaults.object(forKey: Keys.fullPath) as? Bool ?? false
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
        static let kind = "arbor.browser.column.kind"
        static let size = "arbor.browser.column.size"
        static let modified = "arbor.browser.column.modified"
        static let created = "arbor.browser.column.created"
        static let relativePath = "arbor.browser.column.relativePath"
        static let fullPath = "arbor.browser.column.fullPath"
    }
}
