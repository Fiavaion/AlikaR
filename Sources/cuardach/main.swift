// cuardach — command-line companion for .arhunt bundles.
//
// For lecturers checking hand-ins, for the Mac asset pipeline (AROR), and
// for CI. Runs on macOS and Linux; no third-party dependencies.

import CuardachCore
import Foundation

let usage = """
usage: cuardach <command> [arguments]

  validate <bundle> [--strict]        Check a bundle; exit 1 on errors (or warnings with --strict)
  inspect <bundle>                    Summarise elements, anchors, behaviours and file sizes
  catalogue <bundle> [-o file] [--crit]
                                      Write the exhibition catalogue as HTML
  pack <folder> [-o file.arhunt]      Zip an unpacked bundle folder for sharing
  unpack <file.arhunt> [dir]          Unpack a bundle into a folder
  new <title> [--author name] [--dir path]
                                      Create an empty bundle folder
  glb <file.glb|file.gltf>            Report triangles, clips, textures and import warnings
  marker <bundle> <element-id> [-o file.svg]
                                      Write a printable A4 marker sheet (SVG) at the anchor's true width
  link <https-url>                    Print the cuardach:// link to put in a QR code
  briefs [--markdown]                 List the studio briefs

A <bundle> is a .arhunt file or an unpacked .arhunt folder.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cuardach: \(message)\n".utf8))
    exit(2)
}

/// Splits arguments into positionals and `--flag [value]` options.
struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, valued: Set<String>) {
        var it = raw.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("-") {
                if valued.contains(a) {
                    guard let v = it.next() else { fail("\(a) needs a value") }
                    options[a] = v
                } else {
                    flags.insert(a)
                }
            } else {
                positional.append(a)
            }
        }
    }
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

/// Opens a folder in place, or unpacks a zip into a temporary directory.
func openBundle(_ path: String) throws -> ExperienceBundle {
    let u = url(path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { throw CLIError("\(path): no such file") }
    if isDir.boolValue { return try ExperienceBundle.open(folder: u) }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cuardach-\(UUID().uuidString)")
    return try ExperienceBundle.unpack(u, into: tmp)
}

func validate(_ a: Args) throws -> Int32 {
    guard let path = a.positional.first else { fail("validate needs a bundle") }
    let b = try openBundle(path)
    let issues = BundleValidator(bundle: b).validate(b.experience)
    for i in issues { print(i) }
    let errors = issues.filter { $0.severity == .error }.count
    let warnings = issues.filter { $0.severity == .warning }.count
    let notes = issues.count - errors - warnings
    print("\(b.experience.title): \(errors) error(s), \(warnings) warning(s), \(notes) note(s)")
    if errors > 0 || (a.flags.contains("--strict") && warnings > 0) { return 1 }
    return 0
}

func inspect(_ a: Args) throws -> Int32 {
    guard let path = a.positional.first else { fail("inspect needs a bundle") }
    let b = try openBundle(path)
    let x = b.experience
    print("\(x.title)  —  \(x.author)")
    print("id \(x.id) · schema \(x.schemaVersion) · created \(x.created)\(b.isReadOnly ? " · READ-ONLY (newer schema)" : "")")
    if let s = x.siteHint { print(String(format: "site %.5f, %.5f within %.0f m", s.lat, s.long, s.radiusM)) }
    if let st = x.label?.statement { print("\n\(st)") }
    print("\n\(x.elements.count) element(s)")
    for e in x.elements {
        print("\n• \(e.name) [\(e.kind)] \(e.id)")
        if let asset = e.asset { print("  asset      \(asset)") }
        print("  precision  \(e.precision?.title ?? "none")")
        for anchor in e.anchorsInResolutionOrder {
            print("  anchor     \(anchor.priority) \(anchor.tier) \(anchor.id)")
        }
        for beh in e.behaviours { print("  behaviour  \(BehaviourDescriber.describe(beh, on: e, in: x))") }
        if !e.variants.isEmpty { print("  variants   \(e.variants.map(\.name).joined(separator: ", "))") }
        if let d = e.designSize { print("  size       \(d.formattedMillimetres)\(d.lockScale ? " (locked 1:1)" : "")") }
        if let c = e.credit { print("  credit     \([c.creator, c.source, c.licence].compactMap { $0 }.joined(separator: " · "))") }
    }
    if !x.annotations.isEmpty {
        print("\n\(x.annotations.count) crit note(s), \(x.annotations.filter { !$0.resolved }.count) open")
    }
    let files = try b.files()
    print("\nfiles")
    for f in files { print("  \(ByteSize.format(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(f.path)") }
    print("  total \(ByteSize.format(files.reduce(0) { $0 + $1.bytes }))")
    return 0
}

func catalogue(_ a: Args) throws -> Int32 {
    guard let path = a.positional.first else { fail("catalogue needs a bundle") }
    let b = try openBundle(path)
    let html = Catalogue(bundle: b, options: .init(includeCritNotes: a.flags.contains("--crit"))).html()
    let out = a.options["-o"].map(url) ?? url("\(ExperienceBundle.slug(b.experience.title)).html")
    try Data(html.utf8).write(to: out)
    print("wrote \(out.path)")
    return 0
}

func pack(_ a: Args) throws -> Int32 {
    guard let path = a.positional.first else { fail("pack needs a folder") }
    let b = try ExperienceBundle.open(folder: url(path))
    let issues = BundleValidator(bundle: b).validate(b.experience).filter { $0.severity == .error }
    if !issues.isEmpty {
        issues.forEach { print($0) }
        throw CLIError("fix the errors above before packing")
    }
    let out = a.options["-o"].map(url) ?? url("\(ExperienceBundle.slug(b.experience.title)).\(BundleLayout.fileExtension)")
    try b.pack(to: out)
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)??.intValue ?? 0
    print("wrote \(out.path) (\(ByteSize.format(size)))")
    if size > AssetPolicy.bundleWarningBytes { print("note: over 50 MB; share by AirDrop or a QR link rather than email") }
    return 0
}

func unpack(_ a: Args) throws -> Int32 {
    guard let path = a.positional.first else { fail("unpack needs a .arhunt file") }
    let dir = a.positional.count > 1 ? url(a.positional[1]) : url(".")
    let b = try ExperienceBundle.unpack(url(path), into: dir)
    print("unpacked \(b.experience.title) to \(b.folder.path)")
    return 0
}

func new(_ a: Args) throws -> Int32 {
    guard let title = a.positional.first else { fail("new needs a title") }
    let x = Experience(title: title, author: a.options["--author"] ?? "")
    let b = try ExperienceBundle.create(x, in: a.options["--dir"].map(url) ?? url("."))
    print("created \(b.folder.path)")
    return 0
}

func glb(_ a: Args) throws -> Int32 {
    guard let path = a.positional.first else { fail("glb needs a file") }
    let u = url(path)
    let dir = u.deletingLastPathComponent()
    let exists: (String) -> Bool = { rel in
        (try? SafePath.resolve(rel, under: dir)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    let data = try Data(contentsOf: u)
    let ext = u.pathExtension.lowercased()
    let m = ext == "gltf" ? try GLBInspector.inspect(gltfJSON: data, resourceExists: exists)
                          : try GLBInspector.inspect(glb: data, resourceExists: exists)
    print("\(u.lastPathComponent): \(ByteSize.format(data.count))")
    print("triangles   \(m.triangles ?? 0)")
    if let s = m.boundingSize { print(String(format: "size        %.3f × %.3f × %.3f (model units, usually metres)", s.x, s.y, s.z)) }
    print("animations  \(m.animationClips.isEmpty ? "none" : m.animationClips.joined(separator: ", "))")
    for w in m.warnings(format: ext == "gltf" ? .gltf : .glb) { print("\(w.severity): \(w.message)") }
    return 0
}

/// An A4 SVG with the element's marker pattern at its real printed width,
/// for printing from any computer. The app makes the same pattern as PNG.
func marker(_ a: Args) throws -> Int32 {
    guard a.positional.count >= 2 else { fail("marker needs a bundle and an element id") }
    let b = try openBundle(a.positional[0])
    guard let e = b.experience.element(id: a.positional[1]) else { throw CLIError("no element \(a.positional[1])") }
    let widthMM = (e.anchors.first { $0.tier == .image }?.physicalWidthM ?? 0.18) * 1000
    let p = MarkerPattern(seed: e.id)
    let cell = widthMM / Double(p.size)
    let x0 = (210 - widthMM) / 2, y0 = 40.0
    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"210mm\" height=\"297mm\" viewBox=\"0 0 210 297\">\n"
    svg += "<rect width=\"210\" height=\"297\" fill=\"#fff\"/>\n<g fill=\"#000\" shape-rendering=\"crispEdges\">\n"
    for r in 0..<p.size {
        for c in 0..<p.size where p[r, c] {
            svg += String(format: "<rect x=\"%.3f\" y=\"%.3f\" width=\"%.3f\" height=\"%.3f\"/>\n",
                          x0 + Double(c) * cell, y0 + Double(r) * cell, cell + 0.01, cell + 0.01)
        }
    }
    let ty = y0 + widthMM + 18
    svg += "</g>\n<text x=\"105\" y=\"\(ty)\" font-family=\"Helvetica, Arial, sans-serif\" font-size=\"9\" text-anchor=\"middle\">\(Catalogue.escape(e.name))</text>\n"
    svg += "<text x=\"105\" y=\"\(ty + 8)\" font-family=\"Helvetica, Arial, sans-serif\" font-size=\"4\" fill=\"#555\" text-anchor=\"middle\">\(Catalogue.escape(b.experience.title)) · print at 100% · pattern \(Int(widthMM.rounded())) mm wide · mount flat, avoid glossy lamination</text>\n</svg>\n"
    let out = a.options["-o"].map(url) ?? url("marker-\(ExperienceBundle.slug(e.name)).svg")
    try Data(svg.utf8).write(to: out)
    print("wrote \(out.path) (\(Int(widthMM.rounded())) mm pattern)")
    return 0
}

func link(_ a: Args) throws -> Int32 {
    guard let s = a.positional.first, let u = URL(string: s), let l = DeepLink.openLink(for: u) else {
        fail("link needs an https:// URL to a .arhunt file")
    }
    print(l.absoluteString)
    return 0
}

func briefs(_ a: Args) -> Int32 {
    if a.flags.contains("--markdown") {
        print(StudioBrief.markdown(), terminator: "")
        return 0
    }
    for b in StudioBrief.all {
        print("\(b.title)  [\(b.disciplines.map(\.rawValue).joined(separator: ", "))]\n  \(b.prompt)\n")
    }
    return 0
}

let argv = CommandLine.arguments
guard argv.count > 1 else { print(usage); exit(0) }
let args = Args(argv.dropFirst(2), valued: ["-o", "--author", "--dir"])
do {
    let code: Int32
    switch argv[1] {
    case "validate": code = try validate(args)
    case "inspect": code = try inspect(args)
    case "catalogue", "catalog": code = try catalogue(args)
    case "pack": code = try pack(args)
    case "unpack": code = try unpack(args)
    case "new": code = try new(args)
    case "glb", "gltf": code = try glb(args)
    case "marker": code = try marker(args)
    case "link": code = try link(args)
    case "briefs": code = briefs(args)
    case "-h", "--help", "help": print(usage); code = 0
    default: fail("unknown command \"\(argv[1])\"\n\n\(usage)")
    }
    exit(code)
} catch {
    fail("\(error)")
}
