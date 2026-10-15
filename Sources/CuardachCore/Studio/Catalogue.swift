import Foundation

/// Renders an experience as a self-contained HTML exhibition catalogue:
/// statement, object labels, how to visit, interaction notes, credits and
/// licences, and (optionally) the crit record. It is the hand-in document,
/// the degree-show handout and the portfolio page in one, and it works
/// offline with no external resources.
public struct Catalogue {
    public struct Options: Sendable {
        /// Include open and resolved crit notes (for assessment, not for the public).
        public var includeCritNotes = false
        /// Embed the cover and image elements as data URIs when under this size.
        public var embedImagesUnderBytes = 1_500_000
        public init(includeCritNotes: Bool = false) { self.includeCritNotes = includeCritNotes }
    }

    public var experience: Experience
    public var options: Options
    /// Reads a bundle file for embedding; nil skips the image.
    public var readFile: (String) -> Data?

    public init(experience: Experience, options: Options = Options(), readFile: @escaping (String) -> Data? = { _ in nil }) {
        self.experience = experience; self.options = options; self.readFile = readFile
    }

    public init(bundle: ExperienceBundle, options: Options = Options()) {
        self.init(experience: bundle.experience, options: options) { path in
            (try? bundle.url(for: path)).flatMap { try? Data(contentsOf: $0) }
        }
    }

    public func html() -> String {
        let x = experience
        var b = ""
        b += "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        b += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        b += "<title>\(esc(x.title))</title>\n<style>\(Self.css)</style>\n</head>\n<body>\n<main>\n"

        b += "<header>\n"
        if let cover = x.cover, let img = dataURI(cover) {
            b += "<img class=\"cover\" src=\"\(img)\" alt=\"\(esc(x.label?.altText ?? "Cover image"))\">\n"
        }
        b += "<p class=\"eyebrow\">AR experience</p>\n<h1>\(esc(x.label?.title ?? x.title))</h1>\n"
        let byline = [x.label?.artist ?? x.author, x.label?.year].compactMap { $0 }.filter { !$0.isEmpty }
        if !byline.isEmpty { b += "<p class=\"byline\">\(byline.map(esc).joined(separator: ", "))</p>\n" }
        if let medium = x.label?.medium, !medium.isEmpty { b += "<p class=\"medium\">\(esc(medium))</p>\n" }
        b += "</header>\n"

        if let st = x.label?.statement, !st.isEmpty {
            b += "<section>\n<h2>Statement</h2>\n\(paragraphs(st))</section>\n"
        }

        b += visiting()

        b += "<section>\n<h2>Works</h2>\n<ol class=\"works\">\n"
        for e in x.elements { b += work(e) }
        b += "</ol>\n</section>\n"

        b += credits()
        if options.includeCritNotes { b += crit() }

        b += "<footer><p>Made with Cuardach. Open this experience in the Cuardach app on an iPhone or iPad.</p></footer>\n"
        b += "</main>\n</body>\n</html>\n"
        return b
    }

    private func visiting() -> String {
        let x = experience
        var b = "<section>\n<h2>Visiting</h2>\n"
        if let s = x.siteHint {
            b += "<p>Centred on <a href=\"geo:\(fmt(s.lat)),\(fmt(s.long))\">\(fmt(s.lat)), \(fmt(s.long))</a>, within about \(Int(s.radiusM)) m.</p>\n"
        }
        let counts = Dictionary(grouping: x.elements.compactMap(\.precision), by: { $0 }).mapValues(\.count)
        if !counts.isEmpty {
            b += "<ul class=\"precision\">\n"
            for p in Precision.allCases {
                if let n = counts[p] { b += "<li><strong>\(n) × \(p.title)</strong>: \(esc(p.explanation))</li>\n" }
            }
            b += "</ul>\n"
        }
        let markers = x.elements.filter { $0.anchors.contains { $0.tier == .image } }.count
        if markers > 0 { b += "<p>\(markers) work\(markers == 1 ? " uses a" : "s use") printed marker\(markers == 1 ? "" : "s"): look for the posters on site.</p>\n" }
        return b + "</section>\n"
    }

    private func work(_ e: Element) -> String {
        let l = e.label
        var b = "<li class=\"work\" id=\"\(esc(e.id))\">\n"
        if e.kind == .image, let a = e.asset, let img = dataURI(a) {
            b += "<img src=\"\(img)\" alt=\"\(esc(l?.altText ?? e.name))\">\n"
        }
        b += "<h3>\(esc(l?.title ?? e.name))</h3>\n<dl>\n"
        func row(_ k: String, _ v: String?) { if let v, !v.isEmpty { b += "<dt>\(k)</dt><dd>\(esc(v))</dd>\n" } }
        row("Artist", l?.artist)
        row("Year", l?.year)
        row("Medium", l?.medium ?? kindName(e.kind))
        row("Dimensions", l?.dimensions ?? e.designSize?.formattedMillimetres)
        row("Placement", e.precision?.title)
        if !e.variants.isEmpty { row("Variants", e.variants.map(\.name).joined(separator: ", ")) }
        b += "</dl>\n"
        if let st = l?.statement, !st.isEmpty { b += paragraphs(st) }
        if let alt = l?.altText, !alt.isEmpty { b += "<p class=\"alt\"><span>Description:</span> \(esc(alt))</p>\n" }
        let interactions = e.behaviours.map { BehaviourDescriber.describe($0, on: e, in: experience) }
        if !interactions.isEmpty {
            b += "<ul class=\"interactions\">\n" + interactions.map { "<li>\(esc($0))</li>\n" }.joined() + "</ul>\n"
        }
        if !e.variants.isEmpty {
            let notes = e.variants.compactMap { v in v.note.map { "<li><strong>\(esc(v.name))</strong>: \(esc($0))</li>\n" } }
            if !notes.isEmpty { b += "<ul class=\"variants\">\n" + notes.joined() + "</ul>\n" }
        }
        return b + "</li>\n"
    }

