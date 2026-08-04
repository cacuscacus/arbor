import SwiftUI

@main
struct ArborApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Default toolbar style — `.unified` fights Tahoe Liquid Glass floating pills.
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Arbor") {
                    AboutWindowController.shared.show()
                }
            }
            CommandMenu("View") {
                IconViewCommands()
            }
        }
        .defaultSize(width: 1100, height: 700)
    }
}

private struct IconViewCommands: View {
    @FocusedValue(\.browserDisplaySettings) private var displaySettings

    private var iconsDisabled: Bool {
        displaySettings == nil || displaySettings?.viewMode != .icons
    }

    var body: some View {
        Button("Larger Icons") {
            displaySettings?.increaseIconSize()
        }
        .keyboardShortcut("+", modifiers: .command)
        .disabled(iconsDisabled || displaySettings?.canIncreaseIconSize == false)

        Button("Smaller Icons") {
            displaySettings?.decreaseIconSize()
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(iconsDisabled || displaySettings?.canDecreaseIconSize == false)

        Divider()

        Button("Increase Icon Spacing") {
            displaySettings?.increaseGridSpacing()
        }
        .keyboardShortcut("+", modifiers: [.command, .option])
        .disabled(iconsDisabled || displaySettings?.canIncreaseGridSpacing == false)

        Button("Decrease Icon Spacing") {
            displaySettings?.decreaseGridSpacing()
        }
        .keyboardShortcut("-", modifiers: [.command, .option])
        .disabled(iconsDisabled || displaySettings?.canDecreaseGridSpacing == false)

        if displaySettings?.viewMode == .list {
            Divider()
            ForEach(BrowserColumn.configurable) { column in
                if let settings = displaySettings, let binding = settings.binding(for: column) {
                    Toggle(column.title, isOn: binding)
                }
            }
        }
    }
}
