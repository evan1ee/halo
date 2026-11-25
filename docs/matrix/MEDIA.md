# Media Handling

## 1. Download and display
- Sources come from timeline items as upstream `MediaSource` (encrypted or plain) — mapped to an opaque `MediaRef` in the domain.
- Thumbnails: `Client.get_media_thumbnail(source, width, height)`; full content: `get_media_content(source)`; large files: `get_media_file(...)` → temporary file **[VERIFIED F-FFI-4 method names; exact parameters at M1]**.
- The SDK's media store caches downloaded media **[ASSUMPTION V-MEDIA-1: cache policy configurable via `set_media_retention_policy` (method exists, F-FFI-4)]**.
- Decoding: ImageIO (`CGImageSource`) off the main thread, downsampled to the display size; animated WebP/GIF/APNG via `CGAnimateImageAtURLWithBlock` / frame extraction **[ASSUMPTION V-APPLE-1: ImageIO decodes animated GIF, APNG and WebP on iOS 26]**.
- Memory: an in-memory LRU of decoded thumbnails (cap 64 MB), evicted on memory warnings.
- **Status (2026-11-25): the two lines above aren't met.** Thumbnails are kept as encoded bytes (48 MB, `TimelineThumbnailMemory`), decoded with `UIImage(data:)` on the main thread in several view bodies, and nothing reacts to memory warnings; full-size content is loaded as one `Data`. ROADMAP M19-1, M19-5.

## 2. Upload
- Images: `Timeline.send_image(...)` with progress (`MediaUploadProgress`) **[VERIFIED F-FFI-8, F-FFI-22]**; strip location EXIF by default; convert HEIC → JPEG for compatibility **[DECISION D56]**; max dimension 4096 px, quality 0.85.
- Sticker pack images: `Client.upload_media(mime, data)` → `mxc://` (F-FFI-4), then written into the pack state event.

## 3. Privacy
- E2EE rooms: media is encrypted by the SDK (attachment keys in the event).
- **Image-pack media is not encrypted** **[VERIFIED F-SPEC-3]** → the warning in [../features/STICKERS.md](../features/STICKERS.md).
- URL previews: off by default in E2EE rooms (`get_url_preview` exists) **[DECISION D57]** (not built; candidate, ROADMAP M20-17).

## 4. Storage limits
Settings → Storage shows the SDK store sizes (`get_store_sizes` F-FFI-14) with "Clear cache" (*today file sizes and Halo's own caches only*, ROADMAP M20-13).
