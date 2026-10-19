#if canImport(SwiftUI) && os(iOS)
import CuardachAR
import CuardachCore
import SwiftUI

extension AuthorModel {
    /// A binding to one field of an element, with coalesced undo.
    func binding<T: Equatable>(_ id: String, _ kp: WritableKeyPath<Element, T>, _ label: String, fallback: T) -> Binding<T> {
        Binding(get: { self.experience.element(id: id)?[keyPath: kp] ?? fallback },
                set: { v in self.editElement(id, label, coalesce: true) { $0[keyPath: kp] = v } })
    }

    /// Runs one behaviour now, entering preview if needed (PRD A10 "simulate").
    func simulate(elementId id: String, behaviour index: Int) {
        if !isPreviewing { startPreview() }
        runSimulation(id, index)
    }
}

// MARK: Scene list (PRD A12)

struct SceneListPanel: View {
    let model: AuthorModel
    let open: (AuthorSheet) -> Void
    @State private var renaming: Element?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(model.experience.elements) { e in
                    Button { model.selection = e.id; open(.inspector) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: e.kind.symbol).frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(e.name).foregroundStyle(.primary)
                                Text(model.ar.isPlaced(e.id) ? "In view this session" : "Not placed in this session")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if e.startsHidden { Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityLabel("Starts hidden") }
                            PrecisionBadge(precision: e.precision)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { model.delete(e.id) } label: { Label("Delete", systemImage: "trash") }
                        Button { model.duplicate(e.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.tint(.indigo)
                    }
                    .contextMenu {
                        Button { renaming = e; newName = e.name } label: { Label("Rename", systemImage: "pencil") }
                        Button { model.editElement(e.id, String(localized: "Visibility")) { $0.state = $0.startsHidden ? nil : ElementState.hidden } } label: {
                            Label(e.startsHidden ? "Start visible" : "Start hidden", systemImage: e.startsHidden ? "eye" : "eye.slash")
                        }
                        Button { model.duplicate(e.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) { model.delete(e.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } footer: {
                Text("Elements placed in an earlier scan appear when you look around that space.")
            }
        }
        .navigationTitle("Elements")
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let e = renaming { model.editElement(e.id, String(localized: "Rename")) { $0.name = newName } } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: Inspector (PRD A6–A9)

struct InspectorPanel: View {
    let model: AuthorModel

    var body: some View {
        if let e = model.selectedElement {
            Form {
                Section {
                    TextField("Name", text: model.binding(e.id, \.name, String(localized: "Rename"), fallback: ""))
                    Toggle("Starts hidden", isOn: Binding(
                        get: { e.startsHidden },
                        set: { v in model.editElement(e.id, String(localized: "Visibility")) { $0.state = v ? ElementState.hidden : nil } }))
                    Toggle("Always face the viewer", isOn: model.binding(e.id, \.faceViewer, String(localized: "Face viewer"), fallback: false))
                }
                Section("Position (metres from its anchor)") {
                    vecRow("Across", e.id, \.transform.position.x)
                    vecRow("Up", e.id, \.transform.position.y)
                    vecRow("Forward", e.id, \.transform.position.z)
                    Button { model.snapToSurface() } label: { Label("Drop onto surface", systemImage: "arrow.down.to.line") }
                }
                Section("Rotation (degrees)") {
                    eulerRow("Turn", e, \.yaw)
                    eulerRow("Tilt", e, \.pitch)
                    eulerRow("Roll", e, \.roll)
                }
                Section {
                    if e.designSize?.lockScale == true {
                        Label("Scale is locked to the design size", systemImage: "lock")
                    } else {
                        LabeledContent("Scale") {
                            TextField("Scale", value: Binding(
                                get: { e.transform.scale.x },
                                set: { s in model.editElement(e.id, String(localized: "Scale"), coalesce: true) { $0.transform.scale = Vec3(s, s, s) } }),
                                format: .number.precision(.fractionLength(0...3)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                    if let size = model.measuredSize(e.id) { LabeledContent("Measured size", value: size) }
                } header: { Text("Size") }
                playback(e)
            }
            .navigationTitle("Adjust")
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "hand.tap", description: Text("Tap an element to adjust it."))
        }
    }

    private func vecRow(_ title: LocalizedStringKey, _ id: String, _ kp: WritableKeyPath<Element, Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: model.binding(id, kp, String(localized: "Move"), fallback: 0), format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
        }
    }

    private func eulerRow(_ title: LocalizedStringKey, _ e: Element, _ kp: WritableKeyPath<EulerAngles, Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { e.transform.rotation.eulerDegrees[keyPath: kp].rounded() },
                set: { v in
                    model.editElement(e.id, String(localized: "Rotate"), coalesce: true) { el in
                        var angles = el.transform.rotation.eulerDegrees
                        angles[keyPath: kp] = v
                        el.transform.rotation = Quat(eulerDegrees: angles)
                    }
                }), format: .number.precision(.fractionLength(0)))
            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func playback(_ e: Element) -> some View {
        let clips = model.clips(e.id)
        if e.kind == .model, !clips.isEmpty {
            Section("Animation") {
                Picker("Clip", selection: Binding(
                    get: { e.playback?.clip ?? clips.first ?? "" },
                    set: { c in model.editElement(e.id, String(localized: "Animation")) { el in
                        var p = el.playback ?? Playback(); p.clip = c; el.playback = p } })) {
                    ForEach(clips, id: \.self) { Text($0).tag($0) }
                }
                playbackToggles(e)
            }
        } else if e.kind == .video || e.kind == .audio {
            Section(e.kind == .video ? "Video" : "Sound") {
                playbackToggles(e)
                if e.kind == .video {
                    Toggle("Muted", isOn: Binding(
                        get: { e.playback?.muted ?? false },
                        set: { m in model.editElement(e.id, String(localized: "Mute")) { el in var p = el.playback ?? Playback(); p.muted = m; el.playback = p } }))
                }
            }
        }
    }

    @ViewBuilder
    private func playbackToggles(_ e: Element) -> some View {
        Toggle("Loop", isOn: Binding(
            get: { e.playback?.loop ?? true },
            set: { l in model.editElement(e.id, String(localized: "Loop")) { el in var p = el.playback ?? Playback(); p.loop = l; el.playback = p } }))
        if e.kind == .model {
            LabeledContent("Speed") {
                Stepper(value: Binding(
                    get: { e.playback?.speed ?? 1 },
                    set: { s in model.editElement(e.id, String(localized: "Speed"), coalesce: true) { el in var p = el.playback ?? Playback(); p.speed = s; el.playback = p } }),
                    in: 0.25...4, step: 0.25) { Text("\((e.playback?.speed ?? 1).formatted())×") }
            }
        }
    }
}

// MARK: Behaviours (PRD A10)

struct BehaviourPanel: View {
    let model: AuthorModel

    var body: some View {
        if let e = model.selectedElement {
            List {
                Section {
                    ForEach(Array(e.behaviours.enumerated()), id: \.element.id) { i, b in
                        NavigationLink {
                            BehaviourEditor(model: model, elementId: e.id, behaviourId: b.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(BehaviourDescriber.describe(b, on: e, in: model.experience))
                                Button { model.simulate(elementId: e.id, behaviour: i) } label: {
                                    Label("Simulate", systemImage: "play.circle")
                                }
                                .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                    .onDelete { offsets in
                        model.editElement(e.id, String(localized: "Delete behaviour")) { $0.behaviours.remove(atOffsets: offsets) }
                    }
                } footer: {
                    Text("A behaviour is a trigger followed by steps. Actions in the same step run together; each step waits for the one before.")
                }
                Section("Add a behaviour") {
                    ForEach(Trigger.known, id: \.self) { t in
                        Button {
                            model.editElement(e.id, String(localized: "Add behaviour")) { $0.behaviours.append(Behaviour(trigger: t)) }
                        } label: {
                            Label(TriggerUI.title(t), systemImage: TriggerUI.symbol(t))
                        }
                    }
                }
            }
            .navigationTitle("Behaviours")
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "hand.tap", description: Text("Tap an element to give it behaviours."))
        }
    }
}

enum TriggerUI {
    static func title(_ t: Trigger) -> LocalizedStringKey {
        switch t {
        case .start: "When it appears"
        case .tap: "When tapped"
        case .proximityEnter: "When someone comes near"
        case .proximityExit: "When someone walks away"
        case .dwell: "After being looked at"
        case .timeWindow: "At certain times of day"
        default: LocalizedStringKey(t.rawValue)
        }
    }

    static func symbol(_ t: Trigger) -> String {
        switch t {
        case .start: "sparkles"
        case .tap: "hand.tap"
        case .proximityEnter: "figure.walk.arrival"
        case .proximityExit: "figure.walk.departure"
        case .dwell: "eye"
        case .timeWindow: "clock"
        default: "questionmark"
        }
    }

    static func actionTitle(_ a: ActionType) -> LocalizedStringKey {
        switch a {
        case .playAnimation: "Play animation"
        case .stopAnimation: "Stop animation"
        case .show: "Show"
        case .hide: "Hide"
        case .moveTo: "Move to"
        case .rotate: "Spin"
        case .scale: "Scale"
        case .playAudio: "Play sound"
        case .playVideo: "Play video"
        case .delay: "Wait"
        case .setState: "Set state"
        case .setVariant: "Switch variant"
        case .cycleVariant: "Next variant"
        default: LocalizedStringKey(a.rawValue)
        }
    }
}

struct BehaviourEditor: View {
    let model: AuthorModel
    let elementId: String
    let behaviourId: String

    private var element: Element? { model.experience.element(id: elementId) }
    private var index: Int? { element?.behaviours.firstIndex { $0.id == behaviourId } }

    private func update(_ label: String = String(localized: "Edit behaviour"), coalesce: Bool = true, _ change: @escaping (inout Behaviour) -> Void) {
        model.editElement(elementId, label, coalesce: coalesce) { e in
            guard let i = e.behaviours.firstIndex(where: { $0.id == behaviourId }) else { return }
            change(&e.behaviours[i])
        }
    }

    var body: some View {
        if let e = element, let i = index {
            let b = e.behaviours[i]
            Form {
                Section("Trigger") {
                    Picker("Trigger", selection: Binding(get: { b.trigger }, set: { t in update { $0.trigger = t } })) {
                        ForEach(Trigger.known, id: \.self) { Text(TriggerUI.title($0)).tag($0) }
                    }
                    if [.proximityEnter, .proximityExit, .dwell].contains(b.trigger) {
                        Stepper(value: Binding(get: { b.effectiveProximityM }, set: { v in update { $0.proximityM = v } }), in: 0.5...30, step: 0.5) {
                            Text("Within \(b.effectiveProximityM.formatted()) m")
                        }
                    }
                    if b.trigger == .dwell {
                        Stepper(value: Binding(get: { b.effectiveDwellS }, set: { v in update { $0.dwellS = v } }), in: 1...300, step: 1) {
                            Text("Looked at for \(Int(b.effectiveDwellS)) s")
                        }
                    }
                    if b.trigger == .timeWindow {
                        timeRow("From", b.window?.from ?? "18:00") { v in update { $0.window = TimeWindow(from: v, to: $0.window?.to ?? "23:00") } }
                        timeRow("Until", b.window?.to ?? "23:00") { v in update { $0.window = TimeWindow(from: $0.window?.from ?? "18:00", to: v) } }
                    }
                    Picker("If triggered again", selection: Binding(get: { b.retrigger }, set: { r in update { $0.retrigger = r } })) {
                        Text("Wait until finished").tag(Retrigger.afterComplete)
                        Text("Start over").tag(Retrigger.immediately)
                        Text("Only ever once").tag(Retrigger.never)
                    }
                }
                ForEach(Array(b.actions.enumerated()), id: \.offset) { step, group in
                    Section {
                        ForEach(Array(group.enumerated()), id: \.offset) { j, action in
                            ActionRow(model: model, element: e, action: action) { newValue in
                                update { beh in
                                    if let v = newValue { beh.actions[step][j] = v } else { beh.actions[step].remove(at: j) }
                                    beh.actions.removeAll(where: \.isEmpty)
                                }
                            }
                        }
                        addActionMenu(title: "Add to this step") { a in update(coalesce: false) { $0.actions[step].append(a) } }
                    } header: { Text("Step \(step + 1)") }
                }
                Section {
                    addActionMenu(title: "Add a step") { a in update(coalesce: false) { $0.actions.append([a]) } }
                    Button { model.simulate(elementId: elementId, behaviour: i) } label: { Label("Simulate", systemImage: "play.circle") }
                }
            }
            .navigationTitle(TriggerUI.title(b.trigger))
        }
    }

    private func addActionMenu(title: LocalizedStringKey, _ add: @escaping (Action) -> Void) -> some View {
        Menu {
            ForEach(ActionType.known, id: \.self) { t in
                Button(TriggerUI.actionTitle(t)) { add(Self.defaultAction(t)) }
            }
        } label: { Label(title, systemImage: "plus") }
    }

    static func defaultAction(_ t: ActionType) -> Action {
        var a = Action(t)
        switch t {
        case .delay: a.seconds = 1
        case .show, .hide: a.duration = 0.3
        case .moveTo: a.position = Vec3(0, 0.5, 0); a.duration = 1
        case .rotate: a.degrees = 360; a.duration = 2
        case .scale: a.factor = 1.5; a.duration = 0.5
        case .setState: a.value = ElementState.found
        default: break
        }
        return a
    }

    private func timeRow(_ title: LocalizedStringKey, _ hhmm: String, _ set: @escaping (String) -> Void) -> some View {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let date = Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.last ?? 0, second: 0, of: Date()) ?? Date()
        return DatePicker(title, selection: Binding(get: { date }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            set(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
        }), displayedComponents: .hourAndMinute)
    }
}

/// One action with the parameters its type needs.
struct ActionRow: View {
    let model: AuthorModel
    let element: Element
    let action: Action
    /// nil deletes the action.
    let change: (Action?) -> Void

    private var target: Element? { model.experience.element(id: action.target ?? element.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(TriggerUI.actionTitle(action.type)).font(.headline)
                Spacer()
                Menu {
                    Picker("Target", selection: Binding(get: { action.target ?? element.id }, set: { t in
                        var a = action; a.target = t == element.id ? nil : t; change(a)
                    })) {
                        ForEach(model.experience.elements) { Text($0.id == element.id ? String(localized: "This element") : $0.name).tag($0.id) }
                    }
                } label: { Text(target?.id == element.id ? "This element" : (target?.name ?? "?")).font(.caption) }
                Button(role: .destructive) { change(nil) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove action")
            }
            parameters
        }
    }

    @ViewBuilder
    private var parameters: some View {
        switch action.type {
        case .delay:
            number("Seconds", action.seconds ?? 1) { var a = action; a.seconds = $0; change(a) }
        case .show, .hide:
            number("Fade (s)", action.duration ?? 0.3) { var a = action; a.duration = $0; change(a) }
        case .moveTo:
            let p = action.position ?? .zero
            number("Across (m)", p.x) { var a = action; a.position = Vec3($0, p.y, p.z); change(a) }
            number("Up (m)", p.y) { var a = action; a.position = Vec3(p.x, $0, p.z); change(a) }
            number("Forward (m)", p.z) { var a = action; a.position = Vec3(p.x, p.y, $0); change(a) }
            number("Over (s)", action.duration ?? 1) { var a = action; a.duration = $0; change(a) }
        case .rotate:
            number("Degrees", action.degrees ?? 360) { var a = action; a.degrees = $0; change(a) }
            number("Over (s)", action.duration ?? 2) { var a = action; a.duration = $0; change(a) }
        case .scale:
            number("Factor", action.factor ?? 1.5) { var a = action; a.factor = $0; change(a) }
            number("Over (s)", action.duration ?? 0.5) { var a = action; a.duration = $0; change(a) }
        case .playAnimation:
            let clips = model.clips(target?.id ?? element.id)
            if !clips.isEmpty {
                Picker("Clip", selection: Binding(get: { action.clip ?? clips[0] }, set: { var a = action; a.clip = $0; change(a) })) {
                    ForEach(clips, id: \.self) { Text($0).tag($0) }
                }
            }
            Toggle("Loop", isOn: Binding(get: { action.loop ?? false }, set: { var a = action; a.loop = $0; change(a) }))
        case .setState:
            Picker("State", selection: Binding(get: { action.value ?? ElementState.found }, set: { var a = action; a.value = $0; change(a) })) {
                Text("Found").tag(ElementState.found)
                Text("Visible (unlock)").tag(ElementState.visible)
                Text("Hidden").tag(ElementState.hidden)
            }
        case .setVariant:
            if let vs = target?.variants, !vs.isEmpty {
                Picker("Variant", selection: Binding(get: { action.variant ?? vs[0].id }, set: { var a = action; a.variant = $0; change(a) })) {
                    ForEach(vs) { Text($0.name).tag($0.id) }
                }
            } else {
                Text("Add variants to this element under Label, credit and variants.").font(.caption).foregroundStyle(.secondary)
            }
        case .playAudio:
            Text(action.asset ?? (target?.kind == .audio ? String(localized: "Plays the element's own sound") : String(localized: "Choose a sound element as the target")))
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func number(_ title: LocalizedStringKey, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(maxWidth: 100)
        }
    }
}

// MARK: Anchors (PRD L1–L7)

struct AnchorsPanel: View {
    let model: AuthorModel
    @State private var markerWidth = 0.18

    var body: some View {
        if let e = model.selectedElement {
            Form {
                Section {
                    PrecisionBadge(precision: e.precision, showsExplanation: true)
                } header: { Text("How players will find it") }

                Section("Anchors") {
                    if e.anchors.isEmpty {
                        Text("Save to anchor this element to the scan of this space.").foregroundStyle(.secondary)
                    }
                    ForEach(e.anchorsInResolutionOrder) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(tierTitle(a.tier), systemImage: tierSymbol(a.tier))
                            Text(detail(a)).font(.caption).foregroundStyle(.secondary)
                            if a.tier == .image, a.transform == nil {
                                Text("Not linked yet: point the camera at the printed marker while the element is in place.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if a.tier == .gps {
                                Toggle("Show on nearest surface if nothing better is found", isOn: Binding(
                                    get: { a.allowPlaneFallback ?? false },
                                    set: { v in model.editElement(e.id, String(localized: "GPS fallback")) { el in
                                        if let i = el.anchors.firstIndex(where: { $0.id == a.id }) { el.anchors[i].allowPlaneFallback = v } } }))
                                .font(.caption)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                model.editElement(e.id, String(localized: "Remove anchor")) { $0.anchors.removeAll { $0.id == a.id } }
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }

                Section {
                    Button { Task { await model.pinSelectedToLocation() } } label: {
                        Label("Pin to this location", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(model.pin != .idle)
                    Picker("Printed marker size", selection: $markerWidth) {
                        Text("A6 (10 cm)").tag(0.10)
                        Text("A5 (14 cm)").tag(0.14)
                        Text("A4 (18 cm)").tag(0.18)
                    }
                    Button { model.addMarkerToSelected(widthM: markerWidth) } label: {
                        Label("Add a printed marker", systemImage: "qrcode")
                    }
                } footer: {
                    Text("Markers are the most reliable anchor, especially for hunts with children. Location pins help players find the spot outdoors.")
                }

                Section {
                    LabeledContent("Scan", value: model.scanQuality)
                    Text("To strengthen the scan, walk slowly around the spot for 20–30 seconds, looking at textured surfaces from different angles. Then save.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Scan of this space") }
            }
            .navigationTitle("Anchors")
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "hand.tap", description: Text("Tap an element to see its anchors."))
        }
    }

    private func tierTitle(_ t: AnchorTier) -> LocalizedStringKey {
        switch t {
        case .geo: "Location anchor"
        case .worldmap: "Scan of this space"
        case .image: "Printed marker"
        case .object: "Object"
        case .gps: "GPS area"
        default: LocalizedStringKey(t.rawValue)
        }
    }

    private func tierSymbol(_ t: AnchorTier) -> String {
        switch t {
        case .geo: "location.north.circle"
        case .worldmap: "viewfinder"
        case .image: "qrcode"
        case .object: "cube"
        default: "location.circle"
        }
    }

    private func detail(_ a: CuardachCore.Anchor) -> String {
        switch a.tier {
        case .worldmap:
            let when = a.capturedAt.flatMap(ISO8601.date(from:))?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            return "\(when) · \(a.mappingStatus ?? "")"
        case .image:
            return String(format: "%.0f cm wide", (a.physicalWidthM ?? 0) * 100)
        case .gps:
            return String(format: "%.5f, %.5f · %.0f m radius", a.lat ?? 0, a.long ?? 0, a.radiusM ?? 15)
        default:
            return a.coordinate.map { String(format: "%.6f, %.6f", $0.lat, $0.long) } ?? a.id
        }
    }
}

// MARK: Import review (PRD A2, A14)

struct ImportReviewPanel: View {
    let model: AuthorModel
    let close: () -> Void
    @State private var name = ""
    /// AR had no surface or frame yet when Place was tapped; the import is kept.
    @State private var notReady = false

    var body: some View {
        if let r = model.pendingImport {
            let blocked = r.warnings.contains { $0.severity == .blocking }
            Form {
                Section {
                    Label(kindName(r.kind), systemImage: r.kind.symbol)
                    LabeledContent("File size", value: ByteSize.format(r.metrics.bytes))
                    if let t = r.metrics.triangles { LabeledContent("Triangles", value: t.formatted()) }
                    if !r.metrics.animationClips.isEmpty { LabeledContent("Animations", value: r.metrics.animationClips.joined(separator: ", ")) }
                    if !blocked { TextField("Name", text: $name) }
                }
                if !r.warnings.isEmpty {
                    Section("Before you place it") {
                        ForEach(r.warnings, id: \.self) { w in
                            Label(w.message, systemImage: w.severity == .info ? "info.circle" : "exclamationmark.triangle")
                                .foregroundStyle(w.severity == .info ? Color.secondary : (w.severity == .blocking ? .red : .orange))
                        }
                    }
                }
                Section {
                    if !blocked {
                        Button("Place at the crosshair") {
                            if model.placePendingImport(name: name.isEmpty ? String(localized: "Untitled") : name) {
                                close()
                            } else {
                                notReady = true
                                AccessibilityNotification.Announcement(AuthorModel.noSurfaceYet).post()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Discard", role: .destructive) {
                        if !r.path.isEmpty, let u = try? model.bundle.url(for: r.path) { try? FileManager.default.removeItem(at: u) }
                        model.pendingImport = nil
                        close()
                    }
                } footer: {
                    if notReady { Text(AuthorModel.noSurfaceYet) }
                }
            }
            .navigationTitle("Import")
            // Swiping the sheet away would strand pendingImport and block later
            // imports; Place or Discard are the ways out.
            .interactiveDismissDisabled()
            .onAppear { name = (r.path as NSString).lastPathComponent.components(separatedBy: ".").first?.replacingOccurrences(of: "-", with: " ").capitalized ?? "" }
        }
    }

    private func kindName(_ k: ElementKind) -> LocalizedStringKey {
        switch k {
        case .model: "3D model"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Sound"
        default: "File"
        }
    }
}

// MARK: Experience details

struct ExperiencePanel: View {
    let model: AuthorModel

    private func text(_ kp: WritableKeyPath<Experience, String>, _ label: String) -> Binding<String> {
        Binding(get: { model.experience[keyPath: kp] }, set: { v in model.edit(label, coalesce: true) { $0[keyPath: kp] = v } })
    }

    private func label(_ kp: WritableKeyPath<WallLabel, String?>) -> Binding<String> {
        Binding(get: { model.experience.label?[keyPath: kp] ?? "" },
                set: { v in model.edit(String(localized: "Statement"), coalesce: true) { x in
                    var l = x.label ?? WallLabel(); l[keyPath: kp] = v.isEmpty ? nil : v; x.label = l } })
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: text(\.title, String(localized: "Title")))
                TextField("Author", text: text(\.author, String(localized: "Author")))
                TextField("Year", text: label(\.year))
                TextField("Medium", text: label(\.medium), axis: .vertical)
            }
            Section {
                TextField("Statement", text: label(\.statement), axis: .vertical).lineLimit(4...12)
            } header: { Text("Statement") } footer: {
                Text("What the work is about, in your words. It appears in the catalogue and when players open the experience.")
            }
            Section {
                TextField("Description for VoiceOver", text: label(\.altText), axis: .vertical)
            } header: { Text("Accessibility") }
            Section {
                TextField("Message", text: Binding(get: { model.experience.completionMessage ?? "" },
                                                   set: { v in model.edit(String(localized: "Completion message"), coalesce: true) { $0.completionMessage = v.isEmpty ? nil : v } }),
                          axis: .vertical)
            } header: { Text("When a player has found everything") }
        }
        .navigationTitle("About this experience")
    }
}
#endif
