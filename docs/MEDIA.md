# Audio Nexus: media, radio and TTS

Each Server/World workspace has its own media queue. Queue entries can target one or more online CC:Tweaked computers with connected speakers.

## Sources

- YouTube URL — CCNexus first asks the Neko downloader `/info` service for a usable audio source, then falls back to managed yt-dlp nightly + Deno when needed.
- Direct media URL — files/streams readable by FFmpeg.
- Radio / live stream — treated as a direct long-running stream.
- TTS — generated locally with `espeak-ng`, then converted by FFmpeg for CC:Tweaked speakers.

The final speaker stream is 48 kHz mono signed 8-bit PCM delivered over the existing device WebSocket.

## Neko downloader YouTube resolver

By default CCNexus queries:

```text
https://dl.nekosunevr.co.uk/info?url=<youtube-url>&flat=1&fields=full&cache=1
```

The resolver prefers formats in this order:

1. `251` — WebM/Opus audio, normally 48 kHz.
2. `140` — M4A/AAC audio.
3. `250` — WebM/Opus audio.
4. `249` — WebM/Opus audio.
5. `18` — muxed MP4 only as a last fallback when no preferred audio-only format is available.
6. Otherwise the best remaining non-DRM audio-only format, preferring 48 kHz, then a muxed format if necessary.

CCNexus preserves safe HTTP headers supplied by the `/info` response and performs a tiny range probe of the selected signed media URL from the CCNexus host before handing it to FFmpeg. If the URL is expired, IP-bound to another machine, or otherwise returns an error, CCNexus automatically falls back to its local yt-dlp resolver.

Resolver settings:

```env
CCNEXUS_YOUTUBE_INFO_ENABLED=true
CCNEXUS_YOUTUBE_INFO_API=https://dl.nekosunevr.co.uk/info
CCNEXUS_YOUTUBE_INFO_PROBE=true
```

Set `CCNEXUS_YOUTUBE_INFO_ENABLED=false` to bypass the external resolver and use local yt-dlp directly.

## Managed yt-dlp nightly + Deno fallback

Standalone and Pterodactyl installs do not need a globally installed yt-dlp or Deno by default. CCNexus keeps managed binaries under `data/tools/`.

On first media initialization CCNexus:

1. Downloads the latest official yt-dlp nightly release asset compatible with the host architecture.
2. Downloads the latest official Deno release when Deno is not already managed by CCNexus.
3. Makes the managed executables runnable under Linux/macOS.
4. Uses `yt-dlp --update-to nightly` on later starts instead of downloading the full binary every time.
5. Keeps the previous working binaries when an online update check fails.

The local fallback is equivalent to:

```bash
yt-dlp \
  --remote-components ejs:github \
  --js-runtimes "deno:/path/to/data/tools/deno" \
  --extractor-args "youtube:player_client=mweb" \
  -f "bestaudio/best" \
  --no-playlist \
  -g "https://www.youtube.com/watch?v=..."
```

The dashboard only needs the audio source URL because CCNexus is feeding CC:Tweaked speakers. A download command such as `bv*[height<=1080][vcodec^=avc1]+ba` with `--merge-output-format mp4` is appropriate for saving a 1080p MP4, but would waste bandwidth and processing when only speaker audio is required.

Local fallback defaults can be changed in `.env`:

```env
YTDLP_AUTO_UPDATE=true
YTDLP_CHANNEL=nightly
YTDLP_REMOTE_COMPONENTS=ejs:github
YTDLP_YOUTUBE_CLIENT=mweb
DENO_AUTO_INSTALL=true
```

You may opt out of managed binaries by setting `YTDLP_BIN` and/or `DENO_BIN` to your own executables.

## Controls

The dashboard provides Play, Pause, Resume, Skip, Stop, Clear Queue and live volume controls. A queue belongs to one Server/World workspace so radio in one Minecraft server does not interfere with another.

Pause temporarily stops forwarding FFmpeg output and clears the current CC speaker buffer. Resume restarts output from the paused pipeline. Some remote live-radio servers may disconnect a stream which remains paused for an extended period.

## TTS

Docker images include `espeak-ng`, so TTS does not need an external API key. Standalone installs should install `espeak-ng` or set `TTS_BIN` to a compatible binary.

## Fleet update warning

When an Administrator schedules a fleet update, CCNexus sends a short notification chime followed by a spoken announcement to available speaker nodes in the selected workspace(s), for example:

`CCNexus update scheduled in five minutes. Please allow active turtle jobs to finish or pause them safely.`

At the deadline the dashboard reboots the selected online nodes. Installer v0.3 writes a startup hook which downloads the current `/ccnexus.lua` from the self-hosted dashboard before launching it, making that reboot an agent update for nodes installed/reinstalled with 0.3 or later.
