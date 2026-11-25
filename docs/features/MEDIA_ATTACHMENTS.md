# Feature: Media Attachments

> Priority: P1 · Milestone: M1 (display images), M2 (all display, send images) · Modules: FeatureTimeline, FeatureComposer, `MediaPort`, HaloPlatform (decoding) · Requirements: R-P1-MEDIA

## 1. Purpose
Display every incoming media type and send photos (D16).

## 2. User stories
- I see image and video thumbnails inline, open them full screen, zoom, save, share.
- I play audio and voice messages; I open files with Quick Look.
- I pick photos and send them with an optional caption.

## 3. Functional requirements
- FR-1 Inline thumbnails (blurhash placeholder when provided), full-screen viewer with zoom and swipe between media.
- FR-2 Video: poster inline, full-screen playback streamed from a file. *Today videos open in Quick Look* (ROADMAP M20-3).
- FR-3 Audio and voice play in the bubble with waveform, scrubbing and 1×/1.5×/2×. *Today they open in Quick Look; no in-app player* (ROADMAP M20-2).
- FR-4 Files: name, size, Quick Look preview, share.
- FR-5 Photo picker (`PHPicker`) → up to 10 images → `send_image` each with progress and cancel (`abort_send`) **[VERIFIED F-FFI-8]**.
- FR-9 Camera: take a photo or a short video from the composer, permission asked in context (*not built*, ROADMAP M20-5).
- FR-10 Full-size media is handled as files on disk, never as one block in memory; own thumbnails aren't downloaded again after a restart (*not built*, ROADMAP M19-5).
- FR-6 Strip location EXIF; HEIC → JPEG (see [../matrix/MEDIA.md](../matrix/MEDIA.md) §2).
- FR-7 Media display respects the SDK media preview policy (`get_media_preview_display_policy`) **[VERIFIED F-FFI-18]**.
- FR-8 Share extension (D87): text, a link, photos and files shared from other apps are staged by the extension and sent from the app to a chat the person picks; images over `OutgoingImage.maximumBytes` and files over `OutgoingFile.maximumBytes` are refused with a plain message.

## 4. Non-functional requirements
Thumbnail decode ≤ 16 ms on a background thread; memory cap per [../matrix/MEDIA.md](../matrix/MEDIA.md).

## 5–6. Flows and states
Download: `NotLoaded → Loading → Loaded | Failed(retry)`. Upload: `Preparing → Uploading(progress) → Sent | Failed`.

### Sending (seamless echo, D107)
A photo you send shows at once from the SDK's local echo (source `mxc://send-queue.localhost/<txn>`, bytes in the SDK media store) and must stay on screen until the server's own event replaces it. [VERIFIED against Synapse, `sentImageNeverLeavesTheList`] The SDK confirms an echo as `remove(i)` + `pushBack` of an item with the **same** unique ID, and the source changes to the real `mxc:`/encrypted reference. Three rules keep it from flickering:
1. `TimelineDiffCoalescer` (adapter, per subscription) folds that remove + add, within one batch and at the same position, into one `set`; the row never leaves the list, so its views are not rebuilt.
2. `TimelineThumbnailMemory` (feature) keeps shown pictures readable synchronously: a rebuilt `ThumbnailView` paints on its first frame, a failed reload never blanks a shown picture, and when a row's reference changes the picture on screen is adopted as the entry for the new reference (no download for a photo you just uploaded).
3. Disk persistence is the SDK's media store (sqlite, passphrase-encrypted, retention policy), for encrypted and unencrypted rooms alike; Halo adds no plaintext disk cache. The SDK re-keys the uploaded file to the new reference (`replace_media_key`).
Delivery state (TIMELINE FR-6) is the same for photos, videos, files, audio, stickers, locations and text.

## 7. Data models
`MediaRef` (opaque), `MediaInfo { mime, size, width, height, duration, blurhash }`.

## 8. API boundaries
`MediaPort` (download/upload), `TimelinePort.sendImage`.

## 9. Error scenarios
Too large (server limit `get_max_media_upload_size`) · decryption failure · unsupported format (generic file tile).

## 10. Edge cases
Huge panoramas (downsample) · animated GIF as `m.image` (animate) · media in a UTD event.

## 11. Acceptance criteria
- AC-MED-1 Every media type sent from Element Web renders in Halo.
- AC-MED-2 A photo sent from Halo renders in Element Web without location EXIF.
- AC-MED-3 Opening a 100 MB video keeps memory within NFR-12 and shows progress and cancel.
- AC-MED-4 A voice note keeps playing while scrolling, pauses for a call, and is operable with VoiceOver.

## 12. Test requirements
Unit: EXIF stripping, size/format decisions. Integration: S-MED-1..2 (round trip with a headless client). Snapshot: media tiles.

## 13. Open questions
V-MEDIA-1.
