#if canImport(CoreLocation) && canImport(CoreMotion) && os(iOS)
import CoreLocation
import CoreMotion
import CuardachCore
import Observation

/// Location and heading while an AR view is on screen, and only then
/// (PRD L11, C3). Nothing is logged; coordinates leave this object only
/// when the author saves an anchor.
@MainActor
@Observable
public final class LocationService: NSObject {
    public private(set) var coordinate: Coordinate?
    public private(set) var horizontalAccuracyM: Double?
    public private(set) var heading: Double?
    public private(set) var authorization: CLAuthorizationStatus
    public private(set) var speedMps: Double = 0

    @ObservationIgnored private let manager = CLLocationManager()

    public override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 2
        manager.activityType = .fitness
    }

    public var isDenied: Bool { authorization == .denied || authorization == .restricted }

    public func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    public func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        coordinate = nil
        heading = nil
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { self.authorization = status }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        let c = Coordinate(lat: l.coordinate.latitude, long: l.coordinate.longitude)
        let acc = l.horizontalAccuracy
        let speed = max(0, l.speed)
        MainActor.assumeIsolated {
            self.coordinate = c
            self.horizontalAccuracyM = acc
            self.speedMps = speed
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        MainActor.assumeIsolated { self.heading = h }
    }
}

/// Shows "look up" while the player walks (PRD P12, C8). Uses CoreMotion's
/// activity classifier, debounced by `WalkingDetector`.
@MainActor
@Observable
public final class WalkingMonitor {
    public private(set) var isWalking = false
    @ObservationIgnored private let activity = CMMotionActivityManager()
    @ObservationIgnored private var detector = WalkingDetector()
    @ObservationIgnored private let started = Date()

    public init() {}

    public func start() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activity.startActivityUpdates(to: .main) { [weak self] a in
            guard let self, let a else { return }
            let moving = (a.walking || a.running) && a.confidence != .low
            let t = Date().timeIntervalSince(self.started)
            self.isWalking = self.detector.update(speedMps: moving ? 1.2 : 0, at: t)
        }
    }

    public func stop() {
        activity.stopActivityUpdates()
        isWalking = false
    }
}
#endif
