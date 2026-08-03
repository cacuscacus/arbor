import SwiftUI

@main
struct ArborApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .defaultSize(width: 1100, height: 700)
    }
}
