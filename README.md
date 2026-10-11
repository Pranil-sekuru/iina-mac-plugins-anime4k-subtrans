# iina-mac-plugins-anime4k-subtrans

Two [IINA](https://iina.io) plugins for Apple Silicon Macs:

| Plugin | What it does |
|---|---|
| [`anime4k-air`](anime4k-air) | Real-time Anime4K upscaling with an extra **Air HQ** tier tuned for fanless M-series Macs |
| [`subtrans`](subtrans) | Reads a video's DVD bitmap subtitles with Vision OCR and translates them with Apple's on-device Translation. No network, no OpenSubtitles |

## Requirements

- Apple Silicon Mac
- [IINA](https://iina.io) 1.4 or newer (plugin support)
- `subtrans` only: macOS 26 or newer, [Homebrew](https://brew.sh) `ffmpeg` (provides `ffprobe`) and the Xcode command line tools (`xcode-select --install`)

## Install

### 1. Get the code

```sh
git clone https://github.com/<your-username>/iina-mac-plugins-anime4k-subtrans.git
cd iina-mac-plugins-anime4k-subtrans
```

(or use **Code → Download ZIP** on GitHub and unzip it)

### 2. Install the plugins

Quit IINA, then copy the plugin folders into IINA's plugin directory:

```sh
PLUGINS="$HOME/Library/Application Support/com.colliderli.iina/plugins"
mkdir -p "$PLUGINS"
cp -R anime4k-air "$PLUGINS/com.yorkyang2333.anime4k.air.iinaplugin"
cp -R subtrans    "$PLUGINS/local.pranil.subtrans.iinaplugin"
```

Install only the one you want if you don't need both. For development, use `ln -s` instead of `cp -R` so edits show up live.

### 3. Build the subtrans helper (subtrans only)

```sh
brew install ffmpeg
mkdir -p ~/.local/bin
swiftc -O subtrans/helper/subtrans.swift -o ~/.local/bin/subtrans
```

The plugin looks for the helper at `~/.local/bin/subtrans`.

### 4. Enable in IINA

Open IINA, go to **Settings → Plugins**, and make sure both plugins are enabled. Grant any permission prompts. On first use, macOS may ask to download the on-device language pack for translation (System Settings → General → Language & Region → Translation Languages).

## Usage

### anime4k-air
Open any video. The **Anime4K** tab in the sidebar controls the mode and quality. The default is quality `air`, mode `auto`. Switch quality if your Mac runs warm.

### subtrans
Open a local video with DVD subtitles. If none are in your target language, the plugin translates them automatically and loads the `.srt` as it is written. You can also use the plugin menu:

- **Translate subtitles now**
- **Auto-translate when no subtitles in my language** (toggle)

Target language is the `target` preference (default `en`). Results are cached under the plugin's data folder.

## Limitations

- `subtrans` handles DVD (`dvd_subtitle`) tracks only. PGS (Blu-ray) is not supported yet.
- `subtrans` works on local files only, not streams.
- `subtrans` expects `ffprobe` at `/opt/homebrew/bin/ffprobe`.

## Credits and license

`anime4k-air` is a fork of [yorkyang2333/iina-anime4k](https://github.com/yorkyang2333/iina-anime4k), which builds on [Anime4K](https://github.com/bloc97/Anime4K). Only the built plugin is included here. Everything is released under GPL-3.0 (see [LICENSE](LICENSE)).
