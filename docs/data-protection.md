# Data protection note

*PRD C10. One page, for NCAD, schools and parents.*

## Summary

Cuardach processes no personal data on any server, because it has no server. It has no accounts, analytics, advertising, crash-reporting SDKs or third-party trackers. Everything it stores stays on the device unless the user chooses to share a file. For troubleshooting, the app writes technical events to Apple's on-device system log; it never includes locations or file contents, marks file names private (except the app-generated names of world-map scans), and is not collected or sent anywhere.

## What the app touches, and why

| Data | Used for | Where it goes |
| --- | --- | --- |
| Camera | Showing AR content; scanning a space; detecting printed markers; scanning QR codes | Frames are processed live and discarded. Only what an author explicitly saves is kept: a scan of the space (world map), a marker image, or a documentation photo or video. |
| Location (when in use) | Guiding players to content; letting authors pin content to a place | Used on the device. Coordinates are written only into anchors the author saves in their own file. Never logged or sent. |
| Motion | Showing "Look up while you walk" | Used on the device, not stored. |
| Photos (add only) | Saving documentation photos and videos the user takes | The user's photo library. The app cannot read existing photos except ones the user picks to import. |
| Imported media | Building experiences | Copied into the experience. Location metadata (EXIF GPS) is removed from imported photos and videos. |
| Names typed into the app | The author name on an experience; the name on a crit note | Stored in the experience file and on the device. |
| Progress | Which elements this device has found | A small file beside the experience on this device; never inside the shared file. |

## Network

The app connects to the internet only:

1. When the user opens an https link or scans a QR code that points to an experience file, to download that file.
2. Through ARKit's own geotracking, which fetches Apple's localisation imagery for the area. This is Apple's service, governed by Apple's privacy policy.

## Sharing

An experience file contains only what its author put in it: their media, scans of the space (which can show the space itself), marker images, names they typed, any location pins, and crit notes. Authors should consider what a scan of a private space reveals before sharing it.

## Children

Cuardach is a general creative tool rated 4+, intended for supervised classroom and family use. It is deliberately not listed in the App Store Kids Category, and its marketing copy should avoid "for kids" (App Store guideline 2.3.8). It meets the Kids Category's data rules anyway: no third-party analytics or advertising, no accounts, no chat, no external links in the player. A child's activity is not recorded beyond the local found/not-found list.

## Roles under GDPR

Because the app processes no personal data on anyone's behalf, there is no processor relationship with the app's maintainers. Where NCAD or a school hosts experience files for download, that institution is the controller for any personal data in files it hosts (for example, author names), and should apply its usual policies.

## Content

Authors are responsible for the content of their experiences, including permission to use third-party assets and to place work at a location. The app records credits and licences to help, and warns where a licence restricts showing or selling a work.
