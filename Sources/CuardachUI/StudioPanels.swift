#if canImport(SwiftUI) && os(iOS)
import CuardachAR
import CuardachCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Label, credit, variants, size (Studio extensions)

struct StudioPanel: View {
    let model: AuthorModel
    @State private var importingVariant = false
    @State private var variantName = ""

    static let licences: [(id: String, name: LocalizedStringKey)] = [
        ("Own-work", "My own work"),
        ("CC0-1.0", "CC0 (public domain)"),
        ("CC-BY-4.0", "CC BY"),
        ("CC-BY-SA-4.0", "CC BY-SA"),
        ("CC-BY-NC-4.0", "CC BY-NC"),
        ("CC-BY-NC-SA-4.0", "CC BY-NC-SA"),
        ("CC-BY-ND-4.0", "CC BY-ND"),
        ("CC-BY-NC-ND-4.0", "CC BY-NC-ND"),
        ("All-rights-reserved", "All rights reserved (with permission)"),
    ]

    var body: some View {
        if let e = model.selectedElement {
            Form {
                Section {
                    field("Title", e, \.title)
                    field("Artist or designer", e, \.artist)
                    field("Year", e, \.year)
                    field("Medium", e, \.medium)
                    field("Dimensions", e, \.dimensions)
                    field("Statement", e, \.statement, multiline: true)
                } header: { Text("Wall label") } footer: {
                    Text("What a gallery would print beside the work. It appears in the exhibition catalogue.")
                }

                Section {
                    field("Description", e, \.altText, multiline: true)
                } header: { Text("Description for VoiceOver") } footer: {
                    Text("Describe what someone would see, plainly, in a sentence or two.")
                }

                Section {
                    credit("Creator", e, \.creator)
                    credit("Source (e.g. Sketchfab, own scan)", e, \.source)
                    Picker("Licence", selection: Binding(
                        get: { e.credit?.licence ?? "" },
                        set: { v in model.editElement(e.id, String(localized: "Licence")) { el in
                            var c = el.credit ?? Credit(); c.licence = v.isEmpty ? nil : v; el.credit = c } })) {
                        Text("Unknown").tag("")
                        ForEach(Self.licences, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    credit("Link", e, \.url)
                    ForEach(e.credit?.restrictions ?? ["Licence unknown"], id: \.self) { r in
                        Label(r, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                } header: { Text("Credit and licence") } footer: {
                    Text("Record where every asset came from. The catalogue lists credits, and flags licences that limit how the work can be shown or sold.")
                }

                if e.kind == .model || e.kind == .image || e.kind == .video {
                    Section {
                        ForEach(e.variants) { v in
                            VStack(alignment: .leading) {
                                Text(v.name)
                                TextField("Why this option?", text: Binding(
                                    get: { v.note ?? "" },
                                    set: { n in model.editElement(e.id, String(localized: "Variant note"), coalesce: true) { el in
                                        if let i = el.variants.firstIndex(where: { $0.id == v.id }) { el.variants[i].note = n.isEmpty ? nil : n } } }),
                                    axis: .vertical).font(.caption)
                            }
                        }
                        .onDelete { o in model.editElement(e.id, String(localized: "Remove variant")) { $0.variants.remove(atOffsets: o) } }
                        TextField("New variant name (e.g. Brushed steel)", text: $variantName)
                        Button { importingVariant = true } label: { Label("Add variant from Files", systemImage: "plus") }
                            .disabled(variantName.isEmpty)
                        if e.variants.count > 1, !e.behaviours.contains(where: { $0.trigger == .tap && $0.actions.joined().contains { $0.type == .cycleVariant } }) {
                            Button {
                                model.editElement(e.id, String(localized: "Tap to cycle")) {
                                    $0.behaviours.append(Behaviour(trigger: .tap, retrigger: .immediately, actions: [[Action(.cycleVariant)]]))
                                }
                            } label: { Label("Let players tap to compare", systemImage: "hand.tap") }
                        }
                    } header: { Text("Variants") } footer: {
                        Text("Alternative colours, materials, finishes or iterations of the same piece, to compare in place.")
                    }
                }

                if e.kind == .model {
                    designSize(e)
                }
            }
            .navigationTitle(e.name)
            .fileImporter(isPresented: $importingVariant, allowedContentTypes: AuthorScreen.importTypes) { result in
                if case .success(let url) = result {
                    let name = variantName
                    variantName = ""
                    Task { await model.addVariant(from: url, name: name) }
                }
            }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "hand.tap")
        }
    }

    @ViewBuilder
    private func designSize(_ e: Element) -> some View {
        let size = e.designSize
        Section {
            mm("Width", size?.widthM) { v in setSize(e) { $0.widthM = v } }
            mm("Height", size?.heightM) { v in setSize(e) { $0.heightM = v } }
            mm("Depth", size?.depthM) { v in setSize(e) { $0.depthM = v } }
            Toggle("Lock at 1:1", isOn: Binding(get: { size?.lockScale ?? false }, set: { v in setSize(e) { $0.lockScale = v } }))
                .disabled(size == nil)
            if size != nil {
                Button { model.fitToDesignSize() } label: { Label("Scale model to these dimensions", systemImage: "arrow.up.left.and.arrow.down.right") }
            }
            if let m = model.measuredSize(e.id) { LabeledContent("Measured now", value: m) }
        } header: { Text("True size") } footer: {
            Text("Set the real dimensions of the object and lock it at 1:1, so it sits in the room exactly as big as it would be.")
        }
    }

    private func setSize(_ e: Element, _ change: @escaping (inout DesignSize) -> Void) {
        model.editElement(e.id, String(localized: "Design size"), coalesce: true) { el in
            var s = el.designSize ?? DesignSize(widthM: 0.5, heightM: 0.5, depthM: 0.5, lockScale: false)
            change(&s)
            el.designSize = s
        }
    }

    private func mm(_ title: LocalizedStringKey, _ metres: Double?, _ set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField("mm", value: Binding(get: { metres.map { ($0 * 1000).rounded() } }, set: { v in if let v, v > 0 { set(v / 1000) } }),
                      format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func field(_ title: LocalizedStringKey, _ e: Element, _ kp: WritableKeyPath<WallLabel, String?>, multiline: Bool = false) -> some View {
        TextField(title, text: Binding(
            get: { e.label?[keyPath: kp] ?? "" },
            set: { v in model.editElement(e.id, String(localized: "Label"), coalesce: true) { el in
                var l = el.label ?? WallLabel(); l[keyPath: kp] = v.isEmpty ? nil : v; el.label = l } }),
            axis: multiline ? .vertical : .horizontal)
    }

    private func credit(_ title: LocalizedStringKey, _ e: Element, _ kp: WritableKeyPath<Credit, String?>) -> some View {
        TextField(title, text: Binding(
            get: { e.credit?[keyPath: kp] ?? "" },
            set: { v in model.editElement(e.id, String(localized: "Credit"), coalesce: true) { el in
                var c = el.credit ?? Credit(); c[keyPath: kp] = v.isEmpty ? nil : v; el.credit = c } }))
    }
}

// MARK: Crit notes (Studio extension)

struct CritPanel: View {
    let model: AuthorModel
    @AppStorage("critAuthorName") private var author = ""
    @State private var kind = CritNote.Kind.suggestion
    @State private var text = ""
    @State private var replying: CritNote?
    @State private var reply = ""

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $author)
                Picker("Kind", selection: $kind) {
                    Text("Question").tag(CritNote.Kind.question)
                    Text("Suggestion").tag(CritNote.Kind.suggestion)
                    Text("Strength").tag(CritNote.Kind.strength)
                    Text("Issue").tag(CritNote.Kind.issue)
                }
                .pickerStyle(.segmented)
                TextField("Note", text: $text, axis: .vertical).lineLimit(2...6)
                Button {
                    model.addCritNote(author: author.isEmpty ? String(localized: "Anonymous") : author, kind: kind, text: text)
                    text = ""
                } label: {
                    Label(model.selectedElement.map { "Leave note on “\($0.name)”" } ?? String(localized: "Leave note on the whole piece"),
                          systemImage: "bubble.left")
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Leave a note") } footer: {
                Text("Notes float where you are standing, beside the element they are about. Share the file back to the author when you're done.")
            }

            Toggle("Show notes in the scene", isOn: Binding(get: { model.showCritLayer }, set: { model.showCritLayer = $0 }))

            let open = model.experience.annotations.filter { !$0.resolved }
            let done = model.experience.annotations.filter(\.resolved)
            if !open.isEmpty {
                Section("Open") { ForEach(open) { note($0) } }
            }
            if !done.isEmpty {
                Section("Resolved") { ForEach(done) { note($0) } }
            }
        }
        .navigationTitle("Crit")
        .alert("Resolve note", isPresented: Binding(get: { replying != nil }, set: { if !$0 { replying = nil } })) {
            TextField("Reply (optional)", text: $reply)
            Button("Resolve") { if let n = replying { model.resolveCritNote(n.id, reply: reply) }; reply = "" }
            Button("Cancel", role: .cancel) { reply = "" }
        } message: { Text(replying?.text ?? "") }
    }

    private func note(_ n: CritNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(n.kind.rawValue.capitalized).font(.caption.weight(.semibold))
                Text(n.author).font(.caption).foregroundStyle(.secondary)
                if let id = n.elementId, let e = model.experience.element(id: id) {
                    Text("· \(e.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(n.text)
            if let r = n.reply { Text("Reply: \(r)").font(.caption).italic() }
        }
        .swipeActions {
            if !n.resolved { Button("Resolve") { replying = n }.tint(.green) }
        }
    }
}

// MARK: Share and export (PRD S1–S5)

struct ExportPanel: View {
    let model: AuthorModel
    @State private var packed: URL?
    @State private var markersPDF: URL?
    @State private var catalogue: URL?
    @State private var includeCrit = false
    @State private var hostedURL = ""
    @State private var working = false
    @State private var error: String?

    private var issues: [ValidationIssue] { BundleValidator(bundle: model.bundle).validate(model.experience) }
    private var bytes: Int { (try? model.bundle.totalBytes()) ?? 0 }

    var body: some View {
        Form {
            Section {
                LabeledContent("Size", value: ByteSize.format(bytes))
                if bytes > AssetPolicy.bundleWarningBytes {
                    Label("Over 50 MB: email and Messages may refuse it. Share by AirDrop, or upload it and share a QR code.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
                if let packed {
                    ShareLink(item: packed) { Label("Share \(packed.lastPathComponent)", systemImage: "square.and.arrow.up") }
                } else {
                    Button { Task { await pack() } } label: { Label("Prepare the experience file", systemImage: "shippingbox") }
                        .disabled(working || issues.contains { $0.severity == .error })
                }
            } header: { Text("Experience file (.arhunt)") } footer: {
                Text("Anyone with Cuardach can open this file from AirDrop, Files, Mail or a link. It works offline and doesn't depend on any server.")
            }

            if !issues.isEmpty {
                Section("Checks") {
                    ForEach(issues, id: \.self) { i in
                        Label { Text(i.message) } icon: { Image(systemName: i.severity.symbol).foregroundStyle(i.severity.color) }
                            .font(.callout)
                    }
                }
            }

            Section {
                if let markersPDF {
                    ShareLink(item: markersPDF) { Label("Share marker sheets (PDF)", systemImage: "printer") }
                } else {
                    Button { markersPDF = makeMarkers() } label: { Label("Make marker sheets", systemImage: "qrcode") }
                        .disabled(!model.experience.elements.contains { $0.anchors.contains { $0.tier == .image } })
                }
            } header: { Text("Printed markers") } footer: {
                Text("One A4 page per marker at the right size. Print at 100%, without “fit to page”.")
            }

            Section {
                Toggle("Include crit notes", isOn: $includeCrit)
                if let catalogue {
                    ShareLink(item: catalogue) { Label("Share catalogue", systemImage: "doc.richtext") }
                } else {
                    Button { catalogue = makeCatalogue() } label: { Label("Make catalogue", systemImage: "book") }
                }
            } header: { Text("Exhibition catalogue") } footer: {
                Text("A web page with your statement, labels, interactions and credits: for hand-in, a degree show handout or your portfolio.")
            }
            .onChange(of: includeCrit) { _, _ in catalogue = nil }

            Section {
                TextField("https://… link to the uploaded .arhunt file", text: $hostedURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let u = URL(string: hostedURL), let link = DeepLink.openLink(for: u),
                   let qr = MarkerRenderer.qrImage(link.absoluteString, size: 600) {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("QR code that opens this experience")
                    ShareLink(item: Image(uiImage: qr), preview: SharePreview("QR code", image: Image(uiImage: qr))) {
                        Label("Share QR code", systemImage: "square.and.arrow.up")
                    }
                } else if !hostedURL.isEmpty {
                    Text("Use an https:// link.").font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("QR code for a hosted file") } footer: {
                Text("Upload the file anywhere that gives a direct https link (a college server, a GitHub release, iCloud). Scanning the code downloads and opens it.")
            }
        }
        .navigationTitle("Share")
        .alert("Couldn't export", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var exportDir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func pack() async {
        working = true
        defer { working = false }
        await model.save()
        let out = exportDir.appendingPathComponent("\(ExperienceBundle.slug(model.experience.title)).\(BundleLayout.fileExtension)")
        try? FileManager.default.removeItem(at: out)
        do { try model.bundle.pack(to: out); packed = out } catch { self.error = error.localizedDescription }
    }

    private func makeMarkers() -> URL? {
        var sheets: [MarkerRenderer.Sheet] = []
        for e in model.experience.elements {
            for a in e.anchors where a.tier == .image {
                guard let path = a.imageFile, let url = try? model.bundle.url(for: path), let img = UIImage(contentsOfFile: url.path) else { continue }
                sheets.append(.init(element: e, anchor: a, markerImage: img))
            }
        }
        let link = URL(string: hostedURL).flatMap(DeepLink.openLink(for:))
        let data = MarkerRenderer.pdf(title: model.experience.title, sheets: sheets, shareLink: link)
        let out = exportDir.appendingPathComponent("\(ExperienceBundle.slug(model.experience.title))-markers.pdf")
        do { try data.write(to: out); return out } catch { self.error = error.localizedDescription; return nil }
    }

    private func makeCatalogue() -> URL? {
        let html = Catalogue(bundle: model.bundle, options: .init(includeCritNotes: includeCrit)).html()
        let out = exportDir.appendingPathComponent("\(ExperienceBundle.slug(model.experience.title))-catalogue.html")
        do { try Data(html.utf8).write(to: out); return out } catch { self.error = error.localizedDescription; return nil }
    }
}
#endif
