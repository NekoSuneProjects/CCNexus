# Audio Nexus: media, radio and TTS

Each Server/World workspace has its own media queue. Queue entries can target one or more online CC:Tweaked computers with connected speakers.

## Sources

- YouTube URL — CCNexus resolves the audio source through yt-dlp and streams it through FFmpeg.
- Direct media URL — files/streams readable by FFmpeg.
- Radio / live stream — treated as a direct long-running stream.
- TTS — generated locally with `espeak-ng`, then converted by FFmpeg for CC:Tweaked speakers.

The final speaker stream is 48 kHz mono signed 8-bit PCM delivered over the existing device WebSocket.

## Controls

The dashboard provides Play, Pause, Resume, Skip, Stop, Clear Queue and live volume controls. A queue belongs to one Server/World workspace so radio in one Minecraft server does not interfere with another.

Pause temporarily stops forwarding FFmpeg output and clears the current CC speaker buffer. Resume restarts output from the paused pipeline. Some remote live-radio servers may disconnect a stream which remains paused for an extended period.

## TTS

Docker images include `espeak-ng`, so TTS does not need an external API key. Standalone installs should install `espeak-ng` or set `TTS_BIN` to a compatible binary.

## Fleet update warning

When an Administrator schedules a fleet update, CCNexus sends a spoken announcement to available speaker nodes in the selected workspace(s), for example:

`CCNexus update scheduled in five minutes. Please allow active turtle jobs to finish or pause them safely.`

At the deadline the dashboard reboots the selected online nodes. Installer v0.3 writes a startup hook which downloads the current `/ccnexus.lua` from the self-hosted dashboard before launching it, making that reboot an agent update for nodes installed/reinstalled with 0.3 or later.
