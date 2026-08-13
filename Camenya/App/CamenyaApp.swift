import SwiftUI

@main
struct CamenyaApp: App {
    @StateObject private var library = ProjectLibraryModel()

    var body: some Scene {
        WindowGroup {
            ProjectLibraryScreen(model: library)
        }
    }
}
