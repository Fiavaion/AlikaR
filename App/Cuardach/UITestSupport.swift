#if DEBUG
import Foundation

/// Debug-only hooks for the UI tests. `-uitest-reset` empties the library;
/// `UITEST_SEED_OPENED` (a path to an unpacked `.arhunt` folder) is copied
/// into the Opened section. Compiled out of Release builds.
enum UITestSupport {
    static func prepareIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-uitest-reset") else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["My Experiences", "Opened"] {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: support.appendingPathComponent("Progress"))
        try? fm.removeItem(at: support.appendingPathComponent("sources.json"))
        if let seed = ProcessInfo.processInfo.environment["UITEST_SEED_OPENED"] {
            let opened = docs.appendingPathComponent("Opened", isDirectory: true)
            try? fm.createDirectory(at: opened, withIntermediateDirectories: true)
            let src = URL(fileURLWithPath: seed)
            try? fm.copyItem(at: src, to: opened.appendingPathComponent(src.lastPathComponent))
        }
    }
}
#endif
