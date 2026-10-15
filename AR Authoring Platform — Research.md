# AR Authoring Platform — Research

Oct 15, 2026 · @Mark Jones

## Summary

A native iOS app built on RealityKit and ARKit can replace Adobe Aero for NCAD and exceed it in the two areas that matter for a scavenger-hunt use case: location anchoring and ownership of the authored file. No free tool has filled Aero's gap since it was decommissioned in December 2025; the surviving alternatives are either web-AR subscriptions (Zapworks, 8th Wall, Hoverlay) or full game engines (Unity, Unreal).

The headline conclusions:

- Build one app with Author and Player modes, not an app that emits apps. iOS does not permit the latter.
- USDZ is the native runtime format; GLB should be accepted at import through a loader library, with Mac-side conversion (the existing AROR pipeline) as the reliable path for animated assets.
- Apple's Location Anchors (ARGeoAnchor) give sub-metre placement but only along streets Apple has driven; NCAD's Thomas Street frontage is probably covered, its courtyards and any school playground are not. Anchoring therefore has to be tiered: geo anchor where available, saved world map elsewhere, printed image marker as the guaranteed fallback.
- Reuse Aero's behaviour model (trigger + actions) rather than inventing a new one; students already understand it.
- Experiences must be self-contained bundles the author owns and can share by QR, link or AirDrop. A hosted catalogue is a later convenience, never a dependency.
- Use with children is feasible but shapes the design: no accounts, no analytics, no third-party SDKs, location used on-device only, and a teacher-supervised model rather than an App Store Kids Category listing.

## Adobe Aero: what it was and the gap it left

Aero was removed from the App Store, Google Play and Creative Cloud on 6 November 2025, decommissioned on 3 December 2025 (all `.real` scenes stopped working for authors and viewers), and user data was deleted on 16 December 2025. Adobe's stated reason: Aero was built with mixed-reality glasses in mind and the AR landscape had changed since 2020 ([Adobe end-of-support FAQ](https://helpx.adobe.com/aero/faq.html)). It never left beta in six years; the last meaningful update was January 2024 ([community thread](https://community.adobe.com/t5/adobe-aero-discussions/is-adobe-still-actively-developing-aero/m-p/14830000)).

The feature set that users valued, and that no single free tool now replaces:

| Area | What Aero did | Notes for our design |
| --- | --- | --- |
| Authoring surfaces | iPhone/iPad (primary) plus Mac/Windows desktop beta | Mobile-first authoring was the differentiator; desktop was secondary |
| Import | OBJ, FBX, glTF/GLB, USDZ, layered PSD, PNG/JPG, WAV/MP3, animated characters | Aero auto-optimised assets; FBX import was a quiet workhorse for students |
| Anchoring | Surface (horizontal/vertical) and image anchors; no GPS | Our GPS/geo anchoring is a real extension, not parity |
| Interactivity | Behaviours = trigger + ordered/parallel actions. Triggers: Start, Tap, Proximity Enter, Proximity Exit. Re-trigger modes: Immediately / After complete / Never | This model is simple and well understood by design students; reuse it |
| Actions | Animate (play clip), Spin, Bounce, Move To, Follow, Orbit, Aim, Show/Hide (with fade), Play Audio, delays | A dozen primitives covered most student projects |
| Pathways | Draw a motion path in space by walking the device | Cheap to do with ARKit; distinctive and worth keeping |
| Sharing | `.real` file, Adobe link, QR code; viewer needed Aero installed | Link-dependence on Adobe servers is what killed every published experience in one day |
| Cost | Free | Sets the expectation for any replacement |

