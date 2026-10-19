# Architecture

Cuardach follows the PRD's three-layer plan. Everything that can be tested without a camera lives in a Foundation-only package; the Apple-framework layers are thin and replaceable.

```
App (iOS target, XcodeGen)      CuardachApp.swift · Info.plist · privacy manifest · strings · icon
        │
CuardachUI (SwiftUI)            Library · Author mode · Player mode · panels · briefs
        │
CuardachAR (ARKit, RealityKit)  ARSceneController · EntityFactory · SceneRuntime · WorldMapStore
        │                       ImportPipeline · MarkerRenderer · LocationService · WalkingMonitor
        │                       DocumentationCapture
CuardachCore (Foundation only)  Model · Bundle (zip, validator) · BehaviourEngine · AnchorResolver
                                Geo · Assets (GLB inspector) · Player progress · DeepLink · Studio
cuardach (CLI)                  uses CuardachCore only
```

## Key decisions

**Pure, time-injected engines.** `BehaviourEngine` and `AnchorResolver` are value types that take time, taps, distances and anchor events as input and return events. They never touch ARKit. The same engine runs in player mode, in author mode's "Preview as player" and "Simulate", and in the tests.

**One container entity per element.** `EntityFactory` wraps each element's content in a `ModelEntity` carrying collision, an `ElementTag`, opacity and an optional billboard. Gestures, hit tests and fades work the same for models, images, video, sound and text, and swapping a variant replaces only the child.

**`ARView`, not `RealityView`.** Author and player modes need the `ARSession` directly, for world-map capture, initial world maps, geotracking, detection images and `getGeoLocation(forPoint:)`. All of this is contained in `CuardachAR`, so moving to `RealityView` later is a local change.

**Geo and world-map sessions are exclusive.** ARKit runs either `ARGeoTrackingConfiguration` or `ARWorldTrackingConfiguration` with an initial world map, not both. `AnchorResolver.preferredMode(player:)` chooses geotracking when the nearest unresolved element has a usable geo anchor, and otherwise the world map closest to the player. Image markers work in both. Author mode's "Pin to location" saves, switches to a geo session, takes the pin, and returns to the saved map.

**Transforms.** In memory, an element's `transform` is its container's transform relative to its anchor entity. On save, every placed element gets a world-map anchor at its current position and rotation, and `transform` is reduced to scale. Image anchors store the element's pose relative to the marker in the anchor's own `transform`, captured the first time the camera sees the printed marker with the element in place.

