import SwiftUI

@main
struct ArborApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Arbor") {
                    AboutWindowController.shared.show()
                }
            }
        }
        .defaultSize(width: 1100, height: 700)
    }
}
