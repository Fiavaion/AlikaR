# The `.arhunt` bundle format (schema version 1)

An experience is a single file the author owns. It opens offline, needs no server, and can be read and written by any tool that understands zip and JSON. The authoritative schema is [`manifest.schema.json`](manifest.schema.json) (JSON Schema 2020-12); this page explains it.

## Container

- A ZIP archive with the extension `.arhunt`, UTI `ie.ncad.arhunt`, MIME type `application/vnd.ncad.arhunt+zip`.
- Entries may be stored or deflated. Cuardach writes stored entries (the contents are already compressed) with `manifest.json` first.
- Paths use `/`, are relative, and never contain `..`. Readers must reject anything else.
- A single top-level wrapper folder is accepted on read (`My Hunt/manifest.json`), so a folder zipped by Finder still opens. `__MACOSX/` and `.DS_Store` are ignored.
- No ZIP64: a bundle must stay under 4 GB. In practice, aim for under 50 MB.

```
manifest.json      the only file a tool must understand
assets/            models (.usdz, .reality, .glb), images, video, audio
maps/              ARWorldMap archives (NSKeyedArchiver, secure coding)
markers/           marker images for image anchors (PNG)
thumbnail.png      optional cover
```

## Manifest essentials

```json
{
  "schemaVersion": 1,
  "id": "8d6c…",
  "title": "Courtyard Hunt",
  "author": "NCAD Product Design",
  "siteHint": { "lat": 53.3436, "long": -6.2806, "radiusM": 120 },
  "elements": [ … ]
}
```

An **element** has an `id`, `kind` (`model`, `video`, `image`, `audio`, `splat`, or `text`), an `asset` path, a `transform` relative to its anchor (`position` in metres, `rotation` as quaternion `[x,y,z,w]`, `scale`), a list of `anchors`, a list of `behaviours`, and an optional initial `state` (`"hidden"` starts invisible).

An **anchor** has an `id`, a `tier` and a `priority` (lower resolves first; ties fall back to geo, image, worldmap, object, gps):

| Tier | Payload | Player precision |
| --- | --- | --- |
| `geo` | `lat`, `long`, `alt`, `heading` | Street-precise (Apple Location Anchors) |
| `worldmap` | `mapFile`, `anchorTransform` (16 numbers, column-major), `capturedAt`, `mappingStatus`, `lat`/`long` for approach | Site-precise once relocalised |
| `image` | `imageFile`, `physicalWidthM`, `transform` (element pose relative to the marker) | Marker-precise |
| `object` | `referenceObjectFile`, `transform` | Object-precise (iOS 27, later) |
| `gps` | `lat`, `long`, `radiusM`, `allowPlaneFallback` | Approximate: guidance, or placed on the nearest surface |

A world-map anchor is also stored inside its map as an `ARAnchor` named `cuardach:<anchor id>`, which ARKit restores on relocalisation; `anchorTransform` is the same pose for tools that cannot read world maps.

A **behaviour** is a `trigger`, a `retrigger` mode and `actions`: an array of steps, each an array of actions that run together. Each step starts when the previous one has finished.

| Trigger | Parameters |
| --- | --- |
| `start` | — fires when the element first appears |
| `tap` | — |
| `proximityEnter`, `proximityExit` | `proximityM` (default 2) |
| `dwell` (Studio) | `dwellS` (default 3), optional `proximityM` |
| `timeWindow` (Studio) | `window: { "from": "18:00", "to": "06:00" }`, local time, may wrap midnight |

`retrigger`: `immediately` (restart), `afterComplete` (default), or `never` (once per session).

| Action | Parameters |
| --- | --- |
| `playAnimation` | `clip` (default: first), `loop`, `speed` |
| `stopAnimation` | — |
| `show`, `hide` | `duration` (fade, seconds) |
| `moveTo` | `position`, `duration` |
| `rotate` | `degrees` (about the vertical axis), `duration` |
| `scale` | `factor`, `duration` |
| `playAudio` | `asset` (default: the element's own sound), `volume` |
| `playVideo` | — |
| `delay` | `seconds` |
| `setState` | `value`: `found`, `visible` (unlocks a hidden element), `hidden`, or custom |
| `setVariant` (Studio) | `variant` id |
| `cycleVariant` (Studio) | — |

Every action takes an optional `target` element id, defaulting to the behaviour's own element.

## Studio keys

All optional; see [studio.md](studio.md).

- Experience: `label` (statement), `annotations` (crit notes), `completionMessage`, `cover`.
- Element: `label`, `credit`, `variants`, `designSize`, `text`, `faceViewer`, `playback`.

## Compatibility rules

1. **Preserve what you don't understand.** Unknown keys, at any level, must be written back unchanged.
2. **Unknown enum values are not errors.** An unknown `kind`, `tier`, `trigger` or action `type` is skipped, never rejected.
3. **`schemaVersion` gates migrations.** Readers upgrade older manifests step by step. A manifest newer than the reader opens read-only.
4. **Player progress never goes in the bundle.** What a device has found lives in a separate file beside it, so sharing a bundle never shares someone's progress.

## Tools

```sh
swift run cuardach validate my-hunt.arhunt      # errors, warnings, good-practice notes
swift run cuardach inspect my-hunt.arhunt       # elements, anchors, behaviours in plain English, sizes
swift run cuardach pack My-Hunt.arhunt/ -o my-hunt.arhunt
swift run cuardach marker my-hunt.arhunt heron  # A4 SVG at the marker's true printed width
```
