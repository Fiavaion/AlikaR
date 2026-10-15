import XCTest
@testable import CuardachCore

final class ValidatorTests: XCTestCase {
    func codes(_ x: Experience, files: [String: Int] = [:], total: Int? = nil) -> Set<String> {
        Set(BundleValidator(fileSize: { files[$0] }, totalBytes: total).validate(x).map(\.code))
    }

    func testCleanExperienceHasNoErrors() throws {
        var x = Experience(id: "x", title: "Clean", author: "A")
        var e = Element(id: "e", name: "Heron", kind: .model, asset: "assets/h.usdz")
        e.anchors = [.image(id: "i", imageFile: "markers/e.png", physicalWidthM: 0.2)]
        e.label = WallLabel(altText: "A blue heron, wings folded")
        e.credit = Credit(creator: "Me", source: "Own work", licence: "Own-work")
        e.behaviours = [Behaviour(trigger: .tap, actions: [[.playAnimation("fly")]])]
        x.elements = [e]
        let issues = BundleValidator(fileSize: { ["assets/h.usdz": 10, "markers/e.png": 10][$0] }).validate(x)
        XCTAssertEqual(issues, [])
    }

    func testFindsProblems() {
        var x = Experience(id: "x", title: " ", author: "A")
        var a = Element(id: "dup", name: "A", kind: .model, asset: "assets/missing.usdz")
        a.anchors = [Anchor(id: "w", tier: .worldmap)]
        a.anchors[0].mappingStatus = "limited"
        var bad = Action(.setVariant); bad.variant = "nope"
        a.behaviours = [Behaviour(trigger: .tap, actions: [[Action(.moveTo), .playAudio(), bad, .setState("x", target: "ghost")]])]
        var w = Behaviour(trigger: .timeWindow, actions: [[.show()]]); w.window = TimeWindow(from: "late", to: "never")
        a.behaviours.append(w)
        var b = Element(id: "dup", name: "B", kind: .image, asset: "../escape.png")
        b.anchors = [.gps(id: "w", coordinate: Coordinate(lat: 53, long: -6), radiusM: 0, allowPlaneFallback: false)]
        b.credit = Credit(licence: "CC-BY-NC-ND-4.0")
        let c = Element(id: "c", name: "C", kind: .text, asset: nil)
        x.elements = [a, b, c]
        x.annotations = [CritNote(author: "L", kind: .issue, text: "?", elementId: "gone")]

        let found = codes(x, files: ["maps/x": 1], total: 80_000_000)
        for expected in [
            "title.empty", "element.duplicateId", "asset.missing", "path.unsafe", "anchor.worldmap.noMap",
            "anchor.worldmap.noTransform", "anchor.worldmap.limited", "anchor.duplicateId", "anchor.gps.noRadius",
            "anchor.gpsOnly", "action.moveTo.noPosition", "action.playAudio.noAsset", "action.setVariant.unknown",
            "action.badTarget", "behaviour.badWindow", "text.empty", "anchor.none", "access.altText",
            "credit.missing", "credit.restricted", "crit.orphan", "crit.open", "bundle.large", "anchor.noMarker",
        ] {
            XCTAssertTrue(found.contains(expected), "expected \(expected) in \(found.sorted())")
        }
    }

    func testIssuesAreSortedBySeverity() {
        var x = Experience(id: "x", title: "", author: "")
        x.elements = [Element(id: "e", name: "e", kind: .model, asset: nil)]
        let issues = BundleValidator(fileSize: { _ in nil }).validate(x)
        XCTAssertEqual(issues.map(\.severity), issues.map(\.severity).sorted())
    }
}

final class StudioTests: XCTestCase {
    func sample() -> Experience {
        var x = Experience(id: "x", title: "Night <Garden>", author: "Áine & Co")
        x.label = WallLabel(artist: "Áine Ní Bhriain", year: "2026", medium: "AR, sound",
                            statement: "First <b>para</b>.\n\nSecond \"para\".", altText: nil)
        x.siteHint = SiteHint(lat: 53.3436, long: -6.2806, radiusM: 120)
        var e = Element(id: "lamp", name: "Lamp", kind: .model, asset: "assets/lamp.usdz")
        e.anchors = [.image(id: "m", imageFile: "markers/m.png", physicalWidthM: 0.2)]
        e.credit = Credit(creator: "<script>alert(1)</script>", source: "Sketchfab", licence: "CC-BY-NC-4.0", url: "javascript:alert(1)")
        e.variants = [Variant(id: "brass", name: "Brass", asset: "a", note: "Warmer at night"), Variant(id: "steel", name: "Steel", asset: "b")]
        e.designSize = DesignSize(widthM: 0.3, heightM: 1.2, depthM: 0.3)
        var dwell = Behaviour(trigger: .dwell, retrigger: .never, actions: [[.show(target: "lamp")], [Action(.cycleVariant)]])
        dwell.dwellS = 10
        e.behaviours = [dwell, Behaviour(trigger: .tap, actions: [[.playAnimation("glow"), .playAudio()], [.setState("found")]])]
        x.elements = [e]
        x.annotations = [CritNote(author: "Lecturer", kind: .question, text: "Why <brass>?", elementId: "lamp")]
        return x
    }

