# iina-mac-plugins-anime4k-subtrans

IINA plugins for macOS (Apple Silicon): Anime4K upscaling with an Air HQ tier, and fully on-device subtitle translation.

## anime4k-air
Fork of [yorkyang2333/iina-anime4k](https://github.com/yorkyang2333/iina-anime4k) (GPL-3.0) with an extra
**Air HQ** quality tier tuned for fanless M-series Macs (defaults: quality `air`, mode `auto`).
Only the built plugin is included; source maps are omitted. Upstream credit belongs to yorkyang2333.

## subtrans
Translates DVD bitmap subtitles on-device: ffprobe dumps SPU packets -> Vision OCR -> Apple Translation -> `.srt`,
loaded into IINA while it is still being written. No network.

Setup (needs ffprobe at `/opt/homebrew/bin/ffprobe`):
```
swiftc -O subtrans/helper/subtrans.swift -o ~/.local/bin/subtrans
```
Limits: DVD (`dvd_subtitle`) tracks only; PGS/Blu-ray not supported yet.

## Install
Copy a plugin folder to `~/Library/Application Support/com.colliderli.iina/plugins/<identifier>.iinaplugin/`
(or symlink it for development).

License: GPL-3.0 (see LICENSE).
