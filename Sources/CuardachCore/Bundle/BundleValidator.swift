import Foundation

/// A finding about an experience: errors stop it working, warnings make it
/// fragile, notes are studio good practice (credits, access, documentation).
public struct ValidationIssue: Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Comparable, CaseIterable {
        case error, warning, note
        var rank: Int { switch self { case .error: 0; case .warning: 1; case .note: 2 } }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public var severity: Severity
    /// Stable machine-readable code, e.g. "asset.missing".
    public var code: String
    public var message: String
    public var elementId: String?

    public init(_ severity: Severity, _ code: String, _ message: String, element: String? = nil) {
        self.severity = severity; self.code = code; self.message = message; self.elementId = element
    }

    public var description: String {
        let tag = severity.rawValue.uppercased()
        return elementId.map { "\(tag) [\($0)] \(message) (\(code))" } ?? "\(tag) \(message) (\(code))"
    }
}

/// Checks a manifest against its bundle's files. File access is injected,
/// so the same rules run on a folder, a zip or in tests.
public struct BundleValidator {
    public var fileSize: (String) -> Int?
    public var totalBytes: Int?

    public init(fileSize: @escaping (String) -> Int?, totalBytes: Int? = nil) {
        self.fileSize = fileSize; self.totalBytes = totalBytes
    }

