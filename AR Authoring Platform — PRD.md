# AR Authoring Platform — PRD

Oct 15, 2026 · @Mark Jones

## Overview

A free, open-source iPhone and iPad app that lets a non-programmer place 3D models, video, images and audio into the real world, anchor them to physical places (including GPS positions outdoors), give them simple triggered behaviours, and share the result as a file that anyone with the app can open and explore. It replaces the discontinued Adobe Aero for NCAD's Fine Art Media, Product Design and Communication Design departments, and extends it with location anchoring so that an experience can be a scavenger hunt across a campus, park or town.

Working name: **Cuardach** (Irish, "search"). Companion research: [AR Authoring Platform — Research](https://claude.ai/code/artifact/4ae0077e-ba9d-48f3-b859-e30e0e43f654).

The problem: Aero's shutdown on 3 December 2025 broke every published student experience in a day and left no free mobile-first replacement. Students now either pay for web-AR subscriptions or learn Unity. The college wants a tool it owns, that keeps authored work as files the author controls, and that works on the devices students already carry.

## Goals, non-goals and success metrics

**Goals**

1. A design student with no code can author a working AR scene on an iPad in under 10 minutes on first use.
2. An experience survives the college, the author's account and the vendor: it is a file, it opens offline, it needs no server.
3. Elements can be placed at real-world positions and found again by another device with the best precision the location allows, and the author is told which precision that is.
4. Aero's interactivity vocabulary (start, tap, proximity; animate, show/hide, move, play audio) is available so existing teaching material transfers.
5. Everything is open source under a permissive licence, with the bundle format documented so other tools (AROR, a future desktop editor) can read and write it.

**Non-goals (MVP)**

- A game-logic layer (checklists, clues, scoring). Designed for, not built.
- FBX import, animated camera data, PSD layer import.
- Android or web playback. The bundle format should not preclude a future Android player.
- Cloud accounts, hosted catalogue, multiplayer.
- visionOS. RealityKit code should port, but it is not a target.
- Emitting standalone apps per experience. iOS does not allow it.

**Success metrics**

| Metric | Target | Measured how |
| --- | --- | --- |
| Time to first placed, saved element (new user) | ≤ 10 min | Observed sessions with 5 students |
| Relocalisation success at a Tier 2 site, same day | ≥ 90 % of attempts | Field test, 20 attempts, 3 sites |
| Relocalisation success at a Tier 2 site, 1 week later | ≥ 70 % | Same |
| Bundle round-trip | 100 % of authored experiences open identically on a second device | Automated test on sample bundles |
| Crash-free sessions in TestFlight | ≥ 99 % | Xcode Organizer |
| Third-party SDKs in the binary | 0 (GLTFKit2 excepted, vendored) | Build audit |

## Users and personas

| Persona | Device | What they do | What they need from the app |
| --- | --- | --- | --- |
| Student author (Fine Art Media, Product Design, Communication Design) | iPad Pro or iPhone, Mac for asset prep | Builds an AR piece for a module, a degree show, or a community project | Fast placement, honest previews of imported assets, Aero-like triggers, a file to hand in |
| Lecturer / teacher | iPad | Authors a hunt for a class or outreach event; distributes to 20-30 devices | Reliable relocalisation, printable markers, QR sharing, nothing to administer |
| Child player (supervised, roughly 7-14) | Family or school iPhone/iPad | Walks the environment, finds elements, taps them | Big targets, clear "you're close" cues, no reading-heavy UI, no accounts |
| General player | Any ARKit iPhone | Opens a shared experience at a degree show or public site | Open from QR in seconds, works offline after download |
| Maintainer (Mark) | Mac | Builds, signs, ships via TestFlight and the App Store; integrates with AROR | Small Swift codebase, documented bundle schema, no backend to keep alive |

## Core concepts and data model

An Experience is a list of Elements; each Element has one or more Anchors, a set of Behaviours, and a State slot the game layer can use later. The model is deliberately flat so the JSON manifest stays readable and the game layer can be added without migration.

| Concept | Fields | Notes |
| --- | --- | --- |
| Experience | `id`, `title`, `author`, `created`, `schemaVersion`, `elements[]`, `siteHint` (lat/long centroid + radius), `cover` | One per bundle |
| Element | `id`, `name`, `kind` (model / video / image / audio / splat), `asset` (path in bundle), `transform` (relative to its anchor), `anchors[]`, `behaviours[]`, `state` (`hidden`, `found`, custom), `playback` | `state` is unused by MVP but persisted per device |
| Anchor | `id`, `tier` (geo / worldmap / image / object / gps), `priority`, plus tier payload | An element keeps every anchor the author captured; player resolves in priority order |
| Anchor.geo | `lat`, `long`, `alt`, `heading` | ARGeoAnchor; only present if `checkAvailability` passed at authoring |
| Anchor.worldmap | `mapFile`, `anchorTransform`, `capturedAt`, `lat`, `long` | ARWorldMap blob + the element's transform inside it; GPS only to prompt relocalisation |
| Anchor.image | `imageFile`, `physicalWidthM`, `transform` | Printable marker; app can generate one from the element's name and a QR |
| Anchor.object | `referenceObjectFile`, `transform` | iOS 27 reference object; post-MVP |
| Anchor.gps | `lat`, `long`, `radiusM` | Approach-only; content placed on nearest plane when inside radius |
| Behaviour | `trigger` (start / tap / proximityEnter / proximityExit), `retrigger` (immediately / afterComplete / never), `actions[]` (sequential groups of parallel actions) | Aero's model verbatim |
| Action | `type` (playAnimation / stopAnimation / show / hide / moveTo / rotate / scale / playAudio / playVideo / delay / setState), `target` (element id, default self), params | `setState` is the hook for the future game layer |
| Bundle | zip: `manifest.json`, `assets/`, `maps/`, `markers/`, `thumbnail.png` | Extension `.arhunt`, UTI `ie.ncad.arhunt`; manifest is the only file the Mac side must understand |

## Functional requirements — Author mode

Author mode is the MVP's core: open the camera, drop an element, adjust it, give it a behaviour, save. Each requirement is tagged MVP or Later.

| ID | Requirement | Priority |
| --- | --- | --- |
| A1 | Import USDZ and .reality files from Files, Photos (for images/video), AirDrop, the share sheet and iCloud Drive | MVP |
| A2 | Import GLB/glTF via an on-device loader; show a rendered preview and a warning list (missing textures, unsupported extensions, triangle count) before accepting | MVP |
| A3 | Import OBJ (static) with automatic conversion | Later |
| A4 | Import images (PNG/JPG/HEIC), video (MP4/MOV, HEVC with alpha) and audio (WAV/MP3/AAC) as planar or audio elements | MVP |
| A5 | Import Gaussian splat files (.ply/.spz) | Later |
| A6 | Tap a detected surface to place an element; drag to move, two-finger rotate, pinch to scale; snap-to-surface toggle; height offset slider | MVP |
| A7 | Numeric inspector for position, rotation, scale, and "face viewer" toggle | MVP |
| A8 | Animation panel: list clips in the asset, choose one for playback, loop/once, speed | MVP |
| A9 | Video playback options: loop, mute, chroma key colour and tolerance for green-screen holograms | MVP (chroma Later) |
| A10 | Behaviours panel: add trigger, add ordered actions, set re-trigger mode; test by tapping "simulate" | MVP (subset: start, tap, proximity; animate, show, hide, playAudio, delay) |
| A11 | Pathway recording: walk the device to record a motion path for a moveTo action | Later |
| A12 | Scene list: all elements with thumbnails, visibility toggles, duplicate, delete, rename | MVP |
| A13 | Save experience locally; autosave on background; version history (last 5) | MVP (history Later) |
| A14 | Asset optimisation on import: downscale textures above 2048 px, warn above 100k triangles, report bundle size | MVP |
| A15 | Undo/redo for transforms and behaviour edits | MVP |
| A16 | Preview as player without leaving author mode | MVP |

## Functional requirements — Anchoring and location

The author never picks an anchoring technology; the app captures every anchor it can at the spot and reports the precision the player will get.

| ID | Requirement | Priority |
| --- | --- | --- |
| L1 | Every placed element gets a `worldmap` anchor by default: the app captures the current ARWorldMap and the element's transform within it when the author saves | MVP |
| L2 | When the author enables "Pin to location", the app calls `ARGeoTrackingConfiguration.checkAvailability(at:)`; if supported, it adds a `geo` anchor via `session.getGeoLocation(forPoint:)` | MVP |
| L3 | If geotracking is unavailable, the app records a `gps` anchor (lat/long/radius) from Core Location for approach guidance and prompts a 20-30 s surroundings scan to strengthen the world map | MVP |
| L4 | Author can add an `image` anchor by photographing a flat marker or by generating a printable A4 marker (element name + QR + high-contrast pattern) that the app exports as PDF | MVP |
| L5 | Author can add an `object` anchor from a trained reference object (.referenceobject) | Later |
| L6 | Precision badge on every element: "Street-precise" (geo), "Site-precise" (worldmap), "Marker-precise" (image), "Approximate" (gps only), with a one-line explanation | MVP |
| L7 | Author is warned when a world map quality is `limited` and offered a rescan | MVP |
| L8 | Multiple world maps per experience; each element references the map it was placed in | MVP |
| L9 | Experience stores a `siteHint` centroid and radius so the player can show a map overview | MVP |
| L10 | Safety: warn the author when an element is placed within 5 m of a road centreline (Apple Maps data) | Later |
| L11 | Location is read only while author or player mode is on screen; never stored beyond the anchors the author saves; never transmitted | MVP |

## Functional requirements — Player mode

A player opens a bundle, is guided to each element, and sees it snap into place once the best available anchor resolves.

| ID | Requirement | Priority |
| --- | --- | --- |
| P1 | Open a `.arhunt` bundle from Files, AirDrop, a URL (download then open), or a QR code scanned in-app | MVP |
| P2 | Library of opened experiences, stored locally, with delete and "open original link" | MVP |
| P3 | Overview map (MapKit) showing the site centroid and element positions where any location anchor exists; distance and bearing to the nearest unresolved element | MVP |
| P4 | Approach guidance: on-screen arrow and distance when > 15 m from an element's location; "look around to find it" prompt inside that radius | MVP |
| P5 | Anchor resolution in priority order: geo → image → worldmap → object → gps fallback; switch silently to a better anchor if one resolves later | MVP (object Later) |
| P6 | Relocalisation feedback: a soft overlay while a world map is matching; timeout after 30 s with a "try a different angle" hint; gps fallback places content on the nearest plane if the author allowed it | MVP |
| P7 | Behaviours execute as authored: start on first resolve, tap via hit-test, proximity from camera distance | MVP |
| P8 | Per-device state: `found` is set when an element has been tapped or approached within 1 m; persisted locally per experience | MVP |
| P9 | Found count badge and a simple list of found/not-found elements | MVP (the full game layer is Later) |
| P10 | Fully offline once the bundle is on device | MVP |
| P11 | Accessibility: large tap targets, VoiceOver labels on UI, reduced-motion respect | MVP |
| P12 | Walking-speed detection shows a "look up" banner | MVP |

## Functional requirements — Sharing and distribution

The bundle is the product; every sharing route delivers the same file. Assumption for MVP (to confirm): file-based sharing only, no hosted catalogue.

| ID | Requirement | Priority |
| --- | --- | --- |
| S1 | Export experience as a `.arhunt` zip (manifest, assets, maps, markers, thumbnail) via the share sheet: AirDrop, Files, Mail, Messages | MVP |
| S2 | Bundle size shown before export, with a warning above 50 MB and an option to downscale textures | MVP |
| S3 | Generate a QR code for any HTTPS URL the author pastes (NAS, GitHub release, iCloud link); the app downloads and opens the bundle when scanned | MVP |
| S4 | Register the `ie.ncad.arhunt` UTI and a `cuardach://open?url=` custom scheme so links open the app directly | MVP |
| S5 | Export the printable marker sheet (PDF) for all image-anchored elements in one action | MVP |
| S6 | Bundles are forward-compatible: unknown manifest keys are preserved, `schemaVersion` gates migrations | MVP |
| S7 | Hosted catalogue: browse and open experiences from an NCAD-run endpoint or an iCloud shared folder | Later |
| S8 | App Clip player for single-element demos | Later |
| S9 | Export a static USDZ of the scene for AR Quick Look sharing (no behaviours or anchors) | Later |

## Post-MVP roadmap

Each item below builds on the MVP data model without changing it; the game layer in particular only consumes the `state` field and the `setState` action already present.

**Game layer (v1.1)**

- Hunt template: author marks elements as "collectable"; player gets a checklist, found count and a completion screen with the author's message.
- Ordering and clues: each element may name a `nextElement` and a text or audio clue revealed on find; unordered hunts remain the default.
- Unlock rules: an element can be `hidden` until another is `found` (uses `setState` on find).
- Completion artefact: a shareable image card generated on device; no server, no leaderboard.

**Authoring depth (v1.2)**

- Pathway recording for moveTo; chroma-key video; object anchors; Gaussian splat import; per-element spatial audio falloff.

**Mac companion (v1.3)**

- A macOS target (or an AROR export tab) that reads and writes `.arhunt` bundles: asset conversion, bulk editing of behaviours, and marker sheet generation, with placement still done on-device.

**Distribution (v1.4)**

- Hosted catalogue on NCAD infrastructure; App Clip player; collaborative session so a class can author one site together.

**visionOS (later)**

- RealityKit scene and bundle format carry over; anchoring and UI need a separate pass.

## Technical architecture

Swift 6, SwiftUI, RealityKit and ARKit only, with the whole non-UI logic in one Swift package so the Mac companion and tests can reuse it. Minimum deployment target iOS 26 (iOS 27 features such as object anchors are gated at runtime).

&#91;embedded content: app architecture · 3 layers\]

Both modes drive one observable Experience model; the core package owns the bundle, the behaviour engine and the anchor resolver, and talks to Apple frameworks only through thin adapters.

**Modules**

- `CuardachCore` (SPM): `Experience`, `Element`, `Anchor`, `Behaviour` Codable types; `BundleWriter`/`BundleReader` (zip via Apple Archive or vendored minizip); `AssetImporter` (USDZ passthrough, GLB via GLTFKit2 → RealityKit entity → serialised to USDZ in the bundle where possible, else kept as GLB with a loader flag); `BehaviourEngine` (trigger evaluation, action scheduler on the RealityKit update loop); `AnchorResolver` (priority walk, timeouts, best-anchor switching).
- `CuardachAR`: `ARSession` ownership, `RealityView` content, world map capture and relocalisation, geo availability checks, image anchor generation.
- `CuardachUI`: SwiftUI screens for Author, Player and Library; gesture bindings via `ManipulationComponent`.
- App target: document type registration, share sheet, QR scanning (`DataScannerViewController`), marker PDF export.

**Storage**

- Experiences live in the app's Documents directory as unpacked `.arhunt` folders (fast editing); packed to zip only on export. iCloud Drive sync is a user choice via Files.
- Per-device player state is a small JSON beside each imported bundle, never inside it.

**Bundle schema (manifest.json, v1)**

```json
{
  "schemaVersion": 1,
  "id": "8d6c…",
  "title": "Courtyard Hunt",
  "author": "NCAD Product Design",
  "siteHint": { "lat": 53.3436, "long": -6.2806, "radiusM": 120 },
  "elements": [
    {
      "id": "e1", "name": "Blue Heron", "kind": "model", "asset": "assets/heron.usdz",
      "transform": { "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1] },
      "anchors": [
        { "id": "a1", "tier": "worldmap", "priority": 2, "mapFile": "maps/court.arworldmap", "anchorTransform": [], "lat": 53.3436, "long": -6.2806 },
        { "id": "a2", "tier": "image", "priority": 1, "imageFile": "markers/e1.png", "physicalWidthM": 0.21 }
      ],
      "behaviours": [
        { "trigger": "tap", "retrigger": "afterComplete", "actions": [[{ "type": "playAnimation", "clip": "fly" }], [{ "type": "setState", "value": "found" }]] }
      ],
      "state": "hidden"
    }
  ]
}
```

## Platform, devices and performance

| Requirement | Target |
| --- | --- |
| OS | iOS 26 and iPadOS 26 minimum; iOS 27 features gated with `#available` |
| Hardware floor | A12 Bionic or later (ARKit world tracking); cellular model required only for geo anchors, and the app degrades to Tier 2/3 without it |
| LiDAR | Optional; used for occlusion and faster plane detection when present |
| Frame rate | 60 fps in player mode with up to 10 visible elements totalling 300k triangles on an A12; author mode may drop to 30 fps during import |
| Launch to camera | Under 2 s warm, under 4 s cold on A12 |
| Relocalisation | Tier 2 world map resolves within 15 s in 90 % of same-day attempts |
| Bundle load | A 50 MB bundle opens within 5 s from local storage |
| Battery | Player session of 30 min uses under 25 % on an iPhone 15 |
| Memory | Under 1.2 GB resident in player mode on 4 GB devices |
| Orientation | iPhone portrait; iPad portrait and landscape |
| Localisation | English and Irish strings from day one (Localizable.xcstrings) |
| Build | Xcode 27, Swift 6 strict concurrency, SPM only, no CocoaPods |
| Distribution | TestFlight for NCAD cohorts; App Store public release; source on GitHub under MIT |

## Privacy, safety and compliance

The app collects nothing, which is the simplest way to be safe for children and compliant everywhere; the requirements below make that enforceable rather than aspirational.

| ID | Requirement |
| --- | --- |
| C1 | No user accounts, no sign-in, no server the app talks to by default. The only network calls are user-initiated bundle downloads from a URL the user supplied, and ARKit's own geotracking imagery fetch |
| C2 | No analytics, crash reporting or advertising SDKs. Crash data comes only through Apple's opt-in TestFlight and App Store channels |
| C3 | Location: `NSLocationWhenInUseUsageDescription` only; purpose string explains anchors; precise location requested only when "Pin to location" is used; coordinates are written only into anchors the author saves and are never logged or sent |
| C4 | Camera: used only while an AR view is on screen; no frames stored except the world map and marker images the author explicitly captures |
| C5 | Bundles contain only what the author put in them; the app strips EXIF location from imported photos and video |
| C6 | Privacy nutrition label: "Data not collected"; privacy manifest declares no required-reason APIs beyond file timestamps |
| C7 | Not listed in the App Store Kids Category; rated 4+; marketing copy avoids "for kids". Supervised classroom and family use is the intended model and is documented in the README |
| C8 | Player mode shows a "look up" banner when CoreMotion reports walking; author mode warns when placing near roads (later) |
| C9 | Content moderation is the author's responsibility; a bundle shows its author name and a "report to NCAD" mail link only on the NCAD-distributed build, never inside player UI aimed at children |
| C10 | GDPR: no personal data processed by the app; NCAD remains controller for any bundle it hosts; a one-page data-protection note ships with the repo |

## Milestones and phased delivery

About 15 weeks of focused work to a TestFlight MVP, with the spike first so the anchoring tiers are known before any UI is built.

&#91;embedded content: delivery plan · 6 milestones, 6 gates\]

The spike is the only milestone with research output rather than code: it answers which tiers apply at NCAD and at a rural site, whether GLTFKit2 is good enough for student exports, and how well world maps survive a week. Everything after it is sequenced so that an end-to-end hunt exists by the end of M3 and the remaining two milestones only harden it.

## Risks, assumptions and open decisions

**Assumptions made in this PRD**

- MVP distribution is file-based (bundle via AirDrop, Files, QR-to-URL); no hosted catalogue. Confirm.
- Authoring happens on the iOS device; the Mac side only prepares assets (via AROR) and, later, edits bundles.
- The app ships under Mark's company developer account, open source, with NCAD as first user rather than owner.
- Working name Cuardach is a placeholder.

**Risks**

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Geotracking unsupported at every site that matters | Tier 1 becomes marketing only | M0 spike confirms; product is designed around Tiers 2-3 regardless |
| World maps decay over days or seasons | Hunts stop working a week later | Re-scan flow for authors; keep marker fallback mandatory for hunts aimed at children |
| GLTFKit2 material bugs on student exports | Bad first impression at import | Preview + warnings at import; teach USDZ; Mac conversion documented |
| RealityKit API churn between iOS 26 and 27 | Rework mid-build | Isolate framework calls in `CuardachAR`; pin to iOS 26 APIs for MVP |
| App Review questions location use | Launch delay | Clear purpose strings, no data collection, demo video in review notes |
| Scope drift into the game layer | MVP slips | Game layer has its own milestone after M5 and its own PRD section; `state` + `setState` are the only MVP hooks |
| Bundle sizes outgrow sharing routes | Teachers can't distribute | Size budget surfaced in UI; QR-to-URL as the big-bundle path |

**Open decisions**

- [ ] Confirm file-based MVP distribution, or pull a minimal hosted catalogue into scope
- [ ] Choose the bundle extension and UTI (`.arhunt` / `ie.ncad.arhunt` proposed)
- [ ] Decide whether the Mac companion is an AROR export target or a separate target in this repo
- [ ] Pick the licence (MIT proposed) and the name
- [ ] Agree the field-test sites for M0 and M5 (NCAD Thomas Street, one courtyard, one site in Meath)
- [ ] Decide whether Irish localisation is MVP or v1.1
