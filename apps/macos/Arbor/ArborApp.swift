import AppKit
import SwiftUI

@main
struct ArborApp: App {
    @NSApplicationDelegateAdaptor(ArborAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "browser") {
            ContentView()
                .background(WindowOpenInstaller())
        }
        // Default toolbar style — `.unified` fights Tahoe Liquid Glass floating pills.
        .commands {
            NewWindowCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About Arbor") {
                    AboutWindowController.shared.show()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Check for Updates…") {
                    UpdateCheckService.checkForUpdates()
                }
                Button("Release History…") {
                    ReleaseHistoryWindowController.shared.show()
                }
                Button("View Releases on GitHub") {
                    if let url = URL(string: "https://github.com/cacuscacus/arbor/releases") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandMenu("View") {
                SplitViewCommands()
                Divider()
                IconViewCommands()
            }
        }
        .defaultSize(width: 1100, height: 700)
    }
}

/// Installs `openWindow` for Dock reopen after the last window closes.
private struct WindowOpenInstaller: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                WindowLaunchCoordinator.install(openWindow: openWindow)
            }
    }
}

/// File → New Window (⌘N). Dock right-click uses `applicationDockMenu`.
private struct NewWindowCommands: Commands {
    @FocusedValue(\.browserFolderURL) private var browserFolderURL

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                WindowLaunchCoordinator.openNewWindow(cloning: browserFolderURL)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

private struct SplitViewCommands: View {
    @FocusedValue(\.activeBrowserTab) private var tab

    var body: some View {
        Button("Toggle Split View") {
            tab?.toggleSplit()
        }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(tab == nil)

        Button("Close Split View") {
            tab?.closeSplit()
        }
        .disabled(tab?.isSplit != true)
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
