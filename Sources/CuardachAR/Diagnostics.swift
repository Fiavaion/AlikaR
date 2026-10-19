import os

/// On-device diagnostics through Apple's unified log. Local only: nothing is
/// collected or sent. Never log coordinates or file contents; mark file and
/// element names `.private`. See docs/architecture.md, "Diagnostics".
public enum Log {
    public static let subsystem = "ie.ncad.cuardach"
    public static let importing = Logger(subsystem: subsystem, category: "import")
    public static let session = Logger(subsystem: subsystem, category: "ar-session")
    public static let anchors = Logger(subsystem: subsystem, category: "anchors")
    public static let behaviours = Logger(subsystem: subsystem, category: "behaviours")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
}