    public init(bundle: ExperienceBundle) {
        let files = (try? bundle.files()) ?? []
        let sizes = Dictionary(files.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
        self.init(fileSize: { sizes[$0] }, totalBytes: files.reduce(0) { $0 + $1.bytes })
    }

    public func validate(_ x: Experience) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        func add(_ s: ValidationIssue.Severity, _ code: String, _ msg: String, _ el: String? = nil) {
            out.append(ValidationIssue(s, code, msg, element: el))
        }

        if x.schemaVersion > Experience.currentSchemaVersion {
            add(.warning, "schema.newer", "Made with a newer version of the app (schema \(x.schemaVersion)). Some features may not play.")
        }
        if x.title.trimmingCharacters(in: .whitespaces).isEmpty { add(.warning, "title.empty", "The experience has no title.") }
        if x.elements.isEmpty { add(.warning, "elements.empty", "The experience has no elements yet.") }

        let ids = x.elements.map(\.id)
        for dup in Set(ids.filter { id in ids.filter { $0 == id }.count > 1 }).sorted() {
            add(.error, "element.duplicateId", "Two or more elements share the id \"\(dup)\".", dup)
        }
        let byId = Dictionary(x.elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func checkFile(_ path: String, _ what: String, _ el: String?) {
            guard (try? SafePath.components(path)) != nil else {
                add(.error, "path.unsafe", "\(what) has an unsafe path: \(path)", el); return
            }
            guard let size = fileSize(path) else {
                add(.error, "asset.missing", "\(what) is missing from the bundle: \(path)", el); return
            }
            if size > AssetPolicy.assetWarningBytes {
                add(.warning, "asset.large", "\(what) is \(ByteSize.format(size)); over 25 MB it loads slowly.", el)
            }
        }

        if let cover = x.cover { checkFile(cover, "Cover image", nil) }
        if let ad = x.label?.audioDescription { checkFile(ad, "Audio description", nil) }

        var anchorIds: [String: String] = [:]
        for e in x.elements {
            let el = e.id
            if !e.kind.isKnown {
                add(.warning, "element.unknownKind", "\"\(e.name)\" is a \(e.kind) element, which this version can't show.", el)
            }
            if e.kind == .text {
                if (e.text ?? "").isEmpty { add(.warning, "text.empty", "Text element \"\(e.name)\" has no text.", el) }
            } else if let asset = e.asset {
                checkFile(asset, "\"\(e.name)\"'s asset", el)
            } else if e.kind.isKnown {
                add(.error, "asset.none", "\"\(e.name)\" has no asset.", el)
            }
            for v in e.variants { checkFile(v.asset, "Variant \"\(v.name)\" of \"\(e.name)\"", el) }
            if let ad = e.label?.audioDescription { checkFile(ad, "Audio description for \"\(e.name)\"", el) }

            out += validateAnchors(e, anchorIds: &anchorIds, checkFile: checkFile)
            out += validateBehaviours(e, byId: byId, checkFile: checkFile)

            // Studio good practice.
            if e.kind != .audio, (e.label?.altText ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                add(.note, "access.altText", "\"\(e.name)\" has no description for VoiceOver users.", el)
            }
            if e.kind != .text {
                if let c = e.credit {
                    for r in c.restrictions { add(.note, "credit.restricted", "\"\(e.name)\": \(r).", el) }
                } else {
                    add(.note, "credit.missing", "\"\(e.name)\" doesn't say where its asset came from or its licence.", el)
                }
            }
        }

        for n in x.annotations {
            if let target = n.elementId, byId[target] == nil {
                add(.warning, "crit.orphan", "A crit note from \(n.author) refers to an element that no longer exists.")
            }
        }
        let open = x.annotations.filter { !$0.resolved }.count
        if open > 0 { add(.note, "crit.open", "\(open) crit note\(open == 1 ? "" : "s") still open.") }

        let located = x.elements.contains { $0.coordinate != nil }
        if located, x.siteHint == nil { add(.note, "site.noHint", "Located elements exist but the experience has no site hint for the overview map.") }

        if let total = totalBytes, total > AssetPolicy.bundleWarningBytes {
            add(.warning, "bundle.large", "The bundle is \(ByteSize.format(total)). Over 50 MB, email and Messages may refuse it; share by AirDrop or a QR link.")
        }
        return out.sorted { ($0.severity, $0.elementId ?? "", $0.code) < ($1.severity, $1.elementId ?? "", $1.code) }
    }

    private func validateAnchors(_ e: Element, anchorIds: inout [String: String],
                                 checkFile: (String, String, String?) -> Void) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        let el = e.id
        func add(_ s: ValidationIssue.Severity, _ code: String, _ msg: String) {
            out.append(ValidationIssue(s, code, msg, element: el))
        }
        if e.anchors.isEmpty {
            add(.error, "anchor.none", "\"\(e.name)\" has no anchor, so no one else will ever see it.")
            return out
        }
        for a in e.anchors {
            if let other = anchorIds[a.id] {
                add(.error, "anchor.duplicateId", "Anchor id \"\(a.id)\" is also used by element \"\(other)\".")
            }
            anchorIds[a.id] = el
            if let c = a.coordinate, !c.isValid { add(.error, "anchor.badCoordinate", "Anchor \(a.id) has an impossible latitude/longitude.") }
            switch a.tier {
            case .geo:
                if a.coordinate == nil { add(.error, "anchor.geo.incomplete", "Location anchor \(a.id) has no latitude/longitude.") }
            case .worldmap:
                if let f = a.mapFile { checkFile(f, "World map for \"\(e.name)\"", el) } else {
                    add(.error, "anchor.worldmap.noMap", "Scan anchor \(a.id) has no world map file.")
                }
                if !(a.anchorTransform?.isValid ?? false) {
                    add(.error, "anchor.worldmap.noTransform", "Scan anchor \(a.id) has no position inside its world map.")
                }
                if a.mappingStatus == "limited" {
                    add(.warning, "anchor.worldmap.limited", "The scan for \"\(e.name)\" was weak. Rescan, moving slowly around the spot.")
                }
            case .image:
                if let f = a.imageFile { checkFile(f, "Marker image for \"\(e.name)\"", el) } else {
                    add(.error, "anchor.image.noImage", "Marker anchor \(a.id) has no image.")
                }
                if (a.physicalWidthM ?? 0) <= 0 {
                    add(.error, "anchor.image.noWidth", "Marker anchor \(a.id) needs its printed width.")
                }
            case .object:
                if let f = a.referenceObjectFile { checkFile(f, "Reference object for \"\(e.name)\"", el) } else {
                    add(.error, "anchor.object.noFile", "Object anchor \(a.id) has no reference object.")
                }
            case .gps:
                if a.coordinate == nil { add(.error, "anchor.gps.incomplete", "GPS anchor \(a.id) has no latitude/longitude.") }
                if (a.radiusM ?? 0) <= 0 { add(.warning, "anchor.gps.noRadius", "GPS anchor \(a.id) has no radius; 15 m is assumed.") }
            default:
                add(.warning, "anchor.unknownTier", "Anchor \(a.id) uses \"\(a.tier)\", which this version doesn't know.")
            }
        }
        let tiers = Set(e.anchors.map(\.tier))
        if tiers.isSubset(of: [.gps]) {
            add(.warning, "anchor.gpsOnly", "\"\(e.name)\" only has GPS, which drifts 5–15 m. Add a scan or a printed marker.")
        } else if !tiers.contains(.image) {
            add(.note, "anchor.noMarker", "\"\(e.name)\" has no printed-marker fallback. For hunts with children, a marker is the most reliable anchor.")
        }
        return out
    }

