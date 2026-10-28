import SwiftUI

@main
struct CascadeDemoApp: App {
    init() {
        // NOVA pattern: materialize the named folder tree inside
        // Documents at launch (before any UI), so the app's folder
        // shows up in the Files app with content already in it.
        CascadeFolders.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