    private func credits() -> String {
        let rows = experience.elements.filter { $0.kind != .text }
        guard !rows.isEmpty else { return "" }
        var b = "<section>\n<h2>Credits and licences</h2>\n<table>\n<thead><tr><th>Work</th><th>Creator</th><th>Source</th><th>Licence</th></tr></thead>\n<tbody>\n"
        for e in rows {
            let c = e.credit
            let source: String
            if let u = c?.url, let url = URL(string: u), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                source = "<a href=\"\(esc(u))\">\(esc(c?.source ?? u))</a>"
            } else {
                source = esc(c?.source ?? "—")
            }
            let restrictions = c?.restrictions ?? ["Licence unknown"]
            let licence = esc(c?.licence ?? "Unknown") + (restrictions.isEmpty ? "" : "<br><small>\(restrictions.map(esc).joined(separator: "; "))</small>")
            b += "<tr><td>\(esc(e.name))</td><td>\(esc(c?.creator ?? "—"))</td><td>\(source)</td><td>\(licence)</td></tr>\n"
        }
        return b + "</tbody>\n</table>\n</section>\n"
    }

    private func crit() -> String {
        let notes = experience.annotations
        guard !notes.isEmpty else { return "" }
        var b = "<section>\n<h2>Crit record</h2>\n<ul class=\"crit\">\n"
        for n in notes.sorted(by: { $0.created < $1.created }) {
            let about = n.elementId.flatMap { experience.element(id: $0)?.name }.map { " on “\(esc($0))”" } ?? ""
            b += "<li class=\"\(n.resolved ? "resolved" : "open")\"><p><strong>\(esc(n.kind.rawValue.capitalized))</strong> from \(esc(n.author))\(about)\(n.resolved ? " (resolved)" : "")</p>\n<p>\(esc(n.text))</p>\n"
            if let r = n.reply, !r.isEmpty { b += "<p class=\"reply\">Reply: \(esc(r))</p>\n" }
            b += "</li>\n"
        }
        return b + "</ul>\n</section>\n"
    }

    private func kindName(_ k: ElementKind) -> String? {
        switch k {
        case .model: "3D model"
        case .video: "Video"
        case .image: "Image"
        case .audio: "Sound"
        case .splat: "Gaussian splat"
        case .text: "Text"
        default: nil
        }
    }

    private func dataURI(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic"][ext]
        guard let mime, let d = readFile(path), d.count <= options.embedImagesUnderBytes else { return nil }
        return "data:\(mime);base64,\(d.base64EncodedString())"
    }

    private func paragraphs(_ s: String) -> String {
        s.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\(esc($0).replacingOccurrences(of: "\n", with: "<br>"))</p>\n" }.joined()
    }

    private func fmt(_ d: Double) -> String { String(format: "%.5f", d) }

    /// Escapes text for HTML element content and quoted attributes.
    public static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(ch)
            }
        }
        return o
    }

    private func esc(_ s: String) -> String { Self.escape(s) }

    static let css = """
    :root{--bg:#fbfaf7;--fg:#1b1b1a;--muted:#6b6862;--rule:#e2dfd8;--accent:#0b6e4f}
    @media (prefers-color-scheme:dark){:root{--bg:#141413;--fg:#efede8;--muted:#a19d95;--rule:#2f2e2b;--accent:#5cc6a0}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.55 Georgia,'Iowan Old Style',serif}
    main{max-width:760px;margin:0 auto;padding:48px 16px 96px}
    h1,h2,h3,.eyebrow,dt,th,footer,small{font-family:-apple-system,'Helvetica Neue',Arial,sans-serif}
    h1{font-size:2.4rem;line-height:1.1;margin:.2em 0}h2{font-size:1.05rem;text-transform:uppercase;letter-spacing:.08em;border-top:1px solid var(--rule);padding-top:1.2em;margin-top:2.4em}
    h3{font-size:1.25rem;margin:0 0 .4em}.eyebrow{color:var(--accent);font-size:.8rem;letter-spacing:.12em;text-transform:uppercase;margin:0}
    .byline{font-size:1.15rem;margin:.2em 0}.medium{color:var(--muted);margin:0}
    img{max-width:100%;height:auto;display:block;border-radius:4px}.cover{margin-bottom:24px}
    .works{list-style:none;padding:0}.work{padding:20px 0;border-bottom:1px solid var(--rule)}
    dl{display:grid;grid-template-columns:max-content 1fr;gap:2px 16px;margin:0 0 12px}dt{color:var(--muted);font-size:.85rem}dd{margin:0}
    .alt span{color:var(--muted)}.interactions,.variants{color:var(--muted);font-size:.95rem}
    table{width:100%;border-collapse:collapse;font-size:.92rem}th,td{text-align:left;padding:8px 6px;border-bottom:1px solid var(--rule);vertical-align:top}
    th{font-size:.8rem;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}a{color:var(--accent)}
    .crit li{margin-bottom:12px}.crit .resolved{opacity:.6}.reply{font-style:italic}
    footer{margin-top:64px;color:var(--muted);font-size:.85rem}
    @media print{body{background:#fff;color:#000}main{padding:0}a{color:#000}}
    """
}
