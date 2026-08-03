import SwiftUI

struct SidebarView: View {
    @Binding var selectedPath: URL

    private let favorites: [(String, String)] = [
        ("Home", NSHomeDirectory()),
        ("Desktop", NSHomeDirectory() + "/Desktop"),
        ("Documents", NSHomeDirectory() + "/Documents"),
        ("Downloads", NSHomeDirectory() + "/Downloads"),
    ]

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(favorites, id: \.0) { item in
                    Button {
                        selectedPath = URL(fileURLWithPath: item.1)
                    } label: {
                        Label(item.0, systemImage: icon(for: item.0))
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Places") {
                Label("Recents", systemImage: "clock")
                    .foregroundStyle(.secondary)
                Label("Volumes", systemImage: "externaldrive")
                    .foregroundStyle(.secondary)
                Label("Git Repositories", systemImage: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func icon(for name: String) -> String {
        switch name {
        case "Home": return "house"
        case "Desktop": return "desktopcomputer"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        default: return "folder"
        }
    }
}