    func testCatalogueEscapesEverything() {
        let html = Catalogue(experience: sample(), options: .init(includeCritNotes: true)).html()
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<b>para"))
        XCTAssertFalse(html.contains("javascript:"), "non-web URLs are not linked")
        XCTAssertTrue(html.contains("Night &lt;Garden&gt;"))
        XCTAssertTrue(html.contains("Second &quot;para&quot;."))
        XCTAssertTrue(html.contains("Non-commercial only"))
        XCTAssertTrue(html.contains("300 × 1200 × 300 mm"))
        XCTAssertTrue(html.contains("Crit record"))
        XCTAssertTrue(html.contains("Why &lt;brass&gt;?"))
        XCTAssertTrue(html.contains("Marker-precise"))
        XCTAssertFalse(Catalogue(experience: sample()).html().contains("Crit record"), "crit is opt-in")
    }

    func testCatalogueEmbedsCover() {
        var x = sample()
        x.cover = "cover.png"
        let html = Catalogue(experience: x, readFile: { $0 == "cover.png" ? Data([1, 2, 3]) : nil }).html()
        XCTAssertTrue(html.contains("data:image/png;base64,AQID"))
    }

    func testBehaviourDescriptions() {
        let x = sample()
        let e = x.elements[0]
        XCTAssertEqual(BehaviourDescriber.describe(e.behaviours[0], on: e, in: x),
                       "After being looked at for 10 seconds: appear, then show the next variant. Once only.")
        XCTAssertEqual(BehaviourDescriber.describe(e.behaviours[1], on: e, in: x),
                       "When tapped: play “glow” and play a sound, then mark found.")
    }

    func testDesignSize() {
        let s = DesignSize(widthM: 0.45, heightM: 0.9, depthM: 0.5)
        XCTAssertEqual(s.uniformScale(forNativeSize: Vec3(45, 90, 50)) ?? 0, 0.01, accuracy: 1e-12, "a model exported in centimetres")
        XCTAssertNil(s.uniformScale(forNativeSize: .zero))
        XCTAssertEqual(s.formattedMillimetres, "450 × 900 × 500 mm")
    }

    func testCreditRestrictions() {
        XCTAssertEqual(Credit(licence: "CC-BY-NC-ND-4.0").restrictions, ["Non-commercial only", "No derivatives"])
        XCTAssertEqual(Credit(licence: "CC0-1.0").restrictions, [])
        XCTAssertFalse(Credit(licence: "CC0-1.0").requiresAttribution)
        XCTAssertTrue(Credit(licence: "CC-BY-4.0").requiresAttribution)
        XCTAssertEqual(Credit().restrictions, ["Licence unknown"])
    }

    func testMarkerPatternIsDeterministicAndHealthy() {
        let a = MarkerPattern(seed: "heron")
        XCTAssertEqual(a, MarkerPattern(seed: "heron"))
        XCTAssertNotEqual(a, MarkerPattern(seed: "heron2"))
        XCTAssertTrue(a[0, 0] && a[11, 11] && a[0, 5])
        XCTAssertFalse(a[1, 1], "orientation notch")
        for seed in (0..<50).map({ "element-\($0)" }) {
            XCTAssertTrue((0.3...0.7).contains(MarkerPattern(seed: seed).interiorDensity), seed)
        }
    }

    func testBriefsAreComplete() {
        XCTAssertGreaterThanOrEqual(StudioBrief.all.count, 8)
        XCTAssertEqual(Set(StudioBrief.all.map(\.id)).count, StudioBrief.all.count)
        for d in StudioBrief.Discipline.allCases {
            XCTAssertTrue(StudioBrief.all.contains { $0.disciplines.contains(d) }, d.rawValue)
        }
        for b in StudioBrief.all {
            XCTAssertFalse(b.uses.isEmpty || b.reflect.isEmpty || b.lookAt.isEmpty, b.id)
        }
        XCTAssertTrue(StudioBrief.markdown().contains("## Slow looking"))
    }
}