The data-loss lesson is the important one: Aero experiences lived on Adobe infrastructure and died with it. A replacement for an art college should keep the authored experience as a self-contained file the author owns ([Adobe feature summary](https://helpx.adobe.com/aero/using/whats-new/2022.html), [Aero interactivity docs](https://helpx.adobe.com/aero/using/add-interactivity-to-digital-assets.html)).

## Competitor and alternative landscape

Nothing currently offers Aero's combination of free, mobile-first, no-code authoring with on-device playback. Every surviving option trades one of those away.

| Tool | Type | Authoring | Location AR | Cost (Oct 2026) | Fit for NCAD |
| --- | --- | --- | --- | --- | --- |
| [Zapworks](https://www.g2.com/products/adobe-aero/pricing) | Web AR (Designer no-code, Studio code) | Browser | Via 8th Wall-style GPS, no VPS | Free tier limited to 5 experiences, non-commercial; paid from \~$13/month | Closest no-code successor; subscription per student, web-only rendering quality |
| [8th Wall / Niantic](https://nianticlabs.com/blog/lightshipsummit/) | Web AR platform | Browser editor | Lightship VPS, centimetre-level, needs scanned locations | Paid tiers; VPS scanning is self-serve | Strongest location tech; vendor lock-in, Unity or web only |
| [Hoverlay](https://www.hoverlay.com/blog/adobe-aero-end-of-life-alternatives) | Hosted AR CMS + viewer app | Browser (Spaces) | Geofenced content with map navigation | SaaS, enterprise pricing | Explicitly marketed at Aero refugees; same hosted-dependency risk that killed Aero |
| Artivive | Image-triggered art AR | Browser | None | Free tier, \~5 MB asset cap on pro | Good for 2D artwork, too limited for 3D scenes |
| Unity AR Foundation + Lightship ARDK | Game engine | Unity editor | VPS via Lightship (free core ARDK) | Unity licence; Lightship core free | Full control, but requires programmers; not a student-facing authoring tool |
| Reality Composer / Reality Composer Pro 3 | Apple authoring | Mac (Pro) / iPad (RC, legacy) | None | Free with Xcode | Pro 3 is a developer tool for visionOS/iOS scene assembly, not an end-user AR hunt builder |
| Scenery, Mirra, Minsar | Small no-code AR builders | Mixed | Mostly none | Freemium | Low maintenance confidence; several have stalled |

The pattern across the market: location-based AR has consolidated around Niantic's VPS for web and Unity, and around Apple's own Location Anchors for native iOS. A native app is the only route that avoids a subscription and keeps rendering, anchoring and data on the device ([community thread on replacements](https://community.adobe.com/questions-82/need-suggestions-to-replace-adobe-aero-1219185), [SourceForge AR category](https://sourceforge.net/software/product/Adobe-Aero/alternatives)).

## The current iOS AR stack

iOS 27 shipped on 14 September 2026 and brings ARKit object tracking to iPhone and iPad for the first time; RealityKit on iOS 27 renders Gaussian splats, simulates cloth, and now exposes ARKit data directly. The stack is mature enough that the app needs no third-party engine.

| Layer | What it gives us | Notes |
| --- | --- | --- |
| ARKit (world tracking) | 6-DoF tracking, horizontal/vertical plane detection, raycasting, LiDAR scene mesh on Pro devices, people occlusion | Baseline for placement; A12 or later |
| ARKit image anchors | Detect and track printed images, auto scale estimation | The guaranteed fallback anchor for a hunt |
| ARKit object anchors (new in iOS 27) | Reference objects trained once work on iOS and visionOS | A statue or bench can become an anchor; training needs Reality Composer Pro or an object-capture scan ([WWDC26 object tracking](https://developer.apple.com/videos/play/wwdc2026/283/)) |
| ARKit geotracking | ARGeoAnchor: lat/long/altitude anchors refined against Apple's street imagery | See Positioning section for coverage limits ([Apple docs](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration)) |
| ARWorldMap | Save and reload a scanned space so content relocalises later | Works indoors and in courtyards where geotracking cannot; lighting-sensitive |
| ARKit collaborative sessions | Multiple devices share one world map live | Enables a future multiplayer hunt without a server |
| RealityKit | Entity-component scene graph, PBR rendering, USDZ/Reality loading, skeletal animation playback, VideoMaterial, physics, spatial audio, ManipulationComponent for grab/rotate/scale | Gesture handling for author mode comes almost free |
| RealityKit (iOS 27 additions) | Gaussian splat rendering, cloth simulation, physical-space lighting, navigation mesh ([WWDC26 RealityKit](https://developer.apple.com/videos/play/wwdc2026/279/)) | Splats matter for NCAD: the photogrammetry rig output could drop straight into a hunt |
| Reality Composer Pro 3 | Mac tool for assembling scenes, materials, timelines, training reference objects | Developer-side; useful for templates, not the student authoring surface |
| AR Quick Look | System USDZ viewer from Files, Safari, Messages | Zero-install preview of a single asset; no interactivity or anchoring |
| App Clips | Sub-app launched from a QR/NFC/link without full install | A possible zero-install player, within App Clip size limits |

SwiftUI now binds directly to RealityKit entities, so the author-mode UI (inspectors, lists, gesture attachments) can be plain SwiftUI with a RealityView, which keeps the codebase small ([WWDC25 visionOS 26 overview](https://developer.apple.com/videos/play/wwdc2025/317/)).

## Positioning: how good can GPS-placed content be?

Raw GPS cannot hold AR content visually in place; the best achievable precision depends on where the hunt happens, so the app must choose the anchoring method per element and tell the author what precision they actually got.

| Tier | Method | Typical precision | Where it works | Cost to author |
| --- | --- | --- | --- | --- |
| 1 | ARGeoAnchor (Apple Location Anchors) | Sub-metre, orientation-correct | Outdoors, on or facing streets Apple has photographed; excludes gated, pedestrian-only and indoor areas | None beyond standing at the spot; needs network and A12+ cellular device |
| 2 | GPS to approach, then ARWorldMap relocalisation | Centimetres once relocalised; 5-15 m until then | Anywhere the author has scanned: courtyards, playgrounds, indoors | Author scans \~30 s of surroundings per site; map is sensitive to lighting and layout changes |
| 3 | GPS to approach, then image anchor | Centimetres once the marker is in view | Anywhere a printed marker can be fixed | Print and place a marker (A4 laminate); most robust for children |
| 4 | GPS to approach, then object anchor (iOS 27) | Centimetres once recognised | Fixed distinctive objects: sculptures, signs, benches | Train a reference object from a scan; fragile for featureless or changing objects |
| 5 | GPS + compass only | 5-15 m, drifts | Anywhere outdoors | None; acceptable only for "you are near it" cues, not for placing content |

Apple describes its geotracking imagery as captured from public streets reachable by car, with no coverage of gated or pedestrian-only areas, and only available in specific areas across more than 20 countries ([ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration)). Dublin has had Look Around imagery since 1 October 2020 ([Apple newsroom](https://nr.apple.com/dE9i3U1z2i)), so Thomas Street and Dublin city centre are likely supported; this must be confirmed with `checkAvailability(at:)` at the actual coordinates before promising Tier 1 anywhere. Rural Meath and any schoolyard will fall to Tiers 2-3.

Niantic's Lightship VPS reaches centimetre precision in locations that have been community-scanned, and lets developers scan their own ([Niantic Lightship Summit](https://nianticlabs.com/blog/lightshipsummit/)), but it ties the app to Unity or 8th Wall and to Niantic's service terms. It is not recommended for a sovereignty-focused institutional tool; ARWorldMap gives the same practical outcome for fixed sites at no dependency cost.

Recommended strategy: the author drops an element and the app tries Tier 1; if unavailable it prompts a short scan (Tier 2) and offers to generate a printable marker (Tier 3) as a belt-and-braces option. Each element stores every anchor it has, and the player uses the best one that resolves.

## 3D asset formats on iOS

USDZ is the only format RealityKit loads natively with animation, so it is the runtime format; GLB must be converted or loaded through a library, and FBX is out of scope.

| Format | RealityKit support | Animation | Route into the app |
| --- | --- | --- | --- |
| USDZ / .reality | Native | Skeletal and transform animations play back | Import directly; Blender exports USD, Reality Converter on Mac converts from GLB/OBJ |
| GLB / glTF 2.0 | Not native; a `.glb` path fails to load ([flutter\_sceneview notes](https://pub.dev/packages/flutter_sceneview)) | Via loader only | GLTFKit2's `GLTFRealityKitLoader` builds RealityKit entities on device; has known material edge cases ([GLTFKit2 issue 51](https://github.com/warrenm/GLTFKit2/issues/51)). Mac-side conversion via the AROR pipeline is the reliable path for animated assets |
| OBJ | Via ModelIO | None | Convert to USDZ on import; static props only |
| FBX | None | n/a | Out of scope; convert on Mac |
| Video (MP4/MOV, HEVC) | VideoMaterial on a plane | n/a | Native; alpha via HEVC with alpha for "hologram" cut-outs |
| Images (PNG/JPG/HEIC) | UnlitMaterial on a plane | n/a | Native; layered PSD import is not worth replicating |
| Audio (WAV/MP3/AAC) | Spatial audio on an entity | n/a | Native; proximity-triggered sound was an Aero feature worth keeping |
| Gaussian splat (.ply / .spz) | RealityKit renders splats on iOS 27 | n/a | New; connects the photogrammetry rig to the AR output |

Two practical constraints: USDZ files for mobile should stay under roughly 25 MB and 100k triangles per asset to load quickly over AirDrop and render on an A12, and skinned animation exported from Blender needs the AROR USD checks (usdARKitChecker) before it is trusted on iOS. The import step should run those checks and report problems rather than fail silently.

## Distribution and sharing models

A self-contained bundle opened by the same app is the only model that survives the author, the college and the vendor; everything else is an optional convenience layered on top.

| Model | How a child's phone gets the experience | Infrastructure | Offline | Risk |
| --- | --- | --- | --- | --- |
| Bundle file (recommended MVP) | AirDrop, Files, email attachment, or QR code pointing at a file URL; opens in the app via a registered document type | None | Yes, once received | Large bundles (world maps + assets) can reach tens of MB; AirDrop handles it, email may not |
| Link + QR to a hosted bundle | Scan QR, app downloads bundle from any HTTPS URL (NCAD NAS, GitHub release, iCloud link) | Any static file host | After download | Host disappears, link dies (the Aero failure); mitigated by keeping the file on device |
| Hosted catalogue (post-MVP) | Open "Courtyard Hunt" by name inside the app | Small NCAD-run service or iCloud shared folder | After download | Operational burden; worth it for a teacher with 30 devices |
| App Clip | Scan a code, a lightweight player launches without installing the app | App Store review for the clip; size-capped | No | Clip size limits rule out large assets; good for single-element demos only |
| AR Quick Look | Share a USDZ, view in Safari or Files | None | Yes | No anchoring, no triggers; not a hunt |

Aero's own mechanism, a `.real` file that was really a zip containing an assets folder, is the right precedent: a zip with a JSON manifest, an assets folder, world-map blobs and marker images. Keeping the manifest human-readable means the Mac side (AROR or a future desktop editor) can generate or edit bundles without the iOS app ([Aero export instructions](https://www.adobe.com/products/aero.html)).

## Educational and child-safety considerations

The app should be published as a general creative tool rated 4+ and used by children under adult supervision, not listed in the App Store Kids Category; that keeps the authoring features and location use permissible while still meeting the spirit of the children's rules.

What the rules require, and the design response:

| Requirement | Source | Design response |
| --- | --- | --- |
| Kids Category apps may not include third-party advertising or analytics, nor send identifiable or device information to third parties | [App Store guideline 1.3](https://conductatlas.com/platform/apple/apple-app-store-review-guidelines/kids-category-and-child-safety-restrictions/) | Ship with zero third-party SDKs and no analytics at all, whichever category we use |
| Kids Category apps should not include social networking or chat, external links or purchasing | [Kids Category data restrictions](https://conductatlas.com/platform/apple/apple-app-store-review-guidelines/kids-category-data-collection-restrictions/) | No accounts, no chat, no links; sharing is file-based and author-initiated |
| Terms like "for kids" are reserved for the Kids Category | [guideline 2.3.8](https://www.goodbarber.com/help/apple-rejection-r100/apple-rejection-apps-for-kids-a365/) | Describe it as an AR authoring and exploration tool for education |
| Notify and obtain consent before collecting, transmitting or using location | [location consent provision](https://conductatlas.com/platform/apple/apple-app-store-review-guidelines/provision/CA-P-019087/location-data-collection-requires-prior-user-consent/) | Location is used only on device to resolve anchors; never logged, never transmitted; standard iOS prompt with a plain-language reason |
| GDPR: Ireland sets the digital age of consent at 16; schools act as data controllers for pupils | Irish Data Protection Act 2018 | The app stores no personal data, so there is nothing to consent to; document this in the privacy label |
| Physical safety outdoors: Apple asks geotracking apps to discourage use while moving and warn about private property | [ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration) | Player mode shows a "look up" banner when walking speed is detected; authors are warned when an anchor is placed near a road |

The supervised-use model is also the pedagogically sensible one: a teacher or NCAD student authors the hunt, children play it on borrowed or family devices, and nothing a child does is recorded beyond local found/not-found state.

## Risks, open questions and recommendations

The biggest risk is over-promising GPS precision; the second is spending MVP effort on a format pipeline that the Mac side already solves.

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Tier 1 geotracking unavailable at the sites that matter (NCAD courtyards, Athboy, schoolyards) | High | Treat Tier 2 (world map) + Tier 3 (marker) as the real product; Tier 1 is a bonus where it works |
| ARWorldMap fails to relocalise after weather, season or furniture changes | Medium | Author can re-scan and republish; store multiple maps per anchor (morning/evening) later |
| GLB loader renders materials wrongly on some student exports | Medium | Show a preview at import; offer "convert on Mac" guidance; prefer USDZ in teaching |
| Bundle sizes grow past what email or messaging will carry | Medium | AirDrop and QR-to-URL as primary; warn authors above 50 MB; compress textures on import |
| App Review objects to location use in an app children will use | Low | No Kids Category listing, clear purpose string, no data leaves the device |
| Scope creep toward a game engine | High | MVP is placement + anchoring + Aero-style triggers; game layer is a separate milestone with its own PRD section |

Open questions to settle before implementation:

- [ ] Run `ARGeoTrackingConfiguration.checkAvailability(at:)` for NCAD Thomas Street, the NCAD courtyards, and one Athboy location to know which tiers apply
- [ ] Decide whether the Mac companion is an AROR export target or a separate SwiftUI app sharing the bundle package
- [ ] Confirm the minimum device fleet in the departments (A12 vs LiDAR) to set the performance floor
- [ ] Choose the bundle extension and UTI (proposal: `.arhunt`, `ie.ncad.arhunt`)

Recommendation: proceed with the PRD as a single iOS app, Swift and RealityKit only, bundle-first distribution, tiered anchoring, and Aero's trigger/action vocabulary. Target a TestFlight MVP for a single authored hunt on NCAD's campus.

## Sources

- [Adobe Aero end-of-support FAQ](https://helpx.adobe.com/aero/faq.html)
- [Adobe Aero: add interactivity (triggers and actions)](https://helpx.adobe.com/aero/using/add-interactivity-to-digital-assets.html)
- [Adobe Aero feature summary, April 2022](https://helpx.adobe.com/aero/using/whats-new/2022.html)
- [Adobe Aero export instructions](https://www.adobe.com/products/aero.html)
- [Adobe community: replacements for Aero](https://community.adobe.com/questions-82/need-suggestions-to-replace-adobe-aero-1219185)
- [Apple: ARGeoTrackingConfiguration](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration)
- [Apple newsroom: Look Around in London, Edinburgh and Dublin](https://nr.apple.com/dE9i3U1z2i)
- [WWDC26: Explore advances in RealityKit](https://developer.apple.com/videos/play/wwdc2026/279/)
- [WWDC26: Object tracking on iOS](https://developer.apple.com/videos/play/wwdc2026/283/)
- [WWDC25: What's new in visionOS 26](https://developer.apple.com/videos/play/wwdc2025/317/)
- [Niantic Lightship Summit: VPS](https://nianticlabs.com/blog/lightshipsummit/)
- [Hoverlay: Aero end-of-life alternatives](https://www.hoverlay.com/blog/adobe-aero-end-of-life-alternatives)
- [G2: Aero alternatives pricing](https://www.g2.com/products/adobe-aero/pricing)
- [GLTFKit2 RealityKit loader issue](https://github.com/warrenm/GLTFKit2/issues/51)
- [flutter\_sceneview: RealityKit format notes](https://pub.dev/packages/flutter_sceneview)
- [App Store Review Guidelines: Kids Category restrictions](https://conductatlas.com/platform/apple/apple-app-store-review-guidelines/kids-category-and-child-safety-restrictions/)