**Zip without dependencies.** `ZipWriter` streams stored entries; `ZipReader` memory-maps the archive and reads stored and deflated entries (pure-Swift inflate, with Apple's Compression framework used where available). Unpacking rejects absolute and `..` paths (zip slip), caps total size and file count (zip bombs), verifies CRCs, skips `__MACOSX`/`.DS_Store`, and accepts archives wrapped in one top-level folder, as Finder produces.

**Forward compatibility (PRD S6).** Every manifest type keeps unknown keys in `extra` and writes them back. Enumerations (`kind`, `tier`, `trigger`, `action.type`) are open: unknown values survive a round trip, the engine skips them, and the validator explains what will not play. A manifest with a newer `schemaVersion` opens read-only.

**Concurrency.** CuardachCore is strict Swift 6. The ARKit/SwiftUI targets are `@MainActor`, compiled in Swift 5 mode with complete concurrency checking reported as warnings, because ARKit's delegate API is not fully `Sendable`-annotated. Switch them to `.v6` once the first device build is clean.

## Diagnostics

The AR and UI layers write to Apple's unified log (`Log` in `CuardachAR/Diagnostics.swift`), subsystem `ie.ncad.cuardach`, with categories `import`, `ar-session`, `anchors`, `behaviours`, `library` and `capture`. They record state changes and failures, not frames: import measurements and warnings, tracking state and reason, world mapping and geotracking state, relocalisation, markers detected, tracked and lost, the resolver's session choice and events, world-map loads and saves, entity build failures, routing of files sent to the app, and capture errors.

To read it, filter the Xcode console by `subsystem:ie.ncad.cuardach` while running from Xcode, or open Console.app with the iPhone connected and search for the subsystem (turn on Action > Include Info Messages; debug lines appear only with Include Debug Messages). After the fact, a sysdiagnose from the device holds the log archive.

The log stays on the device; the app collects and sends nothing. Coordinates and file contents are never logged. Element and anchor ids and world-map file names are logged; file names and error texts that can contain them are marked `.private`, so they show in full only while the app runs attached to Xcode's debugger and appear as `<private>` elsewhere.

## Testing

`swift test` runs 70 XCTest cases on macOS or Linux:

- **Model:** the PRD's example manifest decodes; unknown keys and enum values round-trip byte-stably; Euler/quaternion conversion; time windows.
- **Bundles:** pack/unpack round trip; deflated, Finder-wrapped zips made by Python's `zipfile`; zip slip; size limits; corruption detection; CRC-32; manifest error messages; read-only newer schemas.
- **Behaviour engine:** every trigger, all three re-trigger modes, sequential and parallel steps, delays within one frame, cancellation, hidden elements, unlocks, variants, saved state, simulate.
- **Anchor resolver:** priority walk and silent upgrade, fallback when an anchor is lost, map choice, map switching, the 30-second relocalisation hint, GPS plane fallback, session-mode choice.
- **Geo, assets, validator, Studio:** distances and bearings; GLB inspection; import warnings; validation codes; catalogue HTML escaping; licence restrictions; marker patterns; briefs.
- **Sample:** `Samples/courtyard-hunt.arhunt` validates, and its marker PNGs (drawn by the Python port of `MarkerPattern`) decode to exactly the Swift pattern.

The iOS layers can only be compiled with the iOS SDK. On Linux their sources are syntax-checked: inactive `#if` blocks are still parsed.

## PRD traceability

✅ done · 🟡 partial · ⏳ later (per PRD) · ❌ not yet

| ID | Status | Where / notes |
| --- | --- | --- |
| A1 | ✅ | Files and Photos pickers (`AuthorView`). USDZ, Reality, GLB/glTF, images, video and sound sent by AirDrop or "Open in…" (document types in `Info.plist`) ask which experience to add to, then run the same import review in author mode (`RootView.openMedia`). |
| A2 | 🟡 | `GLBInspector` warnings, GLTFKit2 loader injected by the app, review sheet. No rendered 3D preview in the sheet yet; the model appears when placed. |
| A3, A5 | ⏳ | Blocked at import with a "convert on a Mac" message. |
| A4 | ✅ | Images, video (HEVC alpha via `VideoMaterial`), audio. Chroma key is ⏳. |
| A6 | ✅ | Place at the crosshair; drag, rotate, pinch; drop onto surface; height via the inspector. |
| A7 | ✅ | Numeric position, rotation (yaw/pitch/roll), scale, face viewer. |
| A8, A9 | ✅ | Clip, loop, speed; video loop and mute. Chroma ⏳. |
| A10 | ✅ | Full Aero set plus dwell and time-window triggers and variant actions; Simulate. |
| A11 | ⏳ | |
| A12 | ✅ | Elements panel: rename, duplicate, delete, start hidden. |
| A13 | 🟡 | Save, debounced autosave, save on background. Version history ⏳. |
| A14 | ✅ | Downscale > 2048 px, warn > 100k triangles, sizes shown. |
| A15 | ✅ | `UndoStack` snapshots, coalesced drags. |
| A16 | ✅ | Preview as player. |
| L1–L4, L6–L9, L11 | ✅ | `AuthorModel` anchors, `AnchorsPanel`, `MarkerRenderer`, `Experience.refreshSiteHint`. |
| L5, L10 | ⏳ | |
| P1–P10, P12 | ✅ | `PlayerModel`, `PlayerView`, `LibraryView` (QR via VisionKit). Object anchors ⏳. |
| P11 | 🟡 | Large targets, VoiceOver labels and announcements, Reduce Motion. Needs an audit on device. |
| S1–S6 | ✅ | `ExportPanel`, `DeepLink`, Info.plist. S2's "downscale on export" happens at import instead. |
| S7–S9 | ⏳ | |
| C1–C6, C8, C10 | ✅ | No network except user downloads; EXIF/location stripped at import; privacy manifest; walking banner; data-protection note. Road warnings (C8) are ⏳. |
| C7 | ✅ | Documentation and App Store copy guidance in `docs/data-protection.md`. |
| C9 | ❌ | The "report to NCAD" link on the NCAD build needs a build flag. |

## Known gaps

- **First device build.** The AR and UI layers have not been compiled against the iOS 26 SDK. They have been through an independent API review, which caught and fixed a module-shadowing name clash, type ambiguities with SwiftUI and RealityKit, access control, actor isolation in initialisers, and several runtime issues. Still worth watching: `AudioFileResource.load` (deprecated in favour of async initialisers), `faceCulling` on materials, and strict-concurrency warnings.
- **Field testing (PRD M0).** Relocalisation rates, geo availability at NCAD and the GPS fallback timing (30 s) are design values until the spike measures them.
- **World maps in the sample.** `Samples/courtyard-hunt.arhunt` has markers and GPS but no scans, which can only be captured on a device. Its 3D assets are placeholder geometry.
