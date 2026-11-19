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
- FR-2 Video playback (AVKit) from a downloaded file.
- FR-3 Audio/voice playback with a waveform when present.
- FR-4 Files: name, size, Quick Look preview, share.
- FR-5 Photo picker (`PHPicker`) → up to 10 images → `send_image` each with progress and cancel (`abort_send`) **[VERIFIED F-FFI-8]**.
- FR-6 Strip location EXIF; HEIC → JPEG (see [../matrix/MEDIA.md](../matrix/MEDIA.md) §2).
- FR-7 Media display respects the SDK media preview policy (`get_media_preview_display_policy`) **[VERIFIED method exists]**.

## 4. Non-functional requirements
Thumbnail decode ≤ 16 ms on a background thread; memory cap per [../matrix/MEDIA.md](../matrix/MEDIA.md).

## 5–6. Flows and states
Download: `NotLoaded → Loading → Loaded | Failed(retry)`. Upload: `Preparing → Uploading(progress) → Sent | Failed`.

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

## 12. Test requirements
Unit: EXIF stripping, size/format decisions. Integration: S-MED-1..2 (round trip with a headless client). Snapshot: media tiles.

## 13. Open questions
V-MEDIA-1.
