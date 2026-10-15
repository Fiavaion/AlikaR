import CuardachAR
import CuardachUI
import SwiftUI
#if canImport(GLTFKit2)
import GLTFKit2
#endif

@main
struct CuardachApp: App {
    /// A file, `cuardach://` link or https link the system asked us to open.
    @State private var incoming: URL?
    @State private var store: LibraryStore

    init() {
        #if DEBUG
        UITestSupport.prepareIfRequested()
        #endif
        _store = State(initialValue: LibraryStore())
        #if canImport(GLTFKit2)
        // GLB/glTF import (PRD A2) is the one third-party component.
        GLTFLoading.loader = { url in try await GLTFRealityKitLoader.load(from: url) }
        #endif
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView(store: store, incoming: $incoming)
                .onOpenURL { incoming = $0 }
        }
    }
}
