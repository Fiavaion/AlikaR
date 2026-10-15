#if canImport(ARKit) && canImport(RealityKit) && os(iOS)
import ARKit
import Combine
import CuardachCore
import Observation
import RealityKit
import UIKit

/// Owns the ARView and its ARSession for both modes. All ARKit and
/// RealityKit calls live in this module so API changes between iOS
/// releases stay local (PRD risk: RealityKit API churn).
///
/// `ARView` is used rather than `RealityView` because author and player
/// modes need the `ARSession` directly: world map capture, initial world
/// maps, geotracking and detection images (PRD L1–L4, P5).
@MainActor
@Observable
public final class ARSceneController: NSObject {
    public enum Mode: Equatable { case idle, authoring, world, geo }

    public let arView: ARView
    public private(set) var mode: Mode = .idle
    public private(set) var isTrackingNormal = false
    public private(set) var trackingHint: String?
    public private(set) var isRelocalising = false
    public private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    public private(set) var geoLocalised = false
    public private(set) var hasDetectedPlane = false
    public let hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    /// A session anchor appeared or updated: image, geo, or a named anchor restored from a world map.
    @ObservationIgnored public var onAnchor: ((ARAnchor) -> Void)?
    /// The session finished relocalising against the world map it was given.
    @ObservationIgnored public var onRelocalised: (() -> Void)?
    /// Called once per rendered frame with seconds since the last frame.
    @ObservationIgnored public var onUpdate: ((TimeInterval) -> Void)?

    /// Prefix for ARAnchors this app adds to world maps; the rest is the manifest anchor id.
    public static let anchorPrefix = "cuardach:"

    @ObservationIgnored private var placed: [String: AnchorEntity] = [:]
    @ObservationIgnored private var updateSubscription: Cancellable?
    @ObservationIgnored private var expectingRelocalisation = false