    private func validateBehaviours(_ e: Element, byId: [String: Element],
                                    checkFile: (String, String, String?) -> Void) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        let el = e.id
        func add(_ s: ValidationIssue.Severity, _ code: String, _ msg: String) {
            out.append(ValidationIssue(s, code, msg, element: el))
        }
        for (i, b) in e.behaviours.enumerated() {
            let where_ = "Behaviour \(i + 1) on \"\(e.name)\""
            if !b.trigger.isKnown { add(.warning, "behaviour.unknownTrigger", "\(where_) uses the trigger \"\(b.trigger)\", which this version ignores.") }
            if let r = b.proximityM, r <= 0 { add(.error, "behaviour.badProximity", "\(where_) has a proximity of \(r) m.") }
            if b.trigger == .timeWindow, !(b.window?.isValid ?? false) {
                add(.error, "behaviour.badWindow", "\(where_) needs a time window like 18:00–23:00.")
            }
            if b.actions.allSatisfy(\.isEmpty) { add(.warning, "behaviour.empty", "\(where_) has no actions.") }
            for a in b.actions.joined() {
                let targetId = a.target ?? e.id
                guard let target = byId[targetId] else {
                    add(.error, "action.badTarget", "\(where_): \(a.type) targets an element that doesn't exist (\(targetId)).")
                    continue
                }
                switch a.type {
                case .delay where (a.seconds ?? -1) < 0:
                    add(.error, "action.delay.noSeconds", "\(where_): a delay needs a number of seconds.")
                case .setState where (a.value ?? "").isEmpty:
                    add(.error, "action.setState.noValue", "\(where_): set state needs a value.")
                case .moveTo where a.position == nil:
                    add(.error, "action.moveTo.noPosition", "\(where_): move to needs a destination.")
                case .scale where (a.factor ?? 0) <= 0:
                    add(.error, "action.scale.noFactor", "\(where_): scale needs a factor above zero.")
                case .rotate where a.degrees == nil:
                    add(.error, "action.rotate.noDegrees", "\(where_): rotate needs an angle.")
                case .setVariant where !target.variants.contains { $0.id == a.variant }:
                    add(.error, "action.setVariant.unknown", "\(where_): \"\(target.name)\" has no variant \"\(a.variant ?? "")\".")
                case .cycleVariant where target.variants.isEmpty:
                    add(.warning, "action.cycleVariant.none", "\(where_): \"\(target.name)\" has no variants to cycle.")
                case .playAudio:
                    if let asset = a.asset { checkFile(asset, "\(where_)'s sound", el) } else if target.kind != .audio {
                        add(.error, "action.playAudio.noAsset", "\(where_): play audio needs a sound, or must target an audio element.")
                    }
                case .playVideo where target.kind != .video:
                    add(.error, "action.playVideo.notVideo", "\(where_): play video targets \"\(target.name)\", which isn't a video.")
                default:
                    if !a.type.isKnown {
                        add(.warning, "action.unknown", "\(where_): the action \"\(a.type)\" will be skipped by this version.")
                    }
                }
            }
        }
        return out
    }
}
