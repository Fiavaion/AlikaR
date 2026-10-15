import XCTest
@testable import CuardachCore

final class AnchorResolverTests: XCTestCase {
    let site = Coordinate(lat: 53.3436, long: -6.2806)

    func experience() -> Experience {
        var x = Experience(id: "x", title: "T", author: "A")
        var heron = Element(id: "heron", name: "Heron", kind: .model, asset: "a")
        heron.anchors = [
            .worldmap(id: "heron-map", mapFile: "maps/court.arworldmap", transform: .identity, capturedAt: Date(), mappingStatus: "mapped", coordinate: site),
            .image(id: "heron-marker", imageFile: "markers/heron.png", physicalWidthM: 0.21),
            .geo(id: "heron-geo", lat: site.lat, long: site.long, alt: 20, heading: nil),
        ]
        var bell = Element(id: "bell", name: "Bell", kind: .audio, asset: "b")
        let far = Geo.offset(site, eastM: 300, northM: 0)
        bell.anchors = [
            .worldmap(id: "bell-map", mapFile: "maps/garden.arworldmap", transform: .identity, capturedAt: Date(), mappingStatus: "mapped", coordinate: far),
            .gps(id: "bell-gps", coordinate: far, radiusM: 20, allowPlaneFallback: true),
        ]
        var drift = Element(id: "drift", name: "Drift", kind: .image, asset: "c")
        drift.anchors = [.gps(id: "drift-gps", coordinate: Geo.offset(site, eastM: 0, northM: 500), radiusM: 15, allowPlaneFallback: true)]
        x.elements = [heron, bell, drift]
        return x
    }

    func testPlanSkipsUnsupportedTiersAndPicksNearestMap() {
        let r = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: false, objectTracking: false))
        let atCourt = r.plan(player: site)
        XCTAssertTrue(atCourt.geo.isEmpty)
        XCTAssertEqual(atCourt.images.map(\.id), ["heron-marker"])
        XCTAssertEqual(atCourt.worldMap, "maps/court.arworldmap")
        XCTAssertEqual(r.plan(player: Geo.offset(site, eastM: 290, northM: 0)).worldMap, "maps/garden.arworldmap")
        XCTAssertEqual(AnchorResolver(experience: experience(), capabilities: .init(geoTracking: true, objectTracking: false))
            .plan(player: nil).geo.map(\.id), ["heron-geo"])
    }

    func testBetterAnchorTakesOverSilently() {
        var r = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: true, objectTracking: false))
        _ = r.beginRelocalising(mapFile: "maps/court.arworldmap", at: 0)
        let map = r.relocalised(mapFile: "maps/court.arworldmap", at: 5)
        XCTAssertEqual(map, [.place(elementId: "heron", anchorId: "heron-map", tier: .worldmap)])
        XCTAssertEqual(r.resolution(of: "heron").precision, .sitePrecise)
        // geo outranks image outranks worldmap (P5).
        XCTAssertEqual(r.anchorResolved("heron-marker"), [.place(elementId: "heron", anchorId: "heron-marker", tier: .image)])
        XCTAssertEqual(r.anchorResolved("heron-geo"), [.place(elementId: "heron", anchorId: "heron-geo", tier: .geo)])
        // A worse anchor resolving again changes nothing.
        XCTAssertTrue(r.anchorResolved("heron-map").isEmpty)
        // Losing the best anchor falls back to the next one still held.
        XCTAssertEqual(r.invalidate(["heron-geo"]), [.place(elementId: "heron", anchorId: "heron-marker", tier: .image)])
        XCTAssertEqual(r.invalidate(["heron-marker", "heron-map"]), [.unplace(elementId: "heron")])
    }

    func testSlowRelocalisationHintOnce() {
        var r = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: false, objectTracking: false))
        _ = r.beginRelocalising(mapFile: "maps/court.arworldmap", at: 100)
        XCTAssertTrue(r.update(at: 129, player: site).isEmpty)
        XCTAssertEqual(r.update(at: 130, player: site), [.relocalisationSlow(mapFile: "maps/court.arworldmap")])
        XCTAssertTrue(r.update(at: 140, player: site).isEmpty)
    }

    func testSwitchingMapsInvalidatesOldMapAnchors() {
        var r = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: false, objectTracking: false))
        _ = r.beginRelocalising(mapFile: "maps/court.arworldmap", at: 0)
        _ = r.relocalised(mapFile: "maps/court.arworldmap", at: 1)
        let ev = r.beginRelocalising(mapFile: "maps/garden.arworldmap", at: 2)
        XCTAssertEqual(ev, [.unplace(elementId: "heron")])
        XCTAssertEqual(r.relocalised(mapFile: "maps/garden.arworldmap", at: 3), [.place(elementId: "bell", anchorId: "bell-map", tier: .worldmap)])
    }

    func testGpsFallbackWaitsForPreciseAnchorsUnlessGpsOnly() {
        var r = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: false, objectTracking: false))
        let bellSpot = Geo.offset(site, eastM: 300, northM: 5)
        XCTAssertTrue(r.update(at: 0, player: bellSpot).isEmpty, "bell has a scan; give it time")
        XCTAssertTrue(r.update(at: 29, player: bellSpot).isEmpty)
        XCTAssertEqual(r.update(at: 30, player: bellSpot), [.placeOnNearestPlane(elementId: "bell")])
        XCTAssertEqual(r.resolution(of: "bell").precision, .approximate)
        // The scan matching later upgrades it.
        _ = r.beginRelocalising(mapFile: "maps/garden.arworldmap", at: 31)
        XCTAssertEqual(r.relocalised(mapFile: "maps/garden.arworldmap", at: 32), [.place(elementId: "bell", anchorId: "bell-map", tier: .worldmap)])

        let driftSpot = Geo.offset(site, eastM: 0, northM: 495)
        XCTAssertEqual(r.update(at: 40, player: driftSpot), [.placeOnNearestPlane(elementId: "drift")], "GPS-only places at once")
    }

    func testOutsideRadiusResetsFallbackTimer() {
        var r = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: false, objectTracking: false))
        let near = Geo.offset(site, eastM: 300, northM: 0)
        _ = r.update(at: 0, player: near)
        _ = r.update(at: 20, player: site)  // walked away
        XCTAssertTrue(r.update(at: 35, player: near).isEmpty)
        XCTAssertEqual(r.update(at: 65, player: near), [.placeOnNearestPlane(elementId: "bell")])
    }

    func testPreferredSessionMode() {
        let noGeo = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: false, objectTracking: false))
        XCTAssertEqual(noGeo.preferredMode(player: site), .world(mapFile: "maps/court.arworldmap"))
        var geo = AnchorResolver(experience: experience(), capabilities: .init(geoTracking: true, objectTracking: false))
        XCTAssertEqual(geo.preferredMode(player: site), .geo, "the heron is nearest and has a geo anchor")
        let atBell = Geo.offset(site, eastM: 300, northM: 0)
        XCTAssertEqual(geo.preferredMode(player: atBell), .world(mapFile: "maps/garden.arworldmap"))
        _ = geo.anchorResolved("heron-geo")
        XCTAssertEqual(geo.preferredMode(player: site), .world(mapFile: "maps/court.arworldmap"), "heron done; bell is next")
    }

    func testNearestUnfound() {
        let x = experience()
        let n = x.nearestUnfound(from: Geo.offset(site, eastM: 250, northM: 0), found: [])
        XCTAssertEqual(n?.element.id, "bell")
        XCTAssertEqual(x.nearestUnfound(from: Geo.offset(site, eastM: 250, northM: 0), found: ["bell"])?.element.id, "heron")
    }
}