    public override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        // NSObject's init is nonisolated; this class is only ever made on the main actor.
        MainActor.assumeIsolated {
            EntityFactory.registerComponents()
            arView.session.delegate = self
            arView.renderOptions.insert(.disableMotionBlur)
            updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.onUpdate?(event.deltaTime)
            }
        }
    }

    // MARK: Sessions

    private func worldConfiguration() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal, .vertical]
        c.environmentTexturing = .automatic
        if hasLiDAR {
            c.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            c.frameSemantics.insert(.personSegmentationWithDepth)
        }
        return c
    }

    /// Author mode: world tracking so a world map can be captured (PRD L1).
    public func runAuthoring(initialMap: ARWorldMap? = nil, images: Set<ARReferenceImage> = []) {
        let c = worldConfiguration()
        c.initialWorldMap = initialMap
        c.detectionImages = images
        c.maximumNumberOfTrackedImages = min(4, images.count)
        run(c, mode: .authoring, relocalising: initialMap != nil)
    }

    /// Player mode with a saved world map and/or markers.
    public func runWorld(map: ARWorldMap?, images: Set<ARReferenceImage>) {
        let c = worldConfiguration()
        c.initialWorldMap = map
        c.detectionImages = images
        c.maximumNumberOfTrackedImages = min(4, images.count)
        run(c, mode: .world, relocalising: map != nil)
    }

    /// Player mode with Apple Location Anchors (PRD P5 tier 1).
    public func runGeo(images: Set<ARReferenceImage>) {
        let c = ARGeoTrackingConfiguration()
        c.planeDetection = [.horizontal, .vertical]
        c.environmentTexturing = .automatic
        c.detectionImages = images
        c.maximumNumberOfTrackedImages = min(4, images.count)
        run(c, mode: .geo, relocalising: false)
    }

    private func run(_ c: ARConfiguration, mode: Mode, relocalising: Bool) {
        removeAllElements()
        expectingRelocalisation = relocalising
        isRelocalising = relocalising
        geoLocalised = false
        hasDetectedPlane = false
        self.mode = mode
        arView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Adds or changes marker images without resetting tracking, so placed
    /// content stays where it is.
    public func updateDetectionImages(_ images: Set<ARReferenceImage>) {
        guard let current = arView.session.configuration else { return }
        if let c = current as? ARWorldTrackingConfiguration {
            c.detectionImages = images
            c.maximumNumberOfTrackedImages = min(4, images.count)
            arView.session.run(c, options: [])
        } else if let c = current as? ARGeoTrackingConfiguration {
            c.detectionImages = images
            c.maximumNumberOfTrackedImages = min(4, images.count)
            arView.session.run(c, options: [])
        }
    }

    public func pause() {
        arView.session.pause()
        mode = .idle
    }

    public static var geoTrackingSupported: Bool { ARGeoTrackingConfiguration.isSupported }

    public static func geoAvailable(at c: Coordinate) async -> Bool {
        guard ARGeoTrackingConfiguration.isSupported else { return false }
        // No async overload in the SDK; wrap the completion handler.
        return await withCheckedContinuation { cont in
            ARGeoTrackingConfiguration.checkAvailability(
                at: CLLocationCoordinate2D(latitude: c.lat, longitude: c.long)
            ) { available, _ in cont.resume(returning: available) }
        }
    }

    // MARK: Placement

    /// The world transform of the surface under a screen point (PRD A6).
    public func surfaceTransform(at point: CGPoint) -> simd_float4x4? {
        arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first?.worldTransform
    }

    /// The surface under the centre of the screen: where new elements land.
    public func surfaceAtCentre() -> simd_float4x4? {
        surfaceTransform(at: CGPoint(x: arView.bounds.midX, y: arView.bounds.midY))
    }

    public var cameraTransform: simd_float4x4? { arView.session.currentFrame?.camera.transform }

    /// Places an element's container under a world-space anchor.
    public func place(_ container: ModelEntity, elementId: String, world: simd_float4x4, local: CuardachCore.Transform) {
        remove(elementId: elementId)
        let anchor = AnchorEntity(world: world)
        container.transform = RealityKit.Transform(local)
        anchor.addChild(container)
        arView.scene.addAnchor(anchor)
        placed[elementId] = anchor
    }

    /// Places an element relative to a detected ARAnchor (image, geo, or one
    /// restored from a world map), applying the manifest's local transform.
    public func place(_ container: ModelEntity, elementId: String, on arAnchor: ARAnchor, local: CuardachCore.Transform) {
        remove(elementId: elementId)
        let anchor = AnchorEntity(anchor: arAnchor)
        container.transform = RealityKit.Transform(local)
        anchor.addChild(container)
        arView.scene.addAnchor(anchor)
        placed[elementId] = anchor
    }

    public func remove(elementId: String) {
        if let a = placed.removeValue(forKey: elementId) { arView.scene.removeAnchor(a) }
    }

    public func removeAllElements() {
        for a in placed.values { arView.scene.removeAnchor(a) }
        placed.removeAll()
    }

    public func isPlaced(_ elementId: String) -> Bool { placed[elementId] != nil }

    /// World transform of the anchor an element hangs from.
    public func anchorWorld(of elementId: String) -> simd_float4x4? {
        placed[elementId]?.transformMatrix(relativeTo: nil)
    }

    /// The element's container's world transform, for saving.
    public func worldTransform(of elementId: String) -> simd_float4x4? {
        placed[elementId]?.children.first?.transformMatrix(relativeTo: nil)
    }

    /// Element under a screen point, walking up from the hit entity to its tagged container.
    public func elementId(at point: CGPoint) -> String? {
        var e = arView.entity(at: point)
        while let cur = e {
            if let tag = cur.components[ElementTag.self] { return tag.elementId }
            e = cur.parent
        }
        return nil
    }

    // MARK: World maps

    /// Adds named anchors at the given world transforms and captures the
    /// world map containing them (PRD L1). The anchors travel in the map;
    /// on relocalisation ARKit restores them by name.
    public func captureWorldMap(anchors: [(id: String, world: simd_float4x4)]) async throws -> ARWorldMap {
        let session = arView.session
        for existing in session.currentFrame?.anchors ?? [] where existing.name?.hasPrefix(Self.anchorPrefix) == true {
            session.remove(anchor: existing)
        }
        for a in anchors {
            session.add(anchor: ARAnchor(name: Self.anchorPrefix + a.id, transform: a.world))
        }
        return try await session.currentWorldMap()
    }

    // MARK: Geo

    /// Converts a world position to latitude/longitude/altitude. Requires a
    /// localised geotracking session.
    public func geoLocation(of world: SIMD3<Float>) async throws -> (Coordinate, Double) {
        let (c, alt) = try await arView.session.geoLocation(forPoint: world)
        return (Coordinate(lat: c.latitude, long: c.longitude), alt)
    }

    /// Adds an ARGeoAnchor named after the manifest anchor id.
    public func addGeoAnchor(id: String, coordinate: Coordinate, altitude: Double?) {
        let c = CLLocationCoordinate2D(latitude: coordinate.lat, longitude: coordinate.long)
        let a = altitude.map { ARGeoAnchor(name: Self.anchorPrefix + id, coordinate: c, altitude: $0) }
            ?? ARGeoAnchor(name: Self.anchorPrefix + id, coordinate: c)
        arView.session.add(anchor: a)
    }

    // MARK: Observations (PRD P7)

    /// Distance and in-view state for each placed element.
    public func observations() -> [ElementObservation] {
        guard let cam = cameraTransform else { return [] }
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let bounds = arView.bounds
        let central = bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
        return placed.compactMap { id, anchor in
            guard let container = anchor.children.first, container.isEnabled else { return nil }
            let p = container.position(relativeTo: nil)
            let d = Double(simd_distance(p, camPos))
            var inView = false
            if let screen = arView.project(p) {
                // Behind the camera, project() can still return a point; check direction too.
                let forward = -SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
                inView = central.contains(screen) && simd_dot(simd_normalize(p - camPos), forward) > 0
            }
            return ElementObservation(elementId: id, distanceM: d, inView: inView)
        }
    }
}

