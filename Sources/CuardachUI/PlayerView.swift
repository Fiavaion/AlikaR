#if canImport(SwiftUI) && os(iOS)
import CuardachAR
import CuardachCore
import MapKit
import SwiftUI

/// Player mode screen: camera, approach arrow, found count, map.
public struct PlayerView: View {
    @State private var model: PlayerModel
    @State private var showingMap = false
    @State private var showingList = false
    @State private var showingAbout = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(bundle: ExperienceBundle, store: PlayerProgressStore) {
        _model = State(initialValue: PlayerModel(bundle: bundle, store: store))
    }

    public var body: some View {
        ZStack {
            ARViewContainer(controller: model.ar) { model.tap($0) }
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                if model.walking.isWalking { lookUpBanner }
                if model.ar.isRelocalising || model.hint != nil || model.ar.trackingHint != nil {
                    Toast(text: model.hint ?? model.ar.trackingHint ?? String(localized: "Matching this place…"))
                }
                Spacer()
                guidance
                bottomBar
            }
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            model.reduceMotion = reduceMotion
            await model.start()
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showingMap) { NavigationStack { OverviewMap(model: model) } }
        .sheet(isPresented: $showingList) { NavigationStack { FoundList(model: model) }.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showingAbout) { NavigationStack { AboutExperience(experience: model.experience) } }
        .alert(model.experience.completionMessage ?? String(localized: "You found everything!"),
               isPresented: Binding(get: { model.completed }, set: { model.completed = $0 })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("Close")
            Spacer()
            Button { showingList = true } label: {
                let c = model.foundCount
                Label("\(c.found) of \(c.total) found", systemImage: "checkmark.seal")
                    .font(.headline).padding(.horizontal, 16).frame(height: 48)
            }
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button { showingAbout = true } label: { Image(systemName: "info").font(.title3.weight(.semibold)).frame(width: 48, height: 48) }
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("About this experience")
        }
        .padding(.horizontal)
        .buttonStyle(.plain)
    }

    private var lookUpBanner: some View {
        Label("Look up while you walk", systemImage: "figure.walk")
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.yellow, in: Capsule())
            .foregroundStyle(.black)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var guidance: some View {
        switch model.guidance {
        case .navigate(let d, let bearing) where d.isFinite:
            VStack(spacing: 6) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 56))
                    .rotationEffect(.degrees(bearing))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: bearing)
                Text(ApproachGuidance.format(distanceM: d)).font(.title2.weight(.bold))
                if let n = model.nextElementName { Text(n).font(.callout) }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(model.nextElementName ?? "") \(ApproachGuidance.format(distanceM: d)) away, \(clock(bearing))"))
        case .lookAround:
            Label("It's nearby. Look around.", systemImage: "eye")
                .font(.title3.weight(.semibold))
                .padding(16)
                .background(.ultraThinMaterial, in: Capsule())
        default:
            EmptyView()
        }
    }

    /// "at 2 o'clock", for VoiceOver.
    private func clock(_ bearing: Double) -> String {
        let hour = Int((bearing / 30).rounded()) % 12
        return String(localized: "at \(hour == 0 ? 12 : hour) o'clock")
    }

    private var bottomBar: some View {
        HStack(spacing: 20) {
            if model.experience.elements.contains(where: { $0.coordinate != nil }) {
                OverlayButton(title: "Map", systemImage: "map") { showingMap = true }
            }
            OverlayButton(title: "Found list", systemImage: "list.bullet") { showingList = true }
        }
    }
}

/// Overview map of the site and element positions (PRD P3).
struct OverviewMap: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let x = model.experience
        Map(initialPosition: initialPosition) {
            UserAnnotation()
            if let s = x.siteHint {
                MapCircle(center: CLLocationCoordinate2D(latitude: s.lat, longitude: s.long), radius: s.radiusM)
                    .foregroundStyle(.teal.opacity(0.12))
                    .stroke(.teal, lineWidth: 1)
            }
            ForEach(x.elements.filter { $0.coordinate != nil }) { e in
                let c = e.coordinate!
                let found = model.progress.foundSet.contains(e.id)
                Annotation(found ? e.name : String(localized: "?"), coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.long)) {
                    Image(systemName: found ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(found ? .green : .orange)
                        .background(.white, in: Circle())
                }
            }
        }
        .mapControls { MapUserLocationButton(); MapCompass() }
        .navigationTitle(x.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }

    private var initialPosition: MapCameraPosition {
        guard let s = model.experience.siteHint else { return .userLocation(fallback: .automatic) }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: s.lat, longitude: s.long),
                                          latitudinalMeters: s.radiusM * 2.6, longitudinalMeters: s.radiusM * 2.6))
    }
}

/// Found / not-found list (PRD P9).
struct FoundList: View {
    let model: PlayerModel
    @State private var confirmReset = false

    var body: some View {
        List {
            ForEach(PlayerProgress.collectable(in: model.experience)) { e in
                let found = model.progress.foundSet.contains(e.id)
                HStack {
                    Image(systemName: found ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(found ? .green : .secondary)
                    Text(found ? e.name : String(localized: "Not found yet"))
                    Spacer()
                    if let r = model.resolutions[e.id], r.isPlaced, !found {
                        Text("Nearby").font(.caption).foregroundStyle(.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                Button("Start again", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Found")
        .confirmationDialog("Forget what you've found on this device?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Start again", role: .destructive) { model.resetProgress() }
        }
    }
}

/// The experience's statement and credits, before or during play.
struct AboutExperience: View {
    let experience: Experience
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(experience.label?.title ?? experience.title).font(.title2.weight(.bold))
                if !experience.author.isEmpty { Text(experience.label?.artist ?? experience.author) }
                if let m = experience.label?.medium { Text(m).foregroundStyle(.secondary) }
            }
            if let s = experience.label?.statement, !s.isEmpty {
                Section("Statement") { Text(s) }
            }
            let credited = experience.elements.filter { $0.credit != nil }
            if !credited.isEmpty {
                Section("Credits") {
                    ForEach(credited) { e in
                        VStack(alignment: .leading) {
                            Text(e.name)
                            Text([e.credit?.creator, e.credit?.source, e.credit?.licence].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("About")
        .toolbar { Button("Done") { dismiss() } }
    }
}
#endif
