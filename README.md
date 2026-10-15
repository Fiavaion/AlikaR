# AlikaR — Cuardach

**Cuardach** (Irish, "search") is a free, open-source iPhone and iPad app for making and exploring augmented-reality work without writing code. Students place 3D models, video, images, sound and text in the real world, pin them to places, give them simple behaviours, and share the result as a single file that anyone with the app can open, offline, with no account and no server.

It replaces Adobe Aero (discontinued December 2025) for NCAD's Fine Art Media, Product Design and Communication Design departments, and extends it with location anchoring, so an experience can be a hunt across a courtyard, a campus or a town. The product brief is in [AR Authoring Platform — PRD.md](AR%20Authoring%20Platform%20—%20PRD.md) and the background in [AR Authoring Platform — Research.md](AR%20Authoring%20Platform%20—%20Research.md).

## What's here

| Part | What it is | Status |
| --- | --- | --- |
| `Sources/CuardachCore` | The whole non-UI app: manifest model, `.arhunt` bundle reader/writer, validator, behaviour engine, tiered anchor resolver, geo maths, asset inspection, Studio features | Builds on macOS, iOS and Linux; 70 unit tests |
| `Sources/cuardach` | Command-line companion: validate, inspect, pack, unpack, catalogue, marker sheets, QR links | Builds and runs on macOS and Linux |
| `Sources/CuardachAR` | ARKit/RealityKit layer: sessions, world maps, geo and image anchors, entity loading, behaviour runtime, markers, documentation capture | iOS only; written, needs its first device build |
| `Sources/CuardachUI` | SwiftUI screens: library, author mode, player mode, panels, briefs | iOS only; written, needs its first device build |
| `App/` | Thin iOS app target (XcodeGen), Info.plist, privacy manifest, English/Irish strings, icon | Generate with XcodeGen |
| `Samples/` | `courtyard-hunt.arhunt`, a demo bundle using every feature, and the script that builds it | Validates clean |
| `docs/` | Architecture, bundle format and JSON Schema, Studio features and teaching notes, studio briefs, data protection | |

## Beyond Aero: the Studio features

On top of the PRD's MVP, Cuardach adds features aimed at how art and design students make, present, credit and critique work. All of them are optional manifest keys, so they never break the core format. See [docs/studio.md](docs/studio.md).

- **Wall labels and statements**: title, maker, year, medium, dimensions, statement and a VoiceOver description for every work.
- **Credits and licences**: creator, source and licence for every asset, with warnings for NC/ND/all-rights-reserved material.
- **True scale**: real dimensions in millimetres, locked at 1:1, so a product sits in the room at its actual size.
- **Variants**: alternative colours, materials, finishes or iterations of one piece, compared in place by tapping.
- **Spatial crit**: lecturers and peers leave notes floating where they stood; the student resolves them and replies.
- **Dwell and time-window triggers**: work that rewards slow looking, or exists only after dark.
- **Documentation capture**: clean photos and screen recordings of the work in situ, for portfolios.
- **Exhibition catalogue**: a self-contained HTML page with statement, labels, interactions and credits.
- **Remix**: copy someone's shared experience into your own library to take it apart.
- **Studio briefs**: nine project prompts tied to the features, with reflection questions and references ([docs/briefs.md](docs/briefs.md)).

## Build and test

### Core and command line (any Mac or Linux machine with Swift 6)

```sh
swift build
swift test                                  # 70 tests
swift run cuardach validate Samples/courtyard-hunt.arhunt
swift run cuardach inspect Samples/courtyard-hunt.arhunt
swift run cuardach catalogue Samples/courtyard-hunt.arhunt -o catalogue.html
swift run cuardach pack Samples/courtyard-hunt.arhunt -o courtyard.arhunt
```

### iOS app (Mac with Xcode 27)

```sh
brew install xcodegen
cd App && xcodegen generate && open Cuardach.xcodeproj
```

Set your signing team, then run on an iPhone or iPad with an A12 chip or later. AR does not work in the Simulator. Open `Samples/courtyard-hunt.arhunt` on the device (AirDrop it, or use Files) to try player mode, then print its markers with `swift run cuardach marker Samples/courtyard-hunt.arhunt heron`.

The AR and UI layers were written without an iOS SDK to hand, so expect a short round of compile fixes on the first Xcode build. See "Known gaps" in [docs/architecture.md](docs/architecture.md).

## Principles (from the PRD)

- **The file is the product.** An experience is a zip with a readable `manifest.json`. It survives the author's account, the college and the vendor. See [docs/bundle-format.md](docs/bundle-format.md).
- **Honest precision.** Every element shows how precisely players will find it: street-, site- or marker-precise, or approximate.
- **Collect nothing.** No accounts, analytics, ads or third-party SDKs (GLTFKit2 excepted). Location stays on the device. See [docs/data-protection.md](docs/data-protection.md).
- **Aero's vocabulary.** Triggers (start, tap, proximity) and actions (animate, show/hide, move, sound) work as they did, so existing teaching material transfers.

## Licence

MIT (proposed in the PRD; see [LICENSE](LICENSE)). The app name and the bundle identifier `ie.ncad.arhunt` are still open decisions.