extension ARSceneController: ARSessionDelegate {
    nonisolated public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            for a in anchors {
                if a is ARPlaneAnchor { hasDetectedPlane = true }
                onAnchor?(a)
            }
        }
    }

    nonisolated public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            // Image anchors report tracking on update; geo anchors become usable once tracked.
            for a in anchors where a is ARImageAnchor || a is ARGeoAnchor { onAnchor?(a) }
        }
    }

    nonisolated public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = camera.trackingState
        MainActor.assumeIsolated {
            switch state {
            case .normal:
                isTrackingNormal = true
                trackingHint = nil
                if expectingRelocalisation {
                    expectingRelocalisation = false
                    isRelocalising = false
                    onRelocalised?()
                }
            case .limited(let reason):
                isTrackingNormal = false
                switch reason {
                case .relocalizing: trackingHint = "Matching this place… move slowly and look at what you scanned."
                case .excessiveMotion: trackingHint = "Move a little more slowly."
                case .insufficientFeatures: trackingHint = "Point at something with more detail or light."
                case .initializing: trackingHint = "Starting up… move the device gently."
                @unknown default: trackingHint = nil
                }
            case .notAvailable:
                isTrackingNormal = false
                trackingHint = "AR isn't available right now."
            }
        }
    }

    nonisolated public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let status = frame.worldMappingStatus
        let geo = frame.geoTrackingStatus?.state
        MainActor.assumeIsolated {
            if mappingStatus != status { mappingStatus = status }
            let localised = geo == .localized
            if geoLocalised != localised { geoLocalised = localised }
        }
    }

    nonisolated public func session(_ session: ARSession, didFailWithError error: Error) {
        let message = (error as? ARError)?.localizedDescription ?? error.localizedDescription
        MainActor.assumeIsolated { trackingHint = message }
    }
}

extension RealityKit.Transform {
    /// Manifest transform → RealityKit.
    public init(_ t: CuardachCore.Transform) {
        self.init(scale: SIMD3<Float>(Float(t.scale.x), Float(t.scale.y), Float(t.scale.z)),
                  rotation: simd_quatf(ix: Float(t.rotation.x), iy: Float(t.rotation.y), iz: Float(t.rotation.z), r: Float(t.rotation.w)),
                  translation: SIMD3<Float>(Float(t.position.x), Float(t.position.y), Float(t.position.z)))
    }
}

extension CuardachCore.Transform {
    /// RealityKit → manifest transform.
    public init(_ t: RealityKit.Transform) {
        self.init(position: Vec3(Double(t.translation.x), Double(t.translation.y), Double(t.translation.z)),
                  rotation: Quat(Double(t.rotation.imag.x), Double(t.rotation.imag.y), Double(t.rotation.imag.z), Double(t.rotation.real)),
                  scale: Vec3(Double(t.scale.x), Double(t.scale.y), Double(t.scale.z)))
    }
}

extension Matrix4 {
    public init(_ m: simd_float4x4) {
        self.init([m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] })
    }

    public var simd: simd_float4x4? {
        guard isValid else { return nil }
        let v = values.map(Float.init)
        return simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                             SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }
}
#endif
