# CCNexus

**CCNexus** is an open-source, self-hosted control plane for Minecraft computers running **CC:Tweaked**. It links CraftOS computers and turtles to a modern browser dashboard over WebSockets so you can control speakers, autonomous mining, redstone systems and future automation modules from one place.

## Current features

- Modern responsive dashboard with real-time device status and activity feed.
- Secure pairing with short-lived six-digit codes and individual device tokens.
- One-command CC:Tweaked installer served directly by your own CCNexus instance.
- Remote speaker discovery and multi-device audio routing.
- YouTube/direct media playback through `yt-dlp` + FFmpeg, converted to 48 kHz mono 8-bit PCM for CC:Tweaked speakers.
- Turtle fleet dashboard with GPS position map, fuel/inventory telemetry, and quarry-style width × length × depth mining jobs.
- Pause/resume/stop controls for active turtle quarry jobs.
- Remote binary and analogue redstone control for lights, doors, machines and other builds.
- Persistent local state in `./data` with no required cloud database.
- Standalone Node.js deployment and Docker/Docker Compose deployment.
- Multi-architecture GHCR images for amd64/arm64 **only when a release tag is pushed**.
- Open source feature development through GitHub Issues and pull requests.

## Quick start — Docker

```bash
cp .env.example .env
# Edit CCNEXUS_PUBLIC_URL and CCNEXUS_ADMIN_TOKEN.
docker compose up -d --build
```

Open `http://localhost:3000` (or your reverse-proxied domain) and sign in with `CCNEXUS_ADMIN_TOKEN`. If you did not set one, CCNexus generates a persistent admin token in `data/state.json` and prints it in the container/server logs.

## Quick start — standalone

Requirements: Node.js 20+, npm. `ffmpeg` and `yt-dlp` are optional unless you want remote media/YouTube playback.

```bash
npm install
export CCNEXUS_PUBLIC_URL="https://ccnexus.example.com"
export CCNEXUS_ADMIN_TOKEN="use-a-long-random-secret"
npm start
```

Data is stored in `./data` by default. Set `CCNEXUS_DATA_DIR` to move it.

## Connect a CC:Tweaked computer

1. In the CCNexus dashboard press **Pair device** and generate a six-digit code.
2. On the CC:Tweaked computer/turtle run:

```lua
wget run https://YOUR-CCNEXUS-DOMAIN/install.lua
```

3. Enter your CCNexus URL and the pairing code when prompted.
4. The installer downloads the agent into `/ccnexus/agent.lua`, stores the device credential in `/ccnexus/config.json`, and creates `/startup/ccnexus.lua` so it reconnects after reboot without replacing existing startup scripts.

> CC:Tweaked must be allowed to make HTTP/WebSocket requests to your CCNexus hostname. Server owners may need to adjust ComputerCraft's HTTP allow/deny rules, especially for private/local IP addresses.

## Turtle GPS map

The turtle map uses `gps.locate()`. For absolute world coordinates, set up a CC:Tweaked GPS constellation (normally four GPS hosts with wireless/Ender modems). Quarry control still works without GPS, but the dashboard cannot place the turtle on an absolute world map.

### Quarry behavior

The first quarry implementation is intentionally conservative: a mining turtle traverses a serpentine rectangle and descends layer by layer, reporting fuel, inventory, position and job progress. Test small jobs first and keep fuel available. World obstacles, protected blocks, unloaded chunks and other mods can interrupt movement.

## Audio pipeline

For a direct media URL:

`URL → FFmpeg → 48 kHz mono signed 8-bit PCM → WebSocket → CC:Tweaked speaker.playAudio()`

For YouTube:

`YouTube URL → yt-dlp media URL → FFmpeg → PCM → WebSocket → speaker`

The Docker image includes FFmpeg and yt-dlp. Standalone installations must provide them in `PATH`, or set `FFMPEG_BIN` / `YTDLP_BIN`.

Use media you are permitted to access and stream, and follow the source platform's terms.

## Reverse proxy

WebSocket upgrades must be enabled for `/ws/device`. Set `CCNEXUS_PUBLIC_URL` to the externally reachable HTTPS URL. CC:Tweaked will then use `wss://` automatically.

## Release-only Docker publishing

The GitHub Actions workflow does **not** publish an image on normal pushes. It runs only for tags matching:

```text
v*
ccnexus-v*
```

Example:

```bash
git tag ccnexus-v0.1.0
git push origin ccnexus-v0.1.0
```

That tag builds and pushes:

- `ghcr.io/nekosuneprojects/ccnexus:ccnexus-v0.1.0`
- `ghcr.io/nekosuneprojects/ccnexus:latest`

for `linux/amd64` and `linux/arm64`.

## Security notes

- Set a strong `CCNEXUS_ADMIN_TOKEN` before exposing the dashboard to the internet.
- Pairing codes expire after 10 minutes and are single-use.
- Each Minecraft node receives a unique device token that can be revoked by removing the device.
- Put CCNexus behind HTTPS when it is internet-accessible.
- Treat the `data/` directory as sensitive because it contains device credentials.

## Feature requests

Have an idea for Create mod bridges, inventory automation, reactor control, farms, monitors, alarms, train control, richer turtle pathfinding, or another CC:Tweaked peripheral? Open a **Feature Request** in GitHub Issues with the mod/peripheral name, Minecraft version, CC:Tweaked version and the workflow you want CCNexus to automate.

## License

MIT
